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

    /// Two app instances share one $TMPDIR; the second must not unlink the first's live sockets.
    func testRemoveStaleSocketsKeepsSocketsSomeoneIsListeningOn() throws {
        let dir = NSTemporaryDirectory() + "ds-\(UUID().uuidString.prefix(6))/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let live = try Self.unixSocket(at: dir + "macherdr-nvim-live0000.sock", listening: true)
        defer { close(live) }
        let dead = try Self.unixSocket(at: dir + "macherdr-nvim-dead0000.sock", listening: true)
        close(dead)  // the file stays behind, like after a crash

        EditorDrawerRegistry.removeStaleSockets(in: dir)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertEqual(left, ["macherdr-nvim-live0000.sock"])
    }

    private static func unixSocket(at path: String, listening: Bool) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "bind \(path)")
        if listening { XCTAssertEqual(Darwin.listen(fd, 1), 0) }
        return fd
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
