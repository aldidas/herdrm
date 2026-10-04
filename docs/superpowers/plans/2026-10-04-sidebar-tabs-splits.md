# Sidebar, Space Tabs, Herdr Splits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the sidebar to match the herdr-gpui reference, add a per-space tab bar, and render a tab's panes in herdr's own split layout.

**Architecture:** Pure, unit-tested logic lives in HerdrKit (git branch resolution, tab→pane selection, `pane.layout` decoding, split-tree building). `AppModel` stores the derived state (git statuses, per-tab layouts) and keeps one attach session per pane. SwiftUI views (`SidebarView` rows, `SpaceTabBar`, split placement in `ContentView.attachedTerminal`) render it. Terminals are never rebuilt on layout change: the existing kept-alive `ZStack` of attach children is *repositioned* by frame instead of nested in a recursive view.

**Tech Stack:** Swift 6 / SwiftUI (macOS), HerdrKit SPM package (XCTest), libghostty terminals, herdr protocol 22.

**Spec:** `docs/superpowers/specs/2026-10-04-sidebar-tabs-splits-design.md`

## Global Constraints

- Build with `make build` (never raw `xcodebuild` without `-skipPackagePluginValidation`); HerdrKit tests with `cd Packages/HerdrKit && swift test --filter <Suite>`.
- macOS-only HerdrKit files are wrapped in `#if os(macOS)` (the package also builds for iOS).
- Keep `StickySection` wrappers, `*RowDragHost` overlays, `sidebarDragChrome`, and row frames' hit-testing intact (drag-and-drop and sticky headers must keep working).
- herdr requests are NDJSON `{"id","method","params"}`; `params` must be present even when empty. Methods used: `pane.layout {pane_id}`, `pane.focus {pane_id}`, `tab.focus {tab_id}`, `tab.close {tab_id}`, `tab.create`, `tab.rename`, `layout.set_split_ratio {tab_id|pane_id, path:[Bool], ratio}`, `pane.zoom {pane_id, mode}`.
- No new third-party dependencies. Remote devices show no git branch.
- Do not commit unless the user has said commits are OK in this session; the commit steps below run only then (otherwise leave changes staged-free and report).
- Out of scope: the bottom usage strip; retiring `SplitContainer`; remote branches.

## Review Focus

- Branch resolution in a **worktree** (`.git` is a file with `gitdir:`), **detached HEAD** (short SHA, not blank), and a directory **outside any repo** (no branch line, no crash).
- A split layout where herdr's rounded cell rects disagree with `ratio` by 1 cell: tree building must still partition panes correctly (center-point test, nested split matched by containment).
- A tab with **one pane** or a **zoomed** tab renders exactly like today (full area, no dividers).
- A pane that **closes** while its tab is selected, or a layout that arrives for a tab the user already left: no stale frames, no crash, no orphaned attach.
- `tab.close` on the **last tab** of a space and `+` while disconnected: errors surface via `model.actionError`, the bar never shows a tab that doesn't exist.

## File Structure

| File | Responsibility |
|---|---|
| `Packages/HerdrKit/Sources/HerdrKit/GitBranchResolver.swift` (new) | `.git/HEAD` parsing, worktree `.git` files, `GitStatus`, `GitStatusProvider` actor (ahead count, TTL cache) |
| `Packages/HerdrKit/Sources/HerdrKit/WorkspaceDirectory.swift` (new) | pick a workspace's representative cwd |
| `Packages/HerdrKit/Sources/HerdrKit/TabSelection.swift` (new) | which pane to select when a tab is clicked |
| `Packages/HerdrKit/Sources/HerdrKit/PaneLayout.swift` (new) | `pane.layout` models, `SplitTree`, frames, dividers |
| `Packages/HerdrKit/Sources/HerdrKit/HerdrService.swift` (modify) | `focusTab`, `closeTab`, `focusPane`, `paneLayout`, `setSplitRatio`, `zoomPane` |
| `Sources/HerdrM/StatusRing.swift` (new) | ring/dot status glyph used by space, agent, tab rows |
| `Sources/HerdrM/SidebarView.swift` (modify) | space/agent rows, section strip |
| `Sources/HerdrM/SpaceTabBar.swift` (new) | tab bar view |
| `Sources/HerdrM/AppModel.swift` (modify) | git statuses, tab selection, layouts, per-pane attach |
| `Sources/HerdrM/ContentView.swift` (modify) | tab bar mount, split placement + dividers |
| `Sources/HerdrM/TerminalView.swift` (modify) | `onFocused` callback from the terminal view |

Tests: `Packages/HerdrKit/Tests/HerdrKitTests/{GitBranchTests,WorkspaceDirectoryTests,TabSelectionTests,PaneLayoutTests}.swift`.

---

# Stage 1 — Sidebar

### Task 1: Git branch resolver (pure HEAD parsing)

**Files:**
- Create: `Packages/HerdrKit/Sources/HerdrKit/GitBranchResolver.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/GitBranchTests.swift`

**Interfaces:**
- Produces: `public struct GitStatus: Sendable, Equatable { public let branch: String; public let ahead: Int; public init(branch: String, ahead: Int) }`, `public enum GitBranchResolver { public static func parseHead(_ text: String) -> String?; public static func branch(forDirectory directory: String) -> String? }`

- [ ] **Step 1: Write the failing tests**

```swift
#if os(macOS)
import XCTest
@testable import HerdrKit

final class GitBranchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-branch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testParsesBranchRef() {
        XCTAssertEqual(GitBranchResolver.parseHead("ref: refs/heads/feature/pekanbaru-site\n"), "feature/pekanbaru-site")
        XCTAssertEqual(GitBranchResolver.parseHead("ref: refs/heads/main"), "main")
    }

    func testDetachedHeadShowsShortSHA() {
        XCTAssertEqual(
            GitBranchResolver.parseHead("0123456789abcdef0123456789abcdef01234567\n"), "0123456"
        )
    }

    func testGarbageHeadIsNil() {
        XCTAssertNil(GitBranchResolver.parseHead(""))
        XCTAssertNil(GitBranchResolver.parseHead("not a head"))
    }

    func testWalksUpFromNestedDirectory() throws {
        try write("ref: refs/heads/main\n", to: "repo/.git/HEAD")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("repo/apps/api"), withIntermediateDirectories: true
        )
        XCTAssertEqual(
            GitBranchResolver.branch(forDirectory: root.appendingPathComponent("repo/apps/api").path),
            "main"
        )
    }

    func testWorktreeGitFileIsFollowed() throws {
        try write("ref: refs/heads/spec/ai\n", to: "main/.git/worktrees/wt/HEAD")
        try write("gitdir: \(root.path)/main/.git/worktrees/wt\n", to: "wt/.git")
        XCTAssertEqual(GitBranchResolver.branch(forDirectory: root.appendingPathComponent("wt").path), "spec/ai")
    }

    func testRelativeGitdirInWorktreeFile() throws {
        try write("ref: refs/heads/rel\n", to: "gitdirs/wt/HEAD")
        try write("gitdir: ../gitdirs/wt\n", to: "checkout/.git")
        XCTAssertEqual(GitBranchResolver.branch(forDirectory: root.appendingPathComponent("checkout").path), "rel")
    }

    func testDirectoryOutsideAnyRepoIsNil() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plain"), withIntermediateDirectories: true
        )
        XCTAssertNil(GitBranchResolver.branch(forDirectory: root.appendingPathComponent("plain").path))
    }

    func testMissingDirectoryIsNil() {
        XCTAssertNil(GitBranchResolver.branch(forDirectory: root.appendingPathComponent("nope").path))
    }
}
#endif
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/HerdrKit && swift test --filter GitBranchTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'GitBranchResolver' in scope`.

- [ ] **Step 3: Implement**

```swift
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
#endif
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/HerdrKit && swift test --filter GitBranchTests 2>&1 | tail -6`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Packages/HerdrKit/Sources/HerdrKit/GitBranchResolver.swift Packages/HerdrKit/Tests/HerdrKitTests/GitBranchTests.swift
git commit -m "feat(kit): resolve git branch from HEAD, incl. worktrees"
```

### Task 2: `GitStatusProvider` (ahead count + TTL cache)

**Files:**
- Modify: `Packages/HerdrKit/Sources/HerdrKit/GitBranchResolver.swift` (append)
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/GitBranchTests.swift` (append a second class in the same file)

**Interfaces:**
- Consumes: `GitBranchResolver.branch(forDirectory:)`, `GitStatus`
- Produces: `public actor GitStatusProvider { public init(ttl: TimeInterval = 5); public func status(forDirectory: String) async -> GitStatus? }`, `static func aheadCount(inDirectory:) async -> Int?` (internal, tested via `@testable`)

- [ ] **Step 1: Write the failing tests** (append to `GitBranchTests.swift`)

```swift
#if os(macOS)
final class GitStatusProviderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-status-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"] + args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args) failed")
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testNoUpstreamMeansZeroAhead() async throws {
        let repo = root.appendingPathComponent("solo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init"], in: repo)
        try git(["commit", "--allow-empty", "-m", "one"], in: repo)
        let status = await GitStatusProvider().status(forDirectory: repo.path)
        XCTAssertEqual(status, GitStatus(branch: "main", ahead: 0))
    }

    func testCountsCommitsAheadOfUpstream() async throws {
        let remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(["init", "--bare"], in: remote)
        let repo = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init"], in: repo)
        try git(["remote", "add", "origin", remote.path], in: repo)
        try git(["commit", "--allow-empty", "-m", "base"], in: repo)
        try git(["push", "-u", "origin", "main"], in: repo)
        try git(["commit", "--allow-empty", "-m", "a"], in: repo)
        try git(["commit", "--allow-empty", "-m", "b"], in: repo)
        let status = await GitStatusProvider().status(forDirectory: repo.path)
        XCTAssertEqual(status, GitStatus(branch: "main", ahead: 2))
    }

    func testNonRepoIsNil() async {
        let status = await GitStatusProvider().status(forDirectory: root.path)
        XCTAssertNil(status)
    }
}
#endif
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/HerdrKit && swift test --filter GitStatusProviderTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'GitStatusProvider' in scope`.

- [ ] **Step 3: Implement** (append inside the `#if os(macOS)` block of `GitBranchResolver.swift`)

```swift
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/HerdrKit && swift test --filter "GitBranchTests|GitStatusProviderTests" 2>&1 | tail -6`
Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Packages/HerdrKit
git commit -m "feat(kit): GitStatusProvider with ahead count and TTL cache"
```

### Task 3: Workspace directory + AppModel git statuses

**Files:**
- Create: `Packages/HerdrKit/Sources/HerdrKit/WorkspaceDirectory.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/WorkspaceDirectoryTests.swift`
- Modify: `Sources/HerdrM/AppModel.swift` (new state near `@Published var attachSessions` ~line 152; hook in snapshot-apply block ~line 1096, right after `sessions[deviceID]?.panes = snapshot.ordinaryTerminalPanes`)

**Interfaces:**
- Produces: `WorkspaceDirectory.resolve(workspaceID: String, candidates: [(workspaceID: String, cwd: String?)]) -> String?`; on `AppModel`: `@Published private(set) var gitStatuses: [String: GitStatus]` keyed by `SpaceEntry.id`, `func gitStatus(for entry: SpaceEntry) -> GitStatus?`, `func refreshGitStatuses(deviceID: UUID)`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import HerdrKit

final class WorkspaceDirectoryTests: XCTestCase {
    func testFirstNonEmptyCwdForWorkspaceWins() {
        let dir = WorkspaceDirectory.resolve(
            workspaceID: "w2",
            candidates: [("w1", "/a"), ("w2", nil), ("w2", ""), ("w2", "/b"), ("w2", "/c")]
        )
        XCTAssertEqual(dir, "/b")
    }

    func testNilWhenWorkspaceHasNoCwd() {
        XCTAssertNil(WorkspaceDirectory.resolve(workspaceID: "w9", candidates: [("w1", "/a")]))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/HerdrKit && swift test --filter WorkspaceDirectoryTests 2>&1 | tail -8`
Expected: FAIL — `cannot find 'WorkspaceDirectory' in scope`.

- [ ] **Step 3: Implement kit side**

```swift
import Foundation

/// A workspace has no cwd of its own; its panes do. The first pane with one
/// (agents listed before ordinary terminals by the caller) represents it.
public enum WorkspaceDirectory {
    public static func resolve(
        workspaceID: String,
        candidates: [(workspaceID: String, cwd: String?)]
    ) -> String? {
        candidates.first { $0.workspaceID == workspaceID && !($0.cwd ?? "").isEmpty }?.cwd
    }
}
```

- [ ] **Step 4: Run to verify pass** — same command; expected `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Wire AppModel**

Add next to `attachSessions` in `AppModel.swift`:

```swift
    /// Branch/ahead per space, local devices only (remote shows none). Keyed by `SpaceEntry.id`.
    @Published private(set) var gitStatuses: [String: GitStatus] = [:]
    private let gitStatusProvider = GitStatusProvider()

    func gitStatus(for entry: SpaceEntry) -> GitStatus? { gitStatuses[entry.id] }

    func refreshGitStatuses(deviceID: UUID) {
        guard let device = device(deviceID), device.isLocal else { return }
        let state = session(deviceID)
        let candidates: [(workspaceID: String, cwd: String?)] =
            state.agents.map { ($0.workspaceID, $0.cwd) } + state.panes.map { ($0.workspaceID, $0.cwd) }
        let spaces = state.workspaces
        Task {
            var updates: [String: GitStatus] = [:]
            var staleKeys: [String] = []
            for workspace in spaces {
                let key = SpaceEntry(device: device, workspace: workspace).id
                guard let directory = WorkspaceDirectory.resolve(
                    workspaceID: workspace.workspaceID, candidates: candidates
                ), let status = await gitStatusProvider.status(forDirectory: directory)
                else { staleKeys.append(key); continue }
                updates[key] = status
            }
            for key in staleKeys { gitStatuses[key] = nil }
            for (key, status) in updates where gitStatuses[key] != status { gitStatuses[key] = status }
        }
    }
```

Call `refreshGitStatuses(deviceID: deviceID)` immediately after `sessions[deviceID]?.panes = snapshot.ordinaryTerminalPanes`.

- [ ] **Step 6: Build** — Run: `make build 2>&1 | grep -E "error|BUILD"` — Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Packages/HerdrKit Sources/HerdrM/AppModel.swift
git commit -m "feat: per-space git status for local devices"
```

### Task 4: StatusRing + sidebar rows + section strip

**Files:**
- Create: `Sources/HerdrM/StatusRing.swift`
- Modify: `Sources/HerdrM/SidebarView.swift` (top action rows lines ~50-72; `SpaceRowView` ~859; `AgentRowView` ~397; add strip between Spaces and Agents sections ~line 106-108)

**Interfaces:**
- Produces: `StatusRing(status: AgentStatus, unreadDone: Bool = false, size: CGFloat = 11)`.

- [ ] **Step 1: Create `StatusRing.swift`**

```swift
import HerdrKit
import SwiftUI

/// herdr's status dot: an outline ring when idle, a spinner while working,
/// a filled amber disc when blocked, a green ring when done (filled blue
/// while the finish is still unread).
struct StatusRing: View {
    let status: AgentStatus
    var unreadDone: Bool = false
    var size: CGFloat = 11

    var body: some View {
        Group {
            switch status {
            case .working:
                SpinnerView(color: Theme.working)
            case .blocked:
                Circle().fill(Theme.warning)
            case .done where unreadDone:
                Circle().fill(Theme.working)
            case .done:
                Circle().strokeBorder(Theme.success, lineWidth: 1.4)
            case .idle, .unknown:
                Circle().strokeBorder(Theme.textGhost, lineWidth: 1.4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Replace the top action rows with a section strip**

In `SidebarView.body`, delete the `VStack(spacing: 1) { actionRow(...) × 5 }.padding(.horizontal, 10)` block and its following `Spacer().frame(height: 10)`; keep `actionRow` helper only if still used by `DevicePopover` (it has its own copy at ~734 — then delete the `SidebarView.actionRow` at ~193 if unused; the build will tell). Add below `groupHeader`:

```swift
    /// `new … menu` strip from the reference layout. Everything the old action
    /// rows offered stays reachable (also via the app menu shortcuts).
    private var sectionStrip: some View {
        HStack {
            Menu {
                Button("New Agent") { model.showNewAgent = true }
                Button("New Terminal") { model.showNewTerminal = true }
                Button("New Space") { model.showNewSpace = true }
            } label: {
                Text("new").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Menu {
                Button("Files") { model.openFileManager() }
                Button("Search") { model.showSearch = true }
            } label: {
                Text("menu").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
```

Insert `sectionStrip` inside the Spaces `StickySection` content, after `Spacer().frame(height: 10)` is replaced by `sectionStrip` followed by `Spacer().frame(height: 6)`.

- [ ] **Step 3: Restyle `SpaceRowView`** — replace its `body`'s `HStack` (keep every modifier from `.contentShape` down unchanged) with:

```swift
        let git = model.gitStatus(for: entry)
        HStack(alignment: .top, spacing: 8) {
            StatusRing(status: entry.workspace.status)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.workspace.label)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                if let git {
                    Text(git.branch)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if let git, git.ahead > 0 {
                Text("↑\(git.ahead)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            if model.showsRowDeviceBadges {
                DeviceChip(device: entry.device)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
```

and change the row background to add a selected outline:

```swift
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.sidebarBorder, lineWidth: 1) }
        }
```

(Replace the old `.frame(height: 30)`; the agent-count text and `SpaceAttentionGlyph` are dropped from the row — attention is carried by the ring, the count is in the Agents section.)

- [ ] **Step 4: Restyle `AgentRowView`** — replace the `VStack` body (from `VStack(alignment: .leading, spacing: 4) {` through the `ForEach(agent.statsLines…)` block) with a one-line row, and give the row a tooltip. Keep every modifier from `.padding(.horizontal, 8)` on, but change `.padding(.vertical, 7)`/`.frame(minHeight: 51)` to `.padding(.vertical, 5)`/`.frame(minHeight: 28)`:

```swift
        HStack(spacing: 7) {
            StatusRing(status: agent.status, unreadDone: unread)
            AgentKindBadge(kind: agent.agent, color: Theme.text)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if agent.status == .blocked {
                Text("needs input")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
            } else {
                Text("\(model.spaceName(deviceID: entry.device.id, workspaceID: agent.workspaceID)) · \(entry.title)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if model.showsRowDeviceBadges {
                DeviceChip(device: entry.device)
            }
        }
        .help(statsTooltip)
```

Add to `AgentRowView`:

```swift
    private var statsTooltip: String {
        ([entry.title] + entry.agent.statsLines.map(\.text)).joined(separator: "\n")
    }
```

Add a `priority` caption to the Agents header: in the Agents `groupHeader` trailing closure, put `Text("priority").font(.system(size: 11)).foregroundStyle(Theme.textGhost)` before `SidebarHeaderButton`.

- [ ] **Step 5: Build** — `make build 2>&1 | grep -E "error|BUILD"` → `** BUILD SUCCEEDED **` (fix any now-unused `actionRow` warning by deleting it).

- [ ] **Step 6: Manual check (user)** — launch (`make run`): ring + name + muted branch per space, `↑N` when ahead, strip with `new`/`menu`, single-line agents, drag a space and an agent to reorder, scroll to confirm sticky headers still pin, hover an agent for the stats tooltip.

- [ ] **Step 7: Commit**

```bash
git add Sources/HerdrM
git commit -m "feat(sidebar): reference layout — rings, branch line, single-line agents"
```

---

# Stage 2 — Space tab bar

### Task 5: Tab selection logic + service calls

**Files:**
- Create: `Packages/HerdrKit/Sources/HerdrKit/TabSelection.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/TabSelectionTests.swift`
- Modify: `Packages/HerdrKit/Sources/HerdrKit/HerdrService.swift` (add after `renameTab`, ~line 354)

**Interfaces:**
- Produces: `TabSelection.paneToSelect(tabID: String, agentPanes: [(paneID: String, tabID: String?)], terminalPanes: [(paneID: String, tabID: String?)]) -> String?` (agents first, then terminals, in given order); `TabSelection.activeTabID(selectedPaneTabID: String?, workspaceActiveTabID: String?, tabIDs: [String]) -> String?`; `HerdrService.focusTab(tabID:)`, `closeTab(tabID:)`, `focusPane(paneID:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import HerdrKit

final class TabSelectionTests: XCTestCase {
    func testAgentPaneWinsOverTerminalInSameTab() {
        let pane = TabSelection.paneToSelect(
            tabID: "t3",
            agentPanes: [("p1", "t1"), ("p5", "t3")],
            terminalPanes: [("p4", "t3")]
        )
        XCTAssertEqual(pane, "p5")
    }

    func testFallsBackToFirstTerminal() {
        let pane = TabSelection.paneToSelect(
            tabID: "t2", agentPanes: [("p1", "t1")], terminalPanes: [("p2", "t2"), ("p3", "t2")]
        )
        XCTAssertEqual(pane, "p2")
    }

    func testNilWhenTabHasNoPanes() {
        XCTAssertNil(TabSelection.paneToSelect(tabID: "t9", agentPanes: [], terminalPanes: []))
    }

    func testActiveTabPrefersSelectedPaneThenWorkspaceThenFirst() {
        XCTAssertEqual(TabSelection.activeTabID(selectedPaneTabID: "t2", workspaceActiveTabID: "t1", tabIDs: ["t1", "t2"]), "t2")
        XCTAssertEqual(TabSelection.activeTabID(selectedPaneTabID: nil, workspaceActiveTabID: "t1", tabIDs: ["t1", "t2"]), "t1")
        XCTAssertEqual(TabSelection.activeTabID(selectedPaneTabID: "gone", workspaceActiveTabID: nil, tabIDs: ["t1", "t2"]), "t1")
        XCTAssertNil(TabSelection.activeTabID(selectedPaneTabID: nil, workspaceActiveTabID: nil, tabIDs: []))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cd Packages/HerdrKit && swift test --filter TabSelectionTests 2>&1 | tail -8` → FAIL `cannot find 'TabSelection'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Which pane a clicked tab should select, and which tab is "active" for a
/// space, resolved from the selection and herdr's own workspace state.
public enum TabSelection {
    public static func paneToSelect(
        tabID: String,
        agentPanes: [(paneID: String, tabID: String?)],
        terminalPanes: [(paneID: String, tabID: String?)]
    ) -> String? {
        agentPanes.first { $0.tabID == tabID }?.paneID
            ?? terminalPanes.first { $0.tabID == tabID }?.paneID
    }

    public static func activeTabID(
        selectedPaneTabID: String?,
        workspaceActiveTabID: String?,
        tabIDs: [String]
    ) -> String? {
        if let selectedPaneTabID, tabIDs.contains(selectedPaneTabID) { return selectedPaneTabID }
        if let workspaceActiveTabID, tabIDs.contains(workspaceActiveTabID) { return workspaceActiveTabID }
        return tabIDs.first
    }
}
```

Add to `HerdrService.swift` after `renameTab`:

```swift
    public func focusTab(tabID: String) async throws {
        _ = try await client().request(method: "tab.focus", params: .object(["tab_id": .string(tabID)]))
    }

    public func closeTab(tabID: String) async throws {
        _ = try await client().request(method: "tab.close", params: .object(["tab_id": .string(tabID)]))
    }

    public func focusPane(paneID: String) async throws {
        _ = try await client().request(method: "pane.focus", params: .object(["pane_id": .string(paneID)]))
    }
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter TabSelectionTests` → `Executed 4 tests, with 0 failures`; then `swift build` in the package → success.

- [ ] **Step 5: Commit**

```bash
git add Packages/HerdrKit
git commit -m "feat(kit): tab selection helpers and focus/close RPCs"
```

### Task 6: `AppModel` tab API + `SpaceTabBar`

**Files:**
- Modify: `Sources/HerdrM/AppModel.swift` (after `selectAgent`, ~line 617)
- Create: `Sources/HerdrM/SpaceTabBar.swift`
- Modify: `Sources/HerdrM/ContentView.swift` (mount above the terminal area)

**Interfaces:**
- Consumes: `TabSelection`, `HerdrService.focusTab/closeTab/createTab/renameTab`, `StatusRing`
- Produces: `AppModel.tabs(in: SpaceRef) -> [TabInfo]`, `AppModel.activeTabID(in: SpaceRef) -> String?`, `AppModel.selectTab(_ tab: TabInfo, deviceID: UUID)`, `AppModel.newTab(in: SpaceRef)`, `AppModel.requestCloseTab(_:deviceID:)`

- [ ] **Step 1: Add model API**

```swift
    // MARK: - Tabs

    func tabs(in space: SpaceRef) -> [TabInfo] {
        session(space.deviceID).tabs.filter { $0.workspaceID == space.workspaceID }
    }

    /// The space whose tab bar is shown: the explicit selection, else the
    /// selected pane's space.
    var tabBarSpace: SpaceRef? {
        if let selectedSpace { return selectedSpace }
        guard let pane = selectedPane else { return nil }
        let state = session(pane.deviceID)
        let workspaceID = state.agents.first { $0.paneID == pane.paneID }?.workspaceID
            ?? state.panes.first { $0.paneID == pane.paneID }?.workspaceID
        return workspaceID.map { SpaceRef(deviceID: pane.deviceID, workspaceID: $0) }
    }

    func activeTabID(in space: SpaceRef) -> String? {
        let state = session(space.deviceID)
        let selectedTab: String? = selectedPane.flatMap { pane in
            guard pane.deviceID == space.deviceID else { return nil }
            return state.agents.first { $0.paneID == pane.paneID }?.tabID
                ?? state.panes.first { $0.paneID == pane.paneID }?.tabID
        }
        return TabSelection.activeTabID(
            selectedPaneTabID: selectedTab,
            workspaceActiveTabID: state.workspaces.first { $0.workspaceID == space.workspaceID }?.activeTabID,
            tabIDs: tabs(in: space).map(\.tabID)
        )
    }

    func selectTab(_ tab: TabInfo, deviceID: UUID) {
        let state = session(deviceID)
        if let paneID = TabSelection.paneToSelect(
            tabID: tab.tabID,
            agentPanes: state.agents.map { ($0.paneID, $0.tabID) },
            terminalPanes: state.panes.map { ($0.paneID, $0.tabID) }
        ) {
            selectAgent(PaneRef(deviceID: deviceID, paneID: paneID))
        }
        guard let device = device(deviceID) else { return }
        let service = service(for: device)
        Task {
            do { try await service.focusTab(tabID: tab.tabID) } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func newTab(in space: SpaceRef) {
        guard let device = device(space.deviceID) else { return }
        let service = service(for: device)
        Task {
            do {
                let paneID = try await service.createTab(workspaceID: space.workspaceID, cwd: nil, label: nil)
                _ = await refreshImmediately(space.deviceID)
                selectAgent(PaneRef(deviceID: space.deviceID, paneID: paneID))
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func closeTab(_ tab: TabInfo, deviceID: UUID) {
        guard let device = device(deviceID) else { return }
        let service = service(for: device)
        Task {
            do {
                try await service.closeTab(tabID: tab.tabID)
                _ = await refreshImmediately(deviceID)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
```

If `selectAgent` is wrong for terminal panes, it is still correct: it only sets `selectedPane` (agents and terminals share `PaneRef`), as `selectAgent` does today. If `refreshImmediately` is `private`, it is in the same class — fine. If `actionError` is not `@MainActor`-safe from `Task`, mark the closures `@MainActor` (`Task { @MainActor in … }`), matching surrounding code.

- [ ] **Step 2: Create `SpaceTabBar.swift`**

```swift
import HerdrKit
import SwiftUI

/// Tabs of the selected space, mirroring herdr's TUI tab strip.
struct SpaceTabBar: View {
    @ObservedObject var model: AppModel
    let space: SpaceRef
    @State private var renaming: TabInfo?
    @State private var renameText = ""

    var body: some View {
        let tabs = model.tabs(in: space)
        let active = model.activeTabID(in: space)
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabCell(tab, selected: tab.tabID == active, canClose: tabs.count > 1)
            }
            Button {
                model.newTab(in: space)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab")
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .background(Theme.statusBarBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .alert("Rename Tab", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func tabCell(_ tab: TabInfo, selected: Bool, canClose: Bool) -> some View {
        HStack(spacing: 6) {
            StatusRing(status: AgentStatus(wire: tab.agentStatusRaw), size: 9)
            Text(tab.customLabel ?? tab.label)
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
            if canClose {
                Button {
                    model.closeTab(tab, deviceID: space.deviceID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(selected ? Theme.terminalBackground : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            renameText = tab.customLabel ?? tab.label
            renaming = tab
        }
        .onTapGesture { model.selectTab(tab, deviceID: space.deviceID) }
    }

    private func commitRename() {
        guard let tab = renaming else { return }
        let label = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !label.isEmpty, let device = model.device(space.deviceID) else { return }
        let service = model.service(for: device)
        Task {
            do { try await service.renameTab(tabID: tab.tabID, label: label) } catch {
                model.actionError = error.localizedDescription
            }
        }
    }
}
```

Closing the last tab is hidden (`canClose`) so a space is never emptied from the bar (Review Focus). If `model.device(_:)`/`model.service(for:)` are `private`, relax them to internal.

- [ ] **Step 3: Mount it** — in `ContentView.swift`, wrap the content that contains `attachedTerminal` so the bar sits on top. Locate where `attachedTerminal` is placed in the main column (grep `attachedTerminal`) and change to:

```swift
VStack(spacing: 0) {
    if let space = model.tabBarSpace, model.selectedShellID == nil, !model.isFileManagerActive,
       !model.tabs(in: space).isEmpty {
        SpaceTabBar(model: model, space: space)
    }
    attachedTerminal
}
```

- [ ] **Step 4: Build** — `make build 2>&1 | grep -E "error|BUILD"` → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual check (user)** — select a space with 3 tabs (e.g. arte-hotel): bar shows claude/nvim/console; clicking switches the pane; `+` adds a tab; × closes one; double-click renames; standalone shells and the file manager hide the bar.

- [ ] **Step 6: Commit**

```bash
git add Sources/HerdrM
git commit -m "feat: space tab bar driven by herdr tabs"
```

---

# Stage 3 — Herdr-driven splits

### Task 7: `PaneLayout`, `SplitTree`, frames, dividers (pure)

**Files:**
- Create: `Packages/HerdrKit/Sources/HerdrKit/PaneLayout.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/PaneLayoutTests.swift`

**Interfaces:**
- Produces:
  - `public struct LayoutRect: Codable, Sendable, Equatable { x, y, width, height: Int }`
  - `public enum LayoutDirection: String, Codable, Sendable { case right, down }`
  - `public struct PaneLayout: Codable, Sendable, Equatable` with `tabID: String, workspaceID: String, zoomed: Bool, area: LayoutRect, focusedPaneID: String, panes: [Pane], splits: [Split]`; nested `Pane { paneID, focused, rect }`, `Split { id, direction, ratio: Double, rect }`
  - `public struct UnitRect: Sendable, Equatable { x, y, width, height: Double }`
  - `public indirect enum SplitTree: Sendable, Equatable { case leaf(paneID: String); case split(id: String, direction: LayoutDirection, ratio: Double, first: SplitTree, second: SplitTree) }`
  - `SplitTree.build(from: PaneLayout) -> SplitTree?`, `.frames(in: UnitRect = .full) -> [String: UnitRect]`, `.dividers(in: UnitRect = .full) -> [SplitDivider]`, `.paneIDs: [String]`
  - `public struct SplitDivider: Sendable, Equatable { id: String; path: [Bool]; direction: LayoutDirection; region: UnitRect }`

- [ ] **Step 1: Write the failing tests** (JSON copied from the live `herdr pane layout` output)

```swift
import XCTest
@testable import HerdrKit

final class PaneLayoutTests: XCTestCase {
    private let twoPane = """
    {"area":{"height":42,"width":139,"x":0,"y":0},"focused_pane_id":"w18:p5",
     "panes":[{"focused":true,"pane_id":"w18:p5","rect":{"height":42,"width":70,"x":0,"y":0}},
              {"focused":false,"pane_id":"w18:p6","rect":{"height":42,"width":69,"x":70,"y":0}}],
     "splits":[{"direction":"right","id":"split_0_root","ratio":0.5,"rect":{"height":42,"width":139,"x":0,"y":0}}],
     "tab_id":"w18:t3","workspace_id":"w18","zoomed":false}
    """

    private let threePane = """
    {"area":{"height":42,"width":139,"x":0,"y":0},"focused_pane_id":"w1E:p5",
     "panes":[{"focused":false,"pane_id":"w1E:p3","rect":{"height":21,"width":139,"x":0,"y":0}},
              {"focused":false,"pane_id":"w1E:p4","rect":{"height":21,"width":70,"x":0,"y":21}},
              {"focused":true,"pane_id":"w1E:p5","rect":{"height":21,"width":69,"x":70,"y":21}}],
     "splits":[{"direction":"down","id":"split_0_root","ratio":0.5,"rect":{"height":42,"width":139,"x":0,"y":0}},
               {"direction":"right","id":"split_1_1","ratio":0.5,"rect":{"height":21,"width":139,"x":0,"y":21}}],
     "tab_id":"w1E:t3","workspace_id":"w1E","zoomed":false}
    """

    private func decode(_ json: String) throws -> PaneLayout {
        try JSONDecoder().decode(PaneLayout.self, from: Data(json.utf8))
    }

    func testDecodesLiveLayout() throws {
        let layout = try decode(twoPane)
        XCTAssertEqual(layout.tabID, "w18:t3")
        XCTAssertEqual(layout.focusedPaneID, "w18:p5")
        XCTAssertEqual(layout.panes.count, 2)
        XCTAssertEqual(layout.splits.first?.direction, .right)
        XCTAssertFalse(layout.zoomed)
    }

    func testTwoPaneTree() throws {
        let tree = try XCTUnwrap(SplitTree.build(from: decode(twoPane)))
        XCTAssertEqual(
            tree,
            .split(id: "split_0_root", direction: .right, ratio: 0.5,
                   first: .leaf(paneID: "w18:p5"), second: .leaf(paneID: "w18:p6"))
        )
    }

    func testThreePaneTreeNestsSecondSplitUnderSecondChild() throws {
        let tree = try XCTUnwrap(SplitTree.build(from: decode(threePane)))
        XCTAssertEqual(
            tree,
            .split(id: "split_0_root", direction: .down, ratio: 0.5,
                   first: .leaf(paneID: "w1E:p3"),
                   second: .split(id: "split_1_1", direction: .right, ratio: 0.5,
                                  first: .leaf(paneID: "w1E:p4"), second: .leaf(paneID: "w1E:p5")))
        )
    }

    func testSinglePaneIsALeaf() throws {
        let json = """
        {"area":{"height":42,"width":139,"x":0,"y":0},"focused_pane_id":"a",
         "panes":[{"focused":true,"pane_id":"a","rect":{"height":42,"width":139,"x":0,"y":0}}],
         "splits":[],"tab_id":"t","workspace_id":"w","zoomed":false}
        """
        XCTAssertEqual(SplitTree.build(from: try decode(json)), .leaf(paneID: "a"))
    }

    func testRoundedRectsDoNotBreakPartitioning() throws {
        // ratio .5 of width 139 is 69.5; herdr gave the left pane 69 and the right 70.
        let json = """
        {"area":{"height":10,"width":139,"x":0,"y":0},"focused_pane_id":"a",
         "panes":[{"focused":true,"pane_id":"a","rect":{"height":10,"width":69,"x":0,"y":0}},
                  {"focused":false,"pane_id":"b","rect":{"height":10,"width":70,"x":69,"y":0}}],
         "splits":[{"direction":"right","id":"split_0_root","ratio":0.5,"rect":{"height":10,"width":139,"x":0,"y":0}}],
         "tab_id":"t","workspace_id":"w","zoomed":false}
        """
        let tree = try XCTUnwrap(SplitTree.build(from: decode(json)))
        XCTAssertEqual(tree.paneIDs, ["a", "b"])
    }

    func testFramesFollowRatios() throws {
        let tree = try XCTUnwrap(SplitTree.build(from: decode(threePane)))
        let frames = tree.frames()
        XCTAssertEqual(frames["w1E:p3"], UnitRect(x: 0, y: 0, width: 1, height: 0.5))
        XCTAssertEqual(frames["w1E:p4"], UnitRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(frames["w1E:p5"], UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    func testDividersCarryPathAndRegion() throws {
        let tree = try XCTUnwrap(SplitTree.build(from: decode(threePane)))
        let dividers = tree.dividers()
        XCTAssertEqual(dividers.map(\.id), ["split_0_root", "split_1_1"])
        XCTAssertEqual(dividers[0].path, [])
        XCTAssertEqual(dividers[1].path, [true])
        XCTAssertEqual(dividers[1].region, UnitRect(x: 0, y: 0.5, width: 1, height: 0.5))
    }

    func testUnmatchedPanesYieldNilNotACrash() throws {
        let json = """
        {"area":{"height":10,"width":10,"x":0,"y":0},"focused_pane_id":"a",
         "panes":[{"focused":true,"pane_id":"a","rect":{"height":10,"width":5,"x":0,"y":0}},
                  {"focused":false,"pane_id":"b","rect":{"height":10,"width":5,"x":5,"y":0}}],
         "splits":[],"tab_id":"t","workspace_id":"w","zoomed":false}
        """
        XCTAssertNil(SplitTree.build(from: try decode(json)))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cd Packages/HerdrKit && swift test --filter PaneLayoutTests 2>&1 | tail -8` → FAIL `cannot find 'PaneLayout'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

public struct LayoutRect: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
}

public enum LayoutDirection: String, Codable, Sendable {
    /// Children side by side (vertical divider).
    case right
    /// Children stacked (horizontal divider).
    case down
}

/// `pane.layout` result: cell rects for every pane of a tab plus its splits.
public struct PaneLayout: Codable, Sendable, Equatable {
    public struct Pane: Codable, Sendable, Equatable {
        public let paneID: String
        public let focused: Bool
        public let rect: LayoutRect
        enum CodingKeys: String, CodingKey { case paneID = "pane_id", focused, rect }
    }

    public struct Split: Codable, Sendable, Equatable {
        public let id: String
        public let direction: LayoutDirection
        public let ratio: Double
        public let rect: LayoutRect
    }

    public let tabID: String
    public let workspaceID: String
    public let zoomed: Bool
    public let area: LayoutRect
    public let focusedPaneID: String
    public let panes: [Pane]
    public let splits: [Split]

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id", workspaceID = "workspace_id", zoomed, area
        case focusedPaneID = "focused_pane_id", panes, splits
    }
}

public struct UnitRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)
}

public struct SplitDivider: Sendable, Equatable {
    public let id: String
    /// Child choices from the root: `false` = first child, `true` = second.
    public let path: [Bool]
    public let direction: LayoutDirection
    /// The area the split occupies; the divider sits at `ratio` along it.
    public let region: UnitRect
    public let ratio: Double
}

public indirect enum SplitTree: Sendable, Equatable {
    case leaf(paneID: String)
    case split(id: String, direction: LayoutDirection, ratio: Double, first: SplitTree, second: SplitTree)

    public var paneIDs: [String] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, _, let first, let second): return first.paneIDs + second.paneIDs
        }
    }

    // MARK: Build

    /// Rebuilds the binary tree from herdr's flat split list. A group of panes
    /// is claimed by the smallest unused split whose rect contains them all;
    /// that split's direction + ratio then partitions the group by pane center,
    /// which tolerates herdr rounding cell rects by a column or row.
    /// Returns nil when the data cannot be reconciled (caller falls back to
    /// the single selected pane).
    public static func build(from layout: PaneLayout) -> SplitTree? {
        var unused = layout.splits
        return build(group: layout.panes, unused: &unused)
    }

    private static func build(group: [PaneLayout.Pane], unused: inout [PaneLayout.Split]) -> SplitTree? {
        if group.count == 1 { return .leaf(paneID: group[0].paneID) }
        guard group.count > 1 else { return nil }
        let bounds = union(group.map(\.rect))
        let candidates = unused.enumerated()
            .filter { contains($0.element.rect, bounds) }
            .sorted { area($0.element.rect) < area($1.element.rect) }
        guard let (index, split) = candidates.first.map({ ($0.offset, $0.element) }) else { return nil }
        unused.remove(at: index)

        let cut: Double = split.direction == .right
            ? Double(split.rect.x) + Double(split.rect.width) * split.ratio
            : Double(split.rect.y) + Double(split.rect.height) * split.ratio
        var first: [PaneLayout.Pane] = []
        var second: [PaneLayout.Pane] = []
        for pane in group {
            let center: Double = split.direction == .right
                ? Double(pane.rect.x) + Double(pane.rect.width) / 2
                : Double(pane.rect.y) + Double(pane.rect.height) / 2
            if center < cut { first.append(pane) } else { second.append(pane) }
        }
        guard !first.isEmpty, !second.isEmpty,
              let a = build(group: first, unused: &unused),
              let b = build(group: second, unused: &unused)
        else { return nil }
        return .split(id: split.id, direction: split.direction, ratio: split.ratio, first: a, second: b)
    }

    private static func union(_ rects: [LayoutRect]) -> LayoutRect {
        let minX = rects.map(\.x).min() ?? 0
        let minY = rects.map(\.y).min() ?? 0
        let maxX = rects.map { $0.x + $0.width }.max() ?? 0
        let maxY = rects.map { $0.y + $0.height }.max() ?? 0
        return LayoutRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func contains(_ outer: LayoutRect, _ inner: LayoutRect) -> Bool {
        outer.x <= inner.x && outer.y <= inner.y
            && outer.x + outer.width >= inner.x + inner.width
            && outer.y + outer.height >= inner.y + inner.height
    }

    private static func area(_ rect: LayoutRect) -> Int { rect.width * rect.height }

    // MARK: Geometry

    public func frames(in rect: UnitRect = .full) -> [String: UnitRect] {
        switch self {
        case .leaf(let id):
            return [id: rect]
        case .split(_, let direction, let ratio, let first, let second):
            let (a, b) = Self.children(of: rect, direction: direction, ratio: ratio)
            return first.frames(in: a).merging(second.frames(in: b)) { lhs, _ in lhs }
        }
    }

    public func dividers(in rect: UnitRect = .full, path: [Bool] = []) -> [SplitDivider] {
        guard case .split(let id, let direction, let ratio, let first, let second) = self else { return [] }
        let (a, b) = Self.children(of: rect, direction: direction, ratio: ratio)
        return [SplitDivider(id: id, path: path, direction: direction, region: rect, ratio: ratio)]
            + first.dividers(in: a, path: path + [false])
            + second.dividers(in: b, path: path + [true])
    }

    private static func children(of rect: UnitRect, direction: LayoutDirection, ratio: Double) -> (UnitRect, UnitRect) {
        switch direction {
        case .right:
            let w = rect.width * ratio
            return (
                UnitRect(x: rect.x, y: rect.y, width: w, height: rect.height),
                UnitRect(x: rect.x + w, y: rect.y, width: rect.width - w, height: rect.height)
            )
        case .down:
            let h = rect.height * ratio
            return (
                UnitRect(x: rect.x, y: rect.y, width: rect.width, height: h),
                UnitRect(x: rect.x, y: rect.y + h, width: rect.width, height: rect.height - h)
            )
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter PaneLayoutTests 2>&1 | tail -6` → `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Packages/HerdrKit
git commit -m "feat(kit): decode pane.layout and rebuild the split tree"
```

### Task 8: Layout RPCs + live verification on a scratch tab

**Files:**
- Modify: `Packages/HerdrKit/Sources/HerdrKit/HerdrService.swift`

**Interfaces:**
- Consumes: `PaneLayout`
- Produces: `HerdrService.paneLayout(paneID:) async throws -> PaneLayout`, `setSplitRatio(tabID:path:ratio:) async throws`, `zoomPane(paneID:mode:) async throws` (`mode`: `"toggle" | "on" | "off"`)

- [ ] **Step 1: Add the methods** (after `focusPane`)

```swift
    public func paneLayout(paneID: String) async throws -> PaneLayout {
        struct Envelope: Codable { let layout: PaneLayout }
        return try await client().request(
            method: "pane.layout",
            params: .object(["pane_id": .string(paneID)]),
            as: Envelope.self
        ).layout
    }

    /// Absolute ratio for the split at `path` (false = first child, true =
    /// second, from the root). Clamped by herdr.
    public func setSplitRatio(tabID: String, path: [Bool], ratio: Double) async throws {
        _ = try await client().request(
            method: "layout.set_split_ratio",
            params: .object([
                "tab_id": .string(tabID),
                "path": .array(path.map { .bool($0) }),
                "ratio": .number(ratio),
            ])
        )
    }

    public func zoomPane(paneID: String, mode: String = "toggle") async throws {
        _ = try await client().request(
            method: "pane.zoom",
            params: .object(["pane_id": .string(paneID), "mode": .string(mode)])
        )
    }
```

- [ ] **Step 2: Build kit** — `cd Packages/HerdrKit && swift build 2>&1 | tail -5` → success.

- [ ] **Step 3: Verify `path` semantics on a scratch tab (do NOT use a real tab)**

```bash
W=$(herdr workspace list | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['workspaces'][0]['workspace_id'])")
TAB=$(herdr tab create --workspace $W --no-focus | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['tab']['tab_id'])")
P=$(herdr pane list | python3 -c "import sys,json;print([p['pane_id'] for p in json.load(sys.stdin)['result']['panes'] if p['tab_id']=='$TAB'][0])")
herdr pane split --pane $P --direction right >/dev/null
herdr pane split --pane $P --direction down >/dev/null      # nests under the first child
herdr pane layout --pane $P | python3 -m json.tool | head -60
echo '{"id":"x","method":"layout.set_split_ratio","params":{"tab_id":"'$TAB'","path":[],"ratio":0.3}}' | nc -U ~/.config/herdr/herdr.sock
herdr pane layout --pane $P | python3 -c "import sys,json;print([(s['id'],s['ratio']) for s in json.load(sys.stdin)['result']['layout']['splits']])"
echo '{"id":"y","method":"layout.set_split_ratio","params":{"tab_id":"'$TAB'","path":[false],"ratio":0.7}}' | nc -U ~/.config/herdr/herdr.sock
herdr pane layout --pane $P | python3 -c "import sys,json;print([(s['id'],s['ratio']) for s in json.load(sys.stdin)['result']['layout']['splits']])"
herdr tab close $TAB
```

Expected: `path: []` changes the root split's ratio to 0.3; `path: [false]` changes the *first child's* nested split (the one that contains the original pane) to 0.7. If either differs (e.g. `true` means first), flip the mapping in `SplitTree.dividers` (`path + [false]` ↔ `[true]`), update `testDividersCarryPathAndRegion`, rerun. Flags such as `--workspace`/`--no-focus` may differ in this herdr build — use `herdr tab create --help` and adjust; always close the scratch tab.

- [ ] **Step 4: Commit**

```bash
git add Packages/HerdrKit
git commit -m "feat(kit): pane layout, split ratio and zoom RPCs"
```

### Task 9: Layout state + per-pane attach in `AppModel`

**Files:**
- Modify: `Sources/HerdrM/AppModel.swift`

**Interfaces:**
- Consumes: `HerdrService.paneLayout/focusPane/setSplitRatio`, `SplitTree`, `TabSelection`
- Produces: `AppModel.activeLayout: ActiveLayout?` where `struct ActiveLayout { let tabID: String; let deviceID: UUID; let tree: SplitTree; let zoomed: Bool; let focusedPaneID: String }`; `func commitSplitRatio(divider: SplitDivider, ratio: Double)`; `func focusLayoutPane(_ paneID: String)`

- [ ] **Step 1: Add state + refresh**

```swift
    struct ActiveLayout: Equatable {
        let tabID: String
        let deviceID: UUID
        let tree: SplitTree
        let zoomed: Bool
        let focusedPaneID: String
    }

    /// Layout of the tab the selected pane lives in, nil for single-pane tabs
    /// or when herdr's data cannot be reconciled (the view then shows the
    /// selected pane alone, exactly as before).
    @Published private(set) var activeLayout: ActiveLayout?

    /// Fetches `pane.layout` for the selected pane's tab and makes sure every
    /// pane in it has a kept-alive attach, so the split can show them all.
    func refreshActiveLayout() async {
        guard let selected = selectedPane, let device = device(selected.deviceID) else {
            activeLayout = nil
            return
        }
        let service = service(for: device)
        do {
            let layout = try await service.paneLayout(paneID: selected.paneID)
            guard selectedPane == selected else { return }   // user moved on mid-flight
            guard layout.panes.count > 1, let tree = SplitTree.build(from: layout) else {
                activeLayout = nil
                return
            }
            for paneID in tree.paneIDs { ensureAttached(PaneRef(deviceID: device.id, paneID: paneID)) }
            let next = ActiveLayout(
                tabID: layout.tabID, deviceID: device.id, tree: tree,
                zoomed: layout.zoomed, focusedPaneID: layout.focusedPaneID
            )
            if activeLayout != next { activeLayout = next }
        } catch {
            activeLayout = nil
        }
    }

    private func ensureAttached(_ ref: PaneRef) {
        guard let device = device(ref.deviceID) else { return }
        let state = session(ref.deviceID)
        let entry: AttachedEntry?
        if let agent = state.agents.first(where: { $0.paneID == ref.paneID }) {
            entry = .agent(agentEntry(device: device, agent: agent))
        } else {
            entry = terminalEntries(for: device).first { $0.pane.paneID == ref.paneID }.map { .terminal($0) }
        }
        if let entry, !attachSessions.contains(where: { $0.id == entry.id }) {
            attachSessions.append(entry)
        }
    }

    /// A click inside a split pane: keyboard + herdr focus move there.
    func focusLayoutPane(_ paneID: String) {
        guard let layout = activeLayout, selectedPane?.paneID != paneID else { return }
        selectedPane = PaneRef(deviceID: layout.deviceID, paneID: paneID)
        guard let device = device(layout.deviceID) else { return }
        let service = service(for: device)
        Task { try? await service.focusPane(paneID: paneID) }
    }

    func commitSplitRatio(divider: SplitDivider, ratio: Double) {
        guard let layout = activeLayout, let device = device(layout.deviceID) else { return }
        let service = service(for: device)
        let clamped = min(max(ratio, 0.05), 0.95)
        Task {
            do { try await service.setSplitRatio(tabID: layout.tabID, path: divider.path, ratio: clamped) }
            catch { actionError = error.localizedDescription }
            await refreshActiveLayout()
        }
    }
```

- [ ] **Step 2: Trigger refreshes** — (a) at the end of the `selectedPane` `didSet` add `Task { await refreshActiveLayout() }`; (b) right after the `refreshGitStatuses(deviceID:)` call from Task 3 add `Task { await refreshActiveLayout() }` (every herdr event already triggers a refresh via `scheduleRefresh`/`refreshImmediately`, including `layout.updated`).

- [ ] **Step 3: Build** — `make build 2>&1 | grep -E "error|BUILD"` → `** BUILD SUCCEEDED **`. (`ensureAttached` appends inside the main-actor class; if the compiler flags actor isolation on the `Task` bodies, annotate them `@MainActor` like neighbouring code.)

- [ ] **Step 4: Commit**

```bash
git add Sources/HerdrM/AppModel.swift
git commit -m "feat: track the selected tab's herdr layout and attach every pane"
```

### Task 10: Place panes by frame, draw dividers, focus on click

**Files:**
- Modify: `Sources/HerdrM/ContentView.swift` (`attachedTerminal` ZStack ~line 528-531; `attachChild` ~line 631)
- Modify: `Sources/HerdrM/TerminalView.swift` (`LineBreakTerminalView`; `AttachTerminalView` ~line 1400)

**Interfaces:**
- Consumes: `AppModel.activeLayout`, `commitSplitRatio`, `focusLayoutPane`, `SplitTree.frames/dividers`, `UnitRect`
- Produces: `LineBreakTerminalView.onFocused: (() -> Void)?`, `AttachTerminalView.onFocused` param (default `{}`)

- [ ] **Step 1: Focus callback.** In `LineBreakTerminalView` add `var onFocused: (() -> Void)?` and, if the class has no `becomeFirstResponder` override (`grep -n becomeFirstResponder Sources/HerdrM/TerminalView.swift`), add:

```swift
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocused?() }
        return result
    }
```

(If one exists, add `if result { onFocused?() }` before its return.) In `AttachTerminalView` add `var onFocused: () -> Void = {}`; in `makeNSView` set `view.onFocused = onFocused` next to `view.controller = …` (line ~1446) and in `updateNSView` set `nsView.onFocused = onFocused` so the closure never goes stale.

- [ ] **Step 2: Placement.** Replace the `ZStack { ForEach(model.attachSessions) { … } }` at `ContentView.swift:528` with:

```swift
GeometryReader { proxy in
    ZStack(alignment: .topLeading) {
        ForEach(model.attachSessions) { session in
            let frame = placement(for: session, in: proxy.size, selected: entry)
            attachChild(session, isSelected: session.id == entry.id, placed: frame != nil)
                .frame(
                    width: frame?.width ?? proxy.size.width,
                    height: frame?.height ?? proxy.size.height
                )
                .offset(x: frame?.minX ?? 0, y: frame?.minY ?? 0)
        }
        if let layout = splitLayout {
            SplitDividersOverlay(layout: layout, size: proxy.size) { divider, ratio in
                model.commitSplitRatio(divider: divider, ratio: ratio)
            }
        }
    }
}
```

Add to `ContentView`:

```swift
    /// The layout to draw, or nil when only the selected pane shows (single
    /// pane, zoomed, or data that could not be reconciled).
    private var splitLayout: AppModel.ActiveLayout? {
        guard let layout = model.activeLayout, !layout.zoomed else { return nil }
        return layout
    }

    /// Pixel frame of an attach child inside the terminal area, or nil when it
    /// is not part of the visible arrangement (then the old rule applies:
    /// full-size, visible only if it is the selected pane).
    private func placement(for session: AppModel.AttachedEntry, in size: CGSize, selected: AppModel.AttachedEntry) -> CGRect? {
        guard let layout = splitLayout, session.ref.deviceID == layout.deviceID,
              let unit = layout.tree.frames()[session.ref.paneID]
        else { return nil }
        return CGRect(
            x: unit.x * size.width, y: unit.y * size.height,
            width: unit.width * size.width, height: unit.height * size.height
        )
    }
```

Change `attachChild(_ session:, isSelected:)` to `attachChild(_ session:, isSelected:, placed: Bool)`:
- `isVisible:` argument becomes `(isSelected || placed) && model.selectedShellID == nil && !model.isFileManagerActive`
- final modifiers become `.opacity(isSelected || placed ? 1 : 0)` and `.allowsHitTesting(isSelected || placed)`
- pass `onFocused: { model.focusLayoutPane(session.ref.paneID) }` to `AttachTerminalView`
- add the focus border as the last modifier on the returned view:

```swift
.overlay {
    if placed, isSelected {
        Rectangle().strokeBorder(Theme.working.opacity(0.8), lineWidth: 1).allowsHitTesting(false)
    }
}
```

- [ ] **Step 3: Dividers overlay** (append to `ContentView.swift`)

```swift
/// Draggable dividers for a herdr split tree. Dragging previews locally and
/// commits one absolute ratio on release (`layout.set_split_ratio`), after
/// which the refreshed layout replaces the preview.
private struct SplitDividersOverlay: View {
    let layout: AppModel.ActiveLayout
    let size: CGSize
    let onCommit: (SplitDivider, Double) -> Void
    @State private var dragging: (id: String, ratio: Double)?

    var body: some View {
        ForEach(layout.tree.dividers(), id: \.id) { divider in
            let ratio = dragging?.id == divider.id ? dragging!.ratio : divider.ratio
            let rect = dividerRect(divider, ratio: ratio)
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: divider.direction == .right ? 1 : rect.width,
                       height: divider.direction == .down ? 1 : rect.height)
                .overlay(
                    Color.clear
                        .frame(width: divider.direction == .right ? 9 : nil,
                               height: divider.direction == .down ? 9 : nil)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(coordinateSpace: .named("terminalArea"))
                                .onChanged { value in
                                    dragging = (divider.id, ratio(for: value.location, in: divider))
                                }
                                .onEnded { value in
                                    let final = ratio(for: value.location, in: divider)
                                    dragging = nil
                                    onCommit(divider, final)
                                }
                        )
                        .onHover { inside in
                            if inside {
                                (divider.direction == .right ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                            } else { NSCursor.pop() }
                        }
                )
                .offset(x: divider.direction == .right ? rect.minX : rect.minX,
                        y: divider.direction == .down ? rect.minY : rect.minY)
        }
    }

    private func dividerRect(_ divider: SplitDivider, ratio: Double) -> CGRect {
        let r = divider.region
        switch divider.direction {
        case .right:
            let x = (r.x + r.width * ratio) * size.width
            return CGRect(x: x, y: r.y * size.height, width: 1, height: r.height * size.height)
        case .down:
            let y = (r.y + r.height * ratio) * size.height
            return CGRect(x: r.x * size.width, y: y, width: r.width * size.width, height: 1)
        }
    }

    private func ratio(for point: CGPoint, in divider: SplitDivider) -> Double {
        let r = divider.region
        switch divider.direction {
        case .right: return min(max((point.x / size.width - r.x) / r.width, 0.05), 0.95)
        case .down: return min(max((point.y / size.height - r.y) / r.height, 0.05), 0.95)
        }
    }
}
```

Add `.coordinateSpace(name: "terminalArea")` on the `ZStack` from Step 2. While `dragging` is non-nil the terminals keep their old frames (only the divider line previews); that is deliberate — resizing PTYs every drag tick would spam herdr/SIGWINCH.

- [ ] **Step 4: Build** — `make build 2>&1 | grep -E "error|BUILD"` → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Verify the multi-attach risk first (user, before polishing)** — select `arte-hotel` → `console` tab (2 panes). Expected: both panes visible side by side, typing goes to the focused one, no "Another client took this pane over" overlay. If a pane shows that overlay, the N-`--takeover` assumption is false: stop and switch `ensureAttached` to attach-on-focus (spec risk fallback) before continuing.

- [ ] **Step 6: Manual check (user)** — 3-pane tab (`robohen_bmad` → `console`): layout matches the herdr TUI (one wide pane on top, two below); click each pane → blue border follows, herdr focus follows (`herdr pane list` shows `focused`); drag a divider → ratio persists after release and matches in the TUI; close a pane from the TUI → layout collapses without a crash; single-pane tabs look unchanged; `pane.zoom` from the TUI shows only the focused pane.

- [ ] **Step 7: Commit**

```bash
git add Sources/HerdrM
git commit -m "feat: render herdr split layout with draggable dividers and pane focus"
```

### Task 11: Regression pass + docs

**Files:**
- Modify: `CLAUDE.md` (Layout section: one bullet for the tab bar / split rendering and the verified `layout.set_split_ratio` / `pane.focus` protocol notes)
- Modify: `CHANGELOG.md` (new `## [Unreleased]` section; mandatory per CLAUDE.md before any tag)

- [ ] **Step 1: Full test run** — `make kit-test 2>&1 | tail -8` → 0 failures (tests that need a live herdr run against the local server).
- [ ] **Step 2: Full build** — `make build 2>&1 | grep -E "error|warning: unused|BUILD"` → `BUILD SUCCEEDED`.
- [ ] **Step 3: Docs** — add the CLAUDE.md protocol bullet:

```
- `pane.layout {pane_id}` returns cell rects + flat `splits` (direction right|down, ratio, rect); the tree is rebuilt in
  `HerdrKit/PaneLayout.swift`. `layout.set_split_ratio {tab_id,path:[bool],ratio}` sets an absolute ratio;
  `pane.focus {pane_id}` / `tab.focus {tab_id}` focus by id (`pane.resize`/`pane.focus_direction` are directional only).
```

and a CHANGELOG entry listing: sidebar reference layout, space tab bar, herdr-driven splits, Ghostty themes.
- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "docs: sidebar, tab bar and split layout notes; changelog"
```

---

## Self-Review

**Spec coverage:** Stage 1 sidebar → Tasks 1–4 (branch, ahead, rings, strip, single-line agents, tooltip, a11y labels untouched, drag/sticky preserved by keeping overlays/wrappers). Stage 2 tab bar → Tasks 5–6 (`tab.list` data already in `session.tabs`; focus/create/close/rename). Stage 3 splits → Tasks 7–10 (decode, tree, focus, resize via `layout.set_split_ratio`, `layout.updated` via the existing refresh path, zoom handled by `activeLayout.zoomed`, single pane unchanged). Risks → N-attach verification is Task 10 Step 5; selection kept pane-centric (Task 6/9). Verification section → each task's build/test/manual steps.

**Deviation from spec (intentional):** the spec described a recursive `HerdrSplitView`; the plan repositions the existing kept-alive attach `ZStack` by frame instead, which preserves terminal identity without new view-tree risk. Poll fallback is not built; `layout.updated` already routes through `scheduleRefresh` → refresh → `refreshActiveLayout`.

**Placeholder scan:** none; the two "if it exists, adapt" notes (`becomeFirstResponder`, `private` helpers) name the exact grep and the exact edit.

**Type consistency:** `GitStatus`, `GitStatusProvider.status(forDirectory:)`, `WorkspaceDirectory.resolve(workspaceID:candidates:)`, `TabSelection.paneToSelect/activeTabID`, `PaneLayout`, `SplitTree.build/frames/dividers/paneIDs`, `SplitDivider.path/region/ratio`, `AppModel.ActiveLayout`, `commitSplitRatio(divider:ratio:)`, `focusLayoutPane(_:)` are used with the same names in every task that references them.
