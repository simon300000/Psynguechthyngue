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
        #expect(before == a.metadataVersion + Data("|c\(FilesItemPolicy.capabilityRevision)".utf8))
        _ = try store.setPinned(a.itemID, pinned: true)
        let pinned = try #require(try reader.item(a.itemID))
        #expect(pinned.changeAnchor > a.changeAnchor)
        #expect(FilesItemPolicy.exposedMetadataVersion(for: pinned) != before)
        _ = try store.setPinned(a.itemID, pinned: false)
        let unpinned = try #require(try reader.item(a.itemID))
        #expect(FilesItemPolicy.exposedMetadataVersion(for: unpinned) == before)
    }

    /// Dynamic E2E: items lacked `.allowsEvicting`, so on iOS neither "Remove
    /// Download" nor the system could ever evict them (NonEvictable, -2008).
    /// The capability change must reach items the system already cached:
    /// every row gets a new anchor once.
    @Test func capabilityRevisionReannouncesEveryRowOnce() throws {
        let (store, reader) = try setup(.everything)
        let since = try reader.currentAnchor()
        #expect(try store.reannounceForCapabilitiesIfNeeded() == [f1])
        let page = try reader.changes(since: since, limit: 100)
        #expect(Set(page.updated.map(\.path.rawValue)).isSuperset(of: ["a", "a/x.txt", "b"]))
        #expect(try store.reannounceForCapabilitiesIfNeeded().isEmpty)
    }

    /// Finding A1: in an on-demand folder a not-downloaded file is ignored
    /// locally, so deleting/moving it could never propagate.
    @Test func remoteOnlyFilesInOnDemandFoldersCannotBeDeletedOrMoved() throws {
        let store = try FilesFixtures.store(FilesFixtures.tempDir(), mode: .onDemand)
        _ = try store.applyIndexBatch(f1, entries: [
            FilesFixtures.dir("d"), FilesFixtures.file("d/remote.txt", local: false), FilesFixtures.file("d2/here.txt"),
        ])
        let remote = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "d/remote.txt")))
        let here = try #require(try store.record(folder: f1, path: RelativePath(rawValue: "d2/here.txt")))
        #expect(!FilesItemPolicy.allowsNamespaceChanges(remote, contentMode: .onDemand))
        #expect(FilesItemPolicy.allowsNamespaceChanges(remote, contentMode: .everything))
        #expect(FilesItemPolicy.allowsNamespaceChanges(here, contentMode: .onDemand))
        #expect(try store.hasRemoteOnlyFiles(f1, at: RelativePath(rawValue: "d")))
        #expect(try !store.hasRemoteOnlyFiles(f1, at: RelativePath(rawValue: "d2")))
        #expect(try !store.hasRemoteOnlyFiles(f1, at: RelativePath(rawValue: "d2/here.txt")))
        // "d" must not match "d2" by prefix.
        #expect(try store.hasRemoteOnlyFiles(f1, at: RelativePath(rawValue: "d/remote.txt")))
        // The flag reaches the exposed version, so cached capabilities refresh.
        #expect(FilesItemPolicy.exposedMetadataVersion(for: remote) != FilesItemPolicy.exposedMetadataVersion(for: here))
    }

    @Test func conflictCopyNameFollowsUpstreamPattern() {
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        let copy = FilesItemPolicy.conflictPath(for: RelativePath(rawValue: "报告/a b.txt"), now: at)
        #expect(copy.rawValue.hasPrefix("报告/a b.sync-conflict-"))
        #expect(copy.rawValue.hasSuffix("-FILESAP.txt"))
        #expect(StatusMapper.isConflictCopy(copy.rawValue))
        #expect(FilesItemPolicy.conflictPath(for: RelativePath(rawValue: "Makefile"), now: at).rawValue.hasSuffix("-FILESAP"))
    }

    /// Simulator acceptance: after Receive Only → Send & Receive, items synced
    /// meanwhile stayed read-only in Files (no new anchor / version).
    @Test func readOnlyFlipReannouncesExistingItems() throws {
        let (store, reader) = try setup(.everything)
        let a = try #require(try reader.item(at: RelativePath(rawValue: "a")))
        let writable = FilesItemPolicy.exposedMetadataVersion(for: a)
        try store.upsertFolder(FilesFolderInfo(folderID: f1, label: "Folder", isReadOnly: true, contentMode: .everything))
        let ro = try #require(try reader.item(a.itemID))
        #expect(ro.isReadOnly)
        #expect(ro.changeAnchor > a.changeAnchor)
        #expect(FilesItemPolicy.exposedMetadataVersion(for: ro) != writable)
        try store.upsertFolder(FilesFolderInfo(folderID: f1, label: "Folder", isReadOnly: false, contentMode: .everything))
        let back = try #require(try reader.item(a.itemID))
        #expect(!back.isReadOnly)
        #expect(back.changeAnchor > ro.changeAnchor)
        #expect(FilesItemPolicy.exposedMetadataVersion(for: back) == writable)
        let changed = try reader.changes(since: ro.changeAnchor, limit: 10, workingSetOnly: false)
        #expect(changed.updated.contains { $0.itemID == a.itemID })
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
