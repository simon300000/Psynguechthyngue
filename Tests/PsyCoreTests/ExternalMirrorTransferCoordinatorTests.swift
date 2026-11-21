import Foundation
import XCTest

@testable import PsyCore

final class ExternalMirrorTransferCoordinatorTests: XCTestCase {
    func testObservationAndApplySubgrantsSettleExactBytesAndFinishOneRun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let observation = try await fixture.prepareImport(contents: "payload")
        let store = fixture.store
        let coordinator = ExternalMirrorTransferCoordinator(store: store)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let folderID = try XCTUnwrap(FolderID(rawValue: "external-folder"))
        let taskID = UUID()
        let observationSession = try coordinator.begin(
            preparedPlan: observation,
            folderID: folderID,
            folderIncarnationDigest: String(repeating: "a", count: 64),
            taskID: taskID,
            expiresAt: now.addingTimeInterval(600),
            at: now,
            configuredRunLimitBytes: 100,
            globalDailyLimitBytes: 100,
            folderDailyLimitBytes: 100
        )
        let mirror = fixture.mirror()
        let observed = try await mirror.observeSynchronization(
            observation,
            meter: observationSession.meter
        )
        let observationReceipt = try observationSession.settleStageSuccessful(
            at: now.addingTimeInterval(1)
        )
        XCTAssertEqual(observationReceipt.chargedBytes, 7)
        let prepared = try await mirror.commitObservedPlan(observed)
        let session = try coordinator.begin(
            preparedPlan: prepared,
            folderID: folderID,
            folderIncarnationDigest: String(repeating: "a", count: 64),
            taskID: taskID,
            expiresAt: now.addingTimeInterval(600),
            at: now.addingTimeInterval(1),
            configuredRunLimitBytes: 100,
            globalDailyLimitBytes: 100,
            folderDailyLimitBytes: 100
        )
        _ = try await mirror.apply(prepared, meter: session.meter)
        let receipt = try session.settleSuccessful(at: now.addingTimeInterval(2))
        XCTAssertEqual(receipt.kind, .exact)
        XCTAssertEqual(receipt.chargedBytes, 35)
        XCTAssertEqual(receipt.grantedBytes, 35)
        XCTAssertEqual(receipt.workKind, .externalMirror)
        XCTAssertEqual(receipt.runID, prepared.runID)
        XCTAssertEqual(receipt.planDigest, prepared.planDigest)
        XCTAssertEqual(receipt.folderID, folderID)
        XCTAssertEqual(receipt.folderIncarnationDigest, String(repeating: "a", count: 64))

        let run = try store.runUsage(for: session.binding)
        XCTAssertEqual(run.committedBytes, 42)
        XCTAssertEqual(run.activeReservedBytes, 0)
        XCTAssertEqual(run.limitBytes, 100)
        XCTAssertTrue(run.isFinished)
        XCTAssertEqual(
            try session.settleSuccessful(at: now.addingTimeInterval(3)),
            receipt,
            "settlement and finish retries must be idempotent"
        )
        XCTAssertEqual(try store.usage(at: now).committedBytes, 42)
    }

    func testAuthorizedUncertainCopySettlesConservativeFullGrantIdempotently() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let prepared = try await fixture.prepareImport(contents: "uncertain")
        let coordinator = ExternalMirrorTransferCoordinator(store: fixture.store)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = try coordinator.begin(
            preparedPlan: prepared,
            folderID: try XCTUnwrap(FolderID(rawValue: "external-folder")),
            folderIncarnationDigest: String(repeating: "b", count: 64),
            taskID: UUID(),
            expiresAt: now.addingTimeInterval(600),
            at: now
        )
        let transfer = try XCTUnwrap(prepared.logicalTransfers.first)
        let meter = session.meter
        try meter.authorize(transfer)
        meter.markUncertain(transfer)

        let receipt = try session.settleFailed(at: now.addingTimeInterval(1))
        XCTAssertEqual(receipt.kind, .conservative)
        XCTAssertEqual(receipt.chargedBytes, prepared.remainingLogicalProviderBytes)
        XCTAssertEqual(
            try session.settleFailed(at: now.addingTimeInterval(2)),
            receipt
        )
        XCTAssertEqual(
            try fixture.store.usage(at: now).committedBytes,
            prepared.remainingLogicalProviderBytes
        )
        XCTAssertFalse(try fixture.store.runUsage(for: session.binding).isFinished)
    }

    func testDailyCapDeniesBeforeApplyAndLeavesNoActiveReservation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let prepared = try await fixture.prepareImport(contents: "1234567")
        let coordinator = ExternalMirrorTransferCoordinator(store: fixture.store)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertThrowsError(
            try coordinator.begin(
                preparedPlan: prepared,
                folderID: try XCTUnwrap(FolderID(rawValue: "external-folder")),
                folderIncarnationDigest: String(repeating: "c", count: 64),
                taskID: UUID(),
                expiresAt: now.addingTimeInterval(600),
                at: now,
                globalDailyLimitBytes: 6
            )
        ) { error in
            XCTAssertEqual(error as? TransferAccountingError, .dailyLimitExceeded)
        }
        XCTAssertTrue(try fixture.store.snapshot().activeReservations.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.managed.appendingPathComponent("payload.txt").path
            )
        )
    }

    func testDroppedSessionIsRecoveredAsFullGrantAfterOwnerLeaseEnds() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let prepared = try await fixture.prepareImport(contents: "crash")
        let coordinator = ExternalMirrorTransferCoordinator(store: fixture.store)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var session: ExternalMirrorTransferSession? = try coordinator.begin(
            preparedPlan: prepared,
            folderID: try XCTUnwrap(FolderID(rawValue: "external-folder")),
            folderIncarnationDigest: String(repeating: "d", count: 64),
            taskID: UUID(),
            expiresAt: now.addingTimeInterval(600),
            at: now
        )
        let reservationID = try XCTUnwrap(session?.reservation.id)
        session = nil

        let recovered = try fixture.store.recoverStaleReservations(at: now)
        XCTAssertEqual(recovered.map(\.id), [reservationID])
        XCTAssertEqual(recovered.first?.kind, .staleOwnerFullGrant)
        XCTAssertEqual(recovered.first?.chargedBytes, prepared.remainingLogicalProviderBytes)
    }
}

private struct Fixture {
    let root: URL
    let managed: URL
    let external: URL
    let ledgerURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-mirror-accounting-\(UUID().uuidString)", isDirectory: true)
        managed = root.appendingPathComponent("managed", isDirectory: true)
        external = root.appendingPathComponent("external", isDirectory: true)
        ledgerURL = root.appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    }

    var store: TransferAccountingStore {
        TransferAccountingStore(url: ledgerURL, budgetTimeZoneIdentifier: "UTC")
    }

    func mirror() -> ControlledMirror {
        ControlledMirror(
            managedRoot: managed,
            externalRoot: external,
            mode: .importOnly
        )
    }

    func prepareImport(contents: String) async throws -> ControlledMirrorPreparedPlan {
        try Data(contents.utf8).write(
            to: external.appendingPathComponent("payload.txt"),
            options: .atomic
        )
        return try await mirror().prepareSynchronization()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
