import XCTest
@testable import MacHerdr

/// The Agents header carries a small "new" button at its right end, pinned or not.
/// Spaces has none: New Space is in the sidebar's titlebar menu.
@MainActor
final class SidebarSectionButtonsUIUXTests: XCTestCase {
    func testSpacesHeaderHasNoButton() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        XCTAssertFalse(sidebar.headerButtons(.spaces).contains(String(localized: "New Space")), "New Space lives in the titlebar menu")
    }

    func testAgentsHeaderButtonOpensNewAgent() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        let expanded = sidebar.listHeight
        sidebar.scroll(.bottom, in: .agents)
        XCTAssertEqual(sidebar.pinnedHeader(in: .agents), .agents)

        try sidebar.clickPinnedHeaderButton(in: .agents)
        XCTAssertTrue(sidebar.model.showNewAgent)
        XCTAssertFalse(sidebar.model.showNewTerminal)
        XCTAssertEqual(sidebar.listHeight, expanded, accuracy: 2, "the button does not collapse the section")
    }

    func testTerminalsHeaderButtonOpensNewTerminal() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, terminals: 20)
        let expanded = sidebar.listHeight
        sidebar.scroll(.bottom)
        XCTAssertEqual(sidebar.pinnedHeader, .terminals)

        try sidebar.clickPinnedHeaderButton()
        XCTAssertTrue(sidebar.model.showNewTerminal)
        XCTAssertFalse(sidebar.model.showNewAgent)
        XCTAssertEqual(sidebar.listHeight, expanded, accuracy: 2, "the button does not collapse the section")
    }

    func testVoiceOverReadsEachHeaderButtonByName() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, terminals: 20)

        XCTAssertTrue(sidebar.headerButtons(.agents).contains(String(localized: "New Agent")), "\(sidebar.headerButtons(.agents))")
        XCTAssertTrue(sidebar.headerButtons(.terminals).contains(String(localized: "New Terminal")), "\(sidebar.headerButtons(.terminals))")
    }

    func testAgentsHeaderButtonPresentsTheNewAgentSheet() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, sheets: true)
        XCTAssertEqual(sidebar.sheetButtons, [])

        try sidebar.pressHeaderButton(.agents, named: String(localized: "New Agent"))
        XCTAssertTrue(sidebar.sheetButtons.contains(String(localized: "Start Agent")), "\(sidebar.sheetButtons)")
    }

    func testTerminalsHeaderButtonPresentsTheNewTerminalSheet() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, terminals: 20, sheets: true)

        try sidebar.pressHeaderButton(.terminals, named: String(localized: "New Terminal"))
        XCTAssertTrue(sidebar.sheetButtons.contains(String(localized: "Open Terminal")), "\(sidebar.sheetButtons)")
    }

    func testClickingAHeaderTitleOpensNothing() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        sidebar.scroll(.bottom)

        try sidebar.clickPinnedHeader()
        XCTAssertFalse(sidebar.model.showNewAgent)
        XCTAssertFalse(sidebar.model.showNewSpace)
    }
}
