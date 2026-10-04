#if os(macOS)
import Foundation

/// Branch and ahead-of-upstream count for a directory inside a git checkout.
public struct GitStatus: Sendable, Equatable {
    public let branch: String
    public let ahead: Int

    public init(branch: String, ahead: Int) {
        self.branch = branch
        self.ahead = ahead
    }
}

/// Resolves the checked-out branch by reading `HEAD` directly — no `git`
/// process, so it is cheap enough to run for every space on every refresh.
public enum GitBranchResolver {
    /// `ref: refs/heads/x` → `x`; a detached 40-hex SHA → its first 7; else nil.
    public static func parseHead(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard !ref.isEmpty else { return nil }
            let heads = "refs/heads/"
            return ref.hasPrefix(heads) ? String(ref.dropFirst(heads.count)) : ref
        }
        guard line.count >= 7, line.allSatisfy(\.isHexDigit) else { return nil }
        return String(line.prefix(7))
    }

    public static func branch(forDirectory directory: String) -> String? {
        guard let head = headFile(forDirectory: directory),
              let text = try? String(contentsOf: head, encoding: .utf8)
        else { return nil }
        return parseHead(text)
    }

    /// Walks up to the nearest `.git` and returns the `HEAD` file it implies.
    /// A `.git` *file* (worktree/submodule) holds `gitdir: <path>`, absolute
    /// or relative to the file's own directory.
    static func headFile(forDirectory directory: String) -> URL? {
        let fileManager = FileManager.default
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        while true {
            let git = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return git.appendingPathComponent("HEAD") }
                guard let text = try? String(contentsOf: git, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first,
                      line.hasPrefix("gitdir:")
                else { return nil }
                let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let base = path.hasPrefix("/")
                    ? URL(fileURLWithPath: path)
                    : url.appendingPathComponent(path)
                return base.standardizedFileURL.appendingPathComponent("HEAD")
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }
}

/// Branch (cheap, from HEAD) plus ahead count (one `git rev-list` per cache
/// miss). Results are cached per directory for `ttl` seconds so the sidebar's
/// frequent refreshes do not spawn a process each time.
public actor GitStatusProvider {
    private var cache: [String: (at: Date, status: GitStatus?)] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 5) {
        self.ttl = ttl
    }

    public func status(forDirectory directory: String) async -> GitStatus? {
        guard let branch = GitBranchResolver.branch(forDirectory: directory) else {
            cache[directory] = nil
            return nil
        }
        if let hit = cache[directory], Date().timeIntervalSince(hit.at) < ttl,
           hit.status?.branch == branch {
            return hit.status
        }
        let ahead = await Self.aheadCount(inDirectory: directory) ?? 0
        let status = GitStatus(branch: branch, ahead: ahead)
        cache[directory] = (Date(), status)
        return status
    }

    /// `git rev-list --count @{u}..HEAD`; nil when there is no upstream or git
    /// is unavailable. Runs off the actor so a slow repo never blocks callers
    /// asking about other directories.
    static func aheadCount(inDirectory directory: String) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let git = "/usr/bin/git"
                guard FileManager.default.isExecutableFile(atPath: git) else {
                    continuation.resume(returning: nil)
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: git)
                process.arguments = ["rev-list", "--count", "@{u}..HEAD"]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}
#endif
