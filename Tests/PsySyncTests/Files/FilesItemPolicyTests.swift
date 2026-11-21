import Foundation
import Testing
@testable import PsySync

private let f1 = FolderID(rawValue: "f1")

@Suite struct FilesItemPolicyTests {
    private func setup(_ mode: ContentMode) throws -> (FilesStore, FolderFilesReader) {
        let store = try FilesFixtures.store(FilesFixtures.tempDir(), mode: mode)
        _ = try store.applyIndexBatch(f1, entries: [FilesFixtures.dir("a"), FilesFixtures.file("a/x.txt"), FilesFixtures.dir("b")])
        return (store, store.reader(folder: f1))
    }

    @Test func rootIsEagerOnlyWhenDownloadingEverything() throws {
        for (mode, expected) in [(ContentMode.everything, FilesItemPolicy.Namespace.materializeEagerly), (.onDemand, .inherited)] {
            let (_, reader) = try setup(mode)
            let root = try #require(try reader.item(reader.rootID))
            #expect(FilesItemPolicy.namespace(for: root, isRoot: true, contentMode: mode) == expected)
            // Unknown folder info (not yet written by the App) never forces eager.
            #expect(FilesItemPolicy.namespace(for: root, isRoot: true, contentMode: nil) == .inherited)
        }
    }

    @Test func pinnedFoldersAreEagerFilesAndOthersInherit() throws {
        let (store, reader) = try setup(.onDemand)
        let a = try #require(try reader.item(at: RelativePath(rawValue: "a")))
        let b = try #require(try reader.item(at: RelativePath(rawValue: "b")))
        let x = try #require(try reader.item(at: RelativePath(rawValue: "a/x.txt")))
        _ = try store.setPinned(a.itemID, pinned: true)
        _ = try store.setPinned(x.itemID, pinned: true)
        let pinnedA = try #require(try reader.item(a.itemID))
        let pinnedX = try #require(try reader.item(x.itemID))
        #expect(FilesItemPolicy.namespace(for: pinnedA, isRoot: false, contentMode: .onDemand) == .materializeEagerly)
        #expect(FilesItemPolicy.namespace(for: b, isRoot: false, contentMode: .onDemand) == .inherited)
        // Namespace policy is about enumerating folders; a pinned file inherits.
        #expect(FilesItemPolicy.namespace(for: pinnedX, isRoot: false, contentMode: .onDemand) == .inherited)
        // Non-root folders do not follow the folder's content mode (the root carries it).
        #expect(FilesItemPolicy.namespace(for: b, isRoot: false, contentMode: .everything) == .inherited)
    }

    @Test func pinningChangesExposedMetadataVersionAndAnchor() throws {
        let (store, reader) = try setup(.onDemand)
        let a = try #require(try reader.item(at: RelativePath(rawValue: "a")))
        let before = FilesItemPolicy.exposedMetadataVersion(for: a)
        #expect(before == a.metadataVersion)
        _ = try store.setPinned(a.itemID, pinned: true)
        let pinned = try #require(try reader.item(a.itemID))
        #expect(pinned.changeAnchor > a.changeAnchor)
        #expect(FilesItemPolicy.exposedMetadataVersion(for: pinned) != before)
        _ = try store.setPinned(a.itemID, pinned: false)
        let unpinned = try #require(try reader.item(a.itemID))
        #expect(FilesItemPolicy.exposedMetadataVersion(for: unpinned) == before)
    }

    @Test func contentModeChangeReannouncesRoot() throws {
        let (store, reader) = try setup(.onDemand)
        let root = try #require(try reader.item(reader.rootID))
        try store.upsertFolder(FilesFolderInfo(folderID: f1, label: "Folder", isReadOnly: false, contentMode: .everything))
        let updated = try #require(try reader.item(reader.rootID))
        #expect(updated.metadataVersion != root.metadataVersion)
        #expect(updated.changeAnchor > root.changeAnchor)
        let changed = try reader.changes(since: root.changeAnchor, limit: 10, workingSetOnly: false)
        #expect(changed.updated.contains { $0.itemID == reader.rootID })
    }
}
