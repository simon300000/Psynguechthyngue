import Foundation
import XCTest

@testable import PsyCore

final class ScopedCoreCommandProducerTests: XCTestCase {
    private let revision = String(repeating: "a", count: 64)
    private let invocationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    func testConfigurationSafetyCommandBindsRevisionAndFolderIncarnation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "safety-folder"))
        let context = try fixture.installSnapshot(
            revision: revision,
            folderIDs: [folderID],
            registeredFolderIDs: [folderID]
        )[folderID]

        let command = try XCTUnwrap(
            ScopedCoreCommandProducer(paths: fixture.paths).prepareCommands(
                invocationID: invocationID,
                kind: .pause,
                folderID: folderID,
                trigger: .user
            ).only
        )

        XCTAssertTrue(command.kind.usesOfflineConfigurationSession)
        XCTAssertEqual(command.commandConfigurationRevision, revision)
        XCTAssertEqual(command.folderIncarnationDigest, context?.folderIncarnationDigest)
    }

    func testFolderActionRejectsAReplacedIncarnationBeforeEnqueue() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "detail-folder"))
        let context = try XCTUnwrap(
            try fixture.installSnapshot(
                revision: revision,
                folderIDs: [folderID],
                registeredFolderIDs: [folderID]
            )[folderID]
        )
        let staleDigest = String(repeating: context.folderIncarnationDigest.first == "f" ? "e" : "f", count: 64)

        XCTAssertThrowsError(
            try ScopedCoreCommandProducer(paths: fixture.paths).prepareCommands(
                invocationID: invocationID,
                kind: .sync,
                folderID: folderID,
                expectedFolderIncarnationDigest: staleDigest,
                trigger: .user
            )
        ) { error in
            XCTAssertEqual(
                error as? ScopedCoreCommandProducerError,
                .folderIncarnationMismatch(
                    expected: staleDigest,
                    actual: context.folderIncarnationDigest
                )
            )
        }
        XCTAssertEqual(try CoreCommandQueue(root: fixture.paths.commandQueue).pending(), [])

        let command = try XCTUnwrap(
            ScopedCoreCommandProducer(paths: fixture.paths).prepareCommands(
                invocationID: invocationID,
                kind: .sync,
                folderID: folderID,
                expectedFolderIncarnationDigest: context.folderIncarnationDigest,
                trigger: .user
            ).only
        )
        XCTAssertEqual(command.folderIncarnationDigest, context.folderIncarnationDigest)
    }

    func testSyncUsesUploadOnlyForRetentionModesAndFullNetworkForFullRetention() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "retention-sync"))
        let context = try XCTUnwrap(
            try fixture.installSnapshot(
                revision: revision,
                folderIDs: [folderID],
                registeredFolderIDs: [folderID]
            )[folderID]
        )
        let store = ContentRetentionStore(url: fixture.paths.contentRetention)
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)
        var generation: UInt64 = 0

        for mode in [
            FolderContentSelectionMode.manualSelection,
            .globRules,
            .regexRules,
            .indexOnly,
            .onDemand,
        ] {
            _ = try store.applyPlan(
                folderID: folderID,
                folderIncarnationDigest: context.folderIncarnationDigest,
                expectedGeneration: generation,
                plan: FolderSelectionPlan(mode: mode)
            )
            generation += 1
            XCTAssertEqual(
                try producer.prepareCommands(
                    kind: .sync,
                    folderID: folderID,
                    trigger: .user
                ).only?.kind,
                .upload,
                "\(mode) must exchange metadata and upload without broad pulling"
            )
        }

        for mode in [FolderContentSelectionMode.fullSync, .pinnedOffline] {
            _ = try store.applyPlan(
                folderID: folderID,
                folderIncarnationDigest: context.folderIncarnationDigest,
                expectedGeneration: generation,
                plan: FolderSelectionPlan(mode: mode)
            )
            generation += 1
            XCTAssertEqual(
                try producer.prepareCommands(
                    kind: .sync,
                    folderID: folderID,
                    trigger: .user
                ).only?.kind,
                .sync
            )
        }
    }

    func testFileProviderMutationsBindBothLocalFencesWithoutAddingAGoWireFence() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "file-provider-folder"))
        let context = try XCTUnwrap(
            try fixture.installSnapshot(
                revision: revision,
                folderIDs: [folderID],
                registeredFolderIDs: [folderID]
            )[folderID]
        )
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)
        let networkBinding = CoreExplicitSessionBinding.network(
            sessionID: UUID(),
            plan: try CoreNetworkSessionPlan(
                taskID: UUID(),
                folderID: folderID,
                expectedConfigurationRevision: revision,
                maximumNetworkBytes: .unlimited
            )
        )

        for (index, kind) in [
            CoreCommandKind.create,
            .modify,
            .move,
            .delete,
        ].enumerated() {
            let command = try XCTUnwrap(
                producer.prepareCommands(
                    invocationID: UUID(
                        uuidString: String(
                            format: "20000000-0000-4000-8000-%012d",
                            index + 1
                        )
                    )!,
                    kind: kind,
                    folderID: folderID,
                    itemID: kind == .create ? nil : "stable-item",
                    expectedFolderIncarnationDigest: context.folderIncarnationDigest,
                    expectedConfigurationRevision: revision,
                    trigger: .fileProvider
                ).only
            )

            XCTAssertTrue(command.requiresDurableConfigurationRevisionPrecondition)
            XCTAssertFalse(command.requiresGoConfigurationWireRevisionFence)
            XCTAssertEqual(command.commandConfigurationRevision, revision)
            XCTAssertEqual(
                command.folderIncarnationDigest,
                context.folderIncarnationDigest
            )
            XCTAssertNil(
                try CoreSessionBridgeContract.commandConfigurationRevision(
                    for: command,
                    binding: networkBinding
                )
            )
        }
    }

    func testFileProviderMutationsRejectEitherStaleFenceBeforeEnqueue() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "file-provider-stale"))
        let context = try XCTUnwrap(
            try fixture.installSnapshot(
                revision: revision,
                folderIDs: [folderID],
                registeredFolderIDs: [folderID]
            )[folderID]
        )
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)
        let staleRevision = String(repeating: "b", count: 64)
        let staleDigest = String(repeating: "c", count: 64)

        for kind in [
            CoreCommandKind.create,
            .modify,
            .move,
            .delete,
        ] {
            XCTAssertThrowsError(
                try producer.prepareCommands(
                    kind: kind,
                    folderID: folderID,
                    expectedFolderIncarnationDigest: context.folderIncarnationDigest,
                    expectedConfigurationRevision: staleRevision,
                    trigger: .fileProvider
                )
            ) { error in
                XCTAssertEqual(
                    error as? ScopedCoreCommandProducerError,
                    .configurationRevisionMismatch(
                        expected: staleRevision,
                        actual: revision
                    )
                )
            }
            XCTAssertThrowsError(
                try producer.prepareCommands(
                    kind: kind,
                    folderID: folderID,
                    expectedFolderIncarnationDigest: staleDigest,
                    expectedConfigurationRevision: revision,
                    trigger: .fileProvider
                )
            ) { error in
                XCTAssertEqual(
                    error as? ScopedCoreCommandProducerError,
                    .folderIncarnationMismatch(
                        expected: staleDigest,
                        actual: context.folderIncarnationDigest
                    )
                )
            }
        }

        XCTAssertEqual(try CoreCommandQueue(root: fixture.paths.commandQueue).pending(), [])
    }

    func testReplacementIncarnationWithOldSnapshotRejectsEveryOldMutationIntent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "file-provider-replacement"))
        let oldContext = try XCTUnwrap(
            try fixture.installSnapshot(
                revision: revision,
                folderIDs: [folderID],
                registeredFolderIDs: [folderID]
            )[folderID]
        )
        let store = FolderIncarnationStore(url: fixture.paths.folderIncarnations)
        _ = try store.removeAfterSuccessfulDeletion(
            folderID: folderID,
            expectedFolderIncarnationDigest: oldContext.folderIncarnationDigest
        )
        let replacement = try store.recordSuccessfulCreation(
            folderID: folderID,
            commandID: UUID()
        )
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)

        for kind in [
            CoreCommandKind.create,
            .modify,
            .move,
            .delete,
        ] {
            XCTAssertThrowsError(
                try producer.prepareCommands(
                    kind: kind,
                    folderID: folderID,
                    expectedFolderIncarnationDigest: oldContext.folderIncarnationDigest,
                    expectedConfigurationRevision: revision,
                    trigger: .fileProvider
                )
            ) { error in
                XCTAssertEqual(
                    error as? ScopedCoreCommandProducerError,
                    .folderIncarnationMismatch(
                        expected: oldContext.folderIncarnationDigest,
                        actual: replacement.folderIncarnationDigest
                    )
                )
            }
        }

        XCTAssertEqual(try CoreCommandQueue(root: fixture.paths.commandQueue).pending(), [])
    }

    func testConfigurationSafetyCommandFailsClosedWithoutRevision() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "missing-revision"))
        _ = try fixture.installSnapshot(
            revision: nil,
            folderIDs: [folderID],
            registeredFolderIDs: [folderID]
        )

        XCTAssertThrowsError(
            try ScopedCoreCommandProducer(paths: fixture.paths).prepareCommands(
                invocationID: invocationID,
                kind: .removeFolder,
                folderID: folderID,
                trigger: .user
            )
        ) { error in
            XCTAssertEqual(
                error as? ScopedCoreCommandProducerError,
                .configurationRevisionUnavailable
            )
        }
    }

    func testDeviceSafetyCommandRequiresRevisionButNotFolderIncarnation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.installSnapshot(
            revision: revision,
            folderIDs: [],
            registeredFolderIDs: []
        )

        for kind in [CoreCommandKind.pause, .resume] {
            let command = try XCTUnwrap(
                ScopedCoreCommandProducer(paths: fixture.paths).prepareCommands(
                    invocationID: invocationID,
                    kind: kind,
                    itemID: "DEVICE-ID",
                    trigger: .appIntent
                ).only
            )
            XCTAssertEqual(command.kind, kind)
            XCTAssertEqual(command.itemID, "DEVICE-ID")
            XCTAssertEqual(command.trigger, .appIntent)
            XCTAssertEqual(command.commandConfigurationRevision, revision)
            XCTAssertNil(command.folderID)
            XCTAssertNil(command.folderIncarnationDigest)
        }
    }

    func testPendingIgnoreConfigurationCommandsBindRevisionWithoutIncarnation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.installSnapshot(
            revision: revision,
            folderIDs: [],
            registeredFolderIDs: []
        )
        let pendingFolder = try XCTUnwrap(FolderID(rawValue: "pending-folder"))
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)

        for command in [
            try XCTUnwrap(
                producer.prepareCommands(
                    invocationID: UUID(),
                    kind: .ignorePendingDevice,
                    itemID: "PENDING-DEVICE",
                    trigger: .user
                ).only
            ),
            try XCTUnwrap(
                producer.prepareCommands(
                    invocationID: UUID(),
                    kind: .unignorePendingFolder,
                    folderID: pendingFolder,
                    trigger: .user
                ).only
            ),
        ] {
            XCTAssertEqual(command.commandConfigurationRevision, revision)
            XCTAssertNil(command.folderIncarnationDigest)
        }
    }

    func testGenericProducerRejectsPendingFolderAcceptAndIgnoreWithoutProofAPI() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.installSnapshot(
            revision: revision,
            folderIDs: [],
            registeredFolderIDs: []
        )
        let folderID = try XCTUnwrap(FolderID(rawValue: "pending-folder"))
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)

        for kind in [CoreCommandKind.acceptFolder, .ignorePendingFolder] {
            XCTAssertThrowsError(
                try producer.prepareCommands(
                    kind: kind,
                    folderID: folderID,
                    arguments: [:],
                    trigger: .user
                )
            ) { error in
                XCTAssertEqual(
                    error as? ScopedCoreCommandProducerError,
                    .invalidProofBackedPendingFolderCommand
                )
            }
        }
        XCTAssertEqual(try CoreCommandQueue(root: fixture.paths.commandQueue).pending(), [])
    }

    func testGlobalSyncExpansionIsSortedStableAndExactlyBound() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let alpha = try XCTUnwrap(FolderID(rawValue: "alpha"))
        let middle = try XCTUnwrap(FolderID(rawValue: "middle"))
        let zulu = try XCTUnwrap(FolderID(rawValue: "zulu"))
        let contexts = try fixture.installSnapshot(
            revision: revision,
            folderIDs: [zulu, alpha, middle],
            registeredFolderIDs: [middle, zulu, alpha]
        )
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)

        let first = try producer.prepareCommands(
            invocationID: invocationID,
            kind: .sync,
            trigger: .appIntent,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let replay = try producer.prepareCommands(
            invocationID: invocationID,
            kind: .sync,
            trigger: .appIntent,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.map(\.folderID), [alpha, middle, zulu])
        XCTAssertEqual(Set(first.map(\.id)).count, 3)
        for command in first {
            let folderID = try XCTUnwrap(command.folderID)
            XCTAssertEqual(
                command.folderIncarnationDigest,
                contexts[folderID]?.folderIncarnationDigest
            )
            XCTAssertNil(command.commandConfigurationRevision)
        }
    }

    func testGlobalSyncExpansionExcludesPausedFoldersAndAllowsNoActiveWork() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let active = try XCTUnwrap(FolderID(rawValue: "active"))
        let paused = try XCTUnwrap(FolderID(rawValue: "paused"))
        _ = try fixture.installSnapshot(
            revision: revision,
            folderIDs: [paused, active],
            registeredFolderIDs: [paused, active],
            pausedFolderIDs: [paused]
        )
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)

        XCTAssertEqual(
            try producer.prepareCommands(
                invocationID: invocationID,
                kind: .sync,
                trigger: .user
            ).map(\.folderID),
            [active]
        )

        try SharedSnapshotStore(snapshotURL: fixture.paths.snapshot).write(
            CoreSnapshot(
                generation: 2,
                configurationRevision: revision,
                folders: [
                    FolderRecord(
                        id: paused,
                        label: paused.rawValue,
                        localPath: fixture.root.appendingPathComponent(paused.rawValue).path,
                        isPaused: true
                    )
                ]
            )
        )
        XCTAssertEqual(
            try producer.prepareCommands(
                invocationID: invocationID,
                kind: .sync,
                trigger: .user
            ),
            []
        )
    }

    func testBackgroundGlobalSyncPreservesIndependentFolderDirectionsAndGlobalMode() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let eligible = try XCTUnwrap(FolderID(rawValue: "a-eligible"))
        let tighter = try XCTUnwrap(FolderID(rawValue: "z-tighter"))
        let contexts = try fixture.installSnapshot(
            revision: revision,
            folderIDs: [tighter, eligible],
            registeredFolderIDs: [eligible, tighter]
        )
        let tighterContext = try XCTUnwrap(contexts[tighter])
        try SyncPolicyStore(url: fixture.paths.policy).saveDocument(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                global: SyncPolicy(),
                folderOverrides: [
                    FolderSyncPolicyOverride(
                        folderID: tighter,
                        folderIncarnationDigest: tighterContext.folderIncarnationDigest,
                        policy: SyncPolicyOverride(allowBackgroundDownload: false)
                    )
                ]
            )
        )
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)

        let background = try producer.prepareCommands(
            invocationID: invocationID,
            kind: .sync,
            trigger: .backgroundProcessing
        )
        XCTAssertEqual(background.map(\.folderID), [eligible, tighter])
        XCTAssertEqual(background.map(\.kind), [.sync, .upload])
        XCTAssertEqual(
            try producer.prepareCommands(
                invocationID: invocationID,
                kind: .sync,
                trigger: .user
            ).map(\.folderID),
            [eligible, tighter]
        )

        var refreshOnly = SyncPolicy()
        refreshOnly.automaticBackgroundMode = .refreshOnly
        try SyncPolicyStore(url: fixture.paths.policy).saveDocument(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                global: refreshOnly
            )
        )
        XCTAssertEqual(
            try producer.prepareCommands(
                invocationID: invocationID,
                kind: .sync,
                trigger: .backgroundProcessing
            ),
            []
        )
    }

    func testMissingOneIncarnationProducesAndEnqueuesNoGlobalSibling() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let valid = try XCTUnwrap(FolderID(rawValue: "a-valid"))
        let missing = try XCTUnwrap(FolderID(rawValue: "z-missing"))
        _ = try fixture.installSnapshot(
            revision: revision,
            folderIDs: [valid, missing],
            registeredFolderIDs: [valid]
        )
        let queue = CoreCommandQueue(root: fixture.paths.commandQueue)

        XCTAssertThrowsError(
            try ScopedCoreCommandProducer(paths: fixture.paths).prepareCommands(
                invocationID: invocationID,
                kind: .sync,
                trigger: .user
            )
        ) { error in
            XCTAssertEqual(
                error as? ScopedCoreCommandProducerError,
                .folderIncarnationUnavailable(missing.rawValue)
            )
        }
        XCTAssertEqual(try queue.pending(), [])
    }

    func testUnscopedNonSyncNetworkCommandFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.installSnapshot(
            revision: revision,
            folderIDs: [],
            registeredFolderIDs: []
        )

        XCTAssertThrowsError(
            try ScopedCoreCommandProducer(paths: fixture.paths).prepareCommands(
                invocationID: invocationID,
                kind: .rescan,
                trigger: .foreground
            )
        ) { error in
            XCTAssertEqual(
                error as? ScopedCoreCommandProducerError,
                .folderScopeRequired(.rescan)
            )
        }
    }

    func testSuccessfulRemoveResultDiscardsOnlyItsExactFolderPolicy() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "removed-policy"))
        let context = try XCTUnwrap(
            try fixture.installSnapshot(
                revision: revision,
                folderIDs: [folderID],
                registeredFolderIDs: [folderID]
            )[folderID]
        )
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)
        let command = try XCTUnwrap(
            producer.prepareCommands(
                invocationID: invocationID,
                kind: .removeFolder,
                folderID: folderID,
                trigger: .user
            ).only
        )
        try SyncPolicyStore(url: fixture.paths.policy).saveDocument(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                folderOverrides: [
                    .init(
                        folderID: folderID,
                        folderIncarnationDigest: context.folderIncarnationDigest,
                        queuePriority: .high,
                        policy: .init(allowBackgroundDownload: false)
                    )
                ]
            )
        )
        let succeeded = CoreCommandResult(commandID: command.id, status: .succeeded)

        XCTAssertTrue(
            try producer.reconcileSuccessfulFolderRemoval(
                command: command,
                result: succeeded
            )
        )
        XCTAssertFalse(
            try producer.reconcileSuccessfulFolderRemoval(
                command: command,
                result: succeeded
            )
        )
        XCTAssertTrue(try SyncPolicyStore(url: fixture.paths.policy).loadDocument().folderOverrides.isEmpty)
    }

    func testRemovalResultReconciliationRejectsWrongResultAndNewIncarnationPolicy() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "replacement-policy"))
        let oldContext = try XCTUnwrap(
            try fixture.installSnapshot(
                revision: revision,
                folderIDs: [folderID],
                registeredFolderIDs: [folderID]
            )[folderID]
        )
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)
        let command = try XCTUnwrap(
            producer.prepareCommands(
                invocationID: invocationID,
                kind: .removeFolder,
                folderID: folderID,
                trigger: .user
            ).only
        )
        let newDigest = String(repeating: "f", count: 64)
        try SyncPolicyStore(url: fixture.paths.policy).saveDocument(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                folderOverrides: [
                    .init(
                        folderID: folderID,
                        folderIncarnationDigest: newDigest,
                        policy: .init(allowBackgroundDownload: false)
                    )
                ]
            )
        )

        XCTAssertThrowsError(
            try producer.reconcileSuccessfulFolderRemoval(
                command: command,
                result: CoreCommandResult(commandID: UUID(), status: .succeeded)
            )
        ) { error in
            XCTAssertEqual(
                error as? ScopedCoreCommandProducerError,
                .resultCommandMismatch
            )
        }
        XCTAssertThrowsError(
            try producer.reconcileSuccessfulFolderRemoval(
                command: command,
                result: CoreCommandResult(commandID: command.id, status: .succeeded)
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncPolicyDocumentError,
                .staleFolderOverride(folderID: folderID.rawValue)
            )
        }
        let retained = try XCTUnwrap(
            try SyncPolicyStore(url: fixture.paths.policy).loadDocument().folderOverrides.first
        )
        XCTAssertNotEqual(retained.folderIncarnationDigest, oldContext.folderIncarnationDigest)
        XCTAssertEqual(retained.folderIncarnationDigest, newDigest)
    }

    func testTemporaryProfileBecomesImmutableDurableTaskAuthority() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "profile-folder"))
        let context = try XCTUnwrap(
            try fixture.installSnapshot(
                revision: revision,
                folderIDs: [folderID],
                registeredFolderIDs: [folderID]
            )[folderID]
        )
        let profile = TemporarySyncPolicyProfile(
            id: UUID(uuidString: "30000000-0000-4000-8000-000000000003")!,
            name: "Metered Override",
            maximumNetworkBytes: 7_000,
            validitySeconds: 600
        )
        try SyncPolicyStore(url: fixture.paths.policy).saveTemporaryProfiles([profile])
        let createdAt = Date(timeIntervalSince1970: 2_000_000_000)

        let command = try XCTUnwrap(
            ScopedCoreCommandProducer(paths: fixture.paths).prepareCommands(
                invocationID: invocationID,
                kind: .sync,
                folderID: folderID,
                expectedFolderIncarnationDigest: context.folderIncarnationDigest,
                temporaryPolicyProfile: profile,
                trigger: .user,
                createdAt: createdAt
            ).only
        )
        let binding = try XCTUnwrap(command.taskPolicyBinding)
        XCTAssertEqual(binding.profileID, profile.id)
        XCTAssertEqual(binding.maximumNetworkBytes, 7_000)
        XCTAssertTrue(binding.requestsTemporaryOverride)
        XCTAssertNoThrow(
            try binding.validated(
                commandCreatedAt: createdAt,
                trigger: .user,
                now: createdAt.addingTimeInterval(599)
            )
        )

        var changedProfile = profile
        changedProfile.maximumNetworkBytes = 8_000
        try SyncPolicyStore(url: fixture.paths.policy).saveTemporaryProfiles([changedProfile])
        XCTAssertThrowsError(
            try ScopedCoreCommandProducer(paths: fixture.paths).prepareCommands(
                kind: .sync,
                folderID: folderID,
                expectedFolderIncarnationDigest: context.folderIncarnationDigest,
                temporaryPolicyProfile: profile,
                trigger: .user,
                createdAt: createdAt
            )
        ) { error in
            XCTAssertEqual(
                error as? ScopedCoreCommandProducerError,
                .temporaryPolicyProfileUnavailable(profile.id)
            )
        }
        try SyncPolicyStore(url: fixture.paths.policy).saveTemporaryProfiles([])
        let queue = CoreCommandQueue(root: fixture.paths.commandQueue)
        try queue.enqueue(command)
        XCTAssertEqual(try queue.pending().only?.taskPolicyBinding, binding)
        XCTAssertThrowsError(
            try binding.validated(
                commandCreatedAt: createdAt,
                trigger: .user,
                now: createdAt.addingTimeInterval(600)
            )
        ) { error in
            XCTAssertEqual(error as? CoreTaskPolicyBindingError, .expired)
        }

        var tampered = binding
        tampered.maximumNetworkBytes += 1
        XCTAssertThrowsError(
            try tampered.validated(
                commandCreatedAt: createdAt,
                trigger: .user,
                now: createdAt.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? CoreTaskPolicyBindingError, .invalidDigest)
        }
    }

    func testTemporaryProfileRejectsUnknownBackgroundAndOfflineUse() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let profileID = UUID()
        XCTAssertThrowsError(
            try ScopedCoreCommandProducer(paths: fixture.paths).prepareCommands(
                kind: .sync,
                folderID: FolderID(rawValue: "missing"),
                temporaryPolicyProfile: .init(id: profileID, name: "Missing"),
                trigger: .user
            )
        ) { error in
            XCTAssertEqual(
                error as? ScopedCoreCommandProducerError,
                .temporaryPolicyProfileUnavailable(profileID)
            )
        }

        let profile = TemporarySyncPolicyProfile(name: "One task")
        try SyncPolicyStore(url: fixture.paths.policy).saveTemporaryProfiles([profile])
        for (kind, trigger) in [
            (CoreCommandKind.sync, SyncTrigger.backgroundProcessing),
            (.pause, .user),
        ] {
            XCTAssertThrowsError(
                try ScopedCoreCommandProducer(paths: fixture.paths).prepareCommands(
                    kind: kind,
                    temporaryPolicyProfile: profile,
                    trigger: trigger
                )
            ) { error in
                XCTAssertEqual(
                    error as? ScopedCoreCommandProducerError,
                    .temporaryPolicyProfileNotApplicable
                )
            }
        }
    }
}

extension ScopedCoreCommandProducerTests {
    fileprivate struct Fixture {
        let root: URL
        let paths: SharedContainerPaths

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ScopedProducerTests-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            paths = SharedContainerPaths(root: root)
        }

        func installSnapshot(
            revision: String?,
            folderIDs: [FolderID],
            registeredFolderIDs: [FolderID],
            pausedFolderIDs: Set<FolderID> = []
        ) throws -> [FolderID: FolderPolicyContext] {
            let folders = folderIDs.map {
                FolderRecord(
                    id: $0,
                    label: $0.rawValue,
                    localPath: root.appendingPathComponent($0.rawValue).path,
                    isPaused: pausedFolderIDs.contains($0)
                )
            }
            try SharedSnapshotStore(snapshotURL: paths.snapshot).write(
                CoreSnapshot(
                    generation: 1,
                    configurationRevision: revision,
                    folders: folders
                )
            )
            let contexts = try FolderIncarnationStore(url: paths.folderIncarnations)
                .ensureLegacyConfiguredFolders(registeredFolderIDs)
            return Dictionary(uniqueKeysWithValues: contexts.map { ($0.folderID, $0) })
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

extension Array {
    fileprivate var only: Element? { count == 1 ? first : nil }
}
