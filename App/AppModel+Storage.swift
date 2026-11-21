import Foundation
import PsyCore
import UIKit
import UserNotifications

extension AppModel {
    func refreshCoreMutationRecoveries(reset: Bool = true) async {
        return await syncController.withSuspension { [self] in
            guard !Task.isCancelled else { return }
            guard let paths, !isCoreMutationRecoveryLoading else { return }
            isCoreMutationRecoveryLoading = true
            defer { isCoreMutationRecoveryLoading = false }
            await discardOrphanedCoreMutationRecoveryExports(paths: paths)
            await retryPendingCoreMutationRecoveryExportCleanup(paths: paths)
            let requestedCursor = reset ? nil : coreMutationRecoveryCursor
            let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
            let outcome = await CoreRuntime.shared.mutationRecoveries(
                after: requestedCursor,
                limit: 100,
                trigger: .user,
                paths: paths,
                environment: environment,
                currentEnvironment: {
                    await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                }
            )
            switch outcome {
            case .completed(let page):
                if reset {
                    coreMutationRecoveries = page.recoveries
                } else {
                    let existing = Set(coreMutationRecoveries.map(\.recoveryID))
                    guard page.recoveries.allSatisfy({ !existing.contains($0.recoveryID) }) else {
                        coreMutationRecoveryFailureCode = "coreInvalidResponse"
                        return
                    }
                    coreMutationRecoveries.append(contentsOf: page.recoveries)
                }
                coreMutationRecoveryCursor = page.nextCursor
                hasMoreCoreMutationRecoveries = page.hasMore
                coreMutationRecoveryFailureCode = nil
                await deliverNotifications(
                    snapshot: snapshot,
                    mutationRecoveries: coreMutationRecoveries
                )
            case .coreBusy:
                coreMutationRecoveryFailureCode = "core_busy"
            case .configurationUnavailable:
                coreMutationRecoveryFailureCode = "policy_configuration_unavailable"
            case .policyDenied(let reasons):
                coreMutationRecoveryFailureCode = reasons.first?.rawValue ?? "policy_denied"
            case .failed(let code):
                coreMutationRecoveryFailureCode = code
            }
        }
    }

    func loadMoreCoreMutationRecoveries() async {
        guard hasMoreCoreMutationRecoveries else { return }
        await refreshCoreMutationRecoveries(reset: false)
    }

    func disposeCoreMutationRecovery(
        _ summary: CoreMutationRecoverySummary,
        afterDangerousReview: Bool
    ) async {
        do {
            let command =
                try afterDangerousReview
                ? CoreMutationRecoveryCommandBuilder.disposeAfterDangerousReview(summary)
                : CoreMutationRecoveryCommandBuilder.dispose(summary)
            _ = await submit(kind: command.kind, arguments: command.arguments)
            await refreshCoreMutationRecoveries(reset: true)
        } catch {
            errorMessage = String(
                localized: "The recovery cleanup request was rejected before any recovery data changed."
            )
            await refreshCoreMutationRecoveries(reset: true)
        }
    }

    func prepareCoreMutationRecoveryExport(
        _ summary: CoreMutationRecoverySummary
    ) async -> CoreMutationRecoveryExport? {
        return await syncController.withSuspension { [self] in
            guard !Task.isCancelled else { return nil }
            guard let paths,
                !runningCoreMutationRecoveryExportIDs.contains(summary.recoveryID)
            else { return nil }
            runningCoreMutationRecoveryExportIDs.insert(summary.recoveryID)
            defer { runningCoreMutationRecoveryExportIDs.remove(summary.recoveryID) }
            await retryPendingCoreMutationRecoveryExportCleanup(paths: paths)
            let outcome = await CoreRuntime.shared.prepareMutationRecoveryExport(
                summary,
                trigger: .user,
                paths: paths
            )
            switch outcome {
            case .completed(let export):
                pendingCoreMutationRecoveryExportCleanup[export.exportID] = export
                statusMessage = String(
                    localized:
                        "A verified snapshot of the mutation recovery copy is ready for the system share sheet. The retained recovery copy was not changed."
                )
                errorMessage = nil
                return export
            case .coreBusy:
                errorMessage = String(
                    localized:
                        "Mutation recovery export failed: core_busy. The retained recovery copy was not changed."
                )
            case .configurationUnavailable:
                errorMessage = String(
                    localized:
                        "Mutation recovery export failed: policy_configuration_unavailable. The retained recovery copy was not changed."
                )
            case .failed(let code):
                errorMessage = String(
                    localized:
                        "Mutation recovery export failed: \(code). The retained recovery copy was not changed."
                )
            }
            await refreshCoreMutationRecoveries(reset: true)
            return nil
        }
    }

    func discardCoreMutationRecoveryExport(
        _ export: CoreMutationRecoveryExport
    ) async {
        return await syncController.withSuspension { [self] in
            guard !Task.isCancelled else { return }
            guard let paths else { return }
            pendingCoreMutationRecoveryExportCleanup[export.exportID] = export
            let outcome = await CoreRuntime.shared.discardMutationRecoveryExport(
                export,
                trigger: .user,
                paths: paths
            )
            switch outcome {
            case .completed:
                pendingCoreMutationRecoveryExportCleanup.removeValue(forKey: export.exportID)
            case .coreBusy:
                errorMessage = String(
                    localized:
                        "The temporary mutation recovery export is awaiting safe cleanup because the core is busy."
                )
            case .configurationUnavailable, .failed:
                errorMessage = String(
                    localized: "The temporary mutation recovery export could not be removed safely."
                )
            }
        }
    }

    func retryPendingCoreMutationRecoveryExportCleanup(
        paths: SharedContainerPaths
    ) async {
        for export in Array(pendingCoreMutationRecoveryExportCleanup.values) {
            let outcome = await CoreRuntime.shared.discardMutationRecoveryExport(
                export,
                trigger: .user,
                paths: paths
            )
            if case .completed = outcome {
                pendingCoreMutationRecoveryExportCleanup.removeValue(forKey: export.exportID)
            }
        }
    }

    func discardOrphanedCoreMutationRecoveryExports(
        paths: SharedContainerPaths
    ) async {
        let root = paths.coreMutationRecoveryExports
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return }
        guard let attributes = try? manager.attributesOfItem(atPath: root.path),
            attributes[.type] as? FileAttributeType == .typeDirectory,
            (try? manager.destinationOfSymbolicLink(atPath: root.path)) == nil,
            let names = try? manager.contentsOfDirectory(atPath: root.path)
        else {
            errorMessage = String(
                localized: "The temporary mutation recovery export could not be removed safely."
            )
            return
        }
        let prefix = ".psy-core-recovery-export-"
        var exportIDs: [UUID] = []
        for name in names {
            let rawID = String(name.dropFirst(prefix.count))
            guard name.hasPrefix(prefix),
                let exportID = UUID(uuidString: rawID),
                rawID == exportID.uuidString.lowercased()
            else {
                errorMessage = String(
                    localized:
                        "The temporary mutation recovery export could not be removed safely."
                )
                return
            }
            guard pendingCoreMutationRecoveryExportCleanup[exportID] == nil else {
                continue
            }
            exportIDs.append(exportID)
        }
        for exportID in exportIDs {
            let outcome = await CoreRuntime.shared.discardMutationRecoveryExport(
                exportID: exportID,
                trigger: .user,
                paths: paths
            )
            switch outcome {
            case .completed, .coreBusy:
                break
            case .configurationUnavailable, .failed:
                errorMessage = String(
                    localized:
                        "The temporary mutation recovery export could not be removed safely."
                )
                return
            }
        }
    }

    @discardableResult
    func showIndexedItemInFiles(_ item: IndexedItem) async -> Bool {
        do {
            let expectedFence = FileProviderRevealFence(item: item)
            let resolved = try await FileProviderRevealService().userVisibleURL(
                itemID: item.id,
                expectedFence: expectedFence
            )
            guard resolved.url.startAccessingSecurityScopedResource() else {
                throw FileProviderRevealError.permissionDenied
            }
            defer { resolved.url.stopAccessingSecurityScopedResource() }
            _ = try await FileProviderRevealService().validateCurrent(
                itemID: resolved.item.id,
                expectedFence: FileProviderRevealFence(item: resolved.item)
            )
            let opened = await withCheckedContinuation { continuation in
                UIApplication.shared.open(resolved.url, options: [:]) { accepted in
                    continuation.resume(returning: accepted)
                }
            }
            guard opened else { throw FileProviderRevealError.openRejected }
            statusMessage = String(localized: "Opened the item in Files.")
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func downloadIndexedItem(_ item: IndexedItem) async -> Bool {
        do {
            _ = try await FileProviderStorageActionService().download(itemID: item.id)
            statusMessage = String(
                localized:
                    "Download requested. This does not keep the item downloaded after iOS needs the cache space."
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func evictFilesCache(for item: IndexedItem) async -> Bool {
        return await syncController.withSuspension { [self] in
            guard !Task.isCancelled else { return false }
            do {
                let result = try await FileProviderStorageActionService().evictItem(
                    itemID: item.id,
                    trigger: .user
                )
                switch result {
                case .waitingForUpload:
                    statusMessage = String(
                        localized:
                            "Waiting for another Syncthing device to receive the complete current version. This download will be removed automatically afterward."
                    )
                case .retained:
                    statusMessage = String(
                        localized: "The item is kept downloaded. Its newer retention choice was preserved."
                    )
                case .evicted:
                    statusMessage = String(
                        localized:
                            "Removed the download from this device. The global-index placeholder remains and no Syncthing deletion was created."
                    )
                case .systemEvictedAwaitingCoreFinalization:
                    statusMessage = String(
                        localized:
                            "iOS removed the local download. Finalizing this device's content-availability state without deleting the global-index item or peer copies."
                    )
                case .directorySummary(_, let removed, let waiting, let failed):
                    statusMessage = String(
                        localized:
                            "Removed \(removed) downloaded files; \(waiting) are waiting for upload and will be removed automatically; \(failed) could not be removed."
                    )
                }
                await refreshContentRetentionProjection()
                errorMessage = nil
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
    }

    @discardableResult
    func keepIndexedItemDownloaded(_ item: IndexedItem) async -> Bool {
        return await syncController.withSuspension { [self] in
            guard !Task.isCancelled else { return false }
            do {
                _ = try await FileProviderStorageActionService().keepDownloaded(itemID: item.id)
                statusMessage = String(
                    localized:
                        "Keep Downloaded is saved. If content is not local yet, iOS will download it when the File Provider domain can run."
                )
                await refreshContentRetentionProjection()
                errorMessage = nil
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
    }

    @discardableResult
    func deleteIndexedItemFromSyncthing(_ item: IndexedItem) async -> Bool {
        let accepted = await submit(
            kind: .delete,
            folderID: item.folderID,
            itemID: item.id,
            arguments: [
                "baseContentVersion": item.contentVersion.base64EncodedString(),
                "baseMetadataVersion": item.metadataVersion.base64EncodedString(),
                "propagatesToPeers": "true",
                "recursive": String(item.isDirectory),
            ]
        )
        if accepted {
            statusMessage = String(
                localized:
                    "Deletion was submitted to Syncthing and will propagate to other devices. This is different from Remove Download."
            )
        }
        return accepted
    }

}
