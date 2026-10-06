import Foundation

/// One usage window (5h, 7d, …) or the context fill, as a percentage.
public struct UsageWindow: Equatable, Hashable, Sendable {
    /// The label the plugin printed (`5h`, `7d`), or `context`.
    public let label: String
    /// Percent used, clamped to 0...100.
    public let percent: Double
    /// Time until the window resets as the plugin printed it (`3h21m`).
    public let resetsIn: String?

    public init(label: String, percent: Double, resetsIn: String? = nil) {
        self.label = label
        self.percent = min(max(percent, 0), 100)
        self.resetsIn = resetsIn
    }

    /// `5h` → "5 hours", `7d` → "7 days", `1d`/`24h` → "Daily", `1w` → "Weekly".
    public var title: String {
        let lower = label.lowercased()
        if lower == "context" || lower == "cx" { return "Context" }
        guard let unit = lower.last, let count = Int(lower.dropLast()) else { return label }
        switch (count, unit) {
        case (1, "d"), (24, "h"): return "Daily"
        case (1, "w"): return "Weekly"
        case (_, "h"): return "\(count) hour\(count == 1 ? "" : "s")"
        case (_, "d"): return "\(count) day\(count == 1 ? "" : "s")"
        case (_, "w"): return "\(count) week\(count == 1 ? "" : "s")"
        default: return label
        }
    }
}

/// What the usage popup shows for an agent: its usage windows plus the
/// account, model and context fill, all read off the pane `tokens` that
/// grazr / herdr-agent-quota / herdr-agent-usage publish (see `AgentStatsLine`).
/// `nil` when the agent publishes no usage window — nothing to show then.
///
/// Every percentage here is *used*. The herdr-agent-usage plugin can print
/// quota remaining instead (its default) and tags the lowest remaining window
/// in `quota_headroom`, so a window matching it tells which way it is printing.
public struct AgentUsage: Equatable, Sendable {
    public let account: String?
    public let model: String?
    public let context: UsageWindow?
    public let windows: [UsageWindow]

    public init?(tokens: [String: String]) {
        func value(_ key: String) -> String? {
            guard let raw = tokens[key] else { return nil }
            let trimmed = raw.replacingOccurrences(of: "\u{200b}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func first(_ keys: [String]) -> String? { keys.lazy.compactMap(value).first }
        func severities(_ stem: String) -> [String] {
            ["normal", "warning", "danger", "unknown"].map { "\(stem)_\($0)" }
        }

        let fromGrazr = value("claude_usage")
        var windows: [UsageWindow]
        if let fromGrazr {
            windows = fromGrazr.components(separatedBy: " \u{b7} ").compactMap(Self.parse)
        } else {
            windows = [first(severities("quota_5h")), first(severities("quota_week"))]
                .compactMap { $0.flatMap(Self.parse) }
        }
        guard !windows.isEmpty else { return nil }

        var context: UsageWindow?
        if let text = value("claude_ctx") {
            context = text.components(separatedBy: " \u{b7} ").compactMap(Self.parse)
                .first { $0.label.lowercased() == "context" }
        } else if let text = first(severities("quota_context") + ["quota_context"]) {
            context = Self.parse(text).map { UsageWindow(label: "context", percent: $0.percent, resetsIn: nil) }
        }

        // Plugin-published (quota_*) values may be remaining; grazr's are used.
        if fromGrazr == nil, Self.printsRemaining(windows: windows, headroom: value("quota_headroom")) {
            windows = windows.map { UsageWindow(label: $0.label, percent: 100 - $0.percent, resetsIn: $0.resetsIn) }
            context = context.map { UsageWindow(label: $0.label, percent: 100 - $0.percent, resetsIn: nil) }
        }
        self.windows = windows
        self.context = context
        account = value("grazr")
        model = first(["claude_model", "quota_model", "quota_provider_model"])
    }

    /// True when a window shows the lowest remaining percent (`quota_headroom`)
    /// rather than its complement. Without a headroom token, assume used.
    private static func printsRemaining(windows: [UsageWindow], headroom: String?) -> Bool {
        guard let headroom, let remaining = Double(headroom) else { return false }
        let shownRemaining = windows.contains { abs($0.percent - remaining) < 0.5 }
        let shownUsed = windows.contains { abs($0.percent - (100 - remaining)) < 0.5 }
        return shownRemaining && !shownUsed
    }

    /// `5h 7% 3h21m` or `5h  ▰▰▰▰▰▱  97% 4h47m` → label, percent, optional
    /// reset. Bar glyphs are dropped; segments that do not look like that
    /// are skipped.
    static func parse(_ segment: String) -> UsageWindow? {
        let barGlyphs: Set<Character> = ["\u{25b0}", "\u{25b1}"]
        let parts = segment.split(separator: " ", omittingEmptySubsequences: true)
            .filter { !$0.allSatisfy(barGlyphs.contains) }
        guard parts.count >= 2, parts[1].hasSuffix("%"),
              let percent = Double(parts[1].dropLast())
        else { return nil }
        let reset = parts.count > 2 ? parts.dropFirst(2).joined(separator: " ") : nil
        return UsageWindow(label: String(parts[0]), percent: percent, resetsIn: reset)
    }
}
