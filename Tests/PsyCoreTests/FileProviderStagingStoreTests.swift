import Foundation
import XCTest

@testable import PsyCore

final class FileProviderStagingStoreTests: XCTestCase {
    func testStageCreatesMissingStagingRootAndCommandDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "missing-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("source")
        let stagingRoot = base.appendingPathComponent("FileProvider/Staging", isDirectory: true)
        let id = UUID()
        try Data("new root".utf8).write(to: source)
        let store = FileProviderStagingStore(
            root: stagingRoot,
            minimumFreeSpaceBytes: 0,
            availableCapacity: { _ in Int64.max }
        )

        XCTAssertEqual(try store.stage(source, id: id), id.uuidString + "/contents")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stagingRoot.appendingPathComponent(id.uuidString + "/contents").path
            )
        )
    }

    func testCancellationDuringCopyRemovesPartialBytesAndReservation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000020")!
        try Data(repeating: 0x5A, count: 3 * 1_024 * 1_024).write(to: fixture.source)
        // Checks 1...4 occur before copy; check 5 enters the loop and writes
        // the first MiB, then check 6 cancels with a real partial file present.
        let state = CancellationProbe(cancelAfterChecks: 6)

        XCTAssertThrowsError(
            try fixture.store.stage(
                fixture.source,
                id: id,
                cancellationCheck: { try state.check() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(id.uuidString + "/contents").path
            )
        )
        XCTAssertEqual(try reservationEntryCount(at: fixture.root), 0)
    }

    func testCancellationAfterInstallRemovesCommittedBytesAndReservation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000021")!
        try Data("cancel after install".utf8).write(to: fixture.source)
        let store = FileProviderStagingStore(
            root: fixture.root,
            minimumFreeSpaceBytes: 0,
            availableCapacity: { _ in Int64.max },
            beforeSourceRead: { _ in },
            beforeCommit: { throw CancellationError() }
        )

        XCTAssertThrowsError(try store.stage(fixture.source, id: id)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(id.uuidString + "/contents").path
            )
        )
        XCTAssertEqual(try reservationEntryCount(at: fixture.root), 0)
    }

    func testPostInstallValidationRejectsContentChangedBeforeDigest() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000025")!
        let original = Data("original staged bytes".utf8)
        let replacement = Data("replaced staged bytes".utf8)
        XCTAssertEqual(original.count, replacement.count)
        try original.write(to: fixture.source)
        let destination = fixture.root.appendingPathComponent(
            id.uuidString + "/contents"
        )
        let store = FileProviderStagingStore(
            root: fixture.root,
            minimumFreeSpaceBytes: 0,
            availableCapacity: { _ in Int64.max },
            beforeSourceRead: { _ in },
            beforeCommit: {
                try replacement.write(to: destination)
            }
        )

        XCTAssertThrowsError(try store.stage(fixture.source, id: id)) { error in
            XCTAssertEqual(error as? FileProviderStagingError, .existingContentMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try reservationEntryCount(at: fixture.root), 0)
    }

    func testProgressCoversCopyAndVerificationAndDispositionIsLockAccurate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000022")!
        try Data(repeating: 0x7B, count: 2 * 1_024 * 1_024).write(to: fixture.source)
        let progress = StagingProgressProbe()

        let first = try fixture.store.stageWithDisposition(
            fixture.source,
            id: id,
            progress: { completed, total in progress.record(completed, total) }
        )
        let retry = try fixture.store.stageWithDisposition(fixture.source, id: id)

        XCTAssertTrue(first.createdByThisInvocation)
        XCTAssertFalse(retry.createdByThisInvocation)
        XCTAssertEqual(first.token, retry.token)
        let observations = progress.snapshot()
        XCTAssertEqual(observations.first?.completed, 0)
        XCTAssertEqual(observations.last?.completed, observations.last?.total)
        XCTAssertTrue(observations.contains { $0.completed > 0 && $0.completed < $0.total })
    }

    func testStageAndCommitSerializesReplayHandoffThroughDurableCommit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000023")!
        try Data("serialized replay".utf8).write(to: fixture.source)
        let firstEnteredCommit = DispatchSemaphore(value: 0)
        let allowFirstCommit = DispatchSemaphore(value: 0)
        let secondEnteredCommit = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let results = StagingResultProbe()

        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do {
                let result = try fixture.store.stageAndCommit(
                    fixture.source,
                    id: id,
                    commit: {
                        firstEnteredCommit.signal()
                        _ = allowFirstCommit.wait(timeout: .now() + 5)
                    }
                )
                results.record(.success(result))
            } catch {
                results.record(.failure(error))
            }
        }
        XCTAssertEqual(firstEnteredCommit.wait(timeout: .now() + 2), .success)

        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do {
                let result = try fixture.store.stageAndCommit(
                    fixture.source,
                    id: id,
                    commit: { secondEnteredCommit.signal() }
                )
                results.record(.success(result))
            } catch {
                results.record(.failure(error))
            }
        }

        XCTAssertEqual(
            secondEnteredCommit.wait(timeout: .now() + 0.1),
            .timedOut,
            "the replay reached commit before the first invocation durably committed"
        )
        allowFirstCommit.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondEnteredCommit.wait(timeout: .now() + 1), .success)

        let recorded = results.snapshot()
        XCTAssertEqual(recorded.count, 2)
        XCTAssertTrue(
            recorded.allSatisfy {
                if case .success = $0 { return true }
                return false
            })
        XCTAssertEqual(
            Set(recorded.compactMap { try? $0.get().createdByThisInvocation }),
            [false, true]
        )
    }

    func testStageAndCompareKeepsProbePrivateUntilComparisonAndReleaseFinish() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000024")!
        let bytes = Data("atomic reimport probe".utf8)
        let target = fixture.base.appendingPathComponent("managed-target")
        try bytes.write(to: fixture.source)
        try bytes.write(to: target)
        let pause = ComparisonPause()
        let store = FileProviderStagingStore(
            root: fixture.root,
            minimumFreeSpaceBytes: 0,
            availableCapacity: { _ in Int64.max },
            beforeSourceRead: { _ in },
            beforeComparison: { pause.arrive() }
        )
        let finished = DispatchGroup()
        let results = BooleanResultProbe()

        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            results.record(
                Result {
                    try store.stageAndCompareContent(
                        fixture.source,
                        id: id,
                        targetRoot: fixture.base,
                        targetRelativePath: target.lastPathComponent
                    )
                }
            )
        }
        XCTAssertEqual(pause.firstEntered.wait(timeout: .now() + 2), .success)

        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            results.record(
                Result {
                    try store.stageAndCompareContent(
                        fixture.source,
                        id: id,
                        targetRoot: fixture.base,
                        targetRelativePath: target.lastPathComponent
                    )
                }
            )
        }
        XCTAssertEqual(
            pause.secondEntered.wait(timeout: .now() + 0.1),
            .timedOut,
            "a replay borrowed the probe before the first comparison and release finished"
        )

        pause.allowFirst.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(pause.secondEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(try results.snapshot().map { try $0.get() }, [true, true])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(id.uuidString + "/contents").path
            )
        )
        XCTAssertEqual(try reservationEntryCount(at: fixture.root), 0)
    }

    func testStagesExactContentIdempotentlyWithPrivatePermissions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        try Data("hello".utf8).write(to: fixture.source)

        let token = try fixture.store.stage(fixture.source, id: id)
        XCTAssertEqual(token, id.uuidString + "/contents")
        let destination = fixture.root.appendingPathComponent(id.uuidString + "/contents")
        XCTAssertEqual(try Data(contentsOf: destination), Data("hello".utf8))
        let mode =
            try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        XCTAssertEqual(try fixture.store.stage(fixture.source, id: id), token)
        let retryStore = FileProviderStagingStore(
            root: fixture.root,
            minimumFreeSpaceBytes: 1_024,
            availableCapacity: { _ in 0 }
        )
        XCTAssertEqual(try retryStore.stage(fixture.source, id: id), token)
    }

    func testRefusesSameLengthDifferentContentForExistingToken() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        try Data("first".utf8).write(to: fixture.source)
        _ = try fixture.store.stage(fixture.source, id: id)
        try Data("other".utf8).write(to: fixture.source)

        XCTAssertThrowsError(try fixture.store.stage(fixture.source, id: id)) { error in
            XCTAssertEqual(error as? FileProviderStagingError, .existingContentMismatch)
        }
    }

    func testLockedContentValidationRequiresExactTokenAndExactBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "A0000000-0000-4000-8000-000000000010")!
        try Data("expected".utf8).write(to: fixture.source)
        let token = try fixture.store.stage(fixture.source, id: id)
        let target = fixture.base.appendingPathComponent("target")
        try Data("expected".utf8).write(to: target)

        XCTAssertTrue(
            try fixture.store.contentMatches(
                token: token,
                commandID: id,
                targetRoot: fixture.base,
                targetRelativePath: target.lastPathComponent
            )
        )
        try Data("different".utf8).write(to: target, options: .atomic)
        XCTAssertFalse(
            try fixture.store.contentMatches(
                token: token,
                commandID: id,
                targetRoot: fixture.base,
                targetRelativePath: target.lastPathComponent
            )
        )
        XCTAssertThrowsError(
            try fixture.store.contentMatches(
                token: id.uuidString.lowercased() + "/contents",
                commandID: id,
                targetRoot: fixture.base,
                targetRelativePath: target.lastPathComponent
            )
        ) { error in
            XCTAssertEqual(error as? FileProviderStagingError, .invalidStagedContentToken)
        }
    }

    func testLockedContentValidationRejectsTargetPathSwapAfterDigest() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "A0000000-0000-4000-8000-000000000011")!
        let expected = Data("expected".utf8)
        try expected.write(to: fixture.source)
        let token = try fixture.store.stage(fixture.source, id: id)
        let target = fixture.base.appendingPathComponent("target-swap")
        let replacement = fixture.base.appendingPathComponent("target-replacement")
        try expected.write(to: target)
        try Data("replaced".utf8).write(to: replacement)
        let store = FileProviderStagingStore(
            root: fixture.root,
            minimumFreeSpaceBytes: 0,
            availableCapacity: { _ in Int64.max },
            beforeSourceRead: { _ in },
            beforePathIdentityRecheck: { candidate in
                guard candidate.standardizedFileURL == target.standardizedFileURL else { return }
                try FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: replacement, to: target)
            }
        )

        XCTAssertThrowsError(
            try store.contentMatches(
                token: token,
                commandID: id,
                targetRoot: fixture.base,
                targetRelativePath: target.lastPathComponent
            )
        ) { error in
            XCTAssertEqual(
                error as? FileProviderStagingError,
                .contentChangedDuringValidation
            )
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("replaced".utf8))
    }

    func testLockedContentValidationRejectsSymlinkTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000011")!
        try Data("expected".utf8).write(to: fixture.source)
        let token = try fixture.store.stage(fixture.source, id: id)
        let target = fixture.base.appendingPathComponent("target")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.source)

        XCTAssertThrowsError(
            try fixture.store.contentMatches(
                token: token,
                commandID: id,
                targetRoot: fixture.base,
                targetRelativePath: target.lastPathComponent
            )
        ) { error in
            XCTAssertEqual(error as? FileProviderStagingError, .targetNotRegularFile)
        }
    }

    func testLockedContentValidationRejectsIntermediateSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000012")!
        try Data("expected".utf8).write(to: fixture.source)
        let token = try fixture.store.stage(fixture.source, id: id)
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("expected".utf8).write(to: outside.appendingPathComponent("target"))
        try FileManager.default.createSymbolicLink(
            at: fixture.base.appendingPathComponent("linked"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try fixture.store.contentMatches(
                token: token,
                commandID: id,
                targetRoot: fixture.base,
                targetRelativePath: "linked/target"
            )
        ) { error in
            XCTAssertEqual(error as? FileProviderStagingError, .targetNotRegularFile)
        }
    }

    func testReservesSpaceForStagingAndAtomicDestinationCopy() throws {
        let fixture = try Fixture(availableCapacity: 15, reserve: 10)
        defer { fixture.remove() }
        try Data("abc".utf8).write(to: fixture.source)

        XCTAssertThrowsError(try fixture.store.stage(fixture.source, id: UUID())) { error in
            XCTAssertEqual(
                error as? FileProviderStagingError,
                .insufficientCapacity(required: 16, available: 15)
            )
        }
    }

    func testReclaimsOnlyExpiredUnreferencedRealUUIDDirectories() throws {
        let fixture = try Fixture(staleAge: 60)
        defer { fixture.remove() }
        let old = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        let retained = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
        let fresh = UUID(uuidString: "10000000-0000-4000-8000-000000000005")!
        let manager = FileManager.default
        for id in [old, retained, fresh] {
            try manager.createDirectory(
                at: fixture.root.appendingPathComponent(id.uuidString),
                withIntermediateDirectories: true
            )
        }
        let now = Date(timeIntervalSince1970: 10_000)
        for id in [old, retained] {
            try manager.setAttributes(
                [.modificationDate: now.addingTimeInterval(-120)],
                ofItemAtPath: fixture.root.appendingPathComponent(id.uuidString).path
            )
        }
        try manager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10)],
            ofItemAtPath: fixture.root.appendingPathComponent(fresh.uuidString).path
        )
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let symlinkID = UUID(uuidString: "10000000-0000-4000-8000-000000000006")!
        let symlink = fixture.root.appendingPathComponent(symlinkID.uuidString)
        try manager.createSymbolicLink(at: symlink, withDestinationURL: outside)

        XCTAssertEqual(
            try fixture.store.reclaimStaleDirectories(retaining: [retained], now: now),
            1
        )
        XCTAssertFalse(manager.fileExists(atPath: fixture.root.appendingPathComponent(old.uuidString).path))
        XCTAssertTrue(manager.fileExists(atPath: fixture.root.appendingPathComponent(retained.uuidString).path))
        XCTAssertTrue(manager.fileExists(atPath: fixture.root.appendingPathComponent(fresh.uuidString).path))
        XCTAssertNotNil(try? manager.destinationOfSymbolicLink(atPath: symlink.path))
        XCTAssertTrue(manager.fileExists(atPath: outside.path))
    }

    func testRejectsSymlinkSourceAndCommandDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("content".utf8).write(to: fixture.source)
        let sourceLink = fixture.base.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: fixture.source)
        XCTAssertThrowsError(try fixture.store.stage(sourceLink, id: UUID())) { error in
            XCTAssertEqual(error as? FileProviderStagingError, .sourceNotRegularFile)
        }

        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000007")!
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(id.uuidString),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try fixture.store.stage(fixture.source, id: id)) { error in
            XCTAssertEqual(error as? FileProviderStagingError, .unsafeCommandDirectory)
        }
    }

    func testRejectsSourceSwapToSymlinkAfterSecureOpen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.source)
        let replacement = fixture.base.appendingPathComponent("replacement")
        try Data("replacement".utf8).write(to: replacement)
        let store = FileProviderStagingStore(
            root: fixture.root,
            minimumFreeSpaceBytes: 0,
            availableCapacity: { _ in Int64.max },
            beforeSourceRead: { source in
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createSymbolicLink(
                    at: source,
                    withDestinationURL: replacement
                )
            }
        )
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000013")!

        XCTAssertThrowsError(try store.stage(fixture.source, id: id)) { error in
            XCTAssertEqual(error as? FileProviderStagingError, .sourceChangedDuringCopy)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(id.uuidString + "/contents").path
            )
        )
    }

    func testExistingTokenRejectsSourceInodeSwapAfterSecureOpen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000014")!
        try Data("same bytes".utf8).write(to: fixture.source)
        _ = try fixture.store.stage(fixture.source, id: id)
        let replacement = fixture.base.appendingPathComponent("replacement")
        try Data("same bytes".utf8).write(to: replacement)
        let store = FileProviderStagingStore(
            root: fixture.root,
            minimumFreeSpaceBytes: 0,
            availableCapacity: { _ in 0 },
            beforeSourceRead: { source in
                try FileManager.default.removeItem(at: source)
                try FileManager.default.moveItem(at: replacement, to: source)
            }
        )

        XCTAssertThrowsError(try store.stage(fixture.source, id: id)) { error in
            XCTAssertEqual(error as? FileProviderStagingError, .sourceChangedDuringCopy)
        }
    }

    func testCompletedIndeterminateCommandRetainsStagingUntilReconciled() throws {
        let fixture = try Fixture(staleAge: 60)
        defer { fixture.remove() }
        let queueRoot = fixture.base.appendingPathComponent("queue", isDirectory: true)
        let queue = CoreCommandQueue(root: queueRoot)
        let retainedCommand = CoreCommand(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000008")!,
            kind: .modify,
            trigger: .fileProvider,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let removableCommand = CoreCommand(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000009")!,
            kind: .modify,
            trigger: .fileProvider,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        for command in [retainedCommand, removableCommand] {
            try queue.enqueue(command)
            let directory = fixture.root.appendingPathComponent(command.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: directory.path
            )
        }
        try queue.record(
            CoreCommandResult(
                commandID: retainedCommand.id,
                status: .failed,
                errorCode: "indeterminate_prior_attempt"
            )
        )
        try queue.acknowledge(retainedCommand)
        try queue.record(CoreCommandResult(commandID: removableCommand.id, status: .succeeded))
        try queue.acknowledge(removableCommand)

        let retainedIDs = try queue.retainedFileProviderStagingCommandIDs()
        XCTAssertEqual(retainedIDs, [retainedCommand.id])
        XCTAssertEqual(
            try fixture.store.reclaimStaleDirectories(
                retaining: retainedIDs,
                now: Date(timeIntervalSince1970: 10_000)
            ),
            1
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(retainedCommand.id.uuidString).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(removableCommand.id.uuidString).path
            )
        )
    }

    func testConcurrentStagesCannotSpendTheSameCapacityObservation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstSource = base.appendingPathComponent("first")
        let secondSource = base.appendingPathComponent("second")
        try Data(repeating: 1, count: 250_000).write(to: firstSource)
        try Data(repeating: 2, count: 250_000).write(to: secondSource)
        let observation = ConcurrentCapacityObservation()
        let store = FileProviderStagingStore(
            root: root,
            minimumFreeSpaceBytes: 256_000,
            availableCapacity: { root in
                observation.enter()
                defer { observation.leave() }
                Thread.sleep(forTimeInterval: 0.05)
                let stagedBytes = try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil
                ).reduce(into: Int64(0)) { total, entry in
                    let contents = entry.appendingPathComponent("contents")
                    if let size = (try? FileManager.default.attributesOfItem(atPath: contents.path)[.size])
                        as? NSNumber
                    {
                        total += size.int64Value
                    }
                }
                return 800_000 - stagedBytes
            }
        )

        let results = await withTaskGroup(of: Result<String, Error>.self) { group in
            group.addTask { Result { try store.stage(firstSource, id: UUID()) } }
            group.addTask { Result { try store.stage(secondSource, id: UUID()) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(
            results.filter {
                guard case .failure(let error) = $0,
                    case .insufficientCapacity = error as? FileProviderStagingError
                else { return false }
                return true
            }.count,
            1
        )
        XCTAssertEqual(observation.maximumConcurrentCalls, 1)
    }

    func testOutstandingDestinationReservationSurvivesRestartUntilRelease() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstSource = base.appendingPathComponent("first")
        let secondSource = base.appendingPathComponent("second")
        try Data(repeating: 1, count: 250_000).write(to: firstSource)
        try Data(repeating: 2, count: 250_000).write(to: secondSource)
        let capacity: FileProviderStagingStore.AvailableCapacity = { root in
            let stagedBytes = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).reduce(into: Int64(0)) { total, entry in
                let contents = entry.appendingPathComponent("contents")
                if let size = (try? FileManager.default.attributesOfItem(atPath: contents.path)[.size])
                    as? NSNumber
                {
                    total += size.int64Value
                }
            }
            return 800_000 - stagedBytes
        }
        let firstID = UUID()
        let firstStore = FileProviderStagingStore(
            root: root,
            minimumFreeSpaceBytes: 256_000,
            availableCapacity: capacity
        )
        _ = try firstStore.stage(firstSource, id: firstID)

        let restartedStore = FileProviderStagingStore(
            root: root,
            minimumFreeSpaceBytes: 256_000,
            availableCapacity: capacity
        )
        XCTAssertThrowsError(try restartedStore.stage(secondSource, id: UUID())) { error in
            XCTAssertEqual(
                error as? FileProviderStagingError,
                .insufficientCapacity(required: 1_006_000, available: 550_000)
            )
        }

        try restartedStore.release(id: firstID)
        let secondID = UUID()
        XCTAssertEqual(
            try restartedStore.stage(secondSource, id: secondID),
            secondID.uuidString + "/contents"
        )
    }

    func testReservationLedgerSymlinkFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.base.appendingPathComponent("outside-reservations")
        let original = Data("do not modify".utf8)
        try original.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(".reservations-v1.json"),
            withDestinationURL: outside
        )
        try Data("payload".utf8).write(to: fixture.source)

        XCTAssertThrowsError(try fixture.store.stage(fixture.source, id: UUID())) { error in
            XCTAssertEqual(error as? FileProviderStagingError, .reservationStateCorrupt)
        }
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testCrashAfterReservationBeforeContentsStillReservesBothCopies() throws {
        let fixture = try Fixture(availableCapacity: 15, reserve: 10)
        defer { fixture.remove() }
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000015")!
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(id.uuidString, isDirectory: true),
            withIntermediateDirectories: false
        )
        try writeReservationLedger(root: fixture.root, entries: [(id, 3)])
        try Data("abc".utf8).write(to: fixture.source)

        XCTAssertThrowsError(try fixture.store.stage(fixture.source, id: id)) { error in
            XCTAssertEqual(
                error as? FileProviderStagingError,
                .insufficientCapacity(required: 16, available: 15)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(id.uuidString + "/contents").path
            )
        )
    }

    func testReservationLedgerRefusesEntryBeyondMaximumWithoutBrickingExistingState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let existing = (0..<4_096).map { _ in (UUID(), Int64(0)) }
        try writeReservationLedger(root: fixture.root, entries: existing)
        try Data().write(to: fixture.source)

        XCTAssertThrowsError(try fixture.store.stage(fixture.source, id: UUID())) { error in
            XCTAssertEqual(error as? FileProviderStagingError, .reservationStateCorrupt)
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: fixture.root.appendingPathComponent(".reservations-v1.json")
                )
            ) as? [String: Any]
        )
        XCTAssertEqual((object["entries"] as? [[String: Any]])?.count, 4_096)
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let cancelAfterChecks: Int

    init(cancelAfterChecks: Int) {
        self.cancelAfterChecks = cancelAfterChecks
    }

    func check() throws {
        let shouldCancel = lock.withLock { () -> Bool in
            checks += 1
            return checks >= cancelAfterChecks
        }
        if shouldCancel { throw CancellationError() }
    }
}

private final class StagingProgressProbe: @unchecked Sendable {
    struct Observation {
        var completed: Int64
        var total: Int64
    }

    private let lock = NSLock()
    private var observations: [Observation] = []

    func record(_ completed: Int64, _ total: Int64) {
        lock.withLock {
            observations.append(Observation(completed: completed, total: total))
        }
    }

    func snapshot() -> [Observation] {
        lock.withLock { observations }
    }
}

private final class StagingResultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<FileProviderStagingResult, Error>] = []

    func record(_ result: Result<FileProviderStagingResult, Error>) {
        lock.withLock { results.append(result) }
    }

    func snapshot() -> [Result<FileProviderStagingResult, Error>] {
        lock.withLock { results }
    }
}

private final class BooleanResultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Bool, Error>] = []

    func record(_ result: Result<Bool, Error>) {
        lock.withLock { results.append(result) }
    }

    func snapshot() -> [Result<Bool, Error>] {
        lock.withLock { results }
    }
}

private final class ComparisonPause: @unchecked Sendable {
    let firstEntered = DispatchSemaphore(value: 0)
    let allowFirst = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var arrivals = 0

    func arrive() {
        let arrival = lock.withLock { () -> Int in
            arrivals += 1
            return arrivals
        }
        if arrival == 1 {
            firstEntered.signal()
            _ = allowFirst.wait(timeout: .now() + 5)
        } else {
            secondEntered.signal()
        }
    }
}

private func writeReservationLedger(root: URL, entries: [(UUID, Int64)]) throws {
    let object: [String: Any] = [
        "schemaVersion": 1,
        "entries": entries.map { id, bytes in
            ["commandID": id.uuidString, "destinationBytes": bytes] as [String: Any]
        },
    ]
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
        to: root.appendingPathComponent(".reservations-v1.json")
    )
}

private func reservationEntryCount(at root: URL) throws -> Int {
    let url = root.appendingPathComponent(".reservations-v1.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any]
    )
    return try XCTUnwrap((object["entries"] as? [[String: Any]])?.count)
}

private struct Fixture {
    let base: URL
    let root: URL
    let source: URL
    let store: FileProviderStagingStore

    init(
        availableCapacity: Int64 = Int64.max,
        reserve: Int64 = 0,
        staleAge: TimeInterval = 24 * 60 * 60
    ) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("staging", isDirectory: true)
        source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = FileProviderStagingStore(
            root: root,
            minimumFreeSpaceBytes: reserve,
            staleAge: staleAge,
            availableCapacity: { _ in availableCapacity }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

private final class ConcurrentCapacityObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCalls = 0
    private var maximum = 0

    var maximumConcurrentCalls: Int {
        lock.withLock { maximum }
    }

    func enter() {
        lock.withLock {
            activeCalls += 1
            maximum = max(maximum, activeCalls)
        }
    }

    func leave() {
        lock.withLock { activeCalls -= 1 }
    }
}
