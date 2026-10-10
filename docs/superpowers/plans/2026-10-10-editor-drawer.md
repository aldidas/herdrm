# Editor Drawer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-herdr-tab, MacHerdr-owned nvim drawer on the right of the terminal area, toggled with ⌘E and opened with the chosen file from ⌘K → Files.

**Architecture:** Pure, unit-tested logic (session registry, nvim launch command, nvim RPC client) lives in HerdrKit (macOS-gated) so `swift test` covers it. `AppModel` owns one `EditorDrawerRegistry` and drives it from ⌘E, `openFile`, and snapshot refresh. The UI is a kept-alive `ShellTerminalView` per drawer (given an explicit `command`) inside a new `DrawerSplit` that wraps `terminalStack`.

**Tech Stack:** Swift 5/SwiftUI/AppKit, libghostty (`ShellTerminalView`), XCTest, nvim `--listen` / `--server --remote-send|--remote-expr`.

**Spec:** `docs/superpowers/specs/2026-10-10-editor-drawer-design.md`

## Global Constraints

- Local devices only; remote devices never get a drawer (spec: "Local devices only").
- Toggle key is ⌘E, in the Terminal menu as "Toggle Editor Drawer".
- Drawer width ratio: `@AppStorage("editorDrawerRatio")`, default 0.45, clamped 0.25…0.7.
- Files reach a running nvim over its RPC socket, never by typing into the pty.
- Socket path: `$TMPDIR/macherdr-nvim-<8 hex>.sock`; always removed when the session ends; stale ones removed at app start.
- The terminal area keeps one structural position (never branch the view tree to show the drawer) — see `SplitContainer.swift` header.
- Never push to `missuo/herdrm`; commits stay local until the user asks to push to `aldidas/herdrm`.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

1. File path containing spaces, `#`, `"`, `\`, `$`, or non-ASCII must open the right file (Task 2 integration test).
2. `⌘K` open while nvim is in insert / cmdline / terminal mode must still switch buffer (spike-verified; Task 2 test covers insert mode).
3. `:q` in the drawer must close it, and the next open must start a fresh nvim with no stale socket (Task 3 `editorDrawerExited`, Task 1 socket cleanup test).
4. A snapshot without a `tabs` list (older herdr) must NOT tear down every drawer (Task 3 guard; Task 1 reconcile test for scoping to one device).
5. nvim not installed: the drawer must disappear and an alert explain why, not sit empty (Task 3, exit code 127).
6. A rejected `:edit` (e.g. user config `nohidden` with an unsaved buffer) must report an error and must NOT kill the running nvim (Task 2 `.rejected`, Task 3 handling).

## File Structure

| File | Responsibility |
|---|---|
| `Packages/HerdrKit/Sources/HerdrKit/EditorDrawer.swift` (create) | `EditorDrawerKey`, `EditorDrawerSession`, `EditorDrawerRegistry`, `EditorDrawerLayout` |
| `Packages/HerdrKit/Sources/HerdrKit/NvimClient.swift` (create) | `NvimCommand.launch`, `NvimClient` (escaping, locate, open file over RPC) |
| `Packages/HerdrKit/Tests/HerdrKitTests/EditorDrawerTests.swift` (create) | registry + layout + socket-cleanup tests |
| `Packages/HerdrKit/Tests/HerdrKitTests/NvimClientTests.swift` (create) | command/escape unit tests + real-nvim integration test |
| `Sources/MacHerdr/AppModel.swift` (modify) | registry state, `selectedTabKey`, toggle, `openFile`, exit handling, refresh reconcile, start cleanup |
| `Sources/MacHerdr/TerminalView.swift` (modify) | `ShellTerminalView.command` override |
| `Sources/MacHerdr/EditorDrawerView.swift` (create) | `DrawerSplit`, `EditorDrawerStack` |
| `Sources/MacHerdr/ContentView.swift` (modify) | wrap `terminalStack` in `DrawerSplit` |
| `Sources/MacHerdr/MacHerdrApp.swift` (modify) | ⌘E menu item |
| `Packages/HerdrKit/Sources/HerdrKit/HerdrService.swift` (modify) | delete superseded editor helpers |
| `Packages/HerdrKit/Tests/HerdrKitTests/RepoFilesTests.swift` (modify) | delete the test of removed helpers |
| `CHANGELOG.md`, `CLAUDE.md` (modify) | docs |

---

### Task 1: Drawer registry and layout math

**Files:**
- Create: `Packages/HerdrKit/Sources/HerdrKit/EditorDrawer.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/EditorDrawerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (used by Tasks 2–5):
  - `public struct EditorDrawerKey: Hashable, Sendable { init(deviceID: UUID, tabID: String) }`
  - `public struct EditorDrawerSession: Identifiable, Equatable, Sendable { id: UUID; key; directory: String; socketPath: String; initialFile: String?; isVisible: Bool }`
  - `public struct EditorDrawerRegistry: Sendable` with
    `var all: [EditorDrawerSession]`, `func session(for: EditorDrawerKey) -> EditorDrawerSession?`,
    `mutating func show(_ key: EditorDrawerKey, directory: String, initialFile: String?, socketDirectory: String) -> (session: EditorDrawerSession, created: Bool)`,
    `mutating func hide(_ key: EditorDrawerKey)`,
    `mutating func remove(id: UUID) -> EditorDrawerSession?`,
    `mutating func reconcile(deviceID: UUID, liveTabIDs: Set<String>) -> [EditorDrawerSession]`,
    `static func removeStaleSockets(in directory: String)`
  - `public enum EditorDrawerLayout { static let defaultRatio = 0.45; static func clamp(_ ratio: Double) -> Double }`

- [ ] **Step 1: Write the failing tests**

```swift
#if os(macOS)
import XCTest
@testable import HerdrKit

final class EditorDrawerTests: XCTestCase {
    private let device = UUID()
    private var key: EditorDrawerKey { EditorDrawerKey(deviceID: device, tabID: "w1:t1") }

    func testShowCreatesVisibleSessionOnce() {
        var registry = EditorDrawerRegistry()
        let first = registry.show(key, directory: "/repo", initialFile: "/repo/a.swift", socketDirectory: "/tmp/")
        XCTAssertTrue(first.created)
        XCTAssertTrue(first.session.isVisible)
        XCTAssertEqual(first.session.initialFile, "/repo/a.swift")
        XCTAssertTrue(first.session.socketPath.hasPrefix("/tmp/macherdr-nvim-"))
        XCTAssertTrue(first.session.socketPath.hasSuffix(".sock"))

        let second = registry.show(key, directory: "/other", initialFile: "/repo/b.swift", socketDirectory: "/tmp/")
        XCTAssertFalse(second.created)
        XCTAssertEqual(second.session.id, first.session.id)
        XCTAssertEqual(second.session.directory, "/repo", "an existing session keeps its directory")
        XCTAssertEqual(registry.all.count, 1)
    }

    func testHideKeepsSessionAndShowReopensIt() {
        var registry = EditorDrawerRegistry()
        let id = registry.show(key, directory: "/repo", initialFile: nil, socketDirectory: "/tmp/").session.id
        registry.hide(key)
        XCTAssertEqual(registry.session(for: key)?.isVisible, false)
        let again = registry.show(key, directory: "/repo", initialFile: nil, socketDirectory: "/tmp/")
        XCTAssertFalse(again.created)
        XCTAssertEqual(again.session.id, id)
        XCTAssertTrue(again.session.isVisible)
    }

    func testRemoveReturnsSessionAndFreesTheKey() {
        var registry = EditorDrawerRegistry()
        let session = registry.show(key, directory: "/repo", initialFile: nil, socketDirectory: "/tmp/").session
        XCTAssertEqual(registry.remove(id: session.id), session)
        XCTAssertNil(registry.session(for: key))
        XCTAssertNil(registry.remove(id: session.id))
    }

    func testReconcileDropsOnlyMissingTabsOfThatDevice() {
        var registry = EditorDrawerRegistry()
        let otherDevice = UUID()
        let kept = EditorDrawerKey(deviceID: device, tabID: "t-live")
        let gone = EditorDrawerKey(deviceID: device, tabID: "t-gone")
        let foreign = EditorDrawerKey(deviceID: otherDevice, tabID: "t-gone")
        for k in [kept, gone, foreign] {
            _ = registry.show(k, directory: "/r", initialFile: nil, socketDirectory: "/tmp/")
        }
        let removed = registry.reconcile(deviceID: device, liveTabIDs: ["t-live"])
        XCTAssertEqual(removed.map(\.key), [gone])
        XCTAssertNotNil(registry.session(for: kept))
        XCTAssertNotNil(registry.session(for: foreign))
    }

    func testRatioClamp() {
        XCTAssertEqual(EditorDrawerLayout.clamp(0.1), 0.25)
        XCTAssertEqual(EditorDrawerLayout.clamp(0.9), 0.7)
        XCTAssertEqual(EditorDrawerLayout.clamp(0.45), 0.45)
        XCTAssertEqual(EditorDrawerLayout.defaultRatio, 0.45)
    }

    func testRemoveStaleSocketsOnlyTouchesOurFiles() throws {
        let dir = NSTemporaryDirectory() + "drawer-sockets-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for name in ["macherdr-nvim-aaaa1111.sock", "macherdr-nvim-bbbb2222.sock", "unrelated.sock"] {
            FileManager.default.createFile(atPath: dir + name, contents: nil)
        }
        EditorDrawerRegistry.removeStaleSockets(in: dir)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertEqual(left, ["unrelated.sock"])
    }
}
#endif
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/aldidas/Documents/Works/herdrm/Packages/HerdrKit && swift test --filter EditorDrawerTests 2>&1 | grep -E "error:|Executed" | head`
Expected: build error `cannot find 'EditorDrawerKey' in scope`.

- [ ] **Step 3: Implement**

```swift
#if os(macOS)
import Foundation

/// A herdr tab on one device — the unit a drawer belongs to.
public struct EditorDrawerKey: Hashable, Sendable {
    public let deviceID: UUID
    public let tabID: String

    public init(deviceID: UUID, tabID: String) {
        self.deviceID = deviceID
        self.tabID = tabID
    }
}

public struct EditorDrawerSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let key: EditorDrawerKey
    /// nvim's working directory. Fixed at creation.
    public let directory: String
    public let socketPath: String
    /// Opened on launch only; later files go over the socket.
    public let initialFile: String?
    public var isVisible: Bool
}

/// Which tabs have a drawer and whether it is showing. Pure value type: the
/// views and processes follow what this says.
public struct EditorDrawerRegistry: Sendable {
    private var byKey: [EditorDrawerKey: EditorDrawerSession] = [:]

    public init() {}

    /// Stable order so SwiftUI's `ForEach` does not reshuffle.
    public var all: [EditorDrawerSession] {
        byKey.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func session(for key: EditorDrawerKey) -> EditorDrawerSession? { byKey[key] }

    /// Shows the tab's drawer, creating it when missing. An existing session
    /// keeps its directory and ignores `initialFile` (that file is opened over RPC).
    @discardableResult
    public mutating func show(
        _ key: EditorDrawerKey,
        directory: String,
        initialFile: String?,
        socketDirectory: String
    ) -> (session: EditorDrawerSession, created: Bool) {
        if var existing = byKey[key] {
            existing.isVisible = true
            byKey[key] = existing
            return (existing, false)
        }
        let id = UUID()
        let session = EditorDrawerSession(
            id: id,
            key: key,
            directory: directory,
            socketPath: socketDirectory + "macherdr-nvim-\(id.uuidString.prefix(8).lowercased()).sock",
            initialFile: initialFile,
            isVisible: true
        )
        byKey[key] = session
        return (session, true)
    }

    public mutating func hide(_ key: EditorDrawerKey) {
        byKey[key]?.isVisible = false
    }

    @discardableResult
    public mutating func remove(id: UUID) -> EditorDrawerSession? {
        guard let entry = byKey.first(where: { $0.value.id == id }) else { return nil }
        byKey[entry.key] = nil
        return entry.value
    }

    /// Removes this device's drawers whose tab no longer exists; returns them so
    /// the caller can delete their sockets.
    public mutating func reconcile(deviceID: UUID, liveTabIDs: Set<String>) -> [EditorDrawerSession] {
        let stale = byKey.values.filter {
            $0.key.deviceID == deviceID && !liveTabIDs.contains($0.key.tabID)
        }
        for session in stale { byKey[session.key] = nil }
        return stale
    }

    /// Deletes `macherdr-nvim-*.sock` left behind by a previous run.
    public static func removeStaleSockets(in directory: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names where name.hasPrefix("macherdr-nvim-") && name.hasSuffix(".sock") {
            try? FileManager.default.removeItem(atPath: directory + name)
        }
    }
}

public enum EditorDrawerLayout {
    public static let defaultRatio = 0.45
    public static let bounds = 0.25...0.7

    public static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, bounds.lowerBound), bounds.upperBound)
    }
}
#endif
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd /Users/aldidas/Documents/Works/herdrm/Packages/HerdrKit && swift test --filter EditorDrawerTests 2>&1 | grep -E "error:|failed|Executed" | head`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/aldidas/Documents/Works/herdrm
git add Packages/HerdrKit/Sources/HerdrKit/EditorDrawer.swift Packages/HerdrKit/Tests/HerdrKitTests/EditorDrawerTests.swift
git commit -m "feat(drawer): editor drawer registry and layout math

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: nvim launch command and RPC client

**Files:**
- Create: `Packages/HerdrKit/Sources/HerdrKit/NvimClient.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/NvimClientTests.swift`

**Interfaces:**
- Consumes: `TerminalCommand` (module-internal memberwise init: `executable`, `args`, `environment`, `authorizationID`).
- Produces:
  - `NvimCommand.launch(directory: String, socketPath: String, file: String?) -> TerminalCommand`
  - `NvimClient.vimStringLiteral(_:) -> String`, `NvimClient.editExpression(path:) -> String`
  - `NvimClient.leaveModeArguments(socketPath:) -> [String]`, `NvimClient.editArguments(socketPath:path:) -> [String]`
  - `enum NvimClient.OpenResult: Equatable, Sendable { case opened, unreachable, rejected(String) }`
  - `NvimClient.resolveBinary() async -> String?` (cached), `NvimClient.openFile(binary:socketPath:path:) async -> OpenResult`, `NvimClient.evaluate(binary:socketPath:expression:) async -> String?`

- [ ] **Step 1: Write the failing tests**

```swift
#if os(macOS)
import XCTest
@testable import HerdrKit

final class NvimClientTests: XCTestCase {
    func testLaunchPassesPathsThroughEnvironmentNotTheScript() {
        let evil = "/tmp/it's a \"file\" $(rm -rf x).txt"
        let command = NvimCommand.launch(directory: "/my repo", socketPath: "/tmp/s.sock", file: evil)
        XCTAssertEqual(command.executable, "/bin/sh")
        XCTAssertEqual(command.environment["MACHERDR_NVIM_DIR"], "/my repo")
        XCTAssertEqual(command.environment["MACHERDR_NVIM_SOCK"], "/tmp/s.sock")
        XCTAssertEqual(command.environment["MACHERDR_NVIM_FILE"], evil)
        let script = command.args.joined(separator: " ")
        XCTAssertFalse(script.contains("my repo"))
        XCTAssertFalse(script.contains("rm -rf"))
        XCTAssertTrue(script.contains("exec nvim --listen"))
        XCTAssertTrue(script.contains("MACHERDR_NVIM_FILE"))
    }

    func testLaunchWithoutFileOmitsFileArgument() {
        let command = NvimCommand.launch(directory: "/r", socketPath: "/tmp/s.sock", file: nil)
        XCTAssertNil(command.environment["MACHERDR_NVIM_FILE"])
        XCTAssertFalse(command.args.joined(separator: " ").contains("MACHERDR_NVIM_FILE"))
    }

    func testVimStringLiteralEscapesBackslashAndQuote() {
        XCTAssertEqual(NvimClient.vimStringLiteral(#"a"b\c"#), #""a\"b\\c""#)
        XCTAssertEqual(
            NvimClient.editExpression(path: "/x y/z#.txt"),
            #"execute("edit " . fnameescape("/x y/z#.txt"))"#
        )
    }

    func testClientArguments() {
        XCTAssertEqual(
            NvimClient.leaveModeArguments(socketPath: "/s"),
            ["--server", "/s", "--remote-send", #"<C-\><C-N>"#]
        )
        XCTAssertEqual(NvimClient.editArguments(socketPath: "/s", path: "/p").prefix(3), ["--server", "/s", "--remote-expr"])
    }

    func testUnreachableSocketIsReportedAsUnreachable() async throws {
        let binary = try await XCTUnwrapAsync(await NvimClient.resolveBinary(), "nvim not installed")
        let result = await NvimClient.openFile(binary: binary, socketPath: "/tmp/does-not-exist-\(UUID().uuidString).sock", path: "/etc/hosts")
        XCTAssertEqual(result, .unreachable)
    }

    /// Real nvim, real socket: insert mode, then a path with a space and a `#`.
    func testOpenFileSwitchesBufferEvenFromInsertMode() async throws {
        let binary = try await XCTUnwrapAsync(await NvimClient.resolveBinary(), "nvim not installed")
        let dir = NSTemporaryDirectory() + "nvim-client-\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let socket = dir + "n.sock"
        let target = dir + "weird name#1.txt"
        try "hello\n".write(toFile: target, atomically: true, encoding: .utf8)

        let server = Process()
        server.executableURL = URL(fileURLWithPath: binary)
        server.arguments = ["--headless", "--listen", socket]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            server.terminate()
            try? FileManager.default.removeItem(atPath: dir)
        }
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: socket) {
            try await Task.sleep(for: .milliseconds(100))
        }

        // Put nvim in insert mode first.
        _ = await NvimClient.evaluate(binary: binary, socketPath: socket, expression: #"feedkeys("i", "n")"#)
        let result = await NvimClient.openFile(binary: binary, socketPath: socket, path: target)
        XCTAssertEqual(result, .opened)
        let name = await NvimClient.evaluate(binary: binary, socketPath: socket, expression: #"expand("%:t")"#)
        XCTAssertEqual(name, "weird name#1.txt")
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async -> T?, _ message: String) async throws -> T {
    guard let unwrapped = await value() else { throw XCTSkip(message) }
    return unwrapped
}
#endif
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/aldidas/Documents/Works/herdrm/Packages/HerdrKit && swift test --filter NvimClientTests 2>&1 | grep -E "error:|Executed" | head`
Expected: build error `cannot find 'NvimCommand' in scope`.

- [ ] **Step 3: Implement**

```swift
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd /Users/aldidas/Documents/Works/herdrm/Packages/HerdrKit && swift test --filter NvimClientTests 2>&1 | grep -E "error:|failed|skipped|Executed" | head`
Expected: all pass (the two nvim tests are skipped only if nvim is missing from the login shell; on this machine they must run, not skip).

- [ ] **Step 5: Commit**

```bash
cd /Users/aldidas/Documents/Works/herdrm
git add Packages/HerdrKit/Sources/HerdrKit/NvimClient.swift Packages/HerdrKit/Tests/HerdrKitTests/NvimClientTests.swift
git commit -m "feat(drawer): nvim launch command and RPC client

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: AppModel integration and removal of the superseded pane flow

**Files:**
- Modify: `Sources/MacHerdr/AppModel.swift` (properties near `repoFiles` ~line 159; replace `openFile` in `// MARK: - File search (⌘K)`; hook in `performRefresh` after `reconcileAttachSessions`; `start()`)
- Modify: `Packages/HerdrKit/Sources/HerdrKit/HerdrService.swift` (delete `foregroundProcessNames`, `isEditorProcessName`, `vimEscapedPath`, `openInEditor`, `launchEditor`)
- Modify: `Packages/HerdrKit/Tests/HerdrKitTests/RepoFilesTests.swift` (delete `testVimPathEscapingAndEditorNames`)

**Interfaces:**
- Consumes: Task 1 registry types, Task 2 `NvimClient`.
- Produces (used by Tasks 4–5):
  - `AppModel.editorDrawers: EditorDrawerRegistry` (`@Published`)
  - `AppModel.selectedTabKey: EditorDrawerKey?`
  - `AppModel.visibleEditorDrawerID: UUID?`
  - `AppModel.toggleEditorDrawer()`
  - `AppModel.editorDrawerExited(_ id: UUID, code: Int32?)`
  - `AppModel.openFile(path:in:directory:)` (same signature)

AppModel has no unit-test harness; this task is verified by `make build` plus the manual checklist in Task 5.

- [ ] **Step 1: Add state and helpers.** Below `let repoFiles = RepoFiles()` add:

```swift
    @Published var editorDrawers = EditorDrawerRegistry()
```

In the `// MARK: - File search (⌘K)` section, replace the whole `openFile` function with:

```swift
    /// The tab the selected pane lives in, for local devices only.
    var selectedTabKey: EditorDrawerKey? {
        guard let ref = selectedPane, device(ref.deviceID)?.isLocal == true else { return nil }
        let state = session(ref.deviceID)
        let tabID: String? = state.agents.first { $0.paneID == ref.paneID }?.tabID
            ?? state.panes.first { $0.paneID == ref.paneID }?.tabID
        return tabID.map { EditorDrawerKey(deviceID: ref.deviceID, tabID: $0) }
    }

    /// The drawer to draw right now: only beside an attached herdr pane, never over a
    /// standalone shell or the file manager.
    var visibleEditorDrawerID: UUID? {
        guard selectedShellID == nil, !isFileManagerActive, selectedAttachedEntry != nil,
              let key = selectedTabKey,
              let session = editorDrawers.session(for: key), session.isVisible
        else { return nil }
        return session.id
    }

    /// ⌘E: hide the tab's drawer if it is showing, else show it (starting plain
    /// nvim in the pane's directory when the tab has none).
    func toggleEditorDrawer() {
        guard let key = selectedTabKey, selectedShellID == nil, !isFileManagerActive,
              let target = fileSearchTarget
        else { return }
        if let session = editorDrawers.session(for: key), session.isVisible {
            editorDrawers.hide(key)
            if let entry = selectedAttachedEntry { AttachViewRegistry.focus(entry.id) }
            return
        }
        let shown = editorDrawers.show(
            key, directory: target.directory, initialFile: nil, socketDirectory: NSTemporaryDirectory()
        )
        ShellViewRegistry.focus(shown.session.id)
    }

    /// Opens `path` in the tab's drawer: a fresh nvim when there is none, otherwise
    /// the running one over its RPC socket. `space` is kept for the caller's sake;
    /// the drawer follows the selected pane's tab.
    func openFile(path: String, in space: SpaceRef, directory: String) {
        guard let key = selectedTabKey else { return }
        guard let existing = editorDrawers.session(for: key) else {
            launchDrawer(key: key, directory: directory, file: path)
            return
        }
        editorDrawers.show(key, directory: existing.directory, initialFile: nil, socketDirectory: NSTemporaryDirectory())
        Task { @MainActor in
            guard let binary = await NvimClient.resolveBinary() else {
                actionError = String(localized: "nvim was not found in your shell PATH.")
                return
            }
            switch await NvimClient.openFile(binary: binary, socketPath: existing.socketPath, path: path) {
            case .opened:
                ShellViewRegistry.focus(existing.id)
            case .unreachable:
                // nvim died between its exit event and now: replace the session.
                discardDrawer(id: existing.id)
                launchDrawer(key: key, directory: directory, file: path)
            case .rejected(let message):
                // Alive but refused (e.g. unsaved buffer with 'nohidden'): keep it.
                actionError = String(localized: "nvim could not open the file: \(message)")
            }
        }
    }

    private func launchDrawer(key: EditorDrawerKey, directory: String, file: String?) {
        let shown = editorDrawers.show(
            key, directory: directory, initialFile: file, socketDirectory: NSTemporaryDirectory()
        )
        ShellViewRegistry.focus(shown.session.id)
    }

    private func discardDrawer(id: UUID) {
        guard let removed = editorDrawers.remove(id: id) else { return }
        try? FileManager.default.removeItem(atPath: removed.socketPath)
    }

    /// The drawer's nvim ended (`:q`, crash, or missing binary).
    func editorDrawerExited(_ id: UUID, code: Int32?) {
        discardDrawer(id: id)
        if code == 127 {
            actionError = String(localized: "nvim was not found in your shell PATH.")
        }
    }
```

- [ ] **Step 2: Reconcile on refresh.** In `performRefresh`, directly after `reconcileAttachSessions(deviceID: deviceID)` add:

```swift
            // A snapshot without a tab list (older herdr) says nothing about tabs;
            // reconciling against an empty set would tear every drawer down.
            if let tabs = snapshot.tabs {
                for removed in editorDrawers.reconcile(deviceID: deviceID, liveTabIDs: Set(tabs.map(\.tabID))) {
                    try? FileManager.default.removeItem(atPath: removed.socketPath)
                }
            }
```

- [ ] **Step 3: Clean stale sockets at launch.** Find `func start()` in `AppModel` (grep `func start()`), and add as its first statement:

```swift
        EditorDrawerRegistry.removeStaleSockets(in: NSTemporaryDirectory())
```

- [ ] **Step 4: Delete the superseded helpers.** In `HerdrService.swift` remove `foregroundProcessNames(paneID:)`, `isEditorProcessName(_:)`, `vimEscapedPath(_:)`, `openInEditor(paneID:path:)`, `launchEditor(paneID:path:)` (the block added with the ⌘K file search, just above `sendInput`). In `RepoFilesTests.swift` delete `testVimPathEscapingAndEditorNames`.

- [ ] **Step 5: Build and test**

Run: `cd /Users/aldidas/Documents/Works/herdrm && make build 2>&1 | grep -E "error:|BUILD" ; cd Packages/HerdrKit && swift test 2>&1 | grep -E "error:|Executed" | tail -3`
Expected: `** BUILD SUCCEEDED **`; HerdrKit tests: 0 failures (integration suites that need a live herdr may be skipped/failed as before this change — compare against `git stash`-free baseline: only tests named `EditorDrawer*`, `NvimClient*`, `RepoFiles*` are in scope for this plan).

- [ ] **Step 6: Commit**

```bash
cd /Users/aldidas/Documents/Works/herdrm
git add -A
git commit -m "feat(drawer): drive the editor drawer from AppModel; drop the pane :e flow

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Drawer views and layout

**Files:**
- Modify: `Sources/MacHerdr/TerminalView.swift` (`ShellTerminalView` ~line 1718–1780)
- Create: `Sources/MacHerdr/EditorDrawerView.swift`
- Modify: `Sources/MacHerdr/ContentView.swift` (`terminal`, ~line 609)

**Interfaces:**
- Consumes: Task 3 `AppModel` members; `NvimCommand.launch`; `EditorDrawerLayout`; `ShellViewRegistry`.
- Produces: `DrawerSplit`, `EditorDrawerStack`.

- [ ] **Step 1: `command` override on `ShellTerminalView`.** Add the property after `var onViewReady`:

```swift
    /// Replaces the default login shell (the editor drawer runs nvim here). Read once,
    /// when the view is created.
    var command: TerminalCommand? = nil
```
and in `makeNSView` replace

```swift
        let command = HerdrService(device: device, autoStartLocalServer: false)
            .terminalCommand()
        context.coordinator.authorizationID = command.authorizationID
        context.coordinator.scheduleAuthorizationCleanup()
        host.start(command: command)
```
with

```swift
        let launch = command ?? HerdrService(device: device, autoStartLocalServer: false)
            .terminalCommand()
        context.coordinator.authorizationID = launch.authorizationID
        context.coordinator.scheduleAuthorizationCleanup()
        host.start(command: launch)
```

- [ ] **Step 2: Create `EditorDrawerView.swift`**

```swift
import AppKit
import HerdrKit
import SwiftUI

/// `[ main | divider | drawer ]` with the drawer on the right.
///
/// Like `SplitContainer`, `main` keeps one structural position: opening the drawer only
/// changes `main`'s trailing padding, never the view tree, so attached terminals are not
/// rebuilt. The drawer keeps its full width while closed (just invisible and inert), so
/// its terminal never sees a zero-column resize.
struct DrawerSplit<Main: View, Drawer: View>: View {
    let isOpen: Bool
    @Binding var ratio: Double
    @ViewBuilder var main: () -> Main
    @ViewBuilder var drawer: () -> Drawer

    /// Ratio when the current drag began; `translation` is a delta.
    @State private var dragStartRatio: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let drawerWidth = total * EditorDrawerLayout.clamp(ratio)
            ZStack(alignment: .trailing) {
                main()
                    .padding(.trailing, isOpen ? drawerWidth + 1 : 0)
                drawer()
                    .frame(width: drawerWidth)
                    .opacity(isOpen ? 1 : 0)
                    .allowsHitTesting(isOpen)
                if isOpen {
                    divider(total: total)
                        .padding(.trailing, drawerWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(.clear)
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard total > 0 else { return }
                                let start = dragStartRatio ?? EditorDrawerLayout.clamp(ratio)
                                if dragStartRatio == nil { dragStartRatio = start }
                                // The drawer is on the right: dragging left grows it.
                                ratio = EditorDrawerLayout.clamp(start - value.translation.width / total)
                            }
                            .onEnded { _ in dragStartRatio = nil }
                    )
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
            )
    }
}

/// One kept-alive nvim terminal per drawer session. Hidden drawers stay in the
/// hierarchy (opacity 0, surface hidden) so their nvim — and its buffers — survive.
struct EditorDrawerStack: View {
    @ObservedObject var model: AppModel
    @AppStorage(TerminalDefaults.fontNameKey) private var fontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var fontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var thinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var fontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var lineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage(TerminalThemeSetting.key) private var themeName = ""
    @AppStorage("terminal.mouseReporting") private var mouseReporting = true
    @AppStorage("terminal.copyOnSelect") private var copyOnSelect = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ForEach(model.editorDrawers.all) { session in
                let visible = model.visibleEditorDrawerID == session.id
                ShellTerminalView(
                    sessionID: session.id,
                    fontName: fontName,
                    fontSize: fontSize,
                    thinStrokes: thinStrokes,
                    fontWeight: fontWeight,
                    lineSpacing: lineSpacing,
                    dark: colorScheme == .dark,
                    themeName: themeName,
                    mouseReporting: mouseReporting,
                    copyOnSelect: copyOnSelect,
                    isVisible: visible,
                    onExit: { code in model.editorDrawerExited(session.id, code: code) },
                    command: NvimCommand.launch(
                        directory: session.directory,
                        socketPath: session.socketPath,
                        file: session.initialFile
                    )
                )
                // Stable id, not keyed on colorScheme: a new id would kill nvim.
                .id("drawer-\(session.id)")
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.terminalBackground)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
            }
        }
        .background(Theme.terminalBackground)
    }
}
```

- [ ] **Step 3: Wire into `DetailView.terminal`.** Add next to the other `@AppStorage` properties in the `// MARK: - Terminal` block:

```swift
    @AppStorage("editorDrawerRatio") private var editorDrawerRatio = EditorDrawerLayout.defaultRatio
```
and replace `terminalStack` inside `terminal` with:

```swift
            DrawerSplit(
                isOpen: model.visibleEditorDrawerID != nil,
                ratio: $editorDrawerRatio
            ) {
                terminalStack
            } drawer: {
                EditorDrawerStack(model: model)
            }
```

- [ ] **Step 4: Build**

Run: `cd /Users/aldidas/Documents/Works/herdrm && make build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`. If the compiler rejects the parameter order in `ShellTerminalView(...)` (memberwise init requires declaration order), reorder the arguments to match the property order in the struct.

- [ ] **Step 5: Commit**

```bash
cd /Users/aldidas/Documents/Works/herdrm
git add -A
git commit -m "feat(drawer): editor drawer views and DrawerSplit layout

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: ⌘E menu item, docs, and manual verification

**Files:**
- Modify: `Sources/MacHerdr/MacHerdrApp.swift` (`CommandMenu("Terminal")`, line ~124)
- Modify: `CHANGELOG.md`, `CLAUDE.md`

**Interfaces:** Consumes `AppModel.toggleEditorDrawer()`.

- [ ] **Step 1: Menu item.** At the top of `CommandMenu("Terminal") { … }`, before "Split Vertically":

```swift
                // Not `.disabled` on model state: the commands body is evaluated once per
                // focused-value change, so such a flag would go stale (see the note on
                // `splitAxis` above). The action guards itself instead.
                Button("Toggle Editor Drawer") { focusedModel?.toggleEditorDrawer() }
                    .keyboardShortcut("e", modifiers: .command)

                Divider()
```

- [ ] **Step 2: Docs.** Add under `## [Unreleased]` → `### Added` in `CHANGELOG.md`:

```markdown
- **Editor drawer.** ⌘E toggles a per-tab nvim drawer on the right; choosing a file in
  ⌘K → Files opens it there (a running nvim switches buffer over its RPC socket). Hiding
  keeps nvim alive. Local spaces only.
```
and replace the "Opening a file" sentence in the existing "File search in ⌘K" entry so it says files open in the editor drawer. In `CLAUDE.md` add one bullet under Layout notes: `Editor drawer: EditorDrawerRegistry/NvimClient (HerdrKit), DrawerSplit/EditorDrawerStack (Sources/MacHerdr/EditorDrawerView.swift); nvim runs with --listen $TMPDIR/macherdr-nvim-*.sock.`

- [ ] **Step 3: Full build + tests**

Run: `cd /Users/aldidas/Documents/Works/herdrm && make build 2>&1 | grep -E "error:|BUILD"; cd Packages/HerdrKit && swift test --filter "EditorDrawerTests|NvimClientTests|RepoFilesTests" 2>&1 | grep -E "error:|failed|Executed" | tail -3`
Expected: `** BUILD SUCCEEDED **`; 0 failures.

- [ ] **Step 4: Manual verification (run `make run`; tick each)**

- [ ] ⌘E on a local tab opens the drawer on the right with nvim in the pane's directory; ⌘E again hides it and the agent terminal has the keyboard.
- [ ] Type something in an nvim buffer, ⌘E to hide, ⌘E to show: buffer and cursor are unchanged.
- [ ] ⌘K → Files → ↩ with no drawer: drawer opens showing that file.
- [ ] Put nvim in insert mode, ⌘K → Files → pick another file: buffer switches.
- [ ] Pick a file whose name has a space and a `#`.
- [ ] Drag the divider; relaunch the app; the ratio is remembered.
- [ ] Open a drawer on tab A, switch to tab B (no drawer): drawer disappears; back to A: it returns with its state.
- [ ] `:q` in the drawer: it closes; ⌘E starts a fresh nvim; `ls $TMPDIR/macherdr-nvim-*` shows only live sockets.
- [ ] Close tab A in herdr: its nvim process is gone (`pgrep -fl "nvim --listen"`).
- [ ] Select a standalone shell and the file manager: no drawer, ⌘E does nothing.
- [ ] Temporarily run with `PATH` lacking nvim (or rename nvim): alert "nvim was not found in your shell PATH." and no empty drawer.

- [ ] **Step 5: Commit**

```bash
cd /Users/aldidas/Documents/Works/herdrm
git add -A
git commit -m "feat(drawer): ⌘E toggle, docs

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** per-tab lazily created drawer (T1/T3), hide keeps process (T3 `hide`, T4 kept-alive), ⌘E (T3/T5), ⌘K open new vs existing (T3 + T2 RPC), launch via login shell (T2), layout/ratio/divider (T4), local-only (T3 `selectedTabKey`), visibility rules (T3 `visibleEditorDrawerID`), end-of-life: `:q` (T3 `editorDrawerExited`), tab gone (T3 reconcile), app quit (process dies with the app; stale sockets cleared at start, T3), removals (T3), error handling (T2 results, T3), risks 1 and 2 verified before writing (⌘E reaches the menu in `performKeyEquivalent`; RPC spike passed in insert, cmdline and terminal mode), risk 3 (hidden-but-alive surface) covered by the manual "hide/show keeps buffer" check.
- **Spec deviation:** pure units live in HerdrKit (macOS-gated) instead of "app types" so `swift test` covers them; the spec's `NvimLocator` is `NvimClient.resolveBinary`. The unreachable-socket case replaces the session and retries once; a rejected `:edit` shows an alert instead of retrying (never kill a live nvim).
- **Type consistency:** `show(_:directory:initialFile:socketDirectory:) -> (session:created:)`, `remove(id:)`, `reconcile(deviceID:liveTabIDs:)`, `NvimClient.openFile(binary:socketPath:path:) -> OpenResult`, `editorDrawerExited(_:code:)` are used identically in Tasks 1–4.
- **Placeholders:** none; Task 3 Step 3 names the function by grep because `start()`'s exact line was not read — the implementer must locate it with `grep -n "func start()" Sources/MacHerdr/AppModel.swift`.
