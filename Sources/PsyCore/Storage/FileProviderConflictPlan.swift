import CryptoKit
import Foundation

/// Stable conflict identities bind the reviewed base and incoming bytes. Two
/// edits based on the same version cannot borrow each other's staging token.
public struct FileProviderConflictPlan: Sendable {
    public let commandID: UUID
    public let filename: String
    public let contentDigest: Data

    public init(
        item: IndexedItem, baseContentVersion: Data, baseMetadataVersion: Data, contentDigest: Data, incarnation: String
    ) {
        var hash = SHA256()
        for text in ["psy-files-conflict-v1", item.folderID.rawValue, item.id, incarnation] {
            hash.update(data: Data(text.utf8))
            hash.update(data: Data([0]))
        }
        for value in [baseContentVersion, baseMetadataVersion, contentDigest] {
            hash.update(data: Data(String(value.count).utf8))
            hash.update(data: Data([0]))
            hash.update(data: value)
        }
        let digest = Array(hash.finalize())
        commandID = UUID(
            uuid: (
                digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
            ))
        let original = URL(fileURLWithPath: item.relativePath).lastPathComponent
        var ext = URL(fileURLWithPath: original).pathExtension
        while ext.utf8.count > 20 { ext.removeLast() }
        let stem = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        let suffix = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
        filename =
            FileProviderShareCatalog.safeComponent(stem) + ".sync-conflict-" + suffix + (ext.isEmpty ? "" : "." + ext)
        self.contentDigest = contentDigest
    }
}
