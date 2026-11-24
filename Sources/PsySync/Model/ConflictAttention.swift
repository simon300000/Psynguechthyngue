import Foundation

/// What the App remembers about conflict copies (`*.sync-conflict-*`):
/// which ones the user chose to ignore and which ones were already announced
/// with a notification. Keyed by folder + conflict-copy path; the copy's name
/// carries upstream's timestamp, so a later conflict on the same file is a
/// different key (a new conflict).
///
/// Ignoring only hides the conflict in the App; the copy stays in the folder.
/// Records are dropped once the copy is gone from the folder, but only from a
/// status whose conflict list is complete (`FolderStatus.conflictsChecked`):
/// right after the engine starts, a folder reports no conflicts until its
/// index has been walked, and that must not look like "the copy was deleted".
public struct ConflictAttention: Hashable, Codable, Sendable {
    public struct Key: Hashable, Codable, Sendable, Comparable {
        public var folderID: FolderID
        public var path: RelativePath
        public init(folderID: FolderID, path: RelativePath) {
            self.folderID = folderID
            self.path = path
        }
        public static func < (a: Key, b: Key) -> Bool {
            (a.folderID.rawValue, a.path.rawValue) < (b.folderID.rawValue, b.path.rawValue)
        }
    }

    public private(set) var ignored: Set<Key>
    public private(set) var notified: Set<Key>

    public init(ignored: Set<Key> = [], notified: Set<Key> = []) {
        self.ignored = ignored
        self.notified = notified
    }

    /// The key of a conflict issue; nil for every other kind of issue.
    public static func key(_ issue: SyncIssue) -> Key? {
        guard issue.kind == .conflict, let folder = issue.folderID, let path = issue.path else { return nil }
        return Key(folderID: folder, path: path)
    }

    public func isIgnored(_ issue: SyncIssue) -> Bool {
        Self.key(issue).map(ignored.contains) ?? false
    }

    /// The issues the App shows: everything except ignored conflicts.
    public func visible(_ issues: [SyncIssue]) -> [SyncIssue] {
        guard !ignored.isEmpty else { return issues }
        return issues.filter { !isIgnored($0) }
    }

    /// Hides these conflicts from now on. Returns whether anything changed.
    @discardableResult
    public mutating func ignore(_ issues: [SyncIssue]) -> Bool {
        var changed = false
        for key in issues.compactMap(Self.key) {
            // An ignored conflict never needs a notification either.
            notified.insert(key)
            changed = ignored.insert(key).inserted || changed
        }
        return changed
    }

    /// Records the folder's current conflicts. `fresh` are the conflicts seen
    /// for the first time (neither ignored nor announced before): the only
    /// ones worth a notification. `changed` says whether to persist.
    public mutating func observe(_ status: FolderStatus) -> (fresh: [SyncIssue], changed: Bool) {
        var fresh: [SyncIssue] = []
        var current = Set<Key>()
        for issue in status.issues {
            guard let key = Self.key(issue), key.folderID == status.folderID else { continue }
            current.insert(key)
            if !ignored.contains(key) && notified.insert(key).inserted { fresh.append(issue) }
        }
        var changed = !fresh.isEmpty
        if status.conflictsChecked {
            let gone: (Key) -> Bool = { $0.folderID == status.folderID && !current.contains($0) }
            let before = ignored.count + notified.count
            ignored = ignored.filter { !gone($0) }
            notified = notified.filter { !gone($0) }
            changed = changed || ignored.count + notified.count != before
        }
        return (fresh, changed)
    }
}

/// Keeps `ConflictAttention` across launches (UserDefaults, as JSON).
public struct ConflictAttentionStore {
    public static let defaultsKey = "psy.conflictAttention"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> ConflictAttention {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let value = try? JSONDecoder().decode(ConflictAttention.self, from: data)
        else { return ConflictAttention() }
        return value
    }

    public func save(_ value: ConflictAttention) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
