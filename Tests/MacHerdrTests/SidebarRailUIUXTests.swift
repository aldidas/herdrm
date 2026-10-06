import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import MacHerdr

/// The collapsed sidebar: a narrow rail of numbered status rings.
@MainActor
final class SidebarRailUIUXTests: XCTestCase {
    private var window: NSWindow!

    private func host(spaces: Int, agents: Int) throws -> AppModel {
        let model = try SidebarHarness.fakeModel(spaces: spaces, agents: agents, terminals: 0, agentTokens: nil)
        let rail = SidebarRail(model: model, collapsed: .constant(true)).frame(width: SidebarRail.width, height: 500)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SidebarRail.width, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "SidebarRail \(UUID().uuidString)"
        window.contentView = NSHostingView(rootView: rail)
        window.orderFrontRegardless()
        settle()
        return model
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private func rows(_ kind: String) -> [AccessibilityProbe.Element] {
        AccessibilityProbe.elements(in: window).filter {
            $0.role == "AXButton" && ($0.identifier ?? "").hasPrefix("sidebar.rail.\(kind).")
        }
    }

    override func tearDown() {
        window?.close()
        super.tearDown()
    }

    func testRailListsEverySpaceAndTheAgentsOfTheSelectedSpace() throws {
        let model = try host(spaces: 3, agents: 2)
        model.selectedSpace = model.visibleSpaces.first?.ref
        settle()
        XCTAssertEqual(rows("space").map(\.identifier), (1...3).map { "sidebar.rail.space.\($0)" })
        XCTAssertEqual(rows("agent").count, 2)
    }

    func testClickingASpaceRowSelectsItWithoutExpanding() throws {
        let model = try host(spaces: 3, agents: 0)
        let second = try XCTUnwrap(rows("space").first { $0.identifier == "sidebar.rail.space.2" })
        AccessibilityProbe.press(second)
        settle()
        XCTAssertEqual(model.selectedSpace, model.visibleSpaces[1].ref)
    }

    func testRailWidthIsNarrowButNotHidden() {
        XCTAssertGreaterThan(SidebarRail.width, 24)
        XCTAssertLessThan(SidebarRail.width, 60)
    }
}
