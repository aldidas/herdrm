import XCTest
@testable import HerdrKit

final class ReviewFixesTests: XCTestCase {
    // #2: a layout only applies to the selection if it contains the selected pane.
    func testTreeContainsOnlyItsOwnPanes() {
        let tree = SplitTree.split(
            id: "split_0_root", direction: .right, ratio: 0.5,
            first: .leaf(paneID: "p1"), second: .leaf(paneID: "p2")
        )
        XCTAssertTrue(tree.contains(paneID: "p2"))
        XCTAssertFalse(tree.contains(paneID: "p9"))
    }

    // #3: only the newest request may apply its reply.
    func testLatestOnlyGateRejectsStaleTokens() {
        var gate = LatestOnlyGate()
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
    }

    // #7: the space ring must carry unread-done, as the old attention glyph did.
    func testSpaceAttentionRingState() {
        XCTAssertEqual(SpaceAttention.blocked.ring.status, .blocked)
        XCTAssertEqual(SpaceAttention.working.ring.status, .working)
        XCTAssertEqual(SpaceAttention.unreadDone.ring.status, .done)
        XCTAssertTrue(SpaceAttention.unreadDone.ring.unreadDone)
        XCTAssertEqual(SpaceAttention.none.ring.status, .idle)
        XCTAssertFalse(SpaceAttention.none.ring.unreadDone)
    }
}
