import Foundation
import PsyCore
import UIKit
import UserNotifications

extension AppModel {
    func authorizeExternalDirectory(
        _ url: URL,
        requestedMode: ExternalDirectoryMode = .controlledMirror
    ) async {
        guard let externalDirectoryBroker else { return }
        do {
            let record = try await externalDirectoryBroker.authorize(
                url: url,
                requestedMode: requestedMode
            )
            try await finishExternalDirectoryAuthorization(record, broker: externalDirectoryBroker)
        } catch {
            errorMessage = externalDirectoryAuthorizationMessage(error)
        }
    }

    @discardableResult
    func authorizeNamedExternalDirectory(
        in parentURL: URL,
        name: String,
        requestedMode: ExternalDirectoryMode = .controlledMirror
    ) async -> Bool {
        guard IOSAppOnMacEnvironment.current.allowsNamedChildCreation else {
            errorMessage = String(
                localized: "Named folder creation is available only when this iPad app runs on Apple silicon Mac."
            )
            return false
        }
        guard let externalDirectoryBroker else { return false }
        do {
            let record = try await ExternalDirectoryNamedChildAuthorizer().createAndAuthorizeBound(
                parentURL: parentURL,
                name: name
            ) { childURL, childIdentity in
                try await externalDirectoryBroker.authorize(
                    url: childURL,
                    requestedMode: requestedMode,
                    expectedRootIdentity: childIdentity
                )
            }
            try await finishExternalDirectoryAuthorization(record, broker: externalDirectoryBroker)
            return true
        } catch {
            errorMessage = externalDirectoryAuthorizationMessage(error)
            return false
        }
    }

    func finishExternalDirectoryAuthorization(
        _ record: ExternalDirectoryRecord,
        broker: ExternalDirectoryAccessBroker
    ) async throws {
        _ = try await broker.reconcileSyncBindings(snapshot: snapshot)
        externalDirectories = await broker.allRecords()
        await processExternalDirectoryBindingQueue()
        await refresh()
        let current = externalDirectories.first(where: { $0.id == record.id }) ?? record
        statusMessage = externalDirectoryBindingMessage(for: current)
        errorMessage = nil
    }

    func externalDirectoryAuthorizationMessage(_ error: Error) -> String {
        if let error = error as? ExternalDirectoryError {
            return localizedExternalDirectoryAuthorizationError(error)
        }
        if let error = error as? ExternalDirectoryNamedChildError {
            return localizedExternalDirectoryNamedChildError(error)
        }
        if let error = error as? ExternalDirectoryChildNameValidationError {
            return localizedExternalDirectoryChildNameError(error)
        }
        return String(
            localized: "External directory authorization failed before any external data changed."
        )
    }

    func updateExternalDirectoryMode(_ id: UUID, mode: ExternalDirectoryMode) async {
        guard let externalDirectoryBroker else { return }
        do {
            let record = try await externalDirectoryBroker.updateMode(id: id, requestedMode: mode)
            externalDirectories = await externalDirectoryBroker.allRecords()
            statusMessage = String(
                localized: "External directory mode is now \(localizedExternalDirectoryMode(record.mode))."
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runExternalDirectoryMirror(
        _ id: UUID,
        requestedTemporaryOverride: Bool = false
    ) async {
        guard let externalDirectoryBroker, let paths,
            !runningExternalDirectoryIDs.contains(id)
        else { return }
        guard let record = externalDirectories.first(where: { $0.id == id }),
            record.authorizationState == .active,
            record.syncBinding.phase == .verified
        else {
            statusMessage = String(
                localized:
                    "The managed mirror is not verified in the latest Syncthing snapshot. Repair the binding before copying files."
            )
            return
        }
        runningExternalDirectoryIDs.insert(id)
        defer { runningExternalDirectoryIDs.remove(id) }
        do {
            let status = try await externalDirectoryBroker.runMirror(
                id: id,
                trigger: .user,
                requestedTemporaryOverride: requestedTemporaryOverride,
                currentEnvironment: {
                    await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                }
            )
            externalDirectories = await externalDirectoryBroker.allRecords()
            if let failureCode = status.failureCode {
                statusMessage = String(localized: "Mirror can be retried: \(failureCode.rawValue).")
            } else {
                await processExternalDirectoryBindingQueue()
                await refresh()
                statusMessage = String(
                    localized:
                        "Mirror completed: \(status.importedFiles) imported, \(status.exportedFiles) exported, \(status.conflictCount) conflicts, \(status.deleteConfirmationCount) deletions awaiting confirmation. A durable Syncthing rescan was attempted and remains queued if policy currently blocks it."
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            externalDirectories = await externalDirectoryBroker.allRecords()
        }
    }

    func resolveExternalDirectoryDeletion(
        recordID: UUID,
        confirmation: ControlledMirrorConfirmation,
        decision: ControlledMirrorConfirmationDecision,
        requestedTemporaryOverride: Bool = false
    ) async {
        guard let externalDirectoryBroker, let paths else { return }
        do {
            let status = try await externalDirectoryBroker.resolveDeletionConfirmation(
                recordID: recordID,
                confirmation: confirmation,
                decision: decision,
                trigger: .user,
                requestedTemporaryOverride: requestedTemporaryOverride,
                currentEnvironment: {
                    await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                }
            )
            externalDirectories = await externalDirectoryBroker.allRecords()
            await processExternalDirectoryBindingQueue()
            await refresh()
            errorMessage = nil
            switch decision {
            case .propagateDeletion:
                statusMessage = String(
                    localized:
                        "The unchanged mirror copy was deleted after confirmation. Remaining deletion requests: \(status.deleteConfirmationCount)."
                )
            case .keepSurvivingCopy:
                statusMessage = String(
                    localized:
                        "The surviving mirror copy was kept. Remaining deletion requests: \(status.deleteConfirmationCount)."
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            externalDirectories = await externalDirectoryBroker.allRecords()
        }
    }

    func resolveExternalDirectoryRecovery(
        recordID: UUID,
        summary: ControlledMirrorRecoverySummary,
        decision: ControlledMirrorRecoveryDecision
    ) async {
        guard let externalDirectoryBroker, let paths,
            !runningExternalDirectoryIDs.contains(recordID)
        else { return }
        runningExternalDirectoryIDs.insert(recordID)
        defer { runningExternalDirectoryIDs.remove(recordID) }
        do {
            try await externalDirectoryBroker.resolveRecovery(
                recordID: recordID,
                summary: summary,
                decision: decision,
                trigger: .user,
                currentEnvironment: {
                    await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                }
            )
            await refreshExternalDirectoryRecoveries()
            errorMessage = nil
            switch decision {
            case .retain:
                statusMessage = String(
                    localized: "The recovery copy was retained. No file was deleted or restored."
                )
            case .deleteAfterUserConfirmation:
                statusMessage = String(
                    localized:
                        "The exact recovery copy was permanently deleted after confirmation. Live mirror files were not changed."
                )
            }
        } catch {
            await refreshExternalDirectoryRecoveries()
            errorMessage = String(
                localized: "External recovery failed: \(stableExternalDirectoryErrorCode(error))."
            )
        }
    }

    func prepareExternalDirectoryRecoveryExport(
        recordID: UUID,
        summary: ControlledMirrorRecoverySummary
    ) async -> ControlledMirrorRecoveryExport? {
        guard let externalDirectoryBroker, let paths,
            !runningExternalDirectoryIDs.contains(recordID)
        else { return nil }
        runningExternalDirectoryIDs.insert(recordID)
        defer { runningExternalDirectoryIDs.remove(recordID) }
        let outputDirectory = recoveryExportDirectory
        do {
            try externalDirectoryBroker.discardTemporaryRecoveryExports(
                from: outputDirectory
            )
            let export = try await externalDirectoryBroker.prepareRecoveryExport(
                recordID: recordID,
                summary: summary,
                outputDirectory: outputDirectory,
                trigger: .user,
                currentEnvironment: {
                    await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                }
            )
            statusMessage = String(
                localized:
                    "A verified snapshot of the recovery copy is ready for the system share sheet. The retained recovery copy was not changed."
            )
            errorMessage = nil
            return export
        } catch {
            await refreshExternalDirectoryRecoveries()
            errorMessage = String(
                localized:
                    "Recovery export failed: \(stableExternalDirectoryErrorCode(error)). The retained recovery copy was not changed."
            )
            return nil
        }
    }

    func discardExternalDirectoryRecoveryExport(
        _ export: ControlledMirrorRecoveryExport
    ) async {
        guard let externalDirectoryBroker else { return }
        do {
            try externalDirectoryBroker.discardRecoveryExport(
                export,
                from: recoveryExportDirectory
            )
        } catch {
            errorMessage = String(
                localized: "The temporary recovery export could not be removed safely."
            )
        }
    }

    var recoveryExportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "PsyRecoveryExports",
            isDirectory: true
        )
    }

    func removeExternalDirectory(_ id: UUID) async {
        do {
            let record = externalDirectories.first(where: { $0.id == id })
            try await externalDirectoryBroker?.remove(id: id)
            externalDirectories = await externalDirectoryBroker?.allRecords() ?? []
            if let folderID = record?.syncBinding.folderID.rawValue {
                statusMessage = String(
                    localized:
                        "Files authorization removed. Managed data and Syncthing folder \(folderID) were retained; remove that folder separately from Folders only if intended."
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func repairExternalDirectoryBinding(_ id: UUID) async {
        guard let externalDirectoryBroker else { return }
        do {
            try await externalDirectoryBroker.repairSyncBinding(id: id, snapshot: snapshot)
            externalDirectories = await externalDirectoryBroker.allRecords()
            await processExternalDirectoryBindingQueue()
            await refresh()
            if let record = externalDirectories.first(where: { $0.id == id }) {
                statusMessage = externalDirectoryBindingMessage(for: record)
            }
            errorMessage = nil
        } catch {
            externalDirectories = await externalDirectoryBroker.allRecords()
            errorMessage = error.localizedDescription
        }
    }

    func localizedExternalDirectoryMode(_ mode: ExternalDirectoryMode) -> String {
        switch mode {
        case .controlledMirror: String(localized: "Controlled Mirror")
        case .importOnly: String(localized: "Import Only")
        case .exportOnly: String(localized: "Export Only")
        case .readOnly: String(localized: "Read Only")
        case .direct: String(localized: "Direct")
        }
    }

    func processExternalDirectoryBindingQueue() async {
        guard let paths else { return }
        let input = policyInput(actions: [.exchangeIndex], trigger: .user)
        let environment = SyncEnvironmentSnapshot(
            network: input.network,
            power: input.power,
            transfer: input.transfer,
            safety: input.safety,
            capturedAt: input.now
        )
        _ = await CoreRuntime.shared.processPending(
            trigger: .user,
            paths: paths,
            environment: environment,
            currentEnvironment: {
                await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
            }
        )
    }

    func refreshExternalDirectoryRecoveries() async {
        guard let externalDirectoryBroker, let paths else {
            externalDirectoryRecoveries = [:]
            externalDirectoryRecoveryFailureCodes = [:]
            return
        }
        var summariesByRecord: [UUID: [ControlledMirrorRecoverySummary]] = [:]
        var failuresByRecord: [UUID: String] = [:]
        for record in externalDirectories where record.authorizationState == .active {
            guard record.syncBinding.phase == .verified else {
                failuresByRecord[record.id] = "binding_not_verified"
                continue
            }
            do {
                summariesByRecord[record.id] = try await externalDirectoryBroker.recoverySummaries(
                    recordID: record.id,
                    trigger: .user,
                    currentEnvironment: {
                        await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                    }
                )
            } catch {
                failuresByRecord[record.id] = stableExternalDirectoryErrorCode(error)
            }
        }
        externalDirectoryRecoveries = summariesByRecord
        externalDirectoryRecoveryFailureCodes = failuresByRecord
    }

    func stableExternalDirectoryErrorCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let error = error as? ExternalDirectoryError else { return "unavailable" }
        switch error {
        case .authorizationDenied: return "authorization_denied"
        case .bookmarkStale: return "bookmark_stale"
        case .unavailable: return "provider_unavailable"
        case .recordNotFound: return "record_not_found"
        case .unsupportedRecordSchema: return "unsupported_record_schema"
        case .capabilityProbeFailed: return "capability_probe_failed"
        case .deletionNotSupported: return "deletion_not_supported"
        case .deletionConfirmationUnavailable: return "deletion_confirmation_unavailable"
        case .deletionConfirmationChanged: return "deletion_confirmation_changed"
        case .authorizationAlreadyRevoked: return "authorization_revoked"
        case .mirrorAlreadyRunning: return "mirror_already_running"
        case .bindingNotVerified: return "binding_not_verified"
        case .invalidBindingIdentifier: return "invalid_binding_identifier"
        case .unsafeManagedRoot: return "unsafe_managed_root"
        case .bindingConflict: return "binding_conflict"
        case .policyDenied: return "policy_denied"
        case .rescanQueueFailed: return "rescan_queue_failed"
        case .recoveryUnavailable: return "recovery_unavailable"
        case .recoveryChanged: return "recovery_changed"
        case .recoveryActive: return "recovery_active"
        case .recoveryExportFailed: return "recovery_export_failed"
        case .recoveryDisposalFailed: return "recovery_disposal_failed"
        }
    }

    func externalDirectoryBindingMessage(for record: ExternalDirectoryRecord) -> String {
        switch record.syncBinding.phase {
        case .verified:
            String(
                localized:
                    "Syncthing folder \(record.syncBinding.folderID.rawValue) is verified at the managed mirror root. It is local-only until explicitly shared with a peer."
            )
        case .queued:
            String(
                localized:
                    "Syncthing folder registration is queued. The mirror is not reported as connected until a snapshot verifies its exact managed root."
            )
        case .repairRequired:
            String(
                localized:
                    "The Syncthing folder binding needs explicit repair. Managed data was retained and no folder was recreated automatically."
            )
        case .conflict:
            String(
                localized:
                    "The Syncthing folder binding conflicts with the current snapshot. No replacement or removal was queued."
            )
        case .failed:
            String(
                localized:
                    "Syncthing folder registration failed. Managed data was retained; use Repair Binding to retry safely."
            )
        }
    }

}
