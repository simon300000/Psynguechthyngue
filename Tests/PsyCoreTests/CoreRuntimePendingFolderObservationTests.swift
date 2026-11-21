import CryptoKit
import Foundation
import XCTest

@testable import PsyCore

final class CoreRuntimePendingFolderObservationTests: XCTestCase {
    private let revision = String(repeating: "b", count: 64)
    private let localDeviceID = DeviceID(rawValue: String(repeating: "A", count: 56))!
    private let offeringDeviceID = DeviceID(rawValue: String(repeating: "B", count: 56))!
    private let otherDeviceID = DeviceID(rawValue: String(repeating: "C", count: 56))!
    private let folderID = FolderID(rawValue: "pending-runtime-folder")!
    private let taskID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let startedAt = Date(timeIntervalSince1970: 1_786_291_200)

    func testObservationUsesConfigurationThenBoundedObservationAndReturnsProofAfterExactSettlement()
        async throws
    {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try savePolicy(.init(), paths: paths)
        let clock = AdvancingObservationClock(now: startedAt)
        let client = PendingObservationTestClient(
            configurationSnapshot: configurationSnapshot(),
            captureBehaviors: [.pending, .pending, .success(.exact)],
            usedBytes: 321,
            proofDate: startedAt,
            observationOpenProbe: {
                let payload = try String(contentsOf: paths.transferAccounting, encoding: .utf8)
                guard payload.contains("\"state\":\"running\"") else {
                    throw PendingObservationTestError.accountingDidNotBeginBeforeOpen
                }
            }
        )

        let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
            folderID: folderID,
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: .user,
            paths: paths,
            environment: .permissiveForTesting,
            clock: clock.value
        )

        guard case .completed(let proof, let transferredBytes, let snapshotGeneration) = outcome else {
            return XCTFail("unexpected outcome: \(outcome)")
        }
        XCTAssertEqual(proof.folderID, folderID)
        XCTAssertEqual(proof.offeringDeviceID, offeringDeviceID)
        XCTAssertEqual(transferredBytes, 321)
        XCTAssertEqual(snapshotGeneration, 7)
        let events = await client.events()
        XCTAssertEqual(
            events,
            [
                "open:configuration", "snapshot:configuration", "close:configuration",
                "open:pendingFolderObservation", "capture", "capture", "capture",
                "close:pendingFolderObservation", "totals",
            ]
        )
        let plans = await client.observationPlans()
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].taskID, taskID)
        XCTAssertEqual(plans[0].folderID, folderID)
        XCTAssertEqual(plans[0].offeringDeviceID, offeringDeviceID)
        XCTAssertEqual(plans[0].expectedConfigurationRevision, revision)
        XCTAssertEqual(plans[0].maximumNetworkBytes, PendingFolderObservationPlan.maximumAllowedNetworkBytes)

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
    }

    func testObservationPolicyUsesOnlyDiscoverAndExchangeIndexNotGenericTransferEnvelope()
        async throws
    {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var policy = SyncPolicy()
        policy.cellularAccess = .uploadOnly
        try savePolicy(policy, paths: paths)
        var environment = SyncEnvironmentSnapshot.permissiveForTesting
        environment.network = .init(kind: .cellular)
        let client = PendingObservationTestClient(
            configurationSnapshot: configurationSnapshot(),
            captureBehaviors: [.success(.exact)],
            usedBytes: 0,
            proofDate: startedAt
        )

        let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
            folderID: folderID,
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: .user,
            paths: paths,
            environment: environment,
            clock: AdvancingObservationClock(now: startedAt).value
        )

        XCTAssertTrue(outcome.completedSuccessfully)
        let openedObservationCount = await client.openedObservationCount()
        XCTAssertEqual(openedObservationCount, 1)
    }

    func testZeroRunGrantAndExhaustedGlobalDailyGrantNeverOpenNetwork() async throws {
        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = 0
            policy.dailyExpensiveBytes = nil
            try savePolicy(policy, paths: paths)
            let client = PendingObservationTestClient(
                configurationSnapshot: configurationSnapshot(),
                captureBehaviors: [.success(.exact)],
                proofDate: startedAt
            )

            let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
                folderID: folderID,
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingObservationClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .policyDenied(reasons: [.runTransferLimit]))
            let openedObservationCount = await client.openedObservationCount()
            XCTAssertEqual(openedObservationCount, 0)
        }

        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = nil
            policy.dailyExpensiveBytes = 100
            try savePolicy(policy, paths: paths)
            try commitPriorGlobalUsage(100, paths: paths, at: startedAt)
            let client = PendingObservationTestClient(
                configurationSnapshot: configurationSnapshot(),
                captureBehaviors: [.success(.exact)],
                proofDate: startedAt
            )

            let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
                folderID: folderID,
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingObservationClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .policyDenied(reasons: [.dailyTransferLimit]))
            let openedObservationCount = await client.openedObservationCount()
            XCTAssertEqual(openedObservationCount, 0)
        }
    }

    func testObservationRejectsUnconfiguredDeviceAndProofScopeOrRevisionMismatch() async throws {
        let missingPaths = try makePaths()
        defer { try? FileManager.default.removeItem(at: missingPaths.root) }
        try savePolicy(.init(), paths: missingPaths)
        let missingClient = PendingObservationTestClient(
            configurationSnapshot: configurationSnapshot(devices: []),
            captureBehaviors: [.success(.exact)],
            proofDate: startedAt
        )
        let missing = await CoreRuntime(clientFactory: { missingClient }).observePendingFolderOffer(
            folderID: folderID,
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: .user,
            paths: missingPaths,
            environment: .permissiveForTesting,
            clock: AdvancingObservationClock(now: startedAt).value
        )
        XCTAssertEqual(missing, .failed(code: "offering_device_not_configured"))
        let openedObservationCount = await missingClient.openedObservationCount()
        XCTAssertEqual(openedObservationCount, 0)

        for mismatch in [ProofMutation.wrongFolder, .wrongDevice, .wrongRevision, .wrongSession] {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            try savePolicy(.init(), paths: paths)
            let client = PendingObservationTestClient(
                configurationSnapshot: configurationSnapshot(),
                captureBehaviors: [.success(mismatch)],
                usedBytes: 17,
                proofDate: startedAt
            )

            let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
                folderID: folderID,
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingObservationClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .failed(code: "pending_folder_observation_scope"))
            let usage = try accountingStore(paths).usage(at: startedAt)
            XCTAssertEqual(
                usage.committedBytes,
                PendingFolderObservationPlan.maximumAllowedNetworkBytes
            )
        }
    }

    func testLivePolicyDriftCancellationAndCloseFailureSettleConservatively() async throws {
        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.allowExpensive = true
            policy.maxExpensiveRunBytes = 1_024
            try savePolicy(policy, paths: paths)
            let initiallyAllowedPolicy = policy
            let policyURL = paths.policy
            var environment = SyncEnvironmentSnapshot.permissiveForTesting
            environment.network.isExpensive = true
            let liveEnvironment = environment
            let client = PendingObservationTestClient(
                configurationSnapshot: configurationSnapshot(),
                captureBehaviors: [.pending, .success(.exact)],
                proofDate: startedAt,
                captureHook: { attempt in
                    guard attempt == 1 else { return }
                    var tightened = initiallyAllowedPolicy
                    tightened.allowExpensive = false
                    try? SyncPolicyStore(url: policyURL).save(tightened)
                }
            )

            let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
                folderID: folderID,
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: environment,
                currentEnvironment: { liveEnvironment },
                clock: AdvancingObservationClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .policyDenied(reasons: [.expensiveNetworkDenied]))
            XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 1_024)
        }

        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = 2_048
            try savePolicy(policy, paths: paths)
            let client = PendingObservationTestClient(
                configurationSnapshot: configurationSnapshot(),
                captureBehaviors: [.suspend],
                proofDate: startedAt
            )
            let runtime = CoreRuntime(clientFactory: { client })
            let observedFolderID = folderID
            let observedDeviceID = offeringDeviceID
            let observedTaskID = taskID
            let observationClock = AdvancingObservationClock(now: startedAt).value
            let task = Task {
                await runtime.observePendingFolderOffer(
                    folderID: observedFolderID,
                    offeringDeviceID: observedDeviceID,
                    taskID: observedTaskID,
                    trigger: .user,
                    paths: paths,
                    environment: .permissiveForTesting,
                    clock: observationClock
                )
            }
            while await client.captureCount() == 0 { await Task.yield() }
            task.cancel()
            let outcome = await task.value
            XCTAssertEqual(outcome, .failed(code: "cancelled"))
            XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 2_048)
        }

        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = 4_096
            try savePolicy(policy, paths: paths)
            let client = PendingObservationTestClient(
                configurationSnapshot: configurationSnapshot(),
                captureBehaviors: [.success(.exact)],
                proofDate: startedAt,
                observationCloseAlwaysFails: true
            )

            let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
                folderID: folderID,
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingObservationClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .failed(code: "coreStopFailed"))
            XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 4_096)
        }
    }

    func testPartialGlobalDailyRemainingIsNativeCapAndFolderOverrideIsIgnored() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var global = SyncPolicy()
        global.cellularAccess = .allowed
        global.maxExpensiveRunBytes = 500
        global.dailyExpensiveBytes = 1_000
        try savePolicy(global, paths: paths)
        var document = try SyncPolicyStore(url: paths.policy).loadDocument()
        document.folderOverrides = [
            FolderSyncPolicyOverride(
                folderID: folderID,
                folderIncarnationDigest: syntheticObservationDigest(),
                policy: .init(cellularAccess: .denied)
            )
        ]
        try SyncPolicyStore(url: paths.policy).saveDocument(document)
        try commitPriorGlobalUsage(700, paths: paths, at: startedAt)
        var environment = SyncEnvironmentSnapshot.permissiveForTesting
        environment.network = .init(kind: .cellular)
        let client = PendingObservationTestClient(
            configurationSnapshot: configurationSnapshot(),
            captureBehaviors: [.success(.exact)],
            usedBytes: 50,
            proofDate: startedAt
        )

        let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
            folderID: folderID,
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: .user,
            paths: paths,
            environment: environment,
            clock: AdvancingObservationClock(now: startedAt).value
        )

        XCTAssertTrue(outcome.completedSuccessfully)
        let plans = await client.observationPlans()
        XCTAssertEqual(plans.map(\.maximumNetworkBytes), [300])
        let usage = try accountingStore(paths).usage(at: startedAt)
        XCTAssertEqual(usage.committedBytes, 750)
        XCTAssertEqual(usage.activeReservedBytes, 0)
    }

    func testPendingTimeoutSettlesExactButUnavailableTotalsAndConfigurationDriftAreConservative()
        async throws
    {
        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = 1_024
            try savePolicy(policy, paths: paths)
            let client = PendingObservationTestClient(
                configurationSnapshot: configurationSnapshot(),
                captureBehaviors: [.pending],
                usedBytes: 9,
                proofDate: startedAt
            )

            let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
                folderID: folderID,
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingObservationClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .failed(code: "pending_folder_observation_timeout"))
            let captureCount = await client.captureCount()
            XCTAssertEqual(captureCount, 151)
            XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 9)
            let history = try SyncRunHistory(url: paths.history).recent()
            XCTAssertEqual(history.first?.networkReceivedBytes, 9)
            XCTAssertEqual(history.first?.networkSentBytes, 0)
            XCTAssertEqual(history.first?.failureCode, "pending_folder_observation_timeout")
        }

        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = 2_048
            try savePolicy(policy, paths: paths)
            let client = PendingObservationTestClient(
                configurationSnapshot: configurationSnapshot(),
                captureBehaviors: [.success(.exact)],
                usedBytes: 7,
                proofDate: startedAt,
                totalsAvailable: false
            )

            let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
                folderID: folderID,
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingObservationClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .failed(code: "coreInvalidResponse"))
            XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 2_048)
        }

        do {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            var policy = SyncPolicy()
            policy.maxExpensiveRunBytes = 4_096
            try savePolicy(policy, paths: paths)
            let snapshotURL = paths.snapshot
            let client = PendingObservationTestClient(
                configurationSnapshot: configurationSnapshot(),
                captureBehaviors: [.pending, .success(.exact)],
                proofDate: startedAt,
                captureHook: { attempt in
                    guard attempt == 1 else { return }
                    try? FileManager.default.removeItem(at: snapshotURL)
                }
            )

            let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
                folderID: folderID,
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingObservationClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .failed(code: "configuration_revision_mismatch"))
            XCTAssertEqual(try accountingStore(paths).usage(at: startedAt).committedBytes, 4_096)
        }
    }

    func testBudgetDayAndBudgetTimeZoneRolloverAbortAndSettleConservatively() async throws {
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
                        year: 2026,
                        month: 8,
                        day: 10,
                        hour: 23,
                        minute: 59,
                        second: 59
                    )
                )
            ).addingTimeInterval(0.95)
            let client = PendingObservationTestClient(
                configurationSnapshot: configurationSnapshot(),
                captureBehaviors: [.pending, .success(.exact)],
                proofDate: dayEnd
            )

            let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
                folderID: folderID,
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingObservationClock(now: dayEnd).value
            )

            XCTAssertEqual(outcome, .failed(code: "budget_day_changed"))
            let captureCount = await client.captureCount()
            XCTAssertEqual(captureCount, 1)
            XCTAssertEqual(try accountingStore(paths).usage(at: dayEnd).committedBytes, 1_024)
            let record = try XCTUnwrap(SyncRunHistory(url: paths.history).recent().first)
            XCTAssertEqual(record.failureCode, "budget_day_changed")
            XCTAssertNil(record.networkReceivedBytes)
            XCTAssertNil(record.networkSentBytes)
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
            let client = PendingObservationTestClient(
                configurationSnapshot: configurationSnapshot(),
                captureBehaviors: [.pending, .success(.exact)],
                proofDate: startedAt,
                captureHook: { attempt in
                    guard attempt == 1,
                        var changed = try? SyncPolicyStore(url: policyURL).loadDocument()
                    else { return }
                    changed.budgetTimeZoneIdentifier = "Asia/Shanghai"
                    try? SyncPolicyStore(url: policyURL).saveDocument(changed)
                }
            )

            let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
                folderID: folderID,
                offeringDeviceID: offeringDeviceID,
                taskID: taskID,
                trigger: .user,
                paths: paths,
                environment: .permissiveForTesting,
                clock: AdvancingObservationClock(now: startedAt).value
            )

            XCTAssertEqual(outcome, .failed(code: "policyConfigurationUnavailable"))
            let originalStore = TransferAccountingStore(
                url: paths.transferAccounting,
                budgetTimeZoneIdentifier: "UTC"
            )
            XCTAssertEqual(try originalStore.usage(at: startedAt).committedBytes, 2_048)
        }
    }

    func testLiveCheapUncappedPolicyBecomingExpensiveAndCappedAbortsConservatively()
        async throws
    {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var initialPolicy = SyncPolicy()
        initialPolicy.allowExpensive = true
        initialPolicy.maxExpensiveRunBytes = nil
        initialPolicy.dailyExpensiveBytes = nil
        try savePolicy(initialPolicy, paths: paths)
        let uncappedPolicy = initialPolicy
        let initialEnvironment = SyncEnvironmentSnapshot.permissiveForTesting
        let environmentBox = LiveObservationEnvironment(initialEnvironment)
        let policyURL = paths.policy
        let client = PendingObservationTestClient(
            configurationSnapshot: configurationSnapshot(),
            captureBehaviors: [.pending, .success(.exact)],
            proofDate: startedAt,
            captureHook: { attempt in
                guard attempt == 1 else { return }
                var expensive = initialEnvironment
                expensive.network.isExpensive = true
                environmentBox.set(expensive)
                var capped = uncappedPolicy
                capped.maxExpensiveRunBytes = 1_024
                try? SyncPolicyStore(url: policyURL).save(capped)
            }
        )

        let outcome = await CoreRuntime(clientFactory: { client }).observePendingFolderOffer(
            folderID: folderID,
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: .user,
            paths: paths,
            environment: initialEnvironment,
            currentEnvironment: { environmentBox.get() },
            clock: AdvancingObservationClock(now: startedAt).value
        )

        XCTAssertEqual(outcome, .policyDenied(reasons: [.runTransferLimit]))
        XCTAssertEqual(
            try accountingStore(paths).usage(at: startedAt).committedBytes,
            PendingFolderObservationPlan.maximumAllowedNetworkBytes
        )
    }

    private func configurationSnapshot(devices: [DeviceRecord]? = nil) -> CoreSnapshot {
        CoreSnapshot(
            generation: 7,
            configurationRevision: revision,
            localDeviceID: localDeviceID,
            devices: devices ?? [DeviceRecord(id: offeringDeviceID, name: "Peer")]
        )
    }

    private func makePaths() throws -> SharedContainerPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-observation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SharedContainerPaths(root: root)
    }

    private func savePolicy(_ policy: SyncPolicy, paths: SharedContainerPaths) throws {
        try SyncPolicyStore(url: paths.policy).save(policy)
    }

    private func accountingStore(_ paths: SharedContainerPaths) throws -> TransferAccountingStore {
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
            folderID: FolderID(rawValue: "prior-accounting")!,
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

    private func syntheticObservationDigest() -> String {
        var material = Data("psy-pending-folder-observation-accounting-v1".utf8)
        for value in [folderID.rawValue, offeringDeviceID.rawValue, revision] {
            material.append(0)
            material.append(contentsOf: value.utf8)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}

private enum PendingObservationTestError: Error {
    case accountingDidNotBeginBeforeOpen
}

private enum ProofMutation: Hashable, Sendable {
    case exact
    case wrongFolder
    case wrongDevice
    case wrongRevision
    case wrongSession
}

private enum CaptureBehavior: Sendable {
    case pending
    case success(ProofMutation)
    case suspend
}

private final class AdvancingObservationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) {
        current = now
    }

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

private final class LiveObservationEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SyncEnvironmentSnapshot

    init(_ value: SyncEnvironmentSnapshot) {
        self.value = value
    }

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

private actor PendingObservationTestClient: CoreClient {
    private enum ActiveSession {
        case configuration(CoreExplicitSessionBinding)
        case observation(CoreExplicitSessionBinding, PendingFolderObservationPlan)

        var binding: CoreExplicitSessionBinding {
            switch self {
            case .configuration(let binding), .observation(let binding, _): binding
            }
        }
    }

    private let localDeviceID = DeviceID(rawValue: String(repeating: "A", count: 56))!
    private let otherDeviceID = DeviceID(rawValue: String(repeating: "C", count: 56))!
    private let configurationSnapshot: CoreSnapshot
    private let captureBehaviors: [CaptureBehavior]
    private let usedBytes: Int64
    private let proofDate: Date
    private let observationOpenProbe: (@Sendable () throws -> Void)?
    private let captureHook: (@Sendable (Int) -> Void)?
    private let observationCloseAlwaysFails: Bool
    private let totalsAvailable: Bool
    private var activeSession: ActiveSession?
    private var lastClosedPlan: PendingFolderObservationPlan?
    private var recordedEvents: [String] = []
    private var plans: [PendingFolderObservationPlan] = []
    private var captureAttempts = 0

    init(
        configurationSnapshot: CoreSnapshot,
        captureBehaviors: [CaptureBehavior],
        usedBytes: Int64 = 0,
        proofDate: Date,
        observationOpenProbe: (@Sendable () throws -> Void)? = nil,
        captureHook: (@Sendable (Int) -> Void)? = nil,
        observationCloseAlwaysFails: Bool = false,
        totalsAvailable: Bool = true
    ) {
        self.configurationSnapshot = configurationSnapshot
        self.captureBehaviors = captureBehaviors
        self.usedBytes = usedBytes
        self.proofDate = proofDate
        self.observationOpenProbe = observationOpenProbe
        self.captureHook = captureHook
        self.observationCloseAlwaysFails = observationCloseAlwaysFails
        self.totalsAvailable = totalsAvailable
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        throw CoreClientError.invalidResponse("legacy_start_used")
    }

    func openConfigurationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID
    ) async throws -> CoreExplicitSessionReceipt {
        guard activeSession == nil else { throw CoreClientError.coreRejected("session_overlap") }
        let binding = CoreExplicitSessionBinding.configuration(sessionID: sessionID)
        activeSession = .configuration(binding)
        recordedEvents.append("open:configuration")
        return try receipt(binding: binding, generation: 1)
    }

    func openPendingFolderObservationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID,
        plan: PendingFolderObservationPlan
    ) async throws -> CoreExplicitSessionReceipt {
        guard activeSession == nil else { throw CoreClientError.coreRejected("session_overlap") }
        try observationOpenProbe?()
        let binding = CoreExplicitSessionBinding.pendingFolderObservation(
            sessionID: sessionID,
            plan: plan
        )
        plans.append(plan)
        activeSession = .observation(binding, plan)
        recordedEvents.append("open:pendingFolderObservation")
        return try receipt(binding: binding, generation: 2)
    }

    func capturePendingFolderObservation() async throws
        -> PendingFolderObservationCaptureReceipt
    {
        guard case .observation(let binding, let plan) = activeSession else {
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
            throw CoreClientError.coreRejected("pending_folder_observation_pending")
        case .suspend:
            try await Task.sleep(for: .seconds(30))
            throw CoreClientError.coreRejected("unexpected_test_wakeup")
        case .success(let mutation):
            let folderID = mutation == .wrongFolder ? FolderID(rawValue: "other-folder")! : plan.folderID
            let deviceID = mutation == .wrongDevice ? otherDeviceID : plan.offeringDeviceID
            let revision =
                mutation == .wrongRevision
                ? String(repeating: "d", count: 64) : plan.expectedConfigurationRevision
            let sessionID =
                mutation == .wrongSession
                ? UUID().uuidString.lowercased() : binding.sessionIDString
            let proof = PendingFolderObservationProof(
                proofID: CoreSessionDigest.stableVersion(["proof", binding.sessionIDString]),
                folderID: folderID,
                offeringDeviceID: deviceID,
                offerVersion: CoreSessionDigest.stableVersion(["offer", plan.folderID.rawValue]),
                label: "Observed folder",
                lastSeen: proofDate,
                lastSeenWireValue: "2026-08-10T00:00:00Z",
                receiveEncrypted: false,
                remoteEncrypted: false,
                configurationRevision: revision,
                observationSessionID: sessionID,
                connectionEpoch: CoreSessionDigest.stableVersion(["connection", binding.sessionIDString]),
                observedAt: proofDate,
                observedAtWireValue: "2026-08-10T00:00:00Z",
                expiresAt: proofDate.addingTimeInterval(PendingFolderObservationProof.timeToLive),
                expiresAtWireValue: "2026-08-10T00:05:00Z"
            )
            return PendingFolderObservationCaptureReceipt(
                generation: 3,
                configurationRevision: plan.expectedConfigurationRevision,
                proof: proof
            )
        }
    }

    func closeExplicitSession() async throws -> CoreExplicitSessionReceipt {
        guard let activeSession else { throw CoreClientError.notRunning }
        switch activeSession {
        case .configuration(let binding):
            recordedEvents.append("close:configuration")
            self.activeSession = nil
            return try receipt(binding: binding, generation: 2)
        case .observation(let binding, let plan):
            if observationCloseAlwaysFails {
                recordedEvents.append("close:pendingFolderObservation:failed")
                throw CoreClientError.coreRejected("close_failed")
            }
            recordedEvents.append("close:pendingFolderObservation")
            lastClosedPlan = plan
            self.activeSession = nil
            return try receipt(binding: binding, generation: 4)
        }
    }

    func stop() async throws {
        throw CoreClientError.invalidResponse("legacy_stop_used")
    }

    func snapshot() async throws -> CoreSnapshot {
        guard case .configuration = activeSession else { throw CoreClientError.notRunning }
        recordedEvents.append("snapshot:configuration")
        return configurationSnapshot
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
    func observationPlans() -> [PendingFolderObservationPlan] { plans }
    func openedObservationCount() -> Int { plans.count }
    func captureCount() -> Int { captureAttempts }

    private func receipt(
        binding: CoreExplicitSessionBinding,
        generation: UInt64
    ) throws -> CoreExplicitSessionReceipt {
        try CoreExplicitSessionReceipt(
            binding: binding,
            deviceID: localDeviceID,
            generation: generation,
            configurationRevision: configurationSnapshot.configurationRevision!
        )
    }
}
