#if os(macOS)
import Foundation

/// One file offered by the ⌘K file search. `path` is relative to the repo root.
public struct RepoFileHit: Sendable, Equatable, Identifiable {
    public let path: String
    /// Line counts from `git diff --numstat HEAD`; nil for untracked or binary files.
    public let added: Int?
    public let deleted: Int?
    public let isChanged: Bool

    public var id: String { path }

    public init(path: String, added: Int? = nil, deleted: Int? = nil, isChanged: Bool = false) {
        self.path = path
        self.added = added
        self.deleted = deleted
        self.isChanged = isChanged
    }
}

public enum RepoFileParser {
    /// `git status --porcelain=v1 -z --no-renames` → paths that still exist
    /// (`XY path\0` entries; deletions are dropped because they cannot be opened).
    public static func changedPaths(porcelain: Data) -> [String] {
        porcelain.split(separator: 0).compactMap { entry in
            guard entry.count > 3, let text = String(data: entry, encoding: .utf8) else { return nil }
            let status = text.prefix(2)
            guard !status.contains("D") else { return nil }
            return String(text.dropFirst(3))
        }
    }

    /// `git diff --numstat --no-renames -z` → `path: (added, deleted)`; binary
    /// files (`-\t-`) are skipped.
    public static func numstat(_ data: Data) -> [String: (added: Int, deleted: Int)] {
        var result: [String: (added: Int, deleted: Int)] = [:]
        for entry in data.split(separator: 0) {
            guard let text = String(data: entry, encoding: .utf8) else { continue }
            let parts = text.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let added = Int(parts[0]), let deleted = Int(parts[1]) else { continue }
            result[String(parts[2])] = (added, deleted)
        }
        return result
    }

    public static func paths(nullSeparated data: Data) -> [String] {
        data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
    }
}

/// Subsequence matcher biased toward filename and word-boundary hits.
public enum FuzzyMatcher {
    /// nil when `query` is not a subsequence of `path`; higher is better.
    public static func score(query: String, path: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let hay = Array(path.lowercased())
        let nameStart = hay.lastIndex(of: "/").map { $0 + 1 } ?? 0
        var score = 0
        var matched = 0
        var previous = -2
        for (index, char) in hay.enumerated() where matched < needle.count && char == needle[matched] {
            var points = 1
            if previous == index - 1 { points += 5 }
            if index == 0 || "/_-. ".contains(hay[index - 1]) { points += 4 }
            if index >= nameStart { points += 3 }
            score += points
            previous = index
            matched += 1
        }
        guard matched == needle.count else { return nil }
        return score * 100 - hay.count
    }
}

/// Changed files (newest first) and fuzzy search over `git ls-files`, for the
/// directory a space lives in. Snapshots are cached for `ttl` seconds so typing
/// does not spawn git on every keystroke.
public actor RepoFiles {
    private struct Snapshot {
        let at: Date
        let root: String
        let changed: [RepoFileHit]
        let all: [String]
    }

    private var cache: [String: Snapshot] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 3) {
        self.ttl = ttl
    }

    /// Empty `query` lists changed files; otherwise fuzzy-matches every tracked
    /// and untracked-but-not-ignored file, with changed files ranked up.
    public func hits(
        query: String, directory: String, limit: Int = 30
    ) async -> (root: String, hits: [RepoFileHit])? {
        guard let snapshot = await snapshot(forDirectory: directory) else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return (snapshot.root, Array(snapshot.changed.prefix(limit))) }

        let changedByPath = Dictionary(uniqueKeysWithValues: snapshot.changed.map { ($0.path, $0) })
        var scored: [(hit: RepoFileHit, score: Int)] = []
        for path in snapshot.all {
            guard var score = FuzzyMatcher.score(query: trimmed, path: path) else { continue }
            let hit = changedByPath[path] ?? RepoFileHit(path: path)
            if hit.isChanged { score += 300 }
            scored.append((hit, score))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.hit.path < $1.hit.path }
        return (snapshot.root, scored.prefix(limit).map(\.hit))
    }

    private func snapshot(forDirectory directory: String) async -> Snapshot? {
        if let hit = cache[directory], Date().timeIntervalSince(hit.at) < ttl { return hit }
        guard let rootData = await Self.git(["rev-parse", "--show-toplevel"], in: directory),
              let root = String(data: rootData, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty
        else {
            cache[directory] = nil
            return nil
        }
        async let status = Self.git(
            ["status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"], in: root
        )
        async let stat = Self.git(["diff", "--numstat", "--no-renames", "-z", "HEAD"], in: root)
        async let listing = Self.git(
            ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root
        )
        let numstat = RepoFileParser.numstat(await stat ?? Data())
        let changed = RepoFileParser.changedPaths(porcelain: await status ?? Data())
            .map { path -> (RepoFileHit, Date) in
                let counts = numstat[path]
                let modified = (try? FileManager.default.attributesOfItem(atPath: root + "/" + path))?[.modificationDate]
                return (
                    RepoFileHit(path: path, added: counts?.added, deleted: counts?.deleted, isChanged: true),
                    (modified as? Date) ?? .distantPast
                )
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        let snapshot = Snapshot(
            at: Date(),
            root: root,
            changed: changed,
            all: RepoFileParser.paths(nullSeparated: await listing ?? Data())
        )
        cache[directory] = snapshot
        return snapshot
    }

    /// Runs git off the actor so a slow repo never blocks other directories.
    private static func git(_ arguments: [String], in directory: String) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let git = "/usr/bin/git"
                guard FileManager.default.isExecutableFile(atPath: git) else {
                    continuation.resume(returning: nil)
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: git)
                process.arguments = arguments
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
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
#endif
