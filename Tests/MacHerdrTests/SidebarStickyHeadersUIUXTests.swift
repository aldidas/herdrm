import XCTest
@testable import MacHerdr

/// What a user sees in the sidebar's section headers. The sticky mechanics
/// are tested in the StickySectionHeaders package; this covers the wiring.
@MainActor
final class SidebarStickyHeadersUIUXTests: XCTestCase {
    func testSpacesHeaderStaysPinnedWhileItsRowsScroll() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        XCTAssertEqual(sidebar.pinnedHeader, .spaces)

        sidebar.scroll(.offset(180))
        XCTAssertEqual(sidebar.scrollOffset, 180, accuracy: 1)
        XCTAssertEqual(sidebar.pinnedHeader, .spaces)
    }

    func testEachPaneKeepsItsOwnHeaderPinned() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        XCTAssertEqual(sidebar.pinnedHeader(in: .agents), .agents)

        sidebar.scroll(.bottom, in: .agents)
        XCTAssertEqual(sidebar.pinnedHeader(in: .agents), .agents)
        XCTAssertEqual(sidebar.pinnedHeader(in: .spaces), .spaces, "scrolling Agents leaves Spaces alone")
    }

    func testDividerStartsAtTheVerticalCentre() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        XCTAssertEqual(sidebar.paneHeight(.spaces), sidebar.paneHeight(.agents), accuracy: 6)
    }

    func testClickingThePinnedHeaderCollapsesAndExpandsItsSection() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        let expanded = sidebar.listHeight

        sidebar.scroll(.offset(180))
        try sidebar.clickPinnedHeader()                       // Spaces ▾ → collapsed
        XCTAssertLessThan(sidebar.listHeight, expanded - 300)

        sidebar.scroll(.top)
        XCTAssertEqual(sidebar.pinnedHeader, .spaces)
        try sidebar.clickPinnedHeader()                       // Spaces ▸ → expanded
        XCTAssertEqual(sidebar.listHeight, expanded, accuracy: 2)
    }
}
