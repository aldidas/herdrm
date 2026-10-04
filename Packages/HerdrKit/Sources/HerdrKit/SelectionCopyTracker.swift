import Foundation

/// Decides when a finished mouse selection deserves a "Copied" notice: once per
/// distinct selection, not on every later click while it is still highlighted.
public struct SelectionCopyTracker: Sendable {
    private var last: String?

    public init() {}

    public mutating func shouldAnnounce(selection: String?) -> Bool {
        guard let selection, !selection.isEmpty else {
            last = nil
            return false
        }
        guard selection != last else { return false }
        last = selection
        return true
    }
}
