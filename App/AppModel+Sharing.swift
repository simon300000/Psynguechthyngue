import Foundation
import PsyCore
import UIKit
import UserNotifications

extension AppModel {
    func acceptPendingDevice(
        _ offer: PendingDeviceOffer,
        observationScope: PendingDeviceObservationScope,
        name: String,
        paused: Bool,
        confirmedUnverifiedIdentity: Bool
    ) async -> Bool {
        do {
            guard confirmedUnverifiedIdentity else {
                throw PendingAcceptanceInputError.explicitConfirmationRequired
            }
            guard snapshot.pendingDeviceObservationScope != .unavailable else {
                throw PendingAcceptanceInputError.pendingStateUnavailable
            }
            guard snapshot.pendingDeviceObservationScope == observationScope else {
                throw PendingAcceptanceInputError.offerChangedOrExpired
            }
            guard snapshot.pendingDevices.first(where: { $0.deviceID == offer.deviceID }) == offer else {
                throw PendingAcceptanceInputError.offerChangedOrExpired
            }
            let command = try PendingAcceptanceCommandBuilder.device(
                offer: offer,
                name: name,
                paused: paused
            )
            let didSubmit = await submit(
                kind: command.kind,
                folderID: command.folderID,
                itemID: command.itemID,
                arguments: command.arguments
            )
            guard didSubmit else { return false }
            try await reloadPendingOfferSnapshot()
            let accepted =
                snapshot.devices.contains(where: { $0.id == offer.deviceID })
                && !snapshot.pendingDevices.contains(where: { $0.deviceID == offer.deviceID })
            guard accepted else {
                errorMessage = String(
                    localized:
                        "The core did not confirm this acceptance in the latest snapshot. It was not treated as accepted; review the request status and refresh before trying again."
                )
                return false
            }
            return true
        } catch {
            errorMessage = pendingAcceptanceErrorMessage(error)
            return false
        }
    }

    func ignorePendingDevice(
        _ offer: PendingDeviceOffer,
        observationScope: PendingDeviceObservationScope
    ) async -> Bool {
        do {
            try await reloadPendingOfferSnapshot()
            guard snapshot.pendingDeviceObservationScope != .unavailable,
                snapshot.suppressedPendingStateAvailable
            else {
                throw PendingAcceptanceInputError.pendingStateUnavailable
            }
            guard snapshot.pendingDeviceObservationScope == observationScope,
                snapshot.pendingDevices.first(where: { $0.deviceID == offer.deviceID }) == offer,
                !snapshot.suppressedPendingDevices.contains(where: { $0.deviceID == offer.deviceID })
            else {
                throw PendingAcceptanceInputError.offerChangedOrExpired
            }

            let command = PendingSuppressionCommandBuilder.ignoreDevice(offer)
            let didSubmit = await submit(
                kind: command.kind,
                folderID: command.folderID,
                itemID: command.itemID,
                arguments: command.arguments
            )
            guard didSubmit else { return false }
            try await reloadPendingOfferSnapshot()
            guard snapshot.confirmsSuppression(of: offer) else {
                throw PendingAcceptanceInputError.suppressionNotConfirmed
            }
            statusMessage = String(
                localized:
                    "This device request is ignored until you allow future requests from this device ID."
            )
            return true
        } catch {
            errorMessage = pendingAcceptanceErrorMessage(error)
            return false
        }
    }

    func allowFutureDeviceRequests(_ record: SuppressedPendingDevice) async -> Bool {
        do {
            try await reloadPendingOfferSnapshot()
            guard snapshot.suppressedPendingStateAvailable else {
                throw PendingAcceptanceInputError.pendingStateUnavailable
            }
            guard snapshot.suppressedPendingDevices.first(where: { $0.deviceID == record.deviceID }) == record else {
                throw PendingAcceptanceInputError.suppressionChangedOrExpired
            }

            let command = PendingSuppressionCommandBuilder.unignoreDevice(record)
            let didSubmit = await submit(
                kind: command.kind,
                folderID: command.folderID,
                itemID: command.itemID,
                arguments: command.arguments
            )
            guard didSubmit else { return false }
            try await reloadPendingOfferSnapshot()
            guard snapshot.confirmsFutureRequestsAllowed(for: record) else {
                throw PendingAcceptanceInputError.futureRequestsNotConfirmed
            }
            statusMessage = String(
                localized:
                    "Future requests from this device ID are allowed. The previous request will not return unless the peer announces it again."
            )
            return true
        } catch {
            errorMessage = pendingAcceptanceErrorMessage(error)
            return false
        }
    }

    var canDiscoverPendingFolderOffers: Bool {
        !isDiscoveringPendingFolderOffers
            && PendingFolderDiscoveryOpportunity.eligibleDeviceCount(in: snapshot) > 0
    }

    func startPendingFolderDiscovery() {
        guard pendingFolderDiscoveryTask == nil, canDiscoverPendingFolderOffers else { return }
        pendingFolderDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            await discoverPendingFolderOffers()
            pendingFolderDiscoveryTask = nil
        }
    }

    func cancelPendingFolderDiscovery() {
        guard let pendingFolderDiscoveryTask else { return }
        pendingFolderDiscoveryStatusMessage = String(
            localized: "Cancelling the folder-offer check…"
        )
        pendingFolderDiscoveryTask.cancel()
    }

    /// Uses the same finite, rotating device batch as an actually launched
    /// background-processing handler. A discovery capture only updates the
    /// durable summary shown in the UI; this method never creates an accept or
    /// ignore command.
    func discoverPendingFolderOffers() async {
        return await syncController.withSuspension { [self] in
            guard !Task.isCancelled else { return }
            guard let paths, !isDiscoveringPendingFolderOffers else {
                if paths == nil {
                    pendingFolderDiscoveryStatusMessage = String(
                        localized: "Folder-offer discovery is unavailable because configuration could not be loaded."
                    )
                }
                return
            }
            isDiscoveringPendingFolderOffers = true
            pendingFolderDiscoveryStatusMessage = String(
                localized: "Checking configured devices for folder offers…"
            )
            defer { isDiscoveringPendingFolderOffers = false }

            let discoverySnapshot: CoreSnapshot
            do {
                let latest = try await Task.detached(priority: .userInitiated) {
                    try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
                }.value
                guard let latest else {
                    pendingFolderDiscoveryStatusMessage = String(
                        localized: "Folder-offer discovery is unavailable because configuration could not be loaded."
                    )
                    return
                }
                discoverySnapshot = latest
                snapshot = latest
            } catch {
                pendingFolderDiscoveryStatusMessage = String(
                    localized: "Folder-offer discovery is unavailable because configuration could not be loaded."
                )
                return
            }

            let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
            let report = await PendingFolderDiscoveryOpportunity.run(
                snapshot: discoverySnapshot,
                trigger: .user,
                paths: paths,
                environment: environment,
                currentEnvironment: {
                    await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                }
            )

            do {
                let latest = try await Task.detached(priority: .userInitiated) {
                    try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
                }.value
                guard let latest else {
                    pendingFolderDiscoveryStatusMessage = String(
                        localized: "Folder-offer discovery is unavailable because configuration could not be loaded."
                    )
                    return
                }
                snapshot = latest
                await deliverNotifications(snapshot: latest)
            } catch {
                pendingFolderDiscoveryStatusMessage = String(
                    localized: "Folder-offer discovery is unavailable because configuration could not be loaded."
                )
                return
            }
            applyPendingFolderDiscoveryReport(report)
        }
    }

    func applyPendingFolderDiscoveryReport(
        _ report: PendingFolderDiscoveryOpportunityReport
    ) {
        switch report.outcome {
        case .completed:
            let summary = String(
                localized:
                    "Checked \(report.completedDeviceCount) configured device(s). Found \(report.discoveredOfferCount) folder offer(s)."
            )
            if report.offersTruncated {
                pendingFolderDiscoveryStatusMessage = String(
                    localized:
                        "\(summary) The visible offer list is truncated; handle visible offers before checking again."
                )
            } else {
                pendingFolderDiscoveryStatusMessage = summary
            }
        case .noEligibleDevices:
            pendingFolderDiscoveryStatusMessage = String(
                localized: "No eligible unpaused configured devices are available."
            )
        case .cancelled:
            pendingFolderDiscoveryStatusMessage = String(
                localized: "The folder-offer check was cancelled."
            )
        case .configurationChanged:
            pendingFolderDiscoveryStatusMessage = String(
                localized:
                    "Folder-offer discovery stopped because configuration changed. Refresh and try again."
            )
        case .environmentChanged:
            pendingFolderDiscoveryStatusMessage = String(
                localized:
                    "Folder-offer discovery stopped because its transfer-budget window changed. No stale result was assumed. Try again."
            )
        case .policyDenied:
            pendingFolderDiscoveryStatusMessage = String(
                localized: "Current sync policy does not allow folder-offer discovery."
            )
        case .coreBusy:
            pendingFolderDiscoveryStatusMessage = String(
                localized: "The core is busy with other work. No folder-offer result was assumed."
            )
        case .configurationUnavailable:
            pendingFolderDiscoveryStatusMessage = String(
                localized: "Folder-offer discovery is unavailable because configuration could not be loaded."
            )
        case .failed:
            pendingFolderDiscoveryStatusMessage = String(
                localized: "Folder-offer discovery failed safely. No folder offer was accepted or ignored."
            )
        }
    }

    func acceptPendingFolder(
        _ offer: PendingFolderOffer,
        label: String,
        type: FolderType,
        paused: Bool,
        deviceIDs: Set<DeviceID>,
        rescanIntervalS: Int,
        confirmedManagedStorageAndDevices: Bool
    ) async -> Bool {
        return await syncController.withSuspension { [self] in
            guard !Task.isCancelled else { return false }
            guard let paths else {
                errorMessage = PendingAcceptanceInputError.sharedContainerUnavailable.localizedDescription
                return false
            }
            do {
                guard confirmedManagedStorageAndDevices else {
                    throw PendingAcceptanceInputError.explicitConfirmationRequired
                }
                try await reloadPendingOfferSnapshot()
                guard snapshot.pendingFoldersAvailable else {
                    throw PendingAcceptanceInputError.pendingStateUnavailable
                }
                guard snapshot.pendingFolders.first(where: { $0.id == offer.id }) == offer else {
                    throw PendingAcceptanceInputError.offerChangedOrExpired
                }
                guard Self.hasSafePendingFolderEvidenceContract(offer) else {
                    throw PendingAcceptanceInputError.offerChangedOrExpired
                }
                guard !offer.hasInvalidEncryptionContract else {
                    throw PendingAcceptanceInputError.invalidEncryptedOffer
                }
                guard !snapshot.folders.contains(where: { $0.id == offer.folderID }) else {
                    throw PendingAcceptanceInputError.folderAlreadyConfigured
                }

                let configuredPeerIDs = Set(
                    snapshot.devices.lazy
                        .map(\.id)
                        .filter { $0 != self.snapshot.localDeviceID }
                )
                guard deviceIDs.contains(offer.offeringDeviceID) else {
                    throw PendingAcceptanceInputError.offeringDeviceNotSelected
                }
                guard !deviceIDs.isEmpty, deviceIDs.isSubset(of: configuredPeerIDs) else {
                    throw PendingAcceptanceInputError.invalidDeviceSelection
                }
                guard !offer.advertisesEncryption || deviceIDs == [offer.offeringDeviceID] else {
                    throw PendingAcceptanceInputError.invalidDeviceSelection
                }

                let observationProof = try await revalidatePendingFolderOffer(
                    offer,
                    paths: paths
                )

                let expectedURL = try paths.managedFolder(for: offer.folderID).standardizedFileURL
                let managedURL = try await Task.detached(priority: .userInitiated) {
                    let created = try paths.createManagedFolder(for: offer.folderID).standardizedFileURL
                    let values = try created.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        throw SharedContainerError.unsafeManagedFolderRoot
                    }
                    return created
                }.value
                guard managedURL == expectedURL else {
                    throw PendingAcceptanceInputError.invalidManagedPath
                }

                let command = try PendingAcceptanceCommandBuilder.folder(
                    offer: offer,
                    observationProof: observationProof,
                    label: label,
                    managedPath: managedURL.path,
                    type: type,
                    paused: paused,
                    deviceIDs: deviceIDs,
                    rescanIntervalS: rescanIntervalS
                )
                // The directory is intentionally retained if durable enqueue or core
                // configuration fails. It may already contain user data from an
                // earlier attempt and must never be rolled back destructively.
                let didSubmit = try await submitProofBackedPendingFolderCommand(
                    command,
                    observationProof: observationProof,
                    expectedConfigurationRevision: observationProof.configurationRevision,
                    paths: paths
                )
                guard didSubmit else { return false }
                let accepted =
                    snapshot.folders.contains(where: { $0.id == offer.folderID })
                    && !snapshot.pendingFolders.contains(where: { $0.id == offer.id })
                guard accepted else {
                    errorMessage = String(
                        localized:
                            "The core did not confirm this acceptance in the latest snapshot. It was not treated as accepted; review the request status and refresh before trying again."
                    )
                    return false
                }
                statusMessage = String(
                    localized: "The folder was accepted and confirmed in the latest core snapshot."
                )
                return true
            } catch {
                errorMessage = pendingAcceptanceErrorMessage(error)
                return false
            }
        }
    }

    func ignorePendingFolder(_ offer: PendingFolderOffer) async -> Bool {
        return await syncController.withSuspension { [self] in
            guard !Task.isCancelled else { return false }
            guard let paths else {
                errorMessage = PendingAcceptanceInputError.sharedContainerUnavailable.localizedDescription
                return false
            }
            do {
                try await reloadPendingOfferSnapshot()
                guard snapshot.pendingFoldersAvailable,
                    snapshot.suppressedPendingStateAvailable
                else {
                    throw PendingAcceptanceInputError.pendingStateUnavailable
                }
                guard snapshot.pendingFolders.first(where: { $0.id == offer.id }) == offer,
                    !snapshot.suppressedPendingFolders.contains(where: {
                        $0.folderID == offer.folderID
                            && $0.offeringDeviceID == offer.offeringDeviceID
                    })
                else {
                    throw PendingAcceptanceInputError.offerChangedOrExpired
                }
                guard Self.hasSafePendingFolderEvidenceContract(offer) else {
                    throw PendingAcceptanceInputError.offerChangedOrExpired
                }

                // Ignoring is valid for encrypted offers. Its durable suppression
                // record contains only the folder/device identity pair and exact
                // offer version. A redacted proof temporarily retains the reviewed
                // fields for at most five minutes and is consumed by this decision;
                // no remote path or address enters either record.
                let observationProof = try await revalidatePendingFolderOffer(
                    offer,
                    paths: paths
                )
                let command = try PendingSuppressionCommandBuilder.ignoreFolder(
                    offer,
                    observationProof: observationProof
                )
                let didSubmit = try await submitProofBackedPendingFolderCommand(
                    command,
                    observationProof: observationProof,
                    expectedConfigurationRevision: observationProof.configurationRevision,
                    paths: paths
                )
                guard didSubmit else { return false }
                try await reloadPendingOfferSnapshot()
                guard snapshot.confirmsSuppression(of: offer) else {
                    throw PendingAcceptanceInputError.suppressionNotConfirmed
                }
                statusMessage = String(
                    localized:
                        "This folder offer is ignored until you allow future offers from this device for this folder ID."
                )
                return true
            } catch {
                errorMessage = pendingAcceptanceErrorMessage(error)
                return false
            }
        }
    }

    func allowFutureFolderRequests(_ record: SuppressedPendingFolder) async -> Bool {
        do {
            try await reloadPendingOfferSnapshot()
            guard snapshot.suppressedPendingStateAvailable else {
                throw PendingAcceptanceInputError.pendingStateUnavailable
            }
            guard snapshot.suppressedPendingFolders.first(where: { $0.id == record.id }) == record else {
                throw PendingAcceptanceInputError.suppressionChangedOrExpired
            }

            let command = PendingSuppressionCommandBuilder.unignoreFolder(record)
            let didSubmit = await submit(
                kind: command.kind,
                folderID: command.folderID,
                itemID: command.itemID,
                arguments: command.arguments
            )
            guard didSubmit else { return false }
            try await reloadPendingOfferSnapshot()
            guard snapshot.confirmsFutureRequestsAllowed(for: record) else {
                throw PendingAcceptanceInputError.futureRequestsNotConfirmed
            }
            statusMessage = String(
                localized:
                    "Future offers from this device for this folder ID are allowed. The previous offer will not return unless the peer announces it again."
            )
            return true
        } catch {
            errorMessage = pendingAcceptanceErrorMessage(error)
            return false
        }
    }

    func isRevalidatingPendingFolderOffer(_ offer: PendingFolderOffer) -> Bool {
        pendingFolderOfferObservationIDs.contains(offer.id)
    }

    /// Revalidation is the only network step permitted before a pending-folder
    /// accept/ignore command exists. The returned proof is compared with every
    /// user-reviewed offer field before any managed directory is created or
    /// durable command is enqueued.
    func revalidatePendingFolderOffer(
        _ offer: PendingFolderOffer,
        paths: SharedContainerPaths
    ) async throws -> PendingFolderObservationProof {
        guard pendingFolderOfferObservationIDs.insert(offer.id).inserted else {
            throw PendingAcceptanceInputError.observationAlreadyInProgress
        }
        statusMessage = String(localized: "Revalidating this offer with the offering device…")
        defer { pendingFolderOfferObservationIDs.remove(offer.id) }

        let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
        let outcome = await CoreRuntime.shared.observePendingFolderOffer(
            folderID: offer.folderID,
            offeringDeviceID: offer.offeringDeviceID,
            trigger: .user,
            paths: paths,
            environment: environment,
            currentEnvironment: {
                await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
            }
        )
        let proof: PendingFolderObservationProof
        switch outcome {
        case .completed(let observedProof, _, _):
            proof = observedProof
        case .coreBusy:
            throw PendingAcceptanceInputError.observationCoreBusy
        case .configurationUnavailable:
            throw PendingAcceptanceInputError.observationConfigurationUnavailable
        case .policyDenied(_):
            throw PendingAcceptanceInputError.observationPolicyDenied
        case .failed(_):
            throw PendingAcceptanceInputError.observationFailed
        }
        guard proof.exactlyMatchesReviewedOffer(offer), Date.now < proof.expiresAt else {
            throw PendingAcceptanceInputError.observedOfferChangedOrExpired
        }
        return proof
    }

    /// The producer performs the enqueue-time authoritative revision check just
    /// before the durable queue write. A concurrent revision change after that
    /// read remains bound to the command and is rejected by native preflight.
    /// Success here means only "queued"; callers still require their final
    /// snapshot postcondition.
    func submitProofBackedPendingFolderCommand(
        _ configuration: PendingAcceptanceCommandConfiguration,
        observationProof: PendingFolderObservationProof,
        expectedConfigurationRevision: String,
        paths: SharedContainerPaths
    ) async throws -> Bool {
        guard configuration.kind.embeddedBridgeCapability == .supported else {
            throw PendingAcceptanceInputError.observationFailed
        }
        let command = try await Task.detached(priority: .userInitiated) {
            try ScopedCoreCommandProducer(paths: paths)
                .enqueueProofBackedPendingFolderCommand(
                    configuration: configuration,
                    observationProof: observationProof,
                    expectedConfigurationRevision: expectedConfigurationRevision,
                    trigger: .user
                )
        }.value

        statusMessage = String(localized: "Request queued. Completion has not been reported yet.")
        let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
        let execution = await processQueuedCommands(
            [command],
            trigger: .user,
            paths: paths,
            initialEnvironment: environment
        )
        var requiresRevalidation = false
        if let result = execution.results[command.id] {
            requiresRevalidation = Self.pendingFolderResultRequiresRevalidation(
                result.errorCode
            )
            switch result.status {
            case .succeeded:
                statusMessage = String(localized: "Request completed successfully.")
            case .retryable:
                statusMessage = String(
                    localized:
                        "Request remains queued for retry: \(result.errorCode ?? String(localized: "unknown"))."
                )
            case .blocked:
                statusMessage = String(
                    localized:
                        "Request was blocked and its result was recorded; it will not retry automatically: \(result.errorCode ?? String(localized: "unknown"))."
                )
            case .failed:
                statusMessage = String(
                    localized:
                        "Request failed and its result was recorded; it will not retry automatically: \(result.errorCode ?? String(localized: "unknown"))."
                )
            }
        } else if case .failed(let code) = execution.outcome {
            requiresRevalidation = Self.pendingFolderResultRequiresRevalidation(code)
            statusMessage = String(
                localized: "Request remains queued because the core could not run: \(code)."
            )
        } else if case .policyDenied(let reasons) = execution.outcome {
            statusMessage = String(
                localized:
                    "Request remains queued because policy blocked it: \(reasons.first?.rawValue ?? String(localized: "unknown"))."
            )
        }
        await refresh()
        if requiresRevalidation {
            throw PendingAcceptanceInputError.configurationChangedAfterObservation
        }
        return true
    }

    static func pendingFolderResultRequiresRevalidation(_ code: String?) -> Bool {
        guard let code else { return false }
        return [
            "configuration_revision_mismatch",
            "observation_proof_configuration_mismatch",
            "observation_proof_expired",
            "observation_proof_not_found",
            "observation_proof_scope_mismatch",
            "offer_version_conflict",
            "pending_folder_not_found",
        ].contains(code)
    }

    static func requiresExactFolderIncarnation(_ kind: CoreCommandKind) -> Bool {
        switch kind {
        case .editFolder, .removeFolder, .sync, .pause, .resume, .rescan:
            true
        case .addDevice, .editDevice, .removeDevice, .acceptDevice, .ignorePendingDevice,
            .unignorePendingDevice, .addFolder, .acceptFolder, .ignorePendingFolder,
            .unignorePendingFolder, .upload, .download, .exchangeIndex, .materialize, .pin,
            .evict, .create, .modify, .move, .delete, .disposeRecovery,
            .disposeRecoveryReviewed:
            false
        }
    }

    static func requiresCanonicalConfiguration(_ kind: CoreCommandKind) -> Bool {
        switch kind {
        case .addDevice, .editDevice, .removeDevice, .acceptDevice, .ignorePendingDevice,
            .unignorePendingDevice, .addFolder, .editFolder, .removeFolder, .acceptFolder,
            .ignorePendingFolder, .unignorePendingFolder, .pause, .resume:
            true
        case .sync, .upload, .download, .exchangeIndex, .rescan, .materialize, .pin,
            .evict, .create, .modify, .move, .delete, .disposeRecovery,
            .disposeRecoveryReviewed:
            false
        }
    }

    static func hasSafePendingFolderEvidenceContract(_ offer: PendingFolderOffer) -> Bool {
        switch offer.evidenceSource {
        case .live:
            !offer.requiresNetworkRevalidation
        case .durableSummary:
            offer.requiresNetworkRevalidation
        }
    }

    /// Pending-offer mutations use the latest durable core snapshot directly
    /// before enqueue and again after execution. This does not depend on a
    /// concurrent broad UI refresh completing first.
    func reloadPendingOfferSnapshot() async throws {
        guard let paths else {
            throw PendingAcceptanceInputError.sharedContainerUnavailable
        }
        snapshot = try await Task.detached(priority: .userInitiated) {
            try SharedSnapshotStore(snapshotURL: paths.snapshot).read() ?? CoreSnapshot()
        }.value
    }

}
