import Foundation

/// Per-item File Provider policies derived from `files.sqlite`, kept free of
/// FileProvider types so they can be unit-tested (the extension maps them).
public enum FilesItemPolicy {
    /// Platform-neutral mirror of `NSFileProviderNamespacePolicy` (iOS 27+).
    public enum Namespace: Hashable, Sendable {
        case inherited
        case materializeEagerly
    }

    /// Folders the user marked "Keep Downloaded", and the root of a folder whose
    /// content mode is "Download everything", are kept fully enumerated
    /// (`.materializeEagerly`); everything else inherits. Below an eager folder,
    /// `.inherited` items pick the eager policy up from it.
    ///
    /// Namespace policy only concerns enumeration of folders; file contents are
    /// governed separately. On iOS `contentPolicy` has no eager/keep-downloaded
    /// case, so content stays at the system default (lazy) and "Keep Downloaded"
    /// keeps the Syncthing copy local (un-ignored) — opening is a cheap APFS clone.
    public static func namespace(for record: FileItemRecord, isRoot: Bool, contentMode: ContentMode?) -> Namespace {
        guard record.isDirectory else { return .inherited }
        if isRoot { return contentMode == .everything ? .materializeEagerly : .inherited }
        return record.isPinned ? .materializeEagerly : .inherited
    }

    /// metadataVersion exposed to the system. Pinning changes the item's
    /// policy (and its custom-action userInfo) without changing the Syncthing
    /// version, so it is folded in here; otherwise the system would keep the
    /// properties it cached for the unchanged version. The root's stored
    /// version already covers the content mode (`FilesStore.upsertFolder`).
    public static func exposedMetadataVersion(for record: FileItemRecord) -> Data {
        record.isPinned ? record.metadataVersion + Data("|pinned".utf8) : record.metadataVersion
    }
}
