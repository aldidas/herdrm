import Foundation

/// One keystroke: a normalized key name plus modifiers. `key` is a lowercase
/// character (`"a"`, `"1"`, `"["`) or a name (`"tab"`, `"enter"`, `"esc"`,
/// `"space"`, `"minus"`, `"up"`, `"down"`, `"left"`, `"right"`).
public struct KeyChord: Hashable, Sendable {
    public var key: String
    public var ctrl: Bool
    public var alt: Bool
    public var shift: Bool
    public var cmd: Bool

    public init(key: String, ctrl: Bool = false, alt: Bool = false, shift: Bool = false, cmd: Bool = false) {
        self.key = key
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
        self.cmd = cmd
    }

    var hasModifier: Bool { ctrl || alt || cmd }
}

/// The herdr actions MacHerdr can perform. Others herdr defines (copy mode,
/// resize mode, detach, …) have no native equivalent and are not mapped.
public enum HerdrAction: String, CaseIterable, Sendable {
    case switchTab = "switch_tab"
    case nextTab = "next_tab"
    case previousTab = "previous_tab"
    case newTab = "new_tab"
    case renameTab = "rename_tab"
    case closeTab = "close_tab"
    case newWorkspace = "new_workspace"
    case renameWorkspace = "rename_workspace"
    case closeWorkspace = "close_workspace"
    case workspacePicker = "workspace_picker"
    case goto
    case switchWorkspace = "switch_workspace"
    case nextWorkspace = "next_workspace"
    case previousWorkspace = "previous_workspace"
    case focusPaneLeft = "focus_pane_left"
    case focusPaneDown = "focus_pane_down"
    case focusPaneUp = "focus_pane_up"
    case focusPaneRight = "focus_pane_right"
    case cyclePaneNext = "cycle_pane_next"
    case cyclePanePrevious = "cycle_pane_previous"
    case zoom
    case closePane = "close_pane"
    case splitVertical = "split_vertical"
    case splitHorizontal = "split_horizontal"
    case toggleSidebar = "toggle_sidebar"
}

public struct KeyBinding: Hashable, Sendable {
    /// True when the chord must follow the prefix key (`prefix+c`).
    public let prefixed: Bool
    public let chord: KeyChord
    /// For `1..9`-style bindings: the digits accepted (the chord's key is ignored).
    public let digitRange: ClosedRange<Int>?
}

public struct KeyMatch: Equatable, Sendable {
    public let action: HerdrAction
    /// The digit pressed, for range bindings (`switch_tab`, `switch_workspace`).
    public let index: Int?
}

/// herdr's `[keys]` configuration, defaults overlaid with `config.toml`.
public struct HerdrKeymap: Equatable, Sendable {
    public var prefix: KeyChord
    public var bindings: [HerdrAction: [KeyBinding]]

    /// herdr 0.9.3's documented defaults for the actions MacHerdr supports.
    public static let defaults: HerdrKeymap = {
        let table: [(HerdrAction, [String])] = [
            (.switchTab, ["prefix+1..9"]), (.nextTab, ["prefix+n"]), (.previousTab, ["prefix+p"]),
            (.newTab, ["prefix+c"]), (.renameTab, ["prefix+shift+t"]), (.closeTab, ["prefix+shift+x"]),
            (.newWorkspace, ["prefix+shift+n"]), (.renameWorkspace, ["prefix+shift+w"]),
            (.closeWorkspace, ["prefix+shift+d"]),
            (.workspacePicker, ["prefix+w"]), (.goto, ["prefix+g"]),
            (.focusPaneLeft, ["prefix+h"]), (.focusPaneDown, ["prefix+j"]),
            (.focusPaneUp, ["prefix+k"]), (.focusPaneRight, ["prefix+l"]),
            (.cyclePaneNext, ["prefix+tab"]), (.cyclePanePrevious, ["prefix+shift+tab"]),
            (.splitVertical, ["prefix+v"]), (.splitHorizontal, ["prefix+minus"]),
            (.closePane, ["prefix+x"]), (.zoom, ["prefix+z"]), (.toggleSidebar, ["prefix+b"]),
        ]
        var bindings: [HerdrAction: [KeyBinding]] = [:]
        for (action, texts) in table { bindings[action] = texts.compactMap(parseBinding) }
        return HerdrKeymap(prefix: KeyChord(key: "b", ctrl: true), bindings: bindings)
    }()

    /// Reads the `[keys]` table of a herdr `config.toml`. An action named there
    /// keeps only the bindings listed there (`""` or `[]` unbinds it); anything
    /// unparseable is ignored and the default stays.
    public static func parse(_ toml: String) -> HerdrKeymap {
        var map = defaults
        var inKeys = false
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inKeys = line == "[keys]"
                continue
            }
            guard inKeys, let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let texts = quotedStrings(in: value)
            let isEmptyList = value.hasPrefix("[") && texts.isEmpty
            guard !texts.isEmpty || isEmptyList || value == "\"\"" else { continue }
            if name == "prefix" {
                if let first = texts.first, let binding = parseBinding(first),
                   !binding.prefixed, binding.chord.hasModifier, binding.digitRange == nil {
                    map.prefix = binding.chord
                }
            } else if let action = HerdrAction(rawValue: name) {
                let parsed = texts.compactMap(parseBinding)
                if parsed.isEmpty && !(texts.allSatisfy { $0.isEmpty }) { continue }
                map.bindings[action] = parsed
            }
        }
        return map
    }

    /// The action `chord` triggers, given whether the prefix was just pressed.
    public func match(_ chord: KeyChord, prefixArmed: Bool) -> KeyMatch? {
        for action in HerdrAction.allCases {
            for binding in bindings[action] ?? [] where binding.prefixed == prefixArmed {
                let c = binding.chord
                guard c.ctrl == chord.ctrl, c.alt == chord.alt, c.shift == chord.shift, c.cmd == chord.cmd
                else { continue }
                if let range = binding.digitRange {
                    if let digit = Int(chord.key), range.contains(digit) {
                        return KeyMatch(action: action, index: digit)
                    }
                } else if c.key == chord.key {
                    return KeyMatch(action: action, index: nil)
                }
            }
        }
        return nil
    }

    // MARK: Parsing

    /// `prefix+shift+x`, `ctrl+alt+h`, `ctrl+1..9`. A direct (unprefixed)
    /// binding must carry ctrl/alt/cmd: plain keys belong to the terminal.
    static func parseBinding(_ text: String) -> KeyBinding? {
        let tokens = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !tokens.isEmpty, !tokens.contains(where: \.isEmpty) else { return nil }
        let prefixed = tokens.first == "prefix"
        let rest = Array(prefixed ? tokens.dropFirst() : tokens[...])
        guard let keyToken = rest.last else { return nil }
        var chord = KeyChord(key: "")
        for modifier in rest.dropLast() {
            switch modifier {
            case "ctrl", "control": chord.ctrl = true
            case "alt", "option": chord.alt = true
            case "shift": chord.shift = true
            case "cmd", "super": chord.cmd = true
            default: return nil
            }
        }
        var range: ClosedRange<Int>?
        if keyToken.contains(".."), keyToken.split(separator: ".", omittingEmptySubsequences: true).count == 2 {
            let parts = keyToken.components(separatedBy: "..")
            guard parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]), lo <= hi else { return nil }
            range = lo...hi
            chord.key = parts[0]
        } else {
            chord.key = normalizedKey(keyToken)
        }
        if !prefixed && !chord.hasModifier { return nil }
        return KeyBinding(prefixed: prefixed, chord: chord, digitRange: range)
    }

    private static func normalizedKey(_ token: String) -> String {
        switch token {
        case "-": return "minus"
        case "escape": return "esc"
        case "return": return "enter"
        case " ": return "space"
        default: return token
        }
    }

    private static func quotedStrings(in value: String) -> [String] {
        var results: [String] = []
        var current = ""
        var inQuote = false
        for character in value {
            if character == "\"" {
                if inQuote { results.append(current); current = "" }
                inQuote.toggle()
            } else if inQuote {
                current.append(character)
            }
        }
        return results
    }

    /// Drops a trailing `# comment`, ignoring `#` inside quotes.
    private static func stripComment(_ line: String) -> String {
        var inQuote = false
        for index in line.indices {
            if line[index] == "\"" { inQuote.toggle() }
            if line[index] == "#" && !inQuote { return String(line[..<index]) }
        }
        return line
    }
}

/// Prefix-key state machine in front of the keymap: decides, per keystroke,
/// whether the app consumes it or the terminal gets it.
public struct KeyPrefixMachine: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Not ours: deliver to the focused terminal untouched.
        case passThrough
        /// Consumed (the prefix itself, an unmapped key after it, or Esc).
        case swallow
        case perform(HerdrAction, index: Int?)
        /// Prefix pressed twice: deliver the literal prefix key to the terminal.
        case sendLiteralPrefix
    }

    public private(set) var armed = false

    public init() {}

    public mutating func handle(_ chord: KeyChord, keymap: HerdrKeymap) -> Outcome {
        if armed {
            armed = false
            if chord == keymap.prefix { return .sendLiteralPrefix }
            if chord.key == "esc", !chord.hasModifier, !chord.shift { return .swallow }
            if let match = keymap.match(chord, prefixArmed: true) {
                return .perform(match.action, index: match.index)
            }
            return .swallow
        }
        if chord == keymap.prefix {
            armed = true
            return .swallow
        }
        if let match = keymap.match(chord, prefixArmed: false) {
            return .perform(match.action, index: match.index)
        }
        return .passThrough
    }

    public mutating func cancel() { armed = false }
}
