import FileProvider
import Foundation
import PsyCore

final class ProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let domainIdentifier: String
    private let suppliedPaths: SharedContainerPaths?
    private let state = ProviderEnumeratorState()
    private let batchSize = 200
    private let changeBatchSize = 500

    init(container: NSFileProviderItemIdentifier, domainIdentifier: String, paths: SharedContainerPaths? = nil) {
        self.container = container
        self.domainIdentifier = domainIdentifier
        suppliedPaths = paths
    }

    func invalidate() {
        state.invalidate()
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let observer = EnumerationObserverBox(observer)
        guard state.isActive else {
            observer.fail(CocoaError(.userCancelled))
            return
        }

        // Folder configuration is intentionally kept in the compact shared snapshot. All
        // file-tree containers use the SQLite projection and keyset pages below.
        if container == .rootContainer,
            domainIdentifier == FileProviderDomainIdentity.legacyAggregateIdentifier
        {
            enumerateRoot(observer: observer, page: page)
            return
        }

        let operation = ProviderEnumeratorOperation {
            [container, domainIdentifier, suppliedPaths, state, batchSize] in
            guard state.isActive else {
                observer.fail(CocoaError(.userCancelled))
                return
            }
            do {
                let paths = try suppliedPaths ?? SharedContainerPaths.resolve()
                let snapshot = try ProviderSupport.snapshot(paths: paths)
                if try Self.enumerateShareWorkingSetPage(
                    container: container, domainIdentifier: domainIdentifier, snapshot: snapshot, page: page,
                    limit: batchSize, observer: observer)
                {
                    return
                }
                // An offset token was emitted by the canonical-snapshot backend.
                // Keep that backend for the rest of this generation even if the
                // derived index has recovered between page requests.
                if let pageValues = ProviderSupport.pageValues(page),
                    case .offset = pageValues.position
                {
                    try Self.enumerateSnapshotFallback(
                        container: container,
                        domainIdentifier: domainIdentifier,
                        snapshot: snapshot,
                        paths: paths,
                        page: page,
                        batchSize: batchSize,
                        observer: observer
                    )
                    return
                }
                let store = try IndexedMetadataStore(
                    databaseURL: paths.metadataIndex,
                    accessMode: .readOnly,
                    recoveryPolicy: .fail
                )
                guard try await store.currentGeneration() == snapshot.generation else {
                    try Self.enumerateSnapshotFallback(
                        container: container,
                        domainIdentifier: domainIdentifier,
                        snapshot: snapshot,
                        paths: paths,
                        page: page,
                        batchSize: batchSize,
                        observer: observer
                    )
                    return
                }

                let cursor = try await Self.cursor(
                    from: page,
                    expectedGeneration: ProviderSupport.metadataGeneration(snapshot),
                    container: container,
                    domainIdentifier: domainIdentifier,
                    snapshot: snapshot,
                    store: store
                )
                let result = try await Self.page(
                    for: container,
                    domainIdentifier: domainIdentifier,
                    snapshot: snapshot,
                    store: store,
                    cursor: cursor,
                    limit: batchSize
                )
                let providerItems = try Self.providerItems(
                    result.items,
                    snapshot: snapshot,
                    metadataDatabaseURL: paths.metadataIndex,
                    domainIdentifier: domainIdentifier
                )
                // The projection can commit another generation between the
                // preflight and the page query, and conversion above may overlap
                // a canonical snapshot update. Never label either state with the
                // older generation carried by this page token.
                let finalStoreGeneration = try await store.currentGeneration()
                guard finalStoreGeneration == snapshot.generation,
                    try ProviderSupport.snapshot(paths: paths).generation == snapshot.generation
                else {
                    observer.fail(ProviderSupport.providerError(.pageExpired))
                    return
                }
                guard state.isActive else {
                    observer.fail(CocoaError(.userCancelled))
                    return
                }
                observer.enumerate(providerItems)
                if result.nextCursor != nil, let lastItemID = result.items.last?.id {
                    guard
                        let next = ProviderSupport.itemPage(
                            generation: ProviderSupport.metadataGeneration(snapshot),
                            lastItemID: lastItemID
                        )
                    else {
                        observer.fail(ProviderSupport.providerError(.pageExpired))
                        return
                    }
                    observer.finish(nextPage: next)
                } else {
                    observer.finish(nextPage: nil)
                }
            } catch {
                // A missing/corrupt derived index may still have a full canonical JSON
                // snapshot available. Use it for continuity; otherwise return a retryable
                // provider error instead of presenting an empty folder as authoritative.
                do {
                    let paths = try suppliedPaths ?? SharedContainerPaths.resolve()
                    let snapshot = try ProviderSupport.snapshot(paths: paths)
                    try Self.enumerateSnapshotFallback(
                        container: container,
                        domainIdentifier: domainIdentifier,
                        snapshot: snapshot,
                        paths: paths,
                        page: page,
                        batchSize: batchSize,
                        observer: observer
                    )
                } catch {
                    observer.fail(Self.supported(error))
                }
            }
        }
        Task.detached(priority: .userInitiated) { await operation.run() }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        let observer = ChangeObserverBox(observer)
        guard state.isActive else {
            observer.fail(CocoaError(.userCancelled))
            return
        }
        guard let anchorValues = ProviderSupport.anchorValues(anchor) else {
            observer.fail(ProviderSupport.providerError(.syncAnchorExpired))
            return
        }

        let operation = ProviderEnumeratorOperation {
            [container, domainIdentifier, suppliedPaths, state, changeBatchSize] in
            guard state.isActive else {
                observer.fail(CocoaError(.userCancelled))
                return
            }
            do {
                let paths = try suppliedPaths ?? SharedContainerPaths.resolve()
                let snapshot = try ProviderSupport.snapshot(paths: paths)
                if container == .workingSet,
                    anchorValues.shareRevision != FileProviderShareCatalog.revision(for: snapshot.folders)
                {
                    observer.fail(ProviderSupport.providerError(.syncAnchorExpired))
                    return
                }
                guard anchorValues.generation <= snapshot.generation else {
                    observer.fail(ProviderSupport.providerError(.syncAnchorExpired))
                    return
                }

                // Folder creation/removal is a low-volume configuration change. Expiring the
                // root anchor lets Files reconcile both insertions and removals with a complete
                // folder page, rather than pretending we have folder tombstones in the item DB.
                if container == .rootContainer,
                    domainIdentifier == FileProviderDomainIdentity.legacyAggregateIdentifier
                {
                    if anchorValues.generation == snapshot.generation {
                        observer.finish(
                            anchor: ProviderSupport.anchor(
                                snapshot.generation,
                                shareRevision: FileProviderShareCatalog.revision(for: snapshot.folders)),
                            moreComing: false
                        )
                    } else {
                        observer.fail(ProviderSupport.providerError(.syncAnchorExpired))
                    }
                    return
                }

                let store = try IndexedMetadataStore(
                    databaseURL: paths.metadataIndex,
                    accessMode: .readOnly,
                    recoveryPolicy: .fail
                )
                guard
                    let scope = try await ProviderSupport.metadataScope(
                        for: container,
                        snapshot: snapshot,
                        paths: paths,
                        domainIdentifier: domainIdentifier
                    )
                else {
                    observer.fail(
                        ProviderSupport.providerError(.noSuchItem, itemIdentifier: container)
                    )
                    return
                }
                let validatedPage: IndexedMetadataValidatedChangeResult
                do {
                    validatedPage = try await store.validatedChanges(
                        sinceGeneration: anchorValues.generation,
                        after: anchorValues.cursor,
                        expectedCurrentGeneration: snapshot.generation,
                        limit: changeBatchSize
                    )
                } catch {
                    throw error
                }
                guard case .page(let page) = validatedPage else {
                    observer.fail(ProviderSupport.providerError(.syncAnchorExpired))
                    return
                }
                guard state.isActive else {
                    observer.fail(CocoaError(.userCancelled))
                    return
                }

                var updatedItemsByID: [String: IndexedItem] = [:]
                var deletedIDs = Set<NSFileProviderItemIdentifier>()
                for change in page.changes {
                    let identifier = ProviderSupport.itemIdentifier(change.itemID)
                    switch change.effect(in: scope) {
                    case .none:
                        break
                    case .update(let item):
                        // A delete followed by recreation can share one batch. Apply
                        // journal order so the observer receives only the final action.
                        deletedIDs.remove(identifier)
                        updatedItemsByID[item.id] = item
                    case .delete:
                        // Pathless tombstones remain domain-wide. didDelete is a no-op
                        // for unknown identifiers and preserves existing propagation.
                        updatedItemsByID.removeValue(forKey: change.itemID)
                        deletedIDs.insert(identifier)
                    }
                }
                if !updatedItemsByID.isEmpty {
                    observer.update(
                        try Self.providerItems(
                            Array(updatedItemsByID.values).sorted { $0.id < $1.id },
                            snapshot: snapshot,
                            metadataDatabaseURL: paths.metadataIndex,
                            domainIdentifier: domainIdentifier
                        )
                    )
                }
                if !deletedIDs.isEmpty {
                    observer.delete(deletedIDs.sorted { $0.rawValue < $1.rawValue })
                }

                if let cursor = page.nextCursor {
                    observer.finish(
                        anchor: ProviderSupport.anchor(
                            anchorValues.generation, cursor: cursor,
                            shareRevision: FileProviderShareCatalog.revision(for: snapshot.folders)),
                        moreComing: true
                    )
                } else {
                    observer.finish(
                        anchor: ProviderSupport.anchor(
                            snapshot.generation, shareRevision: FileProviderShareCatalog.revision(for: snapshot.folders)
                        ),
                        moreComing: false
                    )
                }
            } catch {
                observer.fail(Self.supported(error))
            }
        }
        Task.detached(priority: .utility) { await operation.run() }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let paths = try? suppliedPaths ?? SharedContainerPaths.resolve(),
            let snapshot = try? ProviderSupport.snapshot(paths: paths)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(
            ProviderSupport.anchor(
                snapshot.generation, shareRevision: FileProviderShareCatalog.revision(for: snapshot.folders)))
    }

    private func enumerateRoot(observer: EnumerationObserverBox, page: NSFileProviderPage) {
        do {
            let paths = try suppliedPaths ?? SharedContainerPaths.resolve()
            let snapshot = try ProviderSupport.snapshot(paths: paths)
            let offset: Int
            if let values = ProviderSupport.pageValues(page) {
                guard values.generation == ProviderSupport.metadataGeneration(snapshot),
                    case .offset(let rawOffset) = values.position,
                    let decoded = Int(exactly: rawOffset)
                else {
                    observer.fail(ProviderSupport.providerError(.pageExpired))
                    return
                }
                offset = decoded
            } else {
                offset = 0
            }
            let items: [NSFileProviderItem] = UniqueFolderIdentityIndex(snapshot.folders)
                .uniqueFolders
                .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
                .map { folder in
                    return ProviderItem(
                        folder: folder,
                        generation: ProviderSupport.metadataGeneration(snapshot),
                        displayName: FileProviderShareCatalog.names(for: snapshot.folders)[folder.id],
                        mutationAccess: FileProviderMutationAccess.evaluate(
                            folder: folder,
                            item: nil
                        )
                    )
                }
            guard offset <= items.count else {
                observer.fail(ProviderSupport.providerError(.pageExpired))
                return
            }
            let end = min(items.count, offset + batchSize)
            observer.enumerate(Array(items[offset..<end]))
            observer.finish(
                nextPage: end < items.count
                    ? ProviderSupport.page(
                        generation: ProviderSupport.metadataGeneration(snapshot), offset: UInt64(end))
                    : nil
            )
        } catch {
            observer.fail(Self.supported(error))
        }
    }

    private static func enumerateShareWorkingSetPage(
        container: NSFileProviderItemIdentifier, domainIdentifier: String,
        snapshot: CoreSnapshot, page: NSFileProviderPage, limit: Int,
        observer: EnumerationObserverBox
    ) throws -> Bool {
        guard container == .workingSet, domainIdentifier == FileProviderDomainIdentity.legacyAggregateIdentifier else {
            return false
        }
        let folders = UniqueFolderIdentityIndex(snapshot.folders).uniqueFolders.sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        guard folders.count == snapshot.folders.count else { throw ProviderSupport.providerError(.serverUnreachable) }
        let offset: Int
        if let values = ProviderSupport.pageValues(page) {
            guard values.generation == ProviderSupport.metadataGeneration(snapshot) else {
                throw ProviderSupport.providerError(.pageExpired)
            }
            guard case .shareOffset(let value) = values.position else { return false }
            guard let decoded = Int(exactly: value), decoded <= folders.count else {
                throw ProviderSupport.providerError(.pageExpired)
            }
            offset = decoded
        } else {
            offset = 0
        }
        guard offset < folders.count else { return false }
        let names = FileProviderShareCatalog.names(for: folders)
        let end = min(folders.count, offset + limit)
        observer.enumerate(
            folders[offset..<end].map { folder in
                ProviderItem(
                    folder: folder, generation: ProviderSupport.metadataGeneration(snapshot),
                    displayName: names[folder.id],
                    mutationAccess: FileProviderMutationAccess.evaluate(folder: folder, item: nil))
            })
        observer.finish(
            nextPage: ProviderSupport.sharePage(
                generation: ProviderSupport.metadataGeneration(snapshot), offset: UInt64(end)))
        return true
    }

    private static func cursor(
        from page: NSFileProviderPage,
        expectedGeneration: UInt64,
        container: NSFileProviderItemIdentifier,
        domainIdentifier: String,
        snapshot: CoreSnapshot,
        store: IndexedMetadataStore
    ) async throws -> IndexedItemPageCursor? {
        guard let values = ProviderSupport.pageValues(page) else { return nil }
        guard values.generation == expectedGeneration else {
            throw ProviderSupport.providerError(.pageExpired)
        }
        switch values.position {
        case .itemID(let itemID):
            guard let item = try await store.item(identifier: itemID),
                try await Self.item(
                    item,
                    belongsTo: container,
                    domainIdentifier: domainIdentifier,
                    snapshot: snapshot,
                    store: store
                )
            else {
                throw ProviderSupport.providerError(.pageExpired)
            }
            return IndexedItemPageCursor(relativePath: item.relativePath, itemID: item.id)
        case .shareOffset(let offset):
            guard container == .workingSet,
                domainIdentifier == FileProviderDomainIdentity.legacyAggregateIdentifier,
                offset == UInt64(snapshot.folders.count)
            else { throw ProviderSupport.providerError(.pageExpired) }
            return nil
        case .offset(let offset):
            guard offset == 0 else { throw ProviderSupport.providerError(.pageExpired) }
            return nil
        }
    }

    private static func item(
        _ item: IndexedItem,
        belongsTo container: NSFileProviderItemIdentifier,
        domainIdentifier: String,
        snapshot: CoreSnapshot,
        store: IndexedMetadataStore
    ) async throws -> Bool {
        guard
            let domainScope = ProviderSupport.domainScope(
                identifier: domainIdentifier,
                snapshot: snapshot
            ), domainScope.contains(item.folderID)
        else { return false }
        if container == .workingSet {
            return true
        }
        if container == .rootContainer, let folderID = domainScope.rootFolderID {
            return item.folderID == folderID && item.parentID == nil
        }
        if case .legacyAggregate = domainScope,
            let folder = ProviderSupport.folder(for: container, snapshot: snapshot)
        {
            return item.folderID == folder.id && item.parentID == nil
        }
        guard let parentID = ProviderSupport.rawItemID(container),
            item.parentID == parentID,
            let parent = try await store.item(identifier: parentID),
            parent.isDirectory
        else {
            return false
        }
        return item.folderID == parent.folderID
    }

    private static func page(
        for container: NSFileProviderItemIdentifier,
        domainIdentifier: String,
        snapshot: CoreSnapshot,
        store: IndexedMetadataStore,
        cursor: IndexedItemPageCursor?,
        limit: Int
    ) async throws -> IndexedItemPage {
        guard
            let domainScope = ProviderSupport.domainScope(
                identifier: domainIdentifier,
                snapshot: snapshot
            )
        else {
            throw ProviderSupport.providerError(.noSuchItem, itemIdentifier: container)
        }
        if container == .workingSet {
            return try await store.workingSet(
                inFolder: domainScope.rootFolderID,
                after: cursor,
                limit: limit
            )
        }
        if container == .rootContainer, let folderID = domainScope.rootFolderID {
            return try await store.children(
                inFolder: folderID,
                parentID: nil,
                after: cursor,
                limit: limit
            )
        }
        if case .legacyAggregate = domainScope,
            let folder = ProviderSupport.folder(for: container, snapshot: snapshot)
        {
            return try await store.children(
                inFolder: folder.id,
                parentID: nil,
                after: cursor,
                limit: limit
            )
        }
        guard let parentID = ProviderSupport.rawItemID(container),
            let parent = try await store.item(identifier: parentID),
            parent.isDirectory,
            domainScope.contains(parent.folderID)
        else {
            throw ProviderSupport.providerError(.noSuchItem, itemIdentifier: container)
        }
        return try await store.children(
            inFolder: parent.folderID,
            parentID: parentID,
            after: cursor,
            limit: limit
        )
    }

    private static func enumerateSnapshotFallback(
        container: NSFileProviderItemIdentifier,
        domainIdentifier: String,
        snapshot: CoreSnapshot,
        paths: SharedContainerPaths,
        page: NSFileProviderPage,
        batchSize: Int,
        observer: EnumerationObserverBox
    ) throws {
        let snapshot = try ProviderSupport.fullSnapshot(matching: snapshot, paths: paths)
        let position: ProviderPagePosition?
        if let values = ProviderSupport.pageValues(page) {
            guard values.generation == ProviderSupport.metadataGeneration(snapshot) else {
                throw ProviderSupport.providerError(.pageExpired)
            }
            position = values.position
        } else {
            position = nil
        }

        let retainedSnapshotItems = try ContentRetentionIntentResolver(
            metadataDatabaseURL: paths.metadataIndex
        ).applying(to: snapshot.items)
        guard
            let domainScope = ProviderSupport.domainScope(
                identifier: domainIdentifier,
                snapshot: snapshot
            )
        else {
            throw ProviderSupport.providerError(.noSuchItem, itemIdentifier: container)
        }
        let items: [IndexedItem]
        if container == .workingSet {
            items = retainedSnapshotItems.filter { domainScope.contains($0.folderID) }
        } else if container == .rootContainer, let folderID = domainScope.rootFolderID {
            items = retainedSnapshotItems.filter {
                $0.folderID == folderID && $0.parentID == nil
            }
        } else if case .legacyAggregate = domainScope,
            let folder = ProviderSupport.folder(for: container, snapshot: snapshot)
        {
            items = retainedSnapshotItems.filter { $0.folderID == folder.id && $0.parentID == nil }
        } else if let parentID = ProviderSupport.rawItemID(container),
            let parent = retainedSnapshotItems.first(where: {
                $0.id == parentID && $0.isDirectory && domainScope.contains($0.folderID)
            })
        {
            items = retainedSnapshotItems.filter {
                $0.folderID == parent.folderID && $0.parentID == parentID
            }
        } else {
            throw ProviderSupport.providerError(.noSuchItem, itemIdentifier: container)
        }

        let sorted = items.sorted(by: IndexedMetadataStore.binaryItemOrderPrecedes)
        let offset: Int
        switch position {
        case .shareOffset(let count):
            guard container == .workingSet, count == UInt64(snapshot.folders.count) else {
                throw ProviderSupport.providerError(.pageExpired)
            }
            offset = 0
        case .none:
            offset = 0
        case .offset(let rawOffset):
            guard let decoded = Int(exactly: rawOffset) else {
                throw ProviderSupport.providerError(.pageExpired)
            }
            offset = decoded
        case .itemID(let itemID):
            guard let index = sorted.firstIndex(where: { $0.id == itemID }) else {
                throw ProviderSupport.providerError(.pageExpired)
            }
            offset = sorted.index(after: index)
        }
        guard offset <= sorted.count else { throw ProviderSupport.providerError(.pageExpired) }
        let end = min(sorted.count, offset + batchSize)
        let providerItems = try providerItems(
            Array(sorted[offset..<end]),
            snapshot: snapshot,
            metadataDatabaseURL: paths.metadataIndex,
            domainIdentifier: domainIdentifier
        )
        guard try ProviderSupport.snapshot(paths: paths).generation == snapshot.generation else {
            throw ProviderSupport.providerError(.pageExpired)
        }
        observer.enumerate(providerItems)
        observer.finish(
            nextPage: end < sorted.count
                ? ProviderSupport.page(generation: ProviderSupport.metadataGeneration(snapshot), offset: UInt64(end))
                : nil
        )
    }

    private static func providerItems(
        _ items: [IndexedItem],
        snapshot: CoreSnapshot,
        metadataDatabaseURL: URL,
        domainIdentifier: String
    ) throws -> [ProviderItem] {
        guard
            let domainScope = ProviderSupport.domainScope(
                identifier: domainIdentifier,
                snapshot: snapshot
            )
        else { return [] }
        let resolver = ContentRetentionIntentResolver(
            metadataDatabaseURL: metadataDatabaseURL
        )
        let retained = try resolver.applying(to: items)
        let folderIndex = UniqueFolderIdentityIndex(snapshot.folders)
        return retained.filter { domainScope.contains($0.folderID) && folderIndex.folder($0.folderID) != nil }.map {
            item in
            let access: FileProviderMutationAccess
            if let folder = folderIndex.folder(item.folderID) {
                access = FileProviderMutationAccess.evaluate(
                    folder: folder,
                    item: item
                )
            } else {
                access = .readOnly
            }
            return ProviderItem(
                indexed: item,
                mutationAccess: access,
                rootFolderID: domainScope.rootFolderID
            )
        }
    }

    private static func supported(_ error: Error) -> Error {
        let value = error as NSError
        if value.domain == NSFileProviderErrorDomain || value.domain == NSCocoaErrorDomain { return error }
        return NSError(
            domain: NSCocoaErrorDomain,
            code: NSXPCConnectionReplyInvalid,
            userInfo: [NSUnderlyingErrorKey: value]
        )
    }
}

private final class ProviderEnumeratorState: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false

    var isActive: Bool {
        lock.withLock { !invalidated }
    }

    func invalidate() {
        lock.withLock { invalidated = true }
    }
}

private final class ProviderEnumeratorOperation: @unchecked Sendable {
    private let body: () async -> Void

    init(body: @escaping () async -> Void) {
        self.body = body
    }

    func run() async {
        await body()
    }
}

private final class EnumerationObserverBox: @unchecked Sendable {
    private let observer: NSFileProviderEnumerationObserver

    init(_ observer: NSFileProviderEnumerationObserver) {
        self.observer = observer
    }

    func enumerate<S: Sequence>(_ items: S) where S.Element == NSFileProviderItem {
        observer.didEnumerate(Array(items))
    }

    func finish(nextPage: NSFileProviderPage?) {
        observer.finishEnumerating(upTo: nextPage)
    }

    func fail(_ error: Error) {
        observer.finishEnumeratingWithError(error)
    }
}

private final class ChangeObserverBox: @unchecked Sendable {
    private let observer: NSFileProviderChangeObserver

    init(_ observer: NSFileProviderChangeObserver) {
        self.observer = observer
    }

    func update(_ items: [NSFileProviderItem]) {
        observer.didUpdate(items)
    }

    func delete(_ identifiers: [NSFileProviderItemIdentifier]) {
        observer.didDeleteItems(withIdentifiers: identifiers)
    }

    func finish(anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: moreComing)
    }

    func fail(_ error: Error) {
        observer.finishEnumeratingWithError(error)
    }
}
