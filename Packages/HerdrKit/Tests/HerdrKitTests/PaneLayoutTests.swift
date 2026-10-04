import XCTest
@testable import HerdrKit

final class PaneLayoutTests: XCTestCase {
    private let twoPane = """
    {"area":{"height":42,"width":139,"x":0,"y":0},"focused_pane_id":"w18:p5",
     "panes":[{"focused":true,"pane_id":"w18:p5","rect":{"height":42,"width":70,"x":0,"y":0}},
              {"focused":false,"pane_id":"w18:p6","rect":{"height":42,"width":69,"x":70,"y":0}}],
     "splits":[{"direction":"right","id":"split_0_root","ratio":0.5,"rect":{"height":42,"width":139,"x":0,"y":0}}],
     "tab_id":"w18:t3","workspace_id":"w18","zoomed":false}
    """

    private let threePane = """
    {"area":{"height":42,"width":139,"x":0,"y":0},"focused_pane_id":"w1E:p5",
     "panes":[{"focused":false,"pane_id":"w1E:p3","rect":{"height":21,"width":139,"x":0,"y":0}},
              {"focused":false,"pane_id":"w1E:p4","rect":{"height":21,"width":70,"x":0,"y":21}},
              {"focused":true,"pane_id":"w1E:p5","rect":{"height":21,"width":69,"x":70,"y":21}}],
     "splits":[{"direction":"down","id":"split_0_root","ratio":0.5,"rect":{"height":42,"width":139,"x":0,"y":0}},
               {"direction":"right","id":"split_1_1","ratio":0.5,"rect":{"height":21,"width":139,"x":0,"y":21}}],
     "tab_id":"w1E:t3","workspace_id":"w1E","zoomed":false}
    """

    private func decode(_ json: String) throws -> PaneLayout {
        try JSONDecoder().decode(PaneLayout.self, from: Data(json.utf8))
    }

    func testDecodesLiveLayout() throws {
        let layout = try decode(twoPane)
        XCTAssertEqual(layout.tabID, "w18:t3")
        XCTAssertEqual(layout.focusedPaneID, "w18:p5")
        XCTAssertEqual(layout.panes.count, 2)
        XCTAssertEqual(layout.splits.first?.direction, .right)
        XCTAssertFalse(layout.zoomed)
    }

    func testTwoPaneTree() throws {
        let tree = try XCTUnwrap(SplitTree.build(from: decode(twoPane)))
        XCTAssertEqual(
            tree,
            .split(id: "split_0_root", direction: .right, ratio: 0.5,
                   first: .leaf(paneID: "w18:p5"), second: .leaf(paneID: "w18:p6"))
        )
    }

    func testThreePaneTreeNestsSecondSplitUnderSecondChild() throws {
        let tree = try XCTUnwrap(SplitTree.build(from: decode(threePane)))
        XCTAssertEqual(
            tree,
            .split(id: "split_0_root", direction: .down, ratio: 0.5,
                   first: .leaf(paneID: "w1E:p3"),
                   second: .split(id: "split_1_1", direction: .right, ratio: 0.5,
                                  first: .leaf(paneID: "w1E:p4"), second: .leaf(paneID: "w1E:p5")))
        )
    }

    func testSinglePaneIsALeaf() throws {
        let json = """
        {"area":{"height":42,"width":139,"x":0,"y":0},"focused_pane_id":"a",
         "panes":[{"focused":true,"pane_id":"a","rect":{"height":42,"width":139,"x":0,"y":0}}],
         "splits":[],"tab_id":"t","workspace_id":"w","zoomed":false}
        """
        XCTAssertEqual(SplitTree.build(from: try decode(json)), .leaf(paneID: "a"))
    }

    func testRoundedRectsDoNotBreakPartitioning() throws {
        // ratio .5 of width 139 is 69.5; herdr gave the left pane 69 and the right 70.
        let json = """
        {"area":{"height":10,"width":139,"x":0,"y":0},"focused_pane_id":"a",
         "panes":[{"focused":true,"pane_id":"a","rect":{"height":10,"width":69,"x":0,"y":0}},
                  {"focused":false,"pane_id":"b","rect":{"height":10,"width":70,"x":69,"y":0}}],
         "splits":[{"direction":"right","id":"split_0_root","ratio":0.5,"rect":{"height":10,"width":139,"x":0,"y":0}}],
         "tab_id":"t","workspace_id":"w","zoomed":false}
        """
        let tree = try XCTUnwrap(SplitTree.build(from: decode(json)))
        XCTAssertEqual(tree.paneIDs, ["a", "b"])
    }

    func testFramesFollowRatios() throws {
        let tree = try XCTUnwrap(SplitTree.build(from: decode(threePane)))
        let frames = tree.frames()
        XCTAssertEqual(frames["w1E:p3"], UnitRect(x: 0, y: 0, width: 1, height: 0.5))
        XCTAssertEqual(frames["w1E:p4"], UnitRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(frames["w1E:p5"], UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    func testDividersCarryPathAndRegion() throws {
        let tree = try XCTUnwrap(SplitTree.build(from: decode(threePane)))
        let dividers = tree.dividers()
        XCTAssertEqual(dividers.map(\.id), ["split_0_root", "split_1_1"])
        XCTAssertEqual(dividers[0].path, [])
        XCTAssertEqual(dividers[1].path, [true])
        XCTAssertEqual(dividers[1].region, UnitRect(x: 0, y: 0.5, width: 1, height: 0.5))
    }

    func testUnmatchedPanesYieldNilNotACrash() throws {
        let json = """
        {"area":{"height":10,"width":10,"x":0,"y":0},"focused_pane_id":"a",
         "panes":[{"focused":true,"pane_id":"a","rect":{"height":10,"width":5,"x":0,"y":0}},
                  {"focused":false,"pane_id":"b","rect":{"height":10,"width":5,"x":5,"y":0}}],
         "splits":[],"tab_id":"t","workspace_id":"w","zoomed":false}
        """
        XCTAssertNil(SplitTree.build(from: try decode(json)))
    }
}
