import FileProvider
import PsySync
import UniformTypeIdentifiers
import os

/// Replicated File Provider extension for one managed folder (DESIGN.md §6).
///
/// - Metadata: read-only from `files.sqlite` (projected by the App).
/// - Contents: `LiveContentProvider` (localClone / delegatedToApp / restrictedFetch).
/// - Writes: performed directly in `Folders/<id>/`, journaled for the App's
///   targeted scan, signalled with `filesRequestPosted`.
/// - Never starts the full engine, never calls REST (I4).
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction {
    static let keepDownloadedAction = NSFileProviderExtensionActionIdentifier("app.psynguechthyngue.action.keep-downloaded")
    static let removeDownloadAction = NSFileProviderExtensionActionIdentifier("app.psynguechthyngue.action.remove-download")

    private let domain: NSFileProviderDomain
    private let contextResult: Result<ExtensionContext, Error>
    private let log = Logger(subsystem: FilesLog.subsystem, category: "extension")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        FootprintProbe.log("init-start")
        contextResult = Result { try ExtensionContext(domain: domain) }
        super.init()
        FootprintProbe.log("init-done")
        if case .failure(let error) = contextResult {
            log.fault("extension init failed: \(String(describing: error), privacy: .public)")
        }
    }

    func invalidate() {
        if case .success(let context) = contextResult { context.store.close() }
    }

    private func context() throws -> ExtensionContext {
        switch contextResult {
        case .success(let context): return context
        case .failure: throw NSFileProviderError(.notAuthenticated)
        }
    }

    // MARK: Items

    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        do {
            let context = try context()
            completionHandler(context.item(for: try context.record(identifier)), nil)
        } catch {
            completionHandler(nil, ErrorMapping.map(error))
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws
        -> NSFileProviderEnumerator
    {
        let context = try context()
        if containerItemIdentifier == .workingSet { return WorkingSetEnumerator(context: context) }
        let record = try context.record(containerItemIdentifier)
        return record.isDirectory
            ? DirectoryEnumerator(context: context, parent: record.itemID)
            : SingleItemEnumerator(context: context, id: record.itemID)
    }

    // MARK: Contents

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let completion = UncheckedBox(completionHandler)
        let progressBox = UncheckedBox(progress)
        let versionData = requestedVersion?.contentVersion
        let task = Task { [log] in
            do {
                FootprintProbe.log("fetch-start")
                defer { FootprintProbe.log("fetch-end") }
                let context = try self.context()
                let id = context.storeID(itemIdentifier)
                let result = try await context.content.provideContents(
                    for: id, requestedVersion: versionData, progress: progressBox.value)
                log.info("fetchContents id=\(itemIdentifier.rawValue, privacy: .public) source=\(String(describing: result.source), privacy: .public)")
                completion.value(result.url, context.item(for: result.record), nil)
            } catch {
                log.error("fetchContents id=\(itemIdentifier.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                completion.value(nil, nil, ErrorMapping.map(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: Writes

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
        options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        do {
            let context = try context()
            let parent = try context.record(itemTemplate.parentItemIdentifier)
            guard parent.isDirectory, !parent.isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
            let name = itemTemplate.filename
            guard PathContainment.isValidFilename(name) else { throw CocoaError(.fileWriteInvalidFileName) }
            let path = parent.path.appending(name)
            let isDirectory = itemTemplate.contentType == .folder || itemTemplate.contentType?.conforms(to: .directory) == true
            if itemTemplate.contentType == .symbolicLink { throw CocoaError(.featureUnsupported) }

            if let existing = try context.reader.item(at: path) {
                if options.contains(.mayAlreadyExist) {
                    log.info("createItem mayAlreadyExist → existing id=\(existing.itemID.rawValue, privacy: .public)")
                    completionHandler(context.item(for: existing), [], false, nil)
                    return Progress()
                }
                throw NSFileProviderError(.filenameCollision)
            }
            let target = try context.containment.url(for: path)
            let fm = FileManager.default
            if isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                if fm.fileExists(atPath: target.path(percentEncoded: false)) { throw NSFileProviderError(.filenameCollision) }
                try Self.atomicWrite(from: url, to: target, replacing: false)
            }
            if fields.contains(.contentModificationDate), let date = itemTemplate.contentModificationDate ?? nil {
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path(percentEncoded: false))
            }
            let attributes = try fm.attributesOfItem(atPath: target.path(percentEncoded: false))
            let record = try context.store.recordLocalWrite(
                context.folder, path: path, isDirectory: isDirectory,
                size: isDirectory ? 0 : (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modified: attributes[.modificationDate] as? Date ?? Date())
            try context.store.append(context.folder, kind: .created, path: path, previousPath: nil)
            DarwinNotifier.post(DarwinNotification.filesRequestPosted)
            log.info("createItem id=\(record.itemID.rawValue, privacy: .public) dir=\(isDirectory)")
            completionHandler(context.item(for: record), [], false, nil)
        } catch {
            log.error("createItem failed: \(String(describing: error), privacy: .public)")
            completionHandler(nil, [], false, ErrorMapping.map(error))
        }
        return Progress()
    }

    /// Only contents, filename and parent are acted on. Every other field
    /// (tags, favorite rank, lastUsedDate, xattrs, flags, dates without new
    /// contents) is accepted and ignored — never returned as still pending,
    /// which made the system call modifyItem in a loop (AUDIT §二 P0).
    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
        contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        log.info("modifyItem id=\(item.itemIdentifier.rawValue, privacy: .public) fields=\(changedFields.rawValue) contents=\(newContents != nil)")
        do {
            let context = try context()
            var record = try context.record(item.itemIdentifier)
            guard !record.isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
            let fm = FileManager.default

            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                let parent = changedFields.contains(.parentItemIdentifier)
                    ? try context.record(item.parentItemIdentifier) : try context.reader.item(record.parentID)
                guard let parent, parent.isDirectory, !record.path.isRoot else { throw CocoaError(.fileWriteNoPermission) }
                let name = changedFields.contains(.filename) ? item.filename : record.path.lastComponent
                guard PathContainment.isValidFilename(name) else { throw CocoaError(.fileWriteInvalidFileName) }
                let newPath = parent.path.appending(name)
                if newPath != record.path {
                    if let occupant = try context.reader.item(at: newPath), occupant.itemID != record.itemID {
                        throw NSFileProviderError(.filenameCollision)
                    }
                    let from = try context.containment.url(for: record.path)
                    let to = try context.containment.url(for: newPath)
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: from.path(percentEncoded: false)) {
                        try fm.moveItem(at: from, to: to)
                    }
                    let previous = record.path
                    _ = try context.store.moveIdentity(record.itemID, to: newPath, in: context.folder)
                    try context.store.append(context.folder, kind: .moved, path: newPath, previousPath: previous)
                    record = try context.record(item.itemIdentifier)
                }
            }

            if changedFields.contains(.contents), let newContents, !record.isDirectory {
                let target = try context.containment.url(for: record.path)
                try Self.atomicWrite(from: newContents, to: target, replacing: true)
                if changedFields.contains(.contentModificationDate), let date = item.contentModificationDate ?? nil {
                    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path(percentEncoded: false))
                }
                let attributes = try fm.attributesOfItem(atPath: target.path(percentEncoded: false))
                record = try context.store.recordLocalWrite(
                    context.folder, path: record.path, isDirectory: false,
                    size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                    modified: attributes[.modificationDate] as? Date ?? Date())
                try context.store.append(context.folder, kind: .modified, path: record.path, previousPath: nil)
            }

            DarwinNotifier.post(DarwinNotification.filesRequestPosted)
            log.info("modifyItem done id=\(item.itemIdentifier.rawValue, privacy: .public) stillPending=0")
            completionHandler(context.item(for: record), [], false, nil)
        } catch {
            log.error("modifyItem failed: \(String(describing: error), privacy: .public)")
            completionHandler(nil, [], false, ErrorMapping.map(error))
        }
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        do {
            let context = try context()
            guard let record = try context.reader.item(context.storeID(identifier)) else {
                completionHandler(nil)  // already gone
                return Progress()
            }
            guard !record.isReadOnly, !record.path.isRoot else { throw CocoaError(.fileWriteNoPermission) }
            if record.isDirectory, !options.contains(.recursive),
                !(try context.reader.children(of: record.itemID, after: nil, limit: 1).items.isEmpty)
            {
                throw NSFileProviderError(.directoryNotEmpty)
            }
            let target = try context.containment.url(for: record.path)
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: target)
            }
            try context.store.recordLocalDelete(record.itemID)
            try context.store.append(context.folder, kind: .deleted, path: record.path, previousPath: nil)
            DarwinNotifier.post(DarwinNotification.filesRequestPosted)
            log.info("deleteItem id=\(identifier.rawValue, privacy: .public)")
            completionHandler(nil)
        } catch {
            log.error("deleteItem failed: \(String(describing: error), privacy: .public)")
            completionHandler(ErrorMapping.map(error))
        }
        return Progress()
    }

    /// Copies `source` next to `target` then renames over it (atomic for readers).
    static func atomicWrite(from source: URL?, to target: URL, replacing: Bool) throws {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Hidden temp name that Syncthing ignores (".syncthing.*.tmp").
        let temp = directory.appending(path: ".syncthing.psy-\(UUID().uuidString).tmp")
        if let source {
            if clonefile(source.path(percentEncoded: false), temp.path(percentEncoded: false), 0) != 0 {
                try fm.copyItem(at: source, to: temp)
            }
        } else {
            fm.createFile(atPath: temp.path(percentEncoded: false), contents: Data())
        }
        if !replacing && fm.fileExists(atPath: target.path(percentEncoded: false)) {
            try? fm.removeItem(at: temp)
            throw NSFileProviderError(.filenameCollision)
        }
        guard rename(temp.path(percentEncoded: false), target.path(percentEncoded: false)) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    // MARK: Materialized set → working set

    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        guard let context = try? context(), let manager = context.manager else {
            completionHandler()
            return
        }
        let collector = MaterializedCollector(context: context) { [log] ids in
            do {
                try context.store.setMaterialized(context.folder, ids: ids)
                log.info("materialized set updated count=\(ids.count)")
            } catch {
                log.error("materialized update failed: \(String(describing: error), privacy: .public)")
            }
            completionHandler()
        }
        collector.run(manager.enumeratorForMaterializedItems())
    }

    // MARK: Custom actions (Keep Downloaded / Remove Download)

    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        do {
            let context = try context()
            let keep = actionIdentifier == Self.keepDownloadedAction
            for identifier in itemIdentifiers {
                let record = try context.record(identifier)
                _ = try context.store.setPinned(record.itemID, pinned: keep)
                try context.store.requestPresence(context.folder, path: record.path, present: keep)
            }
            DarwinNotifier.post(DarwinNotification.filesRequestPosted)
            context.manager?.signalEnumerator(for: .workingSet) { _ in }
            completionHandler(nil)
        } catch {
            completionHandler(ErrorMapping.map(error))
        }
        return Progress()
    }
}

// The framework calls the extension from arbitrary queues; all state is
// immutable or internally synchronised (FilesStore, LiveContentProvider).
extension FileProviderExtension: @unchecked Sendable {}

/// Drains `enumeratorForMaterializedItems` into a list of store ids.
private final class MaterializedCollector: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let context: ExtensionContext
    private let done: ([ItemIdentifier]) -> Void
    private var ids: [ItemIdentifier] = []
    private var enumerator: NSFileProviderEnumerator?

    init(context: ExtensionContext, done: @escaping ([ItemIdentifier]) -> Void) {
        self.context = context
        self.done = done
    }

    func run(_ enumerator: NSFileProviderEnumerator) {
        self.enumerator = enumerator
        enumerator.enumerateItems(for: self, startingAt: NSFileProviderPage.initialPageSortedByName as NSFileProviderPage)
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
        ids += updatedItems.map { context.storeID($0.itemIdentifier) }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage {
            enumerator?.enumerateItems(for: self, startingAt: nextPage)
        } else {
            finish()
        }
    }

    func finishEnumeratingWithError(_ error: Error) { finish() }

    private func finish() {
        enumerator?.invalidate()
        enumerator = nil
        done(ids)
    }
}

/// Moves non-Sendable framework values into a Task (they are used from one task only).
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
