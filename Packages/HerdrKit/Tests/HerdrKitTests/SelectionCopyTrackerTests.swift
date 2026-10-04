import XCTest
@testable import HerdrKit

final class SelectionCopyTrackerTests: XCTestCase {
    func testNewSelectionIsAnnouncedOnce() {
        var tracker = SelectionCopyTracker()
        XCTAssertTrue(tracker.shouldAnnounce(selection: "hello"))
        XCTAssertFalse(tracker.shouldAnnounce(selection: "hello"), "a later click on the same selection stays quiet")
    }

    func testChangedSelectionIsAnnouncedAgain() {
        var tracker = SelectionCopyTracker()
        _ = tracker.shouldAnnounce(selection: "one")
        XCTAssertTrue(tracker.shouldAnnounce(selection: "two"))
    }

    func testClearedSelectionResetsSoTheSameTextAnnouncesAgain() {
        var tracker = SelectionCopyTracker()
        _ = tracker.shouldAnnounce(selection: "same")
        XCTAssertFalse(tracker.shouldAnnounce(selection: nil))
        XCTAssertFalse(tracker.shouldAnnounce(selection: ""))
        XCTAssertTrue(tracker.shouldAnnounce(selection: "same"))
    }
}
