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
