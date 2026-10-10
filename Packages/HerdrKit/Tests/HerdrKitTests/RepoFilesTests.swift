#if os(macOS)
import XCTest
@testable import HerdrKit

final class RepoFilesTests: XCTestCase {
    func testPorcelainDropsDeletionsAndKeepsPaths() {
        let data = Data(" M Sources/a.swift\0?? new file.txt\0 D gone.swift\0A  b.swift\0".utf8)
        XCTAssertEqual(
            RepoFileParser.changedPaths(porcelain: data),
            ["Sources/a.swift", "new file.txt", "b.swift"]
        )
    }

    func testNumstatSkipsBinary() {
        let data = Data("12\t3\ta.swift\0-\t-\timg.png\0".utf8)
        let stats = RepoFileParser.numstat(data)
        XCTAssertEqual(stats["a.swift"]?.added, 12)
        XCTAssertEqual(stats["a.swift"]?.deleted, 3)
        XCTAssertNil(stats["img.png"])
    }

    func testVimPathEscapingAndEditorNames() {
        XCTAssertEqual(HerdrService.vimEscapedPath("/a b/c#d.swift"), "/a\\ b/c\\#d.swift")
        XCTAssertTrue(HerdrService.isEditorProcessName("nvim"))
        XCTAssertFalse(HerdrService.isEditorProcessName("zsh"))
    }

    func testFuzzyRequiresSubsequence() {
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", path: "Sources/App.swift"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "srcapp", path: "Sources/App.swift"))
        XCTAssertEqual(FuzzyMatcher.score(query: "", path: "anything"), 0)
    }

    func testFuzzyPrefersFilenameAndBoundaries() throws {
        let filename = try XCTUnwrap(FuzzyMatcher.score(query: "model", path: "Sources/AppModel.swift"))
        let scattered = try XCTUnwrap(FuzzyMatcher.score(query: "model", path: "mod/e/l/other.swift"))
        XCTAssertGreaterThan(filename, scattered)
        let shorter = try XCTUnwrap(FuzzyMatcher.score(query: "app", path: "App.swift"))
        let longer = try XCTUnwrap(FuzzyMatcher.score(query: "app", path: "Sources/Deep/Dir/App.swift"))
        XCTAssertGreaterThan(shorter, longer)
    }

    func testChangedFilesAndSearchInRealRepo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-files-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func git(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(args)")
        }
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git("init", "-q")
        try git("add", ".")
        try git("commit", "-q", "-m", "init")
        try "one\nmore\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

        let files = RepoFiles(ttl: 0)
        let changedResult = await files.hits(query: "", directory: root.path)
        let changed = try XCTUnwrap(changedResult)
        XCTAssertEqual(Set(changed.hits.map(\.path)), ["a.txt", "c.txt"])
        XCTAssertEqual(changed.hits.first { $0.path == "a.txt" }?.added, 1)
        XCTAssertNil(changed.hits.first { $0.path == "c.txt" }?.added)

        let foundResult = await files.hits(query: "b", directory: root.path)
        let found = try XCTUnwrap(foundResult)
        XCTAssertEqual(found.hits.map(\.path), ["b.txt"])

        let outside = await files.hits(query: "", directory: NSTemporaryDirectory())
        XCTAssertNil(outside)
    }
}
#endif
