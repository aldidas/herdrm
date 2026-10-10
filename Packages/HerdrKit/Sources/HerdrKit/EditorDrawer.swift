#if os(macOS)
import Foundation

/// A herdr tab on one device — the unit a drawer belongs to.
public struct EditorDrawerKey: Hashable, Sendable {
    public let deviceID: UUID
    public let tabID: String

    public init(deviceID: UUID, tabID: String) {
        self.deviceID = deviceID
        self.tabID = tabID
    }
}

public struct EditorDrawerSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let key: EditorDrawerKey
    /// nvim's working directory. Fixed at creation.
    public let directory: String
    public let socketPath: String
    /// Opened on launch only; later files go over the socket.
    public let initialFile: String?
    public var isVisible: Bool
}

/// Which tabs have a drawer and whether it is showing. Pure value type: the
/// views and processes follow what this says.
public struct EditorDrawerRegistry: Sendable {
    private var byKey: [EditorDrawerKey: EditorDrawerSession] = [:]

    public init() {}

    /// Stable order so SwiftUI's `ForEach` does not reshuffle.
    public var all: [EditorDrawerSession] {
        byKey.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func session(for key: EditorDrawerKey) -> EditorDrawerSession? { byKey[key] }

    /// Shows the tab's drawer, creating it when missing. An existing session
    /// keeps its directory and ignores `initialFile` (that file is opened over RPC).
    @discardableResult
    public mutating func show(
        _ key: EditorDrawerKey,
        directory: String,
        initialFile: String?,
        socketDirectory: String
    ) -> (session: EditorDrawerSession, created: Bool) {
        if var existing = byKey[key] {
            existing.isVisible = true
            byKey[key] = existing
            return (existing, false)
        }
        let id = UUID()
        let session = EditorDrawerSession(
            id: id,
            key: key,
            directory: directory,
            socketPath: socketDirectory + "macherdr-nvim-\(id.uuidString.prefix(8).lowercased()).sock",
            initialFile: initialFile,
            isVisible: true
        )
        byKey[key] = session
        return (session, true)
    }

    public mutating func hide(_ key: EditorDrawerKey) {
        byKey[key]?.isVisible = false
    }

    @discardableResult
    public mutating func remove(id: UUID) -> EditorDrawerSession? {
        guard let entry = byKey.first(where: { $0.value.id == id }) else { return nil }
        byKey[entry.key] = nil
        return entry.value
    }

    /// Removes this device's drawers whose tab no longer exists; returns them so
    /// the caller can delete their sockets.
    public mutating func reconcile(deviceID: UUID, liveTabIDs: Set<String>) -> [EditorDrawerSession] {
        let stale = byKey.values.filter {
            $0.key.deviceID == deviceID && !liveTabIDs.contains($0.key.tabID)
        }
        for session in stale { byKey[session.key] = nil }
        return stale
    }

    /// Deletes `macherdr-nvim-*.sock` left behind by a previous run.
    public static func removeStaleSockets(in directory: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names where name.hasPrefix("macherdr-nvim-") && name.hasSuffix(".sock") {
            try? FileManager.default.removeItem(atPath: directory + name)
        }
    }
}

public enum EditorDrawerLayout {
    public static let defaultRatio = 0.45
    public static let bounds = 0.25...0.7

    public static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, bounds.lowerBound), bounds.upperBound)
    }
}
#endif
