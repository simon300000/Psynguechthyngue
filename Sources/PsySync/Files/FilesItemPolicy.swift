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
    /// The receive-only flag (capabilities) is folded in the same way.
    /// Bumped whenever the extension's item capabilities change, so the system
    /// re-reads items it cached under the old set (1: `.allowsEvicting`).
    /// Existing rows are re-announced once (`FilesStore.reannounceForCapabilitiesIfNeeded`).
    public static let capabilityRevision: Int64 = 2

    public static func exposedMetadataVersion(for record: FileItemRecord) -> Data {
        var v = record.metadataVersion + Data("|c\(capabilityRevision)".utf8)
        if record.isPinned { v += Data("|pinned".utf8) }
        if record.isReadOnly { v += Data("|readonly".utf8) }
        if isRemoteOnlyFile(record) { v += Data("|remote".utf8) }
        return v
    }

    /// A file whose content is not on this device (and no pending write).
    public static func isRemoteOnlyFile(_ record: FileItemRecord) -> Bool {
        !record.isDirectory && !record.isLocal && !record.pendingUpload
    }

    /// Delete / rename / move are offered only where they can propagate: in an
    /// on-demand folder a not-downloaded file is ignored locally, so the change
    /// would never reach other devices and the item would come back (review
    /// finding A1). Folders are checked when the operation arrives.
    public static func allowsNamespaceChanges(_ record: FileItemRecord, contentMode: ContentMode?) -> Bool {
        contentMode != .onDemand || !isRemoteOnlyFile(record)
    }

    /// `dir/name.sync-conflict-YYYYMMDD-HHMMSS-FILESAP.ext`, the upstream
    /// pattern (StatusMapper lists it as a conflict). Used when an edit in
    /// Files was based on an older version than ours (finding A4).
    public static func conflictPath(for path: RelativePath, now: Date = Date()) -> RelativePath {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = path.lastComponent
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let copy = "\(stem).sync-conflict-\(formatter.string(from: now))-FILESAP" + (ext.isEmpty ? "" : ".\(ext)")
        return path.parent.appending(copy)
    }
}
