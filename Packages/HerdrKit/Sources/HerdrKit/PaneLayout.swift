import Foundation

public struct LayoutRect: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
}

public enum LayoutDirection: String, Codable, Sendable {
    /// Children side by side (vertical divider).
    case right
    /// Children stacked (horizontal divider).
    case down
}

/// `pane.layout` result: cell rects for every pane of a tab plus its splits.
public struct PaneLayout: Codable, Sendable, Equatable {
    public struct Pane: Codable, Sendable, Equatable {
        public let paneID: String
        public let focused: Bool
        public let rect: LayoutRect
        enum CodingKeys: String, CodingKey { case paneID = "pane_id", focused, rect }
    }

    public struct Split: Codable, Sendable, Equatable {
        public let id: String
        public let direction: LayoutDirection
        public let ratio: Double
        public let rect: LayoutRect
    }

    public let tabID: String
    public let workspaceID: String
    public let zoomed: Bool
    public let area: LayoutRect
    public let focusedPaneID: String
    public let panes: [Pane]
    public let splits: [Split]

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id", workspaceID = "workspace_id", zoomed, area
        case focusedPaneID = "focused_pane_id", panes, splits
    }
}

public struct UnitRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)
}

public struct SplitDivider: Sendable, Equatable {
    public let id: String
    /// Child choices from the root: `false` = first child, `true` = second.
    public let path: [Bool]
    public let direction: LayoutDirection
    /// The area the split occupies; the divider sits at `ratio` along it.
    public let region: UnitRect
    public let ratio: Double
}

public indirect enum SplitTree: Sendable, Equatable {
    case leaf(paneID: String)
    case split(id: String, direction: LayoutDirection, ratio: Double, first: SplitTree, second: SplitTree)

    public var paneIDs: [String] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, _, let first, let second): return first.paneIDs + second.paneIDs
        }
    }

    // MARK: Build

    /// Rebuilds the binary tree from herdr's flat split list. A group of panes
    /// is claimed by the smallest unused split whose rect contains them all;
    /// that split's direction + ratio then partitions the group by pane center,
    /// which tolerates herdr rounding cell rects by a column or row.
    /// Returns nil when the data cannot be reconciled (caller falls back to
    /// the single selected pane).
    public static func build(from layout: PaneLayout) -> SplitTree? {
        var unused = layout.splits
        return build(group: layout.panes, unused: &unused)
    }

    private static func build(group: [PaneLayout.Pane], unused: inout [PaneLayout.Split]) -> SplitTree? {
        if group.count == 1 { return .leaf(paneID: group[0].paneID) }
        guard group.count > 1 else { return nil }
        let bounds = union(group.map(\.rect))
        let candidates = unused.enumerated()
            .filter { contains($0.element.rect, bounds) }
            .sorted { area($0.element.rect) < area($1.element.rect) }
        guard let (index, split) = candidates.first.map({ ($0.offset, $0.element) }) else { return nil }
        unused.remove(at: index)

        let cut: Double = split.direction == .right
            ? Double(split.rect.x) + Double(split.rect.width) * split.ratio
            : Double(split.rect.y) + Double(split.rect.height) * split.ratio
        var first: [PaneLayout.Pane] = []
        var second: [PaneLayout.Pane] = []
        for pane in group {
            let center: Double = split.direction == .right
                ? Double(pane.rect.x) + Double(pane.rect.width) / 2
                : Double(pane.rect.y) + Double(pane.rect.height) / 2
            if center < cut { first.append(pane) } else { second.append(pane) }
        }
        guard !first.isEmpty, !second.isEmpty,
              let a = build(group: first, unused: &unused),
              let b = build(group: second, unused: &unused)
        else { return nil }
        return .split(id: split.id, direction: split.direction, ratio: split.ratio, first: a, second: b)
    }

    private static func union(_ rects: [LayoutRect]) -> LayoutRect {
        let minX = rects.map(\.x).min() ?? 0
        let minY = rects.map(\.y).min() ?? 0
        let maxX = rects.map { $0.x + $0.width }.max() ?? 0
        let maxY = rects.map { $0.y + $0.height }.max() ?? 0
        return LayoutRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func contains(_ outer: LayoutRect, _ inner: LayoutRect) -> Bool {
        outer.x <= inner.x && outer.y <= inner.y
            && outer.x + outer.width >= inner.x + inner.width
            && outer.y + outer.height >= inner.y + inner.height
    }

    private static func area(_ rect: LayoutRect) -> Int { rect.width * rect.height }

    // MARK: Geometry

    public func frames(in rect: UnitRect = .full) -> [String: UnitRect] {
        switch self {
        case .leaf(let id):
            return [id: rect]
        case .split(_, let direction, let ratio, let first, let second):
            let (a, b) = Self.children(of: rect, direction: direction, ratio: ratio)
            return first.frames(in: a).merging(second.frames(in: b)) { lhs, _ in lhs }
        }
    }

    public func dividers(in rect: UnitRect = .full, path: [Bool] = []) -> [SplitDivider] {
        guard case .split(let id, let direction, let ratio, let first, let second) = self else { return [] }
        let (a, b) = Self.children(of: rect, direction: direction, ratio: ratio)
        return [SplitDivider(id: id, path: path, direction: direction, region: rect, ratio: ratio)]
            + first.dividers(in: a, path: path + [false])
            + second.dividers(in: b, path: path + [true])
    }

    private static func children(of rect: UnitRect, direction: LayoutDirection, ratio: Double) -> (UnitRect, UnitRect) {
        switch direction {
        case .right:
            let w = rect.width * ratio
            return (
                UnitRect(x: rect.x, y: rect.y, width: w, height: rect.height),
                UnitRect(x: rect.x + w, y: rect.y, width: rect.width - w, height: rect.height)
            )
        case .down:
            let h = rect.height * ratio
            return (
                UnitRect(x: rect.x, y: rect.y, width: rect.width, height: h),
                UnitRect(x: rect.x, y: rect.y + h, width: rect.width, height: rect.height - h)
            )
        }
    }
}

extension SplitTree {
    public func contains(paneID: String) -> Bool { paneIDs.contains(paneID) }
}

/// Hands out increasing tokens so an async reply can tell whether a newer
/// request started while it was in flight (stale replies must not apply).
public struct LatestOnlyGate: Sendable {
    private var latest = 0

    public init() {}

    public mutating func begin() -> Int {
        latest += 1
        return latest
    }

    public func isCurrent(_ token: Int) -> Bool { token == latest }
}
