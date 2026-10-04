import Foundation

/// Where to land when the user switches to a space: back where they were, else
/// on herdr's active tab for it. nil means "no opinion" and the caller falls
/// back to its own default.
public enum SpaceLanding {
    public static func paneToSelect(
        remembered: String?,
        existingPaneIDs: Set<String>,
        activeTabID: String?,
        agentPanes: [(paneID: String, tabID: String?)],
        terminalPanes: [(paneID: String, tabID: String?)]
    ) -> String? {
        if let remembered, existingPaneIDs.contains(remembered) { return remembered }
        guard let activeTabID else { return nil }
        return TabSelection.paneToSelect(tabID: activeTabID, agentPanes: agentPanes, terminalPanes: terminalPanes)
    }
}
