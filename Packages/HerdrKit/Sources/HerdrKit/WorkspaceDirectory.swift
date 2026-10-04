import Foundation

/// A workspace has no cwd of its own; its panes do. The first pane with one
/// (agents listed before ordinary terminals by the caller) represents it.
public enum WorkspaceDirectory {
    public static func resolve(
        workspaceID: String,
        candidates: [(workspaceID: String, cwd: String?)]
    ) -> String? {
        candidates.first { $0.workspaceID == workspaceID && !($0.cwd ?? "").isEmpty }?.cwd
    }
}
