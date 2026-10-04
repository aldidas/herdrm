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
