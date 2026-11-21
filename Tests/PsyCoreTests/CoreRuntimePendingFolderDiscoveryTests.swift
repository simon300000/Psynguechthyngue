import CryptoKit
import Foundation
import XCTest

@testable import PsyCore

final class CoreRuntimePendingFolderDiscoveryTests: XCTestCase {
    private let revision = String(repeating: "b", count: 64)
    private let changedRevision = String(repeating: "d", count: 64)
    private let localDeviceID = DeviceID(rawValue: String(repeating: "A", count: 56))!
    private let offeringDeviceID = DeviceID(rawValue: String(repeating: "B", count: 56))!
    private let otherDeviceID = DeviceID(rawValue: String(repeating: "C", count: 56))!
    private let discoveredFolderID = FolderID(rawValue: "discovered-runtime-folder")!
    private let configuredFolderID = FolderID(rawValue: "configured-runtime-folder")!
    private let taskID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let startedAt = Date(timeIntervalSince1970: 1_786_291_200)

    func testDiscoveryRunsAfterConfigurationAndReturnsCaptureOnlyAfterAccountingHistoryAndRefresh()
        async throws
    {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try savePolicy(.init(), paths: paths)
        let clock = AdvancingDiscoveryClock(now: startedAt)
        let client = PendingDiscoveryTestClient(
            configurationSnapshots: [
                configurationSnapshot(generation: 7),
                configurationSnapshot(
                    generation: 8,
                    pendingFolders: [try durableDiscoveredOffer()],
                    pendingFoldersAvailable: true
                ),
            ],
            captureBehaviors: [.pending, .pending, .success(.exact)],
            usedBytes: 321,
            captureDate: startedAt,
            discoveryOpenProbe: {
                let payload = try String(contentsOf: paths.transferAccounting, encoding: .utf8)
                guard payload.contains("\"state\":\"running\"") else {
                    throw PendingDiscoveryTestError.accountingDidNotBeginBeforeOpen
                }
            },
            configurationOpenProbe: { attempt in
                guard attempt == 2 else { return }
                guard try Self.makeAccountingStore(paths).pendingHistoryProjections().isEmpty,
                    try SyncRunHistory(url: paths.history).recent().count == 1
                else {
                    throw PendingDiscoveryTestError.historyWasNotAcknowledgedBeforeRefresh
                }
            }
        )

        let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting,
            clock: clock.value
        )

        guard case .completed(let capture, let transferredBytes, let snapshotGeneration) = outcome else {
            return XCTFail("unexpected outcome: \(outcome)")
        }
        XCTAssertEqual(capture.offeringDeviceID, offeringDeviceID)
        XCTAssertEqual(capture.offers.map(\.folderID), [discoveredFolderID])
        XCTAssertEqual(transferredBytes, 321)
        XCTAssertEqual(snapshotGeneration, 8)
        let events = await client.events()
        XCTAssertEqual(
            events,
            [
                "open:configuration", "snapshot:configuration", "close:configuration",
                "open:pendingFolderDiscovery", "capture", "capture", "capture",
                "close:pendingFolderDiscovery", "totals",
                "open:configuration", "snapshot:configuration", "close:configuration",
            ]
        )
        let plans = await client.discoveryPlans()
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].taskID, taskID)
        XCTAssertEqual(plans[0].offeringDeviceID, offeringDeviceID)
        XCTAssertEqual(plans[0].expectedConfigurationRevision, revision)
        XCTAssertEqual(plans[0].maximumNetworkBytes, PendingFolderDiscoveryPlan.maximumAllowedNetworkBytes)
        let bindings = await client.discoveryBindings()
        XCTAssertEqual(bindings.count, 1)
        let accountingBinding = TransferAccountingGrantBinding(
            folderID: syntheticDiscoveryAccountingScopeID(),
            folderIncarnationDigest: syntheticDiscoveryAccountingDigest(),
            taskID: taskID,
            sessionID: bindings[0].sessionID,
            planDigest: plans[0].planDigest
        )
        let runUsage = try accountingStore(paths).runUsage(for: accountingBinding)
        XCTAssertEqual(runUsage.committedBytes, 321)
        XCTAssertEqual(runUsage.activeReservedBytes, 0)
        XCTAssertEqual(runUsage.limitBytes, SyncPolicy().maxExpensiveRunBytes)
        XCTAssertTrue(runUsage.isFinished)

        let usage = try accountingStore(paths).usage(at: startedAt)
        XCTAssertEqual(usage.committedBytes, 321)
        XCTAssertEqual(usage.activeReservedBytes, 0)
        XCTAssertTrue(try accountingStore(paths).pendingHistoryProjections().isEmpty)
        let history = try SyncRunHistory(url: paths.history).recent()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].transferredBytes, 321)
        XCTAssertEqual(history[0].networkReceivedBytes, 200)
        XCTAssertEqual(history[0].networkSentBytes, 121)
        XCTAssertEqual(history[0].endReason, .completed)
        XCTAssertNil(history[0].failureCode)

        let snapshot = try XCTUnwrap(try SharedSnapshotStore(snapshotURL: paths.snapshot).read())
        XCTAssertEqual(snapshot.generation, snapshotGeneration)
        XCTAssertEqual(snapshot.configurationRevision, revision)
        XCTAssertEqual(snapshot.folders.map(\.id), [configuredFolderID])
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertTrue(snapshot.pendingFoldersAvailable)
        XCTAssertFalse(snapshot.pendingFoldersTruncated)
        XCTAssertEqual(snapshot.pendingFolders.count, 1)
        let offer = try XCTUnwrap(snapshot.pendingFolders.first)
        XCTAssertEqual(offer.folderID, discoveredFolderID)
        XCTAssertEqual(offer.offeringDeviceID, offeringDeviceID)
        XCTAssertEqual(offer.evidenceSource, .durableSummary)
        XCTAssertTrue(offer.requiresNetworkRevalidation)
        XCTAssertTrue(offer.requiresManagedLocalPath)
        XCTAssertTrue(offer.requiresExplicitDeviceSelection)
    }

    func testDiscoveryUsesSpecializedPolicyAndGlobalCapWithoutFolderOverride() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var global = SyncPolicy()
        global.cellularAccess = .uploadOnly
        global.maxExpensiveRunBytes = 500
        global.dailyExpensiveBytes = 1_000
        try savePolicy(global, paths: paths)
        var document = try SyncPolicyStore(url: paths.policy).loadDocument()
        document.folderOverrides = [
            FolderSyncPolicyOverride(
                folderID: discoveredFolderID,
                folderIncarnationDigest: String(repeating: "e", count: 64),
                policy: .init(cellularAccess: .denied)
            )
        ]
        try SyncPolicyStore(url: paths.policy).saveDocument(document)
        try commitPriorGlobalUsage(700, paths: paths, at: startedAt)
        var environment = SyncEnvironmentSnapshot.permissiveForTesting
        environment.network = .init(kind: .cellular)
        let client = PendingDiscoveryTestClient(
            configurationSnapshots: [
                configurationSnapshot(),
                configurationSnapshot(
                    generation: 8,
                    pendingFolders: [try durableDiscoveredOffer()],
                    pendingFoldersAvailable: true
                ),
            ],
            captureBehaviors: [.success(.exact)],
            usedBytes: 50,
            captureDate: startedAt
        )

        let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: .backgroundRefresh,
            paths: paths,
            environment: environment,
            clock: AdvancingDiscoveryClock(now: startedAt).value
        )

        XCTAssertTrue(outcome.completedSuccessfully)
        let maximumNetworkBytes = await client.discoveryPlans().map(\.maximumNetworkBytes)
        XCTAssertEqual(maximumNetworkBytes, [300])
        XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 750)
    }

    func testZeroRunAndExhaustedDailyCapsNeverOpenDiscoveryNetwork() async throws {
        for (runLimit, dailyLimit, priorUsage, expectedReason) in [
            (Optional(Int64(0)), Optional<Int64>.none, Int64(0), PolicyBlockReason.runTransferLimit),
            (Optional<Int64>.none, Optional(Int64(100)), Int64(100), .dailyTransferLimit),
        ] {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = runLimit
            policy.dailyExpensiveBytes = dailyLimit
            try savePolicy(policy, paths: paths)
            if priorUsage > 0 { try commitPriorGlobalUsage(priorUsage, paths: paths, at: startedAt) }
            let client = PendingDiscoveryTestClient(
                configurationSnapshots: [configurationSnapshot()],
                captureBehaviors: [.success(.exact)],
                captureDate: startedAt
            )

            let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingDiscoveryClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .policyDenied(reasons: [expectedReason]))
            let openedDiscoveryCount = await client.openedDiscoveryCount()
            XCTAssertEqual(openedDiscoveryCount, 0)
        }
    }

    func testDiscoveryRejectsWrongTargetRevisionOfferDeviceAndConfiguredOfferScope() async throws {
        let missingPaths = try makePaths()
        defer { try? FileManager.default.removeItem(at: missingPaths.root) }
        try savePolicy(.init(), paths: missingPaths)
        let missingClient = PendingDiscoveryTestClient(
            configurationSnapshots: [configurationSnapshot(devices: [])],
            captureBehaviors: [.success(.exact)],
            captureDate: startedAt
        )
        let missing = await CoreRuntime(clientFactory: { missingClient }).discoverPendingFolderOffers(
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: .user,
            paths: missingPaths,
            environment: .permissiveForTesting,
            clock: AdvancingDiscoveryClock(now: startedAt).value
        )
        XCTAssertEqual(missing, .failed(code: "offering_device_not_configured"))
        let openedDiscoveryCount = await missingClient.openedDiscoveryCount()
        XCTAssertEqual(openedDiscoveryCount, 0)

        for mutation in [
            DiscoveryCaptureMutation.wrongTarget,
            .wrongRevision,
            .wrongOfferDevice,
            .configuredFolder,
        ] {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            try savePolicy(.init(), paths: paths)
            let client = PendingDiscoveryTestClient(
                configurationSnapshots: [configurationSnapshot()],
                captureBehaviors: [.success(mutation)],
                usedBytes: 17,
                captureDate: startedAt
            )

            let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingDiscoveryClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .failed(code: "pending_folder_discovery_scope"))
            XCTAssertEqual(
                try accountingStore(paths).usage(at: startedAt).committedBytes,
                PendingFolderDiscoveryPlan.maximumAllowedNetworkBytes
            )
        }
    }

    func testLiveDevicePolicyCancellationCloseAndUnknownTotalsAreConservative() async throws {
        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = 1_024
            try savePolicy(policy, paths: paths)
            let snapshotURL = paths.snapshot
            let target = offeringDeviceID
            let client = PendingDiscoveryTestClient(
                configurationSnapshots: [configurationSnapshot()],
                captureBehaviors: [.pending, .success(.exact)],
                captureDate: startedAt,
                captureHook: { attempt in
                    guard attempt == 1,
                        var snapshot = try? SharedSnapshotStore(snapshotURL: snapshotURL).read()
                    else { return }
                    snapshot.devices.removeAll { $0.id == target }
                    try? SharedSnapshotStore(snapshotURL: snapshotURL).write(snapshot)
                }
            )

            let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingDiscoveryClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .failed(code: "offering_device_not_configured"))
            XCTAssertGreaterThan(client.cancellationRequests.value, 0)
            XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 1_024)
        }

        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = 2_048
            try savePolicy(policy, paths: paths)
            let client = PendingDiscoveryTestClient(
                configurationSnapshots: [configurationSnapshot()],
                captureBehaviors: [.suspend],
                captureDate: startedAt
            )
            let targetDeviceID = offeringDeviceID
            let requestedTaskID = taskID
            let requestedAt = startedAt
            let task = Task {
                await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
                    offeringDeviceID: targetDeviceID,
                    taskID: requestedTaskID,
                    trigger: .user,
                    paths: paths,
                    environment: .permissiveForTesting,
                    clock: AdvancingDiscoveryClock(now: requestedAt).value
                )
            }
            while await client.captureCount() == 0 { await Task.yield() }
            task.cancel()

            let cancelledOutcome = await task.value
            XCTAssertEqual(cancelledOutcome, .failed(code: "cancelled"))
            XCTAssertGreaterThan(client.cancellationRequests.value, 0)
            XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 2_048)
        }

        for (closeFails, totalsAvailable, grant, expectedCode) in [
            (true, true, Int64(4_096), "coreStopFailed"),
            (false, false, Int64(8_192), "coreInvalidResponse"),
        ] {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = grant
            try savePolicy(policy, paths: paths)
            let client = PendingDiscoveryTestClient(
                configurationSnapshots: [configurationSnapshot()],
                captureBehaviors: [.success(.exact)],
                usedBytes: 7,
                captureDate: startedAt,
                discoveryCloseAlwaysFails: closeFails,
                totalsAvailable: totalsAvailable
            )

            let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingDiscoveryClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .failed(code: expectedCode))
            XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, grant)
        }
    }

    func testBudgetBoundaryTimeZoneAndCheapToExpensiveCapDriftAbortConservatively() async throws {
        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = 1_024
            try savePolicy(policy, paths: paths)
            var document = try SyncPolicyStore(url: paths.policy).loadDocument()
            document.budgetTimeZoneIdentifier = "UTC"
            try SyncPolicyStore(url: paths.policy).saveDocument(document)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let dayEnd = try XCTUnwrap(
                calendar.date(
                    from: DateComponents(
                        year: 2026, month: 8, day: 10, hour: 23, minute: 59, second: 59
                    )
                )
            ).addingTimeInterval(0.95)
            let client = PendingDiscoveryTestClient(
                configurationSnapshots: [configurationSnapshot()],
                captureBehaviors: [.pending, .success(.exact)],
                captureDate: dayEnd
            )

            let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingDiscoveryClock(now: dayEnd).value
            )

            XCTAssertEqual(outcome, .failed(code: "budget_day_changed"))
            let captureCount = await client.captureCount()
            XCTAssertEqual(captureCount, 1)
            XCTAssertEqual(try accountingStore(paths).usage(at: dayEnd).committedBytes, 1_024)
        }

        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = 2_048
            try savePolicy(policy, paths: paths)
            var document = try SyncPolicyStore(url: paths.policy).loadDocument()
            document.budgetTimeZoneIdentifier = "UTC"
            try SyncPolicyStore(url: paths.policy).saveDocument(document)
            let policyURL = paths.policy
            let client = PendingDiscoveryTestClient(
                configurationSnapshots: [configurationSnapshot()],
                captureBehaviors: [.pending, .success(.exact)],
                captureDate: startedAt,
                captureHook: { attempt in
                    guard attempt == 1,
                        var changed = try? SyncPolicyStore(url: policyURL).loadDocument()
                    else { return }
                    changed.budgetTimeZoneIdentifier = "Asia/Shanghai"
                    try? SyncPolicyStore(url: policyURL).saveDocument(changed)
                }
            )

            let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingDiscoveryClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .failed(code: "policyConfigurationUnavailable"))
            XCTAssertEqual(
                try TransferAccountingStore(
                    url: paths.transferAccounting,
                    budgetTimeZoneIdentifier: "UTC"
                ).usage(at: startedAt).committedBytes,
                2_048
            )
        }

        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.allowExpensive = true
            try savePolicy(policy, paths: paths)
            let uncappedPolicy = policy
            let policyURL = paths.policy
            let environmentBox = LiveDiscoveryEnvironment(.permissiveForTesting)
            let client = PendingDiscoveryTestClient(
                configurationSnapshots: [configurationSnapshot()],
                captureBehaviors: [.pending, .success(.exact)],
                captureDate: startedAt,
                captureHook: { attempt in
                    guard attempt == 1 else { return }
                    var expensive = SyncEnvironmentSnapshot.permissiveForTesting
                    expensive.network.isExpensive = true
                    environmentBox.set(expensive)
                    var capped = uncappedPolicy
                    capped.maxExpensiveRunBytes = 1_024
                    try? SyncPolicyStore(url: policyURL).save(capped)
                }
            )

            let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                currentEnvironment: { environmentBox.get() },
                clock: AdvancingDiscoveryClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .policyDenied(reasons: [.runTransferLimit]))
            XCTAssertEqual(
                try accountingStore(paths).usage(at: startedAt).committedBytes,
                PendingFolderDiscoveryPlan.maximumAllowedNetworkBytes
            )
        }
    }

    func testFinalAuthoritativeRevisionDriftFailsAfterExactHistoryWithoutPublishingCapture()
        async throws
    {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var policy = SyncPolicy()
        policy.maxExpensiveRunBytes = 4_096
        try savePolicy(policy, paths: paths)
        let client = PendingDiscoveryTestClient(
            configurationSnapshots: [
                configurationSnapshot(), configurationSnapshot(generation: 8, revision: changedRevision),
            ],
            captureBehaviors: [.success(.exact)],
            usedBytes: 19,
            captureDate: startedAt
        )

        let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting,
            clock: AdvancingDiscoveryClock(now: startedAt).value
        )

        XCTAssertEqual(outcome, .failed(code: "configuration_revision_changed"))
        XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 19)
        let record = try XCTUnwrap(SyncRunHistory(url: paths.history).recent().first)
        XCTAssertEqual(record.transferredBytes, 19)
        XCTAssertEqual(record.endReason, .completed)
        XCTAssertNil(record.failureCode)
        XCTAssertTrue(try accountingStore(paths).pendingHistoryProjections().isEmpty)
        let snapshot = try XCTUnwrap(try SharedSnapshotStore(snapshotURL: paths.snapshot).read())
        XCTAssertTrue(snapshot.pendingFolders.isEmpty)
    }

    func testFinalAuthoritativeProjectionMismatchFailsAfterExactHistoryWithoutReturningCapture()
        async throws
    {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var policy = SyncPolicy()
        policy.maxExpensiveRunBytes = 4_096
        try savePolicy(policy, paths: paths)
        let client = PendingDiscoveryTestClient(
            configurationSnapshots: [
                configurationSnapshot(), configurationSnapshot(generation: 8),
            ],
            captureBehaviors: [.success(.exact)],
            usedBytes: 23,
            captureDate: startedAt
        )

        let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting,
            clock: AdvancingDiscoveryClock(now: startedAt).value
        )

        XCTAssertEqual(outcome, .failed(code: "pending_folder_discovery_snapshot_scope"))
        XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 23)
        let record = try XCTUnwrap(SyncRunHistory(url: paths.history).recent().first)
        XCTAssertEqual(record.transferredBytes, 23)
        XCTAssertEqual(record.endReason, .completed)
        XCTAssertNil(record.failureCode)
        XCTAssertTrue(try accountingStore(paths).pendingHistoryProjections().isEmpty)
    }

    func testEmptyAndTruncatedTargetCapturesTrustTheNativeGlobalSnapshotProjection()
        async throws
    {
        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            try savePolicy(.init(), paths: paths)
            let siblingFolderID = FolderID(rawValue: "sibling-discovered-folder")!
            let sibling = try durableDiscoveredOffer(
                folderID: siblingFolderID,
                offeringDeviceID: otherDeviceID
            )
            let devices = [
                DeviceRecord(id: offeringDeviceID, name: "Peer"),
                DeviceRecord(id: otherDeviceID, name: "Other peer"),
            ]
            let client = PendingDiscoveryTestClient(
                configurationSnapshots: [
                    configurationSnapshot(
                        devices: devices,
                        pendingFolders: [sibling],
                        pendingFoldersAvailable: true
                    ),
                    configurationSnapshot(
                        generation: 8,
                        devices: devices,
                        pendingFolders: [sibling],
                        pendingFoldersAvailable: true
                    ),
                ],
                captureBehaviors: [.success(.empty)],
                captureDate: startedAt
            )

            let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingDiscoveryClock(now: startedAt).value
            )

            guard case .completed(let capture, _, _) = outcome else {
                return XCTFail("unexpected outcome: \(outcome)")
            }
            XCTAssertTrue(capture.offers.isEmpty)
            XCTAssertFalse(capture.truncated)
            let snapshot = try XCTUnwrap(
                try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
            )
            XCTAssertEqual(snapshot.pendingFolders.map(\.id), [sibling.id])
            XCTAssertTrue(snapshot.pendingFoldersAvailable)
            XCTAssertFalse(snapshot.pendingFoldersTruncated)
        }

        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            try savePolicy(.init(), paths: paths)
            let client = PendingDiscoveryTestClient(
                configurationSnapshots: [
                    configurationSnapshot(),
                    configurationSnapshot(
                        generation: 8,
                        pendingFoldersAvailable: true,
                        pendingFoldersTruncated: true
                    ),
                ],
                captureBehaviors: [.success(.emptyTruncated)],
                captureDate: startedAt
            )

            let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingDiscoveryClock(now: startedAt).value
            )

            guard case .completed(let capture, _, _) = outcome else {
                return XCTFail("unexpected outcome: \(outcome)")
            }
            XCTAssertTrue(capture.offers.isEmpty)
            XCTAssertTrue(capture.truncated)
            let snapshot = try XCTUnwrap(
                try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
            )
            XCTAssertTrue(snapshot.pendingFoldersAvailable)
            XCTAssertTrue(snapshot.pendingFoldersTruncated)
        }
    }

    func testPendingDiscoveryPollsForFifteenSecondsThenSettlesKnownTotalsExactly()
        async throws
    {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var policy = SyncPolicy()
        policy.maxExpensiveRunBytes = 1_024
        try savePolicy(policy, paths: paths)
        let client = PendingDiscoveryTestClient(
            configurationSnapshots: [configurationSnapshot()],
            captureBehaviors: [.pending],
            usedBytes: 9,
            captureDate: startedAt
        )

        let outcome = await CoreRuntime(clientFactory: { client }).discoverPendingFolderOffers(
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting,
            clock: AdvancingDiscoveryClock(now: startedAt).value
        )

        XCTAssertEqual(outcome, .failed(code: "pending_folder_discovery_timeout"))
        let captureCount = await client.captureCount()
        XCTAssertEqual(captureCount, 151)
        XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 9)
        let record = try XCTUnwrap(SyncRunHistory(url: paths.history).recent().first)
        XCTAssertEqual(record.transferredBytes, 9)
        XCTAssertEqual(record.networkReceivedBytes, 9)
        XCTAssertEqual(record.networkSentBytes, 0)
        XCTAssertEqual(record.endReason, .failed)
        XCTAssertEqual(record.failureCode, "pending_folder_discovery_timeout")
    }

    private func configurationSnapshot(
        generation: UInt64 = 7,
        revision: String? = nil,
        devices: [DeviceRecord]? = nil,
        pendingFolders: [PendingFolderOffer] = [],
        pendingFoldersAvailable: Bool = false,
        pendingFoldersTruncated: Bool = false
    ) -> CoreSnapshot {
        CoreSnapshot(
            generation: generation,
            configurationRevision: revision ?? self.revision,
            localDeviceID: localDeviceID,
            devices: devices ?? [DeviceRecord(id: offeringDeviceID, name: "Peer")],
            folders: [
                FolderRecord(
                    id: configuredFolderID,
                    label: "Configured",
                    localPath: "/managed/configured"
                )
            ],
            pendingFolders: pendingFolders,
            pendingFoldersAvailable: pendingFoldersAvailable,
            pendingFoldersTruncated: pendingFoldersTruncated
        )
    }

    private func durableDiscoveredOffer(
        folderID: FolderID? = nil,
        offeringDeviceID: DeviceID? = nil
    ) throws -> PendingFolderOffer {
        try PendingFolderOffer(
            folderID: folderID ?? discoveredFolderID,
            label: "Discovered folder",
            offeringDeviceID: offeringDeviceID ?? self.offeringDeviceID,
            lastSeen: startedAt,
            offerVersion: CoreSessionDigest.stableVersion([
                "offer", (folderID ?? discoveredFolderID).rawValue,
            ]),
            receiveEncrypted: false,
            remoteEncrypted: false,
            requiresManagedLocalPath: true,
            requiresExplicitDeviceSelection: true,
            evidenceSource: .durableSummary,
            requiresNetworkRevalidation: true
        )
    }

    private func syntheticDiscoveryAccountingScopeID() -> FolderID {
        let digest = SHA256.hash(data: Data(offeringDeviceID.rawValue.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return FolderID(rawValue: "pending-discovery-\(digest.prefix(46))")!
    }

    private func syntheticDiscoveryAccountingDigest() -> String {
        var material = Data("psy-pending-folder-discovery-accounting-v1".utf8)
        for value in [offeringDeviceID.rawValue, revision] {
            material.append(0)
            material.append(contentsOf: value.utf8)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    private func makePaths() throws -> SharedContainerPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SharedContainerPaths(root: root)
    }

    private func savePolicy(_ policy: SyncPolicy, paths: SharedContainerPaths) throws {
        try SyncPolicyStore(url: paths.policy).save(policy)
    }

    private func accountingStore(_ paths: SharedContainerPaths) throws -> TransferAccountingStore {
        try Self.makeAccountingStore(paths)
    }

    private static func makeAccountingStore(_ paths: SharedContainerPaths) throws
        -> TransferAccountingStore
    {
        let document = try SyncPolicyStore(url: paths.policy).loadDocument()
        return TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        )
    }

    private func commitPriorGlobalUsage(
        _ bytes: Int64,
        paths: SharedContainerPaths,
        at date: Date
    ) throws {
        let store = try accountingStore(paths)
        let ownerID = UUID()
        let sessionID = UUID()
        let binding = TransferAccountingGrantBinding(
            folderID: FolderID(rawValue: "prior-discovery-accounting")!,
            folderIncarnationDigest: String(repeating: "a", count: 64),
            taskID: UUID(),
            sessionID: sessionID,
            planDigest: String(repeating: "c", count: 64)
        )
        let reservation = try store.reserve(
            ownerID: ownerID,
            binding: binding,
            grantBytes: bytes,
            globalDailyLimitBytes: bytes,
            folderDailyLimitBytes: nil,
            expiresAt: date.addingTimeInterval(60),
            at: date
        )
        _ = try store.begin(
            reservationID: reservation.id,
            ownerID: ownerID,
            binding: binding,
            at: date
        )
        _ = try store.settleAndFinalizeRun(
            reservationID: reservation.id,
            ownerID: ownerID,
            binding: binding,
            outcome: .exact(bytes: bytes),
            at: date
        )
    }
}

private enum PendingDiscoveryTestError: Error {
    case accountingDidNotBeginBeforeOpen
    case historyWasNotAcknowledgedBeforeRefresh
}

private enum DiscoveryCaptureMutation: Hashable, Sendable {
    case exact
    case empty
    case emptyTruncated
    case wrongTarget
    case wrongRevision
    case wrongOfferDevice
    case configuredFolder
}

private enum DiscoveryCaptureBehavior: Sendable {
    case pending
    case success(DiscoveryCaptureMutation)
    case suspend
}

private final class AdvancingDiscoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) { current = now }

    var value: PendingFolderObservationClock {
        PendingFolderObservationClock(
            now: { [self] in read() },
            sleep: { [self] interval in
                advance(by: interval)
                await Task.yield()
            }
        )
    }

    private func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class LiveDiscoveryEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SyncEnvironmentSnapshot

    init(_ value: SyncEnvironmentSnapshot) { self.value = value }

    func get() -> SyncEnvironmentSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: SyncEnvironmentSnapshot) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private final class DiscoveryLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private actor PendingDiscoveryTestClient: CoreClient {
    private enum ActiveSession {
        case configuration(CoreExplicitSessionBinding, CoreSnapshot)
        case discovery(CoreExplicitSessionBinding, PendingFolderDiscoveryPlan)

        var binding: CoreExplicitSessionBinding {
            switch self {
            case .configuration(let binding, _), .discovery(let binding, _): binding
            }
        }
    }

    nonisolated let cancellationRequests = DiscoveryLockedCounter()
    private let localDeviceID = DeviceID(rawValue: String(repeating: "A", count: 56))!
    private let otherDeviceID = DeviceID(rawValue: String(repeating: "C", count: 56))!
    private let discoveredFolderID = FolderID(rawValue: "discovered-runtime-folder")!
    private let configuredFolderID = FolderID(rawValue: "configured-runtime-folder")!
    private let configurationSnapshots: [CoreSnapshot]
    private let captureBehaviors: [DiscoveryCaptureBehavior]
    private let usedBytes: Int64
    private let captureDate: Date
    private let discoveryOpenProbe: (@Sendable () throws -> Void)?
    private let configurationOpenProbe: (@Sendable (Int) throws -> Void)?
    private let captureHook: (@Sendable (Int) -> Void)?
    private let discoveryCloseAlwaysFails: Bool
    private let totalsAvailable: Bool
    private var activeSession: ActiveSession?
    private var lastClosedPlan: PendingFolderDiscoveryPlan?
    private var recordedEvents: [String] = []
    private var plans: [PendingFolderDiscoveryPlan] = []
    private var bindings: [CoreExplicitSessionBinding] = []
    private var captureAttempts = 0
    private var configurationOpens = 0

    init(
        configurationSnapshots: [CoreSnapshot],
        captureBehaviors: [DiscoveryCaptureBehavior],
        usedBytes: Int64 = 0,
        captureDate: Date,
        discoveryOpenProbe: (@Sendable () throws -> Void)? = nil,
        configurationOpenProbe: (@Sendable (Int) throws -> Void)? = nil,
        captureHook: (@Sendable (Int) -> Void)? = nil,
        discoveryCloseAlwaysFails: Bool = false,
        totalsAvailable: Bool = true
    ) {
        self.configurationSnapshots = configurationSnapshots
        self.captureBehaviors = captureBehaviors
        self.usedBytes = usedBytes
        self.captureDate = captureDate
        self.discoveryOpenProbe = discoveryOpenProbe
        self.configurationOpenProbe = configurationOpenProbe
        self.captureHook = captureHook
        self.discoveryCloseAlwaysFails = discoveryCloseAlwaysFails
        self.totalsAvailable = totalsAvailable
    }

    nonisolated func requestCancellation() { cancellationRequests.increment() }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        throw CoreClientError.invalidResponse("legacy_start_used")
    }

    func openConfigurationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID
    ) async throws -> CoreExplicitSessionReceipt {
        guard activeSession == nil else { throw CoreClientError.coreRejected("session_overlap") }
        configurationOpens += 1
        try configurationOpenProbe?(configurationOpens)
        let snapshot = configurationSnapshots[
            min(configurationOpens - 1, configurationSnapshots.count - 1)
        ]
        let binding = CoreExplicitSessionBinding.configuration(sessionID: sessionID)
        activeSession = .configuration(binding, snapshot)
        recordedEvents.append("open:configuration")
        return try receipt(binding: binding, generation: snapshot.generation, revision: snapshot.configurationRevision!)
    }

    func openPendingFolderDiscoverySession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID,
        plan: PendingFolderDiscoveryPlan
    ) async throws -> CoreExplicitSessionReceipt {
        guard activeSession == nil else { throw CoreClientError.coreRejected("session_overlap") }
        try discoveryOpenProbe?()
        let binding = CoreExplicitSessionBinding.pendingFolderDiscovery(
            sessionID: sessionID,
            plan: plan
        )
        plans.append(plan)
        bindings.append(binding)
        activeSession = .discovery(binding, plan)
        recordedEvents.append("open:pendingFolderDiscovery")
        return try receipt(binding: binding, generation: 2, revision: plan.expectedConfigurationRevision)
    }

    func capturePendingFolderDiscovery() async throws -> PendingFolderDiscoveryCaptureReceipt {
        guard case .discovery(_, let plan) = activeSession else {
            throw CoreClientError.coreRejected("wrong_session_mode")
        }
        captureAttempts += 1
        recordedEvents.append("capture")
        captureHook?(captureAttempts)
        let behavior =
            captureAttempts <= captureBehaviors.count
            ? captureBehaviors[captureAttempts - 1] : .pending
        switch behavior {
        case .pending:
            throw CoreClientError.coreRejected("pending_folder_discovery_pending")
        case .suspend:
            try await Task.sleep(for: .seconds(30))
            throw CoreClientError.coreRejected("unexpected_test_wakeup")
        case .success(let mutation):
            let target = mutation == .wrongTarget ? otherDeviceID : plan.offeringDeviceID
            let offerDevice = mutation == .wrongOfferDevice ? otherDeviceID : plan.offeringDeviceID
            let revision =
                mutation == .wrongRevision
                ? String(repeating: "d", count: 64) : plan.expectedConfigurationRevision
            let folderID = mutation == .configuredFolder ? configuredFolderID : discoveredFolderID
            let epoch = CoreSessionDigest.stableVersion(["connection", plan.planDigest])
            let offers: [PendingFolderDiscoveryOffer]
            if mutation == .empty || mutation == .emptyTruncated {
                offers = []
            } else {
                offers = [
                    PendingFolderDiscoveryOffer(
                        folderID: folderID,
                        offeringDeviceID: offerDevice,
                        label: "Discovered folder",
                        lastSeen: captureDate,
                        offerVersion: CoreSessionDigest.stableVersion(["offer", folderID.rawValue]),
                        receiveEncrypted: false,
                        remoteEncrypted: false,
                        connectionEpoch: epoch,
                        observedAt: captureDate
                    )
                ]
            }
            return PendingFolderDiscoveryCaptureReceipt(
                generation: 3,
                configurationRevision: revision,
                offeringDeviceID: target,
                connectionEpoch: epoch,
                observedAt: captureDate,
                offers: offers,
                truncated: mutation == .emptyTruncated
            )
        }
    }

    func closeExplicitSession() async throws -> CoreExplicitSessionReceipt {
        guard let activeSession else { throw CoreClientError.notRunning }
        switch activeSession {
        case .configuration(let binding, let snapshot):
            recordedEvents.append("close:configuration")
            self.activeSession = nil
            return try receipt(
                binding: binding,
                generation: snapshot.generation,
                revision: snapshot.configurationRevision!
            )
        case .discovery(let binding, let plan):
            if discoveryCloseAlwaysFails {
                recordedEvents.append("close:pendingFolderDiscovery:failed")
                throw CoreClientError.coreRejected("close_failed")
            }
            recordedEvents.append("close:pendingFolderDiscovery")
            lastClosedPlan = plan
            self.activeSession = nil
            return try receipt(
                binding: binding,
                generation: 4,
                revision: plan.expectedConfigurationRevision
            )
        }
    }

    func stop() async throws { throw CoreClientError.invalidResponse("legacy_stop_used") }

    func snapshot() async throws -> CoreSnapshot {
        guard case .configuration(_, let snapshot) = activeSession else {
            throw CoreClientError.notRunning
        }
        recordedEvents.append("snapshot:configuration")
        return snapshot
    }

    func networkTransferTotals() async throws -> CoreNetworkTransferTotals? {
        guard let plan = lastClosedPlan, activeSession == nil else {
            throw CoreClientError.invalidResponse("totals_before_close")
        }
        recordedEvents.append("totals")
        guard totalsAvailable else { return nil }
        return CoreNetworkTransferTotals(
            receivedBytes: min(200, usedBytes),
            sentBytes: max(0, usedBytes - 200),
            budgetLimited: true,
            budgetLimitBytes: plan.maximumNetworkBytes,
            budgetUsedBytes: usedBytes,
            budgetExhausted: usedBytes == plan.maximumNetworkBytes
        )
    }

    func execute(_ command: CoreCommand) async throws {
        throw CoreClientError.invalidResponse("execute_used")
    }

    func events() -> [String] { recordedEvents }
    func discoveryPlans() -> [PendingFolderDiscoveryPlan] { plans }
    func discoveryBindings() -> [CoreExplicitSessionBinding] { bindings }
    func openedDiscoveryCount() -> Int { plans.count }
    func captureCount() -> Int { captureAttempts }

    private func receipt(
        binding: CoreExplicitSessionBinding,
        generation: UInt64,
        revision: String
    ) throws -> CoreExplicitSessionReceipt {
        try CoreExplicitSessionReceipt(
            binding: binding,
            deviceID: localDeviceID,
            generation: generation,
            configurationRevision: revision
        )
    }
}
