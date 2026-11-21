import Foundation
import PsyCore
import XCTest

final class ExternalDirectoryNamedChildTests: XCTestCase {
    func testEnvironmentOnlyEnablesTheDesignedForIPadRuntime() {
        XCTAssertTrue(IOSAppOnMacEnvironment(isIOSAppOnMac: true).allowsNamedChildCreation)
        XCTAssertFalse(IOSAppOnMacEnvironment(isIOSAppOnMac: false).allowsNamedChildCreation)

        #if os(iOS)
            XCTAssertEqual(
                IOSAppOnMacEnvironment.current.allowsNamedChildCreation,
                ProcessInfo.processInfo.isiOSAppOnMac
            )
        #else
            XCTAssertFalse(IOSAppOnMacEnvironment.current.allowsNamedChildCreation)
        #endif
    }

    func testChildNameAcceptsOneSafeUnicodeComponent() throws {
        let name = try ExternalDirectoryChildName(validating: "同步 Share 01")
        XCTAssertEqual(name.rawValue, "同步 Share 01")
        XCTAssertEqual(ExternalDirectoryChildName.maximumUTF8ByteCount, 255)
    }

    func testChildNameRejectsEmptyDotSeparatorsControlAndOverlongInput() {
        let cases: [(String, ExternalDirectoryChildNameValidationError)] = [
            ("", .empty),
            (".", .dotComponent),
            ("..", .dotComponent),
            ("nested/folder", .pathSeparator),
            (#"nested\folder"#, .pathSeparator),
            ("nul\0byte", .controlCharacter),
            ("line\nbreak", .controlCharacter),
            (String(repeating: "a", count: 256), .tooLong),
            (String(repeating: "界", count: 86), .tooLong),
        ]

        for (rawName, expected) in cases {
            XCTAssertThrowsError(try ExternalDirectoryChildName(validating: rawName)) { error in
                XCTAssertEqual(error as? ExternalDirectoryChildNameValidationError, expected)
            }
        }
    }

    func testCreatesChildInsideAuthorizedParentAndBalancesScope() async throws {
        let parent = try temporaryDirectory()
        let scope = ScopeHarness()
        let authorizer = ExternalDirectoryNamedChildAuthorizer(scopeAccess: scope.access)

        let authorizedName = try await authorizer.createAndAuthorize(
            parentURL: parent,
            name: "Mac Share"
        ) { childURL in
            var isDirectory = ObjCBool(false)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: childURL.path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertEqual(childURL.deletingLastPathComponent().standardizedFileURL, parent.standardizedFileURL)
            return childURL.lastPathComponent
        }

        XCTAssertEqual(authorizedName, "Mac Share")
        XCTAssertEqual(scope.counts, .init(begin: 1, end: 1))
    }

    func testDeniedParentScopeDoesNotCreateAnything() async throws {
        let parent = try temporaryDirectory()
        let scope = ScopeHarness(beginResult: false)
        let authorizer = ExternalDirectoryNamedChildAuthorizer(scopeAccess: scope.access)

        do {
            _ = try await authorizer.createAndAuthorize(parentURL: parent, name: "Denied") { _ in
                XCTFail("authorization must not run without the parent security scope")
            }
            XCTFail("a denied security scope must fail closed")
        } catch let error as ExternalDirectoryNamedChildError {
            XCTAssertEqual(error, .parentAuthorizationDenied)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("Denied").path))
        XCTAssertEqual(scope.counts, .init(begin: 1, end: 0))
    }

    func testBookmarkFailureRollsBackOnlyTheNewEmptyChild() async throws {
        let parent = try temporaryDirectory()
        let scope = ScopeHarness()
        let authorizer = ExternalDirectoryNamedChildAuthorizer(scopeAccess: scope.access)

        do {
            _ = try await authorizer.createAndAuthorize(parentURL: parent, name: "Rollback") { _ in
                throw BookmarkFailure()
            }
            XCTFail("a bookmark failure must be returned")
        } catch let error as ExternalDirectoryNamedChildError {
            XCTAssertEqual(error, .authorizationFailed)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("Rollback").path))
        XCTAssertEqual(scope.counts, .init(begin: 1, end: 1))
    }

    func testExistingDirectoryIsAuthorizedButNeverRolledBack() async throws {
        let parent = try temporaryDirectory()
        let existing = parent.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let authorizer = ExternalDirectoryNamedChildAuthorizer(scopeAccess: ScopeHarness().access)

        do {
            _ = try await authorizer.createAndAuthorize(parentURL: parent, name: "Existing") { _ in
                throw BookmarkFailure()
            }
            XCTFail("the authorization failure must be returned")
        } catch let error as ExternalDirectoryNamedChildError {
            XCTAssertEqual(error, .authorizationFailed)
        }

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testExistingSymlinkAndNonDirectoryAreRejectedWithoutMutation() async throws {
        let parent = try temporaryDirectory()
        let target = try temporaryDirectory()
        let symlink = parent.appendingPathComponent("Linked", isDirectory: true)
        let file = parent.appendingPathComponent("Regular")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        try Data("keep".utf8).write(to: file)
        let authorizer = ExternalDirectoryNamedChildAuthorizer(scopeAccess: ScopeHarness().access)

        for name in ["Linked", "Regular"] {
            do {
                _ = try await authorizer.createAndAuthorize(parentURL: parent, name: name) { _ in
                    XCTFail("unsafe existing entries must not reach authorization")
                }
                XCTFail("an unsafe existing entry must be rejected")
            } catch let error as ExternalDirectoryNamedChildError {
                XCTAssertEqual(error, .unsafeExistingItem)
            }
        }

        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path),
            target.path
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testRollbackRefusesToDeleteAChildThatBecameNonEmpty() async throws {
        let parent = try temporaryDirectory()
        let authorizer = ExternalDirectoryNamedChildAuthorizer(scopeAccess: ScopeHarness().access)

        do {
            _ = try await authorizer.createAndAuthorize(parentURL: parent, name: "Retained") { childURL in
                try Data("user-data".utf8).write(to: childURL.appendingPathComponent("payload"))
                throw BookmarkFailure()
            }
            XCTFail("rollback must not delete a non-empty directory")
        } catch let error as ExternalDirectoryNamedChildError {
            XCTAssertEqual(error, .rollbackFailed)
        }

        XCTAssertEqual(
            try Data(contentsOf: parent.appendingPathComponent("Retained/payload")),
            Data("user-data".utf8)
        )
    }

    func testSymlinkParentIsRejectedWithoutFollowingIt() async throws {
        let container = try temporaryDirectory()
        let target = try temporaryDirectory()
        let parent = container.appendingPathComponent("Parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: target)
        let authorizer = ExternalDirectoryNamedChildAuthorizer(scopeAccess: ScopeHarness().access)

        do {
            _ = try await authorizer.createAndAuthorize(parentURL: parent, name: "Escaped") { _ in
                XCTFail("a symbolic-link parent must not reach authorization")
            }
            XCTFail("a symbolic-link parent must fail closed")
        } catch let error as ExternalDirectoryNamedChildError {
            XCTAssertEqual(error, .unsafeParent)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Escaped").path))
    }

    func testParentRebindBeforeAuthorizationIsDetectedAndNeverReachesBroker() async throws {
        let container = try temporaryDirectory()
        let parent = container.appendingPathComponent("Parent", isDirectory: true)
        let movedParent = container.appendingPathComponent("MovedParent", isDirectory: true)
        let decoy = container.appendingPathComponent("Decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: false)
        let scope = ScopeHarness()
        let authorizer = ExternalDirectoryNamedChildAuthorizer(
            scopeAccess: scope.access,
            beforeAuthorize: { _ in
                try FileManager.default.moveItem(at: parent, to: movedParent)
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: decoy)
            }
        )

        do {
            _ = try await authorizer.createAndAuthorize(parentURL: parent, name: "BoundChild") { _ in
                XCTFail("a rebound parent must never reach the broker")
            }
            XCTFail("the parent rebind must fail closed")
        } catch let error as ExternalDirectoryNamedChildError {
            XCTAssertEqual(error, .unsafeParent)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: decoy.appendingPathComponent("BoundChild").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedParent.appendingPathComponent("BoundChild").path))
        XCTAssertEqual(scope.counts, .init(begin: 1, end: 1))
    }

    func testConcurrentCreationOfTheSameChildSerializesAuthorization() async throws {
        let parent = try temporaryDirectory()
        let scope = ScopeHarness()
        let authorizer = ExternalDirectoryNamedChildAuthorizer(scopeAccess: scope.access)
        let probe = ConcurrentAuthorizationProbe()

        async let first: Int = authorizer.createAndAuthorize(parentURL: parent, name: "Shared") {
            childURL in
            await probe.authorize(childURL)
        }
        async let second: Int = authorizer.createAndAuthorize(parentURL: parent, name: "Shared") {
            childURL in
            await probe.authorize(childURL)
        }
        _ = try await (first, second)

        let snapshot = await probe.snapshot
        XCTAssertEqual(snapshot.callCount, 2)
        XCTAssertEqual(snapshot.maximumConcurrentCalls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent("Shared").path))
        XCTAssertEqual(scope.counts, .init(begin: 2, end: 2))
    }

    func testBrokerRejectsASecondAuthorizationForTheSameExternalRoot() async throws {
        let roots = try brokerRoots()
        let external = roots.container.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let bookmarks = PathBookmarkHarness()
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedRoots,
            commandQueueURL: roots.commands,
            bookmarkAccess: bookmarks.access,
            capabilityProbe: { _ in Self.fullCapabilities }
        )

        _ = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        do {
            _ = try await broker.authorize(url: external, requestedMode: .controlledMirror)
            XCTFail("the same external root must not receive a competing managed mirror")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .bindingConflict)
        }
        let recordsAfterDuplicate = await broker.allRecords()
        XCTAssertEqual(recordsAfterDuplicate.count, 1)
    }

    func testBrokerRejectsRootReboundDuringCapabilityProbeWithoutArtifacts() async throws {
        let roots = try brokerRoots()
        let external = roots.container.appendingPathComponent("External", isDirectory: true)
        let original = roots.container.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedRoots,
            commandQueueURL: roots.commands,
            bookmarkAccess: PathBookmarkHarness().access,
            capabilityProbe: { _ in
                try? FileManager.default.moveItem(at: external, to: original)
                try? FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
                return Self.fullCapabilities
            }
        )

        await assertBindingConflict {
            _ = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        }
        try await assertNoAuthorizationArtifacts(roots, broker: broker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testBrokerRejectsRootReboundDuringBookmarkCreationWithoutArtifacts() async throws {
        let roots = try brokerRoots()
        let external = roots.container.appendingPathComponent("External", isDirectory: true)
        let original = roots.container.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let access = ExternalDirectoryBookmarkAccess(
            create: { url in
                try FileManager.default.moveItem(at: external, to: original)
                try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
                return Data(url.path.utf8)
            },
            resolve: { data in try PathBookmarkHarness.resolve(data) },
            beginAccess: { _ in true },
            endAccess: { _ in }
        )
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedRoots,
            commandQueueURL: roots.commands,
            bookmarkAccess: access,
            capabilityProbe: { _ in Self.fullCapabilities }
        )

        await assertBindingConflict {
            _ = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        }
        try await assertNoAuthorizationArtifacts(roots, broker: broker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testBrokerRejectsBookmarkResolvingToDifferentIdentityWithoutArtifacts() async throws {
        let roots = try brokerRoots()
        let external = roots.container.appendingPathComponent("External", isDirectory: true)
        let decoy = roots.container.appendingPathComponent("Decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: false)
        let access = ExternalDirectoryBookmarkAccess(
            create: { Data($0.path.utf8) },
            resolve: { _ in ExternalDirectoryBookmarkResolution(url: decoy, isStale: false) },
            beginAccess: { _ in true },
            endAccess: { _ in }
        )
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedRoots,
            commandQueueURL: roots.commands,
            bookmarkAccess: access,
            capabilityProbe: { _ in Self.fullCapabilities }
        )

        await assertBindingConflict {
            _ = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        }
        try await assertNoAuthorizationArtifacts(roots, broker: broker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: decoy.path))
    }

    func testBrokerRejectsRebindAtFinalRecordsTransactionWithoutArtifacts() async throws {
        let roots = try brokerRoots()
        let external = roots.container.appendingPathComponent("External", isDirectory: true)
        let original = roots.container.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let harness = FinalScopeRebindHarness(source: external, movedSource: original)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedRoots,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities }
        )

        await assertBindingConflict {
            _ = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        }
        try await assertNoAuthorizationArtifacts(roots, broker: broker)
        XCTAssertEqual(harness.counts.begin, 3)
        XCTAssertEqual(harness.counts.end, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testBrokerRejectsMismatchedNamedChildIdentityBeforeProbe() async throws {
        let roots = try brokerRoots()
        let external = roots.container.appendingPathComponent("External", isDirectory: true)
        let other = roots.container.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let wrongIdentity = try ExternalDirectoryRootIdentityFence.capture(at: other)
        let probe = SynchronousCallCounter()
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedRoots,
            commandQueueURL: roots.commands,
            bookmarkAccess: PathBookmarkHarness().access,
            capabilityProbe: { _ in
                probe.increment()
                return Self.fullCapabilities
            }
        )

        await assertBindingConflict {
            _ = try await broker.authorize(
                url: external,
                requestedMode: .controlledMirror,
                expectedRootIdentity: wrongIdentity
            )
        }
        XCTAssertEqual(probe.value, 0)
        try await assertNoAuthorizationArtifacts(roots, broker: broker)
    }

    func testBrokerRejectsParentChildOverlap() async throws {
        let roots = try brokerRoots()
        let parent = roots.container.appendingPathComponent("External", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedRoots,
            commandQueueURL: roots.commands,
            bookmarkAccess: PathBookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities }
        )

        _ = try await broker.authorize(url: parent, requestedMode: .controlledMirror)
        await assertBindingConflict {
            _ = try await broker.authorize(url: child, requestedMode: .controlledMirror)
        }
        let records = await broker.allRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: roots.managedRoots.path).count,
            1
        )
    }

    func testConcurrentBrokerAuthorizationCreatesOnlyOneRecordAndManagedRoot() async throws {
        let roots = try brokerRoots()
        let external = roots.container.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedRoots,
            commandQueueURL: roots.commands,
            bookmarkAccess: PathBookmarkHarness().access,
            capabilityProbe: { _ in
                Thread.sleep(forTimeInterval: 0.04)
                return Self.fullCapabilities
            }
        )

        let first = Task { try await broker.authorize(url: external, requestedMode: .controlledMirror) }
        let second = Task { try await broker.authorize(url: external, requestedMode: .controlledMirror) }
        var successes = 0
        var conflicts = 0
        for task in [first, second] {
            do {
                _ = try await task.value
                successes += 1
            } catch let error as ExternalDirectoryError {
                XCTAssertEqual(error, .bindingConflict)
                conflicts += 1
            }
        }

        XCTAssertEqual(successes, 1)
        XCTAssertEqual(conflicts, 1)
        let records = await broker.allRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: roots.managedRoots.path).count,
            1
        )
    }

    func testConcurrentBrokerInstancesCommitOnlyOneAuthorization() async throws {
        let roots = try brokerRoots()
        let external = roots.container.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let access = PathBookmarkHarness().access
        let makeBroker = {
            ExternalDirectoryAccessBroker(
                recordsURL: roots.records,
                managedRootsURL: roots.managedRoots,
                commandQueueURL: roots.commands,
                bookmarkAccess: access,
                capabilityProbe: { _ in
                    Thread.sleep(forTimeInterval: 0.04)
                    return Self.fullCapabilities
                }
            )
        }
        let firstBroker = makeBroker()
        let secondBroker = makeBroker()
        let first = Task {
            try await firstBroker.authorize(url: external, requestedMode: .controlledMirror)
        }
        let second = Task {
            try await secondBroker.authorize(url: external, requestedMode: .controlledMirror)
        }
        var successes = 0
        var conflicts = 0
        for task in [first, second] {
            do {
                _ = try await task.value
                successes += 1
            } catch let error as ExternalDirectoryError {
                XCTAssertEqual(error, .bindingConflict)
                conflicts += 1
            }
        }

        XCTAssertEqual(successes, 1)
        XCTAssertEqual(conflicts, 1)
        let verifier = makeBroker()
        let records = await verifier.allRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: roots.managedRoots.path).count,
            1
        )
    }

    func testLegacyDuplicateRootsFailClosedAcrossEveryExternalIOEntryPoint() async throws {
        let roots = try brokerRoots()
        let firstExternal = roots.container.appendingPathComponent("ExternalA", isDirectory: true)
        let secondExternal = roots.container.appendingPathComponent("ExternalB", isDirectory: true)
        try FileManager.default.createDirectory(at: firstExternal, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondExternal, withIntermediateDirectories: false)
        try Data("unchanged".utf8).write(to: firstExternal.appendingPathComponent("sentinel"))
        let access = PathBookmarkHarness().access
        let initialBroker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedRoots,
            commandQueueURL: roots.commands,
            bookmarkAccess: access,
            capabilityProbe: { _ in Self.fullCapabilities }
        )
        _ = try await initialBroker.authorize(url: firstExternal, requestedMode: .controlledMirror)
        _ = try await initialBroker.authorize(url: secondExternal, requestedMode: .controlledMirror)
        var records = await initialBroker.allRecords()
        XCTAssertEqual(records.count, 2)
        let confirmation = ControlledMirrorConfirmation(
            id: "legacy-duplicate-delete",
            kind: .deleteExternal,
            relativePath: "sentinel",
            expectedContentDigest: nil
        )
        for index in records.indices {
            records[index].bookmark = Data(firstExternal.path.utf8)
            records[index].syncBinding.phase = .verified
            records[index].pendingDeletionConfirmations = [confirmation]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: roots.records, options: .atomic)
        let snapshotURL = roots.container.appendingPathComponent("Metadata/core-snapshot.json")
        let snapshot = CoreSnapshot(
            generation: 1,
            folders: records.map { record in
                FolderRecord(
                    id: record.syncBinding.folderID,
                    label: "External",
                    localPath: roots.managedRoots.appendingPathComponent(record.managedRootToken).path,
                    deviceIDs: []
                )
            }
        )
        try SharedSnapshotStore(snapshotURL: snapshotURL).write(snapshot)

        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedRoots,
            commandQueueURL: roots.commands,
            bookmarkAccess: access,
            capabilityProbe: { _ in Self.fullCapabilities }
        )
        try await broker.load()
        let target = records[0]
        let accessProbe = SynchronousCallCounter()
        await assertBindingConflict {
            _ = try await broker.withAccess(id: target.id) { _ in
                accessProbe.increment()
            }
        }
        XCTAssertEqual(accessProbe.value, 0)

        let status = try await broker.runMirror(
            id: target.id,
            currentEnvironment: { .permissiveForTesting }
        )
        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .mirrorIOFailure)
        await assertBindingConflict {
            _ = try await broker.recoverySummaries(
                recordID: target.id,
                currentEnvironment: { .permissiveForTesting }
            )
        }
        let fakeRecovery = ControlledMirrorRecoverySummary(
            operationID: UUID(),
            side: .managed,
            kind: .copyBackup,
            relativePath: "sentinel",
            payloadKind: .file,
            contentDigest: String(repeating: "0", count: 64),
            byteCount: 0,
            createdAt: .now,
            status: .retainedRequiresUserConfirmation
        )
        await assertBindingConflict {
            try await broker.resolveRecovery(
                recordID: target.id,
                summary: fakeRecovery,
                decision: .retain,
                currentEnvironment: { .permissiveForTesting }
            )
        }
        await assertBindingConflict {
            _ = try await broker.resolveDeletionConfirmation(
                recordID: target.id,
                confirmation: confirmation,
                decision: .propagateDeletion,
                currentEnvironment: { .permissiveForTesting }
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: firstExternal.appendingPathComponent("sentinel")),
            Data("unchanged".utf8)
        )
    }

    private static let fullCapabilities = ExternalDirectoryCapabilities(
        canEnumerate: true,
        canRead: true,
        canCreate: true,
        canWrite: true,
        canAtomicallyReplace: true,
        canRename: true,
        canDelete: true,
        canAccessRecursively: true,
        cleanupSucceeded: true,
        recommendedMode: .controlledMirror
    )

    private typealias BrokerRoots = (
        container: URL,
        records: URL,
        managedRoots: URL,
        commands: URL
    )

    private func brokerRoots() throws -> BrokerRoots {
        let container = try temporaryDirectory()
        let records = container.appendingPathComponent("Metadata/external-directories.json")
        let managedRoots = container.appendingPathComponent("ManagedFolders/External", isDirectory: true)
        let commands = container.appendingPathComponent("Coordination/Commands", isDirectory: true)
        try FileManager.default.createDirectory(
            at: records.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: managedRoots, withIntermediateDirectories: true)
        return (container, records, managedRoots, commands)
    }

    private func assertBindingConflict(
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("the authorization must fail closed")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .bindingConflict)
        } catch {
            XCTFail("unexpected error type")
        }
    }

    private func assertNoAuthorizationArtifacts(
        _ roots: BrokerRoots,
        broker: ExternalDirectoryAccessBroker
    ) async throws {
        let records = await broker.allRecords()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: roots.managedRoots.path).isEmpty
        )
        XCTAssertTrue(try CoreCommandQueue(root: roots.commands).pending().isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        #if os(macOS)
            let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        #else
            let temporaryRoot = FileManager.default.temporaryDirectory
        #endif
        let url =
            temporaryRoot
            .appendingPathComponent("psy-named-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private struct BookmarkFailure: Error {}

private actor ConcurrentAuthorizationProbe {
    private var activeCalls = 0
    private var calls = 0
    private var maximum = 0

    func authorize(_ url: URL) async -> Int {
        activeCalls += 1
        calls += 1
        maximum = max(maximum, activeCalls)
        try? await Task.sleep(for: .milliseconds(30))
        activeCalls -= 1
        return url.lastPathComponent == "Shared" ? calls : -1
    }

    var snapshot: (callCount: Int, maximumConcurrentCalls: Int) {
        (calls, maximum)
    }
}

private final class PathBookmarkHarness: @unchecked Sendable {
    static func resolve(_ data: Data) throws -> ExternalDirectoryBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw ExternalDirectoryError.unavailable
        }
        return ExternalDirectoryBookmarkResolution(
            url: URL(fileURLWithPath: path, isDirectory: true),
            isStale: false
        )
    }

    var access: ExternalDirectoryBookmarkAccess {
        ExternalDirectoryBookmarkAccess(
            create: { Data($0.path.utf8) },
            resolve: Self.resolve,
            beginAccess: { _ in true },
            endAccess: { _ in }
        )
    }
}

private final class SynchronousCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

private final class FinalScopeRebindHarness: @unchecked Sendable {
    struct Counts {
        let begin: Int
        let end: Int
    }

    private let lock = NSLock()
    private let source: URL
    private let movedSource: URL
    private var beginCount = 0
    private var endCount = 0

    init(source: URL, movedSource: URL) {
        self.source = source
        self.movedSource = movedSource
    }

    var access: ExternalDirectoryBookmarkAccess {
        ExternalDirectoryBookmarkAccess(
            create: { Data($0.path.utf8) },
            resolve: PathBookmarkHarness.resolve,
            beginAccess: { [self] _ in
                lock.lock()
                defer { lock.unlock() }
                beginCount += 1
                if beginCount == 3 {
                    do {
                        try FileManager.default.moveItem(at: source, to: movedSource)
                        try FileManager.default.createDirectory(
                            at: source,
                            withIntermediateDirectories: false
                        )
                    } catch {
                        return false
                    }
                }
                return true
            },
            endAccess: { [self] _ in
                lock.withLock { endCount += 1 }
            }
        )
    }

    var counts: Counts {
        lock.withLock { Counts(begin: beginCount, end: endCount) }
    }
}

private final class ScopeHarness: @unchecked Sendable {
    struct Counts: Equatable {
        let begin: Int
        let end: Int
    }

    private let lock = NSLock()
    private let beginResult: Bool
    private var beginCount = 0
    private var endCount = 0

    init(beginResult: Bool = true) {
        self.beginResult = beginResult
    }

    var access: ExternalDirectoryBookmarkAccess {
        ExternalDirectoryBookmarkAccess(
            create: { _ in Data() },
            resolve: { _ in
                ExternalDirectoryBookmarkResolution(url: URL(fileURLWithPath: "/"), isStale: false)
            },
            beginAccess: { [self] _ in
                lock.withLock { beginCount += 1 }
                return beginResult
            },
            endAccess: { [self] _ in
                lock.withLock { endCount += 1 }
            }
        )
    }

    var counts: Counts {
        lock.withLock { Counts(begin: beginCount, end: endCount) }
    }
}
