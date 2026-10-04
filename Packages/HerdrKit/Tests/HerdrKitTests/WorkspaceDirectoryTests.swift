import XCTest
@testable import HerdrKit

final class WorkspaceDirectoryTests: XCTestCase {
    func testFirstNonEmptyCwdForWorkspaceWins() {
        let dir = WorkspaceDirectory.resolve(
            workspaceID: "w2",
            candidates: [("w1", "/a"), ("w2", nil), ("w2", ""), ("w2", "/b"), ("w2", "/c")]
        )
        XCTAssertEqual(dir, "/b")
    }

    func testNilWhenWorkspaceHasNoCwd() {
        XCTAssertNil(WorkspaceDirectory.resolve(workspaceID: "w9", candidates: [("w1", "/a")]))
    }
}
