import Foundation
import Testing
@testable import PsySync

private let f1 = FolderID(rawValue: "f1")

@Suite struct FilesStoreTests {
    @Test func projectsHierarchyWithStableIdentity() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.dir("a"), FilesFixtures.file("a/x.txt"), FilesFixtures.file("b/c/y.txt")])
        let reader = store.reader(folder: f1)
        let top = try reader.children(of: reader.rootID, after: nil, limit: 10).items.map(\.path.rawValue)
        #expect(top == ["a", "b"])
        let b = try #require(try reader.item(at: RelativePath(rawValue: "b")))
        #expect(b.isDirectory)  // placeholder parent created
        let y = try #require(try reader.item(at: RelativePath(rawValue: "b/c/y.txt")))
        let c = try #require(try reader.item(y.parentID))
        #expect(c.path.rawValue == "b/c")
        // Re-applying the same entries keeps ids and anchors.
        let anchor = try store.currentAnchor()
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.dir("a"), FilesFixtures.file("a/x.txt"), FilesFixtures.file("b/c/y.txt")])
        #expect(try store.currentAnchor() == anchor)
        #expect(try reader.item(at: RelativePath(rawValue: "b/c/y.txt"))?.itemID == y.itemID)
    }

    @Test func contentVersionIgnoresMetadataOnlyChanges() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("x", version: "v1", blocks: "QUJD")])
        let before = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "x")))
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("x", version: "v2", blocks: "QUJD")])
        let after = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "x")))
        #expect(before.contentVersion == after.contentVersion)
        #expect(before.metadataVersion != after.metadataVersion)
        #expect(after.changeAnchor > before.changeAnchor)
    }

    @Test func deletionsBecomeTombstonesAndSweepRemovesMissing() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("d/1"), FilesFixtures.file("d/2"), FilesFixtures.file("e")])
        let reader = store.reader(folder: f1)
        let anchor = try reader.currentAnchor()
        let d = try #require(try reader.item(at: RelativePath(rawValue: "d")))
        let one = try #require(try reader.item(at: RelativePath(rawValue: "d/1")))
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("d/1", deleted: true)])
        var changes = try reader.changes(since: anchor, limit: 100)
        #expect(changes.deleted == [one.itemID])
        // Full sync where "d" vanished entirely.
        try store.beginFullSync(f1)
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("e")])
        let next = changes.newAnchor
        try store.finishFullSync(f1)
        changes = try reader.changes(since: next, limit: 100)
        #expect(Set(changes.deleted).contains(d.itemID))
        #expect(try store.itemCount(f1) == 2)  // root + e
    }

    @Test func localRenameKeepsIdentityAndShieldsFromStaleIndex() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.dir("dir"), FilesFixtures.file("dir/a"), FilesFixtures.file("dir/sub/b")])
        let dir = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "dir")))
        let b = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "dir/sub/b")))
        _ = try store.moveIdentity(dir.itemID, to: RelativePath(rawValue: "renamed"), in: f1)
        try store.append(f1, kind: .moved, path: RelativePath(rawValue: "renamed"), previousPath: RelativePath(rawValue: "dir"))
        #expect(try store.record(folder: f1, path: RelativePath(rawValue: "renamed"))?.itemID == dir.itemID)
        #expect(try store.record(folder: f1, path: RelativePath(rawValue: "renamed/sub/b"))?.itemID == b.itemID)
        // A projection pass with the stale (pre-scan) index must not resurrect "dir" nor drop "renamed".
        try store.beginFullSync(f1)
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.dir("dir"), FilesFixtures.file("dir/a"), FilesFixtures.file("dir/sub/b")])
        try store.finishFullSync(f1)
        #expect(try store.record(folder: f1, path: RelativePath(rawValue: "dir")) == nil)
        #expect(try store.record(folder: f1, path: RelativePath(rawValue: "renamed/a")) != nil)
        // After the App scans: journal acked + pending cleared; new index takes over.
        try store.acknowledge(through: Int64.max)
        try store.clearPendingUpload(f1, paths: [RelativePath(rawValue: "renamed")])
        try store.beginFullSync(f1)
        _ = try store.applyIndexBatch(f1, entries: [
            FilesFixtures.dir("renamed"), FilesFixtures.file("renamed/a"), FilesFixtures.file("renamed/sub/b"),
            FilesFixtures.file("dir/a", deleted: true),
        ])
        try store.finishFullSync(f1)
        #expect(try store.record(folder: f1, path: RelativePath(rawValue: "renamed/sub/b"))?.itemID == b.itemID)
        #expect(try store.record(folder: f1, path: RelativePath(rawValue: "renamed"))?.pendingUpload == false)
    }

    @Test func localWriteAndDeleteSurviveStaleProjection() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("keep"), FilesFixtures.file("gone")])
        let written = try store.recordLocalWrite(f1, path: RelativePath(rawValue: "new.txt"), isDirectory: false, size: 3, modified: Date())
        #expect(written.pendingUpload && written.isLocal)
        let gone = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "gone")))
        try store.recordLocalDelete(gone.itemID)
        try store.append(f1, kind: .deleted, path: gone.path, previousPath: nil)
        try store.beginFullSync(f1)
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("keep"), FilesFixtures.file("gone")])
        try store.finishFullSync(f1)
        #expect(try store.record(folder: f1, path: RelativePath(rawValue: "new.txt")) != nil)
        #expect(try store.record(folder: f1, path: RelativePath(rawValue: "gone")) == nil)
    }

    @Test func journalAndInboxRoundTrip() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        try store.append(f1, kind: .created, path: RelativePath(rawValue: "a"), previousPath: nil)
        try store.append(f1, kind: .moved, path: RelativePath(rawValue: "b"), previousPath: RelativePath(rawValue: "a"))
        let pending = try store.pending(limit: 10)
        #expect(pending.map(\.kind) == [.created, .moved])
        try store.acknowledge(through: pending[0].sequence)
        #expect(try store.pending(limit: 10).count == 1)

        let request = try store.post(f1, path: RelativePath(rawValue: "a"), version: Data([1]))
        #expect(try store.open(limit: 10).map(\.id) == [request.id])
        try store.update(request.id, state: .completed, failureCode: nil)
        #expect(try store.get(request.id)?.state == .completed)
        #expect(try store.open(limit: 10).isEmpty)
    }

    @Test func workingSetExcludesUnmaterializedEverythingFiles() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        _ = try store.applyIndexBatch(f1, entries: (0..<50).map { FilesFixtures.file("d/f\($0)") } + [FilesFixtures.file("top")])
        let reader = store.reader(folder: f1)
        #expect(try reader.workingSet(after: nil, limit: 100).items.isEmpty)
        let d = try #require(try reader.item(at: RelativePath(rawValue: "d")))
        try store.setMaterialized(f1, ids: [d.itemID])
        #expect(try reader.workingSet(after: nil, limit: 100).items.count == 51)  // d + children
        let top = try #require(try reader.item(at: RelativePath(rawValue: "top")))
        _ = try store.setPinned(top.itemID, pinned: true)
        #expect(try reader.workingSet(after: nil, limit: 100).items.count == 52)
        // Working-set changes do not report the unrelated file updates outside the set.
        let anchor = try reader.currentAnchor()
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("other", version: "v9")])
        #expect(try reader.changes(since: anchor, limit: 10, workingSetOnly: true).updated.isEmpty)
        #expect(try reader.changes(since: anchor, limit: 10).updated.count == 1)
    }

    /// Regression (iPhone, on-demand folder showed 3 of ~20 root entries): the
    /// system enumerates the root, more index pages are projected, and the
    /// working-set change enumeration runs *before* the system reports the
    /// root as materialized. Those children were filtered out while the anchor
    /// moved past them, so Files never showed them. Becoming materialized must
    /// re-announce the directory's children.
    @Test func childrenProjectedBeforeMaterializationAreReannounced() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        try store.upsertFolder(FilesFolderInfo(folderID: f1, label: "big-folder", isReadOnly: false, contentMode: .onDemand))
        let reader = store.reader(folder: f1)
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("config.yaml", local: false), FilesFixtures.dir("h3-archive")])
        // System: working-set anchor, then the root listing (2 items).
        var systemAnchor = try reader.currentAnchor()
        var seen = Set(try reader.children(of: reader.rootID, after: nil, limit: 100).items.map(\.path.rawValue))
        // Next index page lands; working-set changes run before materialization.
        let late = ["2026-11-04 05-27-39.mkv", "角色摄影", "lens-sim-intro-v11-4k.mp4", "p 文件夹"]
        _ = try store.applyIndexBatch(f1, entries: [
            FilesFixtures.file(late[0], size: 314_572_800, local: false), FilesFixtures.dir(late[1]),
            FilesFixtures.file(late[2], local: false), FilesFixtures.file("\(late[3])/x.txt", local: false),
        ])
        var page = try reader.changes(since: systemAnchor, limit: 100, workingSetOnly: true)
        seen.formUnion(page.updated.map(\.path.rawValue))
        systemAnchor = page.newAnchor
        #expect(seen.isDisjoint(with: late))  // the window: filtered, anchor moved on

        // The system now reports the root as materialized → re-announced.
        #expect(try store.setMaterialized(f1, ids: [reader.rootID]))
        page = try reader.changes(since: systemAnchor, limit: 100, workingSetOnly: true)
        seen.formUnion(page.updated.map(\.path.rawValue))
        #expect(seen.isSuperset(of: late + ["config.yaml", "h3-archive"]))
        // Unchanged materialized set: nothing to re-announce.
        #expect(try !store.setMaterialized(f1, ids: [reader.rootID]))
    }

    /// Existing installs already lost those items (root is materialized, the
    /// system is past their anchors): a one-time repair re-announces them.
    @Test func workingSetRepairRunsOnce() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        try store.upsertFolder(FilesFolderInfo(folderID: f1, label: "big-folder", isReadOnly: false, contentMode: .onDemand))
        let reader = store.reader(folder: f1)
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("a", local: false), FilesFixtures.file("d/b", local: false), FilesFixtures.file("d/e/c", local: false)])
        let d = try #require(try reader.item(at: RelativePath(rawValue: "d")))
        try store.setMaterialized(f1, ids: [reader.rootID, d.itemID])
        let systemAnchor = try reader.currentAnchor()
        #expect(try reader.changes(since: systemAnchor, limit: 100, workingSetOnly: true).updated.isEmpty)

        #expect(try store.repairWorkingSetIfNeeded() == [f1])
        let updated = try reader.changes(since: systemAnchor, limit: 100, workingSetOnly: true).updated.map(\.path.rawValue)
        #expect(Set(updated) == ["a", "d", "d/b", "d/e"])
        #expect(try store.repairWorkingSetIfNeeded().isEmpty)
    }

    @Test func anchorExpiresAfterTombstonePruning() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        store.tombstoneRetention = 5
        _ = try store.applyIndexBatch(f1, entries: (0..<20).map { FilesFixtures.file("x\($0)") })
        try store.beginFullSync(f1)
        try store.finishFullSync(f1)  // everything swept → 20 tombstones → pruned to 5
        #expect(throws: FilesStoreError.anchorExpired) { try store.reader(folder: f1).changes(since: 1, limit: 10) }
    }

    /// Regression (found in the simulator): a read left a cached statement
    /// active, pinning a WAL snapshot; the next write from that connection
    /// failed with SQLITE_BUSY_SNAPSHOT (517) after the other process wrote.
    @Test func secondConnectionWritesDoNotStaleFirstConnection() throws {
        let dir = FilesFixtures.tempDir()
        let app = try FilesFixtures.store(dir)
        let ext = try FilesStore(url: dir.appending(path: "Files/files.sqlite"))
        _ = try app.applyIndexBatch(f1, entries: [FilesFixtures.file("a")])
        let a = try #require(try ext.record(folder: f1, path: RelativePath(rawValue: "a")))
        _ = try ext.reader(folder: f1).children(of: FilesStore.rootItemID(f1), after: nil, limit: 1)
        _ = try app.applyIndexBatch(f1, entries: [FilesFixtures.file("b")])
        _ = try ext.post(f1, path: a.path, version: a.contentVersion)
        try ext.append(f1, kind: .modified, path: a.path, previousPath: nil)
        #expect(try app.open(limit: 10).count == 1)
    }

    @Test func reopensAfterCorruption() throws {
        let dir = FilesFixtures.tempDir()
        let url = dir.appending(path: "Files/files.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 8192).write(to: url)
        let store = try FilesStore(url: url)
        #expect(try store.currentAnchor() == 0)
    }
}

/// DESIGN.md §11 WP-C acceptance: 100k-item pagination and changes.
@Suite(.serialized) struct FilesStoreScaleTests {
    static let total = 100_000

    @Test func hundredThousandItemsPaginationAndChanges() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        let clock = ContinuousClock()
        // 100 directories × (1 dir entry + 999 files) = 100,000 entries.
        var entries: [GlobalIndexEntry] = []
        entries.reserveCapacity(Self.total)
        for d in 0..<100 {
            entries.append(FilesFixtures.dir(String(format: "dir%03d", d)))
            for f in 0..<999 { entries.append(FilesFixtures.file(String(format: "dir%03d/file%04d.bin", d, f))) }
        }
        #expect(entries.count == Self.total)

        let insertStart = clock.now
        try store.beginFullSync(f1)
        for start in stride(from: 0, to: entries.count, by: 1000) {
            _ = try store.applyIndexBatch(f1, entries: Array(entries[start..<min(start + 1000, entries.count)]))
        }
        try store.finishFullSync(f1)
        let insertTime = insertStart.duration(to: clock.now)
        #expect(try store.itemCount(f1) == Self.total + 1)

        let reader = store.reader(folder: f1)
        // Initial changes enumeration from 0, page 1000.
        let changesStart = clock.now
        var anchor: Int64 = 0
        var seen = Set<ItemIdentifier>()
        var pages = 0
        while true {
            let page = try reader.changes(since: anchor, limit: 1000)
            for r in page.updated { seen.insert(r.itemID) }
            anchor = page.newAnchor
            pages += 1
            if !page.more { break }
        }
        let changesTime = changesStart.duration(to: clock.now)
        #expect(seen.count == Self.total + 1)  // + root row
        #expect(pages >= 100)

        // Directory pagination over a 999-child directory and the root, page 100;
        // an unrelated change mid-way must not invalidate the cursor.
        let dir = try #require(try reader.item(at: RelativePath(rawValue: "dir050")))
        var cursor: String?
        var names: [String] = []
        let pageStart = clock.now
        repeat {
            let page = try reader.children(of: dir.itemID, after: cursor, limit: 100)
            names += page.items.map(\.path.lastComponent)
            cursor = page.next
            if names.count == 500 {
                _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("dir010/file0001.bin", version: "v2")])
            }
        } while cursor != nil
        let pageTime = pageStart.duration(to: clock.now)
        #expect(names.count == 999)
        #expect(names == names.sorted())
        #expect(Set(names).count == 999)

        // Incremental: re-applying the full index changes nothing; 10 edits + 5 deletes → exactly 15 changes.
        let before = try reader.currentAnchor()
        let reapplyStart = clock.now
        try store.beginFullSync(f1)
        var modified = entries
        modified[modified.firstIndex { $0.name.rawValue == "dir010/file0001.bin" }!] =
            FilesFixtures.file("dir010/file0001.bin", version: "v2")
        for start in stride(from: 0, to: modified.count, by: 1000) {
            _ = try store.applyIndexBatch(f1, entries: Array(modified[start..<min(start + 1000, modified.count)]))
        }
        try store.finishFullSync(f1)
        let reapplyTime = reapplyStart.duration(to: clock.now)
        #expect(try reader.currentAnchor() == before)

        var edits = (0..<10).map { FilesFixtures.file(String(format: "dir099/file%04d.bin", $0), version: "v3") }
        edits += (0..<5).map { FilesFixtures.file(String(format: "dir098/file%04d.bin", $0), deleted: true) }
        _ = try store.applyIndexBatch(f1, entries: edits)
        let delta = try reader.changes(since: before, limit: 1000)
        #expect(delta.updated.count == 10)
        #expect(delta.deleted.count == 5)
        #expect(!delta.more)

        print("""
            [WP-C scale] items=\(Self.total) insert=\(insertTime) changes(1000/page, \(pages) pages)=\(changesTime) \
            childrenPaging(999 @100)=\(pageTime) fullReapplyNoop=\(reapplyTime)
            """)
    }
}

/// Review finding A2: after a Files edit was uploaded, the projection replaced
/// the local content version with the engine's blocks hash; the system took
/// that for a remote update and evicted the file the user had just saved.
@Suite struct LocalWriteVersionAdoptionTests {
    let f1 = FolderID(rawValue: "f1")

    @Test func uploadedEditKeepsItsContentVersionUntilTheContentChangesElsewhere() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("doc.txt", blocks: "aDE=")])
        let written = try store.recordLocalWrite(
            f1, path: RelativePath(rawValue: "doc.txt"), isDirectory: false, size: 3, modified: Date())
        try store.clearPendingUpload(f1, paths: [RelativePath(rawValue: "doc.txt")])
        // The scan announces our bytes under their real hash.
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("doc.txt", version: "v2", blocks: "aDI=")])
        var row = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "doc.txt")))
        #expect(row.contentVersion == written.contentVersion)
        // Re-read of the same version: still the exposed one.
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("doc.txt", version: "v2", blocks: "aDI=")])
        row = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "doc.txt")))
        #expect(row.contentVersion == written.contentVersion)
        // A peer changes it: a real new content version.
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("doc.txt", version: "v3", blocks: "aDM=")])
        row = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "doc.txt")))
        #expect(row.contentVersion == Data(base64Encoded: "aDM="))
    }
}

/// Dynamic E2E: after files.sqlite was rebuilt, the system kept the old item
/// identifiers and anchors; every folder the user tapped answered noSuchItem
/// and vanished from the listing.
@Suite struct StoreGenerationTests {
    let f1 = FolderID(rawValue: "f1")

    @Test func rebuiltStoreExpiresOldAnchors() throws {
        let dir = FilesFixtures.tempDir()
        let old = try FilesFixtures.store(dir)
        _ = try old.applyIndexBatch(f1, entries: (0..<50).map { FilesFixtures.file("f\($0)") })
        let oldGeneration = try old.generation()
        let oldAnchor = try old.currentAnchor()
        #expect(oldGeneration != 0)
        old.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(filePath: dir.appending(path: "Files/files.sqlite").path() + suffix))
        }
        let rebuilt = try FilesFixtures.store(dir)
        _ = try rebuilt.applyIndexBatch(f1, entries: [FilesFixtures.file("f0")])
        #expect(try rebuilt.generation() != oldGeneration)
        // Legacy plain anchor from the old store is ahead of the new one.
        #expect(throws: FilesStoreError.anchorExpired) {
            _ = try rebuilt.reader(folder: f1).changes(since: oldAnchor, limit: 10, workingSetOnly: true)
        }
        #expect(FilesAnchor.decode(FilesAnchor.encode(generation: 7, anchor: 42))! == (7, 42))
        #expect(FilesAnchor.decode("42")! == (nil, 42))
        #expect(FilesAnchor.decode("x:1") == nil)
    }
}
