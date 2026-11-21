import Foundation

/// Command coverage of the currently bundled mobile bridge.
///
/// Keep this list aligned with `mobilebridge.executeCommandLocked`. Callers use
/// it before persisting work so an unavailable operation cannot later look like
/// a successfully queued request.
public enum CoreBridgeCommandCapability: String, Codable, Hashable, Sendable {
    case supported
    case unsupported
}

extension CoreCommandKind {
    public var embeddedBridgeCapability: CoreBridgeCommandCapability {
        switch self {
        case .addDevice, .editDevice, .removeDevice, .acceptDevice,
            .ignorePendingDevice, .unignorePendingDevice,
            .addFolder, .editFolder, .removeFolder, .acceptFolder,
            .ignorePendingFolder, .unignorePendingFolder,
            .sync, .upload, .download, .exchangeIndex, .pause, .resume, .rescan,
            .evict, .materialize, .pin, .create, .modify, .move, .delete,
            .disposeRecovery, .disposeRecoveryReviewed:
            .supported
        }
    }
}

public enum PendingAcceptanceCommandError: Error, Hashable, Sendable {
    case invalidName
    case invalidManagedPath
    case invalidRescanInterval
    case invalidDeviceSelection
    case offeringDeviceNotSelected
    case invalidEncryptedFolderOffer
    case encryptedFolderTypeMismatch
    case deviceListEncodingFailed
    case observationProofMismatch
    case observationProofExpired
}

public struct PendingAcceptanceCommandConfiguration: Hashable, Sendable {
    public let kind: CoreCommandKind
    public let folderID: FolderID?
    public let itemID: String?
    public let arguments: [String: String]

    public init(
        kind: CoreCommandKind,
        folderID: FolderID?,
        itemID: String?,
        arguments: [String: String]
    ) {
        self.kind = kind
        self.folderID = folderID
        self.itemID = itemID
        self.arguments = arguments
    }
}

/// Builds the exact, narrow JSON-command fields accepted by the pinned Go
/// bridge. Observed peer addresses and remote folder paths are deliberately not
/// inputs, so an untrusted offer cannot be promoted into local configuration.
public enum PendingAcceptanceCommandBuilder {
    public static func device(
        offer: PendingDeviceOffer,
        name: String,
        paused: Bool
    ) throws -> PendingAcceptanceCommandConfiguration {
        let normalizedName = try validatedName(name)
        return PendingAcceptanceCommandConfiguration(
            kind: .acceptDevice,
            folderID: nil,
            itemID: offer.deviceID.rawValue,
            arguments: [
                "offerVersion": offer.offerVersion,
                "name": normalizedName,
                "paused": String(paused),
            ]
        )
    }

    public static func folder(
        offer: PendingFolderOffer,
        observationProof: PendingFolderObservationProof,
        label: String,
        managedPath: String,
        type: FolderType,
        paused: Bool,
        deviceIDs: Set<DeviceID>,
        rescanIntervalS: Int
    ) throws -> PendingAcceptanceCommandConfiguration {
        try validate(observationProof, for: offer)
        guard !offer.hasInvalidEncryptionContract else {
            throw PendingAcceptanceCommandError.invalidEncryptedFolderOffer
        }
        guard offer.advertisesEncryption == (type == .receiveEncrypted) else {
            throw PendingAcceptanceCommandError.encryptedFolderTypeMismatch
        }
        guard deviceIDs.contains(offer.offeringDeviceID) else {
            throw PendingAcceptanceCommandError.offeringDeviceNotSelected
        }
        guard !deviceIDs.isEmpty, deviceIDs.count <= 64 else {
            throw PendingAcceptanceCommandError.invalidDeviceSelection
        }
        guard !offer.advertisesEncryption || deviceIDs == [offer.offeringDeviceID] else {
            throw PendingAcceptanceCommandError.invalidDeviceSelection
        }
        guard (0...(365 * 24 * 60 * 60)).contains(rescanIntervalS) else {
            throw PendingAcceptanceCommandError.invalidRescanInterval
        }
        guard type != .receiveEncrypted || rescanIntervalS == 0 || rescanIntervalS >= 86_400 else {
            throw PendingAcceptanceCommandError.invalidRescanInterval
        }
        guard isSafeAbsolutePath(managedPath) else {
            throw PendingAcceptanceCommandError.invalidManagedPath
        }

        let normalizedLabel = try validatedName(label)
        let selectedIDs = deviceIDs.map(\.rawValue).sorted()
        let encodedDeviceIDs: String
        do {
            let data = try JSONEncoder().encode(selectedIDs)
            guard let value = String(data: data, encoding: .utf8) else {
                throw PendingAcceptanceCommandError.deviceListEncodingFailed
            }
            encodedDeviceIDs = value
        } catch let error as PendingAcceptanceCommandError {
            throw error
        } catch {
            throw PendingAcceptanceCommandError.deviceListEncodingFailed
        }

        var arguments = observationProof.commandArguments
        arguments.merge(
            [
                "label": normalizedLabel,
                "path": managedPath,
                "type": type.rawValue,
                "paused": String(paused),
                "deviceIDs": encodedDeviceIDs,
                "rescanIntervalS": String(rescanIntervalS),
            ],
            uniquingKeysWith: { _, trustedLocalValue in trustedLocalValue }
        )
        return PendingAcceptanceCommandConfiguration(
            kind: .acceptFolder,
            folderID: offer.folderID,
            itemID: nil,
            arguments: arguments
        )
    }

    private static func validate(
        _ proof: PendingFolderObservationProof,
        for offer: PendingFolderOffer
    ) throws {
        guard proof.exactlyMatchesReviewedOffer(offer) else {
            throw PendingAcceptanceCommandError.observationProofMismatch
        }
        guard Date.now < proof.expiresAt else {
            throw PendingAcceptanceCommandError.observationProofExpired
        }
    }

    private static func validatedName(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count <= 256,
            normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw PendingAcceptanceCommandError.invalidName
        }
        return normalized
    }

    private static func isSafeAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value != "/", !value.contains("\0") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .allSatisfy { component in
                !component.isEmpty && component != "." && component != ".."
            }
    }
}

/// Builds the exact compare-and-set commands for durable pending-offer
/// suppression. No advertised label, address, remote path, or encryption
/// metadata can enter these command arguments.
public enum PendingSuppressionCommandBuilder {
    public static func ignoreDevice(
        _ offer: PendingDeviceOffer
    ) -> PendingAcceptanceCommandConfiguration {
        PendingAcceptanceCommandConfiguration(
            kind: .ignorePendingDevice,
            folderID: nil,
            itemID: offer.deviceID.rawValue,
            arguments: ["offerVersion": offer.offerVersion]
        )
    }

    public static func unignoreDevice(
        _ record: SuppressedPendingDevice
    ) -> PendingAcceptanceCommandConfiguration {
        PendingAcceptanceCommandConfiguration(
            kind: .unignorePendingDevice,
            folderID: nil,
            itemID: record.deviceID.rawValue,
            arguments: ["suppressionVersion": record.suppressionVersion]
        )
    }

    public static func ignoreFolder(
        _ offer: PendingFolderOffer,
        observationProof: PendingFolderObservationProof
    ) throws -> PendingAcceptanceCommandConfiguration {
        guard observationProof.exactlyMatchesReviewedOffer(offer) else {
            throw PendingAcceptanceCommandError.observationProofMismatch
        }
        guard Date.now < observationProof.expiresAt else {
            throw PendingAcceptanceCommandError.observationProofExpired
        }
        return PendingAcceptanceCommandConfiguration(
            kind: .ignorePendingFolder,
            folderID: offer.folderID,
            itemID: nil,
            arguments: observationProof.commandArguments
        )
    }

    public static func unignoreFolder(
        _ record: SuppressedPendingFolder
    ) -> PendingAcceptanceCommandConfiguration {
        PendingAcceptanceCommandConfiguration(
            kind: .unignorePendingFolder,
            folderID: record.folderID,
            itemID: nil,
            arguments: [
                "offeringDeviceID": record.offeringDeviceID.rawValue,
                "suppressionVersion": record.suppressionVersion,
            ]
        )
    }
}

extension PendingFolderObservationProof {
    /// The proof may authorize only the exact offer the user reviewed. The
    /// bridge-validated stable offer version cryptographically includes the
    /// native nanosecond `lastSeen` wire value. The App's durable JSON snapshot
    /// stores ISO-8601 only to whole-second precision, so Date comparison is
    /// deliberately limited to that same persisted second; the exact version
    /// prevents this precision normalization from authorizing another offer.
    public func exactlyMatchesReviewedOffer(_ offer: PendingFolderOffer) -> Bool {
        folderID == offer.folderID
            && offeringDeviceID == offer.offeringDeviceID
            && offerVersion == offer.offerVersion
            && label == offer.label
            && Self.samePersistedSecond(lastSeen, offer.lastSeen)
            && receiveEncrypted == offer.receiveEncrypted
            && remoteEncrypted == offer.remoteEncrypted
    }

    private static func samePersistedSecond(_ first: Date, _ second: Date) -> Bool {
        let firstValue = first.timeIntervalSince1970
        let secondValue = second.timeIntervalSince1970
        guard firstValue.isFinite, secondValue.isFinite else { return false }
        return firstValue.rounded(.down) == secondValue.rounded(.down)
    }
}
