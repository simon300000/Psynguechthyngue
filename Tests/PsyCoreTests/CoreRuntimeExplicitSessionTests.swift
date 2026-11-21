import CryptoKit
import Foundation
import XCTest

@testable import PsyCore

final class CoreRuntimeExplicitSessionTests: XCTestCase {
    private let currentRevision = String(repeating: "b", count: 64)
    private let previousRevision = String(repeating: "a", count: 64)

    func testConfigurationRefreshPreservesSiblingRuntimeOnlyForExactIdentity() async throws {
        let unchanged = try await refreshedSiblingSnapshot(
            previousRevision: currentRevision,
            mutateIncarnationDuringRefresh: false
        )
        XCTAssertEqual(unchanged.folders.first(where: { $0.id.rawValue == "sibling" })?.pendingUploadBytes, 91)
        XCTAssertEqual(unchanged.items.map(\.id), ["sibling-item"])
        XCTAssertEqual(
            unchanged.devices.first(where: { $0.name == "target-device" })?.uploadBytesPerSecond,
            50
        )
        XCTAssertEqual(
            unchanged.devices.first(where: { $0.name == "target-device" })?.downloadBytesPerSecond,
            30
        )
        XCTAssertEqual(
            unchanged.devices.first(where: { $0.name == "sibling-device" })?.uploadBytesPerSecond,
            0
        )
        XCTAssertEqual(
            unchanged.devices.first(where: { $0.name == "sibling-device" })?.downloadBytesPerSecond,
            0
        )

        let revisionDrift = try await refreshedSiblingSnapshot(
            previousRevision: previousRevision,
            mutateIncarnationDuringRefresh: false
        )
        XCTAssertEqual(revisionDrift.folders.first(where: { $0.id.rawValue == "sibling" })?.pendingUploadBytes, 0)
        XCTAssertTrue(revisionDrift.items.isEmpty)

        let incarnationDrift = try await refreshedSiblingSnapshot(
            previousRevision: currentRevision,
            mutateIncarnationDuringRefresh: true
        )
        XCTAssertEqual(incarnationDrift.folders.first(where: { $0.id.rawValue == "sibling" })?.pendingUploadBytes, 0)
        XCTAssertTrue(incarnationDrift.items.isEmpty)
    }

    func testConfigurationCompletedReplayDoesNotPreRejectStaleEnqueueRevision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = CoreCommand(
            kind: .addDevice,
            itemID: String(repeating: "C", count: 56),
            commandConfigurationRevision: previousRevision,
            trigger: .user
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = ExplicitSessionTestClient(
            configurationSnapshot: CoreSnapshot(
                generation: 1,
                configurationRevision: currentRevision
            ),
            networkSnapshot: CoreSnapshot(
                generation: 1,
                configurationRevision: currentRevision
            )
        )

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .backgroundProcessing,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .completed(processedCommands: 1, snapshotGeneration: 1))
        let executedIDs = await client.executedCommands().map(\.id)
        let openedModes = await client.openedModes()
        XCTAssertEqual(executedIDs, [command.id])
        XCTAssertEqual(openedModes, [.configuration])
        XCTAssertTrue(try queue.pending().isEmpty)
        XCTAssertEqual(try queue.result(for: command.id)?.status, .succeeded)
    }

    func testStaleDurableRevisionRejectsEveryFileProviderMutationBeforeNativeExecution() async throws {
        for kind in [
            CoreCommandKind.create,
            .modify,
            .move,
            .delete,
        ] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = SharedContainerPaths(root: root)
            let folder = try folderRecord(id: "stale-file-provider-\(kind.rawValue)", paths: paths)
            let context = try XCTUnwrap(
                try FolderIncarnationStore(url: paths.folderIncarnations)
                    .ensureLegacyConfiguredFolders([folder.id]).first
            )
            try SharedSnapshotStore(snapshotURL: paths.snapshot).write(
                CoreSnapshot(
                    generation: 1,
                    configurationRevision: previousRevision,
                    folders: [folder]
                )
            )
            let command = CoreCommand(
                kind: kind,
                folderID: folder.id,
                itemID: kind == .create ? nil : "stable-item",
                folderIncarnationDigest: context.folderIncarnationDigest,
                commandConfigurationRevision: previousRevision,
                trigger: .fileProvider
            )
            let queue = CoreCommandQueue(root: paths.commandQueue)
            try queue.enqueue(command)
            let client = ExplicitSessionTestClient(
                configurationSnapshot: snapshot(folders: [folder]),
                networkSnapshot: snapshot(folders: [folder])
            )

            let outcome = await CoreRuntime(clientFactory: { client }).processPending(
                trigger: .fileProvider,
                paths: paths,
                environment: .permissiveForTesting
            )

            XCTAssertEqual(outcome, .failed(code: "configuration_revision_mismatch"))
            let executed = await client.executedCommands()
            let openedModes = await client.openedModes()
            XCTAssertTrue(executed.isEmpty)
            XCTAssertEqual(openedModes, [.configuration])
        }
    }

    func testNoPendingCompletedCleanupUsesTheCommandsExactSession() async throws {
        let configurationRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: configurationRoot) }
        let configurationPaths = SharedContainerPaths(root: configurationRoot)
        let configurationCommand = CoreCommand(kind: .addDevice, trigger: .user)
        let configurationQueue = CoreCommandQueue(root: configurationPaths.commandQueue)
        try makeCompleted(configurationCommand, in: configurationQueue)
        let configurationClient = ExplicitSessionTestClient(
            configurationSnapshot: CoreSnapshot(
                generation: 1,
                configurationRevision: currentRevision
            ),
            networkSnapshot: CoreSnapshot(
                generation: 1,
                configurationRevision: currentRevision
            )
        )

        let configurationOutcome = await CoreRuntime(clientFactory: { configurationClient })
            .processPending(
                trigger: .foreground,
                paths: configurationPaths,
                environment: .permissiveForTesting
            )

        XCTAssertEqual(
            configurationOutcome,
            .completed(processedCommands: 0, snapshotGeneration: 1)
        )
        let configurationAcknowledgementModes = await configurationClient.acknowledgementModes()
        XCTAssertEqual(configurationAcknowledgementModes, [.configuration])
        XCTAssertTrue(try configurationQueue.completed().isEmpty)

        let networkRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: networkRoot) }
        let networkPaths = SharedContainerPaths(root: networkRoot)
        let folder = try folderRecord(id: "cleanup-folder", paths: networkPaths)
        let context = try XCTUnwrap(
            try FolderIncarnationStore(url: networkPaths.folderIncarnations)
                .ensureLegacyConfiguredFolders([folder.id]).first
        )
        let networkCommand = CoreCommand(
            kind: .sync,
            folderID: folder.id,
            folderIncarnationDigest: context.folderIncarnationDigest,
            trigger: .user
        )
        let networkQueue = CoreCommandQueue(root: networkPaths.commandQueue)
        try makeCompleted(networkCommand, in: networkQueue)
        let networkClient = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [folder]),
            networkSnapshot: snapshot(folders: [folder])
        )

        let networkOutcome = await CoreRuntime(clientFactory: { networkClient }).processPending(
            trigger: .foreground,
            paths: networkPaths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(networkOutcome, .completed(processedCommands: 0, snapshotGeneration: 2))
        let networkOpenedModes = await networkClient.openedModes()
        let networkAcknowledgementModes = await networkClient.acknowledgementModes()
        let openedFolderIDs = await networkClient.openedPlans().map(\.folderID)
        XCTAssertEqual(networkOpenedModes, [.configuration, .network])
        XCTAssertEqual(networkAcknowledgementModes, [.network])
        XCTAssertEqual(openedFolderIDs, [folder.id])
        XCTAssertTrue(try networkQueue.completed().isEmpty)
    }

    func testConfigurationCleanupNeverReappliesOldIncarnationTransition() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folder = try folderRecord(id: "configuration-readd", paths: paths)
        let store = FolderIncarnationStore(url: paths.folderIncarnations)
        let oldContext = try XCTUnwrap(try store.ensureLegacyConfiguredFolders([folder.id]).first)
        let oldRemove = CoreCommand(
            kind: .removeFolder,
            folderID: folder.id,
            folderIncarnationDigest: oldContext.folderIncarnationDigest,
            commandConfigurationRevision: previousRevision,
            trigger: .user
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try makeCompleted(oldRemove, in: queue)
        _ = try store.removeAfterSuccessfulDeletion(
            folderID: folder.id,
            expectedFolderIncarnationDigest: oldContext.folderIncarnationDigest
        )
        let newContext = try store.recordSuccessfulCreation(
            folderID: folder.id,
            commandID: UUID()
        )
        let client = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [folder]),
            networkSnapshot: snapshot(folders: [folder])
        )

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .completed(processedCommands: 0, snapshotGeneration: 1))
        XCTAssertEqual(try store.policyContext(for: folder.id), newContext)
        let acknowledgementModes = await client.acknowledgementModes()
        XCTAssertEqual(acknowledgementModes, [.configuration])
        XCTAssertTrue(try queue.completed().isEmpty)
    }

    func testConfigurationManualReconciliationAcknowledgesBeforeSessionClose() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folder = try folderRecord(id: "configuration-reconcile", paths: paths)
        let store = FolderIncarnationStore(url: paths.folderIncarnations)
        let context = try XCTUnwrap(try store.ensureLegacyConfiguredFolders([folder.id]).first)
        let command = CoreCommand(
            kind: .removeFolder,
            folderID: folder.id,
            folderIncarnationDigest: context.folderIncarnationDigest,
            commandConfigurationRevision: previousRevision,
            trigger: .user
        )
        let priorCoordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        let priorLease = try await priorCoordinator.acquire(as: .mainApp)
        await priorCoordinator.release()
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(
            CoreCommandResult(
                commandID: command.id,
                status: .failed,
                ownerEpoch: priorLease.epoch,
                instanceID: priorLease.instanceID,
                errorCode: "coreExecutionFailed"
            )
        )
        try queue.acknowledge(command)
        let client = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(),
            networkSnapshot: snapshot()
        )

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .completed(processedCommands: 1, snapshotGeneration: 1))
        let reconciledIDs = await client.configurationReconciledCommandIDs()
        XCTAssertEqual(reconciledIDs, [command.id])
        let events = await client.events()
        let acknowledgementIndex = try XCTUnwrap(
            events.firstIndex(of: "ack-reconciled:configuration")
        )
        let closeIndex = try XCTUnwrap(events.firstIndex(of: "close:configuration"))
        XCTAssertLessThan(acknowledgementIndex, closeIndex)
        XCTAssertTrue(try queue.completed().isEmpty)
        XCTAssertThrowsError(try store.policyContext(for: folder.id))
    }

    func testMalformedGlobalNetworkCommandIsTerminalAndCannotLivelock() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let command = CoreCommand(kind: .sync, trigger: .backgroundProcessing)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(),
            networkSnapshot: snapshot()
        )

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .backgroundProcessing,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "folder_scope_required"))
        XCTAssertEqual(try queue.result(for: command.id)?.status, .blocked)
        XCTAssertTrue(try queue.pending().isEmpty)
        XCTAssertTrue(try queue.completed().isEmpty)
        let events = await client.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testManualMutationReconciliationUsesScopedRescanAndRetiresBothLedgers() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.fileProviderStaging,
            withIntermediateDirectories: true
        )
        let folder = try folderRecord(id: "mutation-folder", paths: paths)
        let context = try XCTUnwrap(
            try FolderIncarnationStore(url: paths.folderIncarnations)
                .ensureLegacyConfiguredFolders([folder.id]).first
        )
        let command = CoreCommand(
            kind: .delete,
            folderID: folder.id,
            itemID: "deleted-item",
            folderIncarnationDigest: context.folderIncarnationDigest,
            trigger: .fileProvider
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(
            CoreCommandResult(
                commandID: command.id,
                status: .failed,
                errorCode: "sync_incomplete",
                mutationFailurePhase: .postcommit,
                mutationFailureAmbiguous: true
            )
        )
        try queue.acknowledge(command)
        let authoritative = CoreSnapshot(
            generation: 9,
            configurationRevision: currentRevision,
            folders: [folder],
            tombstones: [IndexTombstone(itemID: "deleted-item", generation: 9)]
        )
        let client = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [folder]),
            networkSnapshot: authoritative
        )

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .completed(processedCommands: 0, snapshotGeneration: 9))
        let executed = await client.executedCommands()
        let rescan = try XCTUnwrap(executed.first(where: { $0.kind == .rescan }))
        XCTAssertEqual(rescan.folderID, folder.id)
        XCTAssertEqual(rescan.folderIncarnationDigest, context.folderIncarnationDigest)
        XCTAssertNil(rescan.commandConfigurationRevision)
        let reconciledCommandIDs = await client.reconciledCommandIDs()
        XCTAssertEqual(reconciledCommandIDs, [command.id])
        XCTAssertTrue(try queue.completed().isEmpty)
        XCTAssertEqual(try queue.result(for: command.id)?.status, .succeeded)
    }

    func testReaddedFolderRejectsOldMutationCleanupAndDefersItFairly() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folder = try folderRecord(id: "readded-folder", paths: paths)
        let store = FolderIncarnationStore(url: paths.folderIncarnations)
        let oldContext = try XCTUnwrap(try store.ensureLegacyConfiguredFolders([folder.id]).first)
        let command = CoreCommand(
            kind: .delete,
            folderID: folder.id,
            itemID: "old-item",
            folderIncarnationDigest: oldContext.folderIncarnationDigest,
            trigger: .fileProvider
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        try queue.record(
            CoreCommandResult(
                commandID: command.id,
                status: .failed,
                errorCode: "sync_incomplete",
                mutationFailurePhase: .postcommit,
                mutationFailureAmbiguous: true
            )
        )
        try queue.acknowledge(command)
        _ = try store.removeAfterSuccessfulDeletion(
            folderID: folder.id,
            expectedFolderIncarnationDigest: oldContext.folderIncarnationDigest
        )
        let newContext = try store.recordSuccessfulCreation(
            folderID: folder.id,
            commandID: UUID()
        )
        XCTAssertNotEqual(newContext.folderIncarnationDigest, oldContext.folderIncarnationDigest)
        let client = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [folder]),
            networkSnapshot: snapshot(folders: [folder])
        )

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "folder_incarnation_mismatch"))
        let openedPlans = await client.openedPlans()
        let executedCommands = await client.executedCommands()
        XCTAssertTrue(openedPlans.isEmpty)
        XCTAssertTrue(executedCommands.isEmpty)
        let completedNames = try FileManager.default.contentsOfDirectory(
            atPath: paths.commandQueue.appendingPathComponent("completed").path
        )
        XCTAssertEqual(completedNames.count, 1)
        XCTAssertTrue(completedNames[0].hasPrefix("~retry-00000000000000000001-"))

        let firstRescan = try XCTUnwrap(
            MutationReconciler(paths: paths).rescanCommand(for: command, ownerEpoch: 7)
        )
        var differentIncarnationCommand = command
        differentIncarnationCommand.folderIncarnationDigest = newContext.folderIncarnationDigest
        let secondRescan = try XCTUnwrap(
            MutationReconciler(paths: paths).rescanCommand(
                for: differentIncarnationCommand,
                ownerEpoch: 7
            )
        )
        XCTAssertEqual(firstRescan.id, secondRescan.id)
        XCTAssertNotEqual(firstRescan, secondRescan)
        let semanticQueue = CoreCommandQueue(
            root: root.appendingPathComponent("SemanticQueue", isDirectory: true)
        )
        try semanticQueue.enqueue(firstRescan)
        XCTAssertThrowsError(try semanticQueue.enqueue(secondRescan)) { error in
            XCTAssertEqual(error as? CoreCommandQueueError, .identifierCollision(firstRescan.id))
        }
    }

    func testQueuedPolicyUsesDurableTriggerAndRejectsAmbientOverride() async throws {
        let backgroundRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: backgroundRoot) }
        let backgroundPaths = SharedContainerPaths(root: backgroundRoot)
        let backgroundFolder = try folderRecord(id: "background-folder", paths: backgroundPaths)
        let backgroundContext = try XCTUnwrap(
            try FolderIncarnationStore(url: backgroundPaths.folderIncarnations)
                .ensureLegacyConfiguredFolders([backgroundFolder.id]).first
        )
        var backgroundPolicy = SyncPolicy()
        backgroundPolicy.cellularAccess = .allowed
        backgroundPolicy.automaticallyAllowedNetworks = [.wifi]
        backgroundPolicy.allowTemporaryUserOverride = true
        try SyncPolicyStore(url: backgroundPaths.policy).save(backgroundPolicy)
        let backgroundCommand = CoreCommand(
            kind: .sync,
            folderID: backgroundFolder.id,
            folderIncarnationDigest: backgroundContext.folderIncarnationDigest,
            trigger: .backgroundProcessing
        )
        let backgroundQueue = CoreCommandQueue(root: backgroundPaths.commandQueue)
        try backgroundQueue.enqueue(backgroundCommand)
        let backgroundClient = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [backgroundFolder]),
            networkSnapshot: snapshot(folders: [backgroundFolder])
        )
        var otherNetwork = SyncEnvironmentSnapshot.permissiveForTesting
        otherNetwork.network = NetworkState(kind: .other)

        let backgroundOutcome = await CoreRuntime(clientFactory: { backgroundClient })
            .processPending(
                trigger: .user,
                paths: backgroundPaths,
                environment: otherNetwork,
                requestedTemporaryOverride: true
            )

        guard case .policyDenied(let backgroundReasons) = backgroundOutcome else {
            return XCTFail("Expected durable background trigger denial, got \(backgroundOutcome)")
        }
        XCTAssertTrue(backgroundReasons.contains(.networkTypeDenied))
        let backgroundPlans = await backgroundClient.openedPlans()
        XCTAssertTrue(backgroundPlans.isEmpty)
        XCTAssertEqual(try backgroundQueue.pending().map(\.id), [backgroundCommand.id])

        let overrideRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: overrideRoot) }
        let overridePaths = SharedContainerPaths(root: overrideRoot)
        let overrideFolder = try folderRecord(id: "override-folder", paths: overridePaths)
        let overrideContext = try XCTUnwrap(
            try FolderIncarnationStore(url: overridePaths.folderIncarnations)
                .ensureLegacyConfiguredFolders([overrideFolder.id]).first
        )
        var overridePolicy = SyncPolicy()
        overridePolicy.cellularAccess = .denied
        overridePolicy.allowTemporaryUserOverride = true
        try SyncPolicyStore(url: overridePaths.policy).save(overridePolicy)
        let overrideCommand = CoreCommand(
            kind: .sync,
            folderID: overrideFolder.id,
            folderIncarnationDigest: overrideContext.folderIncarnationDigest,
            trigger: .user
        )
        let overrideQueue = CoreCommandQueue(root: overridePaths.commandQueue)
        try overrideQueue.enqueue(overrideCommand)
        let overrideClient = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [overrideFolder]),
            networkSnapshot: snapshot(folders: [overrideFolder])
        )
        var cellular = SyncEnvironmentSnapshot.permissiveForTesting
        cellular.network = NetworkState(kind: .cellular)

        let overrideOutcome = await CoreRuntime(clientFactory: { overrideClient }).processPending(
            trigger: .user,
            paths: overridePaths,
            environment: cellular,
            requestedTemporaryOverride: true
        )

        guard case .policyDenied(let overrideReasons) = overrideOutcome else {
            return XCTFail("Expected ambient override denial, got \(overrideOutcome)")
        }
        XCTAssertTrue(overrideReasons.contains(.networkTypeDenied))
        let overridePlans = await overrideClient.openedPlans()
        XCTAssertTrue(overridePlans.isEmpty)
        XCTAssertEqual(try overrideQueue.pending().map(\.id), [overrideCommand.id])
    }

    func testDurableTemporaryProfileOverridesPolicyAndCapsNativeSession() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folder = try folderRecord(id: "profile-runtime", paths: paths)
        let context = try XCTUnwrap(
            try FolderIncarnationStore(url: paths.folderIncarnations)
                .ensureLegacyConfiguredFolders([folder.id]).first
        )
        var policy = SyncPolicy()
        policy.cellularAccess = .denied
        policy.allowTemporaryUserOverride = true
        try SyncPolicyStore(url: paths.policy).save(policy)
        let createdAt = Date()
        let profile = TemporarySyncPolicyProfile(
            name: "Bounded Cellular",
            maximumNetworkBytes: 64,
            validitySeconds: 600
        )
        let command = CoreCommand(
            kind: .sync,
            folderID: folder.id,
            folderIncarnationDigest: context.folderIncarnationDigest,
            taskPolicyBinding: try CoreTaskPolicyBinding(
                profile: profile,
                commandCreatedAt: createdAt,
                trigger: .user
            ),
            trigger: .user,
            createdAt: createdAt
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [folder]),
            networkSnapshot: snapshot(folders: [folder])
        )
        var cellular = SyncEnvironmentSnapshot.permissiveForTesting
        cellular.network = NetworkState(kind: .cellular)
        let cellularEnvironment = cellular

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .user,
            paths: paths,
            environment: cellularEnvironment,
            currentEnvironment: { cellularEnvironment }
        )

        XCTAssertEqual(outcome, .completed(processedCommands: 1, snapshotGeneration: 2))
        let openedPlans = await client.openedPlans()
        XCTAssertEqual(openedPlans.count, 1)
        XCTAssertEqual(openedPlans.first?.maximumNetworkBytes.byteCount, 64)
        XCTAssertEqual(try queue.result(for: command.id)?.status, .succeeded)
    }

    func testExpiredTemporaryProfileIsRetiredBeforeOpeningCore() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folder = try folderRecord(id: "expired-profile", paths: paths)
        let context = try XCTUnwrap(
            try FolderIncarnationStore(url: paths.folderIncarnations)
                .ensureLegacyConfiguredFolders([folder.id]).first
        )
        let createdAt = Date().addingTimeInterval(-601)
        let command = CoreCommand(
            kind: .sync,
            folderID: folder.id,
            folderIncarnationDigest: context.folderIncarnationDigest,
            taskPolicyBinding: try CoreTaskPolicyBinding(
                profile: .init(name: "Expired", validitySeconds: 600),
                commandCreatedAt: createdAt,
                trigger: .user
            ),
            trigger: .user,
            createdAt: createdAt
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [folder]),
            networkSnapshot: snapshot(folders: [folder])
        )

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting
        )

        XCTAssertEqual(outcome, .failed(code: "temporary_policy_profile_expired"))
        let openedModes = await client.openedModes()
        XCTAssertTrue(openedModes.isEmpty)
        XCTAssertEqual(try queue.result(for: command.id)?.errorCode, "temporary_policy_profile_expired")
        XCTAssertEqual(try queue.result(for: command.id)?.status, .blocked)
        XCTAssertTrue(try queue.pending().isEmpty)
    }

    func testSchedulerSkipsDeniedFolderAndRunsEligibleSibling() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let deniedFolder = try folderRecord(id: "scheduler-denied", paths: paths)
        let eligibleFolder = try folderRecord(id: "scheduler-eligible", paths: paths)
        let contexts = try FolderIncarnationStore(url: paths.folderIncarnations)
            .ensureLegacyConfiguredFolders([deniedFolder.id, eligibleFolder.id])
        let deniedContext = try XCTUnwrap(
            contexts.first(where: { $0.folderID == deniedFolder.id })
        )
        let eligibleContext = try XCTUnwrap(
            contexts.first(where: { $0.folderID == eligibleFolder.id })
        )
        let policyStore = SyncPolicyStore(url: paths.policy)
        var document = try policyStore.loadDocument()
        document.folderOverrides = [
            FolderSyncPolicyOverride(
                folderID: deniedFolder.id,
                folderIncarnationDigest: deniedContext.folderIncarnationDigest,
                queuePriority: .high,
                policy: SyncPolicyOverride(allowBackgroundDownload: false)
            )
        ]
        try policyStore.saveDocument(document)
        let denied = CoreCommand(
            kind: .download,
            folderID: deniedFolder.id,
            folderIncarnationDigest: deniedContext.folderIncarnationDigest,
            trigger: .backgroundProcessing,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let eligible = CoreCommand(
            kind: .download,
            folderID: eligibleFolder.id,
            folderIncarnationDigest: eligibleContext.folderIncarnationDigest,
            trigger: .backgroundProcessing,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(denied)
        try queue.enqueue(eligible)
        let client = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [deniedFolder, eligibleFolder]),
            networkSnapshot: snapshot(folders: [deniedFolder, eligibleFolder])
        )

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .backgroundProcessing,
            paths: paths,
            environment: .permissiveForTesting
        )

        guard case .completed(let processed, _) = outcome else {
            return XCTFail("Expected eligible sibling completion, got \(outcome)")
        }
        XCTAssertEqual(processed, 1)
        let openedFolderIDs = await client.openedPlans().map(\.folderID)
        XCTAssertEqual(openedFolderIDs, [eligibleFolder.id])
        XCTAssertEqual(try queue.pending().map(\.id), [denied.id])
        XCTAssertNil(try queue.result(for: denied.id))
        XCTAssertEqual(try queue.result(for: eligible.id)?.status, .succeeded)
    }

    func testFiniteCapCheapChunksReplayButExpensiveExhaustionIsTerminal() async throws {
        let cheapRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: cheapRoot) }
        let cheapPaths = SharedContainerPaths(root: cheapRoot)
        let cheapFolder = try folderRecord(id: "cheap-folder", paths: cheapPaths)
        let cheapContext = try XCTUnwrap(
            try FolderIncarnationStore(url: cheapPaths.folderIncarnations)
                .ensureLegacyConfiguredFolders([cheapFolder.id]).first
        )
        try saveFinitePolicy(paths: cheapPaths, bytes: 64)
        let cheapCommand = CoreCommand(
            kind: .sync,
            folderID: cheapFolder.id,
            folderIncarnationDigest: cheapContext.folderIncarnationDigest,
            trigger: .user
        )
        let cheapQueue = CoreCommandQueue(root: cheapPaths.commandQueue)
        try cheapQueue.enqueue(cheapCommand)
        let cheapClient = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [cheapFolder]),
            networkSnapshot: snapshot(folders: [cheapFolder]),
            networkExecutionFailureCodes: ["network_byte_limit_reached", nil],
            totalsBehaviors: [.exhaustedLimit, .zero]
        )
        let cheapRuntime = CoreRuntime(clientFactory: { cheapClient })

        let firstCheapOutcome = await cheapRuntime.processPending(
            trigger: .user,
            paths: cheapPaths,
            environment: .permissiveForTesting
        )
        XCTAssertEqual(firstCheapOutcome, .failed(code: "network_byte_limit_reached"))
        XCTAssertEqual(try cheapQueue.result(for: cheapCommand.id)?.status, .retryable)
        XCTAssertEqual(try cheapQueue.pending().map(\.id), [cheapCommand.id])
        XCTAssertTrue(try cheapQueue.retryNow(cheapCommand.id))

        let secondCheapOutcome = await cheapRuntime.processPending(
            trigger: .backgroundProcessing,
            paths: cheapPaths,
            environment: .permissiveForTesting
        )
        guard case .completed(let processed, _) = secondCheapOutcome else {
            return XCTFail("Expected cheap replay completion, got \(secondCheapOutcome)")
        }
        XCTAssertEqual(processed, 1)
        let cheapExecutedIDs = await cheapClient.executedCommands().map(\.id)
        XCTAssertEqual(cheapExecutedIDs, [cheapCommand.id, cheapCommand.id])
        let cheapLedger = try accountingStore(paths: cheapPaths).snapshot()
        XCTAssertEqual(cheapLedger.settledReceipts.count, 2)
        XCTAssertTrue(cheapLedger.settledReceipts.allSatisfy { $0.kind == .exact })
        XCTAssertTrue(cheapLedger.settledReceipts.allSatisfy { $0.chargedBytes == 0 })

        let expensiveRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: expensiveRoot) }
        let expensivePaths = SharedContainerPaths(root: expensiveRoot)
        let expensiveFolder = try folderRecord(id: "expensive-folder", paths: expensivePaths)
        let expensiveContext = try XCTUnwrap(
            try FolderIncarnationStore(url: expensivePaths.folderIncarnations)
                .ensureLegacyConfiguredFolders([expensiveFolder.id]).first
        )
        try saveFinitePolicy(paths: expensivePaths, bytes: 64)
        let expensiveCommand = CoreCommand(
            kind: .sync,
            folderID: expensiveFolder.id,
            folderIncarnationDigest: expensiveContext.folderIncarnationDigest,
            trigger: .user
        )
        let expensiveQueue = CoreCommandQueue(root: expensivePaths.commandQueue)
        try expensiveQueue.enqueue(expensiveCommand)
        let expensiveClient = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [expensiveFolder]),
            networkSnapshot: snapshot(folders: [expensiveFolder]),
            networkExecutionFailureCodes: ["network_byte_limit_reached"],
            totalsBehaviors: [.exhaustedLimit]
        )
        var expensiveEnvironment = SyncEnvironmentSnapshot.permissiveForTesting
        expensiveEnvironment.network.isExpensive = true
        let currentExpensiveEnvironment = expensiveEnvironment

        let expensiveOutcome = await CoreRuntime(clientFactory: { expensiveClient })
            .processPending(
                trigger: .user,
                paths: expensivePaths,
                environment: expensiveEnvironment,
                currentEnvironment: { currentExpensiveEnvironment }
            )

        XCTAssertEqual(expensiveOutcome, .failed(code: "network_byte_limit_reached"))
        XCTAssertEqual(try expensiveQueue.result(for: expensiveCommand.id)?.status, .blocked)
        XCTAssertTrue(try expensiveQueue.pending().isEmpty)
        let expensiveLedger = try accountingStore(paths: expensivePaths).snapshot()
        XCTAssertEqual(expensiveLedger.settledReceipts.map(\.kind), [.exact])
        XCTAssertEqual(expensiveLedger.settledReceipts.map(\.chargedBytes), [64])
    }

    func testFileProviderMutationUsesZeroNetworkPlanWithoutAccountingReservation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folder = try folderRecord(id: "mutation-cap-folder", paths: paths)
        let context = try XCTUnwrap(
            try FolderIncarnationStore(url: paths.folderIncarnations)
                .ensureLegacyConfiguredFolders([folder.id]).first
        )
        let command = CoreCommand(
            kind: .create,
            folderID: folder.id,
            arguments: [
                "parentIdentifier": providerFolderIdentifier(folder.id),
                "filename": "new-directory",
                "isDirectory": "true",
            ],
            folderIncarnationDigest: context.folderIncarnationDigest,
            trigger: .fileProvider
        )
        let propagation = CoreCommand(
            kind: .upload,
            folderID: folder.id,
            folderIncarnationDigest: context.folderIncarnationDigest,
            trigger: .backgroundProcessing,
            createdAt: command.createdAt
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueueAtomically([command, propagation], batchID: UUID())
        let client = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [folder]),
            networkSnapshot: snapshot(folders: [folder])
        )

        var configuredEnvironment = SyncEnvironmentSnapshot.permissiveForTesting
        configuredEnvironment.network = .init(kind: .unavailable, isConstrained: true)
        let offlineEnvironment = configuredEnvironment
        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .fileProvider,
            paths: paths,
            environment: offlineEnvironment,
            currentEnvironment: { offlineEnvironment }
        )

        XCTAssertEqual(outcome, .completed(processedCommands: 1, snapshotGeneration: 2))
        let result = try XCTUnwrap(try queue.result(for: command.id))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(try queue.pending().map(\.id), [propagation.id])
        XCTAssertEqual(try queue.completed().map(\.id), [command.id])
        let plans = await client.openedPlans()
        XCTAssertEqual(plans.map(\.operation), [.localMutation])
        XCTAssertEqual(plans.map(\.maximumNetworkBytes.byteCount), [0])
        let ledger = try accountingStore(paths: paths).snapshot()
        XCTAssertTrue(ledger.activeReservations.isEmpty)
        XCTAssertTrue(ledger.settledReceipts.isEmpty)

        let deferredOutcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .backgroundProcessing,
            paths: paths,
            environment: offlineEnvironment,
            currentEnvironment: { offlineEnvironment }
        )
        guard case .policyDenied(let reasons) = deferredOutcome else {
            return XCTFail("Expected deferred upload policy denial, got \(deferredOutcome)")
        }
        XCTAssertTrue(reasons.contains(.networkUnavailable))
        XCTAssertEqual(try queue.pending().map(\.id), [propagation.id])
        let plansAfterDeferral = await client.openedPlans()
        XCTAssertEqual(plansAfterDeferral.map(\.operation), [.localMutation])
    }

    func testFailedDrainUsesConservativeAccountingAndNeverReadsUnclosedTotals() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folder = try folderRecord(id: "drain-folder", paths: paths)
        let context = try XCTUnwrap(
            try FolderIncarnationStore(url: paths.folderIncarnations)
                .ensureLegacyConfiguredFolders([folder.id]).first
        )
        try saveFinitePolicy(paths: paths, bytes: 64)
        let command = CoreCommand(
            kind: .sync,
            folderID: folder.id,
            folderIncarnationDigest: context.folderIncarnationDigest,
            trigger: .user
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [folder]),
            networkSnapshot: snapshot(folders: [folder]),
            totalsBehaviors: [.exhaustedLimit],
            networkCloseFailures: 2
        )
        var expensive = SyncEnvironmentSnapshot.permissiveForTesting
        expensive.network.isExpensive = true
        let currentExpensive = expensive

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .user,
            paths: paths,
            environment: expensive,
            currentEnvironment: { currentExpensive }
        )

        XCTAssertEqual(outcome, .failed(code: "coreStopFailed"))
        let totalsReadCount = await client.networkTotalsReadCount()
        let closeAttemptCount = await client.networkCloseAttemptCount()
        XCTAssertEqual(totalsReadCount, 0)
        XCTAssertEqual(closeAttemptCount, 2)
        let ledger = try accountingStore(paths: paths).snapshot()
        XCTAssertEqual(ledger.settledReceipts.map(\.kind), [.conservative])
        XCTAssertEqual(ledger.settledReceipts.map(\.chargedBytes), [64])
        XCTAssertEqual(try queue.pending().map(\.id), [command.id])
    }

    func testSuccessfulDrainValidatesFinalTotalsBeforeExactSettlement() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let folder = try folderRecord(id: "recovered-drain-folder", paths: paths)
        let context = try XCTUnwrap(
            try FolderIncarnationStore(url: paths.folderIncarnations)
                .ensureLegacyConfiguredFolders([folder.id]).first
        )
        try saveFinitePolicy(paths: paths, bytes: 64)
        let command = CoreCommand(
            kind: .sync,
            folderID: folder.id,
            folderIncarnationDigest: context.folderIncarnationDigest,
            trigger: .user
        )
        let queue = CoreCommandQueue(root: paths.commandQueue)
        try queue.enqueue(command)
        let client = ExplicitSessionTestClient(
            configurationSnapshot: snapshot(folders: [folder]),
            networkSnapshot: snapshot(folders: [folder]),
            totalsBehaviors: [.exhaustedLimit],
            networkCloseFailures: 1
        )
        var expensive = SyncEnvironmentSnapshot.permissiveForTesting
        expensive.network.isExpensive = true
        let currentExpensive = expensive

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .user,
            paths: paths,
            environment: expensive,
            currentEnvironment: { currentExpensive }
        )

        XCTAssertEqual(outcome, .failed(code: "close_failed"))
        let totalsReadCount = await client.networkTotalsReadCount()
        let closeAttemptCount = await client.networkCloseAttemptCount()
        XCTAssertEqual(totalsReadCount, 1)
        XCTAssertEqual(closeAttemptCount, 2)
        let ledger = try accountingStore(paths: paths).snapshot()
        XCTAssertEqual(ledger.settledReceipts.map(\.kind), [.exact])
        XCTAssertEqual(ledger.settledReceipts.map(\.chargedBytes), [64])
        XCTAssertEqual(try queue.pending().map(\.id), [command.id])
    }

    private func refreshedSiblingSnapshot(
        previousRevision: String,
        mutateIncarnationDuringRefresh: Bool
    ) async throws -> CoreSnapshot {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let target = try folderRecord(id: "target", paths: paths)
        var sibling = try folderRecord(id: "sibling", paths: paths)
        let targetDeviceID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "C", count: 56)))
        let siblingDeviceID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "D", count: 56)))
        var targetWithDevice = target
        targetWithDevice.deviceIDs = [targetDeviceID]
        sibling.deviceIDs = [siblingDeviceID]
        let siblingID = sibling.id
        sibling.pendingUploadBytes = 91
        let store = FolderIncarnationStore(url: paths.folderIncarnations)
        let contexts = try store.ensureLegacyConfiguredFolders([targetWithDevice.id, sibling.id])
        let targetContext = try XCTUnwrap(contexts.first(where: { $0.folderID == targetWithDevice.id }))
        let siblingContext = try XCTUnwrap(contexts.first(where: { $0.folderID == sibling.id }))
        let previousItem = IndexedItem(
            id: "sibling-item",
            folderID: sibling.id,
            relativePath: "kept.txt",
            isDirectory: false,
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data(repeating: 1, count: 32),
            metadataVersion: Data(repeating: 2, count: 32),
            availability: .local,
            generation: 1
        )
        try SharedSnapshotStore(snapshotURL: paths.snapshot).write(
            CoreSnapshot(
                generation: 10,
                configurationRevision: previousRevision,
                devices: [
                    DeviceRecord(
                        id: targetDeviceID,
                        name: "target-device",
                        state: .connected,
                        uploadBytesPerSecond: 900,
                        downloadBytesPerSecond: 800,
                        pendingBytes: 70
                    ),
                    DeviceRecord(
                        id: siblingDeviceID,
                        name: "sibling-device",
                        state: .connected,
                        uploadBytesPerSecond: 700,
                        downloadBytesPerSecond: 600,
                        pendingBytes: 50
                    ),
                ],
                folders: [targetWithDevice, sibling],
                items: [previousItem]
            )
        )
        sibling.pendingUploadBytes = 0
        let configuredDevices = [
            DeviceRecord(id: targetDeviceID, name: "target-device"),
            DeviceRecord(id: siblingDeviceID, name: "sibling-device"),
        ]
        let canonical = snapshot(devices: configuredDevices, folders: [targetWithDevice, sibling])
        var network = canonical
        network.devices[0].state = .connected
        network.devices[0].uploadBytesPerSecond = 50
        network.devices[0].downloadBytesPerSecond = 30
        network.devices[0].pendingBytes = 40
        let hook: (@Sendable () throws -> Void)?
        if mutateIncarnationDuringRefresh {
            let replacementCommandID = UUID()
            hook = {
                _ = try store.removeAfterSuccessfulDeletion(
                    folderID: siblingID,
                    expectedFolderIncarnationDigest: siblingContext.folderIncarnationDigest
                )
                _ = try store.recordSuccessfulCreation(
                    folderID: siblingID,
                    commandID: replacementCommandID
                )
            }
        } else {
            hook = nil
        }
        let command = CoreCommand(
            kind: .sync,
            folderID: targetWithDevice.id,
            folderIncarnationDigest: targetContext.folderIncarnationDigest,
            trigger: .user
        )
        try CoreCommandQueue(root: paths.commandQueue).enqueue(command)
        let client = ExplicitSessionTestClient(
            configurationSnapshot: canonical,
            networkSnapshot: network,
            firstConfigurationSnapshotHook: hook
        )

        let outcome = await CoreRuntime(clientFactory: { client }).processPending(
            trigger: .foreground,
            paths: paths,
            environment: .permissiveForTesting
        )
        guard case .completed = outcome else {
            throw ExplicitSessionTestFailure.unexpectedOutcome
        }
        return try XCTUnwrap(try SharedSnapshotStore(snapshotURL: paths.snapshot).read())
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "core-runtime-explicit-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func folderRecord(id: String, paths: SharedContainerPaths) throws -> FolderRecord {
        let folderID = try XCTUnwrap(FolderID(rawValue: id))
        let folderURL = try paths.createManagedFolder(for: folderID)
        return FolderRecord(id: folderID, label: id, localPath: folderURL.path)
    }

    private func snapshot(
        devices: [DeviceRecord] = [],
        folders: [FolderRecord] = []
    ) -> CoreSnapshot {
        CoreSnapshot(
            generation: 1,
            configurationRevision: currentRevision,
            devices: devices,
            folders: folders
        )
    }

    private func makeCompleted(_ command: CoreCommand, in queue: CoreCommandQueue) throws {
        try queue.enqueue(command)
        try queue.record(
            CoreCommandResult(commandID: command.id, status: .succeeded, snapshotGeneration: 1)
        )
        try queue.acknowledge(command)
    }

    private func saveFinitePolicy(paths: SharedContainerPaths, bytes: Int64) throws {
        var policy = SyncPolicy()
        policy.allowExpensive = true
        policy.maxExpensiveRunBytes = bytes
        policy.dailyExpensiveBytes = nil
        try SyncPolicyStore(url: paths.policy).save(policy)
    }

    private func accountingStore(paths: SharedContainerPaths) throws -> TransferAccountingStore {
        let document = try SyncPolicyStore(url: paths.policy).loadDocument()
        return TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        )
    }

    private func providerFolderIdentifier(_ folderID: FolderID) -> String {
        let digest = SHA256.hash(data: Data(folderID.rawValue.utf8))
        return "folder-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

private enum ExplicitSessionTestFailure: Error {
    case unexpectedOutcome
}

private enum ExplicitSessionTestTotalsBehavior: Sendable {
    case zero
    case exhaustedLimit
    case unavailable
}

private actor ExplicitSessionTestClient: CoreClient {
    private enum ActiveSession {
        case configuration(CoreExplicitSessionBinding)
        case network(CoreExplicitSessionBinding, CoreNetworkSessionPlan, Int)

        var binding: CoreExplicitSessionBinding {
            switch self {
            case .configuration(let binding): binding
            case .network(let binding, _, _): binding
            }
        }

        var mode: CoreExplicitSessionMode { binding.mode }
    }

    private let deviceID = DeviceID(rawValue: String(repeating: "A", count: 56))!
    private let configurationSnapshot: CoreSnapshot
    private let networkSnapshot: CoreSnapshot
    private let firstConfigurationSnapshotHook: (@Sendable () throws -> Void)?
    private let networkExecutionFailureCodes: [String?]
    private let totalsBehaviors: [ExplicitSessionTestTotalsBehavior]
    private let firstNetworkMutationFailure: CoreMutationFailure?
    private var remainingNetworkCloseFailures: Int
    private var activeSession: ActiveSession?
    private var lastClosedNetwork: (plan: CoreNetworkSessionPlan, ordinal: Int)?
    private var configurationSnapshotCount = 0
    private var networkExecutionCount = 0
    private var networkCloseAttempts = 0
    private var totalsReads = 0
    private var recordedEvents: [String] = []
    private var plans: [CoreNetworkSessionPlan] = []
    private var commands: [CoreCommand] = []
    private var acknowledgedModes: [CoreExplicitSessionMode] = []
    private var reconciledIDs: [UUID] = []
    private var configurationReconciledIDs: [UUID] = []

    init(
        configurationSnapshot: CoreSnapshot,
        networkSnapshot: CoreSnapshot,
        firstConfigurationSnapshotHook: (@Sendable () throws -> Void)? = nil,
        networkExecutionFailureCodes: [String?] = [],
        totalsBehaviors: [ExplicitSessionTestTotalsBehavior] = [],
        firstNetworkMutationFailure: CoreMutationFailure? = nil,
        networkCloseFailures: Int = 0
    ) {
        self.configurationSnapshot = configurationSnapshot
        self.networkSnapshot = networkSnapshot
        self.firstConfigurationSnapshotHook = firstConfigurationSnapshotHook
        self.networkExecutionFailureCodes = networkExecutionFailureCodes
        self.totalsBehaviors = totalsBehaviors
        self.firstNetworkMutationFailure = firstNetworkMutationFailure
        remainingNetworkCloseFailures = networkCloseFailures
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        throw CoreClientError.invalidResponse("legacy_start_used")
    }

    func openConfigurationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID
    ) async throws -> CoreExplicitSessionReceipt {
        guard activeSession == nil else { throw CoreClientError.invalidResponse("session_overlap") }
        let binding = CoreExplicitSessionBinding.configuration(sessionID: sessionID)
        activeSession = .configuration(binding)
        recordedEvents.append("open:configuration")
        return try receipt(binding: binding, generation: 1)
    }

    func openNetworkSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID,
        plan: CoreNetworkSessionPlan
    ) async throws -> CoreExplicitSessionReceipt {
        guard activeSession == nil else { throw CoreClientError.invalidResponse("session_overlap") }
        let binding = CoreExplicitSessionBinding.network(sessionID: sessionID, plan: plan)
        let ordinal = plans.count
        plans.append(plan)
        activeSession = .network(binding, plan, ordinal)
        recordedEvents.append("open:network:\(plan.folderID.rawValue)")
        return try receipt(binding: binding, generation: 1)
    }

    func closeExplicitSession() async throws -> CoreExplicitSessionReceipt {
        guard let activeSession else { throw CoreClientError.notRunning }
        switch activeSession {
        case .configuration(let binding):
            recordedEvents.append("close:configuration")
            self.activeSession = nil
            return try receipt(binding: binding, generation: 2)
        case .network(let binding, let plan, let ordinal):
            networkCloseAttempts += 1
            if remainingNetworkCloseFailures > 0 {
                remainingNetworkCloseFailures -= 1
                recordedEvents.append("close:network:failed")
                throw CoreClientError.coreRejected("close_failed")
            }
            recordedEvents.append("close:network")
            lastClosedNetwork = (plan, ordinal)
            self.activeSession = nil
            return try receipt(binding: binding, generation: 2)
        }
    }

    func stop() async throws {
        throw CoreClientError.invalidResponse("legacy_stop_used")
    }

    func snapshot() async throws -> CoreSnapshot {
        guard let activeSession else { throw CoreClientError.notRunning }
        switch activeSession {
        case .configuration:
            configurationSnapshotCount += 1
            if configurationSnapshotCount == 1 {
                try firstConfigurationSnapshotHook?()
            }
            recordedEvents.append("snapshot:configuration")
            return configurationSnapshot
        case .network:
            recordedEvents.append("snapshot:network")
            return networkSnapshot
        }
    }

    func networkTransferTotals() async throws -> CoreNetworkTransferTotals? {
        guard activeSession == nil, let closed = lastClosedNetwork else {
            throw CoreClientError.invalidResponse("totals_before_close")
        }
        totalsReads += 1
        recordedEvents.append("totals")
        let behavior =
            closed.ordinal < totalsBehaviors.count
            ? totalsBehaviors[closed.ordinal] : .zero
        switch behavior {
        case .unavailable:
            return nil
        case .zero:
            return totals(plan: closed.plan, usedBytes: 0, exhausted: false)
        case .exhaustedLimit:
            guard let limit = closed.plan.maximumNetworkBytes.byteCount else {
                throw CoreClientError.invalidResponse("test_expected_finite_limit")
            }
            return totals(plan: closed.plan, usedBytes: limit, exhausted: true)
        }
    }

    func execute(_ command: CoreCommand) async throws {
        guard let activeSession else { throw CoreClientError.notRunning }
        commands.append(command)
        recordedEvents.append("execute:\(activeSession.mode.rawValue):\(command.kind.rawValue)")
        guard activeSession.mode == .network else { return }
        let ordinal = networkExecutionCount
        networkExecutionCount += 1
        if ordinal == 0, let firstNetworkMutationFailure {
            throw firstNetworkMutationFailure
        }
        if ordinal < networkExecutionFailureCodes.count,
            let code = networkExecutionFailureCodes[ordinal]
        {
            throw CoreClientError.coreRejected(code)
        }
    }

    func acknowledgeCommand(_ id: UUID) async throws {
        guard let mode = activeSession?.mode else { throw CoreClientError.notRunning }
        acknowledgedModes.append(mode)
        recordedEvents.append("ack:\(mode.rawValue)")
    }

    func acknowledgeReconciledCommand(
        _ command: CoreCommand,
        proof: CoreMutationReconciliationProof
    ) async throws {
        guard activeSession?.mode == .network,
            proof.snapshotGeneration > 0,
            proof.ownerEpoch > 0,
            proof.stateDigest.count == 32
        else {
            throw CoreClientError.invalidResponse("reconciliation_scope")
        }
        reconciledIDs.append(command.id)
        acknowledgedModes.append(.network)
        recordedEvents.append("ack-reconciled:network")
    }

    func acknowledgeReconciledConfigurationCommand(
        _ command: CoreCommand,
        proof: CoreConfigurationReconciliationProof
    ) async throws {
        guard activeSession?.mode == .configuration,
            proof.snapshotGeneration > 0,
            proof.ownerEpoch > 0,
            proof.stateDigest.count == 32
        else {
            throw CoreClientError.invalidResponse("configuration_reconciliation_scope")
        }
        configurationReconciledIDs.append(command.id)
        acknowledgedModes.append(.configuration)
        recordedEvents.append("ack-reconciled:configuration")
    }

    func events() -> [String] { recordedEvents }
    func openedPlans() -> [CoreNetworkSessionPlan] { plans }
    func executedCommands() -> [CoreCommand] { commands }
    func acknowledgementModes() -> [CoreExplicitSessionMode] { acknowledgedModes }
    func reconciledCommandIDs() -> [UUID] { reconciledIDs }
    func configurationReconciledCommandIDs() -> [UUID] { configurationReconciledIDs }
    func networkTotalsReadCount() -> Int { totalsReads }
    func networkCloseAttemptCount() -> Int { networkCloseAttempts }

    func openedModes() -> [CoreExplicitSessionMode] {
        recordedEvents.compactMap { event in
            if event == "open:configuration" { return .configuration }
            if event.hasPrefix("open:network:") { return .network }
            return nil
        }
    }

    private func receipt(
        binding: CoreExplicitSessionBinding,
        generation: UInt64
    ) throws -> CoreExplicitSessionReceipt {
        try CoreExplicitSessionReceipt(
            binding: binding,
            deviceID: deviceID,
            generation: generation,
            configurationRevision: configurationSnapshot.configurationRevision
                ?? String(repeating: "b", count: 64)
        )
    }

    private func totals(
        plan: CoreNetworkSessionPlan,
        usedBytes: Int64,
        exhausted: Bool
    ) -> CoreNetworkTransferTotals {
        if let limit = plan.maximumNetworkBytes.byteCount {
            return CoreNetworkTransferTotals(
                receivedBytes: usedBytes,
                sentBytes: 0,
                budgetLimited: true,
                budgetLimitBytes: limit,
                budgetUsedBytes: usedBytes,
                budgetExhausted: exhausted || limit == 0
            )
        }
        return CoreNetworkTransferTotals(
            receivedBytes: usedBytes,
            sentBytes: 0,
            budgetLimited: false,
            budgetLimitBytes: 0,
            budgetUsedBytes: usedBytes,
            budgetExhausted: false
        )
    }
}
