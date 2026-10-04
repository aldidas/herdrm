import XCTest
@testable import HerdrKit

final class SpaceLandingTests: XCTestCase {
    private let agents: [(paneID: String, tabID: String?)] = [("a1", "t1"), ("a2", "t2")]
    private let terminals: [(paneID: String, tabID: String?)] = [("s1", "t1"), ("s3", "t3")]

    func testRemembersTheLastPaneWhenItStillExists() {
        let pane = SpaceLanding.paneToSelect(
            remembered: "a2", existingPaneIDs: ["a1", "a2", "s1", "s3"],
            activeTabID: "t1", agentPanes: agents, terminalPanes: terminals
        )
        XCTAssertEqual(pane, "a2")
    }

    func testForgottenPaneFallsBackToTheActiveTab() {
        let pane = SpaceLanding.paneToSelect(
            remembered: "gone", existingPaneIDs: ["a1", "a2", "s1", "s3"],
            activeTabID: "t2", agentPanes: agents, terminalPanes: terminals
        )
        XCTAssertEqual(pane, "a2")
    }

    func testActiveTabWithOnlyTerminalsPicksATerminal() {
        let pane = SpaceLanding.paneToSelect(
            remembered: nil, existingPaneIDs: ["a1", "a2", "s1", "s3"],
            activeTabID: "t3", agentPanes: agents, terminalPanes: terminals
        )
        XCTAssertEqual(pane, "s3")
    }

    func testNilWhenNothingMatches() {
        XCTAssertNil(SpaceLanding.paneToSelect(
            remembered: nil, existingPaneIDs: [], activeTabID: nil, agentPanes: [], terminalPanes: []
        ))
        XCTAssertNil(SpaceLanding.paneToSelect(
            remembered: nil, existingPaneIDs: ["a1"], activeTabID: "t9", agentPanes: agents, terminalPanes: terminals
        ))
    }
}
