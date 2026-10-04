import AppKit
import Foundation
import GhosttyTheme

/// The user's chosen Ghostty theme (`terminal.theme`; "" = herdrm's built-in
/// palettes). One theme applies in both system appearances, so everything that
/// used to key on light/dark — the light ANSI adapter, the pane background —
/// reads the theme's own background instead.
enum TerminalThemeSetting {
    static let key = "terminal.theme"

    private static let lock = NSLock()
    private static var cache: (name: String, definition: GhosttyThemeDefinition?)?

    static var currentName: String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    static func definition(named name: String) -> GhosttyThemeDefinition? {
        guard !name.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cache, cache.name == name { return cache.definition }
        let found = GhosttyThemeCatalog.theme(named: name)
            ?? GhosttyThemeCatalog.allThemes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        cache = (name, found)
        return found
    }

    static var current: GhosttyThemeDefinition? { definition(named: currentName) }

    /// Catalog names, sorted for the picker.
    static let allNames: [String] = GhosttyThemeCatalog.allThemes.map(\.name).sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }

    /// Pane background for the active theme, or nil for the built-in look.
    static func backgroundColor() -> NSColor? {
        guard let hex = current?.background else { return nil }
        return NSColor(themeHex: hex)
    }
}

extension NSColor {
    convenience init?(themeHex: String) {
        let hex = themeHex.hasPrefix("#") ? String(themeHex.dropFirst()) : themeHex
        guard hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
