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

    func testLaunchMergesBaseEnvironmentUnderItsOwnKeys() {
        let command = NvimCommand.launch(
            directory: "/r", socketPath: "/tmp/s.sock", file: nil,
            baseEnvironment: ["PATH": "/opt/bin", "SHELL": "/bin/fish", "MACHERDR_NVIM_SOCK": "evil"]
        )
        XCTAssertEqual(command.environment["PATH"], "/opt/bin")
        XCTAssertEqual(command.environment["SHELL"], "/bin/fish")
        XCTAssertEqual(command.environment["MACHERDR_NVIM_SOCK"], "/tmp/s.sock")
    }

    func testOpenFileWhenReadyGivesUpAsUnreachable() async throws {
        let binary = try await XCTUnwrapAsync(await NvimClient.resolveBinary(), "nvim not installed")
        let result = await NvimClient.openFileWhenReady(
            binary: binary, socketPath: "/tmp/nope-\(UUID().uuidString.prefix(8)).sock", path: "/etc/hosts",
            attempts: 2, delay: .milliseconds(50)
        )
        XCTAssertEqual(result, .unreachable)
    }

    /// ⌘E then ⌘K in quick succession: the socket does not exist yet on the first try.
    func testOpenFileWhenReadyWaitsForALateSocket() async throws {
        let binary = try await XCTUnwrapAsync(await NvimClient.resolveBinary(), "nvim not installed")
        let dir = NSTemporaryDirectory() + "nc-\(UUID().uuidString.prefix(6))/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let socket = dir + "n.sock"
        let target = dir + "late.txt"
        try "x\n".write(toFile: target, atomically: true, encoding: .utf8)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: binary)
        server.arguments = ["--headless", "--listen", socket]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        defer {
            server.terminate()
            try? FileManager.default.removeItem(atPath: dir)
        }
        Task {
            try await Task.sleep(for: .milliseconds(600))
            try server.run()
        }
        let result = await NvimClient.openFileWhenReady(
            binary: binary, socketPath: socket, path: target, attempts: 30, delay: .milliseconds(200)
        )
        XCTAssertEqual(result, .opened)
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
