import CryptoKit
import Foundation

public struct DeviceID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    public init?(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isPlausible(normalized) else { return nil }
        self.rawValue = normalized
    }

    /// Parses user-entered or scanned Syncthing IDs and returns the same
    /// canonical eight-by-seven representation emitted by the pinned core.
    /// The permissive `rawValue` initializer remains available for internal
    /// test fixtures; external input must use this checksum-validating path.
    public init?(syncthingString: String) {
        var compact =
            syncthingString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "0", with: "O")
            .replacingOccurrences(of: "1", with: "I")
            .replacingOccurrences(of: "8", with: "B")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        let payload: [UInt8]
        switch compact.utf8.count {
        case 52:
            payload = Array(compact.utf8)
        case 56:
            let checked = Array(compact.utf8)
            var decoded: [UInt8] = []
            decoded.reserveCapacity(52)
            for group in 0..<4 {
                let start = group * 14
                let body = Array(checked[start..<(start + 13)])
                guard let expected = Self.checkDigit(for: body), checked[start + 13] == expected else {
                    return nil
                }
                decoded.append(contentsOf: body)
            }
            payload = decoded
        default:
            return nil
        }

        guard payload.allSatisfy({ Self.base32Alphabet.contains($0) }) else { return nil }
        var checked: [UInt8] = []
        checked.reserveCapacity(56)
        for group in 0..<4 {
            let body = Array(payload[(group * 13)..<((group + 1) * 13)])
            guard let digit = Self.checkDigit(for: body) else { return nil }
            checked.append(contentsOf: body)
            checked.append(digit)
        }
        compact = String(decoding: checked, as: UTF8.self)
        self.rawValue = stride(from: 0, to: compact.count, by: 7).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: 7)
            return String(compact[start..<end])
        }.joined(separator: "-")
    }

    public var description: String { rawValue }

    private static func isPlausible(_ value: String) -> Bool {
        let compact = value.replacingOccurrences(of: "-", with: "")
        guard compact.count == 56 else { return false }
        return compact.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (50...55).contains(byte)
        }
    }

    private static func checkDigit(for bytes: [UInt8]) -> UInt8? {
        var factor = 1
        var sum = 0
        for byte in bytes {
            guard let codepoint = base32Alphabet.firstIndex(of: byte) else { return nil }
            let addend = factor * codepoint
            factor = factor == 2 ? 1 : 2
            sum += (addend / 32) + (addend % 32)
        }
        return base32Alphabet[(32 - (sum % 32)) % 32]
    }
}

public struct FolderID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64 else { return nil }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.rawValue = value
    }

    public var description: String { rawValue }
}

/// Stable File Provider identities for the active aggregate location and the
/// obsolete per-share domains removed during migration. Share folder items use
/// the same opaque digest material without exposing the raw Syncthing folder ID.
public enum FileProviderDomainIdentity {
    public static let legacyAggregateIdentifier = "psynguechthyngue"
    public static let sharePrefix = "share-v1-"

    public static func identifier(for folderID: FolderID) -> String {
        let digest = SHA256.hash(data: Data(folderID.rawValue.utf8))
        return sharePrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func folderItemIdentifier(for folderID: FolderID) -> String {
        let digest = SHA256.hash(data: Data(folderID.rawValue.utf8))
        return "folder-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func folder(
        in snapshot: CoreSnapshot,
        matching identifier: String
    ) -> FolderRecord? {
        guard identifier.hasPrefix(sharePrefix) else { return nil }
        let matches = UniqueFolderIdentityIndex(snapshot.folders).uniqueFolders.filter {
            self.identifier(for: $0.id) == identifier
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

public enum DeviceConnectionState: String, Codable, CaseIterable, Sendable {
    case disconnected
    case connecting
    case connected
    case paused
    case blocked
    case error
}

public enum FolderType: String, Codable, CaseIterable, Sendable {
    case sendReceive
    case sendOnly
    case receiveOnly
    case receiveEncrypted
}

public enum ContentSelectionMode: String, Codable, CaseIterable, Sendable {
    case full
    case manual
    case rules
    case indexOnly
}

public enum FileAvailability: String, Codable, CaseIterable, Sendable {
    case local
    case remoteOnly
    case downloading
    case uploading
    case conflict
    case ignored
    case error
}

public struct DeviceRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: DeviceID
    public var name: String
    public var addresses: [String]
    public var state: DeviceConnectionState
    public var isPaused: Bool
    public var lastSeen: Date?
    public var uploadBytesPerSecond: Int64
    public var downloadBytesPerSecond: Int64
    public var pendingBytes: Int64
    public var blockingReason: String?

    public init(
        id: DeviceID,
        name: String,
        addresses: [String] = ["dynamic"],
        state: DeviceConnectionState = .disconnected,
        isPaused: Bool = false,
        lastSeen: Date? = nil,
        uploadBytesPerSecond: Int64 = 0,
        downloadBytesPerSecond: Int64 = 0,
        pendingBytes: Int64 = 0,
        blockingReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.state = state
        self.isPaused = isPaused
        self.lastSeen = lastSeen
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.pendingBytes = pendingBytes
        self.blockingReason = blockingReason
    }
}

public struct FolderRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: FolderID
    public var label: String
    public var localPath: String
    public var type: FolderType
    public var selectionMode: ContentSelectionMode
    public var isPaused: Bool
    /// Configured remote peers for this folder. `nil` means the persisted
    /// snapshot predates authoritative device projection; it must never be
    /// interpreted as an empty, local-only device set.
    public var deviceIDs: [DeviceID]?
    /// Authoritative bridge configuration value. `nil` means the snapshot was
    /// produced by an older bridge and cannot prove a requested interval.
    public var rescanIntervalS: Int?
    public var pendingUploadBytes: Int64
    public var pendingDownloadBytes: Int64
    public var error: String?

    public init(
        id: FolderID,
        label: String,
        localPath: String,
        type: FolderType = .sendReceive,
        selectionMode: ContentSelectionMode = .full,
        isPaused: Bool = false,
        deviceIDs: [DeviceID]? = nil,
        rescanIntervalS: Int? = nil,
        pendingUploadBytes: Int64 = 0,
        pendingDownloadBytes: Int64 = 0,
        error: String? = nil
    ) {
        self.id = id
        self.label = label
        self.localPath = localPath
        self.type = type
        self.selectionMode = selectionMode
        self.isPaused = isPaused
        self.deviceIDs = deviceIDs
        self.rescanIntervalS = rescanIntervalS
        self.pendingUploadBytes = pendingUploadBytes
        self.pendingDownloadBytes = pendingDownloadBytes
        self.error = error
    }
}

public struct IndexedItem: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var folderID: FolderID
    public var parentID: String?
    public var relativePath: String
    public var isDirectory: Bool
    public var size: Int64
    public var modifiedAt: Date
    public var contentVersion: Data
    public var metadataVersion: Data
    public var availability: FileAvailability
    public var isPinned: Bool
    public var hasUnuploadedChanges: Bool
    public var remoteReplicaCount: Int
    public var generation: UInt64

    /// App-level release eligibility for this exact indexed version. The
    /// bridge is responsible for making `remoteReplicaCount` an exact,
    /// persisted proof for the current version; eviction code consumes only
    /// this result and does not duplicate version/conflict/block checks.
    public var isUploaded: Bool {
        !isDirectory
            && !contentVersion.isEmpty
            && remoteReplicaCount > 0
            && !hasUnuploadedChanges
            && availability != .uploading
            && availability != .conflict
            && availability != .ignored
            && availability != .error
    }

    public var isUploading: Bool {
        !isDirectory && (hasUnuploadedChanges || availability == .uploading)
    }

    public init(
        id: String,
        folderID: FolderID,
        parentID: String? = nil,
        relativePath: String,
        isDirectory: Bool,
        size: Int64 = 0,
        modifiedAt: Date,
        contentVersion: Data,
        metadataVersion: Data,
        availability: FileAvailability,
        isPinned: Bool = false,
        hasUnuploadedChanges: Bool = false,
        remoteReplicaCount: Int = 0,
        generation: UInt64 = 0
    ) {
        self.id = id
        self.folderID = folderID
        self.parentID = parentID
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.availability = availability
        self.isPinned = isPinned
        self.hasUnuploadedChanges = hasUnuploadedChanges
        self.remoteReplicaCount = remoteReplicaCount
        self.generation = generation
    }
}

public struct IndexTombstone: Codable, Hashable, Sendable {
    public var itemID: String
    public var generation: UInt64

    public init(itemID: String, generation: UInt64) {
        self.itemID = itemID
        self.generation = generation
    }
}

public enum PendingDeviceObservationScope: String, Codable, CaseIterable, Sendable {
    /// The offer was observed from Syncthing bridge events and the minimal
    /// projection was persisted across process restarts.
    case bridgeEventsPersisted
    /// The bridge could only retain the event projection in memory. A process
    /// restart can therefore make an offer disappear until it is observed again.
    case bridgeEventsMemoryOnly
    /// The bridge cannot currently provide an authoritative pending-device view.
    case unavailable
}

public enum PendingOfferValidationError: Error, Hashable, Sendable {
    case invalidLabel
    case invalidOfferVersion
    case invalidSuppressionVersion
    case unsafeRiskContract
}

public struct PendingDeviceOffer: Codable, Hashable, Sendable, Identifiable {
    public var id: DeviceID { deviceID }
    public let deviceID: DeviceID
    public let label: String
    public let lastSeen: Date
    public let offerVersion: String
    public let unverifiedIdentity: Bool
    public let requiresExplicitAcceptance: Bool

    public init(
        deviceID: DeviceID,
        label: String,
        lastSeen: Date,
        offerVersion: String,
        unverifiedIdentity: Bool,
        requiresExplicitAcceptance: Bool
    ) throws {
        guard Self.isSafeLabel(label) else {
            throw PendingOfferValidationError.invalidLabel
        }
        guard Self.isCanonicalOfferVersion(offerVersion) else {
            throw PendingOfferValidationError.invalidOfferVersion
        }
        guard unverifiedIdentity, requiresExplicitAcceptance else {
            throw PendingOfferValidationError.unsafeRiskContract
        }
        self.deviceID = deviceID
        self.label = label
        self.lastSeen = lastSeen
        self.offerVersion = offerVersion
        self.unverifiedIdentity = unverifiedIdentity
        self.requiresExplicitAcceptance = requiresExplicitAcceptance
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case label
        case lastSeen
        case offerVersion
        case unverifiedIdentity
        case requiresExplicitAcceptance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                deviceID: container.decode(DeviceID.self, forKey: .deviceID),
                label: container.decode(String.self, forKey: .label),
                lastSeen: container.decode(Date.self, forKey: .lastSeen),
                offerVersion: container.decode(String.self, forKey: .offerVersion),
                unverifiedIdentity: container.decode(Bool.self, forKey: .unverifiedIdentity),
                requiresExplicitAcceptance: container.decode(Bool.self, forKey: .requiresExplicitAcceptance)
            )
        } catch let error as PendingOfferValidationError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath, debugDescription: "Invalid pending-device offer",
                    underlyingError: error)
            )
        }
    }

    fileprivate static func isSafeLabel(_ value: String) -> Bool {
        value.utf8.count <= 256
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func isCanonicalOfferVersion(_ value: String) -> Bool {
        guard value.utf8.count == 43,
            value.utf8.allSatisfy({ byte in
                (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || (48...57).contains(byte)
                    || byte == 45
                    || byte == 95
            })
        else {
            return false
        }
        let base64 =
            value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let decoded = Data(base64Encoded: base64), decoded.count == 32 else {
            return false
        }
        return decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") == value
    }
}

public struct PendingFolderOffer: Codable, Hashable, Sendable, Identifiable {
    public enum EvidenceSource: String, Codable, Hashable, Sendable {
        case live
        case durableSummary
    }

    public struct Identifier: Hashable, Sendable {
        public let folderID: FolderID
        public let offeringDeviceID: DeviceID
    }

    public var id: Identifier { Identifier(folderID: folderID, offeringDeviceID: offeringDeviceID) }
    public let folderID: FolderID
    public let label: String
    public let offeringDeviceID: DeviceID
    public let lastSeen: Date
    public let offerVersion: String
    public let receiveEncrypted: Bool
    public let remoteEncrypted: Bool
    public let requiresManagedLocalPath: Bool
    public let requiresExplicitDeviceSelection: Bool
    public let evidenceSource: EvidenceSource
    public let requiresNetworkRevalidation: Bool

    public var advertisesEncryption: Bool { receiveEncrypted || remoteEncrypted }
    public var hasInvalidEncryptionContract: Bool { receiveEncrypted && remoteEncrypted }
    public var supportsReceiveEncryptedAcceptance: Bool {
        advertisesEncryption && !hasInvalidEncryptionContract
    }

    public init(
        folderID: FolderID,
        label: String,
        offeringDeviceID: DeviceID,
        lastSeen: Date,
        offerVersion: String,
        receiveEncrypted: Bool,
        remoteEncrypted: Bool,
        requiresManagedLocalPath: Bool,
        requiresExplicitDeviceSelection: Bool,
        evidenceSource: EvidenceSource = .live,
        requiresNetworkRevalidation: Bool = false
    ) throws {
        guard PendingDeviceOffer.isSafeLabel(label) else {
            throw PendingOfferValidationError.invalidLabel
        }
        guard PendingDeviceOffer.isCanonicalOfferVersion(offerVersion) else {
            throw PendingOfferValidationError.invalidOfferVersion
        }
        guard requiresManagedLocalPath, requiresExplicitDeviceSelection else {
            throw PendingOfferValidationError.unsafeRiskContract
        }
        guard
            (evidenceSource == .live && !requiresNetworkRevalidation)
                || (evidenceSource == .durableSummary && requiresNetworkRevalidation)
        else {
            throw PendingOfferValidationError.unsafeRiskContract
        }
        self.folderID = folderID
        self.label = label
        self.offeringDeviceID = offeringDeviceID
        self.lastSeen = lastSeen
        self.offerVersion = offerVersion
        self.receiveEncrypted = receiveEncrypted
        self.remoteEncrypted = remoteEncrypted
        self.requiresManagedLocalPath = requiresManagedLocalPath
        self.requiresExplicitDeviceSelection = requiresExplicitDeviceSelection
        self.evidenceSource = evidenceSource
        self.requiresNetworkRevalidation = requiresNetworkRevalidation
    }

    private enum CodingKeys: String, CodingKey {
        case folderID
        case label
        case offeringDeviceID
        case lastSeen
        case offerVersion
        case receiveEncrypted
        case remoteEncrypted
        case requiresManagedLocalPath
        case requiresExplicitDeviceSelection
        case evidenceSource
        case requiresNetworkRevalidation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasEvidenceSource = container.contains(.evidenceSource)
        let hasRevalidation = container.contains(.requiresNetworkRevalidation)
        guard hasEvidenceSource == hasRevalidation else {
            throw DecodingError.dataCorruptedError(
                forKey: hasEvidenceSource ? .requiresNetworkRevalidation : .evidenceSource,
                in: container,
                debugDescription: "Pending-folder evidence fields must be present together"
            )
        }
        let evidenceSource: EvidenceSource
        let requiresNetworkRevalidation: Bool
        if hasEvidenceSource {
            evidenceSource = try container.decode(EvidenceSource.self, forKey: .evidenceSource)
            requiresNetworkRevalidation = try container.decode(
                Bool.self,
                forKey: .requiresNetworkRevalidation
            )
        } else {
            // Legacy snapshots did not distinguish live evidence from a
            // durable summary. Treat every such offer as non-authoritative and
            // require a fresh network observation before any decision.
            evidenceSource = .durableSummary
            requiresNetworkRevalidation = true
        }
        do {
            try self.init(
                folderID: container.decode(FolderID.self, forKey: .folderID),
                label: container.decode(String.self, forKey: .label),
                offeringDeviceID: container.decode(DeviceID.self, forKey: .offeringDeviceID),
                lastSeen: container.decode(Date.self, forKey: .lastSeen),
                offerVersion: container.decode(String.self, forKey: .offerVersion),
                receiveEncrypted: container.decode(Bool.self, forKey: .receiveEncrypted),
                remoteEncrypted: container.decode(Bool.self, forKey: .remoteEncrypted),
                requiresManagedLocalPath: container.decode(Bool.self, forKey: .requiresManagedLocalPath),
                requiresExplicitDeviceSelection: container.decode(Bool.self, forKey: .requiresExplicitDeviceSelection),
                evidenceSource: evidenceSource,
                requiresNetworkRevalidation: requiresNetworkRevalidation
            )
        } catch let error as PendingOfferValidationError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath, debugDescription: "Invalid pending-folder offer",
                    underlyingError: error)
            )
        }
    }
}

/// Minimal persisted projection of an ignored pending-device request. Labels,
/// addresses, and other untrusted discovery metadata are deliberately absent.
public struct SuppressedPendingDevice: Codable, Hashable, Sendable, Identifiable {
    public var id: DeviceID { deviceID }
    public let deviceID: DeviceID
    public let suppressionVersion: String

    public init(deviceID: DeviceID, suppressionVersion: String) throws {
        guard PendingDeviceOffer.isCanonicalOfferVersion(suppressionVersion) else {
            throw PendingOfferValidationError.invalidSuppressionVersion
        }
        self.deviceID = deviceID
        self.suppressionVersion = suppressionVersion
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case suppressionVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                deviceID: container.decode(DeviceID.self, forKey: .deviceID),
                suppressionVersion: container.decode(String.self, forKey: .suppressionVersion)
            )
        } catch let error as PendingOfferValidationError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid suppressed pending-device record",
                    underlyingError: error
                )
            )
        }
    }
}

/// Minimal persisted projection of an ignored pending-folder offer. The pair
/// is the Syncthing identity of an offer; remote labels and paths are excluded.
public struct SuppressedPendingFolder: Codable, Hashable, Sendable, Identifiable {
    public struct Identifier: Hashable, Sendable {
        public let folderID: FolderID
        public let offeringDeviceID: DeviceID
    }

    public var id: Identifier { Identifier(folderID: folderID, offeringDeviceID: offeringDeviceID) }
    public let folderID: FolderID
    public let offeringDeviceID: DeviceID
    public let suppressionVersion: String

    public init(
        folderID: FolderID,
        offeringDeviceID: DeviceID,
        suppressionVersion: String
    ) throws {
        guard PendingDeviceOffer.isCanonicalOfferVersion(suppressionVersion) else {
            throw PendingOfferValidationError.invalidSuppressionVersion
        }
        self.folderID = folderID
        self.offeringDeviceID = offeringDeviceID
        self.suppressionVersion = suppressionVersion
    }

    private enum CodingKeys: String, CodingKey {
        case folderID
        case offeringDeviceID
        case suppressionVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                folderID: container.decode(FolderID.self, forKey: .folderID),
                offeringDeviceID: container.decode(DeviceID.self, forKey: .offeringDeviceID),
                suppressionVersion: container.decode(String.self, forKey: .suppressionVersion)
            )
        } catch let error as PendingOfferValidationError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid suppressed pending-folder record",
                    underlyingError: error
                )
            )
        }
    }
}

public struct CoreSnapshot: Codable, Hashable, Sendable {
    /// Syncthing's configuration includes this device. Product pairing and
    /// sharing flows must count only remote peers without changing the
    /// authoritative configuration projection used by the runtime.
    public var remoteDevices: [DeviceRecord] {
        devices.filter { $0.id != localDeviceID }
    }

    public var schemaVersion: Int
    public var generation: UInt64
    /// Set only on the compact File Provider projection. Canonical snapshots
    /// retain their existing generation and complete item tree.
    public var providerMetadataGeneration: UInt64?
    public var ownerEpoch: UInt64?
    public var instanceID: UUID?
    public var generatedAt: Date
    /// Canonical SHA-256 of the exact persisted Syncthing configuration used
    /// to produce this snapshot. Legacy snapshots may not contain it.
    public var configurationRevision: String?
    public var localDeviceID: DeviceID?
    public var devices: [DeviceRecord]
    public var folders: [FolderRecord]
    public var items: [IndexedItem]
    public var tombstones: [IndexTombstone]
    public var pendingDevices: [PendingDeviceOffer]
    public var pendingFolders: [PendingFolderOffer]
    public var pendingDeviceObservationScope: PendingDeviceObservationScope
    public var pendingFoldersAvailable: Bool
    public var pendingFoldersTruncated: Bool
    public var suppressedPendingDevices: [SuppressedPendingDevice]
    public var suppressedPendingFolders: [SuppressedPendingFolder]
    public var suppressedPendingStateAvailable: Bool
    public var suppressedPendingDevicesTruncated: Bool
    public var suppressedPendingFoldersTruncated: Bool

    public init(
        schemaVersion: Int = 1,
        generation: UInt64 = 0,
        ownerEpoch: UInt64? = nil,
        instanceID: UUID? = nil,
        generatedAt: Date = .now,
        configurationRevision: String? = nil,
        localDeviceID: DeviceID? = nil,
        devices: [DeviceRecord] = [],
        folders: [FolderRecord] = [],
        items: [IndexedItem] = [],
        tombstones: [IndexTombstone] = [],
        pendingDevices: [PendingDeviceOffer] = [],
        pendingFolders: [PendingFolderOffer] = [],
        pendingDeviceObservationScope: PendingDeviceObservationScope = .unavailable,
        pendingFoldersAvailable: Bool = false,
        pendingFoldersTruncated: Bool = false,
        suppressedPendingDevices: [SuppressedPendingDevice] = [],
        suppressedPendingFolders: [SuppressedPendingFolder] = [],
        suppressedPendingStateAvailable: Bool = false,
        suppressedPendingDevicesTruncated: Bool = false,
        suppressedPendingFoldersTruncated: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.providerMetadataGeneration = nil
        self.ownerEpoch = ownerEpoch
        self.instanceID = instanceID
        self.generatedAt = generatedAt
        self.configurationRevision = configurationRevision
        self.localDeviceID = localDeviceID
        self.devices = devices
        self.folders = folders
        self.items = items
        self.tombstones = tombstones
        self.pendingDevices = pendingDevices
        self.pendingFolders = pendingFolders
        self.pendingDeviceObservationScope = pendingDeviceObservationScope
        self.pendingFoldersAvailable = pendingFoldersAvailable
        self.pendingFoldersTruncated = pendingFoldersTruncated
        self.suppressedPendingDevices = suppressedPendingDevices
        self.suppressedPendingFolders = suppressedPendingFolders
        self.suppressedPendingStateAvailable = suppressedPendingStateAvailable
        self.suppressedPendingDevicesTruncated = suppressedPendingDevicesTruncated
        self.suppressedPendingFoldersTruncated = suppressedPendingFoldersTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generation
        case providerMetadataGeneration
        case ownerEpoch
        case instanceID
        case generatedAt
        case configurationRevision
        case localDeviceID
        case devices
        case folders
        case items
        case tombstones
        case pendingDevices
        case pendingFolders
        case pendingDeviceObservationScope
        case pendingFoldersAvailable
        case pendingFoldersTruncated
        case suppressedPendingDevices
        case suppressedPendingFolders
        case suppressedPendingStateAvailable
        case suppressedPendingDevicesTruncated
        case suppressedPendingFoldersTruncated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generation = try container.decode(UInt64.self, forKey: .generation)
        providerMetadataGeneration = try container.decodeIfPresent(UInt64.self, forKey: .providerMetadataGeneration)
        ownerEpoch = try container.decodeIfPresent(UInt64.self, forKey: .ownerEpoch)
        instanceID = try container.decodeIfPresent(UUID.self, forKey: .instanceID)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        configurationRevision = try container.decodeIfPresent(
            String.self,
            forKey: .configurationRevision
        )
        if let configurationRevision,
            !CoreSessionDigest.isLowercaseSHA256(configurationRevision)
        {
            throw DecodingError.dataCorruptedError(
                forKey: .configurationRevision,
                in: container,
                debugDescription: "Configuration revision must be a lowercase SHA-256 digest"
            )
        }
        localDeviceID = try container.decodeIfPresent(DeviceID.self, forKey: .localDeviceID)
        devices = try container.decode([DeviceRecord].self, forKey: .devices)
        folders = try container.decode([FolderRecord].self, forKey: .folders)
        items = try container.decode([IndexedItem].self, forKey: .items)
        tombstones = try container.decode([IndexTombstone].self, forKey: .tombstones)
        pendingDevices = try container.decodeIfPresent([PendingDeviceOffer].self, forKey: .pendingDevices) ?? []
        pendingFolders = try container.decodeIfPresent([PendingFolderOffer].self, forKey: .pendingFolders) ?? []
        pendingDeviceObservationScope =
            try container.decodeIfPresent(
                PendingDeviceObservationScope.self,
                forKey: .pendingDeviceObservationScope
            ) ?? .unavailable
        pendingFoldersAvailable =
            try container.decodeIfPresent(Bool.self, forKey: .pendingFoldersAvailable) ?? false
        pendingFoldersTruncated =
            try container.decodeIfPresent(Bool.self, forKey: .pendingFoldersTruncated) ?? false
        suppressedPendingDevices =
            try container.decodeIfPresent(
                [SuppressedPendingDevice].self,
                forKey: .suppressedPendingDevices
            ) ?? []
        suppressedPendingFolders =
            try container.decodeIfPresent(
                [SuppressedPendingFolder].self,
                forKey: .suppressedPendingFolders
            ) ?? []
        suppressedPendingStateAvailable =
            try container.decodeIfPresent(Bool.self, forKey: .suppressedPendingStateAvailable) ?? false
        suppressedPendingDevicesTruncated =
            try container.decodeIfPresent(Bool.self, forKey: .suppressedPendingDevicesTruncated) ?? false
        suppressedPendingFoldersTruncated =
            try container.decodeIfPresent(Bool.self, forKey: .suppressedPendingFoldersTruncated) ?? false

        guard pendingDeviceObservationScope != .unavailable || pendingDevices.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .pendingDevices,
                in: container,
                debugDescription: "Unavailable pending-device state cannot contain offers"
            )
        }
        guard pendingFoldersAvailable || (pendingFolders.isEmpty && !pendingFoldersTruncated) else {
            throw DecodingError.dataCorruptedError(
                forKey: .pendingFolders,
                in: container,
                debugDescription: "Unavailable pending-folder state cannot contain offers or truncation"
            )
        }
        guard
            suppressedPendingStateAvailable
                || (suppressedPendingDevices.isEmpty
                    && suppressedPendingFolders.isEmpty
                    && !suppressedPendingDevicesTruncated
                    && !suppressedPendingFoldersTruncated)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .suppressedPendingStateAvailable,
                in: container,
                debugDescription: "Unavailable suppressed pending state cannot contain records or truncation"
            )
        }
        let configuredDeviceIDs = Set(devices.map(\.id))
        guard pendingDevices.count <= 512,
            Set(pendingDevices.map(\.deviceID)).count == pendingDevices.count,
            pendingDevices.allSatisfy({ $0.deviceID != localDeviceID && !configuredDeviceIDs.contains($0.deviceID) })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .pendingDevices,
                in: container,
                debugDescription: "Pending-device offers must be unique and unconfigured"
            )
        }
        guard pendingFolders.count <= 512,
            Set(pendingFolders.map(\.id)).count == pendingFolders.count,
            pendingFolders.allSatisfy({
                $0.offeringDeviceID != localDeviceID && configuredDeviceIDs.contains($0.offeringDeviceID)
            })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .pendingFolders,
                in: container,
                debugDescription: "Pending-folder offers must be unique and come from configured peers"
            )
        }
        let suppressedDeviceIDs = Set(suppressedPendingDevices.map(\.deviceID))
        guard suppressedPendingDevices.count <= 512,
            suppressedDeviceIDs.count == suppressedPendingDevices.count,
            suppressedPendingDevices.allSatisfy({
                $0.deviceID != localDeviceID && !configuredDeviceIDs.contains($0.deviceID)
            }),
            Set(pendingDevices.map(\.deviceID)).isDisjoint(with: suppressedDeviceIDs)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .suppressedPendingDevices,
                in: container,
                debugDescription:
                    "Suppressed pending devices must be unique, unconfigured, nonlocal, and absent from pending offers"
            )
        }
        let suppressedFolderIDs = Set(suppressedPendingFolders.map(\.id))
        guard suppressedPendingFolders.count <= 512,
            suppressedFolderIDs.count == suppressedPendingFolders.count,
            suppressedPendingFolders.allSatisfy({
                $0.offeringDeviceID != localDeviceID
                    && configuredDeviceIDs.contains($0.offeringDeviceID)
            }),
            suppressedPendingFolders.allSatisfy({ suppressed in
                !pendingFolders.contains(where: {
                    $0.folderID == suppressed.folderID
                        && $0.offeringDeviceID == suppressed.offeringDeviceID
                })
            })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .suppressedPendingFolders,
                in: container,
                debugDescription:
                    "Suppressed pending folders must be unique, come from configured remote peers, and be absent from pending offers"
            )
        }
    }

    public func confirmsSuppression(of offer: PendingDeviceOffer) -> Bool {
        suppressedPendingStateAvailable
            && !pendingDevices.contains(where: { $0.deviceID == offer.deviceID })
            && suppressedPendingDevices.contains(where: { $0.deviceID == offer.deviceID })
    }

    public func confirmsSuppression(of offer: PendingFolderOffer) -> Bool {
        suppressedPendingStateAvailable
            && !pendingFolders.contains(where: { $0.id == offer.id })
            && suppressedPendingFolders.contains(where: {
                $0.folderID == offer.folderID
                    && $0.offeringDeviceID == offer.offeringDeviceID
            })
    }

    public func confirmsFutureRequestsAllowed(for record: SuppressedPendingDevice) -> Bool {
        suppressedPendingStateAvailable
            && !suppressedPendingDevicesTruncated
            && !suppressedPendingDevices.contains(where: { $0.deviceID == record.deviceID })
    }

    public func confirmsFutureRequestsAllowed(for record: SuppressedPendingFolder) -> Bool {
        suppressedPendingStateAvailable
            && !suppressedPendingFoldersTruncated
            && !suppressedPendingFolders.contains(where: { $0.id == record.id })
    }
}
