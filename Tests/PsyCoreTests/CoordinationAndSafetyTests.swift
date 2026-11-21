import Darwin
import Foundation
import XCTest

@testable import PsyCore

final class CoordinationAndSafetyTests: XCTestCase {
    #if os(macOS)
        // Foundation.Process has no iOS implementation. Keep this subprocess
        // crash-recovery proof in the macOS SwiftPM suite where the helper and
        // SIGKILL lifecycle it exercises are available.
        func testSecureFileLeaseIsReleasedWhenOwnerProcessIsKilled() throws {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let lock = root.appendingPathComponent("selection-core-lifecycle.lock")
            let bootstrap = try SecureFileLease.acquire(at: lock, mode: .exclusive)
            bootstrap.release()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [
                "-e",
                "use Fcntl qw(:flock); $|=1; open(my $fh, '+<', $ARGV[0]) or exit 111; flock($fh, LOCK_EX) or exit 112; print '1'; sleep 3600;",
                lock.path,
            ]
            let readyPipe = Pipe()
            process.standardOutput = readyPipe
            try process.run()
            defer {
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }

            let ready = readyPipe.fileHandleForReading.readData(ofLength: 1)
            XCTAssertEqual(ready, Data("1".utf8))
            XCTAssertNil(try SecureFileLease.tryAcquire(at: lock, mode: .shared))

            XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
            process.waitUntilExit()

            let recovered = try XCTUnwrap(
                try SecureFileLease.tryAcquire(at: lock, mode: .shared)
            )
            recovered.release()
        }
    #endif

    func testOnlyOneCoordinatorOwnsCoreLock() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("core.lock")
        let first = CoreProcessCoordinator(lockURL: lock)
        let second = CoreProcessCoordinator(lockURL: lock)
        let firstID = UUID()
        let firstLease = try await first.acquire(
            as: .mainApp,
            instanceID: firstID,
            acquiredAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(firstLease.schemaVersion, 1)
        XCTAssertEqual(firstLease.epoch, 1)
        XCTAssertEqual(firstLease.instanceID, firstID)
        XCTAssertEqual(firstLease.role, .mainApp)
        do {
            try await second.acquire(as: .fileProvider)
            XCTFail("Second process coordinator unexpectedly acquired the lock")
        } catch let error as CoreOwnershipError {
            XCTAssertEqual(error, .ownedByAnotherProcess)
        }
        await first.release()
        let secondID = UUID()
        let secondLease = try await second.acquire(
            as: .fileProvider,
            instanceID: secondID,
            acquiredAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(secondLease.epoch, 2)
        XCTAssertEqual(secondLease.instanceID, secondID)
        XCTAssertEqual(secondLease.role, .fileProvider)
        XCTAssertNotEqual(secondLease.instanceID, firstLease.instanceID)
        let secondOwnsLock = await second.isOwner
        XCTAssertTrue(secondOwnsLock)
        try await second.validate(secondLease)
        let persisted = try XCTUnwrap(
            CoreOwnerMetadataStore.readIfPresent(
                at: CoreProcessCoordinator.ownerMetadataURL(for: lock)
            )
        )
        XCTAssertEqual(persisted, secondLease)
        await second.release()
    }

    func testCorruptOwnerMetadataFailsClosedWithoutResettingEpoch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = root.appendingPathComponent("core.lock")
        let metadataURL = CoreProcessCoordinator.ownerMetadataURL(for: lock)
        let corruptData = Data("{not-json".utf8)
        try corruptData.write(to: metadataURL, options: .atomic)
        let coordinator = CoreProcessCoordinator(lockURL: lock)

        do {
            try await coordinator.acquire(as: .mainApp)
            XCTFail("Corrupt owner metadata unexpectedly acquired an owner epoch")
        } catch let error as CoreOwnershipError {
            XCTAssertEqual(error, .ownerMetadataCorrupt)
        }

        let isOwner = await coordinator.isOwner
        XCTAssertFalse(isOwner)
        XCTAssertEqual(try Data(contentsOf: metadataURL), corruptData)
    }

    func testZeroOwnerEpochIsCorruptAndDoesNotRestartAtOne() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("core.lock")
        let metadataURL = CoreProcessCoordinator.ownerMetadataURL(for: lock)
        let invalid = CoreOwnerLease(
            epoch: 0,
            instanceID: UUID(),
            role: .mainApp,
            acquiredAt: Date(timeIntervalSince1970: 1)
        )
        try CoreOwnerMetadataStore.write(invalid, to: metadataURL)
        let coordinator = CoreProcessCoordinator(lockURL: lock)

        do {
            try await coordinator.acquire(as: .mainApp)
            XCTFail("Epoch zero unexpectedly migrated to a live epoch")
        } catch let error as CoreOwnershipError {
            XCTAssertEqual(error, .ownerMetadataCorrupt)
        }

        XCTAssertEqual(try CoreOwnerMetadataStore.readIfPresent(at: metadataURL), invalid)
    }

    func testUnsupportedOwnerMetadataSchemaFailsClosed() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("core.lock")
        let metadataURL = CoreProcessCoordinator.ownerMetadataURL(for: lock)
        let unsupported = CoreOwnerLease(
            schemaVersion: 99,
            epoch: 41,
            instanceID: UUID(),
            role: .backgroundTask,
            acquiredAt: Date(timeIntervalSince1970: 1)
        )
        try CoreOwnerMetadataStore.write(unsupported, to: metadataURL)
        let coordinator = CoreProcessCoordinator(lockURL: lock)

        do {
            try await coordinator.acquire(as: .mainApp)
            XCTFail("Unsupported owner metadata unexpectedly acquired an owner epoch")
        } catch let error as CoreOwnershipError {
            XCTAssertEqual(error, .unsupportedOwnerMetadataSchema(99))
        }

        XCTAssertEqual(try CoreOwnerMetadataStore.readIfPresent(at: metadataURL), unsupported)
    }

    func testOwnerEpochOverflowFailsClosedWithoutWrapping() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("core.lock")
        let metadataURL = CoreProcessCoordinator.ownerMetadataURL(for: lock)
        let maximum = CoreOwnerLease(
            epoch: UInt64.max,
            instanceID: UUID(),
            role: .appIntent,
            acquiredAt: Date(timeIntervalSince1970: 1)
        )
        try CoreOwnerMetadataStore.write(maximum, to: metadataURL)
        let coordinator = CoreProcessCoordinator(lockURL: lock)

        do {
            try await coordinator.acquire(as: .mainApp)
            XCTFail("Maximum owner epoch unexpectedly wrapped")
        } catch let error as CoreOwnershipError {
            XCTAssertEqual(error, .ownerEpochOverflow)
        }

        XCTAssertEqual(try CoreOwnerMetadataStore.readIfPresent(at: metadataURL), maximum)
    }

    func testStaleOwnerCannotOverwriteNewerSnapshot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("core.lock")
        let metadataURL = CoreProcessCoordinator.ownerMetadataURL(for: lock)
        let snapshotURL = root.appendingPathComponent("snapshot.json")
        let store = SharedSnapshotStore(snapshotURL: snapshotURL)
        let first = CoreProcessCoordinator(lockURL: lock)
        let firstLease = try await first.acquire(as: .mainApp)
        try store.write(
            .init(generation: 1, ownerEpoch: firstLease.epoch, instanceID: firstLease.instanceID),
            lease: firstLease,
            ownerMetadataURL: metadataURL
        )
        await first.release()

        let second = CoreProcessCoordinator(lockURL: lock)
        let secondLease = try await second.acquire(as: .fileProvider)
        try store.write(
            .init(generation: 2, ownerEpoch: secondLease.epoch, instanceID: secondLease.instanceID),
            lease: secondLease,
            ownerMetadataURL: metadataURL
        )

        XCTAssertThrowsError(
            try store.write(
                .init(generation: 3, ownerEpoch: firstLease.epoch, instanceID: firstLease.instanceID),
                lease: firstLease,
                ownerMetadataURL: metadataURL
            )
        ) { error in
            XCTAssertEqual(error as? CoreOwnershipError, .staleLease)
        }
        let recovered = try XCTUnwrap(store.read())
        XCTAssertEqual(recovered.generation, 2)
        XCTAssertEqual(recovered.ownerEpoch, secondLease.epoch)
        XCTAssertEqual(recovered.instanceID, secondLease.instanceID)
        await second.release()
    }

    func testStaleOwnerCannotOverwriteResultOrAcknowledgeCommand() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("core.lock")
        let metadataURL = CoreProcessCoordinator.ownerMetadataURL(for: lock)
        let queue = CoreCommandQueue(root: root.appendingPathComponent("commands", isDirectory: true))
        let command = CoreCommand(kind: .sync, trigger: .user)
        try queue.enqueue(command)
        let first = CoreProcessCoordinator(lockURL: lock)
        let firstLease = try await first.acquire(as: .mainApp)
        try queue.record(
            .init(
                commandID: command.id,
                status: .retryable,
                ownerEpoch: firstLease.epoch,
                instanceID: firstLease.instanceID,
                errorCode: "device_offline"
            ),
            lease: firstLease,
            ownerMetadataURL: metadataURL
        )
        await first.release()

        let second = CoreProcessCoordinator(lockURL: lock)
        let secondLease = try await second.acquire(as: .fileProvider)
        let currentResult = CoreCommandResult(
            commandID: command.id,
            status: .blocked,
            ownerEpoch: secondLease.epoch,
            instanceID: secondLease.instanceID,
            errorCode: "version_conflict"
        )
        try queue.record(currentResult, lease: secondLease, ownerMetadataURL: metadataURL)

        XCTAssertThrowsError(
            try queue.record(
                .init(
                    commandID: command.id,
                    status: .failed,
                    ownerEpoch: firstLease.epoch,
                    instanceID: firstLease.instanceID,
                    errorCode: "late_failure"
                ),
                lease: firstLease,
                ownerMetadataURL: metadataURL
            )
        ) { error in
            XCTAssertEqual(error as? CoreOwnershipError, .staleLease)
        }
        XCTAssertThrowsError(
            try queue.acknowledge(
                command,
                lease: firstLease,
                ownerMetadataURL: metadataURL
            )
        ) { error in
            XCTAssertEqual(error as? CoreOwnershipError, .staleLease)
        }
        let recoveredResult = try XCTUnwrap(queue.result(for: command.id))
        XCTAssertEqual(recoveredResult.commandID, currentResult.commandID)
        XCTAssertEqual(recoveredResult.status, currentResult.status)
        XCTAssertEqual(recoveredResult.ownerEpoch, currentResult.ownerEpoch)
        XCTAssertEqual(recoveredResult.instanceID, currentResult.instanceID)
        XCTAssertEqual(recoveredResult.errorCode, currentResult.errorCode)
        XCTAssertEqual(try queue.pending().map(\.id), [command.id])
        await second.release()
    }

    func testSnapshotAndResultDecodeWithoutOwnerFields() throws {
        let snapshotData = Data(
            """
            {
              "schemaVersion": 1,
              "generation": 3,
              "generatedAt": "1970-01-01T00:00:00Z",
              "devices": [],
              "folders": [],
              "items": [],
              "tombstones": []
            }
            """.utf8
        )
        let snapshotDecoder = JSONDecoder()
        snapshotDecoder.dateDecodingStrategy = .iso8601
        let snapshot = try snapshotDecoder.decode(CoreSnapshot.self, from: snapshotData)
        XCTAssertEqual(snapshot.generation, 3)
        XCTAssertNil(snapshot.ownerEpoch)
        XCTAssertNil(snapshot.instanceID)
        XCTAssertTrue(snapshot.pendingDevices.isEmpty)
        XCTAssertTrue(snapshot.pendingFolders.isEmpty)
        XCTAssertEqual(snapshot.pendingDeviceObservationScope, .unavailable)
        XCTAssertFalse(snapshot.pendingFoldersAvailable)
        XCTAssertFalse(snapshot.pendingFoldersTruncated)

        let commandID = UUID()
        let resultData = Data(
            """
            {
              "commandID": "\(commandID.uuidString)",
              "status": "retryable",
              "completedAt": 1,
              "errorCode": "device_offline"
            }
            """.utf8
        )
        let resultDecoder = JSONDecoder()
        resultDecoder.dateDecodingStrategy = .secondsSince1970
        let result = try resultDecoder.decode(CoreCommandResult.self, from: resultData)
        XCTAssertEqual(result.commandID, commandID)
        XCTAssertEqual(result.status, .retryable)
        XCTAssertEqual(result.errorCode, "device_offline")
        XCTAssertNil(result.ownerEpoch)
        XCTAssertNil(result.instanceID)
    }

    func testCommandQueueSurvivesRestartAndPreservesOrder() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let older = CoreCommand(kind: .sync, trigger: .appIntent, createdAt: Date(timeIntervalSince1970: 1))
        let newer = CoreCommand(kind: .pause, trigger: .user, createdAt: Date(timeIntervalSince1970: 2))
        try CoreCommandQueue(root: root).enqueue(newer)
        try CoreCommandQueue(root: root).enqueue(older)
        let recovered = try CoreCommandQueue(root: root).pending()
        XCTAssertEqual(recovered.map(\.id), [older.id, newer.id])
        try CoreCommandQueue(root: root).acknowledge(older)
        XCTAssertEqual(try CoreCommandQueue(root: root).pending().map(\.id), [newer.id])
    }

    func testCommandSchedulingClassIsDerivedFromSafetySemanticsAndTrigger() throws {
        XCTAssertEqual(
            CoreCommand(kind: .pause, trigger: .backgroundProcessing).schedulingClass,
            .safetyControl
        )
        XCTAssertEqual(
            CoreCommand(kind: .removeDevice, trigger: .appIntent).schedulingClass,
            .safetyControl
        )
        XCTAssertEqual(
            CoreCommand(kind: .removeFolder, trigger: .foreground).schedulingClass,
            .safetyControl
        )
        XCTAssertEqual(
            CoreCommand(kind: .ignorePendingDevice, trigger: .fileProvider).schedulingClass,
            .safetyControl
        )
        XCTAssertEqual(
            CoreCommand(kind: .ignorePendingFolder, trigger: .user).schedulingClass,
            .safetyControl
        )

        for kind in [
            CoreCommandKind.resume,
            .unignorePendingDevice,
            .unignorePendingFolder,
            .addDevice,
            .editDevice,
            .acceptDevice,
            .addFolder,
            .editFolder,
            .acceptFolder,
        ] {
            XCTAssertEqual(
                CoreCommand(kind: kind, trigger: .backgroundProcessing).schedulingClass,
                .userConfiguration
            )
        }

        XCTAssertEqual(
            CoreCommand(kind: .modify, trigger: .fileProvider).schedulingClass,
            .fileProvider
        )
        XCTAssertEqual(CoreCommand(kind: .sync, trigger: .user).schedulingClass, .appUser)
        XCTAssertEqual(CoreCommand(kind: .sync, trigger: .appIntent).schedulingClass, .appIntent)
        XCTAssertEqual(
            CoreCommand(kind: .sync, trigger: .backgroundRefresh).schedulingClass,
            .background
        )
        XCTAssertEqual(
            CoreCommand(kind: .sync, trigger: .backgroundProcessing).schedulingClass,
            .background
        )
        XCTAssertEqual(
            CoreCommand(kind: .rescan, trigger: .foreground).schedulingClass,
            .maintenance
        )
    }

    func testNextRunnableUsesTrustedClassWhilePendingPreservesStorageOrder() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CoreCommandQueue(root: root)
        let commands = [
            CoreCommand(
                kind: .rescan,
                arguments: ["priority": "999999", "sourceClass": "safetyControl"],
                trigger: .foreground,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            CoreCommand(
                kind: .sync,
                arguments: ["priority": "999999"],
                trigger: .backgroundProcessing,
                createdAt: Date(timeIntervalSince1970: 2)
            ),
            CoreCommand(kind: .sync, trigger: .appIntent, createdAt: Date(timeIntervalSince1970: 3)),
            CoreCommand(kind: .sync, trigger: .user, createdAt: Date(timeIntervalSince1970: 4)),
            CoreCommand(kind: .modify, trigger: .fileProvider, createdAt: Date(timeIntervalSince1970: 5)),
            CoreCommand(kind: .resume, trigger: .user, createdAt: Date(timeIntervalSince1970: 6)),
            CoreCommand(kind: .pause, trigger: .user, createdAt: Date(timeIntervalSince1970: 7)),
        ]
        for command in commands.reversed() {
            try queue.enqueue(command)
        }

        XCTAssertEqual(try queue.pending().map(\.id), commands.map(\.id))
        var alreadySelected = Set<UUID>()
        var scheduled: [CoreCommand] = []
        while let next = try queue.nextRunnable(isRunnable: { !alreadySelected.contains($0.id) }) {
            alreadySelected.insert(next.id)
            scheduled.append(next)
        }
        XCTAssertEqual(
            scheduled.map(\.schedulingClass),
            [
                .safetyControl,
                .userConfiguration,
                .fileProvider,
                .appUser,
                .appIntent,
                .background,
                .maintenance,
            ]
        )
        XCTAssertEqual(scheduled.first?.kind, .pause)
        XCTAssertEqual(scheduled.last?.kind, .rescan)
    }

    func testPendingSafetyStopsOutrankEarlierResumeAndCannotBeForged() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CoreCommandQueue(root: root)
        let resume = CoreCommand(
            kind: .resume,
            arguments: ["priority": String(Int.max), "schedulingClass": "safetyControl"],
            trigger: .user,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let remove = CoreCommand(
            kind: .removeFolder,
            trigger: .user,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let pause = CoreCommand(
            kind: .pause,
            trigger: .user,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        try queue.enqueue(resume)
        try queue.enqueue(pause)
        try queue.enqueue(remove)

        XCTAssertEqual(try queue.nextRunnable()?.id, remove.id)
        XCTAssertEqual(
            try queue.nextRunnable(isRunnable: { $0.id != remove.id })?.id,
            pause.id
        )
        XCTAssertEqual(
            try queue.nextRunnable(isRunnable: { $0.id == resume.id })?.id,
            resume.id
        )
    }

    func testNextRunnableAppliesFolderPriorityOnlyInsideSourceClassAndUsesFIFO() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CoreCommandQueue(root: root)
        let lowFolder = try XCTUnwrap(FolderID(rawValue: "low-folder"))
        let highFolder = try XCTUnwrap(FolderID(rawValue: "high-folder"))
        let invalidFolder = try XCTUnwrap(FolderID(rawValue: "invalid-folder"))
        let missingFolder = try XCTUnwrap(FolderID(rawValue: "missing-folder"))
        let high = CoreCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            kind: .sync,
            folderID: highFolder,
            trigger: .backgroundProcessing,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let low = CoreCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            kind: .sync,
            folderID: lowFolder,
            arguments: ["folderPriority": "high"],
            trigger: .backgroundProcessing,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let invalidIsNormal = CoreCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: .sync,
            folderID: invalidFolder,
            trigger: .backgroundProcessing,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let missingIsNormal = CoreCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            kind: .sync,
            folderID: missingFolder,
            trigger: .backgroundProcessing,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let higherClassAlwaysWins = CoreCommand(
            kind: .sync,
            folderID: lowFolder,
            trigger: .appIntent,
            createdAt: Date(timeIntervalSince1970: 40)
        )
        for command in [high, low, invalidIsNormal, missingIsNormal, higherClassAlwaysWins] {
            try queue.enqueue(command)
        }
        let priorities: [FolderID: Int] = [
            lowFolder: CoreFolderSchedulingPriority.low.rawValue,
            highFolder: CoreFolderSchedulingPriority.high.rawValue,
            invalidFolder: 42,
        ]
        let resolve: (FolderID) -> Int? = { priorities[$0] }

        XCTAssertEqual(
            try queue.nextRunnable(folderPriorityResolver: resolve)?.id,
            higherClassAlwaysWins.id
        )
        XCTAssertEqual(
            try queue.nextRunnable(
                folderPriorityResolver: resolve,
                isRunnable: { $0.id != higherClassAlwaysWins.id }
            )?.id,
            high.id
        )
        XCTAssertEqual(
            try queue.nextRunnable(
                folderPriorityResolver: resolve,
                isRunnable: { $0.id != higherClassAlwaysWins.id && $0.id != high.id }
            )?.id,
            invalidIsNormal.id
        )
        XCTAssertEqual(
            try queue.nextRunnable(
                folderPriorityResolver: resolve,
                isRunnable: {
                    ![
                        higherClassAlwaysWins.id,
                        high.id,
                        invalidIsNormal.id,
                    ].contains($0.id)
                }
            )?.id,
            missingIsNormal.id
        )
    }

    func testNextRunnableSkipsDeferredHigherClassWithoutStarvingRunnableWork() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CoreCommandQueue(root: root)
        let blockedSafety = CoreCommand(
            kind: .pause,
            trigger: .user,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let runnableBackground = CoreCommand(
            kind: .sync,
            trigger: .backgroundProcessing,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try queue.enqueue(blockedSafety)
        try queue.enqueue(runnableBackground)

        XCTAssertEqual(
            try queue.nextRunnable(isRunnable: { $0.id != blockedSafety.id })?.id,
            runnableBackground.id
        )
        XCTAssertNil(try queue.nextRunnable(isRunnable: { _ in false }))
        XCTAssertEqual(try queue.pending().map(\.id), [blockedSafety.id, runnableBackground.id])
    }

    func testNextRunnableReadsLegacyCommandAndIgnoresUnknownPriorityFields() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = root.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let legacy = Data(
            """
            {
              "id": "\(id.uuidString)",
              "kind": "sync",
              "folderID": "legacy-folder",
              "arguments": {},
              "trigger": "backgroundProcessing",
              "createdAt": 10,
              "priority": 999999,
              "schedulingClass": "safetyControl",
              "folderPriority": "high"
            }
            """.utf8
        )
        try legacy.write(
            to: pending.appendingPathComponent(
                "00000000000010000000-\(id.uuidString.lowercased()).json"
            )
        )

        let recovered = try XCTUnwrap(CoreCommandQueue(root: root).nextRunnable())
        XCTAssertEqual(recovered.id, id)
        XCTAssertEqual(recovered.schedulingClass, .background)
    }

    func testRetryBackoffPersistsAcrossRestartAndManualRetryDoesNotIncrementAttempt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-000000000211")!
        let command = CoreCommand(
            id: commandID,
            kind: .sync,
            folderID: FolderID(rawValue: "retry-folder"),
            trigger: .backgroundProcessing,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let attemptedAt = Date(timeIntervalSince1970: 100)
        let queue = CoreCommandQueue(root: root)
        try queue.enqueue(command)
        try queue.record(
            .init(
                commandID: command.id,
                status: .retryable,
                completedAt: attemptedAt,
                errorCode: "device_offline"
            ),
            at: attemptedAt
        )

        let firstState = try XCTUnwrap(queue.retryState(for: command.id, at: attemptedAt))
        XCTAssertEqual(firstState.attempt, 1)
        XCTAssertEqual(firstState.lastError, "device_offline")
        XCTAssertGreaterThan(firstState.earliestRetryAt, attemptedAt)
        XCTAssertEqual(
            firstState.earliestRetryAt.timeIntervalSince(attemptedAt),
            CoreCommandQueue.retryDelay(for: command, attempt: 1),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            CoreCommandQueue.retryDelay(for: command, attempt: 1),
            29.898_272_238_318_99,
            accuracy: 0.000_000_001,
            "jitter must remain deterministic for a durable command identity"
        )
        XCTAssertGreaterThan(
            CoreCommandQueue.retryDelay(for: command, attempt: 2),
            CoreCommandQueue.retryDelay(for: command, attempt: 1)
        )
        XCTAssertLessThanOrEqual(
            CoreCommandQueue.retryDelay(for: command, attempt: .max),
            1_800,
            "exponential growth must remain inside the trigger's hard ceiling"
        )
        let providerCommand = CoreCommand(
            id: command.id,
            kind: command.kind,
            folderID: command.folderID,
            trigger: .fileProvider,
            createdAt: command.createdAt
        )
        XCTAssertGreaterThan(
            CoreCommandQueue.retryDelay(for: command, attempt: 1),
            CoreCommandQueue.retryDelay(for: providerCommand, attempt: 1),
            "background work must use a more conservative retry envelope"
        )

        let restarted = CoreCommandQueue(root: root)
        XCTAssertNil(
            try restarted.nextRunnable(
                at: firstState.earliestRetryAt.addingTimeInterval(-0.001)
            )
        )
        XCTAssertEqual(
            try restarted.nextRunnable(at: firstState.earliestRetryAt)?.id,
            command.id
        )

        let manualRetryAt = firstState.earliestRetryAt.addingTimeInterval(1)
        XCTAssertTrue(try restarted.retryNow(command.id, at: manualRetryAt))
        let manuallyReleased = try XCTUnwrap(
            restarted.retryState(for: command.id, at: manualRetryAt)
        )
        XCTAssertEqual(manuallyReleased.attempt, 1)
        XCTAssertEqual(manuallyReleased.lastError, "device_offline")
        XCTAssertEqual(manuallyReleased.earliestRetryAt, manualRetryAt)
        XCTAssertEqual(try restarted.nextRunnable(at: manualRetryAt)?.id, command.id)

        try restarted.record(
            .init(
                commandID: command.id,
                status: .retryable,
                completedAt: manualRetryAt,
                errorCode: "database_busy"
            ),
            at: manualRetryAt
        )
        let secondState = try XCTUnwrap(
            restarted.retryState(for: command.id, at: manualRetryAt)
        )
        XCTAssertEqual(secondState.attempt, 2)
        XCTAssertEqual(secondState.lastError, "database_busy")
        XCTAssertEqual(
            secondState.earliestRetryAt.timeIntervalSince(manualRetryAt),
            CoreCommandQueue.retryDelay(for: command, attempt: 2),
            accuracy: 0.000_001
        )
    }

    func testRetryClockRollbackFailsClosedAndTerminalResultClearsState() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = CoreCommand(
            kind: .sync,
            folderID: FolderID(rawValue: "clock-folder"),
            trigger: .backgroundRefresh
        )
        let attemptedAt = Date(timeIntervalSince1970: 200)
        let observedAt = Date(timeIntervalSince1970: 205)
        let queue = CoreCommandQueue(root: root)
        try queue.enqueue(command)
        try queue.record(
            .init(
                commandID: command.id,
                status: .retryable,
                completedAt: attemptedAt,
                errorCode: "network_unavailable"
            ),
            at: attemptedAt
        )
        _ = try queue.nextRunnable(at: observedAt)

        XCTAssertThrowsError(
            try queue.nextRunnable(at: Date(timeIntervalSince1970: 204))
        ) { error in
            guard
                case .retryClockRollback(let lastObservedAt, let proposedAt) =
                    error as? CoreCommandQueueError
            else {
                return XCTFail("Unexpected rollback error: \(error)")
            }
            XCTAssertEqual(lastObservedAt, observedAt)
            XCTAssertEqual(proposedAt, Date(timeIntervalSince1970: 204))
        }

        let safety = CoreCommand(
            kind: .pause,
            folderID: command.folderID,
            trigger: .backgroundProcessing
        )
        try queue.enqueue(safety)
        XCTAssertEqual(
            try queue.nextRunnable(at: Date(timeIntervalSince1970: 204))?.id,
            safety.id,
            "clock rollback in background retry state must not swallow a safety stop"
        )

        try queue.record(
            .init(
                commandID: command.id,
                status: .blocked,
                completedAt: observedAt,
                errorCode: "version_conflict"
            ),
            at: observedAt
        )
        XCTAssertNil(try queue.retryState(for: command.id, at: observedAt))
        XCTAssertEqual(try queue.result(for: command.id)?.status, .blocked)

        let succeeds = CoreCommand(
            kind: .sync,
            folderID: FolderID(rawValue: "success-folder"),
            trigger: .backgroundProcessing
        )
        let secondFailureAt = Date(timeIntervalSince1970: 206)
        let succeededAt = Date(timeIntervalSince1970: 207)
        try queue.enqueue(succeeds)
        try queue.record(
            .init(
                commandID: succeeds.id,
                status: .retryable,
                completedAt: secondFailureAt,
                errorCode: "device_offline"
            ),
            at: secondFailureAt
        )
        XCTAssertNotNil(try queue.retryState(for: succeeds.id, at: secondFailureAt))
        try queue.record(
            .init(
                commandID: succeeds.id,
                status: .succeeded,
                completedAt: succeededAt
            ),
            at: succeededAt
        )
        XCTAssertNil(try queue.retryState(for: succeeds.id, at: succeededAt))
    }

    func testRetryScheduleMigratesAndScansPast4096DeferredCommands() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CoreCommandQueue(root: root)
        let deferredFolder = try XCTUnwrap(FolderID(rawValue: "deferred-folder"))
        let eligibleFolder = try XCTUnwrap(FolderID(rawValue: "eligible-folder"))
        let deferred = (0..<CoreCommandQueue.maximumBatchCommands).map { index in
            CoreCommand(
                id: UUID(
                    uuidString: String(
                        format: "00000000-0000-0000-0000-%012llx",
                        UInt64(index + 1)
                    )
                )!,
                kind: .sync,
                folderID: deferredFolder,
                trigger: .backgroundProcessing,
                createdAt: Date(timeIntervalSince1970: Double(index + 1))
            )
        }
        try queue.enqueueAtomically(
            deferred,
            batchID: UUID(uuidString: "00000000-0000-0000-0000-00000000ba7c")!
        )
        let eligible = CoreCommand(
            kind: .sync,
            folderID: eligibleFolder,
            trigger: .backgroundProcessing,
            createdAt: Date(timeIntervalSince1970: 5_000)
        )
        let safety = CoreCommand(
            kind: .pause,
            folderID: deferredFolder,
            trigger: .backgroundProcessing,
            createdAt: Date(timeIntervalSince1970: 5_001)
        )
        try queue.enqueue(eligible)
        try queue.enqueue(safety)

        let legacyEntries: [[String: Any]] = deferred.map {
            [
                "commandID": $0.id.uuidString,
                "attempt": 1,
                "lastError": "device_offline",
                "earliestRetryAt": 1_000,
            ]
        }
        let legacyDocument: [String: Any] = [
            "schemaVersion": 1,
            "entries": legacyEntries,
        ]
        let retryURL = root.appendingPathComponent(CoreCommandQueue.retryScheduleFilename)
        try JSONSerialization.data(
            withJSONObject: legacyDocument,
            options: [.sortedKeys]
        ).write(to: retryURL, options: .atomic)
        let now = Date(timeIntervalSince1970: 100)
        let priorities = [
            deferredFolder: CoreFolderSchedulingPriority.high.rawValue,
            eligibleFolder: CoreFolderSchedulingPriority.low.rawValue,
        ]

        XCTAssertEqual(
            try queue.nextRunnable(
                at: now,
                folderPriorityResolver: { priorities[$0] }
            )?.id,
            safety.id,
            "a safety stop must bypass every background retry deadline"
        )
        XCTAssertEqual(
            try queue.nextRunnable(
                at: now,
                folderPriorityResolver: { priorities[$0] },
                isRunnable: { $0.id != safety.id }
            )?.id,
            eligible.id,
            "the 4,098th pending entry must run across folders when 4,096 are not due"
        )
        let migrated = try XCTUnwrap(queue.retryState(for: deferred[0].id, at: now))
        XCTAssertEqual(migrated.attempt, 1)
        XCTAssertEqual(migrated.lastError, "device_offline")
        XCTAssertEqual(migrated.earliestRetryAt, Date(timeIntervalSince1970: 1_000))
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: retryURL)) as? [String: Any]
        )
        XCTAssertEqual(persisted["schemaVersion"] as? Int, 2)
    }

    func testPerFolderAndKindEnqueueDeduplicationIsAtomic() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CoreCommandQueue(root: root)
        let folder = try XCTUnwrap(FolderID(rawValue: "background-folder"))

        let inserted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for attempt in 0..<24 {
                group.addTask {
                    let command = CoreCommand(
                        kind: .sync,
                        folderID: folder,
                        arguments: ["attempt": String(attempt)],
                        trigger: .backgroundProcessing,
                        createdAt: Date(timeIntervalSince1970: Double(attempt))
                    )
                    return (try? queue.enqueueIfNoPendingCommandInSameFolderAndKind(command)) == true
                }
            }
            var count = 0
            for await didInsert in group where didInsert {
                count += 1
            }
            return count
        }

        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(try queue.pending().count, 1)
        XCTAssertThrowsError(
            try queue.enqueueIfNoPendingCommandInSameFolderAndKind(
                CoreCommand(kind: .sync, folderID: folder, trigger: .user)
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreCommandQueueError,
                .backgroundTriggerRequiredForDeduplication
            )
        }
        let manualFolder = try XCTUnwrap(FolderID(rawValue: "manual-folder"))
        try queue.enqueue(CoreCommand(kind: .sync, folderID: manualFolder, trigger: .user))
        XCTAssertFalse(
            try queue.enqueueIfNoPendingCommandInSameFolderAndKind(
                CoreCommand(kind: .sync, folderID: manualFolder, trigger: .backgroundRefresh)
            )
        )
        let differentKind = CoreCommand(
            kind: .rescan,
            folderID: folder,
            trigger: .backgroundProcessing
        )
        XCTAssertTrue(try queue.enqueueIfNoPendingCommandInSameFolderAndKind(differentKind))
        let otherFolder = try XCTUnwrap(FolderID(rawValue: "other-folder"))
        XCTAssertTrue(
            try queue.enqueueIfNoPendingCommandInSameFolderAndKind(
                CoreCommand(kind: .sync, folderID: otherFolder, trigger: .backgroundRefresh)
            )
        )
        XCTAssertThrowsError(
            try queue.enqueueIfNoPendingCommandInSameFolderAndKind(
                CoreCommand(kind: .sync, trigger: .backgroundProcessing)
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreCommandQueueError,
                .folderIDRequiredForDeduplication
            )
        }
    }

    func testCommandQueueIsIdempotentAndRejectsIdentifierCollisions() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let command = CoreCommand(
            id: id,
            kind: .sync,
            trigger: .appIntent,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let queue = CoreCommandQueue(root: root)
        try queue.enqueue(command)
        try queue.enqueue(command)
        XCTAssertEqual(try queue.pending().count, 1)

        let collision = CoreCommand(
            id: id,
            kind: .delete,
            trigger: .appIntent,
            createdAt: command.createdAt
        )
        XCTAssertThrowsError(try queue.enqueue(collision)) { error in
            XCTAssertEqual(error as? CoreCommandQueueError, .identifierCollision(id))
        }

        let incarnationCollision = CoreCommand(
            id: id,
            kind: command.kind,
            folderIncarnationDigest: String(repeating: "b", count: 64),
            trigger: command.trigger,
            createdAt: command.createdAt
        )
        XCTAssertThrowsError(try queue.enqueue(incarnationCollision)) { error in
            XCTAssertEqual(error as? CoreCommandQueueError, .identifierCollision(id))
        }

        let revisionCollision = CoreCommand(
            id: id,
            kind: command.kind,
            commandConfigurationRevision: String(repeating: "c", count: 64),
            trigger: command.trigger,
            createdAt: command.createdAt
        )
        XCTAssertThrowsError(try queue.enqueue(revisionCollision)) { error in
            XCTAssertEqual(error as? CoreCommandQueueError, .identifierCollision(id))
        }
    }

    func testCommandPreconditionsRoundTripAndLegacyDecodeAsNil() throws {
        let command = CoreCommand(
            kind: .removeFolder,
            folderID: FolderID(rawValue: "folder-alpha"),
            folderIncarnationDigest: String(repeating: "a", count: 64),
            commandConfigurationRevision: String(repeating: "b", count: 64),
            trigger: .user
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoded = try encoder.encode(command)
        let decoded = try decoder.decode(CoreCommand.self, from: encoded)
        XCTAssertEqual(decoded.folderIncarnationDigest, command.folderIncarnationDigest)
        XCTAssertEqual(
            decoded.commandConfigurationRevision,
            command.commandConfigurationRevision
        )

        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacy.removeValue(forKey: "folderIncarnationDigest")
        legacy.removeValue(forKey: "commandConfigurationRevision")
        let legacyCommand = try decoder.decode(
            CoreCommand.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertNil(legacyCommand.folderIncarnationDigest)
        XCTAssertNil(legacyCommand.commandConfigurationRevision)
    }

    func testSuppressionRevisionRemainsPartOfLocalQueueSemantics() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let folderID = try XCTUnwrap(FolderID(rawValue: "pending-folder"))
        let command = CoreCommand(
            id: id,
            kind: .ignorePendingFolder,
            folderID: folderID,
            commandConfigurationRevision: String(repeating: "a", count: 64),
            trigger: .user,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let queue = CoreCommandQueue(root: root)
        try queue.enqueue(command)
        try queue.enqueue(command)

        var collision = command
        collision.commandConfigurationRevision = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try queue.enqueue(collision)) { error in
            XCTAssertEqual(error as? CoreCommandQueueError, .identifierCollision(id))
        }
    }

    func testCommandResultSurvivesRestartAndSuccessCannotRegress() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let queue = CoreCommandQueue(root: root)
        try queue.record(.init(commandID: id, status: .succeeded, snapshotGeneration: 7))
        try CoreCommandQueue(root: root).record(
            .init(commandID: id, status: .failed, errorCode: "lateFailure")
        )
        let recovered = try CoreCommandQueue(root: root).result(for: id)
        XCTAssertEqual(recovered?.status, .succeeded)
        XCTAssertEqual(recovered?.snapshotGeneration, 7)
    }

    func testSnapshotGenerationCannotRegress() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SharedSnapshotStore(snapshotURL: root.appendingPathComponent("snapshot.json"))
        try store.write(.init(generation: 2))
        XCTAssertThrowsError(try store.write(.init(generation: 1))) { error in
            guard case SharedSnapshotError.generationRegression(current: 2, proposed: 1) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try store.read()?.generation, 2)
    }

    func testBundledBridgeCapabilityIncludesContentLifecycleCommands() {
        XCTAssertEqual(
            Set(CoreCommandKind.allCases.filter { $0.embeddedBridgeCapability == .unsupported }),
            []
        )
        for kind in [CoreCommandKind.materialize, .pin] {
            XCTAssertEqual(kind.requestedSyncActions, [.exchangeIndex, .download])
        }
        XCTAssertEqual(CoreCommandKind.evict.requestedSyncActions, [.evictLocalCopy])
        for kind in [CoreCommandKind.create, .modify, .move, .delete] {
            XCTAssertEqual(kind.requestedSyncActions, [.scan, .hash])
            XCTAssertEqual(kind.networkSessionOperation, .localMutation)
            XCTAssertEqual(kind.networkCorePolicyActions, [.scan, .hash])
        }
        for kind in [CoreCommandKind.disposeRecovery, .disposeRecoveryReviewed] {
            XCTAssertEqual(kind.embeddedBridgeCapability, .supported)
            XCTAssertEqual(kind.requestedSyncActions, [.scan, .hash])
            XCTAssertTrue(CoreCommand(kind: kind, trigger: .user).supportsNativeFailureReplay)
        }
    }

    func testPendingOfferContractsRejectUnsafeRiskFieldsAndProjectionContradictions() throws {
        let canonicalDeviceID =
            "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
        XCTAssertEqual(
            DeviceID(syncthingString: canonicalDeviceID)?.rawValue,
            canonicalDeviceID
        )
        XCTAssertEqual(
            DeviceID(
                syncthingString:
                    "p561017mzjnu2yiqgdreydm2mgtimgl3bxnpq6w5bmt88z4tjxzwicq2"
            )?.rawValue,
            canonicalDeviceID
        )
        XCTAssertEqual(
            DeviceID(
                syncthingString:
                    "P56IOI7MZJNU2IQGDREYDM2MGTMGL3BXNPQ6W5BTBBZ4TJXZWICQ"
            )?.rawValue,
            canonicalDeviceID
        )
        XCTAssertNil(
            DeviceID(
                syncthingString:
                    "***REMOVED***"
            )
        )

        let localID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let offeringID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let unknownID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "C", count: 56)))
        let folderID = try XCTUnwrap(FolderID(rawValue: "pending-folder"))
        let version = canonicalOfferVersion(byte: 1)
        let pendingDevice = try PendingDeviceOffer(
            deviceID: unknownID,
            label: "Unknown peer",
            lastSeen: Date(timeIntervalSince1970: 1),
            offerVersion: version,
            unverifiedIdentity: true,
            requiresExplicitAcceptance: true
        )
        let pendingFolder = try PendingFolderOffer(
            folderID: folderID,
            label: "Shared folder",
            offeringDeviceID: offeringID,
            lastSeen: Date(timeIntervalSince1970: 2),
            offerVersion: canonicalOfferVersion(byte: 2),
            receiveEncrypted: false,
            remoteEncrypted: false,
            requiresManagedLocalPath: true,
            requiresExplicitDeviceSelection: true
        )
        let snapshot = CoreSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            localDeviceID: localID,
            devices: [
                DeviceRecord(id: localID, name: "This device"),
                DeviceRecord(id: offeringID, name: "Offering peer"),
            ],
            pendingDevices: [pendingDevice],
            pendingFolders: [pendingFolder],
            pendingDeviceObservationScope: .bridgeEventsPersisted,
            pendingFoldersAvailable: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(CoreSnapshot.self, from: encoder.encode(snapshot)), snapshot)

        XCTAssertThrowsError(
            try PendingDeviceOffer(
                deviceID: unknownID,
                label: "Unknown peer",
                lastSeen: .now,
                offerVersion: "not-a-version",
                unverifiedIdentity: true,
                requiresExplicitAcceptance: true
            )
        )
        XCTAssertThrowsError(
            try PendingDeviceOffer(
                deviceID: unknownID,
                label: "Unknown peer",
                lastSeen: .now,
                offerVersion: version,
                unverifiedIdentity: false,
                requiresExplicitAcceptance: true
            )
        )

        let unavailableWithOffer = CoreSnapshot(
            pendingDevices: [pendingDevice],
            pendingDeviceObservationScope: .unavailable
        )
        XCTAssertThrowsError(
            try decoder.decode(CoreSnapshot.self, from: encoder.encode(unavailableWithOffer))
        )
        let unavailableTruncatedFolders = CoreSnapshot(
            pendingFoldersAvailable: false,
            pendingFoldersTruncated: true
        )
        XCTAssertThrowsError(
            try decoder.decode(CoreSnapshot.self, from: encoder.encode(unavailableTruncatedFolders))
        )
        let duplicateDevices = CoreSnapshot(
            pendingDevices: [pendingDevice, pendingDevice],
            pendingDeviceObservationScope: .bridgeEventsPersisted
        )
        XCTAssertThrowsError(
            try decoder.decode(CoreSnapshot.self, from: encoder.encode(duplicateDevices))
        )
    }

    func testPendingAcceptanceCommandsUseOnlyReviewedOfferAndManagedInputs() throws {
        let offeringID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let otherID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "C", count: 56)))
        let folderID = try XCTUnwrap(FolderID(rawValue: "pending-folder"))
        let deviceOffer = try PendingDeviceOffer(
            deviceID: offeringID,
            label: "Observed label",
            lastSeen: .now,
            offerVersion: canonicalOfferVersion(byte: 3),
            unverifiedIdentity: true,
            requiresExplicitAcceptance: true
        )
        let deviceCommand = try PendingAcceptanceCommandBuilder.device(
            offer: deviceOffer,
            name: "  Verified peer  ",
            paused: true
        )
        XCTAssertEqual(deviceCommand.kind, .acceptDevice)
        XCTAssertNil(deviceCommand.folderID)
        XCTAssertEqual(deviceCommand.itemID, offeringID.rawValue)
        XCTAssertEqual(
            deviceCommand.arguments,
            [
                "offerVersion": deviceOffer.offerVersion,
                "name": "Verified peer",
                "paused": "true",
            ]
        )
        XCTAssertNil(deviceCommand.arguments["addresses"])

        let folderOffer = try PendingFolderOffer(
            folderID: folderID,
            label: "Observed folder",
            offeringDeviceID: offeringID,
            lastSeen: .now,
            offerVersion: canonicalOfferVersion(byte: 4),
            receiveEncrypted: false,
            remoteEncrypted: false,
            requiresManagedLocalPath: true,
            requiresExplicitDeviceSelection: true
        )
        let folderProof = observationProof(for: folderOffer)
        let folderCommand = try PendingAcceptanceCommandBuilder.folder(
            offer: folderOffer,
            observationProof: folderProof,
            label: "  Local label  ",
            managedPath: "/private/tmp/AppGroup/ManagedFolders/Folders/folder-safe",
            type: .sendReceive,
            paused: false,
            deviceIDs: [otherID, offeringID],
            rescanIntervalS: 3600
        )
        XCTAssertEqual(folderCommand.kind, .acceptFolder)
        XCTAssertEqual(folderCommand.folderID, folderID)
        XCTAssertNil(folderCommand.itemID)
        XCTAssertEqual(folderCommand.arguments["offeringDeviceID"], offeringID.rawValue)
        XCTAssertEqual(folderCommand.arguments["offerVersion"], folderOffer.offerVersion)
        XCTAssertEqual(folderCommand.arguments["label"], "Local label")
        XCTAssertEqual(
            folderCommand.arguments["path"],
            "/private/tmp/AppGroup/ManagedFolders/Folders/folder-safe"
        )
        XCTAssertEqual(folderCommand.arguments["type"], FolderType.sendReceive.rawValue)
        XCTAssertEqual(folderCommand.arguments["paused"], "false")
        XCTAssertEqual(
            folderCommand.arguments["deviceIDs"],
            "[\"\(offeringID.rawValue)\",\"\(otherID.rawValue)\"]"
        )
        XCTAssertEqual(folderCommand.arguments["rescanIntervalS"], "3600")

        XCTAssertThrowsError(
            try PendingAcceptanceCommandBuilder.folder(
                offer: folderOffer,
                observationProof: folderProof,
                label: "Local label",
                managedPath: "/private/tmp/managed",
                type: .sendReceive,
                paused: false,
                deviceIDs: [otherID],
                rescanIntervalS: 3600
            )
        )
        XCTAssertThrowsError(
            try PendingAcceptanceCommandBuilder.folder(
                offer: folderOffer,
                observationProof: folderProof,
                label: "Local label",
                managedPath: "relative/remote/path",
                type: .sendReceive,
                paused: false,
                deviceIDs: [offeringID],
                rescanIntervalS: 3600
            )
        )
        XCTAssertThrowsError(
            try PendingAcceptanceCommandBuilder.folder(
                offer: folderOffer,
                observationProof: folderProof,
                label: "Local label",
                managedPath: "/private/tmp/managed",
                type: .receiveEncrypted,
                paused: false,
                deviceIDs: [offeringID],
                rescanIntervalS: 3600
            )
        )
        let encryptedOffer = try PendingFolderOffer(
            folderID: folderID,
            label: "Encrypted folder",
            offeringDeviceID: offeringID,
            lastSeen: .now,
            offerVersion: canonicalOfferVersion(byte: 5),
            receiveEncrypted: true,
            remoteEncrypted: false,
            requiresManagedLocalPath: true,
            requiresExplicitDeviceSelection: true
        )
        XCTAssertThrowsError(
            try PendingAcceptanceCommandBuilder.folder(
                offer: encryptedOffer,
                observationProof: observationProof(for: encryptedOffer),
                label: "Encrypted folder",
                managedPath: "/private/tmp/managed",
                type: .sendReceive,
                paused: false,
                deviceIDs: [offeringID],
                rescanIntervalS: 3600
            )
        ) { error in
            XCTAssertEqual(
                error as? PendingAcceptanceCommandError,
                .encryptedFolderTypeMismatch
            )
        }
    }

    func testSuppressedPendingProjectionDecodesOlderSnapshotsAndRejectsContradictions() throws {
        let localID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let offeringID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let unknownID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "C", count: 56)))
        let folderID = try XCTUnwrap(FolderID(rawValue: "suppressed-folder"))
        let pendingDevice = try PendingDeviceOffer(
            deviceID: unknownID,
            label: "Untrusted label",
            lastSeen: Date(timeIntervalSince1970: 1),
            offerVersion: canonicalOfferVersion(byte: 10),
            unverifiedIdentity: true,
            requiresExplicitAcceptance: true
        )
        let pendingFolder = try PendingFolderOffer(
            folderID: folderID,
            label: "Encrypted remote label",
            offeringDeviceID: offeringID,
            lastSeen: Date(timeIntervalSince1970: 2),
            offerVersion: canonicalOfferVersion(byte: 11),
            receiveEncrypted: true,
            remoteEncrypted: true,
            requiresManagedLocalPath: true,
            requiresExplicitDeviceSelection: true
        )
        let suppressedDevice = try SuppressedPendingDevice(
            deviceID: unknownID,
            suppressionVersion: canonicalOfferVersion(byte: 12)
        )
        let suppressedFolder = try SuppressedPendingFolder(
            folderID: folderID,
            offeringDeviceID: offeringID,
            suppressionVersion: canonicalOfferVersion(byte: 13)
        )
        XCTAssertThrowsError(
            try SuppressedPendingDevice(
                deviceID: unknownID,
                suppressionVersion: "not-a-version"
            )
        )
        XCTAssertThrowsError(
            try SuppressedPendingFolder(
                folderID: folderID,
                offeringDeviceID: offeringID,
                suppressionVersion: "not-a-version"
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var oldObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(
                    CoreSnapshot(
                        generatedAt: Date(timeIntervalSince1970: 0),
                        localDeviceID: localID,
                        devices: [
                            DeviceRecord(id: localID, name: "This device"),
                            DeviceRecord(id: offeringID, name: "Offering peer"),
                        ]
                    )
                )
            ) as? [String: Any]
        )
        oldObject.removeValue(forKey: "suppressedPendingDevices")
        oldObject.removeValue(forKey: "suppressedPendingFolders")
        oldObject.removeValue(forKey: "suppressedPendingStateAvailable")
        oldObject.removeValue(forKey: "suppressedPendingDevicesTruncated")
        oldObject.removeValue(forKey: "suppressedPendingFoldersTruncated")
        let oldSnapshot = try decoder.decode(
            CoreSnapshot.self,
            from: JSONSerialization.data(withJSONObject: oldObject)
        )
        XCTAssertTrue(oldSnapshot.suppressedPendingDevices.isEmpty)
        XCTAssertTrue(oldSnapshot.suppressedPendingFolders.isEmpty)
        XCTAssertFalse(oldSnapshot.suppressedPendingStateAvailable)
        XCTAssertFalse(oldSnapshot.suppressedPendingDevicesTruncated)
        XCTAssertFalse(oldSnapshot.suppressedPendingFoldersTruncated)

        let unavailableWithSuppression = CoreSnapshot(
            localDeviceID: localID,
            devices: [
                DeviceRecord(id: localID, name: "This device"),
                DeviceRecord(id: offeringID, name: "Offering peer"),
            ],
            suppressedPendingDevices: [suppressedDevice]
        )
        XCTAssertThrowsError(
            try decoder.decode(CoreSnapshot.self, from: encoder.encode(unavailableWithSuppression))
        )

        let unavailableAndTruncated = CoreSnapshot(
            suppressedPendingStateAvailable: false,
            suppressedPendingFoldersTruncated: true
        )
        XCTAssertThrowsError(
            try decoder.decode(CoreSnapshot.self, from: encoder.encode(unavailableAndTruncated))
        )

        let pendingSuppressedDeviceConflict = CoreSnapshot(
            localDeviceID: localID,
            devices: [
                DeviceRecord(id: localID, name: "This device"),
                DeviceRecord(id: offeringID, name: "Offering peer"),
            ],
            pendingDevices: [pendingDevice],
            pendingDeviceObservationScope: .bridgeEventsPersisted,
            suppressedPendingDevices: [suppressedDevice],
            suppressedPendingStateAvailable: true
        )
        XCTAssertThrowsError(
            try decoder.decode(CoreSnapshot.self, from: encoder.encode(pendingSuppressedDeviceConflict))
        )

        let pendingSuppressedFolderConflict = CoreSnapshot(
            localDeviceID: localID,
            devices: [
                DeviceRecord(id: localID, name: "This device"),
                DeviceRecord(id: offeringID, name: "Offering peer"),
            ],
            pendingFolders: [pendingFolder],
            pendingFoldersAvailable: true,
            suppressedPendingFolders: [suppressedFolder],
            suppressedPendingStateAvailable: true
        )
        XCTAssertThrowsError(
            try decoder.decode(CoreSnapshot.self, from: encoder.encode(pendingSuppressedFolderConflict))
        )

        let duplicateSuppressedDevices = CoreSnapshot(
            localDeviceID: localID,
            devices: [
                DeviceRecord(id: localID, name: "This device"),
                DeviceRecord(id: offeringID, name: "Offering peer"),
            ],
            suppressedPendingDevices: [suppressedDevice, suppressedDevice],
            suppressedPendingStateAvailable: true
        )
        XCTAssertThrowsError(
            try decoder.decode(CoreSnapshot.self, from: encoder.encode(duplicateSuppressedDevices))
        )

        let configuredDeviceSuppression = try SuppressedPendingDevice(
            deviceID: offeringID,
            suppressionVersion: canonicalOfferVersion(byte: 14)
        )
        let configuredSuppressed = CoreSnapshot(
            localDeviceID: localID,
            devices: [
                DeviceRecord(id: localID, name: "This device"),
                DeviceRecord(id: offeringID, name: "Offering peer"),
            ],
            suppressedPendingDevices: [configuredDeviceSuppression],
            suppressedPendingStateAvailable: true
        )
        XCTAssertThrowsError(
            try decoder.decode(CoreSnapshot.self, from: encoder.encode(configuredSuppressed))
        )
    }

    func testPendingSuppressionCommandsContainOnlyIdentityAndVersionProofs() throws {
        let deviceID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "C", count: 56)))
        let offeringID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let folderID = try XCTUnwrap(FolderID(rawValue: "encrypted-folder"))
        let deviceOffer = try PendingDeviceOffer(
            deviceID: deviceID,
            label: "Private advertised label",
            lastSeen: .now,
            offerVersion: canonicalOfferVersion(byte: 20),
            unverifiedIdentity: true,
            requiresExplicitAcceptance: true
        )
        let folderOffer = try PendingFolderOffer(
            folderID: folderID,
            label: "Private encrypted label",
            offeringDeviceID: offeringID,
            lastSeen: .now,
            offerVersion: canonicalOfferVersion(byte: 21),
            receiveEncrypted: true,
            remoteEncrypted: true,
            requiresManagedLocalPath: true,
            requiresExplicitDeviceSelection: true
        )
        let folderProof = observationProof(for: folderOffer)
        let deviceSuppression = try SuppressedPendingDevice(
            deviceID: deviceID,
            suppressionVersion: canonicalOfferVersion(byte: 22)
        )
        let folderSuppression = try SuppressedPendingFolder(
            folderID: folderID,
            offeringDeviceID: offeringID,
            suppressionVersion: canonicalOfferVersion(byte: 23)
        )

        let ignoreDevice = PendingSuppressionCommandBuilder.ignoreDevice(deviceOffer)
        XCTAssertEqual(ignoreDevice.kind, .ignorePendingDevice)
        XCTAssertNil(ignoreDevice.folderID)
        XCTAssertEqual(ignoreDevice.itemID, deviceID.rawValue)
        XCTAssertEqual(ignoreDevice.arguments, ["offerVersion": deviceOffer.offerVersion])

        let allowDevice = PendingSuppressionCommandBuilder.unignoreDevice(deviceSuppression)
        XCTAssertEqual(allowDevice.kind, .unignorePendingDevice)
        XCTAssertNil(allowDevice.folderID)
        XCTAssertEqual(allowDevice.itemID, deviceID.rawValue)
        XCTAssertEqual(
            allowDevice.arguments,
            ["suppressionVersion": deviceSuppression.suppressionVersion]
        )

        let ignoreFolder = try PendingSuppressionCommandBuilder.ignoreFolder(
            folderOffer,
            observationProof: folderProof
        )
        XCTAssertEqual(ignoreFolder.kind, .ignorePendingFolder)
        XCTAssertEqual(ignoreFolder.folderID, folderID)
        XCTAssertNil(ignoreFolder.itemID)
        XCTAssertEqual(
            ignoreFolder.arguments,
            [
                "observationProofID": folderProof.proofID,
                "offeringDeviceID": offeringID.rawValue,
                "offerVersion": folderOffer.offerVersion,
            ]
        )
        XCTAssertNil(ignoreFolder.arguments["label"])
        XCTAssertNil(ignoreFolder.arguments["path"])
        XCTAssertNil(ignoreFolder.arguments["receiveEncrypted"])
        XCTAssertNil(ignoreFolder.arguments["remoteEncrypted"])

        let allowFolder = PendingSuppressionCommandBuilder.unignoreFolder(folderSuppression)
        XCTAssertEqual(allowFolder.kind, .unignorePendingFolder)
        XCTAssertEqual(allowFolder.folderID, folderID)
        XCTAssertNil(allowFolder.itemID)
        XCTAssertEqual(
            allowFolder.arguments,
            [
                "offeringDeviceID": offeringID.rawValue,
                "suppressionVersion": folderSuppression.suppressionVersion,
            ]
        )

        for kind in [
            CoreCommandKind.ignorePendingDevice,
            .unignorePendingDevice,
            .ignorePendingFolder,
            .unignorePendingFolder,
        ] {
            XCTAssertEqual(kind.embeddedBridgeCapability, .supported)
            XCTAssertTrue(CoreCommand(kind: kind, trigger: .user).supportsNativeFailureReplay)
        }
    }

    func testSuppressionConfirmationRequiresAuthoritativeExactState() throws {
        let localID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let offeringID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let unknownID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "C", count: 56)))
        let folderID = try XCTUnwrap(FolderID(rawValue: "confirmed-folder"))
        let deviceOffer = try PendingDeviceOffer(
            deviceID: unknownID,
            label: "Untrusted label",
            lastSeen: .now,
            offerVersion: canonicalOfferVersion(byte: 30),
            unverifiedIdentity: true,
            requiresExplicitAcceptance: true
        )
        let folderOffer = try PendingFolderOffer(
            folderID: folderID,
            label: "Folder label",
            offeringDeviceID: offeringID,
            lastSeen: .now,
            offerVersion: canonicalOfferVersion(byte: 31),
            receiveEncrypted: true,
            remoteEncrypted: false,
            requiresManagedLocalPath: true,
            requiresExplicitDeviceSelection: true
        )
        let suppressedDevice = try SuppressedPendingDevice(
            deviceID: unknownID,
            suppressionVersion: canonicalOfferVersion(byte: 32)
        )
        let suppressedFolder = try SuppressedPendingFolder(
            folderID: folderID,
            offeringDeviceID: offeringID,
            suppressionVersion: canonicalOfferVersion(byte: 33)
        )
        let configured = [
            DeviceRecord(id: localID, name: "This device"),
            DeviceRecord(id: offeringID, name: "Offering peer"),
        ]
        let confirmed = CoreSnapshot(
            localDeviceID: localID,
            devices: configured,
            suppressedPendingDevices: [suppressedDevice],
            suppressedPendingFolders: [suppressedFolder],
            suppressedPendingStateAvailable: true
        )
        XCTAssertTrue(confirmed.confirmsSuppression(of: deviceOffer))
        XCTAssertTrue(confirmed.confirmsSuppression(of: folderOffer))
        XCTAssertFalse(confirmed.confirmsFutureRequestsAllowed(for: suppressedDevice))
        XCTAssertFalse(confirmed.confirmsFutureRequestsAllowed(for: suppressedFolder))

        let cleared = CoreSnapshot(
            localDeviceID: localID,
            devices: configured,
            suppressedPendingStateAvailable: true
        )
        XCTAssertFalse(cleared.confirmsSuppression(of: deviceOffer))
        XCTAssertFalse(cleared.confirmsSuppression(of: folderOffer))
        XCTAssertTrue(cleared.confirmsFutureRequestsAllowed(for: suppressedDevice))
        XCTAssertTrue(cleared.confirmsFutureRequestsAllowed(for: suppressedFolder))

        let truncatedAbsence = CoreSnapshot(
            localDeviceID: localID,
            devices: configured,
            suppressedPendingStateAvailable: true,
            suppressedPendingDevicesTruncated: true,
            suppressedPendingFoldersTruncated: true
        )
        XCTAssertFalse(truncatedAbsence.confirmsFutureRequestsAllowed(for: suppressedDevice))
        XCTAssertFalse(truncatedAbsence.confirmsFutureRequestsAllowed(for: suppressedFolder))

        let unavailable = CoreSnapshot(localDeviceID: localID, devices: configured)
        XCTAssertFalse(unavailable.confirmsSuppression(of: deviceOffer))
        XCTAssertFalse(unavailable.confirmsFutureRequestsAllowed(for: suppressedDevice))
    }

    #if os(macOS)
        func testSuppressionUIWordingIsLocalizedAndDoesNotPromiseOfferRestoration() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let english = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "App/Resources/en.lproj/Localizable.strings"
                ),
                encoding: .utf8
            )
            let simplifiedChinese = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "App/Resources/zh-Hans.lproj/Localizable.strings"
                ),
                encoding: .utf8
            )
            let devicesView = try String(
                contentsOf: repositoryRoot.appendingPathComponent("App/DevicesView.swift"),
                encoding: .utf8
            )
            let foldersView = try String(
                contentsOf: repositoryRoot.appendingPathComponent("App/FoldersView.swift"),
                encoding: .utf8
            )

            XCTAssertTrue(devicesView.contains("Allow Future Requests"))
            XCTAssertTrue(foldersView.contains("Allow Future Requests"))
            XCTAssertTrue(english.contains("The previous request will not be restored."))
            XCTAssertTrue(english.contains("The previous offer will not be restored."))
            XCTAssertTrue(simplifiedChinese.contains("先前的请求不会恢复"))
            XCTAssertTrue(simplifiedChinese.contains("先前的共享不会恢复"))
            XCTAssertTrue(english.contains("No folder is created"))
            XCTAssertTrue(simplifiedChinese.contains("不会创建文件夹"))
            XCTAssertEqual(localizationKeys(in: english), localizationKeys(in: simplifiedChinese))
        }
    #endif

    func testEnqueueIfEmptyIsAtomicAcrossConcurrentBackgroundLaunches() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CoreCommandQueue(root: root)

        let insertedCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let command = CoreCommand(
                        kind: .sync,
                        arguments: ["attempt": String(index)],
                        trigger: .backgroundProcessing,
                        createdAt: Date(timeIntervalSince1970: 1)
                    )
                    return (try? queue.enqueueIfEmpty(command)) == true
                }
            }
            var count = 0
            for await inserted in group where inserted {
                count += 1
            }
            return count
        }

        XCTAssertEqual(insertedCount, 1)
        XCTAssertEqual(try queue.pending().count, 1)
        XCTAssertEqual(try queue.pending().first?.kind, .sync)
    }

    func testSymlinkEscapeIsRejected() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let candidate = link.appendingPathComponent("secret.txt")
        XCTAssertEqual(
            DestructiveOperationGuard().validateContainedPath(candidate, root: root),
            .failure(.symbolicLinkEscapesRoot)
        )
    }

    func testFileLockRejectsSymbolicLinkLeafWithoutTouchingTarget() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target")
        let original = Data("keep".utf8)
        try original.write(to: target)
        let lock = root.appendingPathComponent("operation.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        var enteredCriticalSection = false

        XCTAssertThrowsError(
            try FileLock.withExclusiveLock(at: lock) {
                enteredCriticalSection = true
            }
        )
        XCTAssertFalse(enteredCriticalSection)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testFileLockRejectsSymbolicLinkParentWithoutCreatingOutsideLock() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedParent = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        let lock = linkedParent.appendingPathComponent("state.lock")

        XCTAssertThrowsError(
            try FileLock.withExclusiveLock(at: lock) {
                XCTFail("Symbolic-link parent unexpectedly allowed a lock")
            }
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("state.lock").path))
    }

    func testFileLockRejectsIntermediateSymbolicLinkBeforeCreatingDirectoriesOutside() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedAncestor = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedAncestor, withDestinationURL: outside)
        let lock =
            linkedAncestor
            .appendingPathComponent("new-parent", isDirectory: true)
            .appendingPathComponent("state.lock")

        XCTAssertThrowsError(
            try FileLock.withExclusiveLock(at: lock) {
                XCTFail("Intermediate symbolic link unexpectedly allowed a lock")
            }
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("new-parent", isDirectory: true).path
            )
        )
    }

    func testFileLockDetectsReboundAncestorAfterCriticalSection() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original", isDirectory: true)
        let nested = original.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        let lock = nested.appendingPathComponent("state.lock")

        XCTAssertThrowsError(
            try FileLock.withExclusiveLock(at: lock) {
                try FileManager.default.moveItem(at: original, to: moved)
                try FileManager.default.createDirectory(
                    at: nested,
                    withIntermediateDirectories: true
                )
            }
        ) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.fileLocking.rawValue)
        }
    }

    func testSecureTraversalCreatesBelowExplicitTrustedAnchor() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = root.appendingPathComponent("nested/state.lock")

        let traversal = try SecureLockFile.openTraversal(
            to: lock,
            createMissingDirectories: true,
            trustedAnchorURL: root
        )
        defer { SecureLockFile.closeTraversal(traversal) }

        XCTAssertTrue(SecureLockFile.validate(traversal))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: lock.deletingLastPathComponent().path
            )
        )
    }

    func testSecureTraversalRejectsSymbolicLinkBelowExplicitTrustedAnchor() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedParent = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: outside)

        XCTAssertThrowsError(
            try SecureLockFile.openTraversal(
                to: linkedParent.appendingPathComponent("state.lock"),
                createMissingDirectories: true,
                trustedAnchorURL: root
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("state.lock").path
            )
        )
    }

    func testSecureTraversalDetectsReboundExplicitTrustedAnchor() throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("anchor", isDirectory: true)
        let moved = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let traversal = try SecureLockFile.openTraversal(
            to: root.appendingPathComponent("state.lock"),
            createMissingDirectories: true,
            trustedAnchorURL: root
        )
        defer { SecureLockFile.closeTraversal(traversal) }

        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertFalse(SecureLockFile.validate(traversal))
    }

    func testCoordinatorRejectsSymbolicLinkCoreLockWithoutLockingTarget() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.coreLock.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outside = root.appendingPathComponent("outside.lock")
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.path, contents: Data()))
        try FileManager.default.createSymbolicLink(at: paths.coreLock, withDestinationURL: outside)

        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        do {
            _ = try await coordinator.acquire(as: .mainApp)
            XCTFail("Expected a symbolic-link lock to be rejected")
        } catch let error as CoreOwnershipError {
            guard case .cannotOpenLock = error else {
                return XCTFail("Unexpected ownership error: \(error)")
            }
        }

        let descriptor = open(outside.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { close(descriptor) } }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        if descriptor >= 0 { _ = flock(descriptor, LOCK_UN) }
    }

    func testCoordinatorRejectsSymbolicLinkParentWithoutCreatingOutsideLock() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let coordination = root.appendingPathComponent("Coordination", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: coordination, withDestinationURL: outside)
        let lock = coordination.appendingPathComponent("syncthing-core.lock")

        let coordinator = CoreProcessCoordinator(lockURL: lock)
        do {
            _ = try await coordinator.acquire(as: .mainApp)
            XCTFail("Expected a symbolic-link parent to be rejected")
        } catch let error as CoreOwnershipError {
            guard case .cannotOpenLock = error else {
                return XCTFail("Unexpected ownership error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("syncthing-core.lock").path
            )
        )
    }

    func testCoordinatorRejectsIntermediateSymbolicLinkBeforeCreatingOutsideLock() async throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedAncestor = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedAncestor, withDestinationURL: outside)
        let lock =
            linkedAncestor
            .appendingPathComponent("new-parent", isDirectory: true)
            .appendingPathComponent("syncthing-core.lock")

        let coordinator = CoreProcessCoordinator(lockURL: lock)
        do {
            _ = try await coordinator.acquire(as: .mainApp)
            XCTFail("Intermediate symbolic link unexpectedly allowed core ownership")
        } catch let error as CoreOwnershipError {
            guard case .cannotOpenLock = error else {
                return XCTFail("Unexpected ownership error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("new-parent", isDirectory: true).path
            )
        )
    }

    func testCoordinatorRejectsSymbolicLinkOwnerMetadataWithoutReplacingTarget() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.coreLock.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let target = root.appendingPathComponent("outside-owner.json")
        let original = Data("outside bytes".utf8)
        try original.write(to: target)
        let metadata = CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: target)

        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        do {
            _ = try await coordinator.acquire(as: .mainApp)
            XCTFail("Expected symbolic-link owner metadata to fail closed")
        } catch {
            XCTAssertEqual(error as? CoreOwnershipError, .ownerMetadataUnreadable)
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: metadata.path))
    }

    func testOwnerMetadataReadAndWriteRejectIntermediateSymbolicLink() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideMetadata = outside.appendingPathComponent("owner.json")
        let persisted = CoreOwnerLease(
            epoch: 7,
            instanceID: UUID(),
            role: .mainApp,
            acquiredAt: Date(timeIntervalSince1970: 1)
        )
        try CoreOwnerMetadataStore.write(persisted, to: outsideMetadata)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let metadata = linked.appendingPathComponent("owner.json")

        XCTAssertThrowsError(try CoreOwnerMetadataStore.readIfPresent(at: metadata)) { error in
            XCTAssertEqual(error as? CoreOwnershipError, .ownerMetadataUnreadable)
        }
        XCTAssertThrowsError(try CoreOwnerMetadataStore.write(persisted, to: metadata)) { error in
            XCTAssertEqual(error as? CoreOwnershipError, .ownerMetadataWriteFailed)
        }
        XCTAssertEqual(try CoreOwnerMetadataStore.readIfPresent(at: outsideMetadata), persisted)
    }

    func testAtomicBatchPublicationSurvivesRestartAndTransitionsEntriesIndividually() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let queue = CoreCommandQueue(root: paths.commandQueue)
        let batchID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let first = CoreCommand(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000011")!,
            kind: .sync,
            folderID: try XCTUnwrap(FolderID(rawValue: "alpha")),
            folderIncarnationDigest: String(repeating: "a", count: 64),
            trigger: .user,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = CoreCommand(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000012")!,
            kind: .sync,
            folderID: try XCTUnwrap(FolderID(rawValue: "beta")),
            folderIncarnationDigest: String(repeating: "b", count: 64),
            trigger: .user,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        try queue.enqueueAtomically([first, second], batchID: batchID)
        try queue.enqueueAtomically([first, second], batchID: batchID)
        XCTAssertEqual(try CoreCommandQueue(root: paths.commandQueue).pending(), [first, second])

        try queue.acknowledge(first)
        let restarted = CoreCommandQueue(root: paths.commandQueue)
        XCTAssertEqual(try restarted.pending(), [second])
        XCTAssertEqual(try restarted.completed(), [first])

        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        let lease = try await coordinator.acquire(as: .mainApp)
        let ownerMetadataURL = CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        let firstEntry = try XCTUnwrap(restarted.completedCleanupBatch().first)
        try restarted.retireCompleted(
            firstEntry,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
        XCTAssertEqual(try restarted.pending(), [second])
        XCTAssertEqual(try restarted.completed(), [])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.commandQueue.appendingPathComponent("batches").path
            )
        )

        try restarted.acknowledge(second)
        let secondEntry = try XCTUnwrap(restarted.completedCleanupBatch().first)
        try restarted.retireCompleted(
            secondEntry,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
        XCTAssertEqual(try restarted.pending(), [])
        XCTAssertEqual(try restarted.completed(), [])
        let batchURL = paths.commandQueue.appendingPathComponent(
            "batches/\(batchID.uuidString.lowercased()).json"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: batchURL.path))
        await coordinator.release()
    }

    func testInterruptedHiddenBatchPublicationIsNotExposedAfterRestart() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let batches = root.appendingPathComponent("batches", isDirectory: true)
        try FileManager.default.createDirectory(at: batches, withIntermediateDirectories: true)
        // This is the only artifact a killed atomic writer may leave before
        // its final rename. Queue readers intentionally skip hidden files.
        try Data("partial".utf8).write(
            to: batches.appendingPathComponent(".interrupted-publication.tmp")
        )
        XCTAssertEqual(try CoreCommandQueue(root: root).pending(), [])

        let command = CoreCommand(
            kind: .sync,
            folderID: try XCTUnwrap(FolderID(rawValue: "restart")),
            folderIncarnationDigest: String(repeating: "c", count: 64),
            trigger: .user
        )
        let batchID = UUID()
        try CoreCommandQueue(root: root).enqueueAtomically([command], batchID: batchID)
        let recovered = try XCTUnwrap(CoreCommandQueue(root: root).pending().first)
        XCTAssertEqual(recovered.id, command.id)
        XCTAssertEqual(recovered.folderIncarnationDigest, command.folderIncarnationDigest)
    }

    func testAtomicBatchIdentifierCollisionPublishesNoSibling() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CoreCommandQueue(root: root)
        let collisionID = UUID()
        let legacy = CoreCommand(
            id: collisionID,
            kind: .sync,
            folderID: try XCTUnwrap(FolderID(rawValue: "legacy")),
            folderIncarnationDigest: String(repeating: "d", count: 64),
            trigger: .user
        )
        try queue.enqueue(legacy)
        let collision = CoreCommand(
            id: collisionID,
            kind: .sync,
            folderID: try XCTUnwrap(FolderID(rawValue: "collision")),
            folderIncarnationDigest: String(repeating: "e", count: 64),
            trigger: .user
        )
        let sibling = CoreCommand(
            kind: .sync,
            folderID: try XCTUnwrap(FolderID(rawValue: "must-not-publish")),
            folderIncarnationDigest: String(repeating: "f", count: 64),
            trigger: .user
        )

        XCTAssertThrowsError(try queue.enqueueAtomically([collision, sibling], batchID: UUID())) { error in
            XCTAssertEqual(error as? CoreCommandQueueError, .identifierCollision(collisionID))
        }
        let remaining = try queue.pending()
        XCTAssertEqual(remaining.map(\.id), [legacy.id])
        XCTAssertEqual(remaining.first?.folderID, legacy.folderID)
    }

    func testBackgroundBatchDeduplicatesPerFolderAndRejectsManualCoalescing() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CoreCommandQueue(root: root)
        let alpha = try XCTUnwrap(FolderID(rawValue: "alpha"))
        let beta = try XCTUnwrap(FolderID(rawValue: "beta"))
        let existingUser = CoreCommand(
            kind: .sync,
            folderID: alpha,
            folderIncarnationDigest: String(repeating: "a", count: 64),
            trigger: .user
        )
        try queue.enqueue(existingUser)
        let duplicate = CoreCommand(
            kind: .sync,
            folderID: alpha,
            folderIncarnationDigest: existingUser.folderIncarnationDigest,
            trigger: .backgroundProcessing
        )
        let inserted = CoreCommand(
            kind: .sync,
            folderID: beta,
            folderIncarnationDigest: String(repeating: "b", count: 64),
            trigger: .backgroundProcessing
        )

        XCTAssertEqual(
            try queue.enqueueBackgroundBatchIfNeeded(
                [duplicate, inserted],
                batchID: UUID()
            ).map(\.id),
            [inserted.id]
        )
        XCTAssertEqual(Set(try queue.pending().map(\.id)), [existingUser.id, inserted.id])
        XCTAssertThrowsError(
            try queue.enqueueBackgroundBatchIfNeeded(
                [
                    CoreCommand(
                        kind: .sync,
                        folderID: beta,
                        folderIncarnationDigest: inserted.folderIncarnationDigest,
                        trigger: .user
                    )
                ],
                batchID: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreCommandQueueError,
                .backgroundTriggerRequiredForDeduplication
            )
        }
    }

    func testBatchDirectorySymlinkAndCorruptEnvelopeFailClosed() throws {
        let symlinkRoot = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: symlinkRoot)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot.appendingPathComponent("batches"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try CoreCommandQueue(root: symlinkRoot).pending()) { error in
            XCTAssertEqual(error as? CoreCommandQueueError, .invalidBatchDocument)
        }

        let corruptRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        let corruptBatches = corruptRoot.appendingPathComponent("batches", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptBatches, withIntermediateDirectories: true)
        let batchID = UUID()
        try Data("{".utf8).write(
            to: corruptBatches.appendingPathComponent("\(batchID.uuidString.lowercased()).json")
        )
        XCTAssertThrowsError(try CoreCommandQueue(root: corruptRoot).pending()) { error in
            XCTAssertEqual(error as? CoreCommandQueueError, .invalidBatchDocument)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func canonicalOfferVersion(byte: UInt8) -> String {
        Data(repeating: byte, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func observationProof(
        for offer: PendingFolderOffer,
        observedAt: Date = .now
    ) -> PendingFolderObservationProof {
        PendingFolderObservationProof(
            proofID: canonicalOfferVersion(byte: 90),
            folderID: offer.folderID,
            offeringDeviceID: offer.offeringDeviceID,
            offerVersion: offer.offerVersion,
            label: offer.label,
            lastSeen: offer.lastSeen,
            lastSeenWireValue: "2026-08-10T00:00:00Z",
            receiveEncrypted: offer.receiveEncrypted,
            remoteEncrypted: offer.remoteEncrypted,
            configurationRevision: String(repeating: "a", count: 64),
            observationSessionID: "10000000-0000-0000-0000-000000000001",
            connectionEpoch: canonicalOfferVersion(byte: 91),
            observedAt: observedAt,
            observedAtWireValue: "2026-08-10T00:00:00Z",
            expiresAt: observedAt.addingTimeInterval(PendingFolderObservationProof.timeToLive),
            expiresAtWireValue: "2026-08-10T00:05:00Z"
        )
    }

    private func localizationKeys(in contents: String) -> Set<String> {
        Set(
            contents.split(separator: "\n").compactMap { line in
                guard line.first == "\"", let separator = line.range(of: "\" = \"") else {
                    return nil
                }
                return String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            }
        )
    }
}
