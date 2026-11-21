import Foundation
import XCTest

@testable import PsyCore

final class TransferAccountingStoreTests: XCTestCase {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testExactAndConservativeSettlementPersistGlobalFolderAndPendingHistory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TransferAccountingStore(
            url: fixture.url,
            budgetTimeZoneIdentifier: "America/Los_Angeles"
        )
        let owner = UUID()
        let firstBinding = try binding(folder: "folder", discriminator: "1")
        var secondBinding = firstBinding
        secondBinding.taskID = UUID()
        secondBinding.sessionID = UUID()
        let beforeMidnightUTC = Date(timeIntervalSince1970: 1_704_092_400)  // 2023-12-31 23:00 PST
        let expiry = beforeMidnightUTC.addingTimeInterval(3_600)

        let first = try store.reserve(
            id: firstID,
            ownerID: owner,
            binding: firstBinding,
            grantBytes: 80,
            globalDailyLimitBytes: 200,
            folderDailyLimitBytes: 200,
            expiresAt: expiry,
            at: beforeMidnightUTC
        )
        XCTAssertEqual(first.dayKey, "2023-12-31")
        XCTAssertEqual(first.state, .prepared)
        XCTAssertEqual(first.binding, firstBinding)
        XCTAssertEqual(
            try store.begin(
                reservationID: firstID,
                ownerID: owner,
                binding: firstBinding,
                at: beforeMidnightUTC
            ).state,
            .running
        )
        XCTAssertEqual(
            try store.usage(for: firstBinding, at: beforeMidnightUTC).folderActiveReservedBytes,
            80
        )
        let exact = try store.settle(
            reservationID: firstID,
            ownerID: owner,
            binding: firstBinding,
            outcome: .exact(bytes: 30),
            at: beforeMidnightUTC
        )
        XCTAssertEqual(exact.chargedBytes, 30)
        XCTAssertEqual(exact.kind, .exact)

        _ = try store.reserve(
            id: secondID,
            ownerID: owner,
            binding: secondBinding,
            grantBytes: 70,
            globalDailyLimitBytes: 200,
            folderDailyLimitBytes: 200,
            expiresAt: expiry,
            at: beforeMidnightUTC
        )
        let conservative = try store.settle(
            reservationID: secondID,
            ownerID: owner,
            binding: secondBinding,
            outcome: .conservative,
            at: beforeMidnightUTC
        )
        XCTAssertEqual(conservative.chargedBytes, 70)
        XCTAssertEqual(conservative.kind, .conservative)
        let usage = try store.usage(for: firstBinding, at: beforeMidnightUTC)
        XCTAssertEqual(usage.committedBytes, 100)
        XCTAssertEqual(usage.activeReservedBytes, 0)
        XCTAssertEqual(usage.effectiveBytes, 100)
        XCTAssertEqual(usage.folderCommittedBytes, 100)
        XCTAssertEqual(usage.folderEffectiveBytes, 100)
        XCTAssertEqual(try store.pendingHistoryProjections().map(\.id), [firstID, secondID])

        try store.acknowledgeHistoryProjection(firstID)
        XCTAssertEqual(try store.pendingHistoryProjections().map(\.id), [secondID])
        XCTAssertEqual(try store.snapshot().settledReceipts.map(\.id), [firstID, secondID])
    }

    func testStaleOrExpiredOwnerIsChargedItsFullGrantAndLiveGrantRemainsActive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        let staleOwner = UUID()
        let liveOwner = UUID()
        let staleBinding = try binding(folder: "stale", discriminator: "1")
        let liveBinding = try binding(folder: "live", discriminator: "2")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try store.reserve(
            id: firstID,
            ownerID: staleOwner,
            binding: staleBinding,
            grantBytes: 90,
            globalDailyLimitBytes: 200,
            folderDailyLimitBytes: 100,
            expiresAt: now.addingTimeInterval(100),
            at: now
        )
        _ = try store.reserve(
            id: secondID,
            ownerID: liveOwner,
            binding: liveBinding,
            grantBytes: 40,
            globalDailyLimitBytes: 200,
            folderDailyLimitBytes: 100,
            expiresAt: now.addingTimeInterval(100),
            at: now
        )

        let recovered = try store.recoverStaleReservations(
            activeOwnerIDs: [liveOwner],
            at: now.addingTimeInterval(10)
        )
        XCTAssertEqual(recovered.map(\.id), [firstID])
        XCTAssertEqual(recovered.first?.chargedBytes, 90)
        XCTAssertEqual(recovered.first?.kind, .staleOwnerFullGrant)
        let usage = try store.usage(for: staleBinding, at: now)
        XCTAssertEqual(usage.committedBytes, 90)
        XCTAssertEqual(usage.activeReservedBytes, 40)
        XCTAssertEqual(usage.effectiveBytes, 130)
        XCTAssertEqual(usage.folderCommittedBytes, 90)
        XCTAssertEqual(usage.folderActiveReservedBytes, 0)

        let expired = try store.recoverStaleReservations(
            activeOwnerIDs: [liveOwner],
            at: now.addingTimeInterval(101)
        )
        XCTAssertTrue(expired.isEmpty, "expiry cannot override a positively live owner")
        let noLongerLive = try store.recoverStaleReservations(
            activeOwnerIDs: [],
            at: now.addingTimeInterval(101)
        )
        XCTAssertEqual(noLongerLive.map(\.id), [secondID])
        XCTAssertEqual(noLongerLive.first?.chargedBytes, 40)
    }

    func testFolderAndGlobalCapsAreBothEnforcedIncludingActiveGrants() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        let owner = UUID()
        let folderA = try binding(folder: "a", discriminator: "1")
        let folderB = try binding(folder: "b", discriminator: "2")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = now.addingTimeInterval(3_600)
        let first = try store.reserve(
            ownerID: owner,
            binding: folderA,
            grantBytes: 60,
            globalDailyLimitBytes: 100,
            folderDailyLimitBytes: 100,
            expiresAt: expiry,
            at: now
        )
        _ = try store.settle(
            reservationID: first.id,
            ownerID: owner,
            binding: folderA,
            outcome: .exact(bytes: 60),
            at: now
        )

        XCTAssertThrowsError(
            try store.reserve(
                ownerID: owner,
                binding: folderA,
                grantBytes: 41,
                globalDailyLimitBytes: 200,
                folderDailyLimitBytes: 100,
                expiresAt: expiry,
                at: now
            )
        ) { error in
            XCTAssertEqual(error as? TransferAccountingError, .folderDailyLimitExceeded)
        }
        XCTAssertThrowsError(
            try store.reserve(
                ownerID: owner,
                binding: folderB,
                grantBytes: 41,
                globalDailyLimitBytes: 100,
                folderDailyLimitBytes: 100,
                expiresAt: expiry,
                at: now
            )
        ) { error in
            XCTAssertEqual(error as? TransferAccountingError, .dailyLimitExceeded)
        }
        _ = try store.reserve(
            ownerID: owner,
            binding: folderB,
            grantBytes: 40,
            globalDailyLimitBytes: 100,
            folderDailyLimitBytes: 100,
            expiresAt: expiry,
            at: now
        )
        XCTAssertEqual(try store.usage(for: folderA, at: now).folderEffectiveBytes, 60)
        XCTAssertEqual(try store.usage(for: folderB, at: now).folderEffectiveBytes, 40)
        XCTAssertEqual(try store.usage(at: now).effectiveBytes, 100)
    }

    func testSettlementReceiptSurvivesHistoryAckAndPreventsDoubleCharge() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        let owner = UUID()
        let binding = try binding(folder: "receipt", discriminator: "1")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = now.addingTimeInterval(3_600)
        _ = try store.reserve(
            id: firstID,
            ownerID: owner,
            binding: binding,
            grantBytes: 60,
            globalDailyLimitBytes: 100,
            folderDailyLimitBytes: 100,
            expiresAt: expiry,
            at: now
        )
        let receipt = try store.settle(
            reservationID: firstID,
            ownerID: owner,
            binding: binding,
            outcome: .exact(bytes: 20),
            at: now
        )
        try store.acknowledgeHistoryProjection(firstID)
        XCTAssertTrue(try store.pendingHistoryProjections().isEmpty)

        XCTAssertThrowsError(
            try store.reserve(
                id: firstID,
                ownerID: owner,
                binding: binding,
                grantBytes: 60,
                globalDailyLimitBytes: 100,
                folderDailyLimitBytes: 100,
                expiresAt: expiry,
                at: now
            )
        ) { error in
            XCTAssertEqual(error as? TransferAccountingError, .reservationIdentifierReused)
        }
        XCTAssertEqual(
            try store.settle(
                reservationID: firstID,
                ownerID: owner,
                binding: binding,
                outcome: .exact(bytes: 20),
                at: now.addingTimeInterval(1)
            ),
            receipt
        )
        XCTAssertEqual(try store.usage(at: now).committedBytes, 20)
        XCTAssertEqual(try store.snapshot().settledReceipts, [receipt])
    }

    func testSettleAndFinalizeRunIsAtomicAndIdempotentAcrossRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        let owner = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let binding = try binding(
            folder: "atomic-finalize",
            discriminator: "1",
            workKind: .externalMirror,
            taskID: UUID(),
            runID: UUID(),
            sessionID: UUID(),
            planDigest: String(repeating: "a", count: 64)
        )
        _ = try store.reserve(
            id: firstID,
            ownerID: owner,
            binding: binding,
            grantBytes: 60,
            runLimitBytes: nil,
            globalDailyLimitBytes: nil,
            folderDailyLimitBytes: nil,
            expiresAt: now.addingTimeInterval(600),
            at: now
        )
        _ = try store.begin(
            reservationID: firstID,
            ownerID: owner,
            binding: binding,
            at: now
        )

        let receipt = try store.settleAndFinalizeRun(
            reservationID: firstID,
            ownerID: owner,
            binding: binding,
            outcome: .exact(bytes: 20),
            at: now
        )
        XCTAssertEqual(
            try store.settleAndFinalizeRun(
                reservationID: firstID,
                ownerID: owner,
                binding: binding,
                outcome: .exact(bytes: 20),
                at: now.addingTimeInterval(1)
            ),
            receipt
        )
        let snapshot = try store.snapshot()
        XCTAssertTrue(snapshot.activeReservations.isEmpty)
        XCTAssertEqual(snapshot.settledReceipts, [receipt])
        XCTAssertEqual(snapshot.runUsages.count, 1)
        XCTAssertEqual(snapshot.runUsages.first?.committedBytes, 20)
        XCTAssertEqual(snapshot.runUsages.first?.finishedAt, now)

        var retry = binding
        retry.sessionID = UUID()
        XCTAssertThrowsError(
            try store.reserve(
                ownerID: owner,
                binding: retry,
                grantBytes: 1,
                runLimitBytes: nil,
                globalDailyLimitBytes: nil,
                folderDailyLimitBytes: nil,
                expiresAt: now.addingTimeInterval(600),
                at: now
            )
        ) { error in
            XCTAssertEqual(error as? TransferAccountingError, .runAlreadyFinished)
        }
    }

    func testExactSettlementCannotExceedGrantAndBindingsCannotBeSwapped() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let owner = UUID()
        let binding = try binding(folder: "exact", discriminator: "1")
        let wrong = try self.binding(folder: "exact", discriminator: "2")
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        _ = try store.reserve(
            id: firstID,
            ownerID: owner,
            binding: binding,
            grantBytes: 10,
            globalDailyLimitBytes: 20,
            folderDailyLimitBytes: 20,
            expiresAt: now.addingTimeInterval(60),
            at: now
        )
        XCTAssertThrowsError(
            try store.begin(
                reservationID: firstID,
                ownerID: owner,
                binding: wrong,
                at: now
            )
        ) { error in
            XCTAssertEqual(error as? TransferAccountingError, .reservationBindingMismatch)
        }
        XCTAssertThrowsError(
            try store.settle(
                reservationID: firstID,
                ownerID: owner,
                binding: binding,
                outcome: .exact(bytes: 11),
                at: now
            )
        ) { error in
            XCTAssertEqual(error as? TransferAccountingError, .exactBytesExceedGrant)
        }
    }

    func testPersistedTimezoneCannotBeChangedToResetBudget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        _ = try store.reserve(
            ownerID: UUID(),
            binding: binding(folder: "zone", discriminator: "1"),
            grantBytes: 1,
            globalDailyLimitBytes: 10,
            folderDailyLimitBytes: 10,
            expiresAt: now.addingTimeInterval(60),
            at: now
        )

        let changedZone = TransferAccountingStore(
            url: fixture.url,
            budgetTimeZoneIdentifier: "Pacific/Auckland"
        )
        XCTAssertThrowsError(try changedZone.usage(at: now)) { error in
            XCTAssertEqual(
                error as? TransferAccountingError,
                .budgetTimeZoneMismatch(expected: "Pacific/Auckland", actual: "UTC")
            )
        }
        XCTAssertThrowsError(
            try TransferAccountingStore(
                url: fixture.root.appendingPathComponent("invalid.json"),
                budgetTimeZoneIdentifier: "Current/Guess"
            ).usage(at: now)
        ) { error in
            XCTAssertEqual(
                error as? TransferAccountingError,
                .invalidBudgetTimeZoneIdentifier("Current/Guess")
            )
        }
    }

    func testSymlinkDirectoryAndTruncatedLedgerAreRejectedWithoutReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let outside = fixture.root.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: outside)
        XCTAssertThrowsError(try store.usage(at: now))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))

        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.usage(at: now))
        XCTAssertTrue(try fixture.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)

        try FileManager.default.removeItem(at: fixture.url)
        let truncated = Data("{\"schemaVersion\":1,\"budgetTimeZoneIdentifier\":\"UTC\"".utf8)
        try truncated.write(to: fixture.url)
        XCTAssertThrowsError(try store.usage(at: now))
        XCTAssertEqual(try Data(contentsOf: fixture.url), truncated)
    }

    func testCanonicalLedgerOrderingAndMonotonicGrantSequenceAreStable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        let owner = UUID()
        let later = Date(timeIntervalSince1970: 1_700_000_000)
        let earlier = later.addingTimeInterval(-86_400)
        let laterReservation = try store.reserve(
            ownerID: owner,
            binding: binding(folder: "z", discriminator: "1"),
            grantBytes: 2,
            globalDailyLimitBytes: nil,
            folderDailyLimitBytes: nil,
            expiresAt: later.addingTimeInterval(3_600),
            at: later
        )
        let earlierBinding = try binding(folder: "a", discriminator: "2")
        let earlierReservation = try store.reserve(
            ownerID: owner,
            binding: earlierBinding,
            grantBytes: 1,
            globalDailyLimitBytes: nil,
            folderDailyLimitBytes: nil,
            expiresAt: earlier.addingTimeInterval(3_600),
            at: earlier
        )
        XCTAssertGreaterThan(earlierReservation.grantSequence, laterReservation.grantSequence)
        _ = try store.settle(
            reservationID: earlierReservation.id,
            ownerID: owner,
            binding: earlierBinding,
            outcome: .conservative,
            at: later
        )

        let first = try Data(contentsOf: fixture.url)
        let snapshot = try store.snapshot()
        try store.replaceForTesting(snapshot)
        XCTAssertEqual(try Data(contentsOf: fixture.url), first)
        XCTAssertEqual(snapshot.dayBuckets.map(\.dayKey), snapshot.dayBuckets.map(\.dayKey).sorted())
        XCTAssertEqual(
            snapshot.activeReservations.map(\.grantSequence),
            snapshot.activeReservations.map(\.grantSequence).sorted()
        )
        XCTAssertEqual(
            snapshot.settledReceipts.map(\.grantSequence),
            snapshot.settledReceipts.map(\.grantSequence).sorted()
        )
        XCTAssertEqual(
            snapshot.pendingHistoryProjections.map(\.grantSequence),
            snapshot.pendingHistoryProjections.map(\.grantSequence).sorted()
        )
    }

    func testRunLimitSurvivesAcrossSessionsAndCannotBeRaisedByRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        let owner = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let taskID = UUID()
        let runID = UUID()
        let planDigest = String(repeating: "a", count: 64)
        let firstBinding = try binding(
            folder: "run-limit",
            discriminator: "1",
            workKind: .externalMirror,
            taskID: taskID,
            runID: runID,
            sessionID: UUID(),
            planDigest: planDigest
        )
        var retryBinding = firstBinding
        retryBinding.sessionID = UUID()

        let first = try store.reserve(
            ownerID: owner,
            binding: firstBinding,
            grantBytes: 60,
            runLimitBytes: 100,
            globalDailyLimitBytes: nil,
            folderDailyLimitBytes: nil,
            expiresAt: now.addingTimeInterval(600),
            at: now
        )
        _ = try store.settle(
            reservationID: first.id,
            ownerID: owner,
            binding: firstBinding,
            outcome: .exact(bytes: 60),
            at: now
        )

        XCTAssertThrowsError(
            try store.reserve(
                ownerID: owner,
                binding: retryBinding,
                grantBytes: 41,
                runLimitBytes: 200,
                globalDailyLimitBytes: nil,
                folderDailyLimitBytes: nil,
                expiresAt: now.addingTimeInterval(600),
                at: now
            )
        ) { error in
            XCTAssertEqual(error as? TransferAccountingError, .runLimitExceeded)
        }
        let retryReservationID = UUID()
        let retryReservation = try store.reserve(
            id: retryReservationID,
            ownerID: owner,
            binding: retryBinding,
            grantBytes: 40,
            runLimitBytes: 200,
            globalDailyLimitBytes: nil,
            folderDailyLimitBytes: nil,
            expiresAt: now.addingTimeInterval(600),
            at: now
        )
        XCTAssertEqual(
            try store.reserve(
                id: retryReservationID,
                ownerID: owner,
                binding: retryBinding,
                grantBytes: 40,
                runLimitBytes: 200,
                globalDailyLimitBytes: nil,
                folderDailyLimitBytes: nil,
                expiresAt: now.addingTimeInterval(600),
                at: now
            ),
            retryReservation,
            "a retry reuses the first durable effective run limit"
        )
        let runUsage = try store.runUsage(for: retryBinding)
        XCTAssertEqual(runUsage.committedBytes, 60)
        XCTAssertEqual(runUsage.activeReservedBytes, 40)
        XCTAssertEqual(runUsage.effectiveBytes, 100)
        XCTAssertEqual(runUsage.limitBytes, 100)
    }

    func testUnlimitedRunPersistsBindingAndCommittedBytesBeforeLaterCapTightening() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        let owner = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let taskID = UUID()
        let runID = UUID()
        let firstBinding = try binding(
            folder: "unlimited-run",
            discriminator: "4",
            workKind: .coreNetwork,
            taskID: taskID,
            runID: runID,
            sessionID: UUID(),
            planDigest: String(repeating: "a", count: 64)
        )
        let first = try store.reserve(
            ownerID: owner,
            binding: firstBinding,
            grantBytes: 60,
            runLimitBytes: nil,
            globalDailyLimitBytes: nil,
            folderDailyLimitBytes: nil,
            expiresAt: now.addingTimeInterval(600),
            at: now
        )
        _ = try store.settle(
            reservationID: first.id,
            ownerID: owner,
            binding: firstBinding,
            outcome: .exact(bytes: 60),
            at: now
        )

        let persisted = try store.runUsage(for: firstBinding)
        XCTAssertEqual(persisted.committedBytes, 60)
        XCTAssertNil(persisted.limitBytes)

        var tightened = firstBinding
        tightened.sessionID = UUID()
        XCTAssertThrowsError(
            try store.reserve(
                ownerID: owner,
                binding: tightened,
                grantBytes: 0,
                runLimitBytes: 50,
                globalDailyLimitBytes: nil,
                folderDailyLimitBytes: nil,
                expiresAt: now.addingTimeInterval(600),
                at: now
            )
        ) { error in
            XCTAssertEqual(error as? TransferAccountingError, .runLimitExceeded)
        }

        var rebound = tightened
        rebound.planDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(
            try store.reserve(
                ownerID: owner,
                binding: rebound,
                grantBytes: 1,
                runLimitBytes: nil,
                globalDailyLimitBytes: nil,
                folderDailyLimitBytes: nil,
                expiresAt: now.addingTimeInterval(600),
                at: now
            )
        ) { error in
            XCTAssertEqual(error as? TransferAccountingError, .runBindingMismatch)
        }
    }

    func testVersionOneLedgerMigratesToVersionTwoWithoutInventingRunUsage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacy = Data(
            """
            {"activeReservations":[],"budgetTimeZoneIdentifier":"UTC","dayBuckets":[],"nextGrantSequence":1,"pendingHistoryProjections":[],"schemaVersion":1,"settledReceipts":[]}
            """.utf8
        )
        try legacy.write(to: fixture.url)
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")

        let migrated = try store.snapshot()
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertTrue(migrated.runUsages.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.url), legacy, "reads do not rewrite the ledger")

        try store.replaceForTesting(migrated)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any]
        )
        XCTAssertEqual(persisted["schemaVersion"] as? Int, 2)
        XCTAssertNotNil(persisted["runUsages"])
    }

    func testOwnerLivenessLeaseProtectsExternalReservationFromLegacyRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lease = try TransferAccountingOwnerLease.acquire(
            directoryURL: store.ownerLeaseDirectoryURL,
            ownerID: UUID()
        )
        defer { lease.release() }
        let binding = try binding(
            folder: "live-external",
            discriminator: "2",
            workKind: .externalMirror,
            taskID: UUID(),
            runID: UUID(),
            sessionID: UUID(),
            planDigest: String(repeating: "b", count: 64)
        )
        _ = try store.reserve(
            id: firstID,
            ownerID: lease.ownerID,
            binding: binding,
            grantBytes: 90,
            runLimitBytes: 90,
            globalDailyLimitBytes: nil,
            folderDailyLimitBytes: nil,
            expiresAt: now.addingTimeInterval(600),
            at: now
        )

        XCTAssertTrue(
            try store.recoverStaleReservations(activeOwnerIDs: [], at: now).isEmpty
        )
        XCTAssertTrue(
            try store.recoverStaleReservations(
                activeOwnerIDs: [],
                at: now.addingTimeInterval(601)
            ).isEmpty,
            "a held liveness lease remains authoritative after reservation expiry"
        )
        XCTAssertTrue(
            try TransferAccountingOwnerLease.isLive(
                ownerID: lease.ownerID,
                directoryURL: store.ownerLeaseDirectoryURL
            ))
        lease.release()
        XCTAssertEqual(
            try store.recoverStaleReservations(at: now).map(\.id),
            [firstID]
        )
    }

    func test4096ZeroByteTerminalFailuresCannotExhaustLedgerCapacity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TransferAccountingStore(url: fixture.url, budgetTimeZoneIdentifier: "UTC")
        let owner = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let folderID = try XCTUnwrap(FolderID(rawValue: "terminal-failures"))
        let exactRunID = UUID()
        let exactBinding = TransferAccountingGrantBinding(
            workKind: .externalMirror,
            folderID: folderID,
            folderIncarnationDigest: String(repeating: "a", count: 64),
            taskID: exactRunID,
            runID: exactRunID,
            sessionID: UUID(),
            planDigest: String(repeating: "c", count: 64)
        )
        let exactReservation = try store.reserve(
            ownerID: owner,
            binding: exactBinding,
            grantBytes: 5,
            globalDailyLimitBytes: 100,
            folderDailyLimitBytes: 100,
            expiresAt: now.addingTimeInterval(600),
            at: now
        )
        _ = try store.begin(
            reservationID: exactReservation.id,
            ownerID: owner,
            binding: exactBinding,
            at: now
        )
        let exactReceipt = try store.settleTerminalFailureAndFinalizeRun(
            reservationID: exactReservation.id,
            ownerID: owner,
            binding: exactBinding,
            outcome: .exact(bytes: 3),
            at: now.addingTimeInterval(0.000_01)
        )
        let conservativeRunID = UUID()
        let conservativeBinding = TransferAccountingGrantBinding(
            workKind: .externalMirror,
            folderID: folderID,
            folderIncarnationDigest: String(repeating: "a", count: 64),
            taskID: conservativeRunID,
            runID: conservativeRunID,
            sessionID: UUID(),
            planDigest: String(repeating: "d", count: 64)
        )
        let conservativeReservation = try store.reserve(
            ownerID: owner,
            binding: conservativeBinding,
            grantBytes: 4,
            globalDailyLimitBytes: 100,
            folderDailyLimitBytes: 100,
            expiresAt: now.addingTimeInterval(600),
            at: now
        )
        _ = try store.begin(
            reservationID: conservativeReservation.id,
            ownerID: owner,
            binding: conservativeBinding,
            at: now
        )
        let conservativeReceipt = try store.settleTerminalFailureAndFinalizeRun(
            reservationID: conservativeReservation.id,
            ownerID: owner,
            binding: conservativeBinding,
            outcome: .conservative,
            at: now.addingTimeInterval(0.000_02)
        )

        for ordinal in 0...TransferAccountingStore.maximumEntriesPerSection {
            let runID = UUID()
            let binding = TransferAccountingGrantBinding(
                workKind: .externalMirror,
                folderID: folderID,
                folderIncarnationDigest: String(repeating: "a", count: 64),
                taskID: runID,
                runID: runID,
                sessionID: UUID(),
                planDigest: String(repeating: "b", count: 64)
            )
            let attemptedAt = now.addingTimeInterval(Double(ordinal) / 10_000)
            let reservation = try store.reserve(
                ownerID: owner,
                binding: binding,
                grantBytes: 0,
                globalDailyLimitBytes: 100,
                folderDailyLimitBytes: 100,
                expiresAt: attemptedAt.addingTimeInterval(600),
                at: attemptedAt
            )
            _ = try store.begin(
                reservationID: reservation.id,
                ownerID: owner,
                binding: binding,
                at: attemptedAt
            )
            let receipt = try store.settleTerminalFailureAndFinalizeRun(
                reservationID: reservation.id,
                ownerID: owner,
                binding: binding,
                outcome: .exact(bytes: 0),
                at: attemptedAt.addingTimeInterval(0.000_01)
            )
            XCTAssertEqual(receipt.kind, .terminalFailureExact)
        }

        let tombstoneRunID = UUID()
        let tombstoneBinding = TransferAccountingGrantBinding(
            workKind: .externalMirror,
            folderID: folderID,
            folderIncarnationDigest: String(repeating: "a", count: 64),
            taskID: tombstoneRunID,
            runID: tombstoneRunID,
            sessionID: UUID(),
            planDigest: String(repeating: "e", count: 64)
        )
        let tombstoneReservation = try store.reserve(
            ownerID: owner,
            binding: tombstoneBinding,
            grantBytes: 0,
            globalDailyLimitBytes: 100,
            folderDailyLimitBytes: 100,
            expiresAt: now.addingTimeInterval(601),
            at: now.addingTimeInterval(1)
        )
        _ = try store.begin(
            reservationID: tombstoneReservation.id,
            ownerID: owner,
            binding: tombstoneBinding,
            at: now.addingTimeInterval(1)
        )
        _ = try store.settleTerminalFailureAndFinalizeRun(
            reservationID: tombstoneReservation.id,
            ownerID: owner,
            binding: tombstoneBinding,
            outcome: .exact(bytes: 0),
            at: now.addingTimeInterval(1.000_01)
        )

        let snapshot = try store.snapshot()
        XCTAssertLessThanOrEqual(snapshot.settledReceipts.count, 66)
        XCTAssertTrue(snapshot.settledReceipts.contains(exactReceipt))
        XCTAssertTrue(snapshot.settledReceipts.contains(conservativeReceipt))
        XCTAssertEqual(
            snapshot.pendingHistoryProjections.map(\.id),
            [exactReceipt.id, conservativeReceipt.id]
        )
        XCTAssertTrue(snapshot.activeReservations.isEmpty)
        XCTAssertEqual(snapshot.runUsages.count, 2)

        XCTAssertThrowsError(
            try store.settleTerminalFailureAndFinalizeRun(
                reservationID: tombstoneReservation.id,
                ownerID: owner,
                binding: tombstoneBinding,
                outcome: .conservative,
                at: now.addingTimeInterval(2)
            )
        ) {
            XCTAssertEqual($0 as? TransferAccountingError, .settlementConflict)
        }
        var reboundBinding = tombstoneBinding
        reboundBinding.sessionID = UUID()
        reboundBinding.planDigest = String(repeating: "f", count: 64)
        XCTAssertThrowsError(
            try store.reserve(
                ownerID: owner,
                binding: reboundBinding,
                grantBytes: 0,
                globalDailyLimitBytes: 100,
                folderDailyLimitBytes: 100,
                expiresAt: now.addingTimeInterval(602),
                at: now.addingTimeInterval(2)
            )
        ) {
            XCTAssertEqual($0 as? TransferAccountingError, .runBindingMismatch)
        }
    }

    private func binding(
        folder: String,
        discriminator: Character,
        workKind: TransferAccountingWorkKind = .coreNetwork,
        taskID: UUID = UUID(),
        runID: UUID? = nil,
        sessionID: UUID = UUID(),
        planDigest: String? = nil
    ) throws -> TransferAccountingGrantBinding {
        let folderID = try XCTUnwrap(FolderID(rawValue: folder))
        let scalar = String(discriminator)
        return TransferAccountingGrantBinding(
            workKind: workKind,
            folderID: folderID,
            folderIncarnationDigest: String(repeating: scalar, count: 64),
            taskID: taskID,
            runID: runID ?? sessionID,
            sessionID: sessionID,
            planDigest: planDigest
                ?? String(repeating: scalar == "f" ? "e" : scalar, count: 64)
        )
    }
}

private struct Fixture {
    let root: URL
    let url: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-accounting-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
