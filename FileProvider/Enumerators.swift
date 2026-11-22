import FileProvider
import PsySync
import os

/// Anchors are the store's monotonic Int64, encoded as decimal text.
enum AnchorCoding {
    static func encode(_ value: Int64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(value).utf8))
    }

    static func decode(_ anchor: NSFileProviderSyncAnchor) -> Int64? {
        Int64(String(decoding: anchor.rawValue, as: UTF8.self))
    }
}

/// Shared helpers for the three enumerators.
class BaseEnumerator: NSObject, NSFileProviderEnumerator {
    let context: ExtensionContext
    let log = Logger(subsystem: FilesLog.subsystem, category: "enumerator")

    init(context: ExtensionContext) { self.context = context }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler((try? context.reader.currentAnchor()).map(AnchorCoding.encode))
    }

    func pageCursor(_ page: NSFileProviderPage) -> String? {
        let raw = page.rawValue as Data
        if raw == NSFileProviderPage.initialPageSortedByName as Data
            || raw == NSFileProviderPage.initialPageSortedByDate as Data
        {
            return nil
        }
        return String(decoding: raw, as: UTF8.self)
    }

    func pageLimit(_ observer: NSFileProviderEnumerationObserver) -> Int {
        min(max(observer.suggestedPageSize ?? 200, 50), 1000)
    }

    /// Reports changes (filtered) from `anchor`.
    func reportChanges(
        _ observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor, workingSet: Bool,
        filter: (FileItemRecord) -> Bool
    ) {
        guard let since = AnchorCoding.decode(anchor) else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            return
        }
        do {
            let limit = min(max(observer.suggestedBatchSize ?? 500, 100), 1000)
            let page = try context.reader.changes(since: since, limit: limit, workingSetOnly: workingSet)
            let updated = page.updated.filter(filter).map(context.item(for:))
            if !updated.isEmpty { observer.didUpdate(updated) }
            #if DEBUG
            FootprintProbe.file?.append("enumerateChanges folder=\(context.folder.rawValue) workingSet=\(workingSet) since=\(since) updated=\(updated.count) deleted=\(page.deleted.count) more=\(page.more)")
            #endif
            let deleted = page.deleted.map { NSFileProviderItemIdentifier($0.rawValue) }
            if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
            observer.finishEnumeratingChanges(upTo: AnchorCoding.encode(page.newAnchor), moreComing: page.more)
        } catch {
            observer.finishEnumeratingWithError(ErrorMapping.map(error))
        }
    }
}

/// Children of a directory (or the root), keyset-paged by name.
final class DirectoryEnumerator: BaseEnumerator {
    let parent: ItemIdentifier

    init(context: ExtensionContext, parent: ItemIdentifier) {
        self.parent = parent
        super.init(context: context)
    }

    override func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        do {
            let result = try context.reader.children(of: parent, after: pageCursor(page), limit: pageLimit(observer))
            #if DEBUG
            FootprintProbe.file?.append("enumerateItems folder=\(context.folder.rawValue) parent=\(parent.rawValue) count=\(result.items.count) policies=\(Self.policySummary(result.items.map(context.item(for:))))")
            #endif
            observer.didEnumerate(result.items.map(context.item(for:)))
            observer.finishEnumerating(upTo: result.next.map { NSFileProviderPage(Data($0.utf8)) })
        } catch {
            observer.finishEnumeratingWithError(ErrorMapping.map(error))
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let parent = self.parent
        reportChanges(observer, from: anchor, workingSet: false) { $0.parentID == parent && $0.itemID != parent }
    }
}

#if DEBUG
extension DirectoryEnumerator {
    static func policySummary(_ items: [FileProviderItem]) -> String {
        guard #available(iOS 27.0, *) else { return "-" }
        let dirs = items.filter { $0.record.isDirectory }
        return dirs.map { "\($0.record.path.lastComponent):\($0.namespacePolicy.rawValue)" }.joined(separator: ",")
    }
}
#endif

/// Working set: pinned + pending + materialized (and their children) items
/// (+ local files in on-demand folders) — never the whole index.
final class WorkingSetEnumerator: BaseEnumerator {
    override func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        do {
            let result = try context.reader.workingSet(after: pageCursor(page), limit: pageLimit(observer))
            observer.didEnumerate(result.items.map(context.item(for:)))
            observer.finishEnumerating(upTo: result.next.map { NSFileProviderPage(Data($0.utf8)) })
        } catch {
            observer.finishEnumeratingWithError(ErrorMapping.map(error))
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        reportChanges(observer, from: anchor, workingSet: true) { _ in true }
    }
}

/// A single (file) item.
final class SingleItemEnumerator: BaseEnumerator {
    let id: ItemIdentifier

    init(context: ExtensionContext, id: ItemIdentifier) {
        self.id = id
        super.init(context: context)
    }

    override func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        do {
            if let record = try context.reader.item(id) { observer.didEnumerate([context.item(for: record)]) }
            observer.finishEnumerating(upTo: nil)
        } catch {
            observer.finishEnumeratingWithError(ErrorMapping.map(error))
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let id = self.id
        reportChanges(observer, from: anchor, workingSet: false) { $0.itemID == id }
    }
}
