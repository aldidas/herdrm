import XCTest
@testable import MacHerdr

final class AppLanguageTests: XCTestCase {
    func testRelaunchHelperWaitsForThisPidThenOpensTheQuotedBundle() {
        let command = AppLanguage.relaunchHelperCommand(
            pid: 42,
            bundlePath: "/Applications/O'Brien/MacHerdr.app"
        )
        XCTAssertEqual(
            command,
            "while /bin/kill -0 42 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open '/Applications/O'\\''Brien/MacHerdr.app'"
        )
    }

    func testFollowSystemDoesNotRelaunchWhenTheMacIsAlreadyEnglish() {
        XCTAssertFalse(
            AppLanguage.needsRelaunch(.system, running: "en", systemLanguages: ["en-US", "zh-Hans-CN"])
        )
    }

    func testExplicitEnglishDoesNotRelaunchWhenAlreadyRunningEnglish() {
        XCTAssertFalse(
            AppLanguage.needsRelaunch(.english, running: "en", systemLanguages: ["zh-Hans-CN"])
        )
    }

    func testFollowSystemRelaunchesWhenTheMacIsChineseAndTheUIIsEnglish() {
        XCTAssertTrue(
            AppLanguage.needsRelaunch(.system, running: "en", systemLanguages: ["zh-Hans-CN"])
        )
    }

    func testChineseRelaunchesWhenTheUIIsEnglish() {
        XCTAssertTrue(
            AppLanguage.needsRelaunch(.simplifiedChinese, running: "en", systemLanguages: ["en-US"])
        )
    }

    func testFollowSystemDoesNotRelaunchWhenTheMacIsAlreadyChinese() {
        XCTAssertFalse(
            AppLanguage.needsRelaunch(.system, running: "zh-Hans", systemLanguages: ["zh-Hans-CN"])
        )
    }
}
