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
        if lower == "context" { return "Context" }
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
/// grazr / herdr-agent-quota publish (see `AgentStatsLine`). `nil` when the
/// agent publishes no usage window — there is nothing to show then.
public struct AgentUsage: Equatable, Sendable {
    public let account: String?
    public let model: String?
    public let context: UsageWindow?
    public let windows: [UsageWindow]

    public init?(tokens: [String: String]) {
        let lines = AgentStatsLine.lines(from: tokens)
        func text(_ kind: AgentStatsLine.Kind) -> String? {
            lines.first { $0.kind == kind }?.text
        }
        let windows = (text(.usage) ?? "").components(separatedBy: " \u{b7} ").compactMap(Self.parse)
        guard !windows.isEmpty else { return nil }
        self.windows = windows
        account = text(.account)
        model = text(.model)
        // Only the context fill is a gauge; the cache segment is a hit rate.
        context = (text(.context) ?? "").components(separatedBy: " \u{b7} ")
            .compactMap(Self.parse)
            .first { $0.label.lowercased() == "context" }
    }

    /// `5h 7% 3h21m` → label, percent, optional reset. Segments that do not
    /// look like that are skipped.
    static func parse(_ segment: String) -> UsageWindow? {
        let parts = segment.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[1].hasSuffix("%"),
              let percent = Double(parts[1].dropLast())
        else { return nil }
        let reset = parts.count > 2 ? String(parts[2]) : nil
        return UsageWindow(label: String(parts[0]), percent: percent, resetsIn: reset)
    }
}
