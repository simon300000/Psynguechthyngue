import Foundation

/// Where a folder's files live on this device.
public enum FolderLocation: Hashable, Codable, Sendable {
    /// `<AppGroup>/Folders/<folderID>/` — default; visible in Files via the
    /// File Provider domain; supports on-demand download.
    case managed
    /// A user-picked local directory (security-scoped bookmark), e.g.
    /// "On My iPhone/…" or an external drive. Synced in place; not exposed
    /// through our File Provider domain (it is already visible in Files).
    /// Rejected for locations that are themselves File Provider backed
    /// (iCloud Drive, other cloud apps) — see DESIGN.md §6.7.
    case external(bookmark: Data, displayPath: String)
}

/// Syncthing folder type.
public enum FolderType: String, Codable, Sendable, CaseIterable {
    case sendReceive = "sendreceive"
    case sendOnly = "sendonly"
    case receiveOnly = "receiveonly"
}

/// How much content this device keeps for a managed folder.
public enum ContentMode: String, Codable, Sendable, CaseIterable {
    /// Everything is downloaded (vanilla Syncthing behaviour).
    case everything
    /// Only files the user opened or marked "Keep Downloaded" are local; the
    /// rest are placeholders in Files. Implemented with a generated
    /// `.stignore` (DESIGN.md §6.3).
    case onDemand
}

/// A configured folder (Syncthing `config.folders[]` + app-only attributes).
public struct Folder: Identifiable, Hashable, Codable, Sendable {
    public var id: FolderID
    public var label: String
    public var type: FolderType
    public var location: FolderLocation
    public var contentMode: ContentMode
    public var devices: [DeviceID]
    public var paused: Bool

    public init(
        id: FolderID,
        label: String,
        type: FolderType = .sendReceive,
        location: FolderLocation = .managed,
        contentMode: ContentMode = .everything,
        devices: [DeviceID] = [],
        paused: Bool = false
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.location = location
        self.contentMode = contentMode
        self.devices = devices
        self.paused = paused
    }
}

/// A folder another device offers us (REST `/rest/cluster/pending/folders`).
public struct PendingFolder: Hashable, Codable, Sendable, Identifiable {
    public var id: String { "\(folderID.rawValue)@\(offeredBy.rawValue)" }
    public var folderID: FolderID
    public var label: String
    public var offeredBy: DeviceID
    public var receivedAt: Date

    public init(folderID: FolderID, label: String, offeredBy: DeviceID, receivedAt: Date) {
        self.folderID = folderID
        self.label = label
        self.offeredBy = offeredBy
        self.receivedAt = receivedAt
    }
}
