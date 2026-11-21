import Foundation
import XCTest

@testable import PsyCore

final class ForegroundSyncServiceTests: XCTestCase {
    func testDeniedNetworkDoesNotPublishAutomaticCommands() async throws {
        let paths = SharedContainerPaths(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let folder = FolderRecord(
            id: FolderID(rawValue: "share")!, label: "Share", localPath: paths.managedFoldersRoot.path)
        _ = try FolderIncarnationStore(url: paths.folderIncarnations).ensureLegacyConfiguredFolders([folder.id])
        try SharedSnapshotStore(snapshotURL: paths.snapshot).write(
            CoreSnapshot(configurationRevision: String(repeating: "a", count: 64), folders: [folder]))
        var environment = SyncEnvironmentSnapshot.permissiveForTesting
        environment.network.kind = .unavailable
        let captured = environment
        let result = await ForegroundSyncService().runCycle(
            paths: paths, environment: captured, currentEnvironment: { captured })
        guard case .blocked(let reasons) = result.activity else {
            return XCTFail("Expected policy wait, got \(result.activity)")
        }
        XCTAssertTrue(reasons.contains(.networkUnavailable))
        XCTAssertTrue(try CoreCommandQueue(root: paths.commandQueue).pending().isEmpty)
    }

    func testLocalOnlyAndPausedFoldersDoNotOpenCore() async throws {
        let paths = SharedContainerPaths(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let local = FolderRecord(id: FolderID(rawValue: "local")!, label: "Local", localPath: "/unused", deviceIDs: [])
        let paused = FolderRecord(
            id: FolderID(rawValue: "paused")!, label: "Paused", localPath: "/unused", isPaused: true)
        try SharedSnapshotStore(snapshotURL: paths.snapshot).write(
            CoreSnapshot(configurationRevision: String(repeating: "a", count: 64), folders: [local, paused]))
        let result = await ForegroundSyncService().runCycle(
            paths: paths, environment: .permissiveForTesting, currentEnvironment: { .permissiveForTesting })
        // The default runtime has an unavailable client. Waiting proves that
        // this pass did not attempt to initialize the core for these folders.
        XCTAssertEqual(result.activity, .waiting)
        XCTAssertTrue(try CoreCommandQueue(root: paths.commandQueue).pending().isEmpty)
    }
}
