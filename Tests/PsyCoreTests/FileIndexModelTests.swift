import Foundation
import XCTest

@testable import PsyCore

@MainActor
final class FileIndexModelTests: XCTestCase {
    func testMissingAndStaleDatabaseUseCanonicalSnapshot() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = FileIndexModel()
        let current = makeItem("current", path: "Current.txt", generation: 2)
        let snapshot = CoreSnapshot(generation: 2, items: [current])
        await model.refresh(paths: paths, snapshot: snapshot, incarnations: [:])
        XCTAssertEqual(model.items.map(\.id), ["current"])
        XCTAssertTrue(model.isUsingSnapshotFallback)
        let database = try IndexedMetadataStore(databaseURL: paths.metadataIndex)
        _ = try await database.importSnapshot(
            CoreSnapshot(generation: 1, items: [makeItem("stale", path: "Stale.txt", generation: 1)]))
        await model.refresh(paths: paths, snapshot: snapshot, incarnations: [:], force: true)
        XCTAssertEqual(model.items.map(\.id), ["current"])
        XCTAssertTrue(model.isUsingSnapshotFallback)
        XCTAssertFalse(model.hasMore)
    }

    func testUnexpectedlyEmptyIndexDoesNotHideCanonicalFiles() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let database = try IndexedMetadataStore(databaseURL: paths.metadataIndex)
        _ = try await database.importSnapshot(CoreSnapshot(generation: 2))
        let model = FileIndexModel()
        let snapshot = CoreSnapshot(generation: 2, items: [makeItem("file", path: "File.txt", generation: 2)])
        await model.refresh(paths: paths, snapshot: snapshot, incarnations: [:])
        XCTAssertEqual(model.items.count, 1)
        XCTAssertTrue(model.isUsingSnapshotFallback)
    }

    func testRecoveredIndexCanReplaceFallbackWithoutGenerationChanging() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = FileIndexModel()
        let snapshot = CoreSnapshot(generation: 2, items: [makeItem("file", path: "File.txt", generation: 2)])
        await model.refresh(paths: paths, snapshot: snapshot, incarnations: [:])
        XCTAssertTrue(model.isUsingSnapshotFallback)
        let database = try IndexedMetadataStore(databaseURL: paths.metadataIndex)
        _ = try await database.importSnapshot(snapshot)
        await model.refresh(paths: paths, snapshot: snapshot, incarnations: [:])
        XCTAssertFalse(model.isUsingSnapshotFallback)
        XCTAssertEqual(model.items.map(\.id), ["file"])
    }

    func testLatestSearchWinsEvenWhenPreviousReadFinishesLast() async {
        let reads = IndexReadGate()
        let model = FileIndexModel(readPage: { await reads.read($0) })
        let paths = temporaryPaths()
        let snapshot = CoreSnapshot(generation: 1)
        let first = Task { await model.refresh(paths: paths, snapshot: snapshot, incarnations: [:], query: "old") }
        await reads.waitForRequest("old")
        let second = Task { await model.refresh(paths: paths, snapshot: snapshot, incarnations: [:], query: "new") }
        await reads.waitForRequest("new")
        await reads.finish("new", items: [makeItem("new", path: "New.txt", generation: 1)])
        await second.value
        XCTAssertEqual(model.items.map(\.id), ["new"])
        await reads.finish("old", items: [makeItem("old", path: "Old.txt", generation: 1)])
        await first.value
        XCTAssertEqual(model.items.map(\.id), ["new"])
        XCTAssertFalse(model.isLoading)
    }

    func testStatusRefreshDoesNotRepeatReadOrResetListForSameGeneration() async {
        let count = IndexReadCounter()
        let model = FileIndexModel(readPage: { request in
            await count.increment()
            return .init(
                items: request.snapshot.items, statuses: [:], totalCount: request.snapshot.items.count, nextCursor: nil,
                isFallback: false)
        })
        let paths = temporaryPaths()
        let snapshot = CoreSnapshot(generation: 1, items: [makeItem("file", path: "File.txt", generation: 1)])
        await model.refresh(paths: paths, snapshot: snapshot, incarnations: [:])
        await model.refresh(paths: paths, snapshot: snapshot, incarnations: [:])
        let reads = await count.value
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.items.count, 1)
    }

    private func temporaryPaths() -> SharedContainerPaths {
        SharedContainerPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func makeItem(_ id: String, path: String, generation: UInt64) -> IndexedItem {
        IndexedItem(
            id: id, folderID: FolderID(rawValue: "share")!, relativePath: path, isDirectory: false,
            modifiedAt: .now, contentVersion: Data([1]), metadataVersion: Data([1]), availability: .remoteOnly,
            generation: generation)
    }
}

private actor IndexReadCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor IndexReadGate {
    private var pending: [String: CheckedContinuation<FileIndexModel.Page, Never>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func read(_ request: FileIndexModel.ReadRequest) async -> FileIndexModel.Page {
        await withCheckedContinuation { continuation in
            pending[request.query] = continuation
            waiters.removeValue(forKey: request.query)?.resume()
        }
    }

    func waitForRequest(_ query: String) async {
        if pending[query] != nil { return }
        await withCheckedContinuation { waiters[query] = $0 }
    }

    func finish(_ query: String, items: [IndexedItem]) {
        pending.removeValue(forKey: query)?.resume(
            returning: .init(items: items, statuses: [:], totalCount: items.count, nextCursor: nil, isFallback: false))
    }
}
