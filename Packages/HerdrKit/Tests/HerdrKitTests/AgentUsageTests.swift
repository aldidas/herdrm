import XCTest
@testable import HerdrKit

final class AgentUsageTests: XCTestCase {
    func testGrazrUsageBecomesWindowsWithResets() throws {
        let usage = try XCTUnwrap(AgentUsage(tokens: [
            "grazr": "senad@example.com",
            "claude_model": "Fable 5.1 (1M context)",
            "claude_ctx": "context 47% · cache 99.8%",
            "claude_usage": "5h 7% 3h21m · 7d 2% 6d18h",
        ]))
        XCTAssertEqual(usage.windows, [
            UsageWindow(label: "5h", percent: 7, resetsIn: "3h21m"),
            UsageWindow(label: "7d", percent: 2, resetsIn: "6d18h"),
        ])
        XCTAssertEqual(usage.windows.map(\.title), ["5 hours", "7 days"])
        XCTAssertEqual(usage.account, "senad@example.com")
        XCTAssertEqual(usage.model, "Fable 5.1 (1M context)")
        XCTAssertEqual(usage.context, UsageWindow(label: "context", percent: 47))
    }

    func testQuotaFallbackTokensWork() throws {
        let usage = try XCTUnwrap(AgentUsage(tokens: [
            "quota_5h_warning": "5h 50% 3h57m",
            "quota_week_danger": "7d 89% 2d8h",
        ]))
        XCTAssertEqual(usage.windows.map(\.percent), [50, 89])
        XCTAssertNil(usage.context)
    }

    func testDailyAndOtherWindowsAreTitledGenerically() {
        XCTAssertEqual(UsageWindow(label: "1d", percent: 1).title, "Daily")
        XCTAssertEqual(UsageWindow(label: "24h", percent: 1).title, "Daily")
        XCTAssertEqual(UsageWindow(label: "30d", percent: 1).title, "30 days")
        XCTAssertEqual(UsageWindow(label: "weird", percent: 1).title, "weird")
    }

    func testNoUsageTokensMeansNoUsage() {
        XCTAssertNil(AgentUsage(tokens: [:]))
        XCTAssertNil(AgentUsage(tokens: ["grazr": "a@b.c", "claude_model": "x", "claude_ctx": "context 5%"]))
        XCTAssertNil(AgentUsage(tokens: ["claude_usage": "no numbers here"]))
    }

    func testPercentIsClampedAndResetIsOptional() throws {
        let usage = try XCTUnwrap(AgentUsage(tokens: ["claude_usage": "5h 140%"]))
        XCTAssertEqual(usage.windows, [UsageWindow(label: "5h", percent: 100, resetsIn: nil)])
    }
}
