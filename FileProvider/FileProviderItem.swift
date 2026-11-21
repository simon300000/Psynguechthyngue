import FileProvider
import PsySync
import UniformTypeIdentifiers

/// NSFileProviderItem over one `files.sqlite` row.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let record: FileItemRecord
    private let rootID: ItemIdentifier
    private let folderLabel: String

    init(record: FileItemRecord, rootID: ItemIdentifier, folderLabel: String) {
        self.record = record
        self.rootID = rootID
        self.folderLabel = folderLabel
    }

    static func identifier(_ id: ItemIdentifier, rootID: ItemIdentifier) -> NSFileProviderItemIdentifier {
        id == rootID ? .rootContainer : NSFileProviderItemIdentifier(id.rawValue)
    }

    var isRoot: Bool { record.itemID == rootID }

    var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier(record.itemID, rootID: rootID) }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        isRoot ? .rootContainer : Self.identifier(record.parentID, rootID: rootID)
    }

    var filename: String { isRoot ? folderLabel : record.path.lastComponent }

    var contentType: UTType {
        if record.isDirectory { return .folder }
        let ext = (record.path.lastComponent as NSString).pathExtension
        return ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
    }

    var documentSize: NSNumber? { record.isDirectory ? nil : NSNumber(value: record.size) }

    var contentModificationDate: Date? { record.modified.timeIntervalSince1970 > 0 ? record.modified : nil }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: record.contentVersion, metadataVersion: record.metadataVersion)
    }

    var capabilities: NSFileProviderItemCapabilities {
        if record.isReadOnly {
            return record.isDirectory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
        }
        if isRoot {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
        }
        if record.isDirectory {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming, .allowsReparenting,
                    .allowsDeleting]
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
    }

    /// Local change not yet announced by the engine ("waiting to upload").
    var isUploaded: Bool { !record.pendingUpload }
    var isUploading: Bool { false }

    // iOS has no eager/keep-downloaded content policy: "Keep Downloaded" keeps
    // the Syncthing copy local (un-ignored), so reopening is a cheap APFS clone.

    /// Used by the custom actions' activation rules (Info.plist).
    var userInfo: [AnyHashable: Any]? {
        ["pinned": record.isPinned, "isFile": !record.isDirectory]
    }
}

/// Synthetic, empty trash container.
final class TrashContainerItem: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .trashContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .trashContainer }
    var filename: String { "Trash" }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsContentEnumerating] }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("trash".utf8), metadataVersion: Data("trash".utf8))
    }
}
