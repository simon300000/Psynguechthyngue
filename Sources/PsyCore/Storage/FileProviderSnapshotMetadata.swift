import CryptoKit
import Foundation

/// A disposable, compact projection of a canonical snapshot. The file stamp
/// binds it to the exact atomic canonical write; legacy writers or a failed
/// sidecar write cause a one-time full read and repair, never a false empty tree.
struct FileProviderSnapshotMetadata: Codable {
    struct Stamp: Codable, Equatable {
        var inode: UInt64
        var bytes: UInt64
        var modified: Date

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let inode = attributes[.systemFileNumber] as? NSNumber,
                let bytes = attributes[.size] as? NSNumber,
                let modified = attributes[.modificationDate] as? Date
            else { throw CocoaError(.fileReadCorruptFile) }
            self.inode = inode.uint64Value
            self.bytes = bytes.uint64Value
            self.modified = modified
        }
    }

    var stamp: Stamp
    var contentDigest: Data
    var snapshot: CoreSnapshot

    init(snapshot source: CoreSnapshot, stamp: Stamp, previous: Self?) {
        self.stamp = stamp
        var hash = SHA256()
        hash.update(data: FileProviderShareCatalog.revision(for: source.folders))
        for item in source.items.sorted(by: { $0.id < $1.id }) {
            for value in [
                item.id, item.folderID.rawValue, item.parentID ?? "", item.relativePath,
                String(item.isDirectory), String(item.size), String(item.modifiedAt.timeIntervalSince1970),
                item.availability.rawValue, String(item.isPinned), String(item.hasUnuploadedChanges),
                String(item.remoteReplicaCount),
            ] {
                hash.update(data: Data(value.utf8))
                hash.update(data: Data([0]))
            }
            for version in [item.contentVersion, item.metadataVersion] {
                hash.update(data: Data(String(version.count).utf8))
                hash.update(data: Data([0]))
                hash.update(data: version)
            }
        }
        for tombstone in source.tombstones.sorted(by: { $0.itemID < $1.itemID }) {
            hash.update(data: Data(tombstone.itemID.utf8))
            hash.update(data: Data([0]))
        }
        contentDigest = Data(hash.finalize())
        snapshot = source
        snapshot.items = []
        snapshot.tombstones = []
        let previousGeneration = previous?.snapshot.providerMetadataGeneration ?? source.generation
        snapshot.providerMetadataGeneration =
            previous?.contentDigest == contentDigest && previousGeneration <= source.generation
            ? previousGeneration : source.generation
    }
}
