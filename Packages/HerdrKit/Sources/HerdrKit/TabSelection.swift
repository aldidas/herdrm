import Foundation

/// Which pane a clicked tab should select, and which tab is "active" for a
/// space, resolved from the selection and herdr's own workspace state.
public enum TabSelection {
    public static func paneToSelect(
        tabID: String,
        agentPanes: [(paneID: String, tabID: String?)],
        terminalPanes: [(paneID: String, tabID: String?)]
    ) -> String? {
        agentPanes.first { $0.tabID == tabID }?.paneID
            ?? terminalPanes.first { $0.tabID == tabID }?.paneID
    }

    public static func activeTabID(
        selectedPaneTabID: String?,
        workspaceActiveTabID: String?,
        tabIDs: [String]
    ) -> String? {
        if let selectedPaneTabID, tabIDs.contains(selectedPaneTabID) { return selectedPaneTabID }
        if let workspaceActiveTabID, tabIDs.contains(workspaceActiveTabID) { return workspaceActiveTabID }
        return tabIDs.first
    }
}
