import Foundation
import Testing
@testable import PsySync

private let f1 = FolderID(rawValue: "f1")

/// Regression (dynamic E2E, user report on iOS 27.3): files fully synced by the
/// engine ("On this device 100%") showed a cloud badge in Files because the
/// system only fetched them when opened. The App now asks the system to
/// download every local file it has not materialized yet.
@Suite struct FilesMaterializerTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: ItemIdentifier) { lock.withLock { ids.append(id.rawValue) } }
        var all: [String] { lock.withLock { ids } }
    }

    @Test func requestsLocalUnmaterializedFilesOnceEach() async throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir())
        _ = try store.applyIndexBatch(f1, entries: [
            FilesFixtures.dir("报告 1"),
            FilesFixtures.file("报告 1/a b.txt"),
            FilesFixtures.file("c.md"),
            FilesFixtures.file("remote.bin", local: false),
            FilesFixtures.file("gone/x.txt"),
        ])
        let a = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "报告 1/a b.txt")))
        let c = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "c.md")))
        let x = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "gone/x.txt")))
        // Already in the Files replica.
        try store.setMaterialized(f1, ids: [FilesStore.rootItemID(f1), c.itemID])
        // "Remove Download" pending for a directory: not re-downloaded.
        try store.requestPresence(f1, path: RelativePath(rawValue: "gone"), present: false)

        let recorder = Recorder()
        let materializer = FilesMaterializer(store: store) { _, id in recorder.add(id) }
        await materializer.refresh(f1)
        await materializer.settle(f1)
        #expect(recorder.all == [a.itemID.rawValue])
        #expect(!recorder.all.contains(x.itemID.rawValue))

        // Same version again (system refused or evicted): not hammered.
        await materializer.refresh(f1)
        await materializer.settle(f1)
        #expect(recorder.all == [a.itemID.rawValue])

        // New content version: requested again.
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.file("报告 1/a b.txt", version: "v2", blocks: "b2")])
        await materializer.refresh(f1)
        await materializer.settle(f1)
        #expect(recorder.all == [a.itemID.rawValue, a.itemID.rawValue])
    }

    @Test func pendingUploadsAndDirectoriesAreSkipped() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir(), mode: .onDemand)
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.dir("d"), FilesFixtures.file("d/up.txt")])
        let up = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "d/up.txt")))
        #expect(try store.unmaterializedLocalFiles(f1, limit: 10).map(\.id) == [up.itemID])
        _ = try store.recordLocalWrite(
            f1, path: RelativePath(rawValue: "d/up.txt"), isDirectory: false, size: 1, modified: Date())
        #expect(try store.unmaterializedLocalFiles(f1, limit: 10).isEmpty)
    }
}
