import Foundation
import PsyCore
import UIKit
import UserNotifications

extension AppModel {
    @discardableResult
    func submit(
        kind: CoreCommandKind,
        folderID: FolderID? = nil,
        itemID: String? = nil,
        arguments: [String: String] = [:],
        expectedFolderIncarnationDigest: String? = nil,
        temporaryPolicyProfileID: UUID? = nil,
        override: Bool = false
    ) async -> Bool {
        guard !isSubmittingCommand else {
            statusMessage = String(localized: "Another action is finishing. Try again in a moment.")
            return false
        }
        isSubmittingCommand = true
        defer { isSubmittingCommand = false }
        return await syncController.withSuspension { [self] in
            guard !Task.isCancelled else { return false }
            return await executeCommand(
                kind: kind, folderID: folderID, itemID: itemID, arguments: arguments,
                expectedFolderIncarnationDigest: expectedFolderIncarnationDigest,
                temporaryPolicyProfileID: temporaryPolicyProfileID, override: override
            )
        }
    }

    @discardableResult
    func executeCommand(
        kind: CoreCommandKind,
        folderID: FolderID? = nil,
        itemID: String? = nil,
        arguments: [String: String] = [:],
        expectedFolderIncarnationDigest: String? = nil,
        temporaryPolicyProfileID: UUID? = nil,
        override: Bool = false
    ) async -> Bool {
        guard kind.embeddedBridgeCapability == .supported else {
            statusMessage = String(
                localized: "The embedded core does not implement \(kind.rawValue); no request was queued."
            )
            return false
        }
        guard !override else {
            statusMessage = String(
                localized:
                    "Temporary policy overrides are not available for durable queued requests. No request was queued."
            )
            return false
        }
        guard let paths else { return false }
        let temporaryPolicyProfile: TemporarySyncPolicyProfile?
        if let temporaryPolicyProfileID {
            guard
                let profile = temporaryPolicyProfiles.first(where: {
                    $0.id == temporaryPolicyProfileID
                })
            else {
                errorMessage = String(
                    localized: "The named temporary policy profile is unavailable."
                )
                return false
            }
            temporaryPolicyProfile = profile
        } else {
            temporaryPolicyProfile = nil
        }
        if Self.requiresCanonicalConfiguration(kind), snapshot.configurationRevision == nil {
            guard
                await ensureCanonicalConfigurationAvailable(
                    paths: paths,
                    trigger: .user
                )
            else { return false }
        }
        if Self.requiresExactFolderIncarnation(kind), let folderID {
            guard let expectedFolderIncarnationDigest,
                folderIncarnationDigests[folderID] == expectedFolderIncarnationDigest
            else {
                errorMessage = String(
                    localized:
                        "This folder action no longer matches the exact folder incarnation you reviewed. Refresh before trying again."
                )
                return false
            }
        }
        let invocationID = UUID()
        let commands: [CoreCommand]
        do {
            commands = try await Task.detached(priority: .userInitiated) {
                try ScopedCoreCommandProducer(paths: paths).prepareCommands(
                    invocationID: invocationID,
                    kind: kind,
                    folderID: folderID,
                    itemID: itemID,
                    arguments: arguments,
                    expectedFolderIncarnationDigest: expectedFolderIncarnationDigest,
                    temporaryPolicyProfile: temporaryPolicyProfile,
                    trigger: .user
                )
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        guard !commands.isEmpty else {
            statusMessage = String(localized: "There are no configured folders to synchronize.")
            return false
        }

        // Durable commands are intentionally unprivileged. The runtime resolves
        // exact-folder policy and V2 transfer accounting from the command's
        // durable trigger immediately before opening its explicit session.
        let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
        var didEnqueue = false
        do {
            try await Task.detached(priority: .userInitiated) {
                let queue = CoreCommandQueue(root: paths.commandQueue)
                if kind == .sync, folderID == nil {
                    try queue.enqueueAtomically(commands, batchID: invocationID)
                } else if let command = commands.first {
                    try queue.enqueue(command)
                }
            }.value
            didEnqueue = true
            statusMessage = String(localized: "Request queued. Completion has not been reported yet.")
            let execution = await processQueuedCommands(
                commands,
                trigger: .user,
                paths: paths,
                initialEnvironment: environment
            )
            let results = execution.results
            let report = CommandExecutionReport(commands: commands, results: results, outcome: execution.outcome)
            if report.succeeded {
                try await Task.detached(priority: .utility) {
                    let producer = ScopedCoreCommandProducer(paths: paths)
                    for command in commands {
                        guard let result = results[command.id] else { continue }
                        _ = try producer.reconcileSuccessfulFolderRemoval(
                            command: command,
                            result: result
                        )
                    }
                }.value
                statusMessage = String(localized: "Request completed successfully.")
            } else if let result = commands.compactMap({ results[$0.id] }).first(where: {
                $0.status != .succeeded
            }) {
                switch result.status {
                case .succeeded:
                    break
                case .retryable:
                    statusMessage = String(
                        localized:
                            "Request remains queued for retry: \(result.errorCode ?? String(localized: "unknown"))."
                    )
                case .blocked:
                    if result.errorCode == "peer_index_proof_unavailable" {
                        statusMessage = String(
                            localized:
                                "The peer did not provide conclusive index-completion proof. Update the peer if possible, or retry after its index has settled. No synchronization success was reported."
                        )
                    } else {
                        statusMessage = String(
                            localized:
                                "Request was blocked and its result was recorded; it will not retry automatically: \(result.errorCode ?? String(localized: "unknown"))."
                        )
                    }
                case .failed:
                    statusMessage = String(
                        localized:
                            "Request failed and its result was recorded; it will not retry automatically: \(result.errorCode ?? String(localized: "unknown"))."
                    )
                }
            } else if case .failed(let code) = execution.outcome {
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
            return report.succeeded
        } catch {
            errorMessage = error.localizedDescription
            if didEnqueue { statusMessage = String(localized: "Request queued. Completion has not been reported yet.") }
            return false
        }
    }

    func processQueuedCommands(
        _ commands: [CoreCommand],
        trigger: SyncTrigger,
        paths: SharedContainerPaths,
        initialEnvironment: SyncEnvironmentSnapshot
    ) async -> (outcome: CoreRunOutcome?, results: [UUID: CoreCommandResult]) {
        let report = await CoreCommandExecutor().execute(
            commands, trigger: trigger, paths: paths, environment: initialEnvironment,
            currentEnvironment: { await SyncEnvironmentSnapshot.captureSystemState(paths: paths) }
        )
        return (report.outcome, report.results)
    }

}
