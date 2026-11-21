import Foundation
import SQLite3
import XCTest

@testable import PsyCore

final class IndexedMetadataStoreTests: XCTestCase {
    func testExistingFullTextSchemaIsProbedBeforeReuse() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/PsyCore/Storage/IndexedMetadataStore.swift"),
            encoding: .utf8
        )
        let probe = try XCTUnwrap(source.range(of: "SELECT COUNT(*) FROM item_search"))
        let create = try XCTUnwrap(source.range(of: "CREATE VIRTUAL TABLE item_search USING fts5"))
        XCTAssertLessThan(probe.lowerBound, create.lowerBound)
        XCTAssertTrue(source.contains("if mayCreate {\n                    // The read-write initializer"))
        XCTAssertTrue(source.contains("message.localizedCaseInsensitiveContains(\"no such module\")"))
    }

    func testWorkingSetCanBeRestrictedToOneShare() async throws {
        let databaseURL = try makeDatabaseURL()
        let folderA = try XCTUnwrap(FolderID(rawValue: "folder-a"))
        let folderB = try XCTUnwrap(FolderID(rawValue: "folder-b"))
        let store = try IndexedMetadataStore(databaseURL: databaseURL)
        var itemA = item(id: "a-local", folder: folderA, path: "A.txt", generation: 1)
        var itemB = item(id: "b-local", folder: folderB, path: "B.txt", generation: 1)
        itemA.availability = .local
        itemB.availability = .local
        try await store.importSnapshot(
            .init(
                generation: 1,
                items: [itemA, itemB]
            )
        )

        let page = try await store.workingSet(inFolder: folderA)

        XCTAssertEqual(page.items.map(\.id), ["a-local"])
        XCTAssertNil(page.nextCursor)
    }

    func testSnapshotFallbackOrderingMatchesSQLiteBinaryKeysetOrdering() async throws {
        let databaseURL = try makeDatabaseURL()
        let folder = try XCTUnwrap(FolderID(rawValue: "unicode-order"))
        let items = [
            item(id: "decomposed", folder: folder, path: "e\u{301}.txt", generation: 1),
            item(id: "composed", folder: folder, path: "é.txt", generation: 1),
            item(id: "ascii", folder: folder, path: "z.txt", generation: 1),
        ]
        let store = try IndexedMetadataStore(databaseURL: databaseURL)
        _ = try await store.importSnapshot(.init(generation: 1, items: items))

        let sqliteOrder = try await store.allItems(limit: 10).items.map(\.id)
        let fallbackOrder = items.sorted(by: IndexedMetadataStore.binaryItemOrderPrecedes).map(\.id)

        XCTAssertEqual(fallbackOrder, sqliteOrder)
    }

    func testImportIsTransactionalIdempotentAndRejectsGenerationReuse() async throws {
        let databaseURL = try makeDatabaseURL()
        let folder = try XCTUnwrap(FolderID(rawValue: "documents"))
        let original = item(
            id: "file-1",
            folder: folder,
            path: "Reports/Quarterly.pdf",
            generation: 1
        )
        let snapshot = CoreSnapshot(generation: 1, items: [original])
        let store = try IndexedMetadataStore(databaseURL: databaseURL)

        let firstImport = try await store.importSnapshot(snapshot)
        XCTAssertEqual(firstImport.insertedOrUpdatedItems, 1)
        let firstGeneration = try await store.currentGeneration()
        let firstStoredItem = try await store.item(identifier: original.id)
        XCTAssertEqual(firstGeneration, 1)
        XCTAssertEqual(firstStoredItem, original)

        let repeatedImport = try await store.importSnapshot(snapshot)
        XCTAssertEqual(repeatedImport.insertedOrUpdatedItems, 0)

        var conflicting = original
        conflicting.relativePath = "Reports/Changed.pdf"
        do {
            _ = try await store.importSnapshot(.init(generation: 1, items: [conflicting]))
            XCTFail("a generation must identify one immutable metadata state")
        } catch let error as IndexedMetadataStoreError {
            XCTAssertEqual(error, .generationCollision(1))
        }
        let storedItemAfterCollision = try await store.item(identifier: original.id)
        XCTAssertEqual(storedItemAfterCollision, original)

        do {
            _ = try await store.importSnapshot(.init(generation: 0))
            XCTFail("generation regression should fail")
        } catch let error as IndexedMetadataStoreError {
            XCTAssertEqual(error, .generationRegression(current: 1, proposed: 0))
        }
        let generationAfterRegression = try await store.currentGeneration()
        XCTAssertEqual(generationAfterRegression, 1)
    }

    func testParentFolderAndSearchQueriesUseStableKeysetPagination() async throws {
        let databaseURL = try makeDatabaseURL()
        let folderA = try XCTUnwrap(FolderID(rawValue: "folder-a"))
        let folderB = try XCTUnwrap(FolderID(rawValue: "folder-b"))
        let values = [
            item(id: "a-dir", folder: folderA, path: "Docs", directory: true, generation: 1),
            item(id: "a-1", folder: folderA, parent: "a-dir", path: "Docs/Alpha.txt", generation: 1),
            item(id: "a-2", folder: folderA, parent: "a-dir", path: "Docs/Résumé Final.pdf", generation: 1),
            item(id: "a-root", folder: folderA, path: "Root.txt", generation: 1),
            item(id: "b-1", folder: folderB, path: "Elsewhere.txt", generation: 1),
        ]
        let store = try IndexedMetadataStore(databaseURL: databaseURL)
        try await store.importSnapshot(.init(generation: 1, items: values))

        let firstRootPage = try await store.children(inFolder: folderA, parentID: nil, limit: 1)
        XCTAssertEqual(firstRootPage.items.count, 1)
        let secondRootPage = try await store.children(
            inFolder: folderA,
            parentID: nil,
            after: try XCTUnwrap(firstRootPage.nextCursor),
            limit: 1
        )
        XCTAssertEqual(Set(firstRootPage.items.map(\.id) + secondRootPage.items.map(\.id)), ["a-dir", "a-root"])
        XCTAssertNil(secondRootPage.nextCursor)

        let childPage = try await store.children(inFolder: folderA, parentID: "a-dir", limit: 10)
        XCTAssertEqual(childPage.items.map(\.id), ["a-1", "a-2"])
        let exactMatch = try await store.item(
            inFolder: folderA,
            relativePath: "Docs/Résumé Final.pdf"
        )
        let wrongFolderMatch = try await store.item(
            inFolder: folderB,
            relativePath: "Docs/Résumé Final.pdf"
        )
        XCTAssertEqual(exactMatch?.id, "a-2")
        XCTAssertNil(wrongFolderMatch)

        var folderItems: [IndexedItem] = []
        var cursor: IndexedItemPageCursor?
        repeat {
            let page = try await store.items(inFolder: folderA, after: cursor, limit: 2)
            folderItems.append(contentsOf: page.items)
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(folderItems.count, 4)
        XCTAssertEqual(Set(folderItems.map(\.folderID)), [folderA])
        XCTAssertEqual(folderItems.map(\.relativePath), folderItems.map(\.relativePath).sorted())

        let searchPage = try await store.search("resume", inFolder: folderA, limit: 10)
        XCTAssertEqual(searchPage.items.map(\.id), ["a-2"])
        let scopedSearch = try await store.search("elsewhere", inFolder: folderA, limit: 10)
        XCTAssertTrue(scopedSearch.items.isEmpty)

        do {
            _ = try await store.items(inFolder: folderA, limit: IndexedMetadataStore.maximumPageSize + 1)
            XCTFail("unbounded pages must be rejected")
        } catch let error as IndexedMetadataStoreError {
            XCTAssertEqual(error, .invalidPageSize(IndexedMetadataStore.maximumPageSize + 1))
        }
    }

    func testChangeJournalAndTombstonesAreGenerationBoundAndPaginated() async throws {
        let databaseURL = try makeDatabaseURL()
        let folder = try XCTUnwrap(FolderID(rawValue: "journal"))
        let first = item(id: "first", folder: folder, path: "First.txt", generation: 1)
        let removed = item(id: "removed", folder: folder, path: "Removed.txt", generation: 1)
        let store = try IndexedMetadataStore(databaseURL: databaseURL)
        try await store.importSnapshot(.init(generation: 1, items: [first, removed]))

        var updated = first
        updated.relativePath = "First-Renamed.txt"
        updated.generation = 2
        let secondResult = try await store.importSnapshot(
            .init(
                generation: 2,
                items: [updated],
                tombstones: [.init(itemID: removed.id, generation: 2)]
            )
        )
        XCTAssertEqual(secondResult.insertedOrUpdatedItems, 1)
        XCTAssertEqual(secondResult.deletedItems, 1)
        XCTAssertEqual(secondResult.recordedTombstones, 1)

        let firstPage = try await store.changes(sinceGeneration: 1, limit: 1)
        XCTAssertEqual(firstPage.changes.count, 1)
        XCTAssertNotNil(firstPage.nextCursor)
        let firstCursor = try XCTUnwrap(firstPage.nextCursor)
        XCTAssertEqual(firstCursor.rowOffset, 1)
        let containsFirstCursor = try await store.containsChange(at: firstCursor)
        let containsForgedCursor = try await store.containsChange(
            at: .init(generation: firstCursor.generation, sequence: .max)
        )
        XCTAssertTrue(containsFirstCursor)
        XCTAssertFalse(containsForgedCursor)
        let validatedSecondPage = try await store.validatedChanges(
            sinceGeneration: 1,
            after: firstCursor,
            expectedCurrentGeneration: 2,
            limit: 1
        )
        guard case .page(let secondPage) = validatedSecondPage else {
            XCTFail("a continuation emitted for this lower bound must remain valid")
            return
        }
        let changes = firstPage.changes + secondPage.changes
        XCTAssertEqual(changes.map(\.generation), [2, 2])
        XCTAssertEqual(Set(changes.map(\.kind)), [.upsert, .delete])
        XCTAssertEqual(changes.first(where: { $0.kind == .upsert })?.currentItem, updated)
        let deletion = try XCTUnwrap(changes.first(where: { $0.kind == .delete }))
        XCTAssertNil(deletion.currentItem)
        XCTAssertEqual(deletion.effect(in: .folderRoot(folder)), .delete)
        XCTAssertEqual(deletion.effect(in: .directory(itemID: "unrelated")), .delete)
        XCTAssertEqual(deletion.effect(in: .workingSet), .delete)
        XCTAssertEqual(secondPage.currentGeneration, 2)

        let splicedCursor = try await store.validatedChanges(
            sinceGeneration: 0,
            after: firstCursor,
            expectedCurrentGeneration: 2,
            limit: 1
        )
        XCTAssertEqual(splicedCursor, .expired)

        let tombstones = try await store.tombstones(limit: 10)
        XCTAssertEqual(tombstones.tombstones, [.init(itemID: removed.id, generation: 2)])
        let removedItem = try await store.item(identifier: removed.id)
        XCTAssertNil(removedItem)

        let prunedChangeCount = try await store.pruneChangeJournal(throughGeneration: 1)
        XCTAssertEqual(prunedChangeCount, 2)
        let containsCursorAfterPruning = try await store.containsChange(at: firstCursor)
        XCTAssertTrue(containsCursorAfterPruning)
        let remaining = try await store.changes(sinceGeneration: 0, limit: 10)
        XCTAssertEqual(remaining.changes.map(\.generation), [2, 2])

        let expiredOldAnchor = try await store.validatedChanges(
            sinceGeneration: 0,
            expectedCurrentGeneration: 2,
            limit: 10
        )
        XCTAssertEqual(expiredOldAnchor, .expired)
        let retainedCoverage = try await store.validatedChanges(
            sinceGeneration: 1,
            expectedCurrentGeneration: 2,
            limit: 10
        )
        guard case .page(let retainedPage) = retainedCoverage else {
            XCTFail("an anchor at the pruning watermark must remain valid")
            return
        }
        XCTAssertEqual(retainedPage.changes.map(\.generation), [2, 2])
    }

    func testCrossDirectoryMoveRoutesDeletionToOldParentAndUpdateToNewParent() async throws {
        let databaseURL = try makeDatabaseURL()
        let folder = try XCTUnwrap(FolderID(rawValue: "move-routing"))
        let oldParent = item(
            id: "old-parent",
            folder: folder,
            path: "Old",
            directory: true,
            generation: 1
        )
        let newParent = item(
            id: "new-parent",
            folder: folder,
            path: "New",
            directory: true,
            generation: 1
        )
        var original = item(
            id: "stable-file",
            folder: folder,
            parent: oldParent.id,
            path: "Old/report.txt",
            generation: 1
        )
        original.availability = .local

        let store = try IndexedMetadataStore(databaseURL: databaseURL)
        try await store.importSnapshot(
            .init(generation: 1, items: [oldParent, newParent, original])
        )

        var moved = original
        moved.parentID = newParent.id
        moved.relativePath = "New/report.txt"
        moved.generation = 2
        try await store.importSnapshot(
            .init(generation: 2, items: [oldParent, newParent, moved])
        )

        let page = try await store.changes(sinceGeneration: 1, limit: 10)
        let change = try XCTUnwrap(page.changes.first { $0.itemID == moved.id })
        XCTAssertEqual(change.previousRoute?.parentID, oldParent.id)
        XCTAssertTrue(change.previousRouteWasRecorded)
        XCTAssertEqual(
            change.effect(in: .directory(itemID: oldParent.id)),
            .delete
        )
        XCTAssertEqual(
            change.effect(in: .directory(itemID: newParent.id)),
            .update(moved)
        )
        XCTAssertEqual(change.effect(in: .folderRoot(folder)), .none)
        XCTAssertEqual(change.effect(in: .workingSet), .update(moved))

        var movedToRoot = moved
        movedToRoot.parentID = nil
        movedToRoot.relativePath = "report.txt"
        movedToRoot.generation = 3
        try await store.importSnapshot(
            .init(generation: 3, items: [oldParent, newParent, movedToRoot])
        )
        let rootMovePage = try await store.changes(sinceGeneration: 2, limit: 10)
        let rootMove = try XCTUnwrap(rootMovePage.changes.first { $0.itemID == moved.id })
        XCTAssertEqual(
            rootMove.effect(in: .directory(itemID: newParent.id)),
            .delete
        )
        XCTAssertEqual(rootMove.effect(in: .folderRoot(folder)), .update(movedToRoot))
    }

    func testSameDirectoryRenameUpdatesWithoutDeletingAndReplayIsIdempotent() async throws {
        let databaseURL = try makeDatabaseURL()
        let folder = try XCTUnwrap(FolderID(rawValue: "rename-routing"))
        let parent = item(
            id: "parent",
            folder: folder,
            path: "Documents",
            directory: true,
            generation: 1
        )
        let original = item(
            id: "stable-file",
            folder: folder,
            parent: parent.id,
            path: "Documents/Before.txt",
            generation: 1
        )
        let store = try IndexedMetadataStore(databaseURL: databaseURL)
        try await store.importSnapshot(.init(generation: 1, items: [parent, original]))

        var renamed = original
        renamed.relativePath = "Documents/After.txt"
        renamed.generation = 2
        let movedSnapshot = CoreSnapshot(generation: 2, items: [parent, renamed])
        let firstImport = try await store.importSnapshot(movedSnapshot)
        let repeatedImport = try await store.importSnapshot(movedSnapshot)
        XCTAssertEqual(firstImport.insertedOrUpdatedItems, 1)
        XCTAssertEqual(repeatedImport.insertedOrUpdatedItems, 0)

        let changes = try await store.changes(sinceGeneration: 1, limit: 10).changes
        let change = try XCTUnwrap(changes.first { $0.itemID == renamed.id })
        XCTAssertEqual(changes.filter { $0.itemID == renamed.id }.count, 1)
        XCTAssertEqual(
            change.effect(in: .directory(itemID: parent.id)),
            .update(renamed)
        )
    }

    func testMoveRoutesRemainStableAcrossChangeJournalPages() async throws {
        let databaseURL = try makeDatabaseURL()
        let folder = try XCTUnwrap(FolderID(rawValue: "move-pages"))
        let oldParent = item(
            id: "old-parent",
            folder: folder,
            path: "Old",
            directory: true,
            generation: 1
        )
        let newParent = item(
            id: "new-parent",
            folder: folder,
            path: "New",
            directory: true,
            generation: 1
        )
        let first = item(
            id: "first",
            folder: folder,
            parent: oldParent.id,
            path: "Old/first.txt",
            generation: 1
        )
        let second = item(
            id: "second",
            folder: folder,
            parent: oldParent.id,
            path: "Old/second.txt",
            generation: 1
        )
        let store = try IndexedMetadataStore(databaseURL: databaseURL)
        try await store.importSnapshot(
            .init(generation: 1, items: [oldParent, newParent, first, second])
        )

        var movedFirst = first
        movedFirst.parentID = newParent.id
        movedFirst.relativePath = "New/first.txt"
        movedFirst.generation = 2
        var movedSecond = second
        movedSecond.parentID = newParent.id
        movedSecond.relativePath = "New/second.txt"
        movedSecond.generation = 2
        try await store.importSnapshot(
            .init(generation: 2, items: [oldParent, newParent, movedFirst, movedSecond])
        )

        let firstPage = try await store.changes(sinceGeneration: 1, limit: 1)
        let cursor = try XCTUnwrap(firstPage.nextCursor)
        let secondPage = try await store.changes(
            sinceGeneration: 1,
            after: cursor,
            limit: 1
        )
        XCTAssertNil(secondPage.nextCursor)
        let pagedChanges = firstPage.changes + secondPage.changes
        XCTAssertEqual(Set(pagedChanges.map(\.itemID)), [first.id, second.id])
        XCTAssertEqual(pagedChanges.map(\.previousRoute?.parentID), [oldParent.id, oldParent.id])
        XCTAssertTrue(
            pagedChanges.allSatisfy {
                $0.effect(in: .directory(itemID: oldParent.id)) == .delete
            }
        )
        XCTAssertTrue(
            pagedChanges.allSatisfy {
                if case .update = $0.effect(in: .directory(itemID: newParent.id)) {
                    return true
                }
                return false
            }
        )
        XCTAssertEqual(secondPage.currentGeneration, 2)
    }

    func testWorkingSetCacheTransitionsPreserveTheGlobalItem() async throws {
        let databaseURL = try makeDatabaseURL()
        let folder = try XCTUnwrap(FolderID(rawValue: "working-set-routing"))
        let original = item(
            id: "working-set-item",
            folder: folder,
            parent: "nested-parent",
            path: "Nested/report.txt",
            generation: 1
        )
        let store = try IndexedMetadataStore(databaseURL: databaseURL)
        try await store.importSnapshot(.init(generation: 1, items: [original]))

        var materialized = original
        materialized.availability = .local
        materialized.generation = 2
        try await store.importSnapshot(.init(generation: 2, items: [materialized]))
        let enteredPage = try await store.changes(sinceGeneration: 1, limit: 10)
        let entered = try XCTUnwrap(enteredPage.changes.first)
        XCTAssertEqual(entered.effect(in: .workingSet), .update(materialized))
        XCTAssertEqual(entered.effect(in: .folderWorkingSet(folder)), .update(materialized))
        XCTAssertEqual(
            entered.effect(in: .folderWorkingSet(try XCTUnwrap(FolderID(rawValue: "other-folder")))),
            .none
        )
        XCTAssertEqual(entered.effect(in: .folderRoot(folder)), .none)

        var evicted = materialized
        evicted.availability = .remoteOnly
        evicted.generation = 3
        try await store.importSnapshot(.init(generation: 3, items: [evicted]))
        let leftPage = try await store.changes(sinceGeneration: 2, limit: 10)
        let left = try XCTUnwrap(leftPage.changes.first)
        XCTAssertEqual(left.effect(in: .workingSet), .update(evicted))
        XCTAssertEqual(left.effect(in: .folderWorkingSet(folder)), .update(evicted))
    }

    func testLegacyJournalRowsConservativelyRepairUnknownFormerContainers() throws {
        let folder = try XCTUnwrap(FolderID(rawValue: "legacy-routing"))
        let current = item(
            id: "legacy-item",
            folder: folder,
            parent: "new-parent",
            path: "New/report.txt",
            generation: 2
        )
        let legacyChange = IndexedMetadataChange(
            generation: 2,
            sequence: 1,
            itemID: current.id,
            kind: .upsert,
            currentItem: current,
            previousRouteWasRecorded: false
        )

        XCTAssertEqual(
            legacyChange.effect(in: .directory(itemID: "new-parent")),
            .update(current)
        )
        XCTAssertEqual(
            legacyChange.effect(in: .directory(itemID: "unknown-old-parent")),
            .delete
        )
        XCTAssertEqual(legacyChange.effect(in: .folderRoot(folder)), .delete)
        XCTAssertEqual(legacyChange.effect(in: .workingSet), .update(current))
    }

    func testStaleItemsAndTombstonesCannotReplaceNewerMetadata() async throws {
        let databaseURL = try makeDatabaseURL()
        let folder = try XCTUnwrap(FolderID(rawValue: "generation-order"))
        let current = item(id: "current", folder: folder, path: "Current.txt", generation: 5)
        let store = try IndexedMetadataStore(databaseURL: databaseURL)
        try await store.importSnapshot(.init(generation: 5, items: [current]))

        var stale = current
        stale.relativePath = "Stale.txt"
        stale.generation = 4
        let result = try await store.importSnapshot(
            .init(
                generation: 6,
                items: [stale],
                tombstones: [.init(itemID: current.id, generation: 4)]
            )
        )

        XCTAssertEqual(result.insertedOrUpdatedItems, 0)
        XCTAssertEqual(result.deletedItems, 0)
        XCTAssertEqual(result.recordedTombstones, 0)
        let storedItem = try await store.item(identifier: current.id)
        let tombstones = try await store.tombstones(limit: 10)
        let changes = try await store.changes(sinceGeneration: 5, limit: 10)
        let generation = try await store.currentGeneration()
        XCTAssertEqual(storedItem, current)
        XCTAssertTrue(tombstones.tombstones.isEmpty)
        XCTAssertTrue(changes.changes.isEmpty)
        XCTAssertEqual(generation, 6)
    }

    func testWALReadOnlyConnectionObservesCommittedWriterChanges() async throws {
        let databaseURL = try makeDatabaseURL()
        let folder = try XCTUnwrap(FolderID(rawValue: "shared"))
        let writer = try IndexedMetadataStore(databaseURL: databaseURL)
        let first = item(id: "shared-file", folder: folder, path: "Before.txt", generation: 1)
        try await writer.importSnapshot(.init(generation: 1, items: [first]))

        let reader = try IndexedMetadataStore(
            databaseURL: databaseURL,
            accessMode: .readOnly,
            recoveryPolicy: .fail
        )
        let firstRead = try await reader.item(identifier: first.id)
        XCTAssertEqual(firstRead, first)

        var updated = first
        updated.relativePath = "After.txt"
        updated.generation = 2
        try await writer.importSnapshot(.init(generation: 2, items: [updated]))
        let updatedRead = try await reader.item(identifier: first.id)
        XCTAssertEqual(updatedRead, updated)
        let validatedRead = try await reader.validatedChanges(
            sinceGeneration: 1,
            expectedCurrentGeneration: 2,
            limit: 10
        )
        guard case .page(let changePage) = validatedRead else {
            XCTFail("a read-only File Provider connection must support atomic journal reads")
            return
        }
        XCTAssertEqual(changePage.changes.map(\.currentItem), [updated])
        let staleExpectedGeneration = try await reader.validatedChanges(
            sinceGeneration: 1,
            expectedCurrentGeneration: 1,
            limit: 10
        )
        XCTAssertEqual(staleExpectedGeneration, .expired)

        do {
            _ = try await reader.importSnapshot(.init(generation: 3))
            XCTFail("read-only connections must reject writes")
        } catch let error as IndexedMetadataStoreError {
            XCTAssertEqual(error, .readOnly)
        }
    }

    func testVersionOneDatabaseMigratesWithoutLosingRows() async throws {
        let databaseURL = try makeDatabaseURL()
        try createVersionOneDatabase(at: databaseURL)

        let store = try IndexedMetadataStore(databaseURL: databaseURL, recoveryPolicy: .fail)
        let schemaVersion = try await store.schemaVersion()
        let generation = try await store.currentGeneration()
        let itemCount = try await store.itemCount()
        let legacyItem = try await store.item(identifier: "legacy")
        let searchPage = try await store.search("document", limit: 10)
        XCTAssertEqual(schemaVersion, IndexedMetadataStore.currentSchemaVersion)
        XCTAssertEqual(generation, 7)
        XCTAssertEqual(itemCount, 1)
        XCTAssertEqual(legacyItem?.relativePath, "Legacy/Document.txt")
        XCTAssertEqual(searchPage.items.map(\.id), ["legacy"])
    }

    func testVersionTwoJournalMigrationMarksFormerRouteUnknown() async throws {
        let databaseURL = try makeDatabaseURL()
        try createVersionOneDatabase(at: databaseURL)
        try upgradeFixtureToVersionTwoWithLegacyMove(at: databaseURL)

        let store = try IndexedMetadataStore(databaseURL: databaseURL, recoveryPolicy: .fail)
        let schemaVersion = try await store.schemaVersion()
        let page = try await store.changes(sinceGeneration: 7, limit: 10)
        let change = try XCTUnwrap(page.changes.first)
        let folder = try XCTUnwrap(FolderID(rawValue: "legacy-folder"))
        XCTAssertEqual(schemaVersion, IndexedMetadataStore.currentSchemaVersion)
        XCTAssertFalse(change.previousRouteWasRecorded)
        XCTAssertNil(change.previousRoute)
        XCTAssertEqual(
            change.effect(in: .directory(itemID: "new-parent")),
            .update(try XCTUnwrap(change.currentItem))
        )
        XCTAssertEqual(
            change.effect(in: .directory(itemID: "unknown-old-parent")),
            .delete
        )
        XCTAssertEqual(change.effect(in: .folderRoot(folder)), .delete)

        let preMigrationAnchor = try await store.validatedChanges(
            sinceGeneration: 7,
            expectedCurrentGeneration: 8,
            limit: 10
        )
        XCTAssertEqual(preMigrationAnchor, .expired)
        let postMigrationAnchor = try await store.validatedChanges(
            sinceGeneration: 8,
            expectedCurrentGeneration: 8,
            limit: 10
        )
        guard case .page(let currentPage) = postMigrationAnchor else {
            XCTFail("the conservative migration watermark must preserve the current anchor")
            return
        }
        XCTAssertTrue(currentPage.changes.isEmpty)
    }

    func testCorruptDatabaseIsBackedUpBeforeRecreation() async throws {
        let databaseURL = try makeDatabaseURL()
        let oldBackupURL = URL(
            fileURLWithPath: databaseURL.path
                + ".recovered-11111111-1111-1111-1111-111111111111"
        )
        try Data("old derived backup".utf8).write(to: oldBackupURL)
        let corruptData = Data("this is not a sqlite database".utf8)
        try corruptData.write(to: databaseURL)

        let store = try IndexedMetadataStore(
            databaseURL: databaseURL,
            recoveryPolicy: .backupAndRecreate
        )
        let recoveryBackupURL = await store.recoveryBackupURL
        let backupURL = try XCTUnwrap(recoveryBackupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBackupURL.path))
        let schemaVersion = try await store.schemaVersion()
        let generation = try await store.currentGeneration()
        let itemCount = try await store.itemCount()
        XCTAssertEqual(schemaVersion, IndexedMetadataStore.currentSchemaVersion)
        XCTAssertNil(generation)
        XCTAssertEqual(itemCount, 0)
    }

    func testLargeIndexRemainsFastAndQueriesStayBounded() async throws {
        let configuredItemCount = ProcessInfo.processInfo.environment["PSY_INDEX_SCALE_ITEM_COUNT"]
            .flatMap(Int.init)
        let scaleItemCount = configuredItemCount ?? 100_000
        guard scaleItemCount == 100_000 || scaleItemCount == 1_000_000 else {
            XCTFail("PSY_INDEX_SCALE_ITEM_COUNT must be 100000 or 1000000")
            return
        }
        let lastIndex = scaleItemCount - 1
        let identifierWidth = max(6, String(lastIndex).count)
        let needle = "needle\(lastIndex)"
        let databaseURL = try makeDatabaseURL()
        let folder = try XCTUnwrap(FolderID(rawValue: "large-index"))
        let contentVersion = Data([1])
        let metadataVersion = Data([2])
        var values: [IndexedItem] = []
        values.reserveCapacity(scaleItemCount)
        for index in 0..<scaleItemCount {
            let path =
                index == lastIndex
                ? "bucket-099/\(needle).txt"
                : String(
                    format: "bucket-%03d/file-%0*d.dat",
                    index % 100,
                    identifierWidth,
                    index
                )
            values.append(
                IndexedItem(
                    id: String(format: "item-%0*d", identifierWidth, index),
                    folderID: folder,
                    parentID: String(format: "bucket-%03d", index % 100),
                    relativePath: path,
                    isDirectory: false,
                    size: Int64(index),
                    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    contentVersion: contentVersion,
                    metadataVersion: metadataVersion,
                    availability: .remoteOnly,
                    remoteReplicaCount: 1,
                    generation: 1
                )
            )
        }

        let store = try IndexedMetadataStore(databaseURL: databaseURL)
        let clock = ContinuousClock()
        let importStart = clock.now
        let result = try await store.importSnapshot(.init(generation: 1, items: values))
        let importDuration = importStart.duration(to: clock.now)
        values.removeAll(keepingCapacity: false)

        XCTAssertEqual(result.insertedOrUpdatedItems, scaleItemCount)
        let itemCount = try await store.itemCount()
        XCTAssertEqual(itemCount, scaleItemCount)
        let importLimitSeconds = scaleItemCount == 1_000_000 ? 180 : 60
        XCTAssertLessThan(
            importDuration,
            .seconds(importLimitSeconds),
            "\(scaleItemCount)-item import took \(importDuration)"
        )

        let queryStart = clock.now
        let firstPage = try await store.items(inFolder: folder, limit: 256)
        let secondPage = try await store.items(
            inFolder: folder,
            after: try XCTUnwrap(firstPage.nextCursor),
            limit: 256
        )
        let searchPage = try await store.search(needle, inFolder: folder, limit: 10)
        let changePage = try await store.changes(sinceGeneration: 0, limit: 500)
        let queryDuration = queryStart.duration(to: clock.now)

        XCTAssertEqual(firstPage.items.count, 256)
        XCTAssertEqual(secondPage.items.count, 256)
        XCTAssertTrue(Set(firstPage.items.map(\.id)).isDisjoint(with: secondPage.items.map(\.id)))
        XCTAssertEqual(
            searchPage.items.map(\.id),
            [String(format: "item-%0*d", identifierWidth, lastIndex)]
        )
        XCTAssertEqual(changePage.changes.count, 500)
        XCTAssertNotNil(changePage.nextCursor)
        XCTAssertLessThan(
            queryDuration,
            .seconds(5),
            "bounded \(scaleItemCount)-item queries took \(queryDuration)"
        )
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexedMetadataStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("metadata.sqlite")
    }

    private func item(
        id: String,
        folder: FolderID,
        parent: String? = nil,
        path: String,
        directory: Bool = false,
        generation: UInt64
    ) -> IndexedItem {
        IndexedItem(
            id: id,
            folderID: folder,
            parentID: parent,
            relativePath: path,
            isDirectory: directory,
            size: directory ? 0 : 42,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentVersion: Data([1, 2, 3]),
            metadataVersion: Data([4, 5, 6]),
            availability: .remoteOnly,
            remoteReplicaCount: 1,
            generation: generation
        )
    }

    private func createVersionOneDatabase(at url: URL) throws {
        try executeSQLite(
            at: url,
            sql: """
                CREATE TABLE store_state(
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    current_generation INTEGER,
                    generated_at REAL NOT NULL
                );
                CREATE TABLE items(
                    item_id TEXT PRIMARY KEY NOT NULL,
                    folder_id TEXT NOT NULL,
                    parent_id TEXT,
                    relative_path TEXT NOT NULL,
                    is_directory INTEGER NOT NULL CHECK(is_directory IN (0, 1)),
                    size INTEGER NOT NULL,
                    modified_at REAL NOT NULL,
                    content_version BLOB NOT NULL,
                    metadata_version BLOB NOT NULL,
                    availability TEXT NOT NULL,
                    is_pinned INTEGER NOT NULL CHECK(is_pinned IN (0, 1)),
                    has_unuploaded_changes INTEGER NOT NULL CHECK(has_unuploaded_changes IN (0, 1)),
                    remote_replica_count INTEGER NOT NULL,
                    generation INTEGER NOT NULL CHECK(generation >= 0)
                );
                CREATE TABLE tombstones(
                    item_id TEXT PRIMARY KEY NOT NULL,
                    generation INTEGER NOT NULL CHECK(generation >= 0)
                );
                INSERT INTO store_state(singleton, current_generation, generated_at)
                VALUES (1, 7, 1700000000);
                INSERT INTO items(
                    item_id, folder_id, parent_id, relative_path, is_directory,
                    size, modified_at, content_version, metadata_version,
                    availability, is_pinned, has_unuploaded_changes,
                    remote_replica_count, generation
                ) VALUES (
                    'legacy', 'legacy-folder', NULL, 'Legacy/Document.txt', 0,
                    7, 1700000000, X'01', X'02',
                    'remoteOnly', 0, 0, 1, 7
                );
                PRAGMA user_version = 1;
                """
        )
    }

    private func upgradeFixtureToVersionTwoWithLegacyMove(at url: URL) throws {
        try executeSQLite(
            at: url,
            sql: """
                ALTER TABLE items ADD COLUMN search_text TEXT NOT NULL DEFAULT '';
                UPDATE items
                SET parent_id = 'new-parent',
                    relative_path = 'New/Document.txt',
                    search_text = 'new/document.txt',
                    generation = 8
                WHERE item_id = 'legacy';
                UPDATE store_state
                SET current_generation = 8, generated_at = 1700000001
                WHERE singleton = 1;
                CREATE TABLE change_journal(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    generation INTEGER NOT NULL CHECK(generation >= 0),
                    item_id TEXT NOT NULL,
                    kind INTEGER NOT NULL CHECK(kind IN (1, 2)),
                    UNIQUE(generation, item_id, kind)
                );
                CREATE INDEX items_by_folder_path
                    ON items(folder_id, relative_path, item_id);
                CREATE INDEX items_by_parent_path
                    ON items(folder_id, parent_id, relative_path, item_id);
                CREATE INDEX items_by_path
                    ON items(relative_path, item_id);
                CREATE INDEX tombstones_by_generation
                    ON tombstones(generation, item_id);
                CREATE INDEX journal_by_generation_sequence
                    ON change_journal(generation, sequence);
                INSERT INTO change_journal(generation, item_id, kind)
                VALUES (8, 'legacy', 1);
                PRAGMA user_version = 2;
                """
        )
    }

    private func executeSQLite(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            throw IndexedMetadataStoreError.sqlite(code: openResult, message: "unable to create migration fixture")
        }
        defer { sqlite3_close_v2(database) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite fixture error"
            sqlite3_free(errorMessage)
            throw IndexedMetadataStoreError.sqlite(code: result, message: message)
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
