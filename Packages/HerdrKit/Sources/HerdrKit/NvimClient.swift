#if os(macOS)
import Foundation

/// How the drawer starts nvim. Paths travel in environment variables so no
/// quoting of user data ever reaches a shell parser.
public enum NvimCommand {
    /// Runs nvim through the user's login shell (the app's own environment is
    /// sparse) with `--listen` so files can be opened later over RPC. Exit status
    /// 127 means the shell could not find nvim.
    public static func launch(directory: String, socketPath: String, file: String?) -> TerminalCommand {
        var environment = [
            "MACHERDR_NVIM_DIR": directory,
            "MACHERDR_NVIM_SOCK": socketPath,
        ]
        var nvim = #"exec nvim --listen "$MACHERDR_NVIM_SOCK""#
        if let file {
            environment["MACHERDR_NVIM_FILE"] = file
            nvim += #" -- "$MACHERDR_NVIM_FILE""#
        }
        let script = #"cd "$MACHERDR_NVIM_DIR" || exit 1; exec "${SHELL:-/bin/zsh}" -l -c '"# + nvim + "'"
        return TerminalCommand(
            executable: "/bin/sh",
            args: ["-c", script],
            environment: environment,
            authorizationID: nil
        )
    }
}

/// Talks to a running drawer nvim through its `--listen` socket by invoking
/// `nvim --server`. Verified against the installed nvim for insert, cmdline and
/// terminal mode and for paths with spaces and `#`.
public enum NvimClient {
    public enum OpenResult: Equatable, Sendable {
        case opened
        /// The socket could not be reached — nvim is gone.
        case unreachable
        /// nvim is alive but refused (for example an unsaved buffer with `nohidden`).
        case rejected(String)
    }

    /// A Vim double-quoted string literal.
    public static func vimStringLiteral(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    public static func editExpression(path: String) -> String {
        "execute(\"edit \" . fnameescape(\(vimStringLiteral(path))))"
    }

    /// Ctrl-\ Ctrl-N leaves any mode.
    public static func leaveModeArguments(socketPath: String) -> [String] {
        ["--server", socketPath, "--remote-send", #"<C-\><C-N>"#]
    }

    public static func editArguments(socketPath: String, path: String) -> [String] {
        ["--server", socketPath, "--remote-expr", editExpression(path: path)]
    }

    public static func openFile(binary: String, socketPath: String, path: String) async -> OpenResult {
        guard let leave = await run(binary, leaveModeArguments(socketPath: socketPath)),
              leave.status == 0
        else { return .unreachable }
        guard let edit = await run(binary, editArguments(socketPath: socketPath, path: path)) else {
            return .rejected("nvim did not answer")
        }
        return edit.status == 0 ? .opened : .rejected(edit.output)
    }

    public static func evaluate(binary: String, socketPath: String, expression: String) async -> String? {
        guard let result = await run(binary, ["--server", socketPath, "--remote-expr", expression]),
              result.status == 0
        else { return nil }
        return result.output
    }

    /// Absolute path of `nvim` as the user's login shell sees it; resolved once.
    public static func resolveBinary() async -> String? {
        await NvimBinaryCache.shared.get()
    }

    fileprivate static func locate() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let result = await run(shell, ["-l", "-c", "command -v nvim"], timeout: 5),
              result.status == 0
        else { return nil }
        // Login shells may print banners first; the path is the last absolute line.
        return result.output.split(whereSeparator: \.isNewline).map(String.init).last {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// Runs a short-lived process; nil on launch failure or timeout.
    private static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 3
    ) async -> (status: Int32, output: String)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let timedOut = Locked(false)
                let watchdog = DispatchWorkItem {
                    timedOut.set(true)
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                if timedOut.value {
                    continuation.resume(returning: nil)
                    return
                }
                let text = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (process.terminationStatus, text))
            }
        }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ newValue: Value) { lock.lock(); stored = newValue; lock.unlock() }
}

private actor NvimBinaryCache {
    static let shared = NvimBinaryCache()
    private var cached: String?

    func get() async -> String? {
        if let cached { return cached }
        let found = await NvimClient.locate()
        cached = found
        return found
    }
}
#endif
