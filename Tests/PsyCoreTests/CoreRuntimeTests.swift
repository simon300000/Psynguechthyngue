import CryptoKit
import Foundation
import XCTest

@testable import PsyCore

final class CoreRuntimeTests: XCTestCase {
    func testMaterializationRejectsDuplicateFolderBeforeOpeningAnyCoreSession() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "duplicate-materialization"))
        let folderRoot = try paths.createManagedFolder(for: folderID)
        var duplicate = FolderRecord(
            id: folderID,
            label: "First",
            localPath: folderRoot.path
        )
        duplicate.label = "Second"
        try SharedSnapshotStore(snapshotURL: paths.snapshot).write(
            CoreSnapshot(
                generation: 1,
                folders: [
                    FolderRecord(id: folderID, label: "First", localPath: folderRoot.path),
                    duplicate,
                ]
            )
        )
        let item = IndexedItem(
            id: "duplicate-item",
            folderID: folderID,
            relativePath: "remote.bin",
            isDirectory: false,
            size: 4,
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data([1]),
            metadataVersion: Data([2]),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 1
        )
        let client = MaterializationLifecycleCountingCoreClient()
        let destination = root.appendingPathComponent("must-not-materialize.bin")

        let outcome = await CoreRuntime(clientFactory: { client }).materialize(
            item,
            to: destination,
            trigger: .fileProvider,
            paths: paths,
            environment: .permissiveForTesting,
            destinationAvailableCapacity: { _ in .max }
        )

        XCTAssertEqual(outcome, .failed(code: "duplicate_folder"))
        let configurationOpenCount = await client.configurationOpenCount()
        let networkStartCount = await client.networkStartCount()
        XCTAssertEqual(configurationOpenCount, 0)
        XCTAssertEqual(networkStartCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDirtyPendingUploadCanStartRuntimeAndRecoveryQueryWhileMaterializationStaysDenied() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "dirty-files-folder"))
        let recovery = try CoreMutationRecoverySummary(
            recoveryID: String(repeating: "a", count: 64),
            folderID: folderID,
            commandKind: .modify,
            relativePath: "Drafts/edited.txt",
            payloadKind: .file,
            digest: String(repeating: "b", count: 64),
            bytes: 39,
            createdAt: Date(timeIntervalSince1970: 1),
            status: .retainedRequiresUserConfirmation
        )
        let page = try CoreMutationRecoveryPage(
            recoveries: [recovery],
            nextCursor: nil,
            hasMore: false
        )
        let client = RecordingCoreClient(recoveryPage: page)
        let runtime = CoreRuntime(clientFactory: { client })
        var dirtyEnvironment = SyncEnvironmentSnapshot.permissiveForTesting
        dirtyEnvironment.safety.hasUnuploadedChanges = true
        let liveDirtyEnvironment = dirtyEnvironment

        let queryOutcome = await runtime.mutationRecoveries(
            trigger: .user,
            paths: paths,
            environment: dirtyEnvironment,
            currentEnvironment: { liveDirtyEnvironment }
        )

        XCTAssertEqual(queryOutcome, .completed(page))
        let queryStarted = await client.wasStarted()
        XCTAssertFalse(queryStarted)

        let materializationClient = RecordingCoreClient()
        var item = IndexedItem(
            id: "dirty-materialization",
            folderID: folderID,
            relativePath: "Drafts/edited.txt",
            isDirectory: false,
            size: 39,
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 1, count: 32),
            metadataVersion: Data(repeating: 2, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 1
        )
        _ = try runtimeTestCommand(
            kind: .rescan,
            paths: paths,
            folderID: folderID,
            trigger: .user
        )
        let cleanTargetWithUnrelatedDirtyState = await CoreRuntime(
            clientFactory: { materializationClient }
        ).materialize(
            item,
            to: root.appendingPathComponent("must-not-materialize.txt"),
            trigger: .fileProvider,
            paths: paths,
            environment: dirtyEnvironment,
            destinationAvailableCapacity: { _ in .max }
        )
        XCTAssertNotEqual(
            cleanTargetWithUnrelatedDirtyState,
            .policyDenied(reasons: [.unuploadedChanges])
        )
        let cleanMaterializationStarted = await materializationClient.wasStarted()
        XCTAssertTrue(cleanMaterializationStarted)

        item.hasUnuploadedChanges = true
        let dirtyTargetClient = RecordingCoreClient()
        let dirtyTargetOutcome = await CoreRuntime(clientFactory: { dirtyTargetClient }).materialize(
            item,
            to: root.appendingPathComponent("dirty-target-must-not-materialize.txt"),
            trigger: .fileProvider,
            paths: paths,
            environment: dirtyEnvironment,
            destinationAvailableCapacity: { _ in .max }
        )
        XCTAssertEqual(dirtyTargetOutcome, .policyDenied(reasons: [.unuploadedChanges]))
        let dirtyTargetStarted = await dirtyTargetClient.wasStarted()
        XCTAssertFalse(dirtyTargetStarted)
    }

    func testMutationRecoveryExportUsesConfigurationSessionAndExactCleanup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "recovery-export-folder"))
        let summary = try CoreMutationRecoverySummary(
            recoveryID: String(repeating: "c", count: 64),
            folderID: folderID,
            commandKind: .modify,
            relativePath: "Drafts/recoverable.txt",
            payloadKind: .file,
            digest: String(repeating: "d", count: 64),
            bytes: 25,
            createdAt: Date(timeIntervalSince1970: 1),
            status: .retainedRequiresUserConfirmation
        )
        let client = RecoveryExportCoreClient(root: root)
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.prepareMutationRecoveryExport(
            summary,
            trigger: .user,
            paths: paths
        )
        guard case .completed(let export) = outcome else {
            return XCTFail("Expected a completed recovery export, got \(outcome)")
        }
        XCTAssertEqual(try Data(contentsOf: export.url), Data(repeating: 0x52, count: 25))
        let observed = await client.exportedSummary()
        XCTAssertEqual(observed, summary)
        let exportAcknowledgementCount = await client.acknowledgementCount()
        XCTAssertEqual(exportAcknowledgementCount, 1)
        let wasStarted = await client.wasLegacyStarted()
        XCTAssertFalse(wasStarted)

        let cleanup = await runtime.discardMutationRecoveryExport(
            export,
            trigger: .user,
            paths: paths
        )
        XCTAssertEqual(cleanup, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.url.path))
        let cleanupAcknowledgementCount = await client.acknowledgementCount()
        XCTAssertEqual(cleanupAcknowledgementCount, 2)
        let repeatedCleanup = await runtime.discardMutationRecoveryExport(
            exportID: export.exportID,
            trigger: .user,
            paths: paths
        )
        XCTAssertEqual(repeatedCleanup, .completed)
        let repeatedCleanupAcknowledgementCount = await client.acknowledgementCount()
        XCTAssertEqual(repeatedCleanupAcknowledgementCount, 3)
        let retainedSourceUnchanged = await client.retainedSourceIsUnchanged()
        XCTAssertTrue(retainedSourceUnchanged)
    }

    func testDirtyPendingUploadDoesNotDeadlockQueuedSyncStart() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(kind: .sync, paths: paths, trigger: .user)
        try CoreCommandQueue(root: paths.commandQueue).enqueue(command)
        let client = RecordingCoreClient()
        var environment = SyncEnvironmentSnapshot.permissiveForTesting
        environment.safety.hasUnuploadedChanges = true
        let liveEnvironment = environment

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .user,
            paths: paths,
            environment: environment,
            currentEnvironment: { liveEnvironment }
        )

        guard case .completed(processedCommands: 1, snapshotGeneration: let generation) = outcome
        else {
            return XCTFail("Expected successful scoped run, got \(outcome)")
        }
        XCTAssertGreaterThan(generation, 0)
        let executed = await client.executedCommandIDs()
        XCTAssertEqual(executed, [command.id])
    }

    func testFileProviderOwnerDoesNotClaimUnrelatedUserWork() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(kind: .sync, paths: paths, trigger: .user)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = RecordingCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })

        let fileProviderOutcome = await runtime.processPending(
            trigger: .fileProvider,
            paths: paths,
            environment: .permissiveForTesting
        )

        guard case .completed(processedCommands: 0, snapshotGeneration: _) = fileProviderOutcome
        else {
            return XCTFail("File Provider must leave unrelated user work queued: \(fileProviderOutcome)")
        }
        let fileProviderExecutions = await client.executedCommandIDs()
        XCTAssertTrue(fileProviderExecutions.isEmpty)
        XCTAssertEqual(try queue.pending().map(\.id), [command.id])

        let userOutcome = await runtime.processPending(
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting
        )
        guard case .completed(processedCommands: 1, snapshotGeneration: _) = userOutcome else {
            return XCTFail("The owning App opportunity should still execute the user task: \(userOutcome)")
        }
        let userExecutions = await client.executedCommandIDs()
        XCTAssertEqual(userExecutions, [command.id])
    }

    func testRecoveryDisposalTransientFailureRetriesButChangedSummaryIsTerminal() async throws {
        let folderID = try XCTUnwrap(FolderID(rawValue: "recovery-result-folder"))
        let summary = try CoreMutationRecoverySummary(
            recoveryID: String(repeating: "c", count: 64),
            folderID: folderID,
            commandKind: .modify,
            relativePath: "edited.txt",
            payloadKind: .file,
            digest: String(repeating: "d", count: 64),
            bytes: 8,
            createdAt: Date(timeIntervalSince1970: 1),
            status: .retainedRequiresUserConfirmation
        )

        let retryRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: retryRoot) }
        let retryPaths = SharedContainerPaths(root: retryRoot)
        let retryCommand = try CoreMutationRecoveryCommandBuilder.dispose(summary)
        let retryQueue = CoreCommandQueue(root: retryPaths.commandQueue)
        try retryQueue.enqueue(retryCommand)
        let retryOutcome = await CoreRuntime(clientFactory: {
            RecoveryRejectingCoreClient(code: "recovery_disposal_interrupted")
        }).processPending(
            trigger: .user,
            paths: retryPaths,
            environment: .permissiveForTesting
        )
        XCTAssertEqual(retryOutcome, .failed(code: "recovery_disposal_interrupted"))
        XCTAssertEqual(try retryQueue.pending().map(\.id), [retryCommand.id])
        XCTAssertEqual(try retryQueue.result(for: retryCommand.id)?.status, .retryable)

        let changedRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: changedRoot) }
        let changedPaths = SharedContainerPaths(root: changedRoot)
        let changedCommand = try CoreMutationRecoveryCommandBuilder.dispose(summary)
        let changedQueue = CoreCommandQueue(root: changedPaths.commandQueue)
        try changedQueue.enqueue(changedCommand)
        _ = await CoreRuntime(clientFactory: {
            RecoveryRejectingCoreClient(code: "recovery_changed")
        }).processPending(
            trigger: .user,
            paths: changedPaths,
            environment: .permissiveForTesting
        )
        XCTAssertTrue(try changedQueue.pending().isEmpty)
        XCTAssertEqual(try changedQueue.result(for: changedCommand.id)?.status, .blocked)
    }

    func testSuccessfulRunPersistsSnapshotResultAndAcknowledgesCommand() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(kind: .sync, paths: paths, trigger: .user)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = RecordingCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting
        )

        guard case .completed(processedCommands: 1, snapshotGeneration: let generation) = outcome
        else {
            return XCTFail("Expected successful scoped run, got \(outcome)")
        }
        XCTAssertGreaterThan(generation, 0)
        XCTAssertEqual(try queue.pending(), [])
        let result = try XCTUnwrap(queue.result(for: command.id))
        let snapshot = try XCTUnwrap(SharedSnapshotStore(snapshotURL: paths.snapshot).read())
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(snapshot.generation, generation)
        XCTAssertEqual(result.snapshotGeneration, snapshot.generation)
        XCTAssertEqual(result.ownerEpoch, snapshot.ownerEpoch)
        XCTAssertEqual(result.instanceID, snapshot.instanceID)
        XCTAssertEqual(result.ownerEpoch, 1)
        XCTAssertNotNil(result.instanceID)
        let executedCommandIDs = await client.executedCommandIDs()
        XCTAssertEqual(executedCommandIDs, [command.id])
        let acknowledgedCommandIDs = await client.acknowledgedCommandIDs()
        XCTAssertEqual(acknowledgedCommandIDs, [])

        let cleanup = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )
        guard
            case .completed(processedCommands: 0, snapshotGeneration: let cleanupGeneration) =
                cleanup
        else {
            return XCTFail("Expected deferred native ledger cleanup, got \(cleanup)")
        }
        XCTAssertGreaterThan(cleanupGeneration, generation)
        let cleanedCommandIDs = await client.acknowledgedCommandIDs()
        XCTAssertEqual(cleanedCommandIDs, [command.id])
    }

    func testSuccessfulRunRecordsExactNetworkTransferTotals() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(kind: .sync, paths: paths, trigger: .user)
        try CoreCommandQueue(root: paths.commandQueue).enqueue(command)
        let client = RecordingCoreClient(
            networkTotals: CoreNetworkTransferTotals(receivedBytes: 12, sentBytes: 34)
        )

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting
        )

        guard case .completed(processedCommands: 1, snapshotGeneration: let generation) = outcome
        else {
            return XCTFail("Expected successful transfer accounting run, got \(outcome)")
        }
        XCTAssertGreaterThan(generation, 0)
        let history = try XCTUnwrap(try SyncRunHistory(url: paths.history).recent(limit: 1).first)
        XCTAssertEqual(history.transferredBytes, 46)
        XCTAssertEqual(history.networkReceivedBytes, 12)
        XCTAssertEqual(history.networkSentBytes, 34)
        XCTAssertEqual(history.measuredNetworkBytes, 46)
    }

    func testCoreRecoveryProtectsLiveExternalMirrorOwnerThenRecoversItAfterLeaseRelease() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let firstCommand = try runtimeTestCommand(
            kind: .sync,
            paths: paths,
            trigger: .user
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(firstCommand)
        let folderID = try XCTUnwrap(firstCommand.folderID)
        let context = try FolderIncarnationStore(url: paths.folderIncarnations)
            .policyContext(for: folderID)
        let document = try SyncPolicyStore(url: paths.policy).loadDocument()
        let store = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        )
        let ownerLease = try TransferAccountingOwnerLease.acquire(
            directoryURL: store.ownerLeaseDirectoryURL
        )
        let binding = TransferAccountingGrantBinding(
            workKind: .externalMirror,
            folderID: context.folderID,
            folderIncarnationDigest: context.folderIncarnationDigest,
            taskID: UUID(),
            runID: UUID(),
            sessionID: UUID(),
            planDigest: String(repeating: "e", count: 64)
        )
        let accountingDate = Date()
        _ = try store.reserve(
            ownerID: ownerLease.ownerID,
            binding: binding,
            grantBytes: 40,
            runLimitBytes: 40,
            globalDailyLimitBytes: nil,
            folderDailyLimitBytes: nil,
            expiresAt: accountingDate.addingTimeInterval(3_600),
            at: accountingDate
        )
        let runtime = CoreRuntime(clientFactory: { RecordingCoreClient() })

        let first = await runtime.processPending(
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting
        )

        guard case .completed = first else {
            ownerLease.release()
            return XCTFail("Expected the first core run to complete, got \(first)")
        }
        var usage = try store.usage(for: binding, at: accountingDate)
        XCTAssertEqual(usage.folderActiveReservedBytes, 40)
        XCTAssertEqual(usage.folderCommittedBytes, 0)

        ownerLease.release()
        let secondCommand = try runtimeTestCommand(
            kind: .sync,
            paths: paths,
            folderID: folderID,
            trigger: .user
        )
        try queue.enqueue(secondCommand)
        let second = await runtime.processPending(
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting
        )

        guard case .completed = second else {
            return XCTFail("Expected the recovery core run to complete, got \(second)")
        }
        usage = try store.usage(for: binding, at: accountingDate)
        XCTAssertEqual(usage.folderActiveReservedBytes, 0)
        XCTAssertEqual(usage.folderCommittedBytes, 40)
    }

    func testCompletedQueueEntriesDriveBridgeLedgerCleanupOnNextOwnerRun() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(kind: .sync, paths: paths, trigger: .user)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(.init(commandID: command.id, status: .succeeded))
        try queue.acknowledge(command)
        XCTAssertEqual(try queue.completed().map(\.id), [command.id])
        let client = RecordingCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .completed(processedCommands: 0, snapshotGeneration: 3))
        let acknowledged = await client.acknowledgedCommandIDs()
        XCTAssertEqual(acknowledged, [command.id])
        XCTAssertEqual(try queue.completed(), [])
        XCTAssertEqual(try queue.result(for: command.id)?.status, .succeeded)
    }

    func testSucceededRemoveResultDiscardsPolicyAfterRestartBeforeQueueAcknowledgement() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "remove-policy-after-result"))
        let command = try runtimeTestCommand(
            kind: .removeFolder,
            paths: paths,
            folderID: folderID,
            trigger: .user
        )
        let context = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: try XCTUnwrap(command.folderIncarnationDigest)
        )
        let policyStore = SyncPolicyStore(url: paths.policy)
        _ = try policyStore.saveFolderPolicy(
            .init(allowBackgroundUpload: false),
            queuePriority: .high,
            for: context
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(.init(commandID: command.id, status: .succeeded))
        let client = RecordingCoreClient()

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        guard case .completed(processedCommands: 0, snapshotGeneration: _) = outcome else {
            return XCTFail("Expected completed cleanup, got \(outcome)")
        }
        XCTAssertTrue(try queue.pending().isEmpty)
        XCTAssertTrue(try queue.completed().isEmpty)
        XCTAssertTrue(try policyStore.loadDocument().folderOverrides.isEmpty)
        let acknowledged = await client.acknowledgedCommandIDs()
        XCTAssertEqual(acknowledged, [command.id])
    }

    func testCompletedRemoveHandoffDiscardsExactPolicyAndMissingOverrideIsIdempotent() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "remove-policy-completed"))
        let command = try runtimeTestCommand(
            kind: .removeFolder,
            paths: paths,
            folderID: folderID,
            trigger: .user
        )
        let context = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: try XCTUnwrap(command.folderIncarnationDigest)
        )
        let policyStore = SyncPolicyStore(url: paths.policy)
        _ = try policyStore.saveFolderPolicy(
            .init(allowBackgroundScan: false),
            queuePriority: .normal,
            for: context
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(.init(commandID: command.id, status: .succeeded))
        try queue.acknowledge(command)

        let first = await CoreRuntime(clientFactory: { RecordingCoreClient() }).processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        guard case .completed(processedCommands: 0, snapshotGeneration: _) = first else {
            return XCTFail("Expected completed cleanup, got \(first)")
        }
        XCTAssertTrue(try policyStore.loadDocument().folderOverrides.isEmpty)
        XCTAssertTrue(try queue.completed().isEmpty)

        let missingPolicyCommand = try runtimeTestCommand(
            kind: .removeFolder,
            paths: paths,
            folderID: try XCTUnwrap(FolderID(rawValue: "remove-policy-missing")),
            trigger: .user
        )
        try queue.enqueue(missingPolicyCommand)
        try queue.record(.init(commandID: missingPolicyCommand.id, status: .succeeded))
        try queue.acknowledge(missingPolicyCommand)
        let second = await CoreRuntime(clientFactory: { RecordingCoreClient() }).processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )
        guard case .completed(processedCommands: 0, snapshotGeneration: _) = second else {
            return XCTFail("Expected idempotent completed cleanup, got \(second)")
        }
        XCTAssertTrue(try queue.completed().isEmpty)
    }

    func testCompletedOldRemovePreservesNewIncarnationPolicyDuringCleanup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "remove-policy-readded"))
        let command = try runtimeTestCommand(
            kind: .removeFolder,
            paths: paths,
            folderID: folderID,
            trigger: .user
        )
        let oldDigest = try XCTUnwrap(command.folderIncarnationDigest)
        let newDigest = String(repeating: oldDigest == String(repeating: "b", count: 64) ? "c" : "b", count: 64)
        let replacement = FolderSyncPolicyOverride(
            folderID: folderID,
            folderIncarnationDigest: newDigest,
            queuePriority: .high,
            policy: .init(allowBackgroundDownload: false)
        )
        let policyStore = SyncPolicyStore(url: paths.policy)
        try policyStore.saveDocument(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                folderOverrides: [replacement]
            )
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(.init(commandID: command.id, status: .succeeded))
        try queue.acknowledge(command)

        let outcome = await CoreRuntime(clientFactory: { RecordingCoreClient() }).processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        guard case .completed(processedCommands: 0, snapshotGeneration: _) = outcome else {
            return XCTFail("Expected completed cleanup, got \(outcome)")
        }
        XCTAssertEqual(try policyStore.loadDocument().folderOverrides, [replacement])
        XCTAssertTrue(try queue.completed().isEmpty)
    }

    func testCorruptPolicyDefersCompletedRemoveBeforeNativeRetirement() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "remove-policy-corrupt"))
        let command = try runtimeTestCommand(
            kind: .removeFolder,
            paths: paths,
            folderID: folderID,
            trigger: .user
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(.init(commandID: command.id, status: .succeeded))
        try queue.acknowledge(command)
        try SecureLockFile.writeAtomically(Data("{".utf8), to: paths.policy)
        let client = RecordingCoreClient()

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "bridgeLedgerCleanupFailed"))
        XCTAssertEqual(try queue.completed().map(\.id), [command.id])
        let acknowledged = await client.acknowledgedCommandIDs()
        XCTAssertEqual(acknowledged, [])
    }

    func testPolicyWriteFailureDefersCompletedRemoveBeforeNativeRetirement() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "remove-policy-write-failure"))
        let command = try runtimeTestCommand(
            kind: .removeFolder,
            paths: paths,
            folderID: folderID,
            trigger: .user
        )
        let context = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: try XCTUnwrap(command.folderIncarnationDigest)
        )
        let policyStore = SyncPolicyStore(url: paths.policy)
        _ = try policyStore.saveFolderPolicy(
            .init(allowBackgroundUpload: false),
            queuePriority: .normal,
            for: context
        )
        let baselineBytes = try Data(contentsOf: paths.policy)
        try FileManager.default.setAttributes(
            [.immutable: true],
            ofItemAtPath: paths.policy.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: paths.policy.path
            )
        }
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(.init(commandID: command.id, status: .succeeded))
        try queue.acknowledge(command)
        let client = RecordingCoreClient()

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "bridgeLedgerCleanupFailed"))
        XCTAssertEqual(try Data(contentsOf: paths.policy), baselineBytes)
        XCTAssertEqual(try queue.completed().map(\.id), [command.id])
        let acknowledged = await client.acknowledgedCommandIDs()
        XCTAssertEqual(acknowledged, [])
    }

    func testCompletedSucceededMutationReleasesStagingBeforeLedgerRetirement() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let commandID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let command = try stagedMutationCommand(id: commandID, paths: paths)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(.init(commandID: command.id, status: .succeeded))
        try queue.acknowledge(command)
        let client = RecordingCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .completed(processedCommands: 0, snapshotGeneration: 3))
        try assertStagingReleased(for: command.id, paths: paths)
        XCTAssertTrue(try queue.completed().isEmpty)
    }

    func testPendingSucceededMutationReleasesStagingAfterRestart() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let commandID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let command = try stagedMutationCommand(id: commandID, paths: paths)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(.init(commandID: command.id, status: .succeeded))
        let client = RecordingCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .completed(processedCommands: 0, snapshotGeneration: 3))
        try assertStagingReleased(for: command.id, paths: paths)
        XCTAssertTrue(try queue.pending().isEmpty)
        XCTAssertTrue(try queue.completed().isEmpty)
    }

    func testSuccessfulMutationReleasesStagingEvenWhenNativeLedgerCleanupFails() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let commandID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        let command = try stagedMutationCommand(id: commandID, paths: paths)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = StarvationLedgerCleanupCoreClient(rejectedIDs: [command.id])
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .fileProvider,
            paths: paths,
            environment: .permissiveForTesting
        )
        let cleanup = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .completed(processedCommands: 1, snapshotGeneration: 3))
        XCTAssertEqual(cleanup, .failed(code: "bridgeLedgerCleanupFailed"))
        XCTAssertEqual(try queue.result(for: command.id)?.status, .succeeded)
        XCTAssertEqual(try queue.completed().map(\.id), [command.id])
        try assertStagingReleased(for: command.id, paths: paths)
    }

    func testCompletedReconciledResultRetriesProofBoundNativeAcknowledgement() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "proof-retry-folder"))
        let command = try runtimeTestCommand(
            kind: .delete,
            paths: paths,
            folderID: folderID,
            itemID: "stable-id",
            arguments: ["propagatesToPeers": "true", "recursive": "false"],
            trigger: .fileProvider
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(
            .init(
                commandID: command.id,
                status: .succeeded,
                snapshotGeneration: 8,
                ownerEpoch: 7,
                reconciliationProofStateDigest: Data(repeating: 9, count: 32)
            )
        )
        try queue.acknowledge(command)
        let client = MutationReconciliationCoreClient(
            rejectedCommandID: nil,
            rejection: .coreRejected("unused"),
            snapshot: CoreSnapshot(generation: 8)
        )
        let runtime = CoreRuntime(clientFactory: { client })

        _ = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        let reconciled = await client.reconciledCommandIDs()
        XCTAssertEqual(reconciled, [command.id])
        XCTAssertEqual(try queue.completed(), [])
        XCTAssertEqual(try queue.result(for: command.id)?.status, .succeeded)
    }

    func testCompletedConfigurationFailureReconcilesFromLaterOwnerSnapshotWithoutReplay() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let local = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let remote = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let command = try runtimeTestCommand(
            kind: .editDevice,
            paths: paths,
            itemID: remote.rawValue,
            arguments: [
                "name": "Reconciled Peer",
                "addresses": #"["dynamic","tcp://127.0.0.1:22000"]"#,
                "paused": "true",
            ],
            trigger: .user
        )
        let priorLease = CoreOwnerLease(
            epoch: 1,
            instanceID: UUID(),
            role: .mainApp,
            acquiredAt: .now
        )
        try CoreOwnerMetadataStore.write(
            priorLease,
            to: CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(
            CoreCommandResult(
                commandID: command.id,
                status: .failed,
                ownerEpoch: priorLease.epoch,
                instanceID: priorLease.instanceID,
                errorCode: "internal_error"
            )
        )
        try queue.acknowledge(command)
        let client = ConfigurationReconciliationCoreClient(
            localDeviceID: local,
            snapshot: CoreSnapshot(
                generation: 8,
                localDeviceID: local,
                devices: [
                    DeviceRecord(id: local, name: "Local"),
                    DeviceRecord(
                        id: remote,
                        name: "Reconciled Peer",
                        addresses: ["dynamic", "tcp://127.0.0.1:22000"],
                        isPaused: true
                    ),
                ]
            )
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .completed(processedCommands: 1, snapshotGeneration: 8))
        let executed = await client.executedCommandIDs()
        let reconciled = await client.configurationReconciledCommandIDs()
        let ordinarilyAcknowledged = await client.ordinaryAcknowledgedCommandIDs()
        XCTAssertEqual(executed, [])
        XCTAssertEqual(reconciled, [command.id])
        XCTAssertEqual(ordinarilyAcknowledged, [])
        XCTAssertEqual(try queue.completed(), [])
        let result = try XCTUnwrap(queue.result(for: command.id))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.ownerEpoch, 2)
        XCTAssertEqual(result.reconciliationProofKind, CoreConfigurationReconciliationProof.kind)
        XCTAssertEqual(result.reconciliationProofStateDigest?.count, 32)
    }

    func testCompletedConfigurationProofRetriesWithoutReplayingOriginalCommand() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let local = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let remote = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let command = try runtimeTestCommand(
            kind: .pause,
            paths: paths,
            itemID: remote.rawValue,
            trigger: .user
        )
        let priorLease = CoreOwnerLease(
            epoch: 1,
            instanceID: UUID(),
            role: .mainApp,
            acquiredAt: .now
        )
        try CoreOwnerMetadataStore.write(
            priorLease,
            to: CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(
            CoreCommandResult(
                commandID: command.id,
                status: .failed,
                ownerEpoch: priorLease.epoch,
                instanceID: priorLease.instanceID,
                errorCode: "internal_error"
            )
        )
        try queue.acknowledge(command)
        let client = ConfigurationReconciliationCoreClient(
            localDeviceID: local,
            snapshot: CoreSnapshot(
                generation: 6,
                localDeviceID: local,
                devices: [
                    DeviceRecord(id: local, name: "Local"),
                    DeviceRecord(id: remote, name: "Peer", isPaused: true),
                ]
            ),
            reconciliationFailures: 1
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let first = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )
        let persistedProof = try XCTUnwrap(queue.result(for: command.id))
        let second = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(first, .failed(code: "bridgeLedgerCleanupFailed"))
        XCTAssertEqual(second, .completed(processedCommands: 0, snapshotGeneration: 7))
        XCTAssertEqual(persistedProof.status, .succeeded)
        XCTAssertEqual(persistedProof.reconciliationProofKind, CoreConfigurationReconciliationProof.kind)
        XCTAssertEqual(try queue.completed(), [])
        let executed = await client.executedCommandIDs()
        let reconciliationAttempts = await client.configurationReconciledCommandIDs()
        let ordinarilyAcknowledged = await client.ordinaryAcknowledgedCommandIDs()
        XCTAssertEqual(executed, [])
        XCTAssertEqual(reconciliationAttempts, [command.id, command.id])
        XCTAssertEqual(ordinarilyAcknowledged, [])
    }

    func testConflictingConfigurationStateBecomesStableManualResultWithoutReplay() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let local = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let remote = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let command = try runtimeTestCommand(
            kind: .editDevice,
            paths: paths,
            itemID: remote.rawValue,
            arguments: ["name": "Requested Name"],
            trigger: .user
        )
        let priorLease = CoreOwnerLease(
            epoch: 1,
            instanceID: UUID(),
            role: .mainApp,
            acquiredAt: .now
        )
        try CoreOwnerMetadataStore.write(
            priorLease,
            to: CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(
            CoreCommandResult(
                commandID: command.id,
                status: .failed,
                ownerEpoch: priorLease.epoch,
                instanceID: priorLease.instanceID,
                errorCode: "internal_error"
            )
        )
        try queue.acknowledge(command)
        let client = ConfigurationReconciliationCoreClient(
            localDeviceID: local,
            snapshot: CoreSnapshot(
                generation: 5,
                localDeviceID: local,
                devices: [
                    DeviceRecord(id: local, name: "Local"),
                    DeviceRecord(id: remote, name: "Later Conflicting Name"),
                ]
            )
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let first = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )
        let resultAfterFirst = try XCTUnwrap(queue.result(for: command.id))
        let second = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(first, .failed(code: "configuration_reconciliation_conflict"))
        XCTAssertEqual(second, .failed(code: "configuration_reconciliation_conflict"))
        XCTAssertEqual(resultAfterFirst.status, .failed)
        XCTAssertEqual(resultAfterFirst.errorCode, "configuration_reconciliation_conflict")
        XCTAssertEqual(resultAfterFirst.ownerEpoch, 2)
        XCTAssertEqual(try queue.result(for: command.id)?.ownerEpoch, 3)
        XCTAssertEqual(try queue.completed().map(\.id), [command.id])
        let executed = await client.executedCommandIDs()
        let reconciled = await client.configurationReconciledCommandIDs()
        let ordinarilyAcknowledged = await client.ordinaryAcknowledgedCommandIDs()
        XCTAssertEqual(executed, [])
        XCTAssertEqual(reconciled, [])
        XCTAssertEqual(ordinarilyAcknowledged, [])
    }

    func testCompletedLedgerCleanupDeterministicallyProgressesBeyondBatchLimit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let completedDirectory = paths.commandQueue.appendingPathComponent(
            "completed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: completedDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let queue = CoreCommandQueue(root: paths.commandQueue)
        let firstTemplate = try runtimeTestCommand(
            kind: .sync,
            paths: paths,
            folderID: try XCTUnwrap(FolderID(rawValue: "cleanup-first-folder")),
            trigger: .foreground
        )
        let beyondLimitTemplate = try runtimeTestCommand(
            kind: .sync,
            paths: paths,
            folderID: try XCTUnwrap(FolderID(rawValue: "cleanup-beyond-limit-folder")),
            trigger: .foreground
        )
        let middleTemplate = try runtimeTestCommand(
            kind: .sync,
            paths: paths,
            folderID: try XCTUnwrap(FolderID(rawValue: "cleanup-middle-folder")),
            trigger: .foreground
        )
        var commands: [CoreCommand] = []
        for index in 1...4_097 {
            let id = try XCTUnwrap(
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", index))
            )
            let createdAt = Date(timeIntervalSince1970: TimeInterval(index))
            let scopedTemplate =
                index == 1
                ? firstTemplate
                : (index == 2 || index == 4_097 ? beyondLimitTemplate : middleTemplate)
            let command = CoreCommand(
                id: id,
                kind: .sync,
                folderID: scopedTemplate.folderID,
                folderIncarnationDigest: scopedTemplate.folderIncarnationDigest,
                trigger: .foreground,
                createdAt: createdAt
            )
            let filename = String(
                format: "%020lld-%@.json",
                Int64(index) * 1_000_000,
                id.uuidString.lowercased()
            )
            try encoder.encode(command).write(
                to: completedDirectory.appendingPathComponent(filename)
            )
            try queue.record(.init(commandID: command.id, status: .succeeded))
            commands.append(command)
        }
        let eventualSuccess = try XCTUnwrap(commands.last)
        let client = StarvationLedgerCleanupCoreClient(
            rejectedIDs: Set(commands.dropLast().map(\.id))
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let firstOutcome = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(firstOutcome, .failed(code: "bridgeLedgerCleanupFailed"))
        let acknowledgementsAfterFirstRun = await client.successfulAcknowledgementIDs()
        XCTAssertEqual(acknowledgementsAfterFirstRun, [])

        let secondOutcome = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(secondOutcome, .failed(code: "bridgeLedgerCleanupFailed"))
        let acknowledgementsAfterSecondRun = await client.successfulAcknowledgementIDs()
        XCTAssertEqual(acknowledgementsAfterSecondRun, [eventualSuccess.id])
        let remaining = try queue.completed(limit: .max)
        XCTAssertEqual(remaining.count, 4_096)
        XCTAssertFalse(remaining.contains(where: { $0.id == eventualSuccess.id }))
        XCTAssertEqual(remaining.first?.id, commands[2].id)
        let remainingFilenames = try FileManager.default.contentsOfDirectory(
            atPath: completedDirectory.path
        )
        XCTAssertEqual(
            remainingFilenames.filter {
                $0.hasPrefix("~retry-00000000000000000001-")
            }.count,
            2
        )
        XCTAssertEqual(
            remainingFilenames.filter {
                $0.hasPrefix("~retry-00000000000000000002-")
            }.count,
            0
        )
    }

    func testFailedRunDoesNotAcknowledgeCommandOrReportCompletion() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(kind: .sync, paths: paths, trigger: .user)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let runtime = CoreRuntime(clientFactory: { UnavailableCoreClient() })

        let outcome = await runtime.processPending(
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "coreBridgeUnavailable"))
        XCTAssertEqual(try queue.pending().map(\.id), [command.id])
        XCTAssertNil(try queue.result(for: command.id))
    }

    func testPolicyDenialDoesNotStartCoreOrAcknowledgeCommand() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(
            kind: .download,
            paths: paths,
            trigger: .backgroundProcessing
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = RecordingCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })
        let denied = SyncEnvironmentSnapshot(
            network: .init(kind: .cellular, isExpensive: true),
            power: .init(
                batteryLevel: 1,
                isExternalPowerConnected: true,
                isLowPowerModeEnabled: false,
                thermalLevel: .nominal
            )
        )

        let outcome = await runtime.processPending(
            trigger: .backgroundProcessing,
            paths: paths,
            environment: denied
        )

        guard case .policyDenied(let reasons) = outcome else {
            return XCTFail("Expected a policy denial, got \(outcome)")
        }
        XCTAssertTrue(reasons.contains(.networkTypeDenied))
        let wasStarted = await client.wasStarted()
        XCTAssertFalse(wasStarted)
        XCTAssertEqual(try queue.pending().map(\.id), [command.id])
    }

    func testPolicyDenialDoesNotIncrementDurableRetryAttempt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(
            kind: .download,
            paths: paths,
            trigger: .backgroundProcessing
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        let failedAt = Date(timeIntervalSince1970: 100)
        let deniedAt = Date(timeIntervalSince1970: 101)
        try queue.enqueue(command)
        try queue.record(
            .init(
                commandID: command.id,
                status: .retryable,
                completedAt: failedAt,
                errorCode: "device_offline"
            ),
            at: failedAt
        )
        XCTAssertTrue(try queue.retryNow(command.id, at: deniedAt))
        let before = try XCTUnwrap(queue.retryState(for: command.id, at: deniedAt))
        let client = RecordingCoreClient()
        let runtime = CoreRuntime(clientFactory: { client }, wallClock: { deniedAt })
        let denied = SyncEnvironmentSnapshot(
            network: .init(kind: .cellular, isExpensive: true),
            power: .init(
                batteryLevel: 1,
                isExternalPowerConnected: true,
                isLowPowerModeEnabled: false,
                thermalLevel: .nominal
            )
        )

        let outcome = await runtime.processPending(
            trigger: .backgroundProcessing,
            paths: paths,
            environment: denied
        )

        guard case .policyDenied(let reasons) = outcome else {
            return XCTFail("Expected a policy denial, got \(outcome)")
        }
        XCTAssertTrue(reasons.contains(.networkTypeDenied))
        let after = try XCTUnwrap(queue.retryState(for: command.id, at: deniedAt))
        XCTAssertEqual(after.attempt, before.attempt)
        XCTAssertEqual(after.lastError, before.lastError)
        XCTAssertEqual(after.earliestRetryAt, before.earliestRetryAt)
        let wasStarted = await client.wasStarted()
        XCTAssertFalse(wasStarted)
    }

    func testNetworkCoreEnvelopeBlocksRescanWhileConfigurationStaysOffline() async throws {
        for kind in [CoreCommandKind.rescan, .pause] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = SharedContainerPaths(root: root)
            var policy = SyncPolicy()
            policy.cellularAccess = .denied
            try SyncPolicyStore(url: paths.policy).save(policy)
            let folderID = try XCTUnwrap(FolderID(rawValue: "network-envelope-folder"))
            let command = try runtimeTestCommand(
                kind: kind,
                paths: paths,
                folderID: folderID,
                trigger: .user
            )
            let queue = CoreCommandQueue(root: paths.commandQueue)
            try queue.enqueue(command)
            let client = RecordingCoreClient()
            let runtime = CoreRuntime(clientFactory: { client })
            var cellular = SyncEnvironmentSnapshot.permissiveForTesting
            cellular.network = .init(kind: .cellular)

            let outcome = await runtime.processPending(
                trigger: .user,
                paths: paths,
                environment: cellular
            )

            if kind == .rescan {
                guard case .policyDenied(let reasons) = outcome else {
                    XCTFail("Expected rescan to be denied before core start, got \(outcome)")
                    continue
                }
                XCTAssertTrue(reasons.contains(.networkTypeDenied))
                XCTAssertEqual(try queue.pending().map(\.id), [command.id])
            } else {
                guard
                    case .completed(processedCommands: 1, snapshotGeneration: let generation) =
                        outcome
                else {
                    XCTFail("Expected configuration to stay offline, got \(outcome)")
                    continue
                }
                XCTAssertGreaterThan(generation, 0)
                XCTAssertTrue(try queue.pending().isEmpty)
            }
            let wasStarted = await client.wasStarted()
            XCTAssertFalse(wasStarted)
        }
    }

    func testQueuedNetworkCoreEnvelopeDoesNotInheritTemporaryOverride() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(kind: .upload, paths: paths, trigger: .user)
        var policy = SyncPolicy()
        policy.cellularAccess = .downloadOnly
        policy.allowTemporaryUserOverride = true
        try SyncPolicyStore(url: paths.policy).save(policy)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = RecordingCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })
        var cellular = SyncEnvironmentSnapshot.permissiveForTesting
        cellular.network = .init(kind: .cellular)

        let outcome = await runtime.processPending(
            trigger: .user,
            paths: paths,
            environment: cellular,
            requestedTemporaryOverride: true
        )

        guard case .policyDenied(let reasons) = outcome else {
            return XCTFail("Expected queued work to reject ambient override, got \(outcome)")
        }
        XCTAssertTrue(reasons.contains(.cellularDirectionDenied))
        let wasStarted = await client.wasStarted()
        XCTAssertFalse(wasStarted)
        XCTAssertEqual(try queue.pending().map(\.id), [command.id])
    }

    func testSequentialRunsReleaseCoreOwnershipBeforeReturning() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let client = RecordingCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })
        let queue = CoreCommandQueue(root: paths.commandQueue)
        let firstCommand = try runtimeTestCommand(
            kind: .sync,
            paths: paths,
            trigger: .foreground
        )
        try queue.enqueue(firstCommand)

        let first = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )
        let secondCommand = try runtimeTestCommand(
            kind: .sync,
            paths: paths,
            trigger: .foreground
        )
        try queue.enqueue(secondCommand)
        let second = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(first, .completed(processedCommands: 1, snapshotGeneration: 3))
        XCTAssertEqual(second, .completed(processedCommands: 1, snapshotGeneration: 5))
        let snapshot = try XCTUnwrap(SharedSnapshotStore(snapshotURL: paths.snapshot).read())
        XCTAssertEqual(snapshot.ownerEpoch, 2)
        let persistedLease = try XCTUnwrap(
            CoreOwnerMetadataStore.readIfPresent(
                at: CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
            )
        )
        XCTAssertEqual(persistedLease.epoch, 2)
        XCTAssertEqual(snapshot.instanceID, persistedLease.instanceID)
    }

    func testRejectedCommandPersistsBlockedResultAndAcknowledgesTerminalCommand() async throws {
        try await assertRejectedCommand(
            error: .coreRejected("version_conflict"),
            expectedStatus: .blocked,
            expectedCode: "version_conflict"
        )
    }

    func testTransientCommandFailurePersistsRetryableResultAndRemainsPending() async throws {
        try await assertRejectedCommand(
            error: .coreRejected("device_offline"),
            expectedStatus: .retryable,
            expectedCode: "device_offline"
        )
    }

    func testPendingSuppressionFreshnessAndStateConflictsAreBlocked() async throws {
        for code in [
            "offer_version_conflict",
            "suppression_version_conflict",
            "pending_device_not_found",
            "pending_folder_not_found",
            "device_state_conflict",
            "folder_state_conflict",
        ] {
            try await assertRejectedCommand(
                error: .coreRejected(code),
                expectedStatus: .blocked,
                expectedCode: code,
                command: try pendingFolderSuppressionRuntimeTestCommand()
            )
        }
    }

    func testReplaySafePendingSuppressionTransientFailuresRemainRetryable() async throws {
        for code in ["pending_state_unavailable", "configuration_save_failed"] {
            try await assertRejectedCommand(
                error: .coreRejected(code),
                expectedStatus: .retryable,
                expectedCode: code,
                command: try pendingFolderSuppressionRuntimeTestCommand()
            )
        }
    }

    func testBoundedSyncTimeoutRemainsRetryable() async throws {
        try await assertRejectedCommand(
            error: .coreRejected("sync_incomplete"),
            expectedStatus: .retryable,
            expectedCode: "sync_incomplete"
        )
    }

    func testUnprovablePeerIndexCompletionIsBlockedAndDoesNotRemainPending() async throws {
        try await assertRejectedCommand(
            error: .coreRejected("peer_index_proof_unavailable"),
            expectedStatus: .blocked,
            expectedCode: "peer_index_proof_unavailable"
        )
    }

    func testCancelledSyncRemainsPendingAndCanSucceedOnNextRun() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(
            kind: .sync,
            paths: paths,
            trigger: .backgroundProcessing
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = RejectOnceCoreClient(error: .coreRejected("sync_cancelled"))
        let runtime = CoreRuntime(clientFactory: { client })

        let cancelledOutcome = await runtime.processPending(
            trigger: .backgroundProcessing,
            paths: paths,
            environment: .permissiveForTesting
        )
        XCTAssertEqual(cancelledOutcome, .failed(code: "sync_cancelled"))
        XCTAssertEqual(try queue.pending().map(\.id), [command.id])
        XCTAssertEqual(try queue.result(for: command.id)?.status, .retryable)
        XCTAssertTrue(try queue.retryNow(command.id))

        let resumedOutcome = await runtime.processPending(
            trigger: .backgroundProcessing,
            paths: paths,
            environment: .permissiveForTesting
        )
        XCTAssertEqual(resumedOutcome, .completed(processedCommands: 1, snapshotGeneration: 5))
        XCTAssertTrue(try queue.pending().isEmpty)
        XCTAssertEqual(try queue.result(for: command.id)?.status, .succeeded)
        let executed = await client.executedCommandIDs()
        XCTAssertEqual(executed, [command.id, command.id])
    }

    func testNativeCancelledRescanIsClassifiedRetryable() async throws {
        try await assertRejectedCommand(
            error: .coreRejected("cancelled"),
            expectedStatus: .retryable,
            expectedCode: "cancelled",
            kind: .rescan
        )
    }

    func testRealAdapterFailureClassifierPreservesNativeCancellationSemantics() throws {
        let commandFailure = CoreBridgeFailureClassifier.failure(
            code: "cancelled",
            mutationPhase: nil,
            mutationAmbiguous: nil,
            expectsMutationMetadata: false
        )
        XCTAssertEqual(commandFailure as? CoreClientError, .coreRejected("cancelled"))

        let mutationFailure = try XCTUnwrap(
            CoreBridgeFailureClassifier.failure(
                code: "cancelled",
                mutationPhase: CoreMutationFailurePhase.postcommit.rawValue,
                mutationAmbiguous: true,
                expectsMutationMetadata: true
            ) as? CoreMutationFailure
        )
        XCTAssertEqual(mutationFailure.code, "cancelled")
        XCTAssertEqual(mutationFailure.phase, .postcommit)
        XCTAssertTrue(mutationFailure.ambiguous)
    }

    func testLiveNetworkLossCancelsRunningRescanAndLeavesItPending() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(kind: .rescan, paths: paths, trigger: .user)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = PolicyCancellationCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })
        let environments = MutableEnvironment(.permissiveForTesting)
        let run = Task {
            await runtime.processPending(
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                currentEnvironment: { await environments.current() }
            )
        }

        try await client.waitUntilExecuteBegins()
        await environments.update(Self.deniedNetworkEnvironment)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { run.cancel() }
        }
        let outcome = await run.value
        timeout.cancel()

        guard case .policyDenied(let reasons) = outcome else {
            return XCTFail("Expected a live policy denial, got \(outcome)")
        }
        XCTAssertTrue(reasons.contains(.networkUnavailable))
        let cancellationRequests = await client.cancellationRequestCount()
        XCTAssertGreaterThanOrEqual(cancellationRequests, 1)
        let stopCount = await client.stopCount()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(try queue.pending().map(\.id), [command.id])
        XCTAssertNil(try queue.result(for: command.id))
        let history = try SyncRunHistory(url: paths.history).recent(limit: 10)
        XCTAssertTrue(
            history.contains {
                $0.endReason == .policyDenied
                    && $0.failureCode == PolicyBlockReason.networkUnavailable.rawValue
            }
        )
    }

    func testLivePolicyTighteningCancelsRunningUploadAndLeavesItPending() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        var policy = SyncPolicy()
        policy.cellularAccess = .allowed
        try SyncPolicyStore(url: paths.policy).save(policy)
        let command = try runtimeTestCommand(kind: .upload, paths: paths, trigger: .user)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = PolicyCancellationCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })
        var cellular = SyncEnvironmentSnapshot.permissiveForTesting
        cellular.network = .init(kind: .cellular)
        let cellularEnvironment = cellular
        let run = Task {
            await runtime.processPending(
                trigger: .user,
                paths: paths,
                environment: cellularEnvironment,
                currentEnvironment: { cellularEnvironment }
            )
        }

        try await client.waitUntilExecuteBegins()
        policy.cellularAccess = .downloadOnly
        try SyncPolicyStore(url: paths.policy).save(policy)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { run.cancel() }
        }
        let outcome = await run.value
        timeout.cancel()

        guard case .policyDenied(let reasons) = outcome else {
            return XCTFail("Expected a live policy denial, got \(outcome)")
        }
        XCTAssertTrue(reasons.contains(.cellularDirectionDenied))
        let networkOperation = await client.runtimeExplicitSessionState.networkOperation()
        XCTAssertEqual(networkOperation, .upload)
        let cancellationRequests = await client.cancellationRequestCount()
        XCTAssertGreaterThanOrEqual(cancellationRequests, 1)
        XCTAssertEqual(try queue.pending().map(\.id), [command.id])
        XCTAssertNil(try queue.result(for: command.id))
    }

    func testCancellationAfterNativeMutationCompletionPreservesLedgerReconciliation() async throws {
        let fixture = try mutationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let itemID = "policy-interrupted-delete"
        let baselineItem = mutationItem(
            id: itemID,
            folderID: fixture.folder.id,
            relativePath: "policy-interrupted.txt",
            isDirectory: false,
            generation: 1
        )
        try persistMutationBaseline(fixture: fixture, items: [baselineItem])
        let command = try runtimeTestCommand(
            kind: .delete,
            paths: fixture.paths,
            folderID: fixture.folder.id,
            itemID: itemID,
            trigger: .fileProvider
        )
        let queue = CoreCommandQueue(root: fixture.paths.commandQueue)
        try queue.enqueue(command)
        let authoritativeSnapshot = CoreSnapshot(
            generation: 2,
            folders: [fixture.folder],
            tombstones: [IndexTombstone(itemID: itemID, generation: 2)]
        )
        let client = PolicyInterruptedMutationCoreClient(
            originalCommandID: command.id,
            snapshot: authoritativeSnapshot
        )
        let runtime = CoreRuntime(clientFactory: { client })
        let interruptedRun = Task {
            await runtime.processPending(
                trigger: .fileProvider,
                paths: fixture.paths,
                environment: .permissiveForTesting,
                currentEnvironment: { .permissiveForTesting }
            )
        }

        try await client.waitUntilMutationCommitted()
        interruptedRun.cancel()
        let interruptedOutcome = await interruptedRun.value

        XCTAssertEqual(interruptedOutcome, .failed(code: "cancelled"))
        XCTAssertEqual(try queue.pending().map(\.id), [command.id])
        XCTAssertNil(try queue.result(for: command.id))
        let firstNativeMutationCount = await client.nativeMutationExecutionCount()
        XCTAssertEqual(firstNativeMutationCount, 1)

        let replayOutcome = await runtime.processPending(
            trigger: .fileProvider,
            paths: fixture.paths,
            environment: .permissiveForTesting,
            currentEnvironment: { .permissiveForTesting }
        )
        let reconciledOutcome = await runtime.processPending(
            trigger: .foreground,
            paths: fixture.paths,
            environment: .permissiveForTesting,
            currentEnvironment: { .permissiveForTesting }
        )

        XCTAssertEqual(replayOutcome, .failed(code: "propagation_not_indexed"))
        guard
            case .completed(processedCommands: 0, snapshotGeneration: let generation) =
                reconciledOutcome
        else {
            return XCTFail("Expected later-owner mutation reconciliation, got \(reconciledOutcome)")
        }
        XCTAssertGreaterThanOrEqual(generation, 2)
        XCTAssertEqual(try queue.result(for: command.id)?.status, .succeeded)
        XCTAssertTrue(try queue.pending().isEmpty)
        let finalNativeMutationCount = await client.nativeMutationExecutionCount()
        XCTAssertEqual(finalNativeMutationCount, 1)
        let reconciledIDs = await client.reconciledCommandIDs()
        XCTAssertEqual(reconciledIDs, [command.id])
    }

    func testPostCommitMutationFailureIsTerminalAndRetainedForReconciliation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = try runtimeTestCommand(
            kind: .modify,
            paths: paths,
            trigger: .fileProvider
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = AlwaysRejectingRecordingCoreClient(
            error: .coreRejected("propagation_not_indexed")
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let failedOutcome = await runtime.processPending(
            trigger: .fileProvider,
            paths: paths,
            environment: .permissiveForTesting
        )
        XCTAssertEqual(failedOutcome, .failed(code: "propagation_not_indexed"))
        XCTAssertTrue(try queue.pending().isEmpty)
        let result = try XCTUnwrap(queue.result(for: command.id))
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(command.requiresManualReconciliation(for: result))
        XCTAssertEqual(try queue.retainedFileProviderStagingCommandIDs(), [command.id])

        _ = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )
        let executed = await client.executedCommandIDs()
        let acknowledged = await client.acknowledgedCommandIDs()
        XCTAssertEqual(executed.filter { $0 == command.id }.count, 1)
        XCTAssertEqual(executed.count, 2)
        XCTAssertFalse(acknowledged.contains(command.id))
        XCTAssertEqual(acknowledged.count, 1)
    }

    func testDefinitePrecommitMutationFailureAcknowledgesAndReleasesStaging() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let commandID = UUID(uuidString: "20000000-0000-4000-8000-000000000021")!
        let source = root.appendingPathComponent("precommit-source")
        try Data("must be released".utf8).write(to: source)
        let token = try stagingStore(paths: paths).stage(source, id: commandID)
        let folderID = try XCTUnwrap(FolderID(rawValue: "precommit-folder"))
        let command = try runtimeTestCommand(
            id: commandID,
            kind: .modify,
            paths: paths,
            folderID: folderID,
            itemID: "stable-id",
            arguments: ["stagedContentToken": token],
            trigger: .fileProvider
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = PhaseAwareMutationRejectingCoreClient(
            failure: CoreMutationFailure(
                code: "staged_content_invalid",
                phase: .precommit,
                ambiguous: false
            )
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .fileProvider,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "staged_content_invalid"))
        let result = try XCTUnwrap(queue.result(for: command.id))
        XCTAssertEqual(result.status, .blocked)
        XCTAssertEqual(result.mutationFailurePhase, .precommit)
        XCTAssertEqual(result.mutationFailureAmbiguous, false)
        XCTAssertFalse(command.requiresManualReconciliation(for: result))
        XCTAssertTrue(try queue.retainedFileProviderStagingCommandIDs().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.fileProviderStaging.appendingPathComponent(command.id.uuidString).path
            )
        )
        let acknowledged = await client.acknowledgedCommandIDs()
        let executed = await client.executedCommands()
        XCTAssertEqual(acknowledged, [command.id])
        XCTAssertFalse(executed.contains { $0.kind == .rescan })
    }

    func testFailedCreateIsReconciledOnNextOwnerRunFromSnapshotAndStagedBytes() async throws {
        let fixture = try mutationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let commandID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let stagedSource = fixture.paths.root.appendingPathComponent("create-source")
        try Data("created bytes".utf8).write(to: stagedSource)
        let token = try stagingStore(paths: fixture.paths).stage(stagedSource, id: commandID)
        let target = fixture.folderRoot.appendingPathComponent("created.txt")
        let created = mutationItem(
            id: "created-stable-id",
            folderID: fixture.folder.id,
            relativePath: "created.txt",
            isDirectory: false,
            generation: 2
        )
        let command = try runtimeTestCommand(
            id: commandID,
            kind: .create,
            paths: fixture.paths,
            folderID: fixture.folder.id,
            arguments: [
                "parentIdentifier": providerFolderIdentifier(fixture.folder.id),
                "filename": "created.txt",
                "isDirectory": "false",
                "stagedContentToken": token,
            ],
            trigger: .fileProvider
        )
        let queue = CoreCommandQueue(root: fixture.paths.commandQueue)
        try queue.enqueue(command)
        let client = MutationReconciliationCoreClient(
            rejectedCommandID: command.id,
            rejection: .coreRejected("propagation_not_indexed"),
            beforeRejectedCommandFailure: {
                try Data("created bytes".utf8).write(to: target)
            },
            snapshot: CoreSnapshot(generation: 2, folders: [fixture.folder], items: [created])
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let failed = await runtime.processPending(
            trigger: .fileProvider,
            paths: fixture.paths,
            environment: .permissiveForTesting
        )
        let reconciled = await runtime.processPending(
            trigger: .foreground,
            paths: fixture.paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(failed, .failed(code: "propagation_not_indexed"))
        guard case .completed(processedCommands: 0, snapshotGeneration: let generation) = reconciled
        else {
            return XCTFail("Expected later-owner reconciliation, got \(reconciled)")
        }
        XCTAssertGreaterThanOrEqual(generation, 2)
        XCTAssertEqual(try queue.result(for: command.id)?.status, .succeeded)
        let executed = await client.executedCommands()
        XCTAssertEqual(executed.filter { $0.id == command.id }.count, 1)
        let rescan = try XCTUnwrap(executed.only(where: { $0.kind == .rescan }))
        XCTAssertNotEqual(rescan.id, command.id)
        XCTAssertEqual(rescan.folderID, command.folderID)
        XCTAssertTrue(rescan.arguments.isEmpty)
        let acknowledged = await client.acknowledgedCommandIDs()
        XCTAssertEqual(Set(acknowledged), [command.id, rescan.id])
        try assertStagingReleased(for: command.id, paths: fixture.paths)
    }

    func testMutationReconciliationRescanIDIsDeterministicAndEpochFenced() throws {
        let folderID = try XCTUnwrap(FolderID(rawValue: "mutation-folder"))
        let command = CoreCommand(
            id: UUID(uuidString: "20000000-0000-4000-8000-000000000015")!,
            kind: .delete,
            folderID: folderID,
            itemID: "stable-id",
            trigger: .fileProvider
        )
        let paths = SharedContainerPaths(root: temporaryDirectory())
        let reconciler = MutationReconciler(paths: paths)
        let first = try XCTUnwrap(reconciler.rescanCommand(for: command, ownerEpoch: 41))
        let sameEpoch = try XCTUnwrap(reconciler.rescanCommand(for: command, ownerEpoch: 41))
        let nextEpoch = try XCTUnwrap(reconciler.rescanCommand(for: command, ownerEpoch: 42))

        XCTAssertEqual(first.id, sameEpoch.id)
        XCTAssertNotEqual(first.id, nextEpoch.id)
        XCTAssertNotEqual(first.id, command.id)
        XCTAssertEqual(first.kind, .rescan)
        XCTAssertEqual(first.folderID, folderID)
        XCTAssertTrue(first.arguments.isEmpty)
    }

    func testOnlyAmbiguousFailedMutationsRequireReconciliation() {
        for kind in [
            CoreCommandKind.create,
            .modify,
            .move,
            .delete,
        ] {
            let command = CoreCommand(kind: kind, trigger: .fileProvider)
            let ambiguous = CoreCommandResult(
                commandID: command.id,
                status: .failed,
                errorCode: "propagation_not_indexed",
                mutationFailurePhase: .postcommit,
                mutationFailureAmbiguous: true
            )
            let precommit = CoreCommandResult(
                commandID: command.id,
                status: .failed,
                errorCode: "staged_content_invalid",
                mutationFailurePhase: .precommit,
                mutationFailureAmbiguous: false
            )
            let blocked = CoreCommandResult(
                commandID: command.id,
                status: .blocked,
                errorCode: "internal_error"
            )

            XCTAssertTrue(command.requiresManualReconciliation(for: ambiguous))
            XCTAssertFalse(command.requiresManualReconciliation(for: precommit))
            XCTAssertFalse(command.requiresManualReconciliation(for: blocked))
        }
    }

    func testCompletedFailedCreateIsReconciledAfterRestartWithoutMutationReplay() async throws {
        let fixture = try mutationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let commandID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        let stagedSource = fixture.paths.root.appendingPathComponent("restart-source")
        try Data("restart bytes".utf8).write(to: stagedSource)
        let token = try stagingStore(paths: fixture.paths).stage(stagedSource, id: commandID)
        try Data("restart bytes".utf8).write(
            to: fixture.folderRoot.appendingPathComponent("restart.txt")
        )
        let command = try runtimeTestCommand(
            id: commandID,
            kind: .create,
            paths: fixture.paths,
            folderID: fixture.folder.id,
            arguments: [
                "parentIdentifier": providerFolderIdentifier(fixture.folder.id),
                "filename": "restart.txt",
                "isDirectory": "false",
                "stagedContentToken": token,
            ],
            trigger: .fileProvider
        )
        let queue = CoreCommandQueue(root: fixture.paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(
            CoreCommandResult(
                commandID: command.id,
                status: .failed,
                errorCode: "indeterminate_prior_attempt",
                reconciliationExpectedIsDirectory: false,
                reconciliationCreateTargetWasAbsent: true
            )
        )
        try queue.acknowledge(command)
        let restoredResult = try XCTUnwrap(
            CoreCommandQueue(root: fixture.paths.commandQueue).result(for: command.id)
        )
        XCTAssertEqual(restoredResult.reconciliationCreateTargetWasAbsent, true)
        let finalItem = mutationItem(
            id: "restart-stable-id",
            folderID: fixture.folder.id,
            relativePath: "restart.txt",
            isDirectory: false,
            generation: 2
        )
        let client = MutationReconciliationCoreClient(
            rejectedCommandID: nil,
            rejection: .coreRejected("unused"),
            snapshot: CoreSnapshot(generation: 2, folders: [fixture.folder], items: [finalItem])
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .foreground,
            paths: fixture.paths,
            environment: .permissiveForTesting
        )

        guard case .completed(processedCommands: 0, snapshotGeneration: let generation) = outcome
        else {
            return XCTFail("Expected completed replay reconciliation, got \(outcome)")
        }
        XCTAssertGreaterThanOrEqual(generation, 2)
        XCTAssertEqual(try queue.result(for: command.id)?.status, .succeeded)
        let executed = await client.executedCommands()
        XCTAssertFalse(executed.contains { $0.id == command.id })
        XCTAssertEqual(executed.filter { $0.kind == .rescan }.count, 1)
        try assertStagingReleased(for: command.id, paths: fixture.paths)
    }

    func testFailedReconciliationRescanIsAcknowledgedWithoutOriginalSuccess() async throws {
        let fixture = try mutationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let command = try runtimeTestCommand(
            id: UUID(uuidString: "20000000-0000-4000-8000-000000000016")!,
            kind: .create,
            paths: fixture.paths,
            folderID: fixture.folder.id,
            arguments: [
                "parentIdentifier": providerFolderIdentifier(fixture.folder.id),
                "filename": "uncertain-directory",
                "isDirectory": "true",
            ],
            trigger: .fileProvider
        )
        let queue = CoreCommandQueue(root: fixture.paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(
            CoreCommandResult(
                commandID: command.id,
                status: .failed,
                errorCode: "indeterminate_prior_attempt",
                reconciliationExpectedIsDirectory: true,
                reconciliationCreateTargetWasAbsent: true
            )
        )
        try queue.acknowledge(command)
        let client = MutationReconciliationCoreClient(
            rejectedCommandID: nil,
            rejection: .coreRejected("unused"),
            rescanRejection: .coreRejected("rescan_failed"),
            snapshot: CoreSnapshot(generation: 2, folders: [fixture.folder])
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .foreground,
            paths: fixture.paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "mutation_reconciliation_conflict"))
        XCTAssertEqual(try queue.result(for: command.id)?.status, .failed)
        let executed = await client.executedCommands()
        let rescan = try XCTUnwrap(executed.only(where: { $0.kind == .rescan }))
        XCTAssertEqual(try queue.result(for: rescan.id)?.status, .failed)
        XCTAssertTrue(try queue.pending().isEmpty)
        let acknowledged = await client.acknowledgedCommandIDs()
        XCTAssertEqual(acknowledged, [rescan.id])
    }

    func testCreateDirectoryDoesNotReconcileWhenTargetPredatedMutation() async throws {
        let fixture = try mutationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let preexisting = mutationItem(
            id: "preexisting-directory-id",
            folderID: fixture.folder.id,
            relativePath: "Already Here",
            isDirectory: true,
            generation: 1
        )
        try persistMutationBaseline(fixture: fixture, items: [preexisting])
        try FileManager.default.createDirectory(
            at: fixture.folderRoot.appendingPathComponent("Already Here"),
            withIntermediateDirectories: false
        )
        let command = try runtimeTestCommand(
            id: UUID(uuidString: "20000000-0000-4000-8000-000000000012")!,
            kind: .create,
            paths: fixture.paths,
            folderID: fixture.folder.id,
            arguments: [
                "parentIdentifier": providerFolderIdentifier(fixture.folder.id),
                "filename": "Already Here",
                "isDirectory": "true",
            ],
            trigger: .fileProvider
        )
        let queue = CoreCommandQueue(root: fixture.paths.commandQueue)
        try queue.enqueue(command)
        var finalItem = preexisting
        finalItem.generation = 2
        let client = MutationReconciliationCoreClient(
            rejectedCommandID: command.id,
            rejection: .coreRejected("internal_error"),
            snapshot: CoreSnapshot(generation: 2, folders: [fixture.folder], items: [finalItem])
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .fileProvider,
            paths: fixture.paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "internal_error"))
        let result = try XCTUnwrap(queue.result(for: command.id))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.reconciliationExpectedIsDirectory, true)
        XCTAssertEqual(result.reconciliationCreateTargetWasAbsent, false)
        let acknowledged = await client.acknowledgedCommandIDs()
        XCTAssertFalse(acknowledged.contains(command.id))
    }

    func testFailedDirectoryCreateReconcilesWhenPreExecutionTargetWasAbsent() async throws {
        let fixture = try mutationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let target = fixture.folderRoot.appendingPathComponent("New Directory")
        let command = try runtimeTestCommand(
            id: UUID(uuidString: "20000000-0000-4000-8000-000000000018")!,
            kind: .create,
            paths: fixture.paths,
            folderID: fixture.folder.id,
            arguments: [
                "parentIdentifier": providerFolderIdentifier(fixture.folder.id),
                "filename": "New Directory",
                "isDirectory": "true",
            ],
            trigger: .fileProvider
        )
        let created = mutationItem(
            id: "new-directory-id",
            folderID: fixture.folder.id,
            relativePath: "New Directory",
            isDirectory: true,
            generation: 2
        )
        let queue = CoreCommandQueue(root: fixture.paths.commandQueue)
        try queue.enqueue(command)
        let client = MutationReconciliationCoreClient(
            rejectedCommandID: command.id,
            rejection: .coreRejected("internal_error"),
            beforeRejectedCommandFailure: {
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: false
                )
            },
            snapshot: CoreSnapshot(generation: 2, folders: [fixture.folder], items: [created])
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let failed = await runtime.processPending(
            trigger: .fileProvider,
            paths: fixture.paths,
            environment: .permissiveForTesting
        )
        let outcome = await runtime.processPending(
            trigger: .foreground,
            paths: fixture.paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(failed, .failed(code: "internal_error"))
        guard case .completed(processedCommands: 0, snapshotGeneration: let generation) = outcome
        else {
            return XCTFail("Expected later-owner directory reconciliation, got \(outcome)")
        }
        XCTAssertGreaterThanOrEqual(generation, 2)
        XCTAssertEqual(try queue.result(for: command.id)?.status, .succeeded)
        let acknowledged = await client.acknowledgedCommandIDs()
        XCTAssertTrue(acknowledged.contains(command.id))
    }

    func testCreateReconciliationRejectsSymlinkedIntermediateDirectory() async throws {
        let fixture = try mutationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let parent = mutationItem(
            id: "symlinked-parent-id",
            folderID: fixture.folder.id,
            relativePath: "linked",
            isDirectory: true,
            generation: 1
        )
        try persistMutationBaseline(fixture: fixture, items: [parent])
        let outside = fixture.paths.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("created"),
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.folderRoot.appendingPathComponent("linked"),
            withDestinationURL: outside
        )
        let command = try runtimeTestCommand(
            id: UUID(uuidString: "20000000-0000-4000-8000-000000000017")!,
            kind: .create,
            paths: fixture.paths,
            folderID: fixture.folder.id,
            arguments: [
                "parentIdentifier": "item-" + parent.id,
                "filename": "created",
                "isDirectory": "true",
            ],
            trigger: .fileProvider
        )
        let created = mutationItem(
            id: "created-through-symlink-id",
            folderID: fixture.folder.id,
            parentID: parent.id,
            relativePath: "linked/created",
            isDirectory: true,
            generation: 2
        )
        let finalParent = mutationItem(
            id: parent.id,
            folderID: fixture.folder.id,
            relativePath: parent.relativePath,
            isDirectory: true,
            generation: 2
        )
        let queue = CoreCommandQueue(root: fixture.paths.commandQueue)
        try queue.enqueue(command)
        let client = MutationReconciliationCoreClient(
            rejectedCommandID: command.id,
            rejection: .coreRejected("internal_error"),
            snapshot: CoreSnapshot(
                generation: 2,
                folders: [fixture.folder],
                items: [finalParent, created]
            )
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .fileProvider,
            paths: fixture.paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "internal_error"))
        XCTAssertEqual(try queue.result(for: command.id)?.status, .failed)
        let acknowledged = await client.acknowledgedCommandIDs()
        XCTAssertFalse(acknowledged.contains(command.id))
    }

    func testModifyReconciliationRejectsWrongInstalledBytesAndRetainsLedger() async throws {
        let fixture = try mutationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let itemID = "modified-stable-id"
        let baselineItem = mutationItem(
            id: itemID,
            folderID: fixture.folder.id,
            relativePath: "modified.txt",
            isDirectory: false,
            generation: 1
        )
        try persistMutationBaseline(fixture: fixture, items: [baselineItem])
        let commandID = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
        let stagedSource = fixture.paths.root.appendingPathComponent("modify-source")
        try Data("expected bytes".utf8).write(to: stagedSource)
        let token = try stagingStore(paths: fixture.paths).stage(stagedSource, id: commandID)
        try Data("wrong bytes".utf8).write(
            to: fixture.folderRoot.appendingPathComponent("modified.txt")
        )
        let command = try runtimeTestCommand(
            id: commandID,
            kind: .modify,
            paths: fixture.paths,
            folderID: fixture.folder.id,
            itemID: itemID,
            arguments: [
                "parentIdentifier": providerFolderIdentifier(fixture.folder.id),
                "filename": "modified.txt",
                "stagedContentToken": token,
            ],
            trigger: .fileProvider
        )
        let queue = CoreCommandQueue(root: fixture.paths.commandQueue)
        try queue.enqueue(command)
        let finalItem = mutationItem(
            id: itemID,
            folderID: fixture.folder.id,
            relativePath: "modified.txt",
            isDirectory: false,
            generation: 2
        )
        let client = MutationReconciliationCoreClient(
            rejectedCommandID: command.id,
            rejection: .invalidResponse("lost response"),
            snapshot: CoreSnapshot(generation: 2, folders: [fixture.folder], items: [finalItem])
        )
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .fileProvider,
            paths: fixture.paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "coreInvalidResponse"))
        let result = try XCTUnwrap(queue.result(for: command.id))
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(command.requiresManualReconciliation(for: result))
        XCTAssertEqual(try queue.retainedFileProviderStagingCommandIDs(), [command.id])
        let acknowledged = await client.acknowledgedCommandIDs()
        let executed = await client.executedCommands()
        XCTAssertFalse(acknowledged.contains(command.id))
        XCTAssertEqual(executed.filter { $0.id == command.id }.count, 1)
    }

    func testDeleteReconciliationRequiresMatchingStableIDTombstone() async throws {
        for (suffix, tombstoneID, expectedStatus) in [
            (4, "deleted-stable-id", CoreCommandResultStatus.succeeded),
            (5, "different-stable-id", CoreCommandResultStatus.failed),
        ] {
            let fixture = try mutationFixture()
            defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
            let itemID = "deleted-stable-id"
            let baselineItem = mutationItem(
                id: itemID,
                folderID: fixture.folder.id,
                relativePath: "deleted.txt",
                isDirectory: false,
                generation: 1
            )
            try persistMutationBaseline(fixture: fixture, items: [baselineItem])
            let commandID = UUID(uuidString: String(format: "20000000-0000-4000-8000-%012d", suffix))!
            let command = try runtimeTestCommand(
                id: commandID,
                kind: .delete,
                paths: fixture.paths,
                folderID: fixture.folder.id,
                itemID: itemID,
                trigger: .fileProvider
            )
            let queue = CoreCommandQueue(root: fixture.paths.commandQueue)
            try queue.enqueue(command)
            let client = MutationReconciliationCoreClient(
                rejectedCommandID: command.id,
                rejection: .coreRejected("internal_error"),
                snapshot: CoreSnapshot(
                    generation: 2,
                    folders: [fixture.folder],
                    tombstones: [IndexTombstone(itemID: tombstoneID, generation: 2)]
                )
            )
            let runtime = CoreRuntime(clientFactory: { client })

            _ = await runtime.processPending(
                trigger: .fileProvider,
                paths: fixture.paths,
                environment: .permissiveForTesting
            )
            _ = await runtime.processPending(
                trigger: .foreground,
                paths: fixture.paths,
                environment: .permissiveForTesting
            )

            XCTAssertEqual(try queue.result(for: command.id)?.status, expectedStatus)
            let acknowledged = await client.acknowledgedCommandIDs()
            XCTAssertEqual(
                acknowledged.contains(command.id),
                expectedStatus == .succeeded
            )
        }
    }

    func testMoveReconciliationRequiresSameStableItemIDAtDerivedTarget() async throws {
        for (suffix, finalItemID, oldPathReplacementID, expectedStatus) in [
            (6, "moving-stable-id", nil, CoreCommandResultStatus.succeeded),
            (7, "replacement-id", nil, CoreCommandResultStatus.failed),
            (8, "moving-stable-id", "reappeared-at-old-path", CoreCommandResultStatus.failed),
        ] {
            let fixture = try mutationFixture()
            defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
            let oldParent = mutationItem(
                id: "old-parent",
                folderID: fixture.folder.id,
                relativePath: "old",
                isDirectory: true,
                generation: 1
            )
            let newParent = mutationItem(
                id: "new-parent",
                folderID: fixture.folder.id,
                relativePath: "new",
                isDirectory: true,
                generation: 1
            )
            let moving = mutationItem(
                id: "moving-stable-id",
                folderID: fixture.folder.id,
                parentID: oldParent.id,
                relativePath: "old/original.txt",
                isDirectory: false,
                generation: 1
            )
            try persistMutationBaseline(fixture: fixture, items: [oldParent, newParent, moving])
            try FileManager.default.createDirectory(
                at: fixture.folderRoot.appendingPathComponent("new"),
                withIntermediateDirectories: false
            )
            try Data("moved".utf8).write(
                to: fixture.folderRoot.appendingPathComponent("new/renamed.txt")
            )
            let commandID = UUID(uuidString: String(format: "20000000-0000-4000-8000-%012d", suffix))!
            let command = try runtimeTestCommand(
                id: commandID,
                kind: .move,
                paths: fixture.paths,
                folderID: fixture.folder.id,
                itemID: moving.id,
                arguments: [
                    "parentIdentifier": "item-" + newParent.id,
                    "filename": "renamed.txt",
                ],
                trigger: .fileProvider
            )
            let queue = CoreCommandQueue(root: fixture.paths.commandQueue)
            try queue.enqueue(command)
            let finalParent = mutationItem(
                id: newParent.id,
                folderID: fixture.folder.id,
                relativePath: "new",
                isDirectory: true,
                generation: 2
            )
            let finalItem = mutationItem(
                id: finalItemID,
                folderID: fixture.folder.id,
                parentID: finalParent.id,
                relativePath: "new/renamed.txt",
                isDirectory: false,
                generation: 2
            )
            let oldPathReplacement = oldPathReplacementID.map {
                mutationItem(
                    id: $0,
                    folderID: fixture.folder.id,
                    parentID: oldParent.id,
                    relativePath: moving.relativePath,
                    isDirectory: false,
                    generation: 2
                )
            }
            let client = MutationReconciliationCoreClient(
                rejectedCommandID: command.id,
                rejection: .coreRejected("rescan_failed"),
                snapshot: CoreSnapshot(
                    generation: 2,
                    folders: [fixture.folder],
                    items: [finalParent, finalItem] + [oldPathReplacement].compactMap { $0 }
                )
            )
            let runtime = CoreRuntime(clientFactory: { client })

            _ = await runtime.processPending(
                trigger: .fileProvider,
                paths: fixture.paths,
                environment: .permissiveForTesting
            )
            _ = await runtime.processPending(
                trigger: .foreground,
                paths: fixture.paths,
                environment: .permissiveForTesting
            )

            XCTAssertEqual(try queue.result(for: command.id)?.status, expectedStatus)
            XCTAssertEqual(
                try queue.result(for: command.id)?.reconciliationSourceRelativePath,
                moving.relativePath
            )
            let acknowledged = await client.acknowledgedCommandIDs()
            let executed = await client.executedCommands()
            XCTAssertEqual(
                acknowledged.contains(command.id),
                expectedStatus == .succeeded
            )
            XCTAssertEqual(executed.filter { $0.id == command.id }.count, 1)
            let reconciled = await client.reconciledCommandIDs()
            XCTAssertEqual(
                reconciled.contains(command.id),
                expectedStatus == .succeeded
            )
        }
    }

    func testPausedFolderMutationIsAcknowledgedForUserResolution() async throws {
        try await assertRejectedCommand(
            error: .coreRejected("folder_paused"),
            expectedStatus: .blocked,
            expectedCode: "folder_paused"
        )
    }

    func testSafeUnsupportedCommandCodeRemainsMachineReadable() async throws {
        try await assertRejectedCommand(
            error: .coreRejected("unsupported_command"),
            expectedStatus: .failed,
            expectedCode: "unsupported_command"
        )
    }

    func testUnsafeBridgeCodeFallsBackWithoutPersistingRawText() async throws {
        try await assertRejectedCommand(
            error: .coreRejected("/private/var/mobile/secret.txt"),
            expectedStatus: .failed,
            expectedCode: "coreRejected"
        )
    }

    func testInvalidBridgeResponsePersistsFailedResultAndAcknowledgesTerminalCommand() async throws {
        try await assertRejectedCommand(
            error: .invalidResponse("malformed envelope"),
            expectedStatus: .failed,
            expectedCode: "coreInvalidResponse"
        )
    }

    func testTerminalFailureDoesNotStarveFollowingValidCommand() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "terminal-failure-folder"))
        let rejected = try runtimeTestCommand(
            kind: .materialize,
            paths: paths,
            folderID: folderID,
            trigger: .user,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let valid = try runtimeTestCommand(
            kind: .rescan,
            paths: paths,
            folderID: folderID,
            trigger: .user,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(rejected)
        try queue.enqueue(valid)
        let client = SelectiveRejectingCoreClient(rejectedID: rejected.id)
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting
        )
        let followingOutcome = await runtime.processPending(
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "unsupported_command"))
        guard
            case .completed(processedCommands: 1, snapshotGeneration: let generation) =
                followingOutcome
        else {
            return XCTFail("Expected the following command to run next, got \(followingOutcome)")
        }
        XCTAssertGreaterThan(generation, 0)
        XCTAssertEqual(try queue.pending(), [])
        XCTAssertEqual(try queue.result(for: rejected.id)?.status, .failed)
        XCTAssertEqual(try queue.result(for: rejected.id)?.errorCode, "unsupported_command")
        XCTAssertEqual(try queue.result(for: valid.id)?.status, .succeeded)
        let executed = await client.executedCommandIDs()
        XCTAssertEqual(executed, [rejected.id, valid.id])
        let history = try SyncRunHistory(url: paths.history).recent(limit: 10)
        XCTAssertTrue(
            history.contains {
                $0.endReason == .failed && $0.failureCode == "unsupported_command"
            }
        )
    }

    func testCorruptOwnerMetadataFailsBeforeStartingCore() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.coreLock.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let metadataURL = CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        let corruptData = Data("not owner metadata".utf8)
        try corruptData.write(to: metadataURL, options: .atomic)
        let client = RecordingCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })

        let outcome = await runtime.processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "ownerMetadataCorrupt"))
        let wasStarted = await client.wasStarted()
        XCTAssertFalse(wasStarted)
        XCTAssertEqual(try Data(contentsOf: metadataURL), corruptData)
        XCTAssertNil(try SharedSnapshotStore(snapshotURL: paths.snapshot).read())
    }

    func testRuntimeDrainsCoreBeforeReleasingOwnerLease() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let client = BlockingStopCoreClient()
        let runtime = CoreRuntime(clientFactory: { client })
        let command = try runtimeTestCommand(
            kind: .sync,
            paths: paths,
            trigger: .foreground
        )
        try CoreCommandQueue(root: paths.commandQueue).enqueue(command)
        let run = Task {
            await runtime.processPending(
                trigger: .foreground,
                paths: paths,
                environment: .permissiveForTesting
            )
        }

        try await client.waitUntilStopBegins()
        let contender = CoreProcessCoordinator(lockURL: paths.coreLock)
        do {
            try await contender.acquire(as: .fileProvider)
            XCTFail("A contender acquired flock while the current core was still draining")
            await contender.release()
        } catch let error as CoreOwnershipError {
            XCTAssertEqual(error, .ownedByAnotherProcess)
        }

        await client.finishStop()
        let outcome = await run.value
        XCTAssertEqual(outcome, .completed(processedCommands: 1, snapshotGeneration: 3))
        let nextLease = try await contender.acquire(as: .fileProvider)
        XCTAssertEqual(nextLease.epoch, 2)
        await contender.release()
    }

    func testMaterializationStreamsBoundedRangesAndCommitsOnlyAfterCoreDrain() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let content = Data((0..<((1 << 20) + 37)).map { UInt8($0 % 251) })
        let item = IndexedItem(
            id: "item-1",
            folderID: folderID,
            relativePath: "Reports/result.bin",
            isDirectory: false,
            size: Int64(content.count),
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 7, count: 32),
            metadataVersion: Data(repeating: 8, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 1
        )
        let client = BlockingMaterializationStopCoreClient(item: item, content: content)
        let runtime = CoreRuntime(clientFactory: { client })
        let destination = root.appendingPathComponent("provider-result.bin")
        let run = Task {
            await runtime.materialize(
                item,
                to: destination,
                trigger: .fileProvider,
                paths: paths,
                environment: .permissiveForTesting,
                destinationAvailableCapacity: { _ in .max }
            )
        }

        try await client.waitUntilStopBegins()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "The atomic destination must not appear until core stop has drained"
        )
        let contender = CoreProcessCoordinator(lockURL: paths.coreLock)
        do {
            try await contender.acquire(as: .mainApp)
            XCTFail("A contender acquired the owner lease while materialization was draining")
            await contender.release()
        } catch let error as CoreOwnershipError {
            XCTAssertEqual(error, .ownedByAnotherProcess)
        }
        await client.finishStop()
        let outcome = await run.value

        XCTAssertEqual(
            outcome,
            .completed(transferredBytes: Int64(content.count), snapshotGeneration: 1)
        )
        XCTAssertEqual(try Data(contentsOf: destination), content)
        let ranges = await client.requestedRanges()
        XCTAssertEqual(ranges.map(\.length), [1 << 20, 37])
        let stopped = await client.didStop()
        XCTAssertTrue(stopped)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.hasPrefix(".psy-materialize-") })
        )
        let history = try XCTUnwrap(try SyncRunHistory(url: paths.history).recent(limit: 1).first)
        XCTAssertEqual(history.endReason, .completed)
        XCTAssertEqual(history.transferredBytes, Int64(content.count))

        let nextLease = try await contender.acquire(as: .mainApp)
        XCTAssertEqual(nextLease.epoch, 2)
        await contender.release()
    }

    func testMaterializationShortReadLeavesNoDestinationOrTemporaryFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let item = IndexedItem(
            id: "item-1",
            folderID: folderID,
            relativePath: "result.bin",
            isDirectory: false,
            size: 128,
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 7, count: 32),
            metadataVersion: Data(repeating: 8, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 1
        )
        let client = RangeCoreClient(item: item, content: Data(repeating: 1, count: 128), shortRead: true)
        let runtime = CoreRuntime(clientFactory: { client })
        let destination = root.appendingPathComponent("provider-result.bin")

        let outcome = await runtime.materialize(
            item,
            to: destination,
            trigger: .fileProvider,
            paths: paths,
            environment: .permissiveForTesting,
            destinationAvailableCapacity: { _ in .max }
        )

        XCTAssertEqual(outcome, .failed(code: "coreInvalidResponse"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.hasPrefix(".psy-materialize-") })
        )
        let stopped = await client.didStop()
        XCTAssertTrue(stopped)
    }

    func testMaterializationNeverOverwritesAnExistingDestination() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let item = IndexedItem(
            id: "item-1",
            folderID: folderID,
            relativePath: "result.bin",
            isDirectory: false,
            size: 3,
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 7, count: 32),
            metadataVersion: Data(repeating: 8, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 1
        )
        let client = RangeCoreClient(item: item, content: Data("new".utf8))
        let runtime = CoreRuntime(clientFactory: { client })
        let destination = root.appendingPathComponent("provider-result.bin")
        try Data("keep".utf8).write(to: destination)

        let outcome = await runtime.materialize(
            item,
            to: destination,
            trigger: .fileProvider,
            paths: paths,
            environment: .permissiveForTesting,
            destinationAvailableCapacity: { _ in .max }
        )

        XCTAssertEqual(outcome, .failed(code: "materialization_destination_exists"))
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
        let ranges = await client.requestedRanges()
        XCTAssertTrue(ranges.isEmpty)
    }

    func testMaterializationUsesTargetOnlySessionWhenAmbientUploadIsDenied() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        var policy = SyncPolicy()
        policy.cellularAccess = .downloadOnly
        try SyncPolicyStore(url: paths.policy).save(policy)
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let content = Data("remote bytes".utf8)
        let item = IndexedItem(
            id: "item-direction-policy",
            folderID: folderID,
            relativePath: "remote.bin",
            isDirectory: false,
            size: Int64(content.count),
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 7, count: 32),
            metadataVersion: Data(repeating: 8, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 3
        )
        let client = RangeCoreClient(item: item, content: content)
        let runtime = CoreRuntime(clientFactory: { client })
        let destination = root.appendingPathComponent("provider-result.bin")
        var cellular = SyncEnvironmentSnapshot.permissiveForTesting
        cellular.network = .init(kind: .cellular)
        let currentCellular = cellular

        let outcome = await runtime.materialize(
            item,
            to: destination,
            trigger: .fileProvider,
            paths: paths,
            environment: cellular,
            currentEnvironment: { currentCellular },
            destinationAvailableCapacity: { _ in .max }
        )

        guard case .completed(let transferredBytes, _) = outcome else {
            return XCTFail("Expected target-only materialization, got \(outcome)")
        }
        XCTAssertEqual(transferredBytes, Int64(content.count))
        let networkOperation = await client.runtimeExplicitSessionState.networkOperation()
        XCTAssertEqual(networkOperation, .materialize)
        let commands = await client.executedCommands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.kind, .materialize)
        XCTAssertEqual(commands.first?.folderID, item.folderID)
        XCTAssertEqual(commands.first?.itemID, item.id)
        XCTAssertEqual(
            commands.first?.arguments,
            ["contentVersion": item.contentVersion.base64EncodedString()]
        )
        let ranges = await client.requestedRanges()
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), content)
    }

    func testMaterializationRevalidatesLivePolicyBeforeEveryBoundedRead() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let content = Data(repeating: 4, count: (1 << 20) + 1)
        let item = IndexedItem(
            id: "item-policy-read",
            folderID: folderID,
            relativePath: "large.bin",
            isDirectory: false,
            size: Int64(content.count),
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 7, count: 32),
            metadataVersion: Data(repeating: 8, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 4
        )
        let client = RangeCoreClient(item: item, content: content)
        let runtime = CoreRuntime(clientFactory: { client })
        let environments = EnvironmentSequence([
            .permissiveForTesting,
            .permissiveForTesting,
            Self.deniedNetworkEnvironment,
        ])
        let destination = root.appendingPathComponent("provider-result.bin")

        let outcome = await runtime.materialize(
            item,
            to: destination,
            trigger: .fileProvider,
            paths: paths,
            environment: .permissiveForTesting,
            currentEnvironment: { await environments.next() },
            destinationAvailableCapacity: { _ in .max }
        )

        guard case .policyDenied(let reasons) = outcome else {
            return XCTFail("Expected a live policy denial, got \(outcome)")
        }
        XCTAssertTrue(reasons.contains(.networkUnavailable))
        let requestedRangeCount = await client.requestedRanges().count
        let didStop = await client.didStop()
        XCTAssertLessThanOrEqual(requestedRangeCount, 1)
        XCTAssertTrue(didStop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try containsMaterializationTemporaryFile(in: root))
        let history = try SyncRunHistory(url: paths.history).recent(limit: 10)
        XCTAssertTrue(
            history.contains {
                $0.endReason == .policyDenied
                    && $0.failureCode == PolicyBlockReason.networkUnavailable.rawValue
            }
        )
    }

    func testMaterializationRevalidatesLivePolicyAfterDrainBeforeCommit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let content = Data(repeating: 5, count: 32)
        let item = IndexedItem(
            id: "item-policy-commit",
            folderID: folderID,
            relativePath: "small.bin",
            isDirectory: false,
            size: Int64(content.count),
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 7, count: 32),
            metadataVersion: Data(repeating: 8, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 5
        )
        let client = RangeCoreClient(item: item, content: content)
        let runtime = CoreRuntime(clientFactory: { client })
        let environments = EnvironmentSequence([
            .permissiveForTesting,
            .permissiveForTesting,
        ])
        let capacities = CapacitySequence([.max, .max, .max, 0])
        let destination = root.appendingPathComponent("provider-result.bin")

        let outcome = await runtime.materialize(
            item,
            to: destination,
            trigger: .fileProvider,
            paths: paths,
            environment: .permissiveForTesting,
            currentEnvironment: { await environments.next() },
            destinationAvailableCapacity: { _ in capacities.next() }
        )

        guard case .policyDenied(let reasons) = outcome else {
            return XCTFail("Expected a final policy denial, got \(outcome)")
        }
        XCTAssertTrue(reasons.contains(.insufficientDisk))
        let requestedRangeCount = await client.requestedRanges().count
        let didStop = await client.didStop()
        XCTAssertEqual(requestedRangeCount, 1)
        XCTAssertTrue(didStop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try containsMaterializationTemporaryFile(in: root))
    }

    func testMaterializationRequiresDestinationCapacityForReserveAndFileBytes() async throws {
        let minimumFreeDiskBytes: Int64 = 512 * 1_024 * 1_024
        let content = Data(repeating: 4, count: 64)
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let item = IndexedItem(
            id: "item-capacity-boundary",
            folderID: folderID,
            relativePath: "capacity.bin",
            isDirectory: false,
            size: Int64(content.count),
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 7, count: 32),
            metadataVersion: Data(repeating: 8, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 6
        )

        let deniedRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: deniedRoot) }
        try FileManager.default.createDirectory(at: deniedRoot, withIntermediateDirectories: true)
        let deniedClient = RangeCoreClient(item: item, content: content)
        let deniedDestination = deniedRoot.appendingPathComponent("denied.bin")
        let denied = await CoreRuntime(clientFactory: { deniedClient }).materialize(
            item,
            to: deniedDestination,
            trigger: .fileProvider,
            paths: SharedContainerPaths(root: deniedRoot),
            environment: .permissiveForTesting,
            destinationAvailableCapacity: { _ in minimumFreeDiskBytes + Int64(content.count) - 1 }
        )

        guard case .policyDenied(let reasons) = denied else {
            return XCTFail("Expected insufficient destination capacity, got \(denied)")
        }
        XCTAssertEqual(reasons, [.insufficientDisk])
        let deniedRanges = await deniedClient.requestedRanges()
        XCTAssertTrue(deniedRanges.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deniedDestination.path))

        let exactRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: exactRoot) }
        try FileManager.default.createDirectory(at: exactRoot, withIntermediateDirectories: true)
        let exactClient = RangeCoreClient(item: item, content: content)
        let exactDestination = exactRoot.appendingPathComponent("exact.bin")
        let capacities = CapacitySequence([
            minimumFreeDiskBytes + Int64(content.count) * 2,
            minimumFreeDiskBytes + Int64(content.count) * 2,
            minimumFreeDiskBytes,
            minimumFreeDiskBytes,
        ])
        let exact = await CoreRuntime(clientFactory: { exactClient }).materialize(
            item,
            to: exactDestination,
            trigger: .fileProvider,
            paths: SharedContainerPaths(root: exactRoot),
            environment: .permissiveForTesting,
            destinationAvailableCapacity: { _ in capacities.next() }
        )

        XCTAssertEqual(
            exact,
            .completed(transferredBytes: Int64(content.count), snapshotGeneration: item.generation)
        )
        XCTAssertEqual(try Data(contentsOf: exactDestination), content)
    }

    func testCancellationDuringNativeMaterializeRequestsBridgeCancellation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let content = Data(repeating: 6, count: 64)
        let item = IndexedItem(
            id: "item-cancel-native-materialize",
            folderID: folderID,
            relativePath: "cancel-native.bin",
            isDirectory: false,
            size: Int64(content.count),
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 7, count: 32),
            metadataVersion: Data(repeating: 8, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 6
        )
        let client = CancellationAwareMaterializationExecuteCoreClient(item: item)
        let runtime = CoreRuntime(clientFactory: { client })
        let destination = root.appendingPathComponent("provider-result.bin")
        let run = Task {
            await runtime.materialize(
                item,
                to: destination,
                trigger: .fileProvider,
                paths: paths,
                environment: .permissiveForTesting,
                destinationAvailableCapacity: { _ in .max }
            )
        }

        try await client.waitUntilExecuteBegins()
        run.cancel()
        let outcome = await run.value

        XCTAssertEqual(outcome, .failed(code: "cancelled"))
        let cancellationRequests = await client.cancellationRequestCount()
        let stopCount = await client.stopCount()
        XCTAssertGreaterThanOrEqual(cancellationRequests, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try containsMaterializationTemporaryFile(in: root))
    }

    func testCancellationDuringLastReadDrainsCoreAndNeverCommits() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let content = Data(repeating: 6, count: 64)
        let item = IndexedItem(
            id: "item-cancel-read",
            folderID: folderID,
            relativePath: "cancel-read.bin",
            isDirectory: false,
            size: Int64(content.count),
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 7, count: 32),
            metadataVersion: Data(repeating: 8, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 6
        )
        let client = CancellationAwareReadCoreClient(item: item, content: content)
        let runtime = CoreRuntime(clientFactory: { client })
        let destination = root.appendingPathComponent("provider-result.bin")
        let run = Task {
            await runtime.materialize(
                item,
                to: destination,
                trigger: .fileProvider,
                paths: paths,
                environment: .permissiveForTesting,
                destinationAvailableCapacity: { _ in .max }
            )
        }

        try await client.waitUntilReadBegins()
        run.cancel()
        let outcome = await run.value

        XCTAssertEqual(outcome, .failed(code: "cancelled"))
        let cancellationRequests = await client.cancellationRequestCount()
        XCTAssertGreaterThanOrEqual(cancellationRequests, 1)
        let stopCount = await client.stopCount()
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try containsMaterializationTemporaryFile(in: root))
        let history = try SyncRunHistory(url: paths.history).recent(limit: 10)
        XCTAssertTrue(
            history.contains {
                $0.endReason == .cancelled && $0.failureCode == "cancelled"
            }
        )
    }

    func testMaterializationNetworkLossCancelsBlockedReadAndNeverCommits() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let content = Data(repeating: 6, count: 64)
        let item = IndexedItem(
            id: "item-policy-cancel-read",
            folderID: folderID,
            relativePath: "policy-cancel-read.bin",
            isDirectory: false,
            size: Int64(content.count),
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 7, count: 32),
            metadataVersion: Data(repeating: 8, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 6
        )
        let client = CancellationAwareReadCoreClient(item: item, content: content)
        let runtime = CoreRuntime(clientFactory: { client })
        let destination = root.appendingPathComponent("provider-result.bin")
        let environments = MutableEnvironment(.permissiveForTesting)
        let run = Task {
            await runtime.materialize(
                item,
                to: destination,
                trigger: .fileProvider,
                paths: paths,
                environment: .permissiveForTesting,
                currentEnvironment: { await environments.current() },
                destinationAvailableCapacity: { _ in .max }
            )
        }

        try await client.waitUntilReadBegins()
        await environments.update(Self.deniedNetworkEnvironment)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { run.cancel() }
        }
        let outcome = await run.value
        timeout.cancel()

        guard case .policyDenied(let reasons) = outcome else {
            return XCTFail("Expected a live policy denial, got \(outcome)")
        }
        XCTAssertTrue(reasons.contains(.networkUnavailable))
        let cancellationRequests = await client.cancellationRequestCount()
        XCTAssertGreaterThanOrEqual(cancellationRequests, 1)
        let stopCount = await client.stopCount()
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try containsMaterializationTemporaryFile(in: root))
    }

    func testCancellationDuringCoreDrainNeverCommitsOrStopsTwice() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let content = Data(repeating: 9, count: 64)
        let item = IndexedItem(
            id: "item-cancel-stop",
            folderID: folderID,
            relativePath: "cancel-stop.bin",
            isDirectory: false,
            size: Int64(content.count),
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 7, count: 32),
            metadataVersion: Data(repeating: 8, count: 32),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: 7
        )
        let client = BlockingMaterializationStopCoreClient(item: item, content: content)
        let runtime = CoreRuntime(clientFactory: { client })
        let destination = root.appendingPathComponent("provider-result.bin")
        let run = Task {
            await runtime.materialize(
                item,
                to: destination,
                trigger: .fileProvider,
                paths: paths,
                environment: .permissiveForTesting,
                destinationAvailableCapacity: { _ in .max }
            )
        }

        try await client.waitUntilStopBegins()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        run.cancel()
        await client.finishStop()
        let outcome = await run.value

        XCTAssertEqual(outcome, .failed(code: "cancelled"))
        let stopCount = await client.stopCount()
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try containsMaterializationTemporaryFile(in: root))
    }

    private func assertRejectedCommand(
        error: CoreClientError,
        expectedStatus: CoreCommandResultStatus,
        expectedCode: String,
        kind: CoreCommandKind = .sync,
        command suppliedCommand: CoreCommand? = nil
    ) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command =
            try suppliedCommand
            ?? runtimeTestCommand(kind: kind, paths: paths, trigger: .user)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let runtime = CoreRuntime(clientFactory: { RejectingCoreClient(error: error) })

        let outcome = await runtime.processPending(
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: expectedCode))
        let expectedPendingIDs = expectedStatus == .retryable ? [command.id] : []
        XCTAssertEqual(try queue.pending().map(\.id), expectedPendingIDs)
        let result = try XCTUnwrap(queue.result(for: command.id))
        XCTAssertEqual(result.status, expectedStatus)
        XCTAssertEqual(result.errorCode, expectedCode)
        XCTAssertGreaterThan(result.snapshotGeneration ?? 0, 0)
    }

    private func pendingFolderSuppressionRuntimeTestCommand() throws -> CoreCommand {
        CoreCommand(
            kind: .ignorePendingFolder,
            folderID: try XCTUnwrap(FolderID(rawValue: "pending-folder")),
            arguments: [
                "observationProofID": CoreSessionDigest.stableVersion([
                    "runtime-test-pending-folder-proof"
                ]),
                "offeringDeviceID": runtimeTestDeviceID.rawValue,
                "offerVersion": CoreSessionDigest.stableVersion([
                    "runtime-test-pending-folder-offer"
                ]),
            ],
            commandConfigurationRevision: runtimeTestConfigurationRevision,
            trigger: .user
        )
    }

    private func mutationFixture() throws -> MutationFixture {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SharedContainerPaths(root: root)
        let folderID = try XCTUnwrap(FolderID(rawValue: "mutation-folder"))
        let folderRoot = try paths.createManagedFolder(for: folderID)
        let folder = FolderRecord(
            id: folderID,
            label: "Mutation Folder",
            localPath: folderRoot.path
        )
        try SharedSnapshotStore(snapshotURL: paths.snapshot).write(
            CoreSnapshot(
                generation: 1,
                configurationRevision: runtimeTestConfigurationRevision,
                folders: [folder]
            )
        )
        _ = try FolderIncarnationStore(url: paths.folderIncarnations)
            .ensureLegacyConfiguredFolders([folderID])
        return MutationFixture(paths: paths, folder: folder, folderRoot: folderRoot)
    }

    private func persistMutationBaseline(
        fixture: MutationFixture,
        items: [IndexedItem]
    ) throws {
        try SharedSnapshotStore(snapshotURL: fixture.paths.snapshot).write(
            CoreSnapshot(
                generation: 1,
                configurationRevision: runtimeTestConfigurationRevision,
                folders: [fixture.folder],
                items: items
            )
        )
    }

    private func stagingStore(paths: SharedContainerPaths) -> FileProviderStagingStore {
        FileProviderStagingStore(
            root: paths.fileProviderStaging,
            minimumFreeSpaceBytes: 0,
            availableCapacity: { _ in Int64.max }
        )
    }

    private func stagedMutationCommand(
        id: UUID,
        paths: SharedContainerPaths
    ) throws -> CoreCommand {
        let source = paths.root.appendingPathComponent("staging-source-" + id.uuidString)
        try Data("staged upload".utf8).write(to: source)
        let token = try stagingStore(paths: paths).stage(source, id: id)
        return try runtimeTestCommand(
            id: id,
            kind: .modify,
            paths: paths,
            arguments: ["stagedContentToken": token],
            trigger: .fileProvider
        )
    }

    private func assertStagingReleased(
        for id: UUID,
        paths: SharedContainerPaths,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.fileProviderStaging.appendingPathComponent(id.uuidString).path
            ),
            file: file,
            line: line
        )
        let reservations = paths.fileProviderStaging.appendingPathComponent(
            ".reservations-v1.json"
        )
        if FileManager.default.fileExists(atPath: reservations.path) {
            let text = try String(contentsOf: reservations, encoding: .utf8)
            XCTAssertFalse(
                text.lowercased().contains(id.uuidString.lowercased()),
                file: file,
                line: line
            )
        }
    }

    private func mutationItem(
        id: String,
        folderID: FolderID,
        parentID: String? = nil,
        relativePath: String,
        isDirectory: Bool,
        generation: UInt64
    ) -> IndexedItem {
        IndexedItem(
            id: id,
            folderID: folderID,
            parentID: parentID,
            relativePath: relativePath,
            isDirectory: isDirectory,
            size: isDirectory ? 0 : 5,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(generation)),
            contentVersion: Data(repeating: UInt8(truncatingIfNeeded: generation), count: 32),
            metadataVersion: Data(repeating: UInt8(truncatingIfNeeded: generation + 1), count: 32),
            availability: .local,
            generation: generation
        )
    }

    private func providerFolderIdentifier(_ folderID: FolderID) -> String {
        let digest = SHA256.hash(data: Data(folderID.rawValue.utf8))
        return "folder-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func runtimeTestCommand(
        id: UUID = UUID(),
        kind: CoreCommandKind,
        paths: SharedContainerPaths,
        folderID requestedFolderID: FolderID? = nil,
        itemID: String? = nil,
        arguments: [String: String] = [:],
        trigger: SyncTrigger,
        createdAt: Date = .now
    ) throws -> CoreCommand {
        let snapshotStore = SharedSnapshotStore(snapshotURL: paths.snapshot)
        var snapshot = try snapshotStore.read() ?? CoreSnapshot(generation: 1)
        snapshot.configurationRevision = runtimeTestConfigurationRevision

        var folderID = requestedFolderID
        if requestedFolderID != nil || !kind.usesOfflineConfigurationSession {
            if folderID == nil { folderID = snapshot.folders.first?.id }
            if folderID == nil {
                folderID = FolderID(rawValue: "runtime-test-folder")
            }
            let exactFolderID = try XCTUnwrap(folderID)
            if !snapshot.folders.contains(where: { $0.id == exactFolderID }) {
                let folderRoot = try paths.createManagedFolder(for: exactFolderID)
                snapshot.folders.append(
                    FolderRecord(
                        id: exactFolderID,
                        label: "Runtime Test Folder",
                        localPath: folderRoot.path
                    )
                )
            }
            _ = try FolderIncarnationStore(url: paths.folderIncarnations)
                .ensureLegacyConfiguredFolders([exactFolderID])
        }
        try snapshotStore.write(snapshot)

        let commands = try ScopedCoreCommandProducer(paths: paths).prepareCommands(
            invocationID: id,
            kind: kind,
            folderID: folderID,
            itemID: itemID,
            arguments: arguments,
            trigger: trigger,
            createdAt: createdAt
        )
        XCTAssertEqual(commands.count, 1)
        return try XCTUnwrap(commands.first)
    }

    private func runtimeTestCommand(
        _ command: CoreCommand,
        paths: SharedContainerPaths
    ) throws -> CoreCommand {
        try runtimeTestCommand(
            id: command.id,
            kind: command.kind,
            paths: paths,
            folderID: command.folderID,
            itemID: command.itemID,
            arguments: command.arguments,
            trigger: command.trigger,
            createdAt: command.createdAt
        )
    }

    private func containsMaterializationTemporaryFile(in directory: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains(where: { $0.hasPrefix(".psy-materialize-") })
    }

    private static var deniedNetworkEnvironment: SyncEnvironmentSnapshot {
        var environment = SyncEnvironmentSnapshot.permissiveForTesting
        environment.network = .init(kind: .unavailable)
        return environment
    }

    private static var deniedDiskEnvironment: SyncEnvironmentSnapshot {
        var environment = SyncEnvironmentSnapshot.permissiveForTesting
        environment.safety.availableDiskBytes = 0
        return environment
    }
}

private struct MutationFixture {
    let paths: SharedContainerPaths
    let folder: FolderRecord
    let folderRoot: URL
}

private let runtimeTestConfigurationRevision = String(repeating: "a", count: 64)
private let runtimeTestDeviceID = DeviceID(rawValue: String(repeating: "A", count: 56))!

private protocol RuntimeExplicitSessionTestClient: CoreClient, AnyObject {
    func runtimeRawSnapshot() async throws -> CoreSnapshot
}

private struct RuntimeExplicitSessionSnapshotContext: Sendable {
    var revision: String
    var deviceID: DeviceID
    var folders: [FolderRecord]
    var root: URL?
}

private actor RuntimeExplicitSessionTestState {
    private var binding: CoreExplicitSessionBinding?
    private var deviceID = runtimeTestDeviceID
    private var revision = runtimeTestConfigurationRevision
    private var folders: [FolderRecord] = []
    private var root: URL?
    private var generation: UInt64 = 0
    private var lastMaximumNetworkBytes: String?
    private var lastNetworkOperation: CoreNetworkSessionOperation?

    func openConfiguration(
        sessionID: UUID,
        root: URL,
        persistedSnapshot: CoreSnapshot?
    ) throws -> CoreExplicitSessionReceipt {
        guard binding == nil else { throw CoreClientError.coreRejected("session_conflict") }
        if let persistedSnapshot {
            folders = persistedSnapshot.folders
        }
        self.root = root
        revision = runtimeTestConfigurationRevision
        deviceID = persistedSnapshot?.localDeviceID ?? runtimeTestDeviceID
        generation += 1
        let next = CoreExplicitSessionBinding.configuration(sessionID: sessionID)
        binding = next
        return try CoreExplicitSessionReceipt(
            binding: next,
            deviceID: deviceID,
            generation: generation,
            configurationRevision: revision
        )
    }

    func openNetwork(
        sessionID: UUID,
        plan: CoreNetworkSessionPlan,
        deviceID: DeviceID
    ) throws -> CoreExplicitSessionReceipt {
        guard binding == nil else { throw CoreClientError.coreRejected("session_conflict") }
        self.deviceID = deviceID
        revision = plan.expectedConfigurationRevision
        lastMaximumNetworkBytes = plan.maximumNetworkBytes.wireValue
        lastNetworkOperation = plan.operation
        generation += 1
        let next = CoreExplicitSessionBinding.network(sessionID: sessionID, plan: plan)
        binding = next
        return try CoreExplicitSessionReceipt(
            binding: next,
            deviceID: deviceID,
            generation: generation,
            configurationRevision: revision
        )
    }

    func activeMode() throws -> CoreExplicitSessionMode {
        guard let binding else { throw CoreClientError.coreRejected("no_active_session") }
        return binding.mode
    }

    func close() throws -> CoreExplicitSessionReceipt {
        guard let binding else { throw CoreClientError.coreRejected("no_active_session") }
        generation += 1
        self.binding = nil
        return try CoreExplicitSessionReceipt(
            binding: binding,
            deviceID: deviceID,
            generation: generation,
            configurationRevision: revision
        )
    }

    func snapshotContext() -> RuntimeExplicitSessionSnapshotContext {
        RuntimeExplicitSessionSnapshotContext(
            revision: revision,
            deviceID: deviceID,
            folders: folders,
            root: root
        )
    }

    func networkOperation() -> CoreNetworkSessionOperation? {
        lastNetworkOperation
    }

    func coherentZeroTotals() -> CoreNetworkTransferTotals {
        coherentTotals(receivedBytes: 0, sentBytes: 0)
    }

    func coherentTotals(
        receivedBytes: Int64,
        sentBytes: Int64
    ) -> CoreNetworkTransferTotals {
        let used = receivedBytes + sentBytes
        guard let maximum = lastMaximumNetworkBytes, maximum != "unlimited" else {
            return CoreNetworkTransferTotals(
                receivedBytes: receivedBytes,
                sentBytes: sentBytes,
                budgetLimited: false,
                budgetLimitBytes: 0,
                budgetUsedBytes: used,
                budgetExhausted: false
            )
        }
        let limit = Int64(maximum) ?? 0
        return CoreNetworkTransferTotals(
            receivedBytes: receivedBytes,
            sentBytes: sentBytes,
            budgetLimited: true,
            budgetLimitBytes: limit,
            budgetUsedBytes: used,
            budgetExhausted: used == limit
        )
    }
}

private final class RuntimeExplicitSessionTestStateRegistry: @unchecked Sendable {
    static let shared = RuntimeExplicitSessionTestStateRegistry()

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: (AnyObject, RuntimeExplicitSessionTestState)] = [:]

    func state(for owner: AnyObject) -> RuntimeExplicitSessionTestState {
        lock.withLock {
            let key = ObjectIdentifier(owner)
            if let existing = entries[key] { return existing.1 }
            let state = RuntimeExplicitSessionTestState()
            entries[key] = (owner, state)
            return state
        }
    }
}

extension RuntimeExplicitSessionTestClient {
    fileprivate var runtimeExplicitSessionState: RuntimeExplicitSessionTestState {
        RuntimeExplicitSessionTestStateRegistry.shared.state(for: self)
    }

    func openConfigurationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID
    ) async throws -> CoreExplicitSessionReceipt {
        let root = configurationDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let persisted = try? SharedSnapshotStore(
            snapshotURL: SharedContainerPaths(root: root).snapshot
        ).read()
        return try await runtimeExplicitSessionState.openConfiguration(
            sessionID: sessionID,
            root: root,
            persistedSnapshot: persisted
        )
    }

    func openNetworkSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID,
        plan: CoreNetworkSessionPlan
    ) async throws -> CoreExplicitSessionReceipt {
        let deviceID = try await start(
            configurationDirectory: configurationDirectory,
            dataDirectory: dataDirectory
        )
        return try await runtimeExplicitSessionState.openNetwork(
            sessionID: sessionID,
            plan: plan,
            deviceID: deviceID
        )
    }

    func closeExplicitSession() async throws -> CoreExplicitSessionReceipt {
        if try await runtimeExplicitSessionState.activeMode() == .network {
            try await stop()
        }
        return try await runtimeExplicitSessionState.close()
    }

    func snapshot() async throws -> CoreSnapshot {
        var snapshot = try await runtimeRawSnapshot()
        let context = await runtimeExplicitSessionState.snapshotContext()
        snapshot.configurationRevision = context.revision
        snapshot.localDeviceID = snapshot.localDeviceID ?? context.deviceID
        let existing = Set(snapshot.folders.map(\.id))
        snapshot.folders.append(contentsOf: context.folders.filter { !existing.contains($0.id) })
        if let root = context.root {
            let paths = SharedContainerPaths(root: root)
            let configured = Set(snapshot.folders.map(\.id))
            for folderID in Set(snapshot.items.map(\.folderID)).subtracting(configured) {
                let folderRoot = try paths.createManagedFolder(for: folderID)
                snapshot.folders.append(
                    FolderRecord(
                        id: folderID,
                        label: "Runtime Test Folder",
                        localPath: folderRoot.path
                    )
                )
            }
        }
        return snapshot
    }

    func networkTransferTotals() async throws -> CoreNetworkTransferTotals? {
        await runtimeExplicitSessionState.coherentZeroTotals()
    }
}

private enum RuntimeTestWaitError: Error {
    case timedOut(String)
}

private actor MutationReconciliationCoreClient: RuntimeExplicitSessionTestClient {
    private let rejectedCommandID: UUID?
    private let rejection: CoreClientError
    private let rescanRejection: CoreClientError?
    private let beforeRejectedCommandFailure: @Sendable () throws -> Void
    private let authoritativeSnapshot: CoreSnapshot
    private var commands: [CoreCommand] = []
    private var acknowledgedIDs: [UUID] = []
    private var reconciledIDs: [UUID] = []

    init(
        rejectedCommandID: UUID?,
        rejection: CoreClientError,
        rescanRejection: CoreClientError? = nil,
        beforeRejectedCommandFailure: @escaping @Sendable () throws -> Void = {},
        snapshot: CoreSnapshot
    ) {
        self.rejectedCommandID = rejectedCommandID
        self.rejection = rejection
        self.rescanRejection = rescanRejection
        self.beforeRejectedCommandFailure = beforeRejectedCommandFailure
        authoritativeSnapshot = snapshot
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {}

    func runtimeRawSnapshot() async throws -> CoreSnapshot { authoritativeSnapshot }

    func execute(_ command: CoreCommand) async throws {
        commands.append(command)
        if command.id == rejectedCommandID {
            try beforeRejectedCommandFailure()
            throw rejection
        }
        if command.kind == .rescan, let rescanRejection { throw rescanRejection }
    }

    func acknowledgeCommand(_ id: UUID) async throws {
        acknowledgedIDs.append(id)
    }

    func acknowledgeReconciledCommand(
        _ command: CoreCommand,
        proof: CoreMutationReconciliationProof
    ) async throws {
        guard proof.snapshotGeneration >= authoritativeSnapshot.generation,
            proof.ownerEpoch > 0,
            proof.stateDigest.count == 32
        else {
            throw CoreClientError.invalidResponse("test reconciliation proof")
        }
        reconciledIDs.append(command.id)
        acknowledgedIDs.append(command.id)
    }

    func executedCommands() -> [CoreCommand] { commands }
    func acknowledgedCommandIDs() -> [UUID] { acknowledgedIDs }
    func reconciledCommandIDs() -> [UUID] { reconciledIDs }
}

private actor ConfigurationReconciliationCoreClient: RuntimeExplicitSessionTestClient {
    private let localDeviceID: DeviceID
    private let authoritativeSnapshot: CoreSnapshot
    private var executedIDs: [UUID] = []
    private var reconciledIDs: [UUID] = []
    private var ordinaryAcknowledgedIDs: [UUID] = []
    private var reconciliationFailures: Int

    init(localDeviceID: DeviceID, snapshot: CoreSnapshot, reconciliationFailures: Int = 0) {
        self.localDeviceID = localDeviceID
        authoritativeSnapshot = snapshot
        self.reconciliationFailures = reconciliationFailures
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        localDeviceID
    }

    func stop() async throws {}
    func runtimeRawSnapshot() async throws -> CoreSnapshot { authoritativeSnapshot }

    func execute(_ command: CoreCommand) async throws {
        executedIDs.append(command.id)
    }

    func acknowledgeCommand(_ id: UUID) async throws {
        ordinaryAcknowledgedIDs.append(id)
    }

    func acknowledgeReconciledConfigurationCommand(
        _ command: CoreCommand,
        proof: CoreConfigurationReconciliationProof
    ) async throws {
        guard command.isConfigurationReconciliationCommand,
            proof.snapshotGeneration >= authoritativeSnapshot.generation,
            proof.ownerEpoch > 0,
            proof.stateDigest.count == 32
        else {
            throw CoreClientError.invalidResponse("test configuration reconciliation proof")
        }
        reconciledIDs.append(command.id)
        if reconciliationFailures > 0 {
            reconciliationFailures -= 1
            throw CoreClientError.coreRejected("injected_configuration_reconciliation_failure")
        }
    }

    func executedCommandIDs() -> [UUID] { executedIDs }
    func configurationReconciledCommandIDs() -> [UUID] { reconciledIDs }
    func ordinaryAcknowledgedCommandIDs() -> [UUID] { ordinaryAcknowledgedIDs }
}

private actor StarvationLedgerCleanupCoreClient: RuntimeExplicitSessionTestClient {
    private let rejectedIDs: Set<UUID>
    private var successfulIDs: [UUID] = []

    init(rejectedIDs: Set<UUID>) {
        self.rejectedIDs = rejectedIDs
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {}
    func runtimeRawSnapshot() async throws -> CoreSnapshot { CoreSnapshot(generation: 1) }
    func execute(_ command: CoreCommand) async throws {}

    func acknowledgeCommand(_ id: UUID) async throws {
        if rejectedIDs.contains(id) {
            throw CoreClientError.coreRejected("injected_cleanup_failure")
        }
        successfulIDs.append(id)
    }

    func successfulAcknowledgementIDs() -> [UUID] { successfulIDs }
}

private actor PhaseAwareMutationRejectingCoreClient: RuntimeExplicitSessionTestClient {
    private let failure: CoreMutationFailure
    private var commands: [CoreCommand] = []
    private var acknowledgedIDs: [UUID] = []

    init(failure: CoreMutationFailure) {
        self.failure = failure
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {}
    func runtimeRawSnapshot() async throws -> CoreSnapshot { CoreSnapshot(generation: 1) }

    func execute(_ command: CoreCommand) async throws {
        commands.append(command)
        throw failure
    }

    func acknowledgeCommand(_ id: UUID) async throws {
        acknowledgedIDs.append(id)
    }

    func executedCommands() -> [CoreCommand] { commands }
    func acknowledgedCommandIDs() -> [UUID] { acknowledgedIDs }
}

extension Array {
    fileprivate func only(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        let matches = try filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }
}

private actor RejectingCoreClient: RuntimeExplicitSessionTestClient {
    private let error: CoreClientError

    init(error: CoreClientError) {
        self.error = error
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {}

    func runtimeRawSnapshot() async throws -> CoreSnapshot {
        CoreSnapshot(generation: 1)
    }

    func execute(_ command: CoreCommand) async throws {
        throw error
    }
}

private actor RejectOnceCoreClient: RuntimeExplicitSessionTestClient {
    private let error: CoreClientError
    private var rejected = false
    private var commandIDs: [UUID] = []

    init(error: CoreClientError) {
        self.error = error
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {}
    func runtimeRawSnapshot() async throws -> CoreSnapshot { CoreSnapshot(generation: 1) }

    func execute(_ command: CoreCommand) async throws {
        commandIDs.append(command.id)
        if !rejected {
            rejected = true
            throw error
        }
    }

    func executedCommandIDs() -> [UUID] { commandIDs }
}

private actor AlwaysRejectingRecordingCoreClient: RuntimeExplicitSessionTestClient {
    private let error: CoreClientError
    private var commandIDs: [UUID] = []
    private var acknowledgedIDs: [UUID] = []

    init(error: CoreClientError) {
        self.error = error
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {}
    func runtimeRawSnapshot() async throws -> CoreSnapshot { CoreSnapshot(generation: 1) }

    func execute(_ command: CoreCommand) async throws {
        commandIDs.append(command.id)
        throw error
    }

    func acknowledgeCommand(_ id: UUID) async throws {
        acknowledgedIDs.append(id)
    }

    func executedCommandIDs() -> [UUID] { commandIDs }
    func acknowledgedCommandIDs() -> [UUID] { acknowledgedIDs }
}

private actor SelectiveRejectingCoreClient: RuntimeExplicitSessionTestClient {
    private let rejectedID: UUID
    private var commandIDs: [UUID] = []

    init(rejectedID: UUID) {
        self.rejectedID = rejectedID
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {}

    func runtimeRawSnapshot() async throws -> CoreSnapshot {
        CoreSnapshot(generation: 1)
    }

    func execute(_ command: CoreCommand) async throws {
        commandIDs.append(command.id)
        if command.id == rejectedID {
            throw CoreClientError.coreRejected("unsupported_command")
        }
    }

    func executedCommandIDs() -> [UUID] { commandIDs }
}

private actor MaterializationLifecycleCountingCoreClient: RuntimeExplicitSessionTestClient {
    private var configurationOpens = 0
    private var networkStarts = 0

    func openConfigurationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID
    ) async throws -> CoreExplicitSessionReceipt {
        configurationOpens += 1
        throw CoreClientError.coreRejected("unexpected_configuration_open")
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        networkStarts += 1
        return runtimeTestDeviceID
    }

    func stop() async throws {}
    func execute(_ command: CoreCommand) async throws {}
    func runtimeRawSnapshot() async throws -> CoreSnapshot { CoreSnapshot(generation: 1) }

    func configurationOpenCount() -> Int { configurationOpens }
    func networkStartCount() -> Int { networkStarts }
}

private actor RecordingCoreClient: RuntimeExplicitSessionTestClient {
    private var commandIDs: [UUID] = []
    private var acknowledgedIDs: [UUID] = []
    private var started = false
    private let networkTotals: CoreNetworkTransferTotals?
    private let recoveryPage: CoreMutationRecoveryPage?

    init(
        networkTotals: CoreNetworkTransferTotals? = nil,
        recoveryPage: CoreMutationRecoveryPage? = nil
    ) {
        self.networkTotals = networkTotals
        self.recoveryPage = recoveryPage
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        started = true
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {}

    func runtimeRawSnapshot() async throws -> CoreSnapshot {
        CoreSnapshot(generation: 1)
    }

    func networkTransferTotals() async throws -> CoreNetworkTransferTotals? {
        guard let networkTotals else {
            return await runtimeExplicitSessionState.coherentZeroTotals()
        }
        return await runtimeExplicitSessionState.coherentTotals(
            receivedBytes: networkTotals.receivedBytes,
            sentBytes: networkTotals.sentBytes
        )
    }

    func execute(_ command: CoreCommand) async throws {
        commandIDs.append(command.id)
    }

    func acknowledgeCommand(_ id: UUID) async throws {
        acknowledgedIDs.append(id)
    }

    func mutationRecoveries(after cursor: String?, limit: Int) async throws
        -> CoreMutationRecoveryPage
    {
        guard cursor == nil, (1...200).contains(limit), let recoveryPage else {
            throw CoreClientError.invalidResponse("test_recovery_query")
        }
        return recoveryPage
    }

    func executedCommandIDs() -> [UUID] { commandIDs }
    func acknowledgedCommandIDs() -> [UUID] { acknowledgedIDs }
    func wasStarted() -> Bool { started }
}

private actor RecoveryExportCoreClient: RuntimeExplicitSessionTestClient {
    private let root: URL
    private var observedSummary: CoreMutationRecoverySummary?
    private var exports: [UUID: URL] = [:]
    private var acknowledgedRequestIDs: Set<UUID> = []
    private var legacyStarted = false
    private let retainedSource = Data(repeating: 0x52, count: 25)

    init(root: URL) {
        self.root = root
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        legacyStarted = true
        return runtimeTestDeviceID
    }

    func stop() async throws {}

    func runtimeRawSnapshot() async throws -> CoreSnapshot {
        CoreSnapshot(generation: 1)
    }

    func execute(_ command: CoreCommand) async throws {}

    func exportMutationRecovery(
        _ summary: CoreMutationRecoverySummary,
        exportID: UUID,
        outputName: String
    ) async throws {
        let paths = SharedContainerPaths(root: root)
        let export = try CoreMutationRecoveryExportBuilder.export(
            for: summary,
            exportID: exportID,
            paths: paths
        )
        guard export.url.lastPathComponent == outputName else {
            throw CoreClientError.invalidResponse("test_recovery_export_name")
        }
        try FileManager.default.createDirectory(
            at: export.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try retainedSource.write(to: export.url, options: .withoutOverwriting)
        observedSummary = summary
        exports[exportID] = export.url
    }

    func discardMutationRecoveryExport(_ exportID: UUID, requestID _: UUID) async throws {
        guard let url = exports.removeValue(forKey: exportID) else { return }
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func acknowledgeCommand(_ id: UUID) async throws {
        guard acknowledgedRequestIDs.insert(id).inserted else {
            throw CoreClientError.invalidResponse("duplicate_test_acknowledgement")
        }
    }

    func exportedSummary() -> CoreMutationRecoverySummary? { observedSummary }
    func wasLegacyStarted() -> Bool { legacyStarted }
    func retainedSourceIsUnchanged() -> Bool {
        retainedSource == Data(repeating: 0x52, count: 25)
    }
    func acknowledgementCount() -> Int { acknowledgedRequestIDs.count }
}

private actor RecoveryRejectingCoreClient: RuntimeExplicitSessionTestClient {
    let code: String

    init(code: String) { self.code = code }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test_device_id")
        }
        return deviceID
    }

    func stop() async throws {}

    func runtimeRawSnapshot() async throws -> CoreSnapshot { CoreSnapshot(generation: 1) }

    func execute(_ command: CoreCommand) async throws {
        throw CoreClientError.coreRejected(code)
    }
}

private actor BlockingStopCoreClient: RuntimeExplicitSessionTestClient {
    private var stopBegan = false
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {
        stopBegan = true
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func runtimeRawSnapshot() async throws -> CoreSnapshot {
        CoreSnapshot(generation: 1)
    }

    func execute(_ command: CoreCommand) async throws {}

    func waitUntilStopBegins() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !stopBegan {
            guard clock.now < deadline else {
                throw RuntimeTestWaitError.timedOut("blocking stop did not begin")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func finishStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private actor RangeCoreClient: RuntimeExplicitSessionTestClient {
    private let item: IndexedItem
    private let content: Data
    private let shortRead: Bool
    private var ranges: [CoreReadRangeRequest] = []
    private var commands: [CoreCommand] = []
    private var stopped = false

    init(item: IndexedItem, content: Data, shortRead: Bool = false) {
        self.item = item
        self.content = content
        self.shortRead = shortRead
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {
        stopped = true
    }

    func runtimeRawSnapshot() async throws -> CoreSnapshot {
        CoreSnapshot(generation: 1, items: [item])
    }

    func execute(_ command: CoreCommand) async throws {
        commands.append(command)
    }

    func readRange(_ request: CoreReadRangeRequest) async throws -> Data {
        ranges.append(request)
        let start = Int(request.offset)
        let end = start + request.length
        guard start >= 0, end <= content.count else {
            throw CoreClientError.coreRejected("invalid_range")
        }
        let requested = Data(content[start..<end])
        return shortRead && !requested.isEmpty ? Data(requested.dropLast()) : requested
    }

    func requestedRanges() -> [CoreReadRangeRequest] { ranges }
    func executedCommands() -> [CoreCommand] { commands }
    func didStop() -> Bool { stopped }
}

private actor EnvironmentSequence {
    private var environments: [SyncEnvironmentSnapshot]
    private var index = 0

    init(_ environments: [SyncEnvironmentSnapshot]) {
        self.environments = environments
    }

    func next() -> SyncEnvironmentSnapshot {
        guard !environments.isEmpty else { return .permissiveForTesting }
        defer { index = min(index + 1, environments.count - 1) }
        return environments[index]
    }
}

private actor MutableEnvironment {
    private var environment: SyncEnvironmentSnapshot

    init(_ environment: SyncEnvironmentSnapshot) {
        self.environment = environment
    }

    func current() -> SyncEnvironmentSnapshot { environment }

    func update(_ environment: SyncEnvironmentSnapshot) {
        self.environment = environment
    }
}

private actor PolicyCancellationCoreClient: RuntimeExplicitSessionTestClient {
    private var executeBegan = false
    private var executeContinuation: CheckedContinuation<Void, Never>?
    private var cancellationReceived = false
    private var cancellationRequests = 0
    private var stops = 0

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {
        stops += 1
    }

    nonisolated func requestCancellation() {
        Task { await receiveCancellation() }
    }

    func runtimeRawSnapshot() async throws -> CoreSnapshot {
        CoreSnapshot(generation: 1)
    }

    func execute(_ command: CoreCommand) async throws {
        executeBegan = true
        if !cancellationReceived {
            await withCheckedContinuation { continuation in
                if cancellationReceived {
                    continuation.resume()
                } else {
                    executeContinuation = continuation
                }
            }
        }
        throw CancellationError()
    }

    func waitUntilExecuteBegins() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !executeBegan {
            guard clock.now < deadline else {
                throw RuntimeTestWaitError.timedOut("policy execution did not begin")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func receiveCancellation() {
        cancellationRequests += 1
        cancellationReceived = true
        executeContinuation?.resume()
        executeContinuation = nil
    }

    func cancellationRequestCount() -> Int { cancellationRequests }
    func stopCount() -> Int { stops }
}

private actor PolicyInterruptedMutationCoreClient: RuntimeExplicitSessionTestClient {
    private let originalCommandID: UUID
    private let authoritativeSnapshot: CoreSnapshot
    private let persistedFailure = CoreMutationFailure(
        code: "propagation_not_indexed",
        phase: .postcommit,
        ambiguous: true
    )
    private var mutationCommitted = false
    private var interruptionContinuation: CheckedContinuation<Void, Never>?
    private var cancellationReceived = false
    private var deliveredOriginalResponse = false
    private var nativeMutationExecutions = 0
    private var reconciledIDs: [UUID] = []

    init(originalCommandID: UUID, snapshot: CoreSnapshot) {
        self.originalCommandID = originalCommandID
        authoritativeSnapshot = snapshot
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {}

    nonisolated func requestCancellation() {
        Task { await receiveCancellation() }
    }

    func runtimeRawSnapshot() async throws -> CoreSnapshot { authoritativeSnapshot }

    func execute(_ command: CoreCommand) async throws {
        guard command.id == originalCommandID else { return }
        if !deliveredOriginalResponse {
            deliveredOriginalResponse = true
            nativeMutationExecutions += 1
            mutationCommitted = true
            if !cancellationReceived {
                await withCheckedContinuation { continuation in
                    if cancellationReceived {
                        continuation.resume()
                    } else {
                        interruptionContinuation = continuation
                    }
                }
            }
        }
        // A repeated UUID replays this durable response. It never applies the
        // mutation again, allowing the Swift owner to reconcile safely.
        throw persistedFailure
    }

    func acknowledgeReconciledCommand(
        _ command: CoreCommand,
        proof: CoreMutationReconciliationProof
    ) async throws {
        guard command.id == originalCommandID,
            proof.snapshotGeneration >= authoritativeSnapshot.generation,
            proof.ownerEpoch > 0,
            proof.stateDigest.count == 32
        else {
            throw CoreClientError.invalidResponse("test reconciliation proof")
        }
        reconciledIDs.append(command.id)
    }

    func waitUntilMutationCommitted() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !mutationCommitted {
            guard clock.now < deadline else {
                throw RuntimeTestWaitError.timedOut("mutation did not commit")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func receiveCancellation() {
        cancellationReceived = true
        interruptionContinuation?.resume()
        interruptionContinuation = nil
    }

    func nativeMutationExecutionCount() -> Int { nativeMutationExecutions }
    func reconciledCommandIDs() -> [UUID] { reconciledIDs }
}

private final class CapacitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let capacities: [Int64]
    private var index = 0

    init(_ capacities: [Int64]) {
        self.capacities = capacities
    }

    func next() -> Int64 {
        lock.withLock {
            guard !capacities.isEmpty else { return 0 }
            defer { index = min(index + 1, capacities.count - 1) }
            return capacities[index]
        }
    }
}

private actor CancellationAwareReadCoreClient: RuntimeExplicitSessionTestClient {
    private let item: IndexedItem
    private let content: Data
    private var readBegan = false
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var stops = 0
    private var cancellationRequests = 0
    private var cancellationReceived = false

    init(item: IndexedItem, content: Data) {
        self.item = item
        self.content = content
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {
        stops += 1
    }

    nonisolated func requestCancellation() {
        Task { await receiveCancellation() }
    }

    func runtimeRawSnapshot() async throws -> CoreSnapshot {
        CoreSnapshot(generation: 1, items: [item])
    }

    func execute(_ command: CoreCommand) async throws {}

    func readRange(_ request: CoreReadRangeRequest) async throws -> Data {
        readBegan = true
        await withCheckedContinuation { continuation in
            readContinuation = continuation
        }
        if cancellationReceived { throw CancellationError() }
        return content
    }

    func waitUntilReadBegins() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !readBegan {
            guard clock.now < deadline else {
                throw RuntimeTestWaitError.timedOut("range read did not begin")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func receiveCancellation() {
        cancellationRequests += 1
        cancellationReceived = true
        readContinuation?.resume()
        readContinuation = nil
    }

    func stopCount() -> Int { stops }
    func cancellationRequestCount() -> Int { cancellationRequests }
}

private actor CancellationAwareMaterializationExecuteCoreClient: RuntimeExplicitSessionTestClient {
    private let item: IndexedItem
    private var executeBegan = false
    private var executeContinuation: CheckedContinuation<Void, Never>?
    private var cancellationReceived = false
    private var cancellationRequests = 0
    private var stops = 0

    init(item: IndexedItem) {
        self.item = item
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {
        stops += 1
    }

    nonisolated func requestCancellation() {
        Task { await receiveCancellation() }
    }

    func runtimeRawSnapshot() async throws -> CoreSnapshot {
        CoreSnapshot(generation: item.generation, items: [item])
    }

    func execute(_ command: CoreCommand) async throws {
        executeBegan = true
        if !cancellationReceived {
            await withCheckedContinuation { continuation in
                if cancellationReceived {
                    continuation.resume()
                } else {
                    executeContinuation = continuation
                }
            }
        }
        throw CancellationError()
    }

    func waitUntilExecuteBegins() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !executeBegan {
            guard clock.now < deadline else {
                throw RuntimeTestWaitError.timedOut("native materialization did not begin")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func receiveCancellation() {
        cancellationRequests += 1
        cancellationReceived = true
        executeContinuation?.resume()
        executeContinuation = nil
    }

    func cancellationRequestCount() -> Int { cancellationRequests }
    func stopCount() -> Int { stops }
}

private actor BlockingMaterializationStopCoreClient: RuntimeExplicitSessionTestClient {
    private let item: IndexedItem
    private let content: Data
    private var ranges: [CoreReadRangeRequest] = []
    private var stopBegan = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stops = 0

    init(item: IndexedItem, content: Data) {
        self.item = item
        self.content = content
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56)) else {
            throw CoreClientError.invalidResponse("test device ID")
        }
        return deviceID
    }

    func stop() async throws {
        stops += 1
        stopBegan = true
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func runtimeRawSnapshot() async throws -> CoreSnapshot {
        CoreSnapshot(generation: 1, items: [item])
    }

    func execute(_ command: CoreCommand) async throws {}

    func readRange(_ request: CoreReadRangeRequest) async throws -> Data {
        ranges.append(request)
        let start = Int(request.offset)
        let end = start + request.length
        guard start >= 0, end <= content.count else {
            throw CoreClientError.coreRejected("invalid_range")
        }
        return Data(content[start..<end])
    }

    func waitUntilStopBegins() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !stopBegan {
            guard clock.now < deadline else {
                throw RuntimeTestWaitError.timedOut("materialization drain did not begin")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func finishStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func requestedRanges() -> [CoreReadRangeRequest] { ranges }
    func didStop() -> Bool { stopBegan && stopContinuation == nil }
    func stopCount() -> Int { stops }
}
