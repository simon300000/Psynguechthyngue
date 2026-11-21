import CryptoKit
import Foundation

public enum ScopedCoreCommandProducerError: Error, Hashable, Sendable, LocalizedError {
    case snapshotUnavailable
    case configurationRevisionUnavailable
    case folderScopeRequired(CoreCommandKind)
    case folderUnavailable(String)
    case folderIncarnationUnavailable(String)
    case backgroundPolicyUnavailable(String)
    case duplicateFolder(String)
    case folderIncarnationMismatch(expected: String, actual: String)
    case resultCommandMismatch
    case invalidProofBackedPendingFolderCommand
    case configurationRevisionMismatch(expected: String, actual: String?)
    case temporaryPolicyProfileUnavailable(UUID)
    case temporaryPolicyProfileNotApplicable

    public var errorDescription: String? {
        switch self {
        case .snapshotUnavailable:
            "The authoritative core snapshot is unavailable; no request was queued."
        case .configurationRevisionUnavailable:
            "The authoritative configuration revision is unavailable; no request was queued."
        case .folderScopeRequired(let kind):
            "The \(kind.rawValue) request requires an exact folder scope; no request was queued."
        case .folderUnavailable(let folderID):
            "Folder \(folderID) is not present exactly once in the authoritative snapshot; no request was queued."
        case .folderIncarnationUnavailable(let folderID):
            "The exact incarnation for folder \(folderID) is unavailable; no request was queued."
        case .backgroundPolicyUnavailable(let folderID):
            "The exact background policy for folder \(folderID) is unavailable; no request was queued."
        case .duplicateFolder(let folderID):
            "Folder \(folderID) appears more than once in the authoritative snapshot; no request was queued."
        case .folderIncarnationMismatch:
            "The folder was removed or replaced after this action was presented; no request was queued."
        case .resultCommandMismatch:
            "The durable result does not belong to the command being reconciled."
        case .invalidProofBackedPendingFolderCommand:
            "The pending-folder request is not bound to a valid observation proof; no request was queued."
        case .configurationRevisionMismatch:
            "The configuration changed after offer revalidation; no request was queued."
        case .temporaryPolicyProfileUnavailable:
            "The selected temporary policy profile is unavailable; no request was queued."
        case .temporaryPolicyProfileNotApplicable:
            "A temporary policy profile can only authorize a user-initiated network task."
        }
    }
}

extension CoreCommandKind {
    /// Configuration sessions are offline and must not inherit the network
    /// policy gate used by exact-folder transfer sessions.
    public var usesOfflineConfigurationSession: Bool {
        switch self {
        case .addDevice, .editDevice, .removeDevice,
            .acceptDevice, .ignorePendingDevice, .unignorePendingDevice,
            .addFolder, .editFolder, .removeFolder,
            .acceptFolder, .ignorePendingFolder, .unignorePendingFolder,
            .pause, .resume, .disposeRecovery, .disposeRecoveryReviewed:
            true
        default:
            false
        }
    }

    fileprivate var requiresExistingFolderIncarnationWhenFolderScoped: Bool {
        switch self {
        case .editFolder, .removeFolder, .pause, .resume:
            true
        case .addDevice, .editDevice, .removeDevice,
            .acceptDevice, .ignorePendingDevice, .unignorePendingDevice,
            .addFolder, .acceptFolder, .ignorePendingFolder, .unignorePendingFolder,
            .disposeRecovery, .disposeRecoveryReviewed:
            false
        default:
            true
        }
    }
}

/// Builds new durable queue commands from only the authoritative persisted
/// snapshot and the App-owned folder-incarnation registry.
///
/// A nil-folder sync is expanded into a deterministic exact-folder batch. The
/// complete batch is prepared before callers enqueue anything, so a missing or
/// stale folder identity cannot leave a partially produced global request.
public struct ScopedCoreCommandProducer: Sendable {
    private let snapshotStore: SharedSnapshotStore
    private let incarnationStore: FolderIncarnationStore
    private let policyStore: SyncPolicyStore
    private let retentionStore: ContentRetentionStore
    private let commandQueueRoot: URL?

    public init(paths: SharedContainerPaths) {
        snapshotStore = SharedSnapshotStore(snapshotURL: paths.snapshot)
        incarnationStore = FolderIncarnationStore(url: paths.folderIncarnations)
        policyStore = SyncPolicyStore(url: paths.policy)
        retentionStore = ContentRetentionStore(url: paths.contentRetention)
        commandQueueRoot = paths.commandQueue
    }

    public init(
        snapshotURL: URL,
        folderIncarnationsURL: URL
    ) {
        snapshotStore = SharedSnapshotStore(snapshotURL: snapshotURL)
        incarnationStore = FolderIncarnationStore(url: folderIncarnationsURL)
        policyStore = SyncPolicyStore(
            url: snapshotURL.deletingLastPathComponent().appendingPathComponent("sync-policy.json")
        )
        retentionStore = ContentRetentionStore(
            url: snapshotURL.deletingLastPathComponent().appendingPathComponent(
                "content-retention-v1.json"
            )
        )
        commandQueueRoot = nil
    }

    /// Returns one command for a scoped/configuration request, or one command
    /// per configured folder for a nil-folder `.sync`. `invocationID` is the
    /// durable identity of this producer invocation; global child identifiers
    /// are derived from it and the canonical folder ID so replaying the same
    /// invocation produces byte-for-byte equivalent queue semantics.
    public func prepareCommands(
        invocationID: UUID = UUID(),
        kind: CoreCommandKind,
        folderID: FolderID? = nil,
        itemID: String? = nil,
        arguments: [String: String] = [:],
        expectedFolderIncarnationDigest: String? = nil,
        expectedConfigurationRevision: String? = nil,
        temporaryPolicyProfile: TemporarySyncPolicyProfile? = nil,
        trigger: SyncTrigger,
        createdAt: Date = .now
    ) throws -> [CoreCommand] {
        guard kind != .acceptFolder, kind != .ignorePendingFolder else {
            throw ScopedCoreCommandProducerError.invalidProofBackedPendingFolderCommand
        }
        let taskPolicyBinding = try makeTaskPolicyBinding(
            expectedProfile: temporaryPolicyProfile,
            kind: kind,
            trigger: trigger,
            createdAt: createdAt
        )
        if kind == .sync, folderID == nil {
            let snapshot = try authoritativeSnapshot()
            let commandConfigurationRevision: String?
            if let expectedConfigurationRevision {
                guard snapshot.configurationRevision == expectedConfigurationRevision else {
                    throw ScopedCoreCommandProducerError.configurationRevisionMismatch(
                        expected: expectedConfigurationRevision,
                        actual: snapshot.configurationRevision
                    )
                }
                guard CoreSessionDigest.isLowercaseSHA256(expectedConfigurationRevision) else {
                    throw ScopedCoreCommandProducerError.configurationRevisionUnavailable
                }
                commandConfigurationRevision = expectedConfigurationRevision
            } else {
                commandConfigurationRevision = nil
            }
            // Validate the complete projection before filtering. A duplicate
            // paused record is still corrupt authoritative state and must not
            // be hidden by the active-folder view.
            _ = try uniqueSortedFolderIDs(snapshot.folders.map(\.id))
            let folderIDs = try uniqueSortedFolderIDs(
                snapshot.folders.filter { !$0.isPaused }.map(\.id)
            )
            // Resolve every identity before returning any command. This is the
            // all-or-nothing validation boundary for global expansion.
            let exactContexts = try folderIDs.map { try exactContext(for: $0, snapshot: snapshot) }
            let commands = try backgroundEligibleCommands(
                exactContexts,
                requestedKind: kind,
                snapshot: snapshot,
                trigger: trigger
            )
            return commands.enumerated().map { index, value in
                let (context, effectiveKind) = value
                return CoreCommand(
                    id: Self.childCommandID(
                        invocationID: invocationID,
                        kind: effectiveKind,
                        folderID: context.folderID
                    ),
                    kind: effectiveKind,
                    folderID: context.folderID,
                    itemID: itemID,
                    arguments: arguments,
                    folderIncarnationDigest: context.folderIncarnationDigest,
                    commandConfigurationRevision: commandConfigurationRevision,
                    taskPolicyBinding: taskPolicyBinding,
                    trigger: trigger,
                    createdAt: createdAt.addingTimeInterval(Double(index) / 1_000_000)
                )
            }
        }

        var command = CoreCommand(
            id: invocationID,
            kind: kind,
            folderID: folderID,
            itemID: itemID,
            arguments: arguments,
            taskPolicyBinding: taskPolicyBinding,
            trigger: trigger,
            createdAt: createdAt
        )

        let needsRevision =
            command.requiresDurableConfigurationRevisionPrecondition
            || expectedConfigurationRevision != nil
        let needsIncarnation =
            folderID != nil
            && kind.requiresExistingFolderIncarnationWhenFolderScoped
        let needsSnapshot = needsRevision || needsIncarnation || !kind.usesOfflineConfigurationSession

        let snapshot = needsSnapshot ? try authoritativeSnapshot() : nil
        if needsRevision {
            guard let revision = snapshot?.configurationRevision,
                CoreSessionDigest.isLowercaseSHA256(revision)
            else {
                throw ScopedCoreCommandProducerError.configurationRevisionUnavailable
            }
            if let expectedConfigurationRevision,
                expectedConfigurationRevision != revision
            {
                throw ScopedCoreCommandProducerError.configurationRevisionMismatch(
                    expected: expectedConfigurationRevision,
                    actual: revision
                )
            }
            command.commandConfigurationRevision = revision
        }

        if needsIncarnation {
            guard let folderID, let snapshot else {
                throw ScopedCoreCommandProducerError.folderScopeRequired(kind)
            }
            let context = try exactContext(
                for: folderID,
                snapshot: snapshot
            )
            if let expectedFolderIncarnationDigest,
                expectedFolderIncarnationDigest != context.folderIncarnationDigest
            {
                throw ScopedCoreCommandProducerError.folderIncarnationMismatch(
                    expected: expectedFolderIncarnationDigest,
                    actual: context.folderIncarnationDigest
                )
            }
            command.folderIncarnationDigest = context.folderIncarnationDigest
            command.kind = try retentionAwareSyncKind(
                requestedKind: command.kind,
                context: context,
                snapshot: snapshot
            )
        } else if !kind.usesOfflineConfigurationSession, folderID == nil {
            throw ScopedCoreCommandProducerError.folderScopeRequired(kind)
        }

        return [command]
    }

    private func retentionAwareSyncKind(
        requestedKind: CoreCommandKind,
        context: FolderPolicyContext,
        snapshot: CoreSnapshot
    ) throws -> CoreCommandKind {
        guard requestedKind == .sync else { return requestedKind }
        let matches = snapshot.folders.filter { $0.id == context.folderID }
        guard matches.count == 1, let folder = matches.first else {
            throw ScopedCoreCommandProducerError.duplicateFolder(context.folderID.rawValue)
        }
        if let policy = try retentionStore.folderPolicy(
            folderID: context.folderID,
            folderIncarnationDigest: context.folderIncarnationDigest
        ) {
            return policy.plan.mode == .fullSync || policy.plan.mode == .pinnedOffline
                ? .sync : .upload
        }
        return folder.selectionMode == .full ? .sync : .upload
    }

    private func makeTaskPolicyBinding(
        expectedProfile: TemporarySyncPolicyProfile?,
        kind: CoreCommandKind,
        trigger: SyncTrigger,
        createdAt: Date
    ) throws -> CoreTaskPolicyBinding? {
        guard let expectedProfile else { return nil }
        guard !kind.usesOfflineConfigurationSession,
            trigger == .user || trigger == .appIntent
        else {
            throw ScopedCoreCommandProducerError.temporaryPolicyProfileNotApplicable
        }
        let document = try policyStore.loadDocument()
        guard
            let profile = document.temporaryProfiles.first(where: {
                $0.id == expectedProfile.id
            }), profile == expectedProfile
        else {
            throw ScopedCoreCommandProducerError.temporaryPolicyProfileUnavailable(
                expectedProfile.id
            )
        }
        return try CoreTaskPolicyBinding(
            profile: profile,
            commandCreatedAt: createdAt,
            trigger: trigger
        )
    }

    /// Produces the only durable accept/ignore commands allowed to consume a
    /// pending-folder observation proof. The authoritative snapshot is read
    /// once, immediately before construction, and its revision must equal the
    /// proof's revision supplied by the caller. No active core session or
    /// ambient revision can satisfy this precondition.
    public func prepareProofBackedPendingFolderCommand(
        invocationID: UUID = UUID(),
        configuration: PendingAcceptanceCommandConfiguration,
        observationProof: PendingFolderObservationProof,
        expectedConfigurationRevision: String,
        trigger: SyncTrigger,
        createdAt: Date = .now
    ) throws -> CoreCommand {
        guard expectedConfigurationRevision == observationProof.configurationRevision,
            Date.now < observationProof.expiresAt,
            CoreSessionDigest.isLowercaseSHA256(expectedConfigurationRevision),
            Self.isStrictProofBackedPendingFolderConfiguration(
                configuration,
                observationProof: observationProof
            )
        else {
            throw ScopedCoreCommandProducerError.invalidProofBackedPendingFolderCommand
        }
        let snapshot = try authoritativeSnapshot()
        guard snapshot.configurationRevision == expectedConfigurationRevision else {
            throw ScopedCoreCommandProducerError.configurationRevisionMismatch(
                expected: expectedConfigurationRevision,
                actual: snapshot.configurationRevision
            )
        }
        return CoreCommand(
            id: invocationID,
            kind: configuration.kind,
            folderID: configuration.folderID,
            itemID: configuration.itemID,
            arguments: configuration.arguments,
            commandConfigurationRevision: expectedConfigurationRevision,
            trigger: trigger,
            createdAt: createdAt
        )
    }

    /// Persists exactly one proof-backed command after the authoritative
    /// revision check. A crash before `enqueue` leaves only a short-lived,
    /// unused native proof; a crash after it is covered by the durable queue.
    /// A concurrent core revision change after the snapshot read is still safe:
    /// the same revision remains on the command and native preflight rejects it
    /// before mutation.
    @discardableResult
    public func enqueueProofBackedPendingFolderCommand(
        invocationID: UUID = UUID(),
        configuration: PendingAcceptanceCommandConfiguration,
        observationProof: PendingFolderObservationProof,
        expectedConfigurationRevision: String,
        trigger: SyncTrigger,
        createdAt: Date = .now
    ) throws -> CoreCommand {
        guard let commandQueueRoot else {
            throw ScopedCoreCommandProducerError.invalidProofBackedPendingFolderCommand
        }
        let command = try prepareProofBackedPendingFolderCommand(
            invocationID: invocationID,
            configuration: configuration,
            observationProof: observationProof,
            expectedConfigurationRevision: expectedConfigurationRevision,
            trigger: trigger,
            createdAt: createdAt
        )
        try CoreCommandQueue(root: commandQueueRoot).enqueue(command)
        return command
    }

    /// Completes the App-owned half of a successful folder deletion. The
    /// command's durable incarnation fence is the only authority accepted by
    /// the policy store; a later folder with the same ID cannot be discarded.
    @discardableResult
    public func reconcileSuccessfulFolderRemoval(
        command: CoreCommand,
        result: CoreCommandResult
    ) throws -> Bool {
        guard result.commandID == command.id else {
            throw ScopedCoreCommandProducerError.resultCommandMismatch
        }
        guard result.status == .succeeded, command.kind == .removeFolder else {
            return false
        }
        guard let folderID = command.folderID else {
            throw ScopedCoreCommandProducerError.folderScopeRequired(command.kind)
        }
        guard let digest = command.folderIncarnationDigest,
            CoreSessionDigest.isLowercaseSHA256(digest)
        else {
            throw ScopedCoreCommandProducerError.folderIncarnationUnavailable(
                folderID.rawValue
            )
        }
        return try policyStore.discardFolderPolicy(
            for: FolderPolicyContext(
                folderID: folderID,
                folderIncarnationDigest: digest
            )
        )
    }

    private func authoritativeSnapshot() throws -> CoreSnapshot {
        do {
            guard let snapshot = try snapshotStore.read() else {
                throw ScopedCoreCommandProducerError.snapshotUnavailable
            }
            return snapshot
        } catch let error as ScopedCoreCommandProducerError {
            throw error
        } catch {
            throw ScopedCoreCommandProducerError.snapshotUnavailable
        }
    }

    private static func isStrictProofBackedPendingFolderConfiguration(
        _ configuration: PendingAcceptanceCommandConfiguration,
        observationProof: PendingFolderObservationProof
    ) -> Bool {
        guard configuration.folderID == observationProof.folderID,
            configuration.itemID == nil,
            let proofID = configuration.arguments["observationProofID"],
            proofID == observationProof.proofID,
            CoreSessionDigest.isCanonicalStableVersion(proofID),
            let deviceValue = configuration.arguments["offeringDeviceID"],
            deviceValue == observationProof.offeringDeviceID.rawValue,
            DeviceID(rawValue: deviceValue)?.rawValue == deviceValue,
            configuration.arguments["offerVersion"] == observationProof.offerVersion,
            CoreSessionDigest.isCanonicalStableVersion(observationProof.offerVersion)
        else {
            return false
        }
        let expectedKeys: Set<String>
        switch configuration.kind {
        case .acceptFolder:
            expectedKeys = [
                "deviceIDs", "label", "observationProofID", "offerVersion",
                "offeringDeviceID", "path", "paused", "rescanIntervalS", "type",
            ]
        case .ignorePendingFolder:
            expectedKeys = ["observationProofID", "offerVersion", "offeringDeviceID"]
        default:
            return false
        }
        guard Set(configuration.arguments.keys) == expectedKeys else {
            return false
        }
        guard configuration.kind == .acceptFolder else {
            return true
        }
        return isStrictPendingFolderAcceptance(
            configuration.arguments,
            observationProof: observationProof
        )
    }

    private static func isStrictPendingFolderAcceptance(
        _ arguments: [String: String],
        observationProof: PendingFolderObservationProof
    ) -> Bool {
        guard !(observationProof.receiveEncrypted && observationProof.remoteEncrypted),
            let typeValue = arguments["type"],
            let type = FolderType(rawValue: typeValue),
            type.rawValue == typeValue,
            arguments["paused"] == "true" || arguments["paused"] == "false",
            let rescanValue = arguments["rescanIntervalS"],
            let rescanIntervalS = Int(rescanValue),
            String(rescanIntervalS) == rescanValue,
            (0...(365 * 24 * 60 * 60)).contains(rescanIntervalS),
            let deviceData = arguments["deviceIDs"]?.data(using: .utf8),
            let deviceValues = try? JSONDecoder().decode([String].self, from: deviceData),
            !deviceValues.isEmpty,
            deviceValues.count <= 64,
            deviceValues == deviceValues.sorted(),
            Set(deviceValues).count == deviceValues.count,
            deviceValues.allSatisfy({ DeviceID(rawValue: $0)?.rawValue == $0 }),
            deviceValues.contains(observationProof.offeringDeviceID.rawValue)
        else {
            return false
        }

        let advertisesEncryption =
            observationProof.receiveEncrypted || observationProof.remoteEncrypted
        guard advertisesEncryption == (type == .receiveEncrypted) else {
            return false
        }
        if advertisesEncryption {
            return deviceValues == [observationProof.offeringDeviceID.rawValue]
                && (rescanIntervalS == 0 || rescanIntervalS >= 86_400)
        }
        return type == .sendReceive || type == .sendOnly || type == .receiveOnly
    }

    private func exactContext(
        for folderID: FolderID,
        snapshot: CoreSnapshot
    ) throws -> FolderPolicyContext {
        let matches = snapshot.folders.lazy.filter { $0.id == folderID }.count
        guard matches == 1 else {
            if matches > 1 {
                throw ScopedCoreCommandProducerError.duplicateFolder(folderID.rawValue)
            }
            throw ScopedCoreCommandProducerError.folderUnavailable(folderID.rawValue)
        }
        do {
            return try incarnationStore.policyContext(for: folderID)
        } catch {
            throw ScopedCoreCommandProducerError.folderIncarnationUnavailable(folderID.rawValue)
        }
    }

    private func uniqueSortedFolderIDs(_ folderIDs: [FolderID]) throws -> [FolderID] {
        let grouped = Dictionary(grouping: folderIDs, by: { $0 })
        if let duplicate = grouped.first(where: { $0.value.count != 1 })?.key {
            throw ScopedCoreCommandProducerError.duplicateFolder(duplicate.rawValue)
        }
        return grouped.keys.sorted { $0.rawValue < $1.rawValue }
    }

    private func backgroundEligibleCommands(
        _ contexts: [FolderPolicyContext],
        requestedKind: CoreCommandKind,
        snapshot: CoreSnapshot,
        trigger: SyncTrigger
    ) throws -> [(FolderPolicyContext, CoreCommandKind)] {
        guard trigger == .backgroundRefresh || trigger == .backgroundProcessing else {
            return try contexts.map { context in
                (
                    context,
                    try retentionAwareSyncKind(
                        requestedKind: requestedKind,
                        context: context,
                        snapshot: snapshot
                    )
                )
            }
        }
        let document: SyncPolicyDocumentV2
        do {
            document = try policyStore.loadDocument()
        } catch {
            throw ScopedCoreCommandProducerError.backgroundPolicyUnavailable("global")
        }
        guard document.global.automaticBackgroundMode == .refreshAndProcessing else {
            return []
        }
        return try contexts.compactMap { context in
            let resolved: SyncPolicy
            do {
                resolved = try document.resolvedPolicy(
                    for: context.folderID,
                    folderIncarnationDigest: context.folderIncarnationDigest
                )
            } catch {
                throw ScopedCoreCommandProducerError.backgroundPolicyUnavailable(
                    context.folderID.rawValue
                )
            }
            let selectionKind = try retentionAwareSyncKind(
                requestedKind: requestedKind,
                context: context,
                snapshot: snapshot
            )
            let effectiveKind: CoreCommandKind?
            if selectionKind == .upload {
                // Selective folders never turn a background opportunity into a
                // bulk download. A scan-only fallback can still advance their
                // local index when upload permission is disabled.
                if resolved.allowBackgroundUpload && resolved.allowBackgroundScan {
                    effectiveKind = .upload
                } else if resolved.allowBackgroundScan {
                    effectiveKind = .rescan
                } else {
                    effectiveKind = nil
                }
            } else if resolved.allowBackgroundUpload,
                resolved.allowBackgroundDownload,
                resolved.allowBackgroundScan
            {
                effectiveKind = selectionKind
            } else if resolved.allowBackgroundUpload && resolved.allowBackgroundScan {
                effectiveKind = .upload
            } else if resolved.allowBackgroundDownload {
                // Download sessions do not request a local scan capability.
                effectiveKind = .download
            } else if resolved.allowBackgroundScan {
                effectiveKind = .rescan
            } else {
                effectiveKind = nil
            }
            return effectiveKind.map { (context, $0) }
        }
    }

    private static func childCommandID(
        invocationID: UUID,
        kind: CoreCommandKind,
        folderID: FolderID
    ) -> UUID {
        var material = Data("psy-scoped-command-v1".utf8)
        for value in [
            invocationID.uuidString.lowercased(),
            kind.rawValue,
            folderID.rawValue,
        ] {
            material.append(0)
            material.append(contentsOf: value.utf8)
        }
        let bytes = Array(SHA256.hash(data: material).prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }
}
