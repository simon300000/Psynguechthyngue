import Darwin
import Foundation
import XCTest

@testable import PsyCore

final class ControlledMirrorTests: XCTestCase {
    func testUserStignoreIsOpaquePayloadAndImportsByteForByte() async throws {
        let roots = try makeRoots()
        let original = Data("# user-owned\n(?d)private/**\n!private/keep.txt\n".utf8)
        try original.write(to: roots.external.appendingPathComponent(".stignore"))
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly
        )

        _ = try await mirror.synchronize()

        XCTAssertEqual(
            try Data(contentsOf: roots.managed.appendingPathComponent(".stignore")),
            original
        )
        XCTAssertEqual(
            try Data(contentsOf: roots.external.appendingPathComponent(".stignore")),
            original
        )
    }

    func testPrepareSynchronizationIsMetadataOnlyBeforeAccountingBegins() async throws {
        let roots = try makeRoots()
        try write("provider payload", to: roots.external.appendingPathComponent("payload.txt"))
        let reads = PayloadReadCounter()
        let base = ControlledMirrorIO.coordinated
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly,
            io: ControlledMirrorIO(
                readData: {
                    reads.record($0)
                    return try base.readData(at: $0)
                },
                writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
                createDirectory: { try base.createDirectory(at: $0) },
                copyFileAtomically: {
                    try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2)
                },
                removeItem: { try base.removeItem(at: $0) }
            )
        )

        let prepared = try await mirror.prepareSynchronization()

        XCTAssertEqual(reads.count, 0, "prepare must not read provider or managed payload")
        XCTAssertEqual(prepared.maximumLogicalProviderBytes, 16)
    }

    func testObservationAndApplyMeterEveryProviderPayloadEvent() async throws {
        let roots = try makeRoots()
        try write("payload", to: roots.external.appendingPathComponent("payload.txt"))
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly
        )

        let observation = try await mirror.prepareSynchronization()
        XCTAssertEqual(observation.stage, .observation)
        XCTAssertEqual(observation.maximumLogicalProviderBytes, 7)
        XCTAssertEqual(observation.remainingLogicalProviderBytes, 7)
        XCTAssertEqual(observation.logicalTransfers.count, 1)
        XCTAssertEqual(observation.logicalTransfers.first?.direction, .readExternalProvider)
        XCTAssertEqual(observation.logicalTransfers.first?.eventKey, "observation:external:payload.txt")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: roots.managed.appendingPathComponent("payload.txt").path
            ),
            "metadata prepare must neither read nor apply payload bytes"
        )

        let recorder = LogicalTransferRecorder()
        let observed = try await mirror.observeSynchronization(
            observation,
            meter: ControlledMirrorTransferMeter(
                authorize: { recorder.authorize($0) },
                complete: { recorder.complete($0) },
                markUncertain: { recorder.markUncertain($0) }
            )
        )
        let prepared = try await mirror.commitObservedPlan(observed)
        XCTAssertEqual(prepared.stage, .apply)
        XCTAssertEqual(prepared.logicalTransfers.count, 5)
        XCTAssertEqual(
            prepared.logicalTransfers.filter { $0.direction == .fromExternalProvider }.count,
            1
        )
        XCTAssertEqual(
            prepared.logicalTransfers.filter { $0.direction == .readExternalProvider }.count,
            4
        )
        XCTAssertEqual(Set(prepared.logicalTransfers.map(\.eventKey)).count, 5)
        let result = try await mirror.apply(
            prepared,
            meter: ControlledMirrorTransferMeter(
                authorize: { recorder.authorize($0) },
                complete: { recorder.complete($0) },
                markUncertain: { recorder.markUncertain($0) }
            )
        )
        XCTAssertEqual(result.copiedToManaged, 1)
        XCTAssertEqual(
            recorder.authorized,
            observation.logicalTransfers + prepared.logicalTransfers
        )
        XCTAssertEqual(
            recorder.completed,
            observation.logicalTransfers + prepared.logicalTransfers
        )
        XCTAssertTrue(recorder.uncertain.isEmpty)

        let noOpObservation = try await mirror.prepareSynchronization()
        XCTAssertEqual(noOpObservation.maximumLogicalProviderBytes, 7)
        let noOpObserved = try await mirror.observeSynchronization(
            noOpObservation,
            meter: ControlledMirrorTransferMeter(
                authorize: { recorder.authorize($0) },
                complete: { recorder.complete($0) },
                markUncertain: { recorder.markUncertain($0) }
            )
        )
        let noOp = try await mirror.commitObservedPlan(noOpObserved)
        XCTAssertEqual(noOp.maximumLogicalProviderBytes, 7)
        XCTAssertEqual(noOp.logicalTransfers.map(\.eventKey), ["final:external:payload.txt"])
        _ = try await mirror.apply(
            noOp,
            meter: ControlledMirrorTransferMeter(
                authorize: { recorder.authorize($0) },
                complete: { recorder.complete($0) },
                markUncertain: { recorder.markUncertain($0) }
            )
        )
        XCTAssertEqual(recorder.authorized.count, 8)
        XCTAssertEqual(recorder.completed.count, 8)
    }

    func testMetadataObservationGetsFreshRunIdentityAcrossMirrorInstances() async throws {
        let roots = try makeRoots()
        try write("stable", to: roots.external.appendingPathComponent("stable.txt"))
        let firstMirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly
        )
        let first = try await firstMirror.prepareSynchronization()
        let restarted = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly
        )
        let second = try await restarted.prepareSynchronization()

        XCTAssertEqual(first.stage, .observation)
        XCTAssertEqual(second.stage, .observation)
        XCTAssertNotEqual(second.runID, first.runID)
        XCTAssertNotEqual(second.planDigest, first.planDigest)
        XCTAssertEqual(second.maximumLogicalProviderBytes, first.maximumLogicalProviderBytes)
        XCTAssertEqual(second.logicalTransfers.map(\.byteCount), first.logicalTransfers.map(\.byteCount))
    }

    func testExportAndReplacePlansMeterWriteProbesInstalledAndFinalScan() async throws {
        let roots = try makeRoots()
        let managed = roots.managed.appendingPathComponent("export.txt")
        try write("payload", to: managed)
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .exportOnly
        )

        let initialObservation = try await mirror.prepareSynchronization()
        XCTAssertTrue(initialObservation.logicalTransfers.isEmpty)
        let initialObserved = try await mirror.observeSynchronization(
            initialObservation,
            meter: .unmetered
        )
        let initialApply = try await mirror.commitObservedPlan(initialObserved)
        XCTAssertEqual(initialApply.logicalTransfers.count, 9)
        XCTAssertEqual(initialApply.logicalTransfers.filter { $0.direction == .toExternalProvider }.count, 1)
        XCTAssertEqual(initialApply.logicalTransfers.filter { $0.direction == .readExternalProvider }.count, 8)
        XCTAssertEqual(Set(initialApply.logicalTransfers.map(\.eventKey)).count, 9)
        XCTAssertEqual(
            initialApply.logicalTransfers.reduce(Int64(0)) { $0 + $1.byteCount },
            initialApply.maximumLogicalProviderBytes
        )
        let initialRecorder = LogicalTransferRecorder()
        _ = try await mirror.apply(
            initialApply,
            meter: ControlledMirrorTransferMeter(
                authorize: { initialRecorder.authorize($0) },
                complete: { initialRecorder.complete($0) },
                markUncertain: { initialRecorder.markUncertain($0) }
            )
        )
        XCTAssertEqual(initialRecorder.authorized, initialRecorder.completed)
        XCTAssertEqual(initialRecorder.authorized.count, 6)
        XCTAssertTrue(Set(initialRecorder.authorized).isSubset(of: Set(initialApply.logicalTransfers)))
        XCTAssertEqual(
            initialRecorder.authorized.filter { $0.eventKey.contains(":io:incoming-read:") }.count,
            3
        )
        XCTAssertFalse(
            initialRecorder.authorized.contains { $0.eventKey.contains(":destination-preflight:") }
        )
        XCTAssertTrue(initialRecorder.uncertain.isEmpty)

        try write("updated", to: managed)
        let replaceObservation = try await mirror.prepareSynchronization()
        XCTAssertEqual(replaceObservation.logicalTransfers.count, 1)
        let replaceObserved = try await mirror.observeSynchronization(
            replaceObservation,
            meter: .unmetered
        )
        let replaceApply = try await mirror.commitObservedPlan(replaceObserved)
        XCTAssertEqual(replaceApply.logicalTransfers.count, 14)
        XCTAssertEqual(replaceApply.logicalTransfers.filter { $0.direction == .toExternalProvider }.count, 1)
        XCTAssertEqual(replaceApply.logicalTransfers.filter { $0.direction == .readExternalProvider }.count, 13)
        XCTAssertEqual(Set(replaceApply.logicalTransfers.map(\.eventKey)).count, 14)
        XCTAssertEqual(
            replaceApply.logicalTransfers.reduce(Int64(0)) { $0 + $1.byteCount },
            replaceApply.maximumLogicalProviderBytes
        )
        let replaceRecorder = LogicalTransferRecorder()
        _ = try await mirror.apply(
            replaceApply,
            meter: ControlledMirrorTransferMeter(
                authorize: { replaceRecorder.authorize($0) },
                complete: { replaceRecorder.complete($0) },
                markUncertain: { replaceRecorder.markUncertain($0) }
            )
        )
        XCTAssertEqual(replaceRecorder.authorized, replaceRecorder.completed)
        XCTAssertEqual(replaceRecorder.authorized.count, 11)
        XCTAssertTrue(Set(replaceRecorder.authorized).isSubset(of: Set(replaceApply.logicalTransfers)))
        XCTAssertEqual(
            replaceRecorder.authorized.filter { $0.eventKey.contains(":io:incoming-read:") }.count,
            3
        )
        XCTAssertEqual(
            replaceRecorder.authorized.filter { $0.eventKey.contains(":io:old-read:") }.count,
            4
        )
        XCTAssertFalse(
            replaceRecorder.authorized.contains { $0.eventKey.contains(":io:resume-old-read:") }
        )
        XCTAssertTrue(replaceRecorder.uncertain.isEmpty)
        XCTAssertEqual(
            try String(
                contentsOf: roots.external.appendingPathComponent("export.txt"),
                encoding: .utf8
            ),
            "updated"
        )
    }

    func testReplacePlanSeparatesIncomingOldAndResumePayloadBounds() async throws {
        let roots = try makeRoots()
        let managed = roots.managed.appendingPathComponent("sized.txt")
        let external = roots.external.appendingPathComponent("sized.txt")
        try write(String(repeating: "D", count: 29), to: managed)
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .exportOnly
        )
        _ = try await mirror.synchronize()
        try write("SOURCE!", to: managed)
        XCTAssertEqual(try Data(contentsOf: external).count, 29)

        let observation = try await mirror.prepareSynchronization()
        let observed = try await mirror.observeSynchronization(observation, meter: .unmetered)
        let apply = try await mirror.commitObservedPlan(observed)
        let incoming = apply.logicalTransfers.filter { $0.eventKey.contains(":io:incoming-read:") }
        let old = apply.logicalTransfers.filter { $0.eventKey.contains(":io:old-read:") }
        let resume = apply.logicalTransfers.filter { $0.eventKey.contains(":io:resume-old-read:") }

        XCTAssertEqual(incoming.count, 5)
        XCTAssertTrue(incoming.allSatisfy { $0.byteCount == 7 })
        XCTAssertEqual(old.count, 4)
        XCTAssertTrue(old.allSatisfy { $0.byteCount == 29 })
        XCTAssertEqual(resume.count, 1)
        XCTAssertEqual(resume.only?.byteCount, 29)
        XCTAssertGreaterThanOrEqual(
            apply.maximumLogicalProviderBytes,
            8 * 7 + 6 * 29,
            "the finite grant must cover success, rollback, and restart recovery branches"
        )

        let recorder = LogicalTransferRecorder()
        _ = try await mirror.apply(
            apply,
            meter: ControlledMirrorTransferMeter(
                authorize: { recorder.authorize($0) },
                complete: { recorder.complete($0) },
                markUncertain: { recorder.markUncertain($0) }
            )
        )
        XCTAssertEqual(recorder.authorized, recorder.completed)
        XCTAssertTrue(recorder.uncertain.isEmpty)
        XCTAssertEqual(
            recorder.completed.filter { $0.eventKey.contains(":io:incoming-read:") }
                .map(\.byteCount),
            [7, 7, 7]
        )
        XCTAssertEqual(
            recorder.completed.filter { $0.eventKey.contains(":io:old-read:") }
                .map(\.byteCount),
            [29, 29, 29, 29]
        )
        XCTAssertFalse(
            recorder.completed.contains { $0.eventKey.contains(":io:resume-old-read:") }
        )
        XCTAssertLessThanOrEqual(
            recorder.completed.reduce(Int64(0)) { $0 + $1.byteCount },
            apply.maximumLogicalProviderBytes
        )
    }

    func testEveryProviderPayloadIOHasOneActiveSemanticEvent() async throws {
        let roots = try makeRoots()
        let managed = roots.managed.appendingPathComponent("active-event.txt")
        try write(String(repeating: "D", count: 31), to: managed)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .exportOnly
        )
        _ = try await baseline.synchronize()
        try write("SOURCE!", to: managed)

        let recorder = LogicalTransferRecorder()
        let base = ControlledMirrorIO.coordinated
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: {
                try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2)
            },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            afterAtomicCopySwap: { _, _, _ in recorder.recordOpaqueCallback() },
            beforeProviderPayloadIO: { recorder.recordProviderPayloadIO($0) }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .exportOnly,
            io: io
        )
        let meter = ControlledMirrorTransferMeter(
            authorize: { recorder.authorize($0) },
            complete: { recorder.complete($0) },
            markUncertain: { recorder.markUncertain($0) }
        )

        let observation = try await mirror.prepareSynchronization()
        let observed = try await mirror.observeSynchronization(observation, meter: meter)
        let apply = try await mirror.commitObservedPlan(observed)
        _ = try await mirror.apply(apply, meter: meter)

        XCTAssertFalse(recorder.hasInvalidActiveEvent)
        XCTAssertEqual(recorder.activeCount, 0)
        XCTAssertEqual(recorder.providerPayloadIO, recorder.completed)
        XCTAssertEqual(Set(recorder.providerPayloadIO.map(\.id)).count, recorder.providerPayloadIO.count)
        XCTAssertTrue(
            Set(recorder.completed).isSubset(
                of: Set(observation.logicalTransfers + apply.logicalTransfers)
            )
        )
        let applyCompleted = recorder.completed.filter { !$0.eventKey.hasPrefix("observation:") }
        XCTAssertLessThanOrEqual(
            applyCompleted.reduce(Int64(0)) { $0 + $1.byteCount },
            apply.maximumLogicalProviderBytes
        )
    }

    func testMissingExternalInstallRollbackUsesOnlyStartedIncomingEvents() async throws {
        let roots = try makeRoots()
        let managed = roots.managed.appendingPathComponent("install-rollback.txt")
        try write("SOURCE!", to: managed)
        let recorder = LogicalTransferRecorder()
        let mutateOnce = FailOnce()
        let diagnostics = AtomicCopyDiagnosticRecorder()
        let base = ControlledMirrorIO.coordinated
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: {
                try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2)
            },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            beforeProviderPayloadIO: { transfer in
                recorder.recordProviderPayloadIO(transfer)
                guard transfer.eventKey.contains(":io:incoming-read:2"),
                    mutateOnce.shouldFail()
                else {
                    return
                }
                try Data("CHANGED".utf8).write(to: managed, options: .atomic)
            },
            atomicCopyDiagnostic: { stage, code in
                if stage == .rollbackInstall {
                    recorder.recordOpaqueCallback()
                }
                diagnostics.record(stage: stage, code: code)
            }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .exportOnly,
            io: io
        )
        let meter = ControlledMirrorTransferMeter(
            authorize: { recorder.authorize($0) },
            complete: { recorder.complete($0) },
            markUncertain: { recorder.markUncertain($0) }
        )
        let observation = try await mirror.prepareSynchronization()
        let observed = try await mirror.observeSynchronization(observation, meter: meter)
        let apply = try await mirror.commitObservedPlan(observed)

        do {
            _ = try await mirror.apply(apply, meter: meter)
            XCTFail("a managed source mutation after install must trigger the install rollback")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .sourceChangedDuringRun)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: roots.external.appendingPathComponent("install-rollback.txt").path
            )
        )
        XCTAssertTrue(diagnostics.stages.contains(.rollbackInstall))
        XCTAssertFalse(recorder.hasInvalidActiveEvent)
        XCTAssertEqual(recorder.activeCount, 0)
        XCTAssertEqual(recorder.providerPayloadIO, recorder.completed)
        XCTAssertTrue(recorder.uncertain.isEmpty)
        XCTAssertEqual(
            recorder.completed.filter { $0.eventKey.contains(":io:incoming-read:") }.count,
            5
        )
        XCTAssertEqual(
            recorder.completed.filter { $0.direction == .toExternalProvider }.count,
            1
        )
        XCTAssertLessThanOrEqual(
            recorder.completed.reduce(Int64(0)) { $0 + $1.byteCount },
            apply.maximumLogicalProviderBytes
        )
    }

    func testExternalToExternalConflictCopyMetersSourceWriteAndEveryProbeSeparately() async throws {
        let roots = try makeRoots()
        let managed = roots.managed.appendingPathComponent("conflict.txt")
        let external = roots.external.appendingPathComponent("conflict.txt")
        try write("base", to: managed)
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .exportOnly
        )
        _ = try await mirror.synchronize()
        try write("SOURCE!", to: managed)
        try write(String(repeating: "D", count: 29), to: external)

        let observation = try await mirror.prepareSynchronization()
        let observed = try await mirror.observeSynchronization(observation, meter: .unmetered)
        let apply = try await mirror.commitObservedPlan(observed)

        XCTAssertEqual(apply.logicalTransfers.count, 28)
        XCTAssertEqual(apply.logicalTransfers.filter { $0.direction == .fromExternalProvider }.count, 1)
        XCTAssertEqual(apply.logicalTransfers.filter { $0.direction == .toExternalProvider }.count, 2)
        XCTAssertEqual(apply.logicalTransfers.filter { $0.direction == .readExternalProvider }.count, 25)
        XCTAssertTrue(apply.logicalTransfers.allSatisfy { $0.direction != .withinExternalProvider })
        XCTAssertEqual(Set(apply.logicalTransfers.map(\.eventKey)).count, 28)
        XCTAssertEqual(
            apply.logicalTransfers.filter { $0.eventKey.contains(":io:stage-source-read:") }.count,
            1
        )
        XCTAssertEqual(
            apply.logicalTransfers.filter { $0.eventKey.contains(":io:stage-provider-write:") }.count,
            2
        )
        XCTAssertEqual(
            apply.logicalTransfers.filter { $0.eventKey.contains(":io:stage-provider-write:") }
                .map(\.byteCount).sorted(),
            [7, 29]
        )
        XCTAssertEqual(
            apply.logicalTransfers.filter { $0.eventKey.contains(":io:old-read:") }
                .map(\.byteCount),
            [29, 29, 29, 29]
        )
        XCTAssertEqual(
            apply.logicalTransfers.reduce(Int64(0)) { $0 + $1.byteCount },
            apply.maximumLogicalProviderBytes
        )
        let recorder = LogicalTransferRecorder()
        let result = try await mirror.apply(
            apply,
            meter: ControlledMirrorTransferMeter(
                authorize: { recorder.authorize($0) },
                complete: { recorder.complete($0) },
                markUncertain: { recorder.markUncertain($0) }
            )
        )
        XCTAssertEqual(recorder.authorized, recorder.completed)
        XCTAssertEqual(recorder.authorized.count, 21)
        XCTAssertTrue(Set(recorder.authorized).isSubset(of: Set(apply.logicalTransfers)))
        XCTAssertEqual(
            recorder.authorized.reduce(Int64(0)) { $0 + $1.byteCount },
            recorder.completed.reduce(Int64(0)) { $0 + $1.byteCount }
        )
        XCTAssertLessThanOrEqual(
            recorder.completed.reduce(Int64(0)) { $0 + $1.byteCount },
            apply.maximumLogicalProviderBytes
        )
        XCTAssertTrue(recorder.uncertain.isEmpty)
        XCTAssertEqual(result.conflicts.count, 1)
    }

    func testConfirmedExternalDeleteMetersPreflightAndSixDescriptorProbes() async throws {
        let roots = try makeRoots()
        try write("payload", to: roots.external.appendingPathComponent("delete.txt"))
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await mirror.synchronize()
        try FileManager.default.removeItem(at: roots.managed.appendingPathComponent("delete.txt"))
        let prompt = try await mirror.synchronize()
        let confirmation = try XCTUnwrap(prompt.confirmationRequired.only)

        let observation = try await mirror.prepareConfirmation(
            confirmation,
            decision: .propagateDeletion
        )
        XCTAssertEqual(observation.logicalTransfers.count, 1)
        let observed = try await mirror.observeConfirmation(
            observation,
            requestedConfirmation: confirmation,
            decision: .propagateDeletion,
            meter: .unmetered
        )
        let apply = try await mirror.commitObservedPlan(observed)
        XCTAssertEqual(apply.logicalTransfers.count, 7)
        XCTAssertTrue(apply.logicalTransfers.allSatisfy { $0.direction == .readExternalProvider })
        XCTAssertEqual(Set(apply.logicalTransfers.map(\.eventKey)).count, 7)
        XCTAssertEqual(
            apply.logicalTransfers.filter { $0.eventKey.contains(":destination-preflight:") }.count,
            1
        )
        XCTAssertEqual(
            apply.logicalTransfers.filter { $0.eventKey.contains(":io:delete-read:") }.count,
            6
        )
        let recorder = LogicalTransferRecorder()
        _ = try await mirror.apply(
            apply,
            meter: ControlledMirrorTransferMeter(
                authorize: { recorder.authorize($0) },
                complete: { recorder.complete($0) },
                markUncertain: { recorder.markUncertain($0) }
            )
        )
        XCTAssertEqual(recorder.authorized, apply.logicalTransfers)
        XCTAssertEqual(recorder.completed, apply.logicalTransfers)
        XCTAssertTrue(recorder.uncertain.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: roots.external.appendingPathComponent("delete.txt").path))
    }

    func testSourceChangeAfterPrepareFailsBeforeMeterAuthorization() async throws {
        let roots = try makeRoots()
        let external = roots.external.appendingPathComponent("changed.txt")
        try write("before", to: external)
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly
        )
        let prepared = try await mirror.prepareSynchronization()
        try write("after", to: external)
        let recorder = LogicalTransferRecorder()

        do {
            _ = try await mirror.observeSynchronization(
                prepared,
                meter: ControlledMirrorTransferMeter(
                    authorize: { recorder.authorize($0) },
                    complete: { recorder.complete($0) },
                    markUncertain: { recorder.markUncertain($0) }
                )
            )
            XCTFail("a changed source must invalidate the prepared copy")
        } catch ControlledMirrorPreparedPlanError.changed {}
        XCTAssertTrue(recorder.authorized.isEmpty)
        XCTAssertTrue(recorder.completed.isEmpty)
        XCTAssertTrue(recorder.uncertain.isEmpty)
    }

    func testAuthorizedObservationNeverReadsPastItsDescriptorBoundWhenPayloadChanges() async throws {
        let payload = Data(repeating: 0x61, count: 2 * 1_048_576)
        for mutation in BoundedPayloadMutation.allCases {
            let roots = try makeRoots()
            let external = roots.external.appendingPathComponent("bounded.bin")
            try payload.write(to: external, options: .atomic)
            let probe = BoundedPayloadReadProbe(mutation: mutation, replacement: payload)
            let base = ControlledMirrorIO.coordinated
            let mirror = ControlledMirror(
                managedRoot: roots.managed,
                externalRoot: roots.external,
                mode: .importOnly,
                io: ControlledMirrorIO(
                    readData: { try base.readData(at: $0) },
                    readDataBounded: { try probe.read($0, exactByteCount: $1, identity: $2) },
                    writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
                    createDirectory: { try base.createDirectory(at: $0) },
                    copyFileAtomically: {
                        try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2)
                    },
                    removeItem: { try base.removeItem(at: $0) }
                )
            )
            let prepared = try await mirror.prepareSynchronization()
            let recorder = LogicalTransferRecorder()

            do {
                _ = try await mirror.observeSynchronization(
                    prepared,
                    meter: ControlledMirrorTransferMeter(
                        authorize: { recorder.authorize($0) },
                        complete: { recorder.complete($0) },
                        markUncertain: { recorder.markUncertain($0) }
                    )
                )
                XCTFail("\(mutation) must invalidate the descriptor-bound observation")
            } catch let failure as ControlledMirrorFailure {
                XCTAssertEqual(failure.code, .ioRead)
            }

            XCTAssertTrue(probe.mutationSucceeded, "\(mutation) must exercise its race")
            XCTAssertEqual(recorder.authorized, prepared.logicalTransfers)
            XCTAssertTrue(recorder.completed.isEmpty)
            XCTAssertEqual(recorder.uncertain, prepared.logicalTransfers)
            let authorizedBytes = recorder.authorized.reduce(Int64(0)) { $0 + $1.byteCount }
            XCTAssertLessThanOrEqual(probe.bytesRead, authorizedBytes)
            if mutation == .growAfterFirstChunk {
                XCTAssertEqual(probe.bytesRead, Int64(payload.count))
            } else {
                XCTAssertEqual(probe.bytesRead, 0)
            }
        }
    }

    func testFirstImportPersistsRelativeStateAndRerunIsIdempotent() async throws {
        let roots = try makeRoots()
        try write("hello", to: roots.external.appendingPathComponent("nested/hello.txt"))
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly
        )

        let first = try await mirror.synchronize()
        XCTAssertEqual(first.copiedToManaged, 1)
        XCTAssertEqual(first.copiedToExternal, 0)
        XCTAssertTrue(first.conflicts.isEmpty)
        XCTAssertTrue(first.confirmationRequired.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: roots.managed.appendingPathComponent("nested/hello.txt"), encoding: .utf8),
            "hello"
        )

        let stateRoot = roots.managed.appendingPathComponent(ControlledMirror.stateDirectoryName)
        let manifest = try Data(contentsOf: stateRoot.appendingPathComponent(ControlledMirror.manifestFileName))
        let journal = try Data(contentsOf: stateRoot.appendingPathComponent(ControlledMirror.journalFileName))
        let persistedText = String(decoding: manifest + journal, as: UTF8.self)
        XCTAssertFalse(persistedText.contains(roots.managed.path))
        XCTAssertFalse(persistedText.contains(roots.external.path))

        let second = try await mirror.synchronize()
        XCTAssertEqual(second.generation, first.generation)
        XCTAssertEqual(second.copiedToManaged, 0)
        XCTAssertEqual(second.copiedToExternal, 0)
        XCTAssertTrue(second.conflicts.isEmpty)
        XCTAssertTrue(second.confirmationRequired.isEmpty)
    }

    func testControlledMirrorPropagatesSingleSidedModification() async throws {
        let roots = try makeRoots()
        try write("initial", to: roots.external.appendingPathComponent("file.txt"))
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await mirror.synchronize()
        let managedStateRoot = roots.managed.appendingPathComponent(ControlledMirror.stateDirectoryName)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: managedStateRoot.appendingPathComponent(ControlledMirror.manifestFileName).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: managedStateRoot.appendingPathComponent(ControlledMirror.journalFileName).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: roots.external.appendingPathComponent(ControlledMirror.stateDirectoryName).path
            ),
            "mirror recovery state belongs only in the managed root"
        )
        try write("managed edit", to: roots.managed.appendingPathComponent("file.txt"))
        let result = try await mirror.synchronize()

        XCTAssertEqual(result.copiedToExternal, 1)
        XCTAssertEqual(result.copiedToManaged, 0)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: roots.external.appendingPathComponent("file.txt"), encoding: .utf8),
            "managed edit"
        )
    }

    func testConcurrentModificationPreservesExternalVersionAsStableConflictArtifact() async throws {
        let roots = try makeRoots()
        try write("base", to: roots.external.appendingPathComponent("notes.txt"))
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await mirror.synchronize()

        try write("managed version", to: roots.managed.appendingPathComponent("notes.txt"))
        try write("external version", to: roots.external.appendingPathComponent("notes.txt"))
        let result = try await mirror.synchronize()

        let conflict = try XCTUnwrap(result.conflicts.only)
        XCTAssertEqual(conflict.originalRelativePath, "notes.txt")
        XCTAssertEqual(conflict.preservedSide, .external)
        XCTAssertEqual(
            try String(contentsOf: roots.managed.appendingPathComponent("notes.txt"), encoding: .utf8),
            "managed version"
        )
        XCTAssertEqual(
            try String(contentsOf: roots.external.appendingPathComponent("notes.txt"), encoding: .utf8),
            "managed version"
        )
        for root in [roots.managed, roots.external] {
            XCTAssertEqual(
                try String(contentsOf: root.appendingPathComponent(conflict.artifactRelativePath), encoding: .utf8),
                "external version"
            )
        }

        let retry = try await mirror.synchronize()
        XCTAssertTrue(retry.conflicts.isEmpty)
        XCTAssertEqual(retry.generation, result.generation)
        let managedNames = try visibleRelativePaths(in: roots.managed)
        XCTAssertEqual(managedNames.filter { $0.contains("psy-conflict") }.count, 1)
    }

    func testDeletionIsNotPropagatedWithoutConfirmation() async throws {
        let roots = try makeRoots()
        try write("keep", to: roots.external.appendingPathComponent("keep.txt"))
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await mirror.synchronize()
        try FileManager.default.removeItem(at: roots.managed.appendingPathComponent("keep.txt"))

        let result = try await mirror.synchronize()
        let confirmation = try XCTUnwrap(result.confirmationRequired.only)
        XCTAssertEqual(confirmation.kind, .deleteExternal)
        XCTAssertEqual(confirmation.relativePath, "keep.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: roots.external.appendingPathComponent("keep.txt").path))

        let retry = try await mirror.synchronize()
        XCTAssertEqual(retry.generation, result.generation)
        XCTAssertEqual(retry.confirmationRequired, result.confirmationRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: roots.external.appendingPathComponent("keep.txt").path))
    }

    func testDeletionConfirmationCanRestoreOrDeleteTheUnchangedSurvivingCopy() async throws {
        for decision in [
            ControlledMirrorConfirmationDecision.keepSurvivingCopy,
            .propagateDeletion,
        ] {
            let roots = try makeRoots()
            try write("keep", to: roots.external.appendingPathComponent("keep.txt"))
            let mirror = ControlledMirror(
                managedRoot: roots.managed,
                externalRoot: roots.external,
                mode: .controlledMirror
            )
            _ = try await mirror.synchronize()
            try FileManager.default.removeItem(at: roots.managed.appendingPathComponent("keep.txt"))
            let promptResult = try await mirror.synchronize()
            let pending = try XCTUnwrap(promptResult.confirmationRequired.only)

            let resolved = try await mirror.resolveConfirmation(
                pending,
                decision: decision
            )

            XCTAssertTrue(resolved.confirmationRequired.isEmpty)
            switch decision {
            case .keepSurvivingCopy:
                XCTAssertEqual(
                    try String(
                        contentsOf: roots.managed.appendingPathComponent("keep.txt"),
                        encoding: .utf8
                    ),
                    "keep"
                )
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: roots.external.appendingPathComponent("keep.txt").path
                    )
                )
            case .propagateDeletion:
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: roots.external.appendingPathComponent("keep.txt").path
                    )
                )
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: roots.managed.appendingPathComponent("keep.txt").path
                    )
                )
            }
        }
    }

    func testDeletionConfirmationRefusesAChangedSurvivingCopy() async throws {
        let roots = try makeRoots()
        try write("original", to: roots.external.appendingPathComponent("keep.txt"))
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await mirror.synchronize()
        try FileManager.default.removeItem(at: roots.managed.appendingPathComponent("keep.txt"))
        let promptResult = try await mirror.synchronize()
        let pending = try XCTUnwrap(promptResult.confirmationRequired.only)
        try write("changed after prompt", to: roots.external.appendingPathComponent("keep.txt"))

        do {
            _ = try await mirror.resolveConfirmation(
                pending,
                decision: .propagateDeletion
            )
            XCTFail("changed content must never be deleted using an obsolete confirmation")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .confirmationChanged)
            XCTAssertEqual(failure.relativePath, "keep.txt")
        }
        XCTAssertEqual(
            try String(contentsOf: roots.external.appendingPathComponent("keep.txt"), encoding: .utf8),
            "changed after prompt"
        )
    }

    func testSymlinkIsRejectedBeforeContentCanEscapeEitherRoot() async throws {
        let roots = try makeRoots()
        let outside = roots.container.appendingPathComponent("outside.txt")
        try write("private", to: outside)
        try FileManager.default.createSymbolicLink(
            at: roots.external.appendingPathComponent("escape.txt"),
            withDestinationURL: outside
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly
        )

        do {
            _ = try await mirror.synchronize()
            XCTFail("a symbolic link must never be mirrored")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .symbolicLinkRejected)
            XCTAssertEqual(failure.relativePath, "escape.txt")
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
        XCTAssertFalse(FileManager.default.fileExists(atPath: roots.managed.appendingPathComponent("escape.txt").path))
    }

    func testNestedRootsAreRejectedBeforeEnumeration() async throws {
        let roots = try makeRoots()
        let nestedExternal = roots.managed.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedExternal, withIntermediateDirectories: true)
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: nestedExternal,
            mode: .controlledMirror
        )

        do {
            _ = try await mirror.synchronize()
            XCTFail("overlapping roots could recursively escape containment")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .rootsOverlap)
            XCTAssertNil(failure.relativePath)
        }
    }

    func testCaseAndUnicodeEquivalentPathsAreRejectedAsCollisions() async throws {
        for names in [("Readme.txt", "README.txt"), ("\u{FB01}le.txt", "file.txt")] {
            let roots = try makeRoots()
            try write("managed", to: roots.managed.appendingPathComponent(names.0))
            try write("external", to: roots.external.appendingPathComponent(names.1))
            let mirror = ControlledMirror(
                managedRoot: roots.managed,
                externalRoot: roots.external,
                mode: .controlledMirror
            )

            do {
                _ = try await mirror.synchronize()
                XCTFail("ambiguous path spellings must not be mirrored")
            } catch let failure as ControlledMirrorFailure {
                XCTAssertEqual(failure.code, .pathCollision)
                XCTAssertNotNil(failure.relativePath)
            }
        }
    }

    func testExportOnlyAndReadOnlyRespectDirection() async throws {
        let exportRoots = try makeRoots()
        try write("managed", to: exportRoots.managed.appendingPathComponent("export.txt"))
        let exporter = ControlledMirror(
            managedRoot: exportRoots.managed,
            externalRoot: exportRoots.external,
            mode: .exportOnly
        )
        let exportResult = try await exporter.synchronize()
        XCTAssertEqual(exportResult.copiedToExternal, 1)
        XCTAssertEqual(
            try String(contentsOf: exportRoots.external.appendingPathComponent("export.txt"), encoding: .utf8),
            "managed"
        )

        let readOnlyRoots = try makeRoots()
        try write("external", to: readOnlyRoots.external.appendingPathComponent("observed.txt"))
        let observer = ControlledMirror(
            managedRoot: readOnlyRoots.managed,
            externalRoot: readOnlyRoots.external,
            mode: .readOnly
        )
        let observed = try await observer.synchronize()
        XCTAssertEqual(observed.copiedToManaged, 0)
        XCTAssertEqual(observed.copiedToExternal, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: readOnlyRoots.managed.appendingPathComponent("observed.txt").path)
        )
    }

    func testInterruptedAtomicCopyResumesFromJournalWithoutDuplicateOutput() async throws {
        let roots = try makeRoots()
        try write("payload", to: roots.external.appendingPathComponent("retry.txt"))
        let base = ControlledMirrorIO.coordinated
        let interrupter = FailOnce()
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { source, destination, staging in
                try base.copyFileAtomically(from: source, to: destination, stagingAt: staging)
            },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { source, destination, _ in
                if interrupter.shouldFail() {
                    throw NSError(
                        domain: "secret-provider-error-\(source.path)",
                        code: 991,
                        userInfo: [NSLocalizedDescriptionKey: "do not persist \(destination.path)"]
                    )
                }
            }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly,
            io: io
        )

        do {
            _ = try await mirror.synchronize()
            XCTFail("the injected interruption should escape as a stable failure")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .atomicReplaceFailed)
            XCTAssertEqual(failure.relativePath, "retry.txt")
        }

        let journalURL = roots.managed
            .appendingPathComponent(ControlledMirror.stateDirectoryName)
            .appendingPathComponent(ControlledMirror.journalFileName)
        let journalText = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertFalse(journalText.contains("secret-provider-error"))
        XCTAssertFalse(journalText.contains(roots.managed.path))
        XCTAssertFalse(journalText.contains(roots.external.path))

        let retry = try await mirror.synchronize()
        XCTAssertEqual(retry.copiedToManaged, 1)
        XCTAssertEqual(
            try String(contentsOf: roots.managed.appendingPathComponent("retry.txt"), encoding: .utf8), "payload")
        XCTAssertEqual(try visibleRelativePaths(in: roots.managed).filter { $0 == "retry.txt" }.count, 1)
    }

    func testSourceChangeAfterStagingFailsWithoutReplacingDestination() async throws {
        let roots = try makeRoots()
        let source = roots.external.appendingPathComponent("race.txt")
        let destination = roots.managed.appendingPathComponent("race.txt")
        try write("original destination", to: source)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly
        )
        _ = try await baseline.synchronize()
        try write("planned source", to: source)

        let base = ControlledMirrorIO.coordinated
        let mutateOnce = FailOnce()
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { source, _, staging in
                guard mutateOnce.shouldFail() else { return }
                guard try Data(contentsOf: staging) == Data("planned source".utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try Data("changed after staging".utf8).write(to: source, options: .atomic)
            }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly,
            io: io
        )

        do {
            _ = try await mirror.synchronize()
            XCTFail("a source mutation after staging must abort before commit")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .sourceChangedDuringRun)
            XCTAssertEqual(failure.relativePath, "race.txt")
        }
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("original destination".utf8),
            "the prior destination bytes must survive a rejected source race"
        )
    }

    func testDestinationChangeAfterStagingFailsWithoutLosingConcurrentBytes() async throws {
        let roots = try makeRoots()
        let source = roots.external.appendingPathComponent("race.txt")
        let destination = roots.managed.appendingPathComponent("race.txt")
        try write("original destination", to: source)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly
        )
        _ = try await baseline.synchronize()
        try write("planned source", to: source)

        let base = ControlledMirrorIO.coordinated
        let mutateOnce = FailOnce()
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, destination, staging in
                guard mutateOnce.shouldFail() else { return }
                guard try Data(contentsOf: staging) == Data("planned source".utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try Data("concurrent destination".utf8).write(to: destination, options: .atomic)
            }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .importOnly,
            io: io
        )

        do {
            _ = try await mirror.synchronize()
            XCTFail("a destination mutation after staging must abort before commit")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .destinationChangedDuringRun)
            XCTAssertEqual(failure.relativePath, "race.txt")
        }
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("concurrent destination".utf8),
            "the concurrently written destination bytes must never be overwritten"
        )
    }

    func testCopyRejectsDestinationParentRebindWithSameFingerprintDecoy() async throws {
        let roots = try makeRoots()
        let source = roots.external.appendingPathComponent("nested/rebind.txt")
        let destination = roots.managed.appendingPathComponent("nested/rebind.txt")
        try write("baseline B", to: source)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await baseline.synchronize()
        try write("requested A", to: source)

        let originalParent = destination.deletingLastPathComponent()
        let displacedParent = roots.managed.appendingPathComponent("nested-original", isDirectory: true)
        let base = ControlledMirrorIO.coordinated
        let rebindOnce = FailOnce()
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in
                guard rebindOnce.shouldFail() else { return }
                try FileManager.default.moveItem(at: originalParent, to: displacedParent)
                try FileManager.default.createDirectory(at: originalParent, withIntermediateDirectories: true)
                try Data("baseline B".utf8).write(to: destination)
            }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror,
            io: io
        )

        do {
            _ = try await mirror.synchronize()
            XCTFail("a rebound destination parent must abort even when the decoy bytes match")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .atomicReplaceFailed)
            XCTAssertEqual(failure.relativePath, "nested/rebind.txt")
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("baseline B".utf8))
        XCTAssertEqual(
            try Data(contentsOf: displacedParent.appendingPathComponent("rebind.txt")),
            Data("baseline B".utf8)
        )
    }

    func testCopyRetainsOldInodeWrittenAfterFinalVerification() async throws {
        let roots = try makeRoots()
        let source = roots.external.appendingPathComponent("copy-final-window.txt")
        let destination = roots.managed.appendingPathComponent("copy-final-window.txt")
        try write("old destination bytes", to: source)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await baseline.synchronize()

        let writer = try OpenFileDescriptorWriter(url: destination)
        try write("new source bytes", to: source)
        let base = ControlledMirrorIO.coordinated
        let mutateOnce = FailOnce()
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            beforeCopyBackupRetention: { _ in
                guard mutateOnce.shouldFail() else { return }
                try writer.replaceContents(with: Data("late old inode bytes".utf8))
            }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror,
            io: io
        )

        _ = try await mirror.synchronize()

        XCTAssertEqual(try Data(contentsOf: destination), Data("new source bytes".utf8))
        let operationID = try confirmationOperationID(in: roots.managed)
        let recovery = recoveryPayload(root: roots.managed, operationID: operationID)
        XCTAssertEqual(
            try Data(contentsOf: recovery),
            Data("late old inode bytes".utf8),
            "the displaced inode must remain durably linked after the copy commits"
        )
    }

    func testCopyCompletesRecoveryRecordAfterRestartWithoutDroppingBackup() async throws {
        let roots = try makeRoots()
        let source = roots.external.appendingPathComponent("copy-restart.txt")
        let destination = roots.managed.appendingPathComponent("copy-restart.txt")
        try write("old destination", to: source)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await baseline.synchronize()
        try write("new source", to: source)

        let base = ControlledMirrorIO.coordinated
        let failAfterMoveOnce = FailOnce()
        let interruptedIO = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            afterRecoveryMove: { _ in
                guard failAfterMoveOnce.shouldFail() else { return }
                throw CocoaError(.fileWriteUnknown)
            }
        )
        let interrupted = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror,
            io: interruptedIO
        )

        do {
            _ = try await interrupted.synchronize()
            XCTFail("a crash before the retained record must keep the copy journal pending")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .atomicReplaceFailed)
            XCTAssertEqual(failure.relativePath, "copy-restart.txt")
        }

        let operationID = try confirmationOperationID(in: roots.managed)
        let recovery = recoveryPayload(root: roots.managed, operationID: operationID)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new source".utf8))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("old destination".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: recovery.deletingLastPathComponent().appendingPathComponent("retained.json").path
            )
        )

        let restarted = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        let completed = try await restarted.synchronize()
        XCTAssertEqual(completed.copiedToManaged, 1)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new source".utf8))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("old destination".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recovery.deletingLastPathComponent().appendingPathComponent("retained.json").path
            )
        )
    }

    func testExternalCopyResumeMetersRetainedOldBackupAtItsOwnBound() async throws {
        let roots = try makeRoots()
        let managed = roots.managed.appendingPathComponent("external-copy-restart.txt")
        let external = roots.external.appendingPathComponent("external-copy-restart.txt")
        try write(String(repeating: "D", count: 29), to: managed)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .exportOnly
        )
        _ = try await baseline.synchronize()
        try write("SOURCE!", to: managed)

        let firstRecorder = LogicalTransferRecorder()
        let base = ControlledMirrorIO.coordinated
        let failAfterMoveOnce = FailOnce()
        let interruptedIO = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: {
                try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2)
            },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            afterRecoveryMove: { _ in
                firstRecorder.recordOpaqueCallback()
                guard failAfterMoveOnce.shouldFail() else { return }
                throw CocoaError(.fileWriteUnknown)
            },
            beforeProviderPayloadIO: { firstRecorder.recordProviderPayloadIO($0) }
        )
        let interrupted = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .exportOnly,
            io: interruptedIO
        )
        let firstMeter = ControlledMirrorTransferMeter(
            authorize: { firstRecorder.authorize($0) },
            complete: { firstRecorder.complete($0) },
            markUncertain: { firstRecorder.markUncertain($0) }
        )
        let observation = try await interrupted.prepareSynchronization()
        let observed = try await interrupted.observeSynchronization(observation, meter: firstMeter)
        let firstApply = try await interrupted.commitObservedPlan(observed)
        do {
            _ = try await interrupted.apply(firstApply, meter: firstMeter)
            XCTFail("the injected retained-record persistence failure must leave a resumable journal")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .atomicReplaceFailed)
        }
        XCTAssertFalse(firstRecorder.hasInvalidActiveEvent)
        XCTAssertEqual(firstRecorder.providerPayloadIO, firstRecorder.completed)
        XCTAssertEqual(try Data(contentsOf: external), Data("SOURCE!".utf8))

        let operationID = try confirmationOperationID(in: roots.managed)
        let recovery = recoveryPayload(root: roots.external, operationID: operationID)
        XCTAssertEqual(try Data(contentsOf: recovery).count, 29)

        let retryRecorder = LogicalTransferRecorder()
        let retryIO = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: {
                try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2)
            },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            beforeProviderPayloadIO: { retryRecorder.recordProviderPayloadIO($0) }
        )
        let restarted = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .exportOnly,
            io: retryIO
        )
        let retryPlan = try await restarted.prepareSynchronization()
        XCTAssertEqual(retryPlan.stage, .apply)
        let retryMeter = ControlledMirrorTransferMeter(
            authorize: { retryRecorder.authorize($0) },
            complete: { retryRecorder.complete($0) },
            markUncertain: { retryRecorder.markUncertain($0) }
        )
        _ = try await restarted.apply(retryPlan, meter: retryMeter)

        XCTAssertFalse(retryRecorder.hasInvalidActiveEvent)
        XCTAssertEqual(retryRecorder.activeCount, 0)
        XCTAssertEqual(retryRecorder.providerPayloadIO, retryRecorder.completed)
        XCTAssertTrue(retryRecorder.uncertain.isEmpty)
        XCTAssertEqual(
            retryRecorder.completed.filter { $0.eventKey.contains(":destination-preflight:") }
                .map(\.byteCount),
            [7]
        )
        XCTAssertEqual(
            retryRecorder.completed.filter { $0.eventKey.contains(":io:resume-old-read:") }
                .map(\.byteCount),
            [29]
        )
        XCTAssertEqual(
            retryRecorder.completed.filter { $0.eventKey.hasPrefix("final:external:") }
                .map(\.byteCount),
            [7]
        )
        XCTAssertLessThanOrEqual(
            retryRecorder.completed.reduce(Int64(0)) { $0 + $1.byteCount },
            retryPlan.maximumLogicalProviderBytes
        )
    }

    func testExternalDeleteGrowthBeforeRetentionFailsBeforeUnboundedRead() async throws {
        let roots = try makeRoots()
        let external = roots.external.appendingPathComponent("delete-final-window.txt")
        let managed = roots.managed.appendingPathComponent("delete-final-window.txt")
        try write("confirmed bytes", to: external)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await baseline.synchronize()
        try FileManager.default.removeItem(at: managed)
        let prompt = try await baseline.synchronize()
        let confirmation = try XCTUnwrap(prompt.confirmationRequired.only)

        let writer = try OpenFileDescriptorWriter(url: external)
        let base = ControlledMirrorIO.coordinated
        let mutateOnce = FailOnce()
        let recorder = LogicalTransferRecorder()
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            beforeDeleteRecoveryRetention: { _ in
                guard mutateOnce.shouldFail() else { return }
                try writer.replaceContents(with: Data("late deleted inode bytes".utf8))
            },
            beforeProviderPayloadIO: { recorder.recordProviderPayloadIO($0) }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror,
            io: io
        )

        let meter = ControlledMirrorTransferMeter(
            authorize: { recorder.authorize($0) },
            complete: { recorder.complete($0) },
            markUncertain: { recorder.markUncertain($0) }
        )
        let observation = try await mirror.prepareConfirmation(
            confirmation,
            decision: .propagateDeletion
        )
        let observed = try await mirror.observeConfirmation(
            observation,
            requestedConfirmation: confirmation,
            decision: .propagateDeletion,
            meter: meter
        )
        let apply = try await mirror.commitObservedPlan(observed)
        do {
            _ = try await mirror.apply(apply, meter: meter)
            XCTFail("provider growth beyond the finite old-payload bound must fail closed")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .atomicReplaceFailed)
            XCTAssertEqual(failure.relativePath, "delete-final-window.txt")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
        let operationID = try confirmationOperationID(in: roots.managed)
        let recovery = recoveryPayload(root: roots.external, operationID: operationID)
        XCTAssertEqual(
            try Data(contentsOf: recovery),
            Data("late deleted inode bytes".utf8),
            "the quarantined inode must remain durably linked after visible deletion"
        )
        XCTAssertFalse(recorder.hasInvalidActiveEvent)
        XCTAssertEqual(recorder.activeCount, 0)
        XCTAssertEqual(recorder.providerPayloadIO, recorder.completed)
        XCTAssertTrue(recorder.uncertain.isEmpty)
        let applyCompleted = recorder.completed.filter { !$0.eventKey.hasPrefix("observation:") }
        XCTAssertLessThanOrEqual(
            applyCompleted.reduce(Int64(0)) { $0 + $1.byteCount },
            apply.maximumLogicalProviderBytes
        )
    }

    func testExternalDirectoryDeleteRejectsConcurrentChildWithoutPayloadAuthorization() async throws {
        let roots = try makeRoots()
        let external = roots.external.appendingPathComponent("delete-directory", isDirectory: true)
        let managed = roots.managed.appendingPathComponent("delete-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await baseline.synchronize()
        try FileManager.default.removeItem(at: managed)
        let prompt = try await baseline.synchronize()
        let confirmation = try XCTUnwrap(prompt.confirmationRequired.only)

        let base = ControlledMirrorIO.coordinated
        let mutateOnce = FailOnce()
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            beforeDeleteRecoveryRetention: { quarantine in
                guard mutateOnce.shouldFail() else { return }
                let nested = quarantine.appendingPathComponent("late/nested.txt")
                try FileManager.default.createDirectory(
                    at: nested.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("late directory bytes".utf8).write(to: nested)
            }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror,
            io: io
        )

        let observation = try await mirror.prepareConfirmation(
            confirmation,
            decision: .propagateDeletion
        )
        let observed = try await mirror.observeConfirmation(
            observation,
            requestedConfirmation: confirmation,
            decision: .propagateDeletion,
            meter: .unmetered
        )
        let apply = try await mirror.commitObservedPlan(observed)
        XCTAssertTrue(apply.logicalTransfers.isEmpty)
        let recorder = LogicalTransferRecorder()
        do {
            _ = try await mirror.apply(
                apply,
                meter: ControlledMirrorTransferMeter(
                    authorize: { recorder.authorize($0) },
                    complete: { recorder.complete($0) },
                    markUncertain: { recorder.markUncertain($0) }
                )
            )
            XCTFail("a concurrently populated external directory must fail closed")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .atomicReplaceFailed)
        }
        XCTAssertTrue(recorder.authorized.isEmpty)
        XCTAssertTrue(recorder.completed.isEmpty)
        XCTAssertTrue(recorder.uncertain.isEmpty)
    }

    func testDeleteRacePreservesReplacementWithoutMovingNewInode() async throws {
        let roots = try makeRoots()
        let external = roots.external.appendingPathComponent("delete-race.txt")
        let managed = roots.managed.appendingPathComponent("delete-race.txt")
        try write("original", to: external)
        let base = ControlledMirrorIO.coordinated
        let replaceOnce = FailOnce()
        let diagnostics = AtomicCopyDiagnosticRecorder()
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            beforeDeleteCommit: { destination in
                guard replaceOnce.shouldFail() else { return }
                try Data("new inode version".utf8).write(to: destination, options: .atomic)
            },
            atomicCopyDiagnostic: { stage, code in
                diagnostics.record(stage: stage, code: code)
            }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror,
            io: io
        )
        _ = try await mirror.synchronize()
        try FileManager.default.removeItem(at: managed)
        let prompt = try await mirror.synchronize()
        let confirmation = try XCTUnwrap(prompt.confirmationRequired.only)

        do {
            _ = try await mirror.resolveConfirmation(
                confirmation,
                decision: .propagateDeletion
            )
            XCTFail("a replacement after the initial fingerprint must not be deleted")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .destinationChangedDuringRun)
            XCTAssertEqual(failure.relativePath, "delete-race.txt")
        }
        XCTAssertEqual(
            try Data(contentsOf: external),
            Data("new inode version".utf8),
            "the replacement inode must remain at its original path"
        )
        XCTAssertFalse(
            diagnostics.stages.contains(.deleteRollback),
            "the final identity fence rejects the replacement before any move needs rollback"
        )
    }

    func testDeleteDetectsWriteThroughOldDescriptorAfterQuarantineVerification() async throws {
        let roots = try makeRoots()
        let external = roots.external.appendingPathComponent("delete-open-fd.txt")
        let managed = roots.managed.appendingPathComponent("delete-open-fd.txt")
        try write("confirmed old bytes", to: external)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await baseline.synchronize()
        try FileManager.default.removeItem(at: managed)
        let prompt = try await baseline.synchronize()
        let confirmation = try XCTUnwrap(prompt.confirmationRequired.only)

        let writer = try OpenFileDescriptorWriter(url: external)
        let base = ControlledMirrorIO.coordinated
        let mutateOnce = FailOnce()
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            afterDeleteVerification: { _ in
                guard mutateOnce.shouldFail() else { return }
                try writer.replaceContents(with: Data("concurrent descriptor bytes".utf8))
            }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror,
            io: io
        )

        do {
            _ = try await mirror.resolveConfirmation(confirmation, decision: .propagateDeletion)
            XCTFail("a write through the pre-rename descriptor must prevent final unlink")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .atomicReplaceFailed)
            XCTAssertEqual(failure.relativePath, "delete-open-fd.txt")
        }

        let operationID = try confirmationOperationID(in: roots.managed)
        let recovery = recoveryPayload(root: roots.external, operationID: operationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("concurrent descriptor bytes".utf8))
        let pendingJournal = try journalText(in: roots.managed)
        XCTAssertTrue(pendingJournal.contains("\"phase\":\"applying\""))
        XCTAssertTrue(pendingJournal.contains("\"lastErrorCode\":\"atomicReplaceFailed\""))

        let restarted = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        do {
            _ = try await restarted.synchronize()
            XCTFail("changed quarantine contents require explicit manual cleanup")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .atomicReplaceFailed)
            XCTAssertEqual(failure.relativePath, "delete-open-fd.txt")
        }
        XCTAssertEqual(try Data(contentsOf: recovery), Data("concurrent descriptor bytes".utf8))
    }

    func testDeleteRecoveryRecordFailureRemainsPendingAndCompletesAfterRestart() async throws {
        let roots = try makeRoots()
        let external = roots.external.appendingPathComponent("delete-retry.txt")
        let managed = roots.managed.appendingPathComponent("delete-retry.txt")
        try write("private bytes", to: external)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await baseline.synchronize()
        try FileManager.default.removeItem(at: managed)
        let prompt = try await baseline.synchronize()
        let confirmation = try XCTUnwrap(prompt.confirmationRequired.only)

        let base = ControlledMirrorIO.coordinated
        let failAfterMoveOnce = FailOnce()
        let interruptedIO = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            afterRecoveryMove: { _ in
                guard failAfterMoveOnce.shouldFail() else { return }
                throw CocoaError(.fileWriteUnknown)
            }
        )
        let interrupted = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror,
            io: interruptedIO
        )
        do {
            _ = try await interrupted.resolveConfirmation(confirmation, decision: .propagateDeletion)
            XCTFail("a crash after the durable move must keep the journal pending")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .atomicReplaceFailed)
            XCTAssertEqual(failure.relativePath, "delete-retry.txt")
        }

        let operationID = try confirmationOperationID(in: roots.managed)
        let recovery = recoveryPayload(root: roots.external, operationID: operationID)
        let recoveryDirectory = recovery.deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("private bytes".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recoveryDirectory.appendingPathComponent("prepared.json").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: recoveryDirectory.appendingPathComponent("retained.json").path
            )
        )
        let pendingJournal = try journalText(in: roots.managed)
        XCTAssertTrue(pendingJournal.contains("\"phase\":\"applying\""))
        XCTAssertTrue(pendingJournal.contains("\"lastErrorCode\":\"atomicReplaceFailed\""))

        let activeSummaries = try await interrupted.recoverySummaries()
        let activeSummary = try XCTUnwrap(activeSummaries.only)
        XCTAssertTrue(activeSummary.isReferencedByActiveJournal)
        do {
            try await interrupted.resolveRecovery(
                activeSummary,
                decision: .deleteAfterUserConfirmation,
                authorization: { _ in true }
            )
            XCTFail("an applying journal must retain the only restart recovery payload")
        } catch let error as ControlledMirrorRecoveryError {
            XCTAssertEqual(error, .activeJournal)
        }
        XCTAssertEqual(try Data(contentsOf: recovery), Data("private bytes".utf8))

        let exportDirectory = roots.container.appendingPathComponent("exports", isDirectory: true)
        let exportPlan = try await interrupted.prepareRecoveryExport(activeSummary)
        XCTAssertEqual(exportPlan.plan.maximumLogicalProviderBytes, activeSummary.byteCount * 2)
        let exportRecorder = LogicalTransferRecorder()
        let exported = try await interrupted.exportRecovery(
            exportPlan,
            to: exportDirectory,
            authorization: { $0 == activeSummary },
            meter: ControlledMirrorTransferMeter(
                authorize: { exportRecorder.authorize($0) },
                complete: { exportRecorder.complete($0) },
                markUncertain: { exportRecorder.markUncertain($0) }
            )
        )
        XCTAssertEqual(exported.payloadKind, .file)
        XCTAssertEqual(try Data(contentsOf: exported.url), Data("private bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("private bytes".utf8))
        XCTAssertEqual(exportRecorder.completed.count, 2)
        XCTAssertTrue(exportRecorder.uncertain.isEmpty)
        try ControlledMirror.removeRecoveryExport(exported, from: exportDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.url.path))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("private bytes".utf8))

        let restarted = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        let completed = try await restarted.synchronize()
        XCTAssertTrue(completed.confirmationRequired.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("private bytes".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recoveryDirectory.appendingPathComponent("retained.json").path
            )
        )

        let inactiveSummaries = try await restarted.recoverySummaries()
        let inactiveSummary = try XCTUnwrap(inactiveSummaries.only)
        XCTAssertFalse(inactiveSummary.isReferencedByActiveJournal)
        try await restarted.resolveRecovery(
            inactiveSummary,
            decision: .deleteAfterUserConfirmation,
            authorization: { _ in true }
        )
        let summariesAfterDisposal = try await restarted.recoverySummaries()
        XCTAssertTrue(summariesAfterDisposal.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))

        let rerun = try await restarted.synchronize()
        XCTAssertEqual(rerun.generation, completed.generation)
    }

    func testManagedDirectoryRecoveryExportsAsExactDirectorySnapshot() async throws {
        let roots = try makeRoots()
        let externalDirectory = roots.external.appendingPathComponent(
            "empty-directory",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: true
        )
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await baseline.synchronize()
        try FileManager.default.removeItem(at: externalDirectory)
        let prompt = try await baseline.synchronize()
        let confirmation = try XCTUnwrap(prompt.confirmationRequired.only)
        XCTAssertEqual(confirmation.kind, .deleteManaged)

        let base = ControlledMirrorIO.coordinated
        let failAfterMoveOnce = FailOnce()
        let interrupted = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror,
            io: ControlledMirrorIO(
                readData: { try base.readData(at: $0) },
                writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
                createDirectory: { try base.createDirectory(at: $0) },
                copyFileAtomically: {
                    try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2)
                },
                removeItem: { try base.removeItem(at: $0) },
                beforeAtomicCopyCommit: { _, _, _ in },
                afterRecoveryMove: { _ in
                    guard failAfterMoveOnce.shouldFail() else { return }
                    throw CocoaError(.fileWriteUnknown)
                }
            )
        )
        do {
            _ = try await interrupted.resolveConfirmation(
                confirmation,
                decision: .propagateDeletion
            )
            XCTFail("the injected failure must retain the moved directory")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .atomicReplaceFailed)
            XCTAssertEqual(failure.relativePath, "empty-directory")
        }

        let interruptedSummaries = try await interrupted.recoverySummaries()
        let summary = try XCTUnwrap(interruptedSummaries.only)
        XCTAssertEqual(summary.side, .managed)
        XCTAssertEqual(summary.payloadKind, .directory)
        XCTAssertEqual(summary.byteCount, 0)
        let exportDirectory = roots.container.appendingPathComponent(
            "directory-exports",
            isDirectory: true
        )
        let plan = try await interrupted.prepareRecoveryExport(summary)
        XCTAssertEqual(plan.plan.maximumLogicalProviderBytes, 0)
        let export = try await interrupted.exportRecovery(
            plan,
            to: exportDirectory,
            authorization: { $0 == summary },
            meter: .unmetered
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: export.url.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: export.url.path), [])
        let summariesAfterExport = try await interrupted.recoverySummaries()
        XCTAssertEqual(summariesAfterExport, [summary])
        try ControlledMirror.removeRecoveryExport(export, from: exportDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.url.path))
        let summariesAfterCleanup = try await interrupted.recoverySummaries()
        XCTAssertEqual(summariesAfterCleanup, [summary])
    }

    func testRollbackAfterSwapNeverMovesAndCleansConcurrentDestination() async throws {
        let roots = try makeRoots()
        let managed = roots.managed.appendingPathComponent("swap-race.txt")
        let external = roots.external.appendingPathComponent("swap-race.txt")
        try write("B old destination", to: external)
        let baseline = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror
        )
        _ = try await baseline.synchronize()
        try write("A incoming", to: managed)

        let base = ControlledMirrorIO.coordinated
        let replaceOnce = FailOnce()
        let diagnostics = AtomicCopyDiagnosticRecorder()
        let recorder = LogicalTransferRecorder()
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            afterAtomicCopySwap: { _, destination, staging in
                recorder.recordOpaqueCallback()
                guard replaceOnce.shouldFail() else { return }
                guard try Data(contentsOf: destination) == Data("A incoming".utf8),
                    try Data(contentsOf: staging) == Data("B old destination".utf8)
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try Data("C concurrent".utf8).write(to: destination, options: .atomic)
                throw CocoaError(.fileWriteUnknown)
            },
            beforeProviderPayloadIO: { recorder.recordProviderPayloadIO($0) },
            atomicCopyDiagnostic: { stage, code in
                if stage == .rollbackSwap {
                    recorder.recordOpaqueCallback()
                }
                diagnostics.record(stage: stage, code: code)
            }
        )
        let mirror = ControlledMirror(
            managedRoot: roots.managed,
            externalRoot: roots.external,
            mode: .controlledMirror,
            io: io
        )
        let meter = ControlledMirrorTransferMeter(
            authorize: { recorder.authorize($0) },
            complete: { recorder.complete($0) },
            markUncertain: { recorder.markUncertain($0) }
        )
        let observation = try await mirror.prepareSynchronization()
        let observed = try await mirror.observeSynchronization(observation, meter: meter)
        let apply = try await mirror.commitObservedPlan(observed)

        do {
            _ = try await mirror.apply(apply, meter: meter)
            XCTFail("the injected post-swap write must fail closed")
        } catch let failure as ControlledMirrorFailure {
            XCTAssertEqual(failure.code, .atomicReplaceFailed)
            XCTAssertEqual(failure.relativePath, "swap-race.txt")
        }
        XCTAssertEqual(
            try Data(contentsOf: external),
            Data("C concurrent".utf8),
            "rollback must leave the concurrent destination in place"
        )
        let operationID = try confirmationOperationID(in: roots.managed)
        let recovery = recoveryPayload(root: roots.external, operationID: operationID)
        XCTAssertEqual(
            try Data(contentsOf: recovery),
            Data("B old destination".utf8),
            "the pre-swap destination must remain recoverable in indexed recovery"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recovery.deletingLastPathComponent().appendingPathComponent("conflict.json").path
            )
        )
        XCTAssertTrue(diagnostics.stages.contains(.validateAfterSwap))
        XCTAssertTrue(diagnostics.stages.contains(.rollbackSwap))
        XCTAssertFalse(recorder.hasInvalidActiveEvent)
        XCTAssertEqual(recorder.activeCount, 0)
        XCTAssertEqual(recorder.providerPayloadIO, recorder.completed)
        XCTAssertTrue(recorder.uncertain.isEmpty)
        let applyCompleted = recorder.completed.filter { !$0.eventKey.hasPrefix("observation:") }
        XCTAssertLessThanOrEqual(
            applyCompleted.reduce(Int64(0)) { $0 + $1.byteCount },
            apply.maximumLogicalProviderBytes
        )
    }

    private func makeRoots() throws -> (container: URL, managed: URL, external: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControlledMirrorTests-\(UUID().uuidString)", isDirectory: true)
        let managed = container.appendingPathComponent("managed", isDirectory: true)
        let external = container.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return (container, managed, external)
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url, options: .atomic)
    }

    private func visibleRelativePaths(in root: URL) throws -> [String] {
        let canonicalRoot = root.resolvingSymlinksInPath()
        guard
            let enumerator = FileManager.default.enumerator(
                at: canonicalRoot,
                includingPropertiesForKeys: nil
            )
        else {
            return []
        }
        var result: [String] = []
        for case let url as URL in enumerator {
            let relative = url.resolvingSymlinksInPath().pathComponents
                .dropFirst(canonicalRoot.pathComponents.count)
                .joined(separator: "/")
            if relative == ControlledMirror.stateDirectoryName {
                enumerator.skipDescendants()
                continue
            }
            result.append(relative)
        }
        return result.sorted()
    }

    private func confirmationOperationID(in managedRoot: URL) throws -> String {
        let journal =
            managedRoot
            .appendingPathComponent(ControlledMirror.stateDirectoryName, isDirectory: true)
            .appendingPathComponent(ControlledMirror.journalFileName)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: journal))
        let dictionary = try XCTUnwrap(object as? [String: Any])
        let operations = try XCTUnwrap(dictionary["operations"] as? [[String: Any]])
        let operation = try XCTUnwrap(operations.only)
        return try XCTUnwrap(operation["id"] as? String)
    }

    private func journalText(in managedRoot: URL) throws -> String {
        let journal =
            managedRoot
            .appendingPathComponent(ControlledMirror.stateDirectoryName, isDirectory: true)
            .appendingPathComponent(ControlledMirror.journalFileName)
        return try String(contentsOf: journal, encoding: .utf8)
    }

    private func recoveryPayload(root: URL, operationID: String) -> URL {
        root.appendingPathComponent(ControlledMirror.stateDirectoryName, isDirectory: true)
            .appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent(operationID, isDirectory: true)
            .appendingPathComponent("payload")
    }
}

private enum BoundedPayloadMutation: CaseIterable {
    case growBeforeRead
    case truncateBeforeRead
    case sameSizeRebindBeforeRead
    case growAfterFirstChunk
}

private final class BoundedPayloadReadProbe: @unchecked Sendable {
    private let mutation: BoundedPayloadMutation
    private let replacement: Data
    private let lock = NSLock()
    private var recordedBytes: Int64 = 0
    private var didMutate = false
    private var mutationWasSuccessful = false

    init(mutation: BoundedPayloadMutation, replacement: Data) {
        self.mutation = mutation
        self.replacement = replacement
    }

    var bytesRead: Int64 {
        lock.withLock { recordedBytes }
    }

    var mutationSucceeded: Bool {
        lock.withLock { mutationWasSuccessful }
    }

    func read(
        _ url: URL,
        exactByteCount: Int64,
        identity: ControlledMirrorPayloadIdentity?
    ) throws -> Data {
        switch mutation {
        case .growBeforeRead, .truncateBeforeRead, .sameSizeRebindBeforeRead:
            try mutate(url)
        case .growAfterFirstChunk:
            break
        }
        return try ControlledMirrorIO.readRegularFileExactlyForTesting(
            at: url,
            expectedByteCount: exactByteCount,
            expectedIdentity: identity,
            didRead: { [self] count in
                lock.withLock { recordedBytes += Int64(count) }
                if mutation == .growAfterFirstChunk { mutateAfterFirstChunk(url) }
            }
        )
    }

    private func mutate(_ url: URL) throws {
        switch mutation {
        case .growBeforeRead, .growAfterFirstChunk:
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x62]))
        case .truncateBeforeRead:
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(max(0, replacement.count - 1)))
        case .sameSizeRebindBeforeRead:
            try replacement.write(to: url, options: .atomic)
        }
        lock.withLock {
            didMutate = true
            mutationWasSuccessful = true
        }
    }

    private func mutateAfterFirstChunk(_ url: URL) {
        let shouldMutate = lock.withLock {
            guard !didMutate else { return false }
            didMutate = true
            return true
        }
        guard shouldMutate else { return }
        do {
            try mutate(url)
        } catch {
            lock.withLock { mutationWasSuccessful = false }
        }
    }
}

private final class FailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFailed = false

    func shouldFail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFailed else { return false }
        hasFailed = true
        return true
    }
}

private final class AtomicCopyDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStages: [ControlledMirrorIO.AtomicCopyStage] = []

    var stages: [ControlledMirrorIO.AtomicCopyStage] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStages
    }

    func record(stage: ControlledMirrorIO.AtomicCopyStage, code _: Int32?) {
        lock.lock()
        recordedStages.append(stage)
        lock.unlock()
    }
}

private final class LogicalTransferRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var authorizedTransfers: [ControlledMirrorLogicalTransfer] = []
    private var completedTransfers: [ControlledMirrorLogicalTransfer] = []
    private var uncertainTransfers: [ControlledMirrorLogicalTransfer] = []
    private var activeTransferIDs: Set<UUID> = []
    private var payloadIOTransfers: [ControlledMirrorLogicalTransfer] = []
    private var invalidActiveEvent = false

    var authorized: [ControlledMirrorLogicalTransfer] {
        lock.lock()
        defer { lock.unlock() }
        return authorizedTransfers
    }

    var completed: [ControlledMirrorLogicalTransfer] {
        lock.lock()
        defer { lock.unlock() }
        return completedTransfers
    }

    var uncertain: [ControlledMirrorLogicalTransfer] {
        lock.lock()
        defer { lock.unlock() }
        return uncertainTransfers
    }

    var providerPayloadIO: [ControlledMirrorLogicalTransfer] {
        lock.withLock { payloadIOTransfers }
    }

    var hasInvalidActiveEvent: Bool {
        lock.withLock { invalidActiveEvent }
    }

    var activeCount: Int {
        lock.withLock { activeTransferIDs.count }
    }

    func authorize(_ transfer: ControlledMirrorLogicalTransfer) {
        lock.lock()
        if !activeTransferIDs.insert(transfer.id).inserted {
            invalidActiveEvent = true
        }
        authorizedTransfers.append(transfer)
        lock.unlock()
    }

    func complete(_ transfer: ControlledMirrorLogicalTransfer) {
        lock.lock()
        if activeTransferIDs.remove(transfer.id) == nil {
            invalidActiveEvent = true
        }
        completedTransfers.append(transfer)
        lock.unlock()
    }

    func markUncertain(_ transfer: ControlledMirrorLogicalTransfer) {
        lock.lock()
        if activeTransferIDs.remove(transfer.id) == nil {
            invalidActiveEvent = true
        }
        uncertainTransfers.append(transfer)
        lock.unlock()
    }

    func recordProviderPayloadIO(_ transfer: ControlledMirrorLogicalTransfer) {
        lock.withLock {
            if !activeTransferIDs.contains(transfer.id)
                || payloadIOTransfers.contains(where: { $0.id == transfer.id })
            {
                invalidActiveEvent = true
            }
            payloadIOTransfers.append(transfer)
        }
    }

    func recordOpaqueCallback() {
        lock.withLock {
            if !activeTransferIDs.isEmpty {
                invalidActiveEvent = true
            }
        }
    }
}

private final class PayloadReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var count: Int { lock.withLock { urls.count } }

    func record(_ url: URL) {
        lock.withLock { urls.append(url) }
    }
}

private final class OpenFileDescriptorWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()

    init(url: URL) throws {
        descriptor = url.path.withCString { open($0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    deinit {
        close(descriptor)
    }

    func replaceContents(with data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var written = 0
        try data.withUnsafeBytes { bytes in
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
                guard result > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

extension Array {
    fileprivate var only: Element? { count == 1 ? first : nil }
}
