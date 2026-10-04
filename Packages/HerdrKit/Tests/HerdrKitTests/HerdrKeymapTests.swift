import XCTest
@testable import HerdrKit

final class HerdrKeymapTests: XCTestCase {
    /// The user's real config: custom prefix, ctrl+1..9 for workspaces.
    private let userConfig = """
    onboarding = false

    [ui]
    tab_bar_position = "top"

    [keys]
    prefix = "ctrl+a"
    split_horizontal = "prefix+s"
    focus_pane_left = "prefix+h"
    switch_tab = "prefix+1..9"
    switch_workspace = "ctrl+1..9"
    toggle_sidebar = "prefix+["
    new_tab = "prefix+c"
    detach = "prefix+d"
    zoom = "prefix+z"
    close_pane = "prefix+x"

    [theme]
    name = "catppuccin-mocha"
    """

    private func chord(_ key: String, ctrl: Bool = false, alt: Bool = false, shift: Bool = false) -> KeyChord {
        KeyChord(key: key, ctrl: ctrl, alt: alt, shift: shift)
    }

    func testDefaultsMatchHerdrDocs() {
        let map = HerdrKeymap.defaults
        XCTAssertEqual(map.prefix, chord("b", ctrl: true))
        XCTAssertEqual(map.match(chord("c"), prefixArmed: true), KeyMatch(action: .newTab, index: nil))
        XCTAssertEqual(map.match(chord("minus"), prefixArmed: true), KeyMatch(action: .splitHorizontal, index: nil))
        XCTAssertEqual(map.match(chord("x", shift: true), prefixArmed: true), KeyMatch(action: .closeTab, index: nil))
        XCTAssertNil(map.match(chord("c"), prefixArmed: false), "prefixed bindings need the prefix first")
    }

    func testWorkspaceManagementDefaults() {
        let map = HerdrKeymap.parse(userConfig)   // the user config does not set these
        XCTAssertEqual(map.match(chord("n", shift: true), prefixArmed: true), KeyMatch(action: .newWorkspace, index: nil))
        XCTAssertEqual(map.match(chord("w", shift: true), prefixArmed: true), KeyMatch(action: .renameWorkspace, index: nil))
        XCTAssertEqual(map.match(chord("d", shift: true), prefixArmed: true), KeyMatch(action: .closeWorkspace, index: nil))
        XCTAssertEqual(map.match(chord("n"), prefixArmed: true), KeyMatch(action: .nextTab, index: nil), "unshifted n stays next_tab")
    }

    func testPickerAndGotoDefaults() {
        let map = HerdrKeymap.parse(userConfig)
        XCTAssertEqual(map.match(chord("w"), prefixArmed: true), KeyMatch(action: .workspacePicker, index: nil))
        XCTAssertEqual(map.match(chord("g"), prefixArmed: true), KeyMatch(action: .goto, index: nil))
    }

    func testParsesUserConfigOverDefaults() {
        let map = HerdrKeymap.parse(userConfig)
        XCTAssertEqual(map.prefix, chord("a", ctrl: true))
        XCTAssertEqual(map.match(chord("s"), prefixArmed: true), KeyMatch(action: .splitHorizontal, index: nil))
        XCTAssertEqual(map.match(chord("["), prefixArmed: true), KeyMatch(action: .toggleSidebar, index: nil))
        // Untouched actions keep herdr's defaults.
        XCTAssertEqual(map.match(chord("v"), prefixArmed: true), KeyMatch(action: .splitVertical, index: nil))
        // Replaced default is gone: prefix+minus no longer splits horizontally.
        XCTAssertNil(map.match(chord("minus"), prefixArmed: true))
    }

    func testDigitRangesCarryTheIndex() {
        let map = HerdrKeymap.parse(userConfig)
        XCTAssertEqual(map.match(chord("3"), prefixArmed: true), KeyMatch(action: .switchTab, index: 3))
        XCTAssertEqual(map.match(chord("7", ctrl: true), prefixArmed: false), KeyMatch(action: .switchWorkspace, index: 7))
        XCTAssertNil(map.match(chord("0"), prefixArmed: true))
        XCTAssertNil(map.match(chord("7"), prefixArmed: false))
    }

    func testListsAndDirectChordsAndUnbinding() {
        let map = HerdrKeymap.parse("""
        [keys]
        focus_pane_left = ["prefix+h", "ctrl+alt+h"]
        zoom = ""
        next_tab = []
        """)
        XCTAssertEqual(map.match(chord("h"), prefixArmed: true), KeyMatch(action: .focusPaneLeft, index: nil))
        XCTAssertEqual(
            map.match(chord("h", ctrl: true, alt: true), prefixArmed: false),
            KeyMatch(action: .focusPaneLeft, index: nil)
        )
        XCTAssertNil(map.match(chord("z"), prefixArmed: true), "empty string unbinds")
        XCTAssertNil(map.match(chord("n"), prefixArmed: true), "empty list unbinds")
    }

    func testOnlyTheKeysSectionIsRead() {
        let map = HerdrKeymap.parse("""
        [ui]
        zoom = "prefix+q"
        [keys.indexed]
        tabs = "alt+1..9"
        """)
        XCTAssertEqual(map, HerdrKeymap.defaults)
    }

    func testCommentsAndGarbageDoNotCrash() {
        let map = HerdrKeymap.parse("""
        [keys]
        # zoom = "prefix+q"
        zoom = "prefix+z" # trailing comment
        new_tab = "???+"
        close_pane
        """)
        XCTAssertEqual(map.match(chord("z"), prefixArmed: true), KeyMatch(action: .zoom, index: nil))
    }

    // MARK: prefix state machine

    func testPrefixThenActionThenBackToIdle() {
        let map = HerdrKeymap.parse(userConfig)
        var machine = KeyPrefixMachine()
        XCTAssertEqual(machine.handle(chord("a", ctrl: true), keymap: map), .swallow)
        XCTAssertEqual(machine.handle(chord("c"), keymap: map), .perform(.newTab, index: nil))
        XCTAssertEqual(machine.handle(chord("c"), keymap: map), .passThrough, "prefix is spent after one key")
    }

    func testPrefixTwiceSendsTheLiteralPrefix() {
        let map = HerdrKeymap.parse(userConfig)
        var machine = KeyPrefixMachine()
        _ = machine.handle(chord("a", ctrl: true), keymap: map)
        XCTAssertEqual(machine.handle(chord("a", ctrl: true), keymap: map), .sendLiteralPrefix)
        XCTAssertEqual(machine.handle(chord("z"), keymap: map), .passThrough)
    }

    func testUnknownKeyAfterPrefixIsSwallowedAndEscCancels() {
        let map = HerdrKeymap.parse(userConfig)
        var machine = KeyPrefixMachine()
        _ = machine.handle(chord("a", ctrl: true), keymap: map)
        XCTAssertEqual(machine.handle(chord("q"), keymap: map), .swallow)
        XCTAssertEqual(machine.handle(chord("q"), keymap: map), .passThrough)
        _ = machine.handle(chord("a", ctrl: true), keymap: map)
        XCTAssertEqual(machine.handle(chord("esc"), keymap: map), .swallow)
        XCTAssertEqual(machine.handle(chord("c"), keymap: map), .passThrough)
    }

    func testDirectChordWorksWithoutPrefix() {
        let map = HerdrKeymap.parse(userConfig)
        var machine = KeyPrefixMachine()
        XCTAssertEqual(
            machine.handle(chord("2", ctrl: true), keymap: map),
            .perform(.switchWorkspace, index: 2)
        )
    }

    func testCancelDisarms() {
        let map = HerdrKeymap.parse(userConfig)
        var machine = KeyPrefixMachine()
        _ = machine.handle(chord("a", ctrl: true), keymap: map)
        machine.cancel()
        XCTAssertEqual(machine.handle(chord("c"), keymap: map), .passThrough)
    }
}
