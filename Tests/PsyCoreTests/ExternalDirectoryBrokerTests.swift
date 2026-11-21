import Foundation
import XCTest

@testable import PsyCore

final class ExternalDirectoryBrokerTests: XCTestCase {
    private static let configurationRevision = String(repeating: "a", count: 64)

    func testLegacyRecordMigratesWithoutPersistingAbsolutePath() async throws {
        let roots = try makeRoots()
        let id = UUID()
        let legacy = LegacyExternalDirectoryRecord(
            id: id,
            displayName: "Legacy",
            bookmark: Data("opaque-bookmark".utf8),
            mode: .direct,
            capabilities: Self.fullCapabilities(),
            lastResolvedPath: "/private/secret/provider/path",
            lastProbedAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([legacy]).write(to: roots.records, options: .atomic)

        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() },
            now: { Date(timeIntervalSince1970: 10) }
        )
        try await broker.load()

        let migratedRecords = await broker.allRecords()
        let record = try XCTUnwrap(migratedRecords.first)
        XCTAssertEqual(record.schemaVersion, ExternalDirectoryRecord.currentSchemaVersion)
        XCTAssertEqual(record.managedRootToken, id.uuidString.lowercased())
        XCTAssertEqual(record.syncBinding.folderID.rawValue, "external-\(id.uuidString.lowercased())")
        XCTAssertEqual(record.syncBinding.phase, .queued)
        XCTAssertEqual(record.mode, .controlledMirror)
        XCTAssertEqual(record.lastMirrorStatus.phase, .neverRun)
        let persisted = try String(contentsOf: roots.records, encoding: .utf8)
        XCTAssertFalse(persisted.contains("lastResolvedPath"))
        XCTAssertFalse(persisted.contains("/private/secret/provider/path"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: roots.managedBase.appendingPathComponent(id.uuidString.lowercased()).path
            )
        )

        let reloadedBroker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        try await reloadedBroker.load()
        let reloadedRecords = await reloadedBroker.allRecords()
        let reloaded = try XCTUnwrap(reloadedRecords.first)
        XCTAssertEqual(reloaded.syncBinding.folderID, record.syncBinding.folderID)
        XCTAssertEqual(reloaded.syncBinding.commandID, record.syncBinding.commandID)
    }

    func testCapabilityModesOnlyDowngradeWithoutBroadeningDirection() {
        var readOnly = ExternalDirectoryCapabilities()
        readOnly.canEnumerate = true
        readOnly.canRead = true
        readOnly.recommendedMode = .importOnly

        XCTAssertEqual(
            ExternalDirectoryAccessBroker.safeMode(requested: .controlledMirror, capabilities: readOnly),
            .importOnly
        )
        XCTAssertEqual(
            ExternalDirectoryAccessBroker.safeMode(requested: .exportOnly, capabilities: readOnly),
            .readOnly
        )
        XCTAssertEqual(
            ExternalDirectoryAccessBroker.allowedModes(for: readOnly),
            [.importOnly, .readOnly]
        )

        let full = Self.fullCapabilities()
        XCTAssertEqual(
            ExternalDirectoryAccessBroker.safeMode(requested: .direct, capabilities: full),
            .controlledMirror
        )
        XCTAssertEqual(
            ExternalDirectoryAccessBroker.allowedModes(for: full),
            [.controlledMirror, .exportOnly, .importOnly, .readOnly]
        )
    }

    func testManagedRootTokensAndFolderIdentifiersStayContainedOutsideCoreHome() throws {
        let container = try makeRoots().container
        let paths = SharedContainerPaths(root: container)
        let token = UUID().uuidString.lowercased()
        let external = try paths.createExternalManagedRoot(for: token)
        let folderID = try XCTUnwrap(FolderID(rawValue: "team/docs"))
        let folder = try paths.createManagedFolder(for: folderID)

        XCTAssertTrue(isContained(external, by: paths.externalManagedFoldersRoot))
        XCTAssertTrue(isContained(folder, by: paths.synchronizedManagedFoldersRoot))
        XCTAssertFalse(isContained(folder, by: paths.coreData))
        XCTAssertFalse(isContained(folder, by: paths.coreConfiguration))
        XCTAssertFalse(folder.lastPathComponent.contains("/"))
        XCTAssertThrowsError(try paths.externalManagedRoot(for: "../escape")) {
            XCTAssertEqual($0 as? SharedContainerError, .invalidManagedRootToken)
        }
    }

    func testManagedFolderCreationRejectsParentAndLeafSymlinksBeforeWriting() throws {
        let manager = FileManager.default
        let container = manager.temporaryDirectory
            .appendingPathComponent("ManagedFolderSymlink-\(UUID().uuidString)", isDirectory: true)
        let outside = manager.temporaryDirectory
            .appendingPathComponent("ManagedFolderOutside-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: container, withIntermediateDirectories: false)
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: container)
            try? FileManager.default.removeItem(at: outside)
        }

        let paths = SharedContainerPaths(root: container)
        let folderID = try XCTUnwrap(FolderID(rawValue: "pending-safe-folder"))
        let escapedLeaf = outside.appendingPathComponent(
            try paths.managedFolder(for: folderID).lastPathComponent,
            isDirectory: true
        )

        try manager.createSymbolicLink(
            at: paths.managedFoldersRoot,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try paths.createManagedFolder(for: folderID)) {
            XCTAssertEqual($0 as? SharedContainerError, .unsafeManagedFolderRoot)
        }
        XCTAssertFalse(manager.fileExists(atPath: escapedLeaf.path))

        try manager.removeItem(at: paths.managedFoldersRoot)
        try manager.createDirectory(at: paths.managedFoldersRoot, withIntermediateDirectories: false)
        try manager.createSymbolicLink(
            at: paths.synchronizedManagedFoldersRoot,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try paths.createManagedFolder(for: folderID)) {
            XCTAssertEqual($0 as? SharedContainerError, .unsafeManagedFolderRoot)
        }
        XCTAssertFalse(manager.fileExists(atPath: escapedLeaf.path))

        try manager.removeItem(at: paths.synchronizedManagedFoldersRoot)
        try manager.createDirectory(
            at: paths.synchronizedManagedFoldersRoot,
            withIntermediateDirectories: false
        )
        let managedFolder = try paths.managedFolder(for: folderID)
        try manager.createSymbolicLink(at: managedFolder, withDestinationURL: outside)
        XCTAssertThrowsError(try paths.createManagedFolder(for: folderID)) {
            XCTAssertEqual($0 as? SharedContainerError, .unsafeManagedFolderRoot)
        }
        XCTAssertEqual(
            try manager.contentsOfDirectory(
                at: outside,
                includingPropertiesForKeys: nil
            ),
            []
        )
    }

    func testAuthorizationRejectsManagedRootOverlapBeforeCapabilityProbe() async throws {
        let roots = try makeRoots()
        let counter = ProbeCounter()
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in
                counter.increment()
                return Self.fullCapabilities()
            }
        )

        do {
            _ = try await broker.authorize(
                url: roots.managedBase,
                requestedMode: .controlledMirror
            )
            XCTFail("a provider root must not overlap the App-owned mirror base")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .bindingConflict)
        }
        let outside = roots.container.appendingPathComponent("symlink-target", isDirectory: true)
        let symlink = roots.container.appendingPathComponent("provider-symlink", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        do {
            _ = try await broker.authorize(url: symlink, requestedMode: .controlledMirror)
            XCTFail("a symbolic-link provider root must be rejected before probing")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .bindingConflict)
        }
        XCTAssertEqual(counter.value, 0)
        let records = await broker.allRecords()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(try CoreCommandQueue(root: roots.commands).pending().isEmpty)
    }

    func testMirrorRefusesUnverifiedBindingBeforeAccessingProviderOrCopyingFiles() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("unverified-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("must-not-copy".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        let harness = BookmarkHarness()
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )

        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        let authorizationAccessCount = harness.beginCount

        do {
            _ = try await broker.runMirror(id: record.id)
            XCTFail("mirror must remain unavailable until the core snapshot verifies its exact root")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .bindingNotVerified)
        }

        XCTAssertEqual(harness.beginCount, authorizationAccessCount)
        XCTAssertEqual(harness.endCount, authorizationAccessCount)
        let managedRoot = roots.managedBase.appendingPathComponent(record.managedRootToken)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: managedRoot.appendingPathComponent("document.txt").path
            )
        )
    }

    func testBrokerRunsMirrorWithBalancedScopeAndRemovalKeepsManagedData() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: external.appendingPathComponent("document.txt"), options: .atomic)
        let harness = BookmarkHarness()
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() },
            now: { Date(timeIntervalSince1970: 20) }
        )

        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        let authorizationScopeCount = harness.beginCount
        _ = try await broker.reconcileSyncBindings(snapshot: CoreSnapshot())
        let bindingCommand = try XCTUnwrap(
            try CoreCommandQueue(root: roots.commands).pending().first
        )
        XCTAssertEqual(bindingCommand.id, record.syncBinding.commandID)
        XCTAssertEqual(bindingCommand.kind, .addFolder)
        XCTAssertEqual(bindingCommand.folderID, record.syncBinding.folderID)
        XCTAssertEqual(
            bindingCommand.commandConfigurationRevision,
            Self.configurationRevision
        )
        let queuedBindingPath = try XCTUnwrap(bindingCommand.arguments["path"])
        XCTAssertEqual(
            URL(fileURLWithPath: queuedBindingPath).resolvingSymlinksInPath().path,
            roots.managedBase.appendingPathComponent(record.managedRootToken)
                .resolvingSymlinksInPath().path
        )
        XCTAssertEqual(bindingCommand.arguments["deviceIDs"], "[]")
        let verifiedSnapshot = CoreSnapshot(
            generation: 1,
            folders: [
                FolderRecord(
                    id: record.syncBinding.folderID,
                    label: "External",
                    localPath: roots.managedBase.appendingPathComponent(record.managedRootToken).path,
                    deviceIDs: []
                )
            ]
        )
        try SharedSnapshotStore(snapshotURL: roots.snapshot).write(verifiedSnapshot)
        let folderContext = try XCTUnwrap(
            FolderIncarnationStore(
                url: SharedContainerPaths(root: roots.container).folderIncarnations
            ).ensureLegacyConfiguredFolders([record.syncBinding.folderID]).first)
        _ = try await broker.reconcileSyncBindings(snapshot: verifiedSnapshot)
        let status = try await broker.runMirror(id: record.id)
        XCTAssertEqual(status.phase, .succeeded)
        XCTAssertEqual(status.importedFiles, 1)
        XCTAssertNil(status.failureCode)
        let pendingAfterMirror = try CoreCommandQueue(root: roots.commands).pending()
        let rescan = try XCTUnwrap(pendingAfterMirror.first(where: { $0.kind == .rescan }))
        XCTAssertEqual(rescan.folderID, record.syncBinding.folderID)
        XCTAssertEqual(
            rescan.folderIncarnationDigest,
            folderContext.folderIncarnationDigest
        )
        XCTAssertEqual(rescan.trigger, .user)
        XCTAssertEqual(pendingAfterMirror.filter { $0.kind == .rescan }.count, 1)
        XCTAssertEqual(harness.beginCount, authorizationScopeCount + 1)
        XCTAssertEqual(harness.endCount, harness.beginCount)

        let managedRoot = roots.managedBase.appendingPathComponent(record.managedRootToken)
        XCTAssertEqual(
            try String(contentsOf: managedRoot.appendingPathComponent("document.txt"), encoding: .utf8),
            "payload"
        )
        let persisted = try String(contentsOf: roots.records, encoding: .utf8)
        XCTAssertFalse(persisted.contains(external.path))
        XCTAssertFalse(persisted.contains(managedRoot.path))
        XCTAssertFalse(persisted.contains("localizedDescription"))

        try await broker.remove(id: record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("document.txt").path))
        let remainingRecords = await broker.allRecords()
        let revoked = try XCTUnwrap(remainingRecords.first)
        XCTAssertEqual(revoked.authorizationState, .revoked)
        XCTAssertTrue(revoked.bookmark.isEmpty)
        XCTAssertEqual(revoked.syncBinding.phase, .verified)
        XCTAssertEqual(
            try CoreCommandQueue(root: roots.commands).pending().filter { $0.kind == .rescan },
            [rescan]
        )
    }

    func testMirrorDoesNotReportSuccessWhenManagedRootRescanCannotBeQueued() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("rescan-queue-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)

        if FileManager.default.fileExists(atPath: roots.commands.path) {
            try FileManager.default.removeItem(at: roots.commands)
        }
        try FileManager.default.createDirectory(
            at: roots.commands.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a queue directory".utf8).write(to: roots.commands, options: .atomic)
        let status = try await broker.runMirror(id: record.id)
        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .rescanQueueFailed)
        let records = await broker.allRecords()
        let persisted = try XCTUnwrap(records.first)
        XCTAssertEqual(persisted.lastMirrorStatus.phase, .retryableFailure)
        XCTAssertEqual(persisted.lastMirrorStatus.failureCode, .rescanQueueFailed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: roots.managedBase
                    .appendingPathComponent(record.managedRootToken)
                    .appendingPathComponent("document.txt").path
            ),
            "the completed file copy remains safe even though it is not reported as indexed"
        )
    }

    func testRevocationFencesBlockedMirrorCompletionAcrossBrokerInstances() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("revocation-race-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: external.appendingPathComponent("document.txt"), options: .atomic)
        let harness = BookmarkHarness()
        let copyGate = MirrorCopyGate()
        let runningBroker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            mirrorIO: copyGate.io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let revokingBroker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await runningBroker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: runningBroker, roots: roots)
        try await revokingBroker.load()

        let run = Task { try await runningBroker.runMirror(id: record.id) }
        defer {
            copyGate.release()
            run.cancel()
        }
        XCTAssertTrue(copyGate.waitUntilBlocked(timeout: 5), "the mirror must reach its blocked copy")
        let revocationCompleted = CompletionProbe()
        let revocation = Task {
            try await revokingBroker.remove(id: record.id)
            revocationCompleted.markCompleted()
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(
            revocationCompleted.isCompleted,
            "revocation must wait for the record's in-flight mirror lease"
        )
        copyGate.release()
        let status = try await run.value
        XCTAssertEqual(status.phase, .succeeded)
        try await revocation.value
        XCTAssertTrue(revocationCompleted.isCompleted)

        let reloaded = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        try await reloaded.load()
        let reloadedRecords = await reloaded.allRecords()
        let persisted = try XCTUnwrap(reloadedRecords.first)
        XCTAssertEqual(persisted.authorizationState, .revoked)
        XCTAssertTrue(persisted.bookmark.isEmpty)
        XCTAssertTrue(persisted.pendingDeletionConfirmations.isEmpty)
        XCTAssertEqual(persisted.lastMirrorStatus.failureCode, .authorizationRevoked)
        XCTAssertEqual(persisted.syncBinding.phase, .verified)
        let managedRoot = roots.managedBase.appendingPathComponent(record.managedRootToken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedRoot.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("document.txt").path),
            "the in-flight copy must linearize before revocation, never after revocation returns"
        )
    }

    func testRevocationWaitsForInFlightExternalCommitAndFencesLaterMutations() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("external-commit-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let harness = BookmarkHarness()
        let copyGate = MirrorCopyGate()
        let runningBroker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            mirrorIO: copyGate.io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let revokingBroker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await runningBroker.authorize(url: external, requestedMode: .exportOnly)
        try await verifyBinding(record, broker: runningBroker, roots: roots)
        try await revokingBroker.load()
        let managedFile = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.txt")
        try Data("before-revocation".utf8).write(to: managedFile, options: .atomic)

        let run = Task { try await runningBroker.runMirror(id: record.id) }
        defer {
            copyGate.release()
            run.cancel()
        }
        XCTAssertTrue(copyGate.waitUntilBlocked(timeout: 5))
        let revocationCompleted = CompletionProbe()
        let revocation = Task {
            try await revokingBroker.remove(id: record.id)
            revocationCompleted.markCompleted()
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(revocationCompleted.isCompleted)

        copyGate.release()
        let runStatus = try await run.value
        XCTAssertEqual(runStatus.phase, .succeeded)
        try await revocation.value
        let externalFile = external.appendingPathComponent("document.txt")
        XCTAssertEqual(
            try String(contentsOf: externalFile, encoding: .utf8),
            "before-revocation"
        )

        try Data("after-revocation".utf8).write(to: managedFile, options: .atomic)
        do {
            _ = try await runningBroker.runMirror(id: record.id)
            XCTFail("the revoked epoch must not perform later external writes")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .authorizationAlreadyRevoked)
        }
        XCTAssertEqual(
            try String(contentsOf: externalFile, encoding: .utf8),
            "before-revocation"
        )
    }

    func testBindingVerificationRequiresExactLocalOnlyActiveSendReceiveConfiguration() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("strict-binding-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        let managedRoot = roots.managedBase.appendingPathComponent(record.managedRootToken)
        let peer = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))

        let mismatches: [(FolderRecord, String)] = [
            (
                FolderRecord(
                    id: record.syncBinding.folderID,
                    label: "Legacy",
                    localPath: managedRoot.path
                ),
                "folder_devices_unavailable"
            ),
            (
                FolderRecord(
                    id: record.syncBinding.folderID,
                    label: "Shared",
                    localPath: managedRoot.path,
                    deviceIDs: [peer]
                ),
                "folder_shared_with_peers"
            ),
            (
                FolderRecord(
                    id: record.syncBinding.folderID,
                    label: "Wrong Type",
                    localPath: managedRoot.path,
                    type: .sendOnly,
                    deviceIDs: []
                ),
                "folder_type_mismatch"
            ),
            (
                FolderRecord(
                    id: record.syncBinding.folderID,
                    label: "Paused",
                    localPath: managedRoot.path,
                    isPaused: true,
                    deviceIDs: []
                ),
                "folder_paused"
            ),
        ]
        for (folder, failureCode) in mismatches {
            let result = try await broker.reconcileSyncBindings(snapshot: CoreSnapshot(folders: [folder]))
            XCTAssertEqual(result.verifiedRecordCount, 0)
            let records = await broker.allRecords()
            let current = try XCTUnwrap(records.first)
            XCTAssertEqual(current.syncBinding.phase, .conflict)
            XCTAssertEqual(current.syncBinding.failureCode, failureCode)
        }

        let sharedFolder = mismatches[1].0
        do {
            try await broker.repairSyncBinding(
                id: record.id,
                snapshot: CoreSnapshot(folders: [sharedFolder])
            )
            XCTFail("repair must not mark a peer-shared folder as verified")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .bindingConflict)
        }
        let conflictedRecords = await broker.allRecords()
        XCTAssertEqual(
            try XCTUnwrap(conflictedRecords.first).syncBinding.failureCode,
            "folder_shared_with_peers"
        )

        let verified = try await broker.reconcileSyncBindings(
            snapshot: CoreSnapshot(
                folders: [
                    FolderRecord(
                        id: record.syncBinding.folderID,
                        label: "Local Only",
                        localPath: managedRoot.path,
                        type: .sendReceive,
                        isPaused: false,
                        deviceIDs: []
                    )
                ]
            )
        )
        XCTAssertEqual(verified.verifiedRecordCount, 1)
        let records = await broker.allRecords()
        XCTAssertEqual(try XCTUnwrap(records.first).syncBinding.phase, .verified)
    }

    func testLegacyFolderSnapshotWithoutDeviceIDsDecodesButCannotVerifyBinding() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("legacy-folder-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        let legacy = LegacyFolderRecord(
            id: record.syncBinding.folderID,
            label: "Legacy",
            localPath: roots.managedBase.appendingPathComponent(record.managedRootToken).path,
            type: .sendReceive,
            selectionMode: .full,
            isPaused: false,
            pendingUploadBytes: 0,
            pendingDownloadBytes: 0,
            error: nil
        )
        let decoded = try JSONDecoder().decode(
            FolderRecord.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(decoded.deviceIDs)

        _ = try await broker.reconcileSyncBindings(snapshot: CoreSnapshot(folders: [decoded]))
        let records = await broker.allRecords()
        let current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.syncBinding.phase, .conflict)
        XCTAssertEqual(current.syncBinding.failureCode, "folder_devices_unavailable")
    }

    func testMirrorAndConfirmationRevalidateLatestSnapshotBeforeProviderMutation() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("snapshot-fence-provider", isDirectory: true)
        let externalFile = external.appendingPathComponent("document.txt")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: externalFile, options: .atomic)
        let harness = BookmarkHarness()
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        try await verifyBinding(record, broker: broker, roots: roots)
        _ = try await broker.runMirror(id: record.id)
        let managedFile = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.txt")
        try FileManager.default.removeItem(at: managedFile)
        let pending = try await broker.runMirror(id: record.id)
        XCTAssertEqual(pending.phase, .requiresConfirmation)
        let pendingRecords = await broker.allRecords()
        let confirmation = try XCTUnwrap(pendingRecords.first?.pendingDeletionConfirmations.first)

        let peer = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let sharedSnapshot = authoritativeSnapshot(
            for: record,
            roots: roots,
            generation: 2,
            deviceIDs: [peer]
        )
        try SharedSnapshotStore(snapshotURL: roots.snapshot).write(sharedSnapshot)
        let accessCount = harness.beginCount

        do {
            _ = try await broker.runMirror(id: record.id)
            XCTFail("a newly shared folder must block mirror I/O")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .bindingNotVerified)
        }
        XCTAssertEqual(harness.beginCount, accessCount)

        let repairedSnapshot = authoritativeSnapshot(
            for: record,
            roots: roots,
            generation: 3
        )
        try SharedSnapshotStore(snapshotURL: roots.snapshot).write(repairedSnapshot)
        _ = try await broker.reconcileSyncBindings(snapshot: repairedSnapshot)
        let resharedSnapshot = authoritativeSnapshot(
            for: record,
            roots: roots,
            generation: 4,
            deviceIDs: [peer]
        )
        try SharedSnapshotStore(snapshotURL: roots.snapshot).write(resharedSnapshot)

        do {
            _ = try await broker.resolveDeletionConfirmation(
                recordID: record.id,
                confirmation: confirmation,
                decision: .propagateDeletion
            )
            XCTFail("a newly shared folder must invalidate an old deletion confirmation")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .bindingNotVerified)
        }
        XCTAssertEqual(harness.beginCount, accessCount)
        XCTAssertEqual(try String(contentsOf: externalFile, encoding: .utf8), "payload")
        let records = await broker.allRecords()
        let current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.syncBinding.phase, .conflict)
        XCTAssertEqual(current.syncBinding.failureCode, "folder_shared_with_peers")
    }

    func testOnlyOneBrokerCanRunMirrorForRecordAtATime() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("concurrent-run-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: external.appendingPathComponent("document.txt"), options: .atomic)
        let harness = BookmarkHarness()
        let copyGate = MirrorCopyGate()
        let firstBroker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            mirrorIO: copyGate.io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let secondBroker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await firstBroker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: firstBroker, roots: roots)
        try await secondBroker.load()

        let firstRun = Task { try await firstBroker.runMirror(id: record.id) }
        defer {
            copyGate.release()
            firstRun.cancel()
        }
        XCTAssertTrue(copyGate.waitUntilBlocked(timeout: 5), "the first mirror must hold the record lease")
        do {
            _ = try await secondBroker.runMirror(id: record.id)
            XCTFail("a second broker must not run the same mirror concurrently")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .mirrorAlreadyRunning)
        }

        copyGate.release()
        let firstStatus = try await firstRun.value
        XCTAssertEqual(firstStatus.phase, .succeeded)
    }

    func testBrokerTransactionsMergeRecordsAndKeepRevocationMonotonic() async throws {
        let roots = try makeRoots()
        let firstExternal = roots.container.appendingPathComponent("first-provider", isDirectory: true)
        let secondExternal = roots.container.appendingPathComponent("second-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: firstExternal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondExternal, withIntermediateDirectories: true)
        let harness = BookmarkHarness()
        let firstBroker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let staleBroker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )

        let first = try await firstBroker.authorize(url: firstExternal, requestedMode: .controlledMirror)
        let second = try await staleBroker.authorize(url: secondExternal, requestedMode: .controlledMirror)
        let mergedRecords = await firstBroker.allRecords()
        XCTAssertEqual(Set(mergedRecords.map(\.id)), Set([first.id, second.id]))

        try await firstBroker.remove(id: first.id)
        do {
            _ = try await staleBroker.updateMode(id: first.id, requestedMode: .readOnly)
            XCTFail("a stale broker must not mutate or reactivate a revoked record")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .authorizationAlreadyRevoked)
        }

        let persistedRecords = await staleBroker.allRecords()
        let revoked = try XCTUnwrap(persistedRecords.first(where: { $0.id == first.id }))
        XCTAssertEqual(revoked.authorizationState, .revoked)
        XCTAssertTrue(revoked.bookmark.isEmpty)
        XCTAssertEqual(revoked.authorizationEpoch, first.authorizationEpoch + 1)
        XCTAssertGreaterThan(revoked.revision, first.revision)
        XCTAssertNotNil(persistedRecords.first(where: { $0.id == second.id }))
    }

    func testBindingReconciliationIsIdempotentAndRequiresExactSnapshotPath() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("binding-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        let managedRoot = roots.managedBase.appendingPathComponent(record.managedRootToken)
        let existingIgnore = "// user header\n#escape=\\\n!/**\n"
        try Data(existingIgnore.utf8).write(
            to: managedRoot.appendingPathComponent(".stignore"),
            options: .atomic
        )

        let first = try await broker.reconcileSyncBindings(snapshot: CoreSnapshot())
        let second = try await broker.reconcileSyncBindings(snapshot: CoreSnapshot())
        XCTAssertEqual(first.enqueuedCommandCount, 1)
        XCTAssertEqual(second.enqueuedCommandCount, 0)
        XCTAssertEqual(try CoreCommandQueue(root: roots.commands).pending().count, 1)
        let ignore = try String(
            contentsOf: managedRoot.appendingPathComponent(".stignore"),
            encoding: .utf8
        )
        XCTAssertEqual(ignore, existingIgnore, "binding reconciliation must never rewrite .stignore")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: external.appendingPathComponent(".stignore").path
            )
        )

        let wrongPath = roots.container.appendingPathComponent("wrong", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongPath, withIntermediateDirectories: true)
        _ = try await broker.reconcileSyncBindings(
            snapshot: CoreSnapshot(
                folders: [
                    FolderRecord(
                        id: record.syncBinding.folderID,
                        label: "Wrong",
                        localPath: wrongPath.path,
                        deviceIDs: []
                    )
                ]
            )
        )
        var records = await broker.allRecords()
        var current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.syncBinding.phase, .conflict)
        XCTAssertEqual(current.syncBinding.failureCode, "folder_path_mismatch")

        let pendingCommandID = current.syncBinding.commandID
        try await broker.repairSyncBinding(id: record.id, snapshot: CoreSnapshot())
        records = await broker.allRecords()
        current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.syncBinding.phase, .queued)
        XCTAssertEqual(current.syncBinding.commandID, pendingCommandID)
        XCTAssertEqual(try CoreCommandQueue(root: roots.commands).pending().map(\.id), [pendingCommandID])

        _ = try await broker.reconcileSyncBindings(
            snapshot: CoreSnapshot(
                folders: [
                    FolderRecord(
                        id: record.syncBinding.folderID,
                        label: "External",
                        localPath: managedRoot.path,
                        deviceIDs: []
                    )
                ]
            )
        )
        records = await broker.allRecords()
        current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.syncBinding.phase, .verified)
        XCTAssertNil(current.syncBinding.failureCode)
    }

    func testVerifiedBindingDoesNotAutoRecreateMissingFolderAndRepairRotatesCommand() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("repair-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        let managedRoot = roots.managedBase.appendingPathComponent(record.managedRootToken)
        _ = try await broker.reconcileSyncBindings(
            snapshot: CoreSnapshot(
                folders: [
                    FolderRecord(
                        id: record.syncBinding.folderID,
                        label: "External",
                        localPath: managedRoot.path,
                        deviceIDs: []
                    )
                ]
            )
        )

        _ = try await broker.reconcileSyncBindings(snapshot: CoreSnapshot())
        var records = await broker.allRecords()
        var current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.syncBinding.phase, .repairRequired)
        XCTAssertTrue(try CoreCommandQueue(root: roots.commands).pending().isEmpty)

        let oldCommandID = current.syncBinding.commandID
        try await broker.repairSyncBinding(id: record.id, snapshot: CoreSnapshot())
        records = await broker.allRecords()
        current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.syncBinding.phase, .queued)
        XCTAssertNotEqual(current.syncBinding.commandID, oldCommandID)
        XCTAssertEqual(try CoreCommandQueue(root: roots.commands).pending().map(\.id), [current.syncBinding.commandID])
    }

    func testManagedBindingRootSymlinkAndFolderOverlapFailClosedBeforeQueueing() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("unsafe-provider", isDirectory: true)
        let outside = roots.container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        let managedRoot = roots.managedBase.appendingPathComponent(record.managedRootToken)
        try FileManager.default.removeItem(at: managedRoot)
        try FileManager.default.createSymbolicLink(at: managedRoot, withDestinationURL: outside)

        _ = try await broker.reconcileSyncBindings(snapshot: CoreSnapshot())
        var records = await broker.allRecords()
        var current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.syncBinding.phase, .conflict)
        XCTAssertEqual(current.syncBinding.failureCode, "unsafe_managed_root")
        XCTAssertTrue(try CoreCommandQueue(root: roots.commands).pending().isEmpty)

        try FileManager.default.removeItem(at: managedRoot)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        do {
            try await broker.repairSyncBinding(
                id: record.id,
                snapshot: CoreSnapshot(
                    folders: [
                        FolderRecord(
                            id: FolderID(rawValue: "overlap")!,
                            label: "Overlap",
                            localPath: roots.managedBase.path
                        )
                    ]
                )
            )
            XCTFail("overlapping folders must block repair")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .bindingConflict)
        }
        records = await broker.allRecords()
        current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.syncBinding.phase, .conflict)
        XCTAssertEqual(current.syncBinding.failureCode, "folder_path_overlap")
        XCTAssertTrue(try CoreCommandQueue(root: roots.commands).pending().isEmpty)
    }

    func testUserIgnoreContentsAreOpaqueAndRemainUnchangedWhileBindingQueues() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("ignore-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        let ignoreURL = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent(".stignore")
        let modified = """
            // BEGIN Psynguechthyngue external mirror internals
            // user-modified managed block
            // END Psynguechthyngue external mirror internals

            """
        try Data(modified.utf8).write(to: ignoreURL, options: .atomic)

        _ = try await broker.reconcileSyncBindings(snapshot: CoreSnapshot())

        let records = await broker.allRecords()
        let current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.syncBinding.phase, .queued)
        XCTAssertNil(current.syncBinding.failureCode)
        XCTAssertEqual(try String(contentsOf: ignoreURL, encoding: .utf8), modified)
        XCTAssertEqual(try CoreCommandQueue(root: roots.commands).pending().count, 1)
    }

    func testBrokerPersistsAndResolvesDeletionConfirmationWithoutDeletingChangedContent() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("confirmation-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: external.appendingPathComponent("document.txt"), options: .atomic)
        let harness = BookmarkHarness()
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() },
            now: { Date(timeIntervalSince1970: 30) }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        try await verifyBinding(record, broker: broker, roots: roots)
        _ = try await broker.runMirror(id: record.id)
        let managed = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.txt")
        try FileManager.default.removeItem(at: managed)
        let pendingStatus = try await broker.runMirror(id: record.id)
        XCTAssertEqual(pendingStatus.phase, .requiresConfirmation)
        let persistedRecords = await broker.allRecords()
        let persisted = try XCTUnwrap(persistedRecords.first)
        let confirmation = try XCTUnwrap(persisted.pendingDeletionConfirmations.first)
        XCTAssertEqual(confirmation.relativePath, "document.txt")
        let paths = SharedContainerPaths(root: roots.container)
        let policy = try SyncPolicyStore(url: paths.policy).loadDocument()
        let accounting = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: policy.budgetTimeZoneIdentifier
        )
        let receiptsBeforeConfirmation = Set(
            try accounting.snapshot().settledReceipts.map(\.id)
        )

        let resolved = try await broker.resolveDeletionConfirmation(
            recordID: record.id,
            confirmation: confirmation,
            decision: .keepSurvivingCopy
        )
        XCTAssertEqual(resolved.phase, .succeeded)
        XCTAssertEqual(try String(contentsOf: managed, encoding: .utf8), "payload")
        let refreshedRecords = await broker.allRecords()
        let refreshed = try XCTUnwrap(refreshedRecords.first)
        XCTAssertTrue(refreshed.pendingDeletionConfirmations.isEmpty)
        let confirmationReceipts = try accounting.snapshot().settledReceipts.filter {
            !receiptsBeforeConfirmation.contains($0.id)
        }
        XCTAssertEqual(confirmationReceipts.map(\.kind), [.exact, .exact])
        XCTAssertEqual(confirmationReceipts.map(\.grantedBytes), [7, 35])
        XCTAssertEqual(confirmationReceipts.map(\.chargedBytes), [7, 35])

        try FileManager.default.removeItem(at: managed)
        _ = try await broker.runMirror(id: record.id)
        let staleRecords = await broker.allRecords()
        let staleRecord = try XCTUnwrap(staleRecords.first)
        let stale = try XCTUnwrap(staleRecord.pendingDeletionConfirmations.first)
        try Data("changed".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        do {
            _ = try await broker.resolveDeletionConfirmation(
                recordID: record.id,
                confirmation: stale,
                decision: .propagateDeletion
            )
            XCTFail("a stale provider prompt must not delete changed content")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .deletionConfirmationChanged)
        }
        XCTAssertEqual(
            try String(contentsOf: external.appendingPathComponent("document.txt"), encoding: .utf8),
            "changed"
        )
    }

    func testDeletionConfirmationCapDenialCopiesZeroProviderBytes() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent(
            "confirmation-cap-provider",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        let accountingDate = Date(timeIntervalSince1970: 1_700_000_000)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() },
            now: { accountingDate }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        try await verifyBinding(record, broker: broker, roots: roots)
        _ = try await broker.runMirror(id: record.id)
        let managed = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.txt")
        try FileManager.default.removeItem(at: managed)
        _ = try await broker.runMirror(id: record.id)
        let records = await broker.allRecords()
        let pending = try XCTUnwrap(records.first)
        let confirmation = try XCTUnwrap(pending.pendingDeletionConfirmations.first)

        let paths = SharedContainerPaths(root: roots.container)
        var policy = SyncPolicy()
        policy.allowExpensive = true
        policy.maxExpensiveRunBytes = 6
        policy.dailyExpensiveBytes = 1_000
        try SyncPolicyStore(url: paths.policy).save(policy)
        let document = try SyncPolicyStore(url: paths.policy).loadDocument()
        let accounting = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        )
        let receiptIDs = Set(try accounting.snapshot().settledReceipts.map(\.id))
        let environment: ExternalDirectoryAccessBroker.CurrentEnvironment = {
            var value = SyncEnvironmentSnapshot.permissiveForTesting
            value.network = .init(kind: .wifi, isExpensive: true)
            value.capturedAt = accountingDate
            return value
        }

        do {
            _ = try await broker.resolveDeletionConfirmation(
                recordID: record.id,
                confirmation: confirmation,
                decision: .keepSurvivingCopy,
                currentEnvironment: environment
            )
            XCTFail("the full keep-copy bound must fit before provider copy")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .policyDenied)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        let after = try accounting.snapshot()
        XCTAssertTrue(after.activeReservations.isEmpty)
        XCTAssertEqual(Set(after.settledReceipts.map(\.id)), receiptIDs)
        let recordsAfterDenial = await broker.allRecords()
        XCTAssertEqual(
            try XCTUnwrap(recordsAfterDenial.first).pendingDeletionConfirmations,
            [confirmation]
        )
    }

    func testDeletionConfirmationMetersInterruptedJournalAndNewKeepCopySeparately() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent(
            "confirmation-interrupted-provider",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: external.appendingPathComponent("prompt.txt"),
            options: .atomic
        )
        let interruption = ArmableMirrorJournalFailure(trigger: .firstCompletedOperation)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            mirrorIO: interruption.io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        try await verifyBinding(record, broker: broker, roots: roots)
        _ = try await broker.runMirror(id: record.id)
        let managed = roots.managedBase.appendingPathComponent(record.managedRootToken)
        try FileManager.default.removeItem(at: managed.appendingPathComponent("prompt.txt"))
        _ = try await broker.runMirror(id: record.id)
        let pendingRecords = await broker.allRecords()
        let confirmation = try XCTUnwrap(
            try XCTUnwrap(pendingRecords.first).pendingDeletionConfirmations.first
        )

        for name in ["first.txt", "second.txt"] {
            try Data("payload".utf8).write(
                to: external.appendingPathComponent(name),
                options: .atomic
            )
        }
        interruption.arm()
        let interruptedStatus = try await broker.runMirror(id: record.id)
        XCTAssertEqual(interruptedStatus.phase, .retryableFailure)

        let paths = SharedContainerPaths(root: roots.container)
        let policy = try SyncPolicyStore(url: paths.policy).loadDocument()
        let accounting = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: policy.budgetTimeZoneIdentifier
        )
        let receiptsBeforeResolution = Set(
            try accounting.snapshot().settledReceipts.map(\.id)
        )
        let resolved = try await broker.resolveDeletionConfirmation(
            recordID: record.id,
            confirmation: confirmation,
            decision: .keepSurvivingCopy
        )

        XCTAssertEqual(resolved.phase, .succeeded)
        for name in ["prompt.txt", "first.txt", "second.txt"] {
            XCTAssertEqual(
                try String(contentsOf: managed.appendingPathComponent(name), encoding: .utf8),
                "payload"
            )
        }
        let resolutionReceipts = try accounting.snapshot().settledReceipts.filter {
            !receiptsBeforeResolution.contains($0.id)
        }
        XCTAssertEqual(resolutionReceipts.map(\.kind), [.exact, .exact, .exact])
        XCTAssertEqual(resolutionReceipts.map(\.grantedBytes), [49, 21, 49])
        XCTAssertEqual(resolutionReceipts.map(\.chargedBytes), [49, 21, 49])
        XCTAssertTrue(try accounting.snapshot().activeReservations.isEmpty)
    }

    func testMirrorPolicyGateRejectsInitialCellularRunAndAllowsExplicitTemporaryOverride() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("policy-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        let environment = DeferredFirstEnvironmentHarness(network: .init(kind: .cellular))
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)
        let managed = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.txt")

        let deniedRun = Task {
            try await broker.runMirror(
                id: record.id,
                trigger: .user,
                currentEnvironment: { await environment.capture() }
            )
        }
        await environment.waitUntilFirstCaptureStarts()
        let recordsWhilePolicyIsPending = await broker.allRecords()
        XCTAssertEqual(recordsWhilePolicyIsPending.first?.lastMirrorStatus.phase, .neverRun)
        await environment.releaseFirstCapture()
        let denied = try await deniedRun.value
        XCTAssertEqual(denied.phase, .retryableFailure)
        XCTAssertEqual(denied.failureCode, .policyDenied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))

        let overridden = try await broker.runMirror(
            id: record.id,
            trigger: .user,
            requestedTemporaryOverride: true,
            currentEnvironment: { await environment.capture() }
        )
        XCTAssertEqual(overridden.phase, .succeeded)
        XCTAssertEqual(try String(contentsOf: managed, encoding: .utf8), "payload")
        let captureCount = await environment.captureCount
        XCTAssertGreaterThan(captureCount, 1)
    }

    func testMirrorPolicyGateAppliesTighterExactFolderOverrideThanGlobalPolicy() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("folder-policy-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)
        let paths = SharedContainerPaths(root: roots.container)
        let context = try FolderIncarnationStore(url: paths.folderIncarnations)
            .policyContext(for: record.syncBinding.folderID)
        var global = SyncPolicy()
        global.cellularAccess = .allowed
        try SyncPolicyStore(url: paths.policy).saveDocument(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                global: global,
                folderOverrides: [
                    FolderSyncPolicyOverride(
                        folderID: context.folderID,
                        folderIncarnationDigest: context.folderIncarnationDigest,
                        policy: SyncPolicyOverride(cellularAccess: .denied)
                    )
                ]
            )
        )

        let status = try await broker.runMirror(
            id: record.id,
            trigger: .user,
            currentEnvironment: {
                var environment = SyncEnvironmentSnapshot.permissiveForTesting
                environment.network = .init(kind: .cellular)
                return environment
            }
        )

        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .policyDenied)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: roots.managedBase
                    .appendingPathComponent(record.managedRootToken)
                    .appendingPathComponent("document.txt").path
            )
        )
    }

    func testMirrorPolicyGateRejectsStaleOverrideAfterFolderReadd() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("readded-policy-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)
        let paths = SharedContainerPaths(root: roots.container)
        let incarnations = FolderIncarnationStore(url: paths.folderIncarnations)
        let original = try incarnations.policyContext(for: record.syncBinding.folderID)
        try SyncPolicyStore(url: paths.policy).saveDocument(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                folderOverrides: [
                    FolderSyncPolicyOverride(
                        folderID: original.folderID,
                        folderIncarnationDigest: original.folderIncarnationDigest
                    )
                ]
            )
        )
        XCTAssertTrue(
            try incarnations.removeAfterSuccessfulDeletion(
                folderID: original.folderID,
                expectedFolderIncarnationDigest: original.folderIncarnationDigest
            )
        )
        let readded = try incarnations.recordSuccessfulCreation(
            folderID: original.folderID,
            commandID: UUID()
        )
        XCTAssertNotEqual(readded.folderIncarnationDigest, original.folderIncarnationDigest)

        let status = try await broker.runMirror(
            id: record.id,
            currentEnvironment: { .permissiveForTesting }
        )

        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .policyDenied)
    }

    func testMirrorPolicyGateUsesExactFolderAccountingInsteadOfAmbientHistory() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("accounted-policy-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 30).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)
        let paths = SharedContainerPaths(root: roots.container)
        let context = try FolderIncarnationStore(url: paths.folderIncarnations)
            .policyContext(for: record.syncBinding.folderID)
        var global = SyncPolicy()
        global.allowExpensive = true
        global.dailyExpensiveBytes = 1_000
        try SyncPolicyStore(url: paths.policy).saveDocument(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                global: global,
                folderOverrides: [
                    FolderSyncPolicyOverride(
                        folderID: context.folderID,
                        folderIncarnationDigest: context.folderIncarnationDigest,
                        policy: SyncPolicyOverride(dailyExpensiveBytes: .limit(100))
                    )
                ]
            )
        )
        let accountingDate = Date(timeIntervalSince1970: 1_700_000_000)
        let accounting = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: "UTC"
        )
        let ownerID = UUID()
        let binding = TransferAccountingGrantBinding(
            folderID: context.folderID,
            folderIncarnationDigest: context.folderIncarnationDigest,
            taskID: UUID(),
            sessionID: UUID(),
            planDigest: context.folderIncarnationDigest
        )
        let reservation = try accounting.reserve(
            ownerID: ownerID,
            binding: binding,
            grantBytes: 80,
            globalDailyLimitBytes: 1_000,
            folderDailyLimitBytes: 100,
            expiresAt: accountingDate.addingTimeInterval(3_600),
            at: accountingDate
        )
        _ = try accounting.settle(
            reservationID: reservation.id,
            ownerID: ownerID,
            binding: binding,
            outcome: .exact(bytes: 80),
            at: accountingDate
        )

        let status = try await broker.runMirror(
            id: record.id,
            trigger: .user,
            currentEnvironment: {
                var environment = SyncEnvironmentSnapshot.permissiveForTesting
                environment.network = .init(kind: .wifi, isExpensive: true)
                environment.transfer.alreadyTransferredTodayBytes = 0
                environment.capturedAt = accountingDate
                return environment
            }
        )

        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .policyDenied)
    }

    func testMirrorRunCapAccountsTheWholePreparedPlanBeforeEitherPayloadCopy() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("run-cap-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 60).write(
            to: external.appendingPathComponent("first.bin"),
            options: .atomic
        )
        try Data(repeating: 0x62, count: 60).write(
            to: external.appendingPathComponent("second.bin"),
            options: .atomic
        )
        let paths = SharedContainerPaths(root: roots.container)
        var policy = SyncPolicy()
        policy.allowExpensive = true
        policy.maxExpensiveRunBytes = 100
        policy.dailyExpensiveBytes = 1_000
        try SyncPolicyStore(url: paths.policy).save(policy)
        let payloadReads = MirrorPayloadReadProbe()
        let baseIO = ControlledMirrorIO.coordinated
        let mirrorIO = ControlledMirrorIO(
            readData: {
                payloadReads.record()
                return try baseIO.readData(at: $0)
            },
            readDataBounded: {
                payloadReads.record()
                return try baseIO.readData(
                    at: $0,
                    exactByteCount: $1,
                    expectedIdentity: $2
                )
            },
            writeDataAtomically: { try baseIO.writeDataAtomically($0, to: $1) },
            createDirectory: { try baseIO.createDirectory(at: $0) },
            copyFileAtomically: {
                try baseIO.copyFileAtomically(from: $0, to: $1, stagingAt: $2)
            },
            removeItem: { try baseIO.removeItem(at: $0) }
        )
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            mirrorIO: mirrorIO,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)

        let status = try await broker.runMirror(
            id: record.id,
            currentEnvironment: {
                var environment = SyncEnvironmentSnapshot.permissiveForTesting
                environment.network = .init(kind: .wifi, isExpensive: true)
                return environment
            }
        )

        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .policyDenied)
        XCTAssertEqual(
            payloadReads.count,
            0,
            "full observation cap denial must precede every provider payload read"
        )
        let managed = roots.managedBase.appendingPathComponent(record.managedRootToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.appendingPathComponent("first.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.appendingPathComponent("second.bin").path))
    }

    func testMirrorExactSettlementCountsEveryProviderPayloadProbeAcrossNoOpRetry() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("exact-accounting-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 30).write(
            to: external.appendingPathComponent("document.bin"),
            options: .atomic
        )
        let accountingDate = Date(timeIntervalSince1970: 1_700_000_000)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() },
            now: { accountingDate }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)
        let environment: ExternalDirectoryAccessBroker.CurrentEnvironment = {
            var value = SyncEnvironmentSnapshot.permissiveForTesting
            value.capturedAt = accountingDate
            return value
        }

        let first = try await broker.runMirror(
            id: record.id,
            currentEnvironment: environment
        )
        let second = try await broker.runMirror(
            id: record.id,
            currentEnvironment: environment
        )

        XCTAssertEqual(first.phase, .succeeded)
        XCTAssertEqual(second.phase, .succeeded)
        let paths = SharedContainerPaths(root: roots.container)
        let document = try SyncPolicyStore(url: paths.policy).loadDocument()
        let ledger = try TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        ).snapshot()
        let receipts = ledger.settledReceipts.filter {
            $0.workKind == .externalMirror && $0.folderID == record.syncBinding.folderID
        }
        XCTAssertEqual(receipts.map(\.chargedBytes).sorted(), [30, 30, 30, 150])
        XCTAssertTrue(receipts.allSatisfy { $0.kind == .exact })
        XCTAssertTrue(receipts.allSatisfy { $0.taskID == $0.runID })
        XCTAssertTrue(ledger.activeReservations.isEmpty)
        XCTAssertEqual(ledger.dayBuckets.reduce(0) { $0 + $1.committedBytes }, 240)
    }

    func testExportAndReplaceReceiptsEqualOnlyActualProviderEvents() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent(
            "export-receipt-provider",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let accountingDate = Date(timeIntervalSince1970: 1_700_000_000)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() },
            now: { accountingDate }
        )
        let record = try await broker.authorize(url: external, requestedMode: .exportOnly)
        try await verifyBinding(record, broker: broker, roots: roots)
        let managed = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.bin")
        try Data("SOURCE!".utf8).write(to: managed, options: .atomic)
        let environment: ExternalDirectoryAccessBroker.CurrentEnvironment = {
            var value = SyncEnvironmentSnapshot.permissiveForTesting
            value.capturedAt = accountingDate
            return value
        }

        let exported = try await broker.runMirror(
            id: record.id,
            currentEnvironment: environment
        )
        XCTAssertEqual(exported.phase, .succeeded)
        try Data("NEW-SOURCE!".utf8).write(to: managed, options: .atomic)
        let replaced = try await broker.runMirror(
            id: record.id,
            currentEnvironment: environment
        )
        XCTAssertEqual(replaced.phase, .succeeded)

        let paths = SharedContainerPaths(root: roots.container)
        let policy = try SyncPolicyStore(url: paths.policy).loadDocument()
        let ledger = try TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: policy.budgetTimeZoneIdentifier
        ).snapshot()
        let receipts = ledger.settledReceipts.filter {
            $0.workKind == .externalMirror
                && $0.folderID == record.syncBinding.folderID
                && $0.chargedBytes > 0
        }.sorted { $0.chargedBytes < $1.chargedBytes }

        // Initial export performs W(S) + 3 incoming reads + installed + final.
        // Replace observes D once, then applies 6*S + 5*D actual events. The
        // unused two incoming and resume events remain grant-only capacity.
        XCTAssertEqual(receipts.map(\.chargedBytes), [7, 42, 101])
        XCTAssertEqual(receipts.map(\.grantedBytes), [7, 63, 141])
        XCTAssertTrue(receipts.allSatisfy { $0.kind == .exact })
        XCTAssertEqual(
            ledger.dayBuckets.reduce(Int64(0)) { $0 + $1.committedBytes },
            150
        )
        XCTAssertTrue(ledger.activeReservations.isEmpty)
    }

    func testStaleExternalReservationKeepsOnlyMatchingPlannedJournalResumable() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("stale-journal-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        let accountingDate = Date(timeIntervalSince1970: 1_700_000_000)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() },
            now: { accountingDate }
        )
        let environment: ExternalDirectoryAccessBroker.CurrentEnvironment = {
            var value = SyncEnvironmentSnapshot.permissiveForTesting
            value.capturedAt = accountingDate
            return value
        }
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)
        let managedRoot = roots.managedBase.appendingPathComponent(record.managedRootToken)
        let mirror = ControlledMirror(
            managedRoot: managedRoot,
            externalRoot: external,
            mode: .importOnly
        )
        let observation = try await mirror.prepareSynchronization()
        let observed = try await mirror.observeSynchronization(observation, meter: .unmetered)
        let apply = try await mirror.commitObservedPlan(observed)
        let paths = SharedContainerPaths(root: roots.container)
        let policy = try SyncPolicyStore(url: paths.policy).loadDocument()
        let store = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: policy.budgetTimeZoneIdentifier
        )
        let context = try FolderIncarnationStore(url: paths.folderIncarnations)
            .policyContext(for: record.syncBinding.folderID)
        let staleOwner = UUID()
        let staleBinding = TransferAccountingGrantBinding(
            workKind: .externalMirror,
            folderID: context.folderID,
            folderIncarnationDigest: context.folderIncarnationDigest,
            taskID: apply.runID,
            runID: apply.runID,
            sessionID: UUID(),
            planDigest: apply.planDigest
        )
        let staleReservation = try store.reserve(
            ownerID: staleOwner,
            binding: staleBinding,
            grantBytes: apply.remainingLogicalProviderBytes,
            globalDailyLimitBytes: nil,
            folderDailyLimitBytes: nil,
            expiresAt: accountingDate.addingTimeInterval(600),
            at: accountingDate
        )
        _ = try store.begin(
            reservationID: staleReservation.id,
            ownerID: staleOwner,
            binding: staleBinding,
            at: accountingDate
        )

        let resumed = try await broker.runMirror(
            id: record.id,
            currentEnvironment: environment
        )
        XCTAssertEqual(resumed.phase, .succeeded)
        var ledger = try store.snapshot()
        XCTAssertEqual(
            ledger.settledReceipts.first { $0.id == staleReservation.id }?.kind,
            .staleOwnerFullGrant
        )
        XCTAssertNotNil(
            ledger.runUsages.first {
                $0.runID == apply.runID && $0.planDigest == apply.planDigest
            }?.finishedAt
        )

        let orphanRunID = UUID()
        let orphanBinding = TransferAccountingGrantBinding(
            workKind: .externalMirror,
            folderID: context.folderID,
            folderIncarnationDigest: context.folderIncarnationDigest,
            taskID: orphanRunID,
            runID: orphanRunID,
            sessionID: UUID(),
            planDigest: String(repeating: "f", count: 64)
        )
        let orphanReservation = try store.reserve(
            ownerID: UUID(),
            binding: orphanBinding,
            grantBytes: 0,
            globalDailyLimitBytes: nil,
            folderDailyLimitBytes: nil,
            expiresAt: accountingDate.addingTimeInterval(600),
            at: accountingDate
        )
        _ = try store.begin(
            reservationID: orphanReservation.id,
            ownerID: orphanReservation.ownerID,
            binding: orphanBinding,
            at: accountingDate
        )
        let afterOrphan = try await broker.runMirror(
            id: record.id,
            currentEnvironment: environment
        )
        XCTAssertEqual(afterOrphan.phase, .succeeded)
        ledger = try store.snapshot()
        XCTAssertEqual(
            ledger.settledReceipts.first { $0.id == orphanReservation.id }?.kind,
            .staleOwnerFullGrant
        )
        XCTAssertNotNil(
            ledger.runUsages.first {
                $0.runID == orphanRunID && $0.planDigest == orphanBinding.planDigest
            }?.finishedAt
        )
    }

    func testMirrorPolicyTightenAfterFirstPayloadSettlesOnlyExactCompletedBytes() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("tighten-accounting-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        for name in ["first.bin", "second.bin"] {
            try Data(repeating: 0x61, count: 40).write(
                to: external.appendingPathComponent(name),
                options: .atomic
            )
        }
        let paths = SharedContainerPaths(root: roots.container)
        var initialPolicy = SyncPolicy()
        initialPolicy.allowExpensive = true
        initialPolicy.maxExpensiveRunBytes = 1_000
        initialPolicy.dailyExpensiveBytes = 1_000
        try SyncPolicyStore(url: paths.policy).save(initialPolicy)
        let policyToTighten = initialPolicy
        let checkpoint = MirrorJournalWriteCheckpoint(trigger: .firstCompletedOperation) {
            var tightened = policyToTighten
            tightened.maxExpensiveRunBytes = 40
            try SyncPolicyStore(url: paths.policy).save(tightened)
        }
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            mirrorIO: checkpoint.io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)

        let status = try await broker.runMirror(
            id: record.id,
            currentEnvironment: {
                var value = SyncEnvironmentSnapshot.permissiveForTesting
                value.network = .init(kind: .wifi, isExpensive: true)
                return value
            }
        )

        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .policyDenied)
        let managed = roots.managedBase.appendingPathComponent(record.managedRootToken)
        let copiedCount = ["first.bin", "second.bin"].filter {
            FileManager.default.fileExists(atPath: managed.appendingPathComponent($0).path)
        }.count
        XCTAssertEqual(copiedCount, 1)
        let accountingDocument = try SyncPolicyStore(url: paths.policy).loadDocument()
        let ledger = try TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: accountingDocument.budgetTimeZoneIdentifier
        ).snapshot()
        let receipt = try XCTUnwrap(
            ledger.settledReceipts.last(where: { $0.workKind == .externalMirror })
        )
        XCTAssertEqual(receipt.kind, .exact)
        XCTAssertEqual(receipt.grantedBytes, 400)
        XCTAssertEqual(receipt.chargedBytes, 160)
    }

    func testMirrorCancellationAfterFirstPayloadSettlesExactKnownBytes() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("cancel-accounting-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        for name in ["first.bin", "second.bin"] {
            try Data(repeating: 0x61, count: 25).write(
                to: external.appendingPathComponent(name),
                options: .atomic
            )
        }
        let cancellation = ExternalDirectoryMirrorCancellation()
        let checkpoint = MirrorJournalWriteCheckpoint(trigger: .firstCompletedOperation) {
            cancellation.cancel()
        }
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            mirrorIO: checkpoint.io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)

        let status = try await broker.runMirror(id: record.id, cancellation: cancellation)

        XCTAssertEqual(status.phase, .cancelled)
        let paths = SharedContainerPaths(root: roots.container)
        let document = try SyncPolicyStore(url: paths.policy).loadDocument()
        let ledger = try TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        ).snapshot()
        let receipt = try XCTUnwrap(
            ledger.settledReceipts.last(where: { $0.workKind == .externalMirror })
        )
        XCTAssertEqual(receipt.kind, .exact)
        XCTAssertEqual(receipt.grantedBytes, 250)
        XCTAssertEqual(receipt.chargedBytes, 100)
    }

    func testMirrorFolderReaddAfterFirstPayloadFencesOldIncarnationAndSettlesExactBytes() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("readd-accounting-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        for name in ["first.bin", "second.bin"] {
            try Data(repeating: 0x61, count: 20).write(
                to: external.appendingPathComponent(name),
                options: .atomic
            )
        }
        let paths = SharedContainerPaths(root: roots.container)
        let brokerWithoutHook = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await brokerWithoutHook.authorize(
            url: external,
            requestedMode: .importOnly
        )
        try await verifyBinding(record, broker: brokerWithoutHook, roots: roots)
        let incarnations = FolderIncarnationStore(url: paths.folderIncarnations)
        let original = try incarnations.policyContext(for: record.syncBinding.folderID)
        let checkpoint = MirrorJournalWriteCheckpoint(trigger: .firstCompletedOperation) {
            guard
                try incarnations.removeAfterSuccessfulDeletion(
                    folderID: original.folderID,
                    expectedFolderIncarnationDigest: original.folderIncarnationDigest
                )
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            _ = try incarnations.recordSuccessfulCreation(
                folderID: original.folderID,
                commandID: UUID()
            )
        }
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            mirrorIO: checkpoint.io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        try await broker.load()

        let status = try await broker.runMirror(id: record.id)

        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .policyDenied)
        let document = try SyncPolicyStore(url: paths.policy).loadDocument()
        let ledger = try TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        ).snapshot()
        let receipt = try XCTUnwrap(
            ledger.settledReceipts.last(where: { $0.workKind == .externalMirror })
        )
        XCTAssertEqual(receipt.folderIncarnationDigest, original.folderIncarnationDigest)
        XCTAssertEqual(receipt.kind, .exact)
        XCTAssertEqual(receipt.chargedBytes, 80)
    }

    func testMirrorBudgetDayRolloverAfterFirstPayloadSettlesExactAndRequiresRetry() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("rollover-accounting-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        for name in ["first.bin", "second.bin"] {
            try Data(repeating: 0x61, count: 15).write(
                to: external.appendingPathComponent(name),
                options: .atomic
            )
        }
        let firstDay = Date(timeIntervalSince1970: 1_700_000_000)
        let environment = MutableCapturedEnvironmentHarness(capturedAt: firstDay)
        let checkpoint = MirrorJournalWriteCheckpoint(trigger: .firstCompletedOperation) {
            environment.capturedAt = firstDay.addingTimeInterval(24 * 60 * 60)
        }
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            mirrorIO: checkpoint.io,
            capabilityProbe: { _ in Self.fullCapabilities() },
            now: { firstDay }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)

        let status = try await broker.runMirror(
            id: record.id,
            currentEnvironment: { await environment.capture() }
        )

        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .policyDenied)
        let paths = SharedContainerPaths(root: roots.container)
        let document = try SyncPolicyStore(url: paths.policy).loadDocument()
        let ledger = try TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        ).snapshot()
        let receipt = try XCTUnwrap(
            ledger.settledReceipts.last(where: { $0.workKind == .externalMirror })
        )
        XCTAssertEqual(receipt.kind, .exact)
        XCTAssertEqual(receipt.chargedBytes, 60)
    }

    func testMirrorSettlementWriteFailureNeverReportsSuccess() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("settlement-failure-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        let paths = SharedContainerPaths(root: roots.container)
        let checkpoint = MirrorJournalWriteCheckpoint(trigger: .committed) {
            try Data("{".utf8).write(to: paths.transferAccounting, options: .atomic)
        }
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            mirrorIO: checkpoint.io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)

        let status = try await broker.runMirror(id: record.id)

        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .mirrorIOFailure)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: roots.managedBase
                    .appendingPathComponent(record.managedRootToken)
                    .appendingPathComponent("document.txt").path
            ),
            "payload commit may precede settlement, but success must not"
        )
    }

    func testMirrorReloadsPolicyAndLiveEnvironmentBeforeAtomicCopyCommit() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("live-policy-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        var initialPolicy = SyncPolicy()
        initialPolicy.cellularAccess = .allowed
        let policyURL = SharedContainerPaths(root: roots.container).policy
        try SyncPolicyStore(url: policyURL).save(initialPolicy)
        let environment = LiveEnvironmentHarness(network: .init(kind: .wifi))
        let copyGate = MirrorCopyGate()
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            mirrorIO: copyGate.io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)
        let managed = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.txt")

        let run = Task {
            try await broker.runMirror(
                id: record.id,
                trigger: .user,
                currentEnvironment: { await environment.capture() }
            )
        }
        defer {
            copyGate.release()
            run.cancel()
        }
        XCTAssertTrue(copyGate.waitUntilBlocked(timeout: 5))
        environment.network = .init(kind: .cellular)
        var tightenedPolicy = initialPolicy
        tightenedPolicy.cellularAccess = .denied
        try SyncPolicyStore(url: policyURL).save(tightenedPolicy)
        copyGate.release()

        let status = try await run.value
        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .policyDenied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        XCTAssertGreaterThanOrEqual(environment.captureCount, 2)
    }

    func testDeletionConfirmationUsesLivePolicyAndRequiresExplicitOverride() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("deletion-policy-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalFile = external.appendingPathComponent("document.txt")
        try Data("payload".utf8).write(to: externalFile, options: .atomic)
        let environment = LiveEnvironmentHarness(network: .init(kind: .wifi))
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        try await verifyBinding(record, broker: broker, roots: roots)
        _ = try await broker.runMirror(
            id: record.id,
            trigger: .user,
            currentEnvironment: { await environment.capture() }
        )
        let managed = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.txt")
        try FileManager.default.removeItem(at: managed)
        _ = try await broker.runMirror(
            id: record.id,
            trigger: .user,
            currentEnvironment: { await environment.capture() }
        )
        let pendingRecords = await broker.allRecords()
        let pendingRecord = try XCTUnwrap(pendingRecords.first)
        let confirmation = try XCTUnwrap(pendingRecord.pendingDeletionConfirmations.first)
        XCTAssertEqual(confirmation.kind, .deleteExternal)

        environment.network = .init(kind: .cellular)
        do {
            _ = try await broker.resolveDeletionConfirmation(
                recordID: record.id,
                confirmation: confirmation,
                decision: .propagateDeletion,
                trigger: .user,
                currentEnvironment: { await environment.capture() }
            )
            XCTFail("a newly denied policy must fence the delete commit")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .policyDenied)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path))

        let resolved = try await broker.resolveDeletionConfirmation(
            recordID: record.id,
            confirmation: confirmation,
            decision: .propagateDeletion,
            trigger: .user,
            requestedTemporaryOverride: true,
            currentEnvironment: { await environment.capture() }
        )
        XCTAssertEqual(resolved.phase, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalFile.path))
    }

    func testRecoveryBrokerListsRedactedSummariesAndRequiresExplicitDisposal() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("recovery-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalFile = external.appendingPathComponent("private/document.txt")
        try FileManager.default.createDirectory(
            at: externalFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("original bytes".utf8).write(to: externalFile, options: .atomic)
        let harness = BookmarkHarness()
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        try await verifyBinding(record, broker: broker, roots: roots)
        _ = try await broker.runMirror(id: record.id)
        let managedFile = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("private/document.txt")
        try Data("replacement bytes".utf8).write(to: managedFile, options: .atomic)
        _ = try await broker.runMirror(id: record.id)
        let paths = SharedContainerPaths(root: roots.container)
        let policy = try SyncPolicyStore(url: paths.policy).loadDocument()
        let accounting = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: policy.budgetTimeZoneIdentifier
        )
        var knownReceiptIDs = Set(try accounting.snapshot().settledReceipts.map(\.id))

        let summaries = try await broker.recoverySummaries(recordID: record.id)
        XCTAssertEqual(summaries.count, 1)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.relativePath, "private/document.txt")
        XCTAssertEqual(summary.kind, .copyBackup)
        XCTAssertEqual(summary.status, .retainedRequiresUserConfirmation)
        XCTAssertEqual(summary.byteCount, Int64(Data("original bytes".utf8).count))
        XCTAssertFalse(summary.contentDigest.isEmpty)
        let encodedSummary = try XCTUnwrap(
            String(
                data: JSONEncoder().encode(summary),
                encoding: .utf8
            ))
        XCTAssertFalse(encodedSummary.contains(external.path))
        XCTAssertFalse(encodedSummary.contains(roots.managedBase.path))
        let summariesReceipt = try XCTUnwrap(
            try accounting.snapshot().settledReceipts.first {
                !knownReceiptIDs.contains($0.id)
            }
        )
        XCTAssertEqual(summariesReceipt.kind, .exact)
        XCTAssertEqual(summariesReceipt.grantedBytes, summary.byteCount)
        XCTAssertEqual(summariesReceipt.chargedBytes, summary.byteCount)
        knownReceiptIDs.insert(summariesReceipt.id)

        let exportDirectory = roots.container.appendingPathComponent(
            "recovery-exports",
            isDirectory: true
        )
        let export = try await broker.prepareRecoveryExport(
            recordID: record.id,
            summary: summary,
            outputDirectory: exportDirectory
        )
        XCTAssertEqual(export.payloadKind, .file)
        XCTAssertEqual(try Data(contentsOf: export.url), Data("original bytes".utf8))
        XCTAssertFalse(export.url.path.contains(external.path))
        XCTAssertFalse(export.url.path.contains(roots.managedBase.path))
        let exportReceipt = try XCTUnwrap(
            try accounting.snapshot().settledReceipts.first {
                !knownReceiptIDs.contains($0.id)
            }
        )
        XCTAssertEqual(exportReceipt.kind, .exact)
        XCTAssertEqual(exportReceipt.grantedBytes, summary.byteCount * 2)
        XCTAssertEqual(exportReceipt.chargedBytes, summary.byteCount * 2)
        knownReceiptIDs.insert(exportReceipt.id)
        try broker.discardRecoveryExport(export, from: exportDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.url.path))
        let summariesAfterExport = try await broker.recoverySummaries(recordID: record.id)
        XCTAssertEqual(
            summariesAfterExport,
            [summary],
            "sharing a snapshot must not mutate or resolve the retained recovery item"
        )
        knownReceiptIDs = Set(try accounting.snapshot().settledReceipts.map(\.id))

        try await broker.resolveRecovery(
            recordID: record.id,
            summary: summary,
            decision: .retain
        )
        let retainReceipt = try XCTUnwrap(
            try accounting.snapshot().settledReceipts.first {
                !knownReceiptIDs.contains($0.id)
            }
        )
        XCTAssertEqual(retainReceipt.kind, .exact)
        XCTAssertEqual(retainReceipt.grantedBytes, summary.byteCount)
        XCTAssertEqual(retainReceipt.chargedBytes, summary.byteCount)
        knownReceiptIDs.insert(retainReceipt.id)
        let summariesAfterRetain = try await broker.recoverySummaries(recordID: record.id)
        XCTAssertEqual(summariesAfterRetain, [summary])
        knownReceiptIDs = Set(try accounting.snapshot().settledReceipts.map(\.id))

        try await broker.resolveRecovery(
            recordID: record.id,
            summary: summary,
            decision: .deleteAfterUserConfirmation
        )
        let disposalReceipt = try XCTUnwrap(
            try accounting.snapshot().settledReceipts.first {
                !knownReceiptIDs.contains($0.id)
            }
        )
        XCTAssertEqual(disposalReceipt.kind, .exact)
        XCTAssertEqual(disposalReceipt.grantedBytes, summary.byteCount * 4)
        XCTAssertEqual(disposalReceipt.chargedBytes, summary.byteCount * 4)
        let summariesAfterDisposal = try await broker.recoverySummaries(recordID: record.id)
        XCTAssertTrue(summariesAfterDisposal.isEmpty)
        XCTAssertEqual(harness.beginCount, harness.endCount)
    }

    func testRecoveryDisposalFailsClosedForLivePolicyStaleBookmarkAndCancellation() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("recovery-fences-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalFile = external.appendingPathComponent("document.txt")
        try Data("original".utf8).write(to: externalFile, options: .atomic)
        let harness = BookmarkHarness()
        let environment = LiveEnvironmentHarness(network: .init(kind: .wifi))
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        try await verifyBinding(record, broker: broker, roots: roots)
        _ = try await broker.runMirror(id: record.id)
        let managedFile = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.txt")
        try Data("replacement".utf8).write(to: managedFile, options: .atomic)
        _ = try await broker.runMirror(id: record.id)
        let summaries = try await broker.recoverySummaries(recordID: record.id)
        XCTAssertEqual(summaries.count, 1)
        let summary = try XCTUnwrap(summaries.first)

        environment.network = .init(kind: .cellular)
        do {
            try await broker.resolveRecovery(
                recordID: record.id,
                summary: summary,
                decision: .deleteAfterUserConfirmation,
                currentEnvironment: { await environment.capture() }
            )
            XCTFail("recovery disposal must obey the live policy")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .policyDenied)
        }
        let summariesAfterDenial = try await broker.recoverySummaries(recordID: record.id)
        XCTAssertEqual(summariesAfterDenial, [summary])

        harness.isStale = true
        do {
            _ = try await broker.recoverySummaries(recordID: record.id)
            XCTFail("a stale bookmark must not expose recovery state")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .bookmarkStale)
        }
        harness.isStale = false

        let cancellation = ExternalDirectoryMirrorCancellation()
        cancellation.cancel()
        do {
            try await broker.resolveRecovery(
                recordID: record.id,
                summary: summary,
                decision: .deleteAfterUserConfirmation,
                cancellation: cancellation,
                requestedTemporaryOverride: true,
                currentEnvironment: { await environment.capture() }
            )
            XCTFail("a cancelled recovery operation must retain its payload")
        } catch is CancellationError {}
        let summariesAfterCancellation = try await broker.recoverySummaries(recordID: record.id)
        XCTAssertEqual(summariesAfterCancellation, [summary])

        try await broker.remove(id: record.id)
        do {
            _ = try await broker.recoverySummaries(recordID: record.id)
            XCTFail("revoked authorization must fail closed even for App-owned recovery metadata")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .authorizationAlreadyRevoked)
        }
    }

    func testExternalRecoveryHashRequiresFreshDownloadPolicyBeforeReadingPayload() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("recovery-download-policy", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("original external bytes".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        let probe = RecoveryPayloadReadProbe()
        let base = ControlledMirrorIO.coordinated
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            beforeRecoveryPayloadRead: { side, kind, byteCount in
                probe.record(side: side, kind: kind, byteCount: byteCount)
            }
        )
        let environment = LiveEnvironmentHarness(network: .init(kind: .wifi))
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            mirrorIO: io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        try await verifyBinding(record, broker: broker, roots: roots)
        _ = try await broker.runMirror(
            id: record.id,
            currentEnvironment: { await environment.capture() }
        )
        let managed = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.txt")
        try Data("replacement managed bytes".utf8).write(to: managed, options: .atomic)
        _ = try await broker.runMirror(
            id: record.id,
            currentEnvironment: { await environment.capture() }
        )

        probe.reset()
        environment.network = .init(kind: .cellular)
        do {
            _ = try await broker.recoverySummaries(
                recordID: record.id,
                currentEnvironment: { await environment.capture() }
            )
            XCTFail("external recovery hashing must require the live download policy")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .policyDenied)
        }
        XCTAssertEqual(probe.readCount, 0, "denied download policy must fence before payload bytes")

        let recoveryBytes = Int64(Data("original external bytes".utf8).count)
        let paths = SharedContainerPaths(root: roots.container)
        var capped = SyncPolicy()
        capped.allowExpensive = true
        capped.maxExpensiveRunBytes = recoveryBytes - 1
        capped.dailyExpensiveBytes = 1_000
        try SyncPolicyStore(url: paths.policy).save(capped)
        environment.network = .init(kind: .wifi, isExpensive: true)
        probe.reset()
        do {
            _ = try await broker.recoverySummaries(
                recordID: record.id,
                currentEnvironment: { await environment.capture() }
            )
            XCTFail("a finite recovery plan must reserve its full provider-read bound")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .policyDenied)
        }
        XCTAssertEqual(probe.readCount, 0, "cap denial must precede provider payload reads")
        let cappedDocument = try SyncPolicyStore(url: paths.policy).loadDocument()
        let cappedLedger = try TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: cappedDocument.budgetTimeZoneIdentifier
        ).snapshot()
        XCTAssertTrue(cappedLedger.activeReservations.isEmpty)

        capped.maxExpensiveRunBytes = 1_000
        try SyncPolicyStore(url: paths.policy).save(capped)
        environment.network = .init(kind: .wifi)
        let summaries = try await broker.recoverySummaries(
            recordID: record.id,
            currentEnvironment: { await environment.capture() }
        )
        XCTAssertEqual(summaries.count, 1)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.side, .external)
        XCTAssertEqual(summary.payloadKind, .file)
        XCTAssertEqual(summary.byteCount, recoveryBytes)
        XCTAssertGreaterThan(probe.readCount, 0)
        XCTAssertEqual(probe.lastByteCount, summary.byteCount)
    }

    func testExternalRecoveryOpaquePostReadFailuresFinishRunsConservatively() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent(
            "recovery-opaque-provider",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let original = Data("original bytes".utf8)
        try original.write(to: external.appendingPathComponent("document.txt"), options: .atomic)
        let failure = ArmableRecoveryReadFailure()
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
            afterRecoveryPayloadRead: { side, _, _ in
                if side == .external { try failure.failIfArmed() }
            }
        )
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            mirrorIO: io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        try await verifyBinding(record, broker: broker, roots: roots)
        _ = try await broker.runMirror(id: record.id)
        let managed = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.txt")
        try Data("replacement bytes".utf8).write(to: managed, options: .atomic)
        _ = try await broker.runMirror(id: record.id)
        let paths = SharedContainerPaths(root: roots.container)
        let document = try SyncPolicyStore(url: paths.policy).loadDocument()
        let accounting = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        )
        let knownReceiptIDs = Set(try accounting.snapshot().settledReceipts.map(\.id))

        failure.arm()
        do {
            _ = try await broker.recoverySummaries(recordID: record.id)
            XCTFail("an opaque post-read failure must not return recovery metadata")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .recoveryChanged)
        }
        let ledger = try accounting.snapshot()
        let receipt = try XCTUnwrap(
            ledger.settledReceipts.first {
                !knownReceiptIDs.contains($0.id)
            }
        )
        XCTAssertEqual(receipt.kind, .terminalFailureConservative)
        XCTAssertEqual(receipt.grantedBytes, Int64(original.count))
        XCTAssertEqual(receipt.chargedBytes, Int64(original.count))
        XCTAssertTrue(ledger.activeReservations.isEmpty)
        XCTAssertTrue(ledger.pendingHistoryProjections.contains { $0.id == receipt.id })
        XCTAssertNotNil(
            ledger.runUsages.first {
                $0.runID == receipt.runID && $0.planDigest == receipt.planDigest
            }?.finishedAt
        )

        let recoverySummaries = try await broker.recoverySummaries(recordID: record.id)
        let summary = try XCTUnwrap(recoverySummaries.first)
        let knownResolutionReceiptIDs = Set(
            try accounting.snapshot().settledReceipts.map(\.id)
        )
        failure.arm()
        do {
            try await broker.resolveRecovery(
                recordID: record.id,
                summary: summary,
                decision: .deleteAfterUserConfirmation
            )
            XCTFail("an opaque post-read failure must not dispose the recovery payload")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .recoveryUnavailable)
        }
        let resolutionLedger = try accounting.snapshot()
        let resolutionReceipt = try XCTUnwrap(
            resolutionLedger.settledReceipts.first {
                !knownResolutionReceiptIDs.contains($0.id)
            }
        )
        XCTAssertEqual(resolutionReceipt.kind, .terminalFailureConservative)
        XCTAssertEqual(resolutionReceipt.grantedBytes, Int64(original.count) * 4)
        XCTAssertEqual(resolutionReceipt.chargedBytes, Int64(original.count) * 4)
        XCTAssertTrue(resolutionLedger.activeReservations.isEmpty)
        XCTAssertTrue(
            resolutionLedger.pendingHistoryProjections.contains {
                $0.id == resolutionReceipt.id
            }
        )
        XCTAssertNotNil(
            resolutionLedger.runUsages.first {
                $0.runID == resolutionReceipt.runID
                    && $0.planDigest == resolutionReceipt.planDigest
            }?.finishedAt
        )
    }

    func testExternalRecoverySettlementFailureNeverReturnsSuccess() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent(
            "recovery-settlement-provider",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("original bytes".utf8).write(
            to: external.appendingPathComponent("document.txt"),
            options: .atomic
        )
        let paths = SharedContainerPaths(root: roots.container)
        let clock = ArmableAccountingCorruptingClock(accountingURL: paths.transferAccounting)
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            capabilityProbe: { _ in Self.fullCapabilities() },
            now: { clock.capture() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        try await verifyBinding(record, broker: broker, roots: roots)
        _ = try await broker.runMirror(id: record.id)
        let managed = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("document.txt")
        try Data("replacement bytes".utf8).write(to: managed, options: .atomic)
        _ = try await broker.runMirror(id: record.id)

        clock.arm()
        do {
            _ = try await broker.recoverySummaries(recordID: record.id)
            XCTFail("settlement failure must prevent a successful recovery response")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .recoveryUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: paths.transferAccounting), Data("{".utf8))
    }

    func testExternalDirectoryRecoveryHashFailsClosedWithoutBoundedTransferSize() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("recovery-directory-policy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: external.appendingPathComponent("empty-directory", isDirectory: true),
            withIntermediateDirectories: true
        )
        let probe = RecoveryPayloadReadProbe()
        let base = ControlledMirrorIO.coordinated
        let io = ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2) },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { _, _, _ in },
            beforeRecoveryPayloadRead: { side, kind, byteCount in
                probe.record(side: side, kind: kind, byteCount: byteCount)
            }
        )
        let environment = LiveEnvironmentHarness(network: .init(kind: .wifi))
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            commandQueueURL: roots.commands,
            bookmarkAccess: BookmarkHarness().access,
            mirrorIO: io,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .controlledMirror)
        try await verifyBinding(record, broker: broker, roots: roots)
        _ = try await broker.runMirror(
            id: record.id,
            currentEnvironment: { await environment.capture() }
        )
        let managedDirectory = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("empty-directory", isDirectory: true)
        try FileManager.default.removeItem(at: managedDirectory)
        _ = try await broker.runMirror(
            id: record.id,
            currentEnvironment: { await environment.capture() }
        )
        let pendingRecords = await broker.allRecords()
        XCTAssertEqual(pendingRecords.count, 1)
        let pending = try XCTUnwrap(pendingRecords.first)
        XCTAssertEqual(pending.pendingDeletionConfirmations.count, 1)
        let confirmation = try XCTUnwrap(pending.pendingDeletionConfirmations.first)
        _ = try await broker.resolveDeletionConfirmation(
            recordID: record.id,
            confirmation: confirmation,
            decision: .propagateDeletion,
            currentEnvironment: { await environment.capture() }
        )
        let paths = SharedContainerPaths(root: roots.container)
        let document = try SyncPolicyStore(url: paths.policy).loadDocument()
        let accounting = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        )
        let receiptIDsBeforeRecovery = Set(
            try accounting.snapshot().settledReceipts.map(\.id)
        )

        probe.reset()
        do {
            _ = try await broker.recoverySummaries(
                recordID: record.id,
                currentEnvironment: { await environment.capture() }
            )
            XCTFail("an external directory payload has no bounded transfer size and must fail closed")
        } catch let error as ExternalDirectoryError {
            XCTAssertEqual(error, .policyDenied)
        }
        XCTAssertEqual(probe.readCount, 0)
        let ledgerAfterRecovery = try accounting.snapshot()
        XCTAssertTrue(ledgerAfterRecovery.activeReservations.isEmpty)
        XCTAssertEqual(
            Set(ledgerAfterRecovery.settledReceipts.map(\.id)),
            receiptIDsBeforeRecovery,
            "an unbounded payload must fail before reserve/begin"
        )
    }

    func testPrecancelledMirrorDoesNotTouchProviderContent() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("cancel-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: external.appendingPathComponent("cancel.txt"), options: .atomic)
        let harness = BookmarkHarness()
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        let authorizationScopeCount = harness.beginCount
        try await verifyBinding(record, broker: broker, roots: roots)
        let cancellation = ExternalDirectoryMirrorCancellation()
        cancellation.cancel()

        let status = try await broker.runMirror(id: record.id, cancellation: cancellation)
        XCTAssertEqual(status.phase, .cancelled)
        XCTAssertEqual(status.failureCode, .cancelled)
        let managedFile = roots.managedBase
            .appendingPathComponent(record.managedRootToken)
            .appendingPathComponent("cancel.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedFile.path))
        XCTAssertEqual(
            harness.beginCount,
            authorizationScopeCount,
            "a precancelled run must not acquire another provider scope"
        )
        XCTAssertEqual(harness.endCount, harness.beginCount)
    }

    func testRevokedStaleAndOfflineBookmarksReturnStableRetryableStatuses() async throws {
        let roots = try makeRoots()
        let external = roots.container.appendingPathComponent("revoked-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let harness = BookmarkHarness()
        let broker = ExternalDirectoryAccessBroker(
            recordsURL: roots.records,
            managedRootsURL: roots.managedBase,
            bookmarkAccess: harness.access,
            capabilityProbe: { _ in Self.fullCapabilities() }
        )
        let record = try await broker.authorize(url: external, requestedMode: .importOnly)
        try await verifyBinding(record, broker: broker, roots: roots)

        harness.allowAccess = false
        var status = try await broker.runMirror(id: record.id)
        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .authorizationRevoked)

        harness.allowAccess = true
        harness.isStale = true
        status = try await broker.runMirror(id: record.id)
        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .bookmarkStale)

        harness.isStale = false
        harness.isOffline = true
        status = try await broker.runMirror(id: record.id)
        XCTAssertEqual(status.phase, .retryableFailure)
        XCTAssertEqual(status.failureCode, .providerOffline)

        let reloadedRecords = await broker.allRecords()
        let reloaded = try XCTUnwrap(reloadedRecords.first)
        XCTAssertEqual(reloaded.lastMirrorStatus.failureCode, .providerOffline)
        let persisted = try String(contentsOf: roots.records, encoding: .utf8)
        XCTAssertFalse(persisted.contains("provider-secret-localized-error"))
        XCTAssertFalse(persisted.contains(external.path))
    }

    private func makeRoots() throws -> (
        container: URL,
        records: URL,
        managedBase: URL,
        commands: URL,
        snapshot: URL
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalDirectoryBrokerTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let records = container.appendingPathComponent("Metadata/external-directories.json")
        let managedBase = container.appendingPathComponent("ManagedFolders/External", isDirectory: true)
        let commands = container.appendingPathComponent("Coordination/Commands", isDirectory: true)
        let snapshot = container.appendingPathComponent("Metadata/core-snapshot.json")
        try FileManager.default.createDirectory(
            at: records.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedBase, withIntermediateDirectories: true)
        try SharedSnapshotStore(snapshotURL: snapshot).write(
            CoreSnapshot(configurationRevision: Self.configurationRevision)
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return (container, records, managedBase, commands, snapshot)
    }

    private static func fullCapabilities() -> ExternalDirectoryCapabilities {
        ExternalDirectoryCapabilities(
            canEnumerate: true,
            canRead: true,
            canCreate: true,
            canWrite: true,
            canAtomicallyReplace: true,
            canRename: true,
            canDelete: true,
            canAccessRecursively: true,
            cleanupSucceeded: true,
            recommendedMode: .direct
        )
    }

    private func verifyBinding(
        _ record: ExternalDirectoryRecord,
        broker: ExternalDirectoryAccessBroker,
        roots: (
            container: URL,
            records: URL,
            managedBase: URL,
            commands: URL,
            snapshot: URL
        )
    ) async throws {
        let snapshot = authoritativeSnapshot(for: record, roots: roots, generation: 1)
        try SharedSnapshotStore(snapshotURL: roots.snapshot).write(snapshot)
        _ = try FolderIncarnationStore(
            url: SharedContainerPaths(root: roots.container).folderIncarnations
        ).ensureLegacyConfiguredFolders([record.syncBinding.folderID])
        _ = try await broker.reconcileSyncBindings(snapshot: snapshot)
    }

    private func authoritativeSnapshot(
        for record: ExternalDirectoryRecord,
        roots: (
            container: URL,
            records: URL,
            managedBase: URL,
            commands: URL,
            snapshot: URL
        ),
        generation: UInt64,
        deviceIDs: [DeviceID] = []
    ) -> CoreSnapshot {
        CoreSnapshot(
            generation: generation,
            configurationRevision: Self.configurationRevision,
            folders: [
                FolderRecord(
                    id: record.syncBinding.folderID,
                    label: "External",
                    localPath: roots.managedBase.appendingPathComponent(record.managedRootToken).path,
                    deviceIDs: deviceIDs
                )
            ]
        )
    }

    private func isContained(_ child: URL, by parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        return childComponents.count > parentComponents.count
            && Array(childComponents.prefix(parentComponents.count)) == parentComponents
    }
}

private struct LegacyExternalDirectoryRecord: Encodable {
    let id: UUID
    let displayName: String
    let bookmark: Data
    let mode: ExternalDirectoryMode
    let capabilities: ExternalDirectoryCapabilities
    let lastResolvedPath: String
    let lastProbedAt: Date
}

private struct LegacyFolderRecord: Encodable {
    let id: FolderID
    let label: String
    let localPath: String
    let type: FolderType
    let selectionMode: ContentSelectionMode
    let isPaused: Bool
    let pendingUploadBytes: Int64
    let pendingDownloadBytes: Int64
    let error: String?
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}

private final class RecoveryPayloadReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(ControlledMirrorSide, ControlledMirrorRecoveryPayloadKind, Int64?)] = []

    var readCount: Int {
        lock.withLock { records.count }
    }

    var lastByteCount: Int64? {
        lock.withLock { records.last?.2 }
    }

    func record(
        side: ControlledMirrorSide,
        kind: ControlledMirrorRecoveryPayloadKind,
        byteCount: Int64?
    ) {
        lock.withLock { records.append((side, kind, byteCount)) }
    }

    func reset() {
        lock.withLock { records.removeAll() }
    }
}

private final class MirrorPayloadReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func record() {
        lock.withLock { value += 1 }
    }
}

private final class ArmableRecoveryReadFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var fired = false

    func arm() {
        lock.withLock {
            armed = true
            fired = false
        }
    }

    func failIfArmed() throws {
        let shouldFail = lock.withLock {
            guard armed, !fired else { return false }
            fired = true
            return true
        }
        if shouldFail { throw CocoaError(.fileReadUnknown) }
    }
}

private final class ArmableAccountingCorruptingClock: @unchecked Sendable {
    private let accountingURL: URL
    private let lock = NSLock()
    private var armed = false
    private var fired = false
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    init(accountingURL: URL) {
        self.accountingURL = accountingURL
    }

    func arm() {
        lock.withLock { armed = true }
    }

    func capture() -> Date {
        let shouldCorrupt = lock.withLock {
            guard armed, !fired else { return false }
            fired = true
            return true
        }
        if shouldCorrupt {
            try? Data("{".utf8).write(to: accountingURL, options: .atomic)
        }
        return date
    }
}

private final class BookmarkHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _allowAccess = true
    private var _isStale = false
    private var _isOffline = false
    private var _beginCount = 0
    private var _endCount = 0

    var allowAccess: Bool {
        get { withLock { _allowAccess } }
        set { withLock { _allowAccess = newValue } }
    }

    var isStale: Bool {
        get { withLock { _isStale } }
        set { withLock { _isStale = newValue } }
    }

    var isOffline: Bool {
        get { withLock { _isOffline } }
        set { withLock { _isOffline = newValue } }
    }

    var beginCount: Int { withLock { _beginCount } }
    var endCount: Int { withLock { _endCount } }

    var access: ExternalDirectoryBookmarkAccess {
        ExternalDirectoryBookmarkAccess(
            create: { Data($0.path.utf8) },
            resolve: { [self] bookmark in
                if isOffline {
                    throw NSError(
                        domain: "provider-secret-localized-error",
                        code: 17,
                        userInfo: [NSLocalizedDescriptionKey: "provider-secret-localized-error"]
                    )
                }
                guard let path = String(data: bookmark, encoding: .utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return ExternalDirectoryBookmarkResolution(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    isStale: isStale
                )
            },
            beginAccess: { [self] _ in
                withLock {
                    _beginCount += 1
                    return _allowAccess
                }
            },
            endAccess: { [self] _ in
                withLock { _endCount += 1 }
            }
        )
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ProbeCounter: @unchecked Sendable {
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

private final class MirrorCopyGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false

    var io: ControlledMirrorIO {
        let base = ControlledMirrorIO.coordinated
        return ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { try base.writeDataAtomically($0, to: $1) },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: { source, destination, staging in
                try base.copyFileAtomically(from: source, to: destination, stagingAt: staging)
            },
            removeItem: { try base.removeItem(at: $0) },
            beforeAtomicCopyCommit: { [self] _, _, _ in
                condition.lock()
                isBlocked = true
                condition.broadcast()
                while !isReleased {
                    condition.wait()
                }
                condition.unlock()
            }
        )
    }

    func waitUntilBlocked(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isBlocked {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class MirrorJournalWriteCheckpoint: @unchecked Sendable {
    enum Trigger {
        case firstCompletedOperation
        case committed
    }

    private let trigger: Trigger
    private let action: @Sendable () throws -> Void
    private let lock = NSLock()
    private var fired = false

    init(
        trigger: Trigger,
        action: @escaping @Sendable () throws -> Void
    ) {
        self.trigger = trigger
        self.action = action
    }

    var io: ControlledMirrorIO {
        let base = ControlledMirrorIO.coordinated
        return ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { [self] data, url in
                try base.writeDataAtomically(data, to: url)
                try observe(data: data, url: url)
            },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: {
                try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2)
            },
            removeItem: { try base.removeItem(at: $0) }
        )
    }

    private func observe(data: Data, url: URL) throws {
        guard url.lastPathComponent == ControlledMirror.journalFileName,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let phase = object["phase"] as? String
        else {
            return
        }
        let matched: Bool
        switch trigger {
        case .committed:
            matched = phase == "committed"
        case .firstCompletedOperation:
            let operations = object["operations"] as? [[String: Any]] ?? []
            matched =
                phase == "applying"
                && operations.filter { $0["isCompleted"] as? Bool == true }.count == 1
        }
        guard matched else { return }
        let shouldFire = lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
        if shouldFire { try action() }
    }
}

private final class ArmableMirrorJournalFailure: @unchecked Sendable {
    private let trigger: MirrorJournalWriteCheckpoint.Trigger
    private let lock = NSLock()
    private var armed = false
    private var fired = false

    init(trigger: MirrorJournalWriteCheckpoint.Trigger) {
        self.trigger = trigger
    }

    var io: ControlledMirrorIO {
        let base = ControlledMirrorIO.coordinated
        return ControlledMirrorIO(
            readData: { try base.readData(at: $0) },
            writeDataAtomically: { [self] data, url in
                try base.writeDataAtomically(data, to: url)
                try observe(data: data, url: url)
            },
            createDirectory: { try base.createDirectory(at: $0) },
            copyFileAtomically: {
                try base.copyFileAtomically(from: $0, to: $1, stagingAt: $2)
            },
            removeItem: { try base.removeItem(at: $0) }
        )
    }

    func arm() {
        lock.withLock { armed = true }
    }

    private func observe(data: Data, url: URL) throws {
        guard url.lastPathComponent == ControlledMirror.journalFileName,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let phase = object["phase"] as? String
        else {
            return
        }
        let matched: Bool
        switch trigger {
        case .committed:
            matched = phase == "committed"
        case .firstCompletedOperation:
            let operations = object["operations"] as? [[String: Any]] ?? []
            matched =
                phase == "applying"
                && operations.filter { $0["isCompleted"] as? Bool == true }.count == 1
        }
        guard matched else { return }
        let shouldFail = lock.withLock {
            guard armed, !fired else { return false }
            fired = true
            return true
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
    }
}

private final class LiveEnvironmentHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var state: SyncEnvironmentSnapshot
    private var count = 0

    init(network: NetworkState) {
        state = SyncEnvironmentSnapshot(
            network: network,
            power: .init(
                batteryLevel: 1,
                isExternalPowerConnected: true,
                isLowPowerModeEnabled: false,
                thermalLevel: .nominal
            ),
            safety: .init(availableDiskBytes: .max)
        )
    }

    var network: NetworkState {
        get { withLock { state.network } }
        set { withLock { state.network = newValue } }
    }

    var captureCount: Int { withLock { count } }

    func capture() async -> SyncEnvironmentSnapshot {
        withLock {
            count += 1
            state.capturedAt = .now
            return state
        }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class MutableCapturedEnvironmentHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(capturedAt: Date) {
        date = capturedAt
    }

    var capturedAt: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }

    func capture() async -> SyncEnvironmentSnapshot {
        var value = SyncEnvironmentSnapshot.permissiveForTesting
        value.capturedAt = capturedAt
        return value
    }
}

private actor DeferredFirstEnvironmentHarness {
    private var state: SyncEnvironmentSnapshot
    private var firstCaptureContinuation: CheckedContinuation<SyncEnvironmentSnapshot, Never>?
    private var firstCaptureWaiters: [CheckedContinuation<Void, Never>] = []
    private var didReleaseFirstCapture = false
    private(set) var captureCount = 0

    init(network: NetworkState) {
        state = SyncEnvironmentSnapshot(
            network: network,
            power: .init(
                batteryLevel: 1,
                isExternalPowerConnected: true,
                isLowPowerModeEnabled: false,
                thermalLevel: .nominal
            ),
            safety: .init(availableDiskBytes: .max)
        )
    }

    func capture() async -> SyncEnvironmentSnapshot {
        captureCount += 1
        state.capturedAt = .now
        guard !didReleaseFirstCapture else { return state }
        return await withCheckedContinuation { continuation in
            firstCaptureContinuation = continuation
            let waiters = firstCaptureWaiters
            firstCaptureWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilFirstCaptureStarts() async {
        guard firstCaptureContinuation == nil, !didReleaseFirstCapture else { return }
        await withCheckedContinuation { continuation in
            firstCaptureWaiters.append(continuation)
        }
    }

    func releaseFirstCapture() {
        didReleaseFirstCapture = true
        firstCaptureContinuation?.resume(returning: state)
        firstCaptureContinuation = nil
    }
}
