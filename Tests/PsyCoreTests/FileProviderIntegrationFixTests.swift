import Foundation
import XCTest

@testable import PsyCore

final class FileProviderIntegrationFixTests: XCTestCase {
    func testCompactMetadataPreservesAuthorityAndAvoidsTheItemTree() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SharedSnapshotStore(snapshotURL: root.appendingPathComponent("snapshot.json"))
        let items = (0..<1000).map { item("\($0)") }
        var snapshot = CoreSnapshot(
            generation: 1, configurationRevision: String(repeating: "a", count: 64), folders: [folder()], items: items)
        try store.write(snapshot)
        let first = try XCTUnwrap(store.readProviderMetadata())
        XCTAssertTrue(first.items.isEmpty)
        XCTAssertEqual(first.folders, snapshot.folders)
        XCTAssertEqual(first.configurationRevision, snapshot.configurationRevision)
        XCTAssertEqual(first.providerMetadataGeneration, 1)
        XCTAssertEqual(try store.read()?.items.count, 1000)
        let metadata = root.appendingPathComponent("snapshot.json.provider-metadata")
        XCTAssertLessThan(try Data(contentsOf: metadata).count, 10_000)
        snapshot.generation = 2
        snapshot.generatedAt = .now
        snapshot.items = snapshot.items.map {
            var value = $0
            value.generation = 2
            return value
        }
        try store.write(snapshot)
        XCTAssertEqual(try store.readProviderMetadata()?.providerMetadataGeneration, 1)
        snapshot.generation = 3
        snapshot.items[0].contentVersion = Data([9])
        try store.write(snapshot)
        XCTAssertEqual(try store.readProviderMetadata()?.providerMetadataGeneration, 3)
    }

    func testMetadataRepairsMissingOrExternallyReplacedCanonicalSnapshot() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("snapshot.json")
        let store = SharedSnapshotStore(snapshotURL: url)
        try store.write(CoreSnapshot(generation: 1, folders: [folder()], items: [item("a")]))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let replacement = CoreSnapshot(generation: 7, folders: [folder(label: "Renamed")], items: [item("b")])
        try encoder.encode(replacement).write(to: url, options: .atomic)
        XCTAssertEqual(try store.readProviderMetadata()?.generation, 7)
        XCTAssertEqual(try store.readProviderMetadata()?.folders.first?.label, "Renamed")
        try FileManager.default.removeItem(at: url.appendingPathExtension("provider-metadata"))
        XCTAssertEqual(try store.readProviderMetadata()?.generation, 7)
    }

    func testShareNamesHandleDuplicateUnicodeAndUnsafeComponents() {
        let folders = [
            folder("a", label: "Photos"), folder("b", label: "photos"), folder("c", label: "Work/2026"),
            folder("d", label: ".."), folder("e", label: "Cafe"), folder("f", label: "Café"),
            folder("g", label: String(repeating: "照", count: 200)),
        ]
        let names = FileProviderShareCatalog.names(for: folders)
        XCTAssertEqual(names, FileProviderShareCatalog.names(for: Array(folders.reversed())))
        XCTAssertNotEqual(names[folders[0].id], names[folders[1].id])
        XCTAssertNotEqual(names[folders[4].id], names[folders[5].id])
        for name in names.values {
            XCTAssertFalse(name.isEmpty || name == "." || name == "..")
            XCTAssertFalse(name.contains("/") || name.contains(":"))
            XCTAssertLessThanOrEqual(name.utf8.count, 255)
        }
        XCTAssertEqual(folders[2].label, "Work/2026")
        XCTAssertNotEqual(
            FileProviderShareCatalog.revision(for: folders),
            FileProviderShareCatalog.revision(for: Array(folders.dropLast())))
    }

    func testRemoteUpdatesAndCacheEvictionRemainWorkingSetUpdates() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try IndexedMetadataStore(databaseURL: root.appendingPathComponent("index.sqlite"))
        var remote = item("remote")
        _ = try await database.importSnapshot(CoreSnapshot(generation: 1, items: [remote]))
        let page = try await database.workingSet()
        XCTAssertEqual(page.items.map(\.id), [remote.id])
        remote.generation = 2
        remote.contentVersion = Data([8])
        _ = try await database.importSnapshot(CoreSnapshot(generation: 2, items: [remote]))
        var changes = try await database.changes(sinceGeneration: 1)
        XCTAssertEqual(changes.changes.first?.effect(in: .workingSet), .update(remote))
        remote.availability = .local
        remote.generation = 3
        _ = try await database.importSnapshot(CoreSnapshot(generation: 3, items: [remote]))
        remote.availability = .remoteOnly
        remote.generation = 4
        _ = try await database.importSnapshot(CoreSnapshot(generation: 4, items: [remote]))
        changes = try await database.changes(sinceGeneration: 3)
        XCTAssertEqual(changes.changes.first?.effect(in: .workingSet), .update(remote))
    }

    func testPointLookupRejectsAProjectionOfAnotherGeneration() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try IndexedMetadataStore(databaseURL: root.appendingPathComponent("index.sqlite"))
        _ = try await database.importSnapshot(CoreSnapshot(generation: 2, items: [item("a")]))
        do {
            _ = try await database.item(identifier: "a", expectedGeneration: 1)
            XCTFail("Accepted mixed generations")
        } catch { XCTAssertEqual(error as? IndexedMetadataStoreError, .generationCollision(1)) }
    }

    func testExplicitEvictionUsesFreshIdentityAndRejectsSupersededIntent() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let retention = ContentRetentionStore(url: root.appendingPathComponent("retention.json"))
        var downloaded = item("a")
        downloaded.availability = .local
        downloaded.remoteReplicaCount = 1
        let digest = String(repeating: "a", count: 64)
        guard
            case .ready(let transaction) = try retention.requestEviction(
                of: downloaded, folderIncarnationDigest: digest, configurationRevision: digest)
        else { return XCTFail("No eviction transaction") }
        let command = ContentEvictionFinalization.command(for: transaction, trigger: .fileProvider)
        XCTAssertNotEqual(command.id, transaction.id)
        XCTAssertNil(command.arguments["systemEvictionObserved"])
        XCTAssertEqual(command.kind.networkSessionOperation, .localContent)
        XCTAssertNoThrow(try ContentEvictionFinalization.validate(command, store: retention))
        try retention.keepDownloaded(
            itemID: downloaded.id, folderID: downloaded.folderID, relativePath: downloaded.relativePath,
            isDirectory: false, folderIncarnationDigest: digest)
        XCTAssertThrowsError(try ContentEvictionFinalization.validate(command, store: retention))
        XCTAssertFalse(try retention.coreEvictionIsRequested(transactionID: transaction.id))
        guard
            case .ready(let renewed) = try retention.requestEviction(
                of: downloaded, folderIncarnationDigest: digest, configurationRevision: digest)
        else { return XCTFail("New explicit removal was not prepared") }
        XCTAssertNotEqual(renewed.id, transaction.id)
        XCTAssertNotEqual(ContentEvictionFinalization.command(for: renewed, trigger: .fileProvider).id, command.id)
        XCTAssertNoThrow(
            try ContentEvictionFinalization.validate(
                ContentEvictionFinalization.command(for: renewed, trigger: .fileProvider), store: retention))
    }

    func testReplicaObservationDoesNotChangeCoreContentOrRetention() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try Data("sole local copy".utf8).write(to: source)
        let replicas = FileProviderReplicaStore(url: root.appendingPathComponent("replicas.json"))
        try replicas.replaceObservedIdentifiers(["item-a"])
        try replicas.replaceObservedIdentifiers([])
        XCTAssertEqual(try replicas.observedIdentifiers(), [])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "sole local copy")
    }

    func testConflictNamesBindIncomingBytesAndReviewedVersion() {
        let original = item("a")
        let first = FileProviderConflictPlan(
            item: original, baseContentVersion: Data([1]), baseMetadataVersion: Data([2]), contentDigest: Data([3]),
            incarnation: "first")
        let retry = FileProviderConflictPlan(
            item: original, baseContentVersion: Data([1]), baseMetadataVersion: Data([2]), contentDigest: Data([3]),
            incarnation: "first")
        let other = FileProviderConflictPlan(
            item: original, baseContentVersion: Data([1]), baseMetadataVersion: Data([2]), contentDigest: Data([4]),
            incarnation: "first")
        XCTAssertEqual(first.commandID, retry.commandID)
        XCTAssertEqual(first.filename, retry.filename)
        XCTAssertNotEqual(first.commandID, other.commandID)
        XCTAssertTrue(first.filename.contains(".sync-conflict-"))
        XCTAssertTrue(first.filename.hasSuffix(".txt"))
        var unicode = original
        unicode.relativePath = String(repeating: "字", count: 60) + "." + String(repeating: "文", count: 20)
        let bounded = FileProviderConflictPlan(
            item: unicode, baseContentVersion: Data([1]), baseMetadataVersion: Data([2]), contentDigest: Data([3]),
            incarnation: "first")
        XCTAssertLessThanOrEqual(bounded.filename.utf8.count, 255)
    }

    func testDeliveryUsesFreshMetadataWithoutChangingTheFetchedContentIdentity() {
        let original = item("fetched")
        var current = original
        current.metadataVersion = Data([9])
        current.relativePath = "Renamed.txt"
        current.availability = .local
        XCTAssertTrue(FileProviderDeliveryFence(item: original).matches(current))
        current.contentVersion = Data([8])
        XCTAssertFalse(FileProviderDeliveryFence(item: original).matches(current))
    }

    func testStagingRejectsBytesThatChangedAfterContentIdentityWasChosen() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        let staging = FileProviderStagingStore(
            root: root.appendingPathComponent("staging"), availableCapacity: { _ in .max })
        try Data("first".utf8).write(to: source)
        let digest = try staging.sourceContentDigest(source)
        try Data("second".utf8).write(to: source)
        var committed = false
        XCTAssertThrowsError(
            try staging.stageAndCommit(source, id: UUID(), expectedDigest: digest, commit: { committed = true }))
        XCTAssertFalse(committed)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    private func folder(_ id: String = "share", label: String = "Photos") -> FolderRecord {
        FolderRecord(id: FolderID(rawValue: id)!, label: label, localPath: "/unused/\(id)")
    }
    private func item(_ id: String) -> IndexedItem {
        IndexedItem(
            id: id, folderID: FolderID(rawValue: "share")!, parentID: "directory", relativePath: "Folder/\(id).txt",
            isDirectory: false,
            size: 4, modifiedAt: Date(timeIntervalSince1970: 1), contentVersion: Data([1]), metadataVersion: Data([2]),
            availability: .remoteOnly, generation: 1)
    }
}
