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
