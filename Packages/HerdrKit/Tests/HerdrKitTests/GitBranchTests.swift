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
