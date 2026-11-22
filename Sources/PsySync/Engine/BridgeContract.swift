import Foundation

/// Swift mirror of GoBridge/psybridge. The App and File Provider targets
/// provide concrete adapters over `PsyBridge.xcframework`
/// (`Platform/PsyBridgeAdapter.swift`, WP-A). SwiftPM code depends only on
/// these protocols so it builds and tests on macOS without the xcframework.
public enum BridgeContract {
    /// Must equal `psybridge.APIVersion()`; checked at launch.
    public static let apiVersion: Int64 = 2

    /// Stable error codes (GoBridge/psybridge/errors.go).
    public enum Code: String, Sendable, CaseIterable {
        case notImplemented = "not_implemented"
        case invalidArgument = "invalid_argument"
        case alreadyRunning = "already_running"
        case notRunning = "not_running"
        case identity
        case database
        case config
        case listen
        case stopTimeout = "stop_timeout"
        case fileNotFound = "file_not_found"
        case versionMismatch = "version_mismatch"
        case noPeer = "no_peer"
        case hashMismatch = "hash_mismatch"
        case tooLarge = "too_large"
        case deadline
        case cancelled
        case io
    }

    /// Parses "psy:<code>: <detail>" (the NSError localizedDescription gomobile produces).
    public static func parse(_ message: String) -> (code: Code?, detail: String) {
        guard message.hasPrefix("psy:") else { return (nil, message) }
        let rest = message.dropFirst(4)
        guard let colon = rest.firstIndex(of: ":") else { return (Code(rawValue: String(rest)), "") }
        let code = Code(rawValue: String(rest[..<colon]))
        let detail = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (code, detail)
    }
}

/// Go runtime memory profile (psybridge/runtime.go).
public struct MemoryProfile: Hashable, Sendable {
    public var limitMiB: Int64
    public var gcPercent: Int64

    public init(limitMiB: Int64, gcPercent: Int64) {
        self.limitMiB = limitMiB
        self.gcPercent = gcPercent
    }

    public static let foreground = MemoryProfile(limitMiB: 256, gcPercent: 100)
    public static let background = MemoryProfile(limitMiB: 160, gcPercent: 100)
    public static let restrictedFetch = MemoryProfile(limitMiB: 40, gcPercent: 50)
}

public struct DeviceIdentity: Hashable, Sendable {
    public var certificatePEM: Data
    public var privateKeyPEM: Data
    public var deviceID: DeviceID

    public init(certificatePEM: Data, privateKeyPEM: Data, deviceID: DeviceID) {
        self.certificatePEM = certificatePEM
        self.privateKeyPEM = privateKeyPEM
        self.deviceID = deviceID
    }
}

/// Returned by `SyncthingBridge.start`. `apiKey` lives only in memory.
public struct RESTEndpoint: Hashable, Sendable {
    public var baseURL: URL
    public var apiKey: String
    public var deviceID: DeviceID

    public init(baseURL: URL, apiKey: String, deviceID: DeviceID) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.deviceID = deviceID
    }
}

/// Synchronous, blocking facade over `PsybridgeEngine`. Implementations
/// must be called from a dedicated thread (see `SyncEngine` doc).
public protocol SyncthingBridge: Sendable {
    func generateIdentity() throws -> DeviceIdentity
    func validateDeviceID(_ input: String) throws -> DeviceID
    func applyMemoryProfile(_ profile: MemoryProfile)
    func syncthingVersion() -> String

    /// psybridge.NewEngine + Engine.Start.
    func start(homeDirectory: URL, identity: DeviceIdentity, deviceName: String, timeout: Duration) throws -> RESTEndpoint
    /// Engine.Stop.
    func stop(timeout: Duration) throws
    func onMemoryWarning()

    /// Engine.OpenIndexStream + Next/Close; `next` returns [] when exhausted.
    /// Deleted entries are left out (IndexStream.SetLiveOnly): every consumer
    /// skips them, and a long-lived folder holds far more of them than files.
    func openIndexStream(folder: FolderID) throws -> any GlobalIndexCursor

    /// Engine.FolderIndexState: DB counters (valid while paused) and whether
    /// each peer's index is still arriving. nil = not available (fakes).
    func folderIndexState(folder: FolderID) throws -> FolderIndexState?

    /// psybridge.NewIgnoreMatcher: upstream ignore semantics for `lines`
    /// as a .stignore at `folderRoot`. nil = not available (fakes).
    func ignoreMatcher(folderRoot: URL, lines: [String]) throws -> (any IgnoreMatching)?
}

extension SyncthingBridge {
    public func ignoreMatcher(folderRoot: URL, lines: [String]) throws -> (any IgnoreMatching)? { nil }
    public func folderIndexState(folder: FolderID) throws -> FolderIndexState? { nil }
}

/// Mirror of FolderIndexStateJSON (psybridge/indexstate.go).
public struct FolderIndexState: Hashable, Codable, Sendable {
    public struct Peer: Hashable, Codable, Sendable {
        public var device: String
        /// receiving / awaiting / complete / disconnected
        public var phase: String
        /// Entries received on this connection.
        public var received: Int64
        /// The peer's index entries stored here (deletions included).
        public var entries: Int64
        public var deleted: Int64
        /// Highest sequence of the peer's index we hold.
        public var sequence: Int64

        public init(device: String, phase: String, received: Int64 = 0, entries: Int64 = 0, deleted: Int64 = 0,
                    sequence: Int64 = 0)
        {
            self.device = device
            self.phase = phase
            self.received = received
            self.entries = entries
            self.deleted = deleted
            self.sequence = sequence
        }
    }

    public var globalFiles: Int64 = 0
    public var globalDirectories: Int64 = 0
    public var globalSymlinks: Int64 = 0
    public var globalDeleted: Int64 = 0
    public var globalBytes: Int64 = 0
    public var localFiles: Int64 = 0
    public var localDirectories: Int64 = 0
    public var localSymlinks: Int64 = 0
    public var localDeleted: Int64 = 0
    public var localBytes: Int64 = 0
    public var localSequence: Int64 = 0
    public var peers: [Peer] = []

    public init() {}

    public var globalItems: Int64 { globalFiles + globalDirectories + globalSymlinks }

    /// Changes whenever the folder's global index can have changed (any
    /// device's sequence): the Files projection skips passes over an
    /// unchanged index.
    public var indexFingerprint: String {
        let remote = peers.map { "\($0.device)=\($0.sequence)" }.sorted().joined(separator: ",")
        return "\(localSequence)|\(remote)"
    }
}

/// Whether a folder-relative path is ignored by a set of rules.
public protocol IgnoreMatching: Sendable {
    func isIgnored(_ path: RelativePath) -> Bool
}

public protocol GlobalIndexCursor: AnyObject {
    func next(maxEntries: Int) throws -> [GlobalIndexEntry]
    func close()
}

/// Mirror of IndexEntryJSON (psybridge/index.go).
public struct GlobalIndexEntry: Hashable, Codable, Sendable {
    public enum EntryType: String, Codable, Sendable {
        case file
        case directory
        case symlink
    }

    public var name: RelativePath
    public var type: EntryType
    public var size: Int64
    public var modified: Date
    public var deleted: Bool
    public var invalid: Bool
    public var sequence: Int64
    /// Content+metadata version token (base64 sha256 of version vector).
    public var version: String
    /// Content-only token; empty for directories.
    public var blocksHash: String
    public var localPresent: Bool
    /// Set by LiveSyncEngine (not the bridge): excluded by the user's own
    /// ignore rules on this device — not the on-demand `*` rule. Such paths
    /// never sync here, so they are kept out of the Files list.
    public var userIgnored = false

    private enum CodingKeys: String, CodingKey {
        case name, type, size, modified, deleted, invalid, sequence, version, blocksHash, localPresent
    }

    public init(
        name: RelativePath,
        type: EntryType,
        size: Int64,
        modified: Date,
        deleted: Bool,
        invalid: Bool,
        sequence: Int64,
        version: String,
        blocksHash: String,
        localPresent: Bool
    ) {
        self.name = name
        self.type = type
        self.size = size
        self.modified = modified
        self.deleted = deleted
        self.invalid = invalid
        self.sequence = sequence
        self.version = version
        self.blocksHash = blocksHash
        self.localPresent = localPresent
    }
}
