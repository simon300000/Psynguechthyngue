import Foundation
import SQLite3
import XCTest

@testable import PsyCore

final class MetadataIndexProjectionTests: XCTestCase {
    func testProjectionPersistsReadyStatusAndQueryablePages() async throws {
        let root = try temporaryDirectory()
        let paths = SharedContainerPaths(root: root)
        let folder = try XCTUnwrap(FolderID(rawValue: "documents"))
        let items = [
            item(id: "a", folder: folder, path: "A.txt", availability: .remoteOnly),
            item(id: "b", folder: folder, path: "B.txt", availability: .local),
            item(id: "c", folder: folder, path: "C.txt", availability: .remoteOnly, pinned: true),
        ]

        let projector = MetadataIndexProjector(
            databaseURL: paths.metadataIndex,
            statusURL: paths.metadataIndexStatus
        )
        let status = await projector.project(.init(generation: 4, items: items))

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.snapshotGeneration, 4)
        XCTAssertEqual(status.indexedItemCount, 3)
        XCTAssertNil(status.errorCode)
        let persistedStatus = try XCTUnwrap(projector.readStatus())
        XCTAssertEqual(persistedStatus.state, status.state)
        XCTAssertEqual(persistedStatus.snapshotGeneration, status.snapshotGeneration)
        XCTAssertEqual(persistedStatus.indexedItemCount, status.indexedItemCount)
        XCTAssertEqual(persistedStatus.errorCode, status.errorCode)

        let store = try IndexedMetadataStore(
            databaseURL: paths.metadataIndex,
            accessMode: .readOnly,
            recoveryPolicy: .fail
        )
        let first = try await store.allItems(limit: 2)
        let second = try await store.allItems(after: try XCTUnwrap(first.nextCursor), limit: 2)
        let workingSet = try await store.workingSet(limit: 10)
        XCTAssertEqual(first.items.map(\.id), ["a", "b"])
        XCTAssertEqual(second.items.map(\.id), ["c"])
        XCTAssertEqual(workingSet.items.map(\.id), ["a", "b", "c"])
    }

    func testProjectionPersistsOnlyStableFailureCode() async throws {
        let root = try temporaryDirectory()
        let paths = SharedContainerPaths(root: root)
        let projector = MetadataIndexProjector(
            databaseURL: paths.metadataIndex,
            statusURL: paths.metadataIndexStatus
        )

        let status = await projector.project(.init(schemaVersion: 999, generation: 7))

        XCTAssertEqual(status.state, .degraded)
        XCTAssertEqual(status.snapshotGeneration, 7)
        XCTAssertEqual(status.errorCode, "metadataIndexSnapshotSchema")
        let data = try Data(contentsOf: paths.metadataIndexStatus)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(root.path))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("unsupported"))
    }

    func testSQLiteFailureCodesAreCategorizedWithoutPersistingMessages() {
        let cases: [(Int32, String)] = [
            (SQLITE_BUSY, "metadataIndexSQLiteBusy"),
            (SQLITE_LOCKED, "metadataIndexSQLiteLocked"),
            (SQLITE_READONLY, "metadataIndexSQLiteReadOnly"),
            (SQLITE_CANTOPEN, "metadataIndexSQLiteCantOpen"),
            (SQLITE_CORRUPT, "metadataIndexSQLiteCorrupt"),
            (SQLITE_NOTADB, "metadataIndexSQLiteCorrupt"),
            (SQLITE_FULL, "metadataIndexSQLiteFull"),
            (SQLITE_IOERR, "metadataIndexSQLiteIO"),
            (SQLITE_PERM, "metadataIndexSQLitePermission"),
            (SQLITE_AUTH, "metadataIndexSQLitePermission"),
            (SQLITE_MISUSE, "metadataIndexSQLiteFailure"),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(
                MetadataIndexProjector.stableErrorCode(
                    IndexedMetadataStoreError.sqlite(
                        code: code | (7 << 8),
                        message: "/private/secret/path"
                    )
                ),
                expected
            )
        }
    }

    func testProjectionPreservesFormerParentForMoveEnumeration() async throws {
        let root = try temporaryDirectory()
        let paths = SharedContainerPaths(root: root)
        let folder = try XCTUnwrap(FolderID(rawValue: "projection-move"))
        let oldParent = IndexedItem(
            id: "old-parent",
            folderID: folder,
            relativePath: "Old",
            isDirectory: true,
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data([1]),
            metadataVersion: Data([2]),
            availability: .local,
            generation: 1
        )
        let newParent = IndexedItem(
            id: "new-parent",
            folderID: folder,
            relativePath: "New",
            isDirectory: true,
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data([1]),
            metadataVersion: Data([2]),
            availability: .local,
            generation: 1
        )
        let original = IndexedItem(
            id: "stable-item",
            folderID: folder,
            parentID: oldParent.id,
            relativePath: "Old/report.txt",
            isDirectory: false,
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data([1]),
            metadataVersion: Data([2]),
            availability: .local,
            generation: 1
        )
        let projector = MetadataIndexProjector(
            databaseURL: paths.metadataIndex,
            statusURL: paths.metadataIndexStatus
        )
        let initialStatus = await projector.project(
            .init(generation: 1, items: [oldParent, newParent, original])
        )
        XCTAssertEqual(initialStatus.state, .ready)

        var moved = original
        moved.parentID = newParent.id
        moved.relativePath = "New/report.txt"
        moved.generation = 2
        let movedStatus = await projector.project(
            .init(generation: 2, items: [oldParent, newParent, moved])
        )
        XCTAssertEqual(movedStatus.state, .ready)

        let store = try IndexedMetadataStore(
            databaseURL: paths.metadataIndex,
            accessMode: .readOnly,
            recoveryPolicy: .fail
        )
        let page = try await store.changes(sinceGeneration: 1, limit: 10)
        let change = try XCTUnwrap(page.changes.first { $0.itemID == moved.id })
        XCTAssertEqual(
            change.effect(in: .directory(itemID: oldParent.id)),
            .delete
        )
        XCTAssertEqual(
            change.effect(in: .directory(itemID: newParent.id)),
            .update(moved)
        )
    }

    func testPinnedOfflinePolicyOverlaysMetadataAndWorkingSetFailClosed() async throws {
        let root = try temporaryDirectory()
        let paths = SharedContainerPaths(root: root)
        let folder = try XCTUnwrap(FolderID(rawValue: "pinned-folder"))
        let folderRoot = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderRoot, withIntermediateDirectories: true)
        let snapshot = CoreSnapshot(
            generation: 9,
            items: [item(id: "remote", folder: folder, path: "remote.txt", availability: .remoteOnly)]
        )
        let incarnation = try XCTUnwrap(
            FolderIncarnationStore(url: paths.folderIncarnations)
                .ensureLegacyConfiguredFolders([folder]).first
        )
        _ = try ContentRetentionStore(url: paths.contentRetention).applyPlan(
            folderID: folder,
            folderIncarnationDigest: incarnation.folderIncarnationDigest,
            expectedGeneration: 0,
            plan: FolderSelectionPlan(mode: .pinnedOffline)
        )

        let projector = MetadataIndexProjector(
            databaseURL: paths.metadataIndex,
            statusURL: paths.metadataIndexStatus
        )
        let projectionStatus = await projector.project(snapshot)
        XCTAssertEqual(projectionStatus.state, .ready)

        let store = try IndexedMetadataStore(
            databaseURL: paths.metadataIndex,
            accessMode: .readOnly,
            recoveryPolicy: .fail
        )
        let loadedItem = try await store.item(identifier: "remote")
        let projected = try XCTUnwrap(loadedItem)
        XCTAssertTrue(projected.isPinned)
        let workingSet = try await store.workingSet(limit: 10)
        XCTAssertEqual(workingSet.items.map(\.id), ["remote"])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataProjectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func item(
        id: String,
        folder: FolderID,
        path: String,
        availability: FileAvailability,
        pinned: Bool = false
    ) -> IndexedItem {
        IndexedItem(
            id: id,
            folderID: folder,
            relativePath: path,
            isDirectory: false,
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data([1]),
            metadataVersion: Data([2]),
            availability: availability,
            isPinned: pinned,
            generation: 4
        )
    }
}
