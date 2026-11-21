@preconcurrency import FileProvider
import Foundation
import PsyCore

enum FileProviderWorkingSetSignalResult: Equatable, Sendable {
    case noPendingRequest
    case signaled
    case deferred
    case stateUnavailable
}

enum FileProviderDomainStatus: Equatable, Sendable {
    case checking
    case enabled
    case noShares
    case disabled
    case notInstalled
    case unavailable
}

@MainActor
enum FileProviderDomainManager {
    nonisolated static let aggregateDomainIdentifier = NSFileProviderDomainIdentifier(
        FileProviderDomainIdentity.legacyAggregateIdentifier
    )

    /// Installs one user-visible provider domain whose root enumerates each
    /// current share as a separate folder entry. iOS groups multiple domains
    /// under one provider location and does not expose a reliable per-domain
    /// sidebar entry, so the aggregate root is the only directly reachable
    /// multi-share UX. Obsolete per-share domains are migration state and are
    /// removed only after the aggregate replacement is installed.
    static func reconcileDomains(snapshot: CoreSnapshot) async {
        // A default `CoreSnapshot()` is also the AppModel's pre-bootstrap and
        // startup-failure state. Never interpret it as an authoritative empty
        // configuration and remove an already installed Files location.
        guard snapshot.localDeviceID != nil else { return }
        let folders = UniqueFolderIdentityIndex(snapshot.folders).uniqueFolders
        guard folders.count == snapshot.folders.count else { return }
        do {
            let domains = try await NSFileProviderManager.domains()
            if !folders.isEmpty {
                let domain = NSFileProviderDomain(
                    identifier: aggregateDomainIdentifier,
                    displayName: "Psynguechthyngue"
                )
                try await NSFileProviderManager.add(domain)
            }

            for existing in domains
            where
                existing.identifier.rawValue.hasPrefix(FileProviderDomainIdentity.sharePrefix)
                || (folders.isEmpty && existing.identifier == aggregateDomainIdentifier)
            {
                do {
                    try await NSFileProviderManager.remove(existing)
                } catch {
                    // A domain currently displayed by Files can reject removal.
                    // Continue migrating its siblings and retry this exact
                    // domain on the next foreground/app-launch opportunity.
                    continue
                }
            }
        } catch {
            // The UI exposes the shared-container/extension error on refresh;
            // domain installation remains retryable on the next app launch.
        }
        // Installation and every later launch are retry opportunities for a
        // durable request left behind while the domain was missing or disabled.
        _ = await signalWorkingSetChanges()
    }

    static func installDomainIfNeeded() async {
        let snapshot =
            (try? SharedContainerPaths.resolve()).flatMap {
                try? SharedSnapshotStore(snapshotURL: $0.snapshot).read()
            } ?? CoreSnapshot()
        await reconcileDomains(snapshot: snapshot)
    }

    static func status(snapshot: CoreSnapshot) async -> FileProviderDomainStatus {
        guard snapshot.localDeviceID != nil else { return .checking }
        let folders = UniqueFolderIdentityIndex(snapshot.folders).uniqueFolders
        guard folders.count == snapshot.folders.count else { return .unavailable }
        guard !folders.isEmpty else { return .noShares }
        let domains: [NSFileProviderDomain]
        do {
            domains = try await NSFileProviderManager.domains()
        } catch {
            return .unavailable
        }
        guard let domain = domains.first(where: { $0.identifier == aggregateDomainIdentifier }) else {
            return .notInstalled
        }
        guard domain.userEnabled else { return .disabled }
        guard NSFileProviderManager(for: domain) != nil else { return .unavailable }
        return .enabled
    }

    static func evictItemFromSystemCache(folderID: FolderID, itemID: String) async throws {
        let manager = try await enabledManager(for: folderID)
        let identifier = NSFileProviderItemIdentifier("item-\(itemID)")
        do {
            try await manager.evictItem(identifier: identifier)
        } catch {
            throw FileProviderStorageActionError.systemError(error)
        }
    }

    static func requestDownload(folderID: FolderID, itemID: String) async throws {
        let manager = try await enabledManager(for: folderID)
        do {
            try await manager.requestDownloadForItem(
                withIdentifier: NSFileProviderItemIdentifier("item-\(itemID)")
            )
        } catch {
            throw FileProviderStorageActionError.systemError(error)
        }
    }

    static func isItemMaterialized(folderID: FolderID, itemID: String) async throws -> Bool {
        _ = try await enabledManager(for: folderID)
        let identifiers = try await materializedItemIdentifiers()
        return identifiers.contains(NSFileProviderItemIdentifier("item-\(itemID)"))
    }

    static func materializedItemIdentifiers() async throws -> Set<NSFileProviderItemIdentifier> {
        let domains: [NSFileProviderDomain]
        do {
            domains = try await NSFileProviderManager.domains()
        } catch {
            throw FileProviderStorageActionError.domainUnavailable
        }
        guard let domain = domains.first(where: { $0.identifier == aggregateDomainIdentifier }) else {
            throw FileProviderStorageActionError.domainNotInstalled
        }
        guard domain.userEnabled else {
            throw FileProviderStorageActionError.domainDisabled
        }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw FileProviderStorageActionError.domainUnavailable
        }
        return try await AppMaterializedItemSetCollector.collect(
            from: manager.enumeratorForMaterializedItems()
        )
    }

    private static func enabledManager(for folderID: FolderID) async throws -> NSFileProviderManager {
        guard
            let paths = try? SharedContainerPaths.resolve(),
            let snapshot = try? SharedSnapshotStore(snapshotURL: paths.snapshot).read(),
            UniqueFolderIdentityIndex(snapshot.folders).folder(folderID) != nil
        else {
            throw FileProviderStorageActionError.domainNotInstalled
        }
        let domains: [NSFileProviderDomain]
        do {
            domains = try await NSFileProviderManager.domains()
        } catch {
            throw FileProviderStorageActionError.domainUnavailable
        }
        guard let domain = domains.first(where: { $0.identifier == aggregateDomainIdentifier }) else {
            throw FileProviderStorageActionError.domainNotInstalled
        }
        guard domain.userEnabled else {
            throw FileProviderStorageActionError.domainDisabled
        }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw FileProviderStorageActionError.domainUnavailable
        }
        return manager
    }

    static func userVisibleURL(folderID: FolderID, itemID: String) async throws -> URL {
        let domains: [NSFileProviderDomain]
        do {
            domains = try await NSFileProviderManager.domains()
        } catch {
            throw FileProviderRevealError.domainUnavailable
        }
        guard let domain = domains.first(where: { $0.identifier == aggregateDomainIdentifier }) else {
            throw FileProviderRevealError.domainNotInstalled
        }
        guard domain.userEnabled else {
            throw FileProviderRevealError.domainDisabled
        }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw FileProviderRevealError.domainUnavailable
        }

        do {
            return try await manager.getUserVisibleURL(
                for: NSFileProviderItemIdentifier("item-\(itemID)")
            )
        } catch {
            throw FileProviderRevealError.systemError(error)
        }
    }

    /// Persists the greatest snapshot generation before asking the replicated
    /// File Provider domain to enumerate its working set. A failed system call
    /// leaves that request durable. Successful delivery acknowledges only the
    /// generation actually sent, preserving a newer concurrent request.
    nonisolated static func signalWorkingSetChanges(
        snapshotGeneration: UInt64? = nil
    ) async -> FileProviderWorkingSetSignalResult {
        let paths: SharedContainerPaths
        do {
            paths = try SharedContainerPaths.resolve()
        } catch {
            return .stateUnavailable
        }
        let store = WorkingSetSignalStore(url: paths.workingSetSignalState)

        var pendingGeneration: UInt64?
        do {
            pendingGeneration = try store.pending()
        } catch {
            return .stateUnavailable
        }

        var generationToRequest = snapshotGeneration
        if generationToRequest == nil {
            do {
                generationToRequest = try SharedSnapshotStore(snapshotURL: paths.snapshot).read()?.generation
            } catch {
                // A previously persisted request can still be delivered even if
                // the newest snapshot is temporarily unreadable.
                if pendingGeneration == nil { return .stateUnavailable }
            }
        }
        if let generationToRequest {
            do {
                pendingGeneration = try store.request(generation: generationToRequest)
            } catch {
                return .stateUnavailable
            }
        }
        guard let generationBeingSent = pendingGeneration else { return .noPendingRequest }

        do {
            let snapshot = try SharedSnapshotStore(snapshotURL: paths.snapshot).read() ?? CoreSnapshot()
            let folders = UniqueFolderIdentityIndex(snapshot.folders).uniqueFolders
            guard folders.count == snapshot.folders.count else { return .deferred }
            if !folders.isEmpty {
                let domains = try await NSFileProviderManager.domains()
                guard
                    let domain = domains.first(where: {
                        $0.identifier == aggregateDomainIdentifier
                    }),
                    domain.userEnabled,
                    let manager = NSFileProviderManager(for: domain)
                else {
                    return .deferred
                }
                try await manager.signalEnumerator(for: .workingSet)
                // Clear legacy terminal errors only after publishing current
                // authoritative metadata. Every retry still rechecks policy,
                // item versions and the exact folder incarnation.
                try? await manager.signalErrorResolved(
                    NSError(
                        domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.cannotSynchronize.rawValue))
                try? await manager.signalErrorResolved(
                    NSError(
                        domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.serverUnreachable.rawValue))
            }
        } catch {
            return .deferred
        }

        do {
            return try store.acknowledge(upTo: generationBeingSent) == nil
                ? .signaled
                : .deferred
        } catch {
            // The system accepted the signal, but retrying is safer than losing
            // durable intent when acknowledgement persistence fails.
            return .deferred
        }
    }
}

enum FileProviderRevealError: Error, LocalizedError, Sendable {
    case metadataUnavailable
    case itemNotFound
    case itemChanged
    case domainNotInstalled
    case domainDisabled
    case domainUnavailable
    case permissionDenied
    case systemRejected(domain: String, code: Int)
    case openRejected

    var errorDescription: String? {
        switch self {
        case .metadataUnavailable:
            String(
                localized:
                    "The current indexed metadata could not be verified, so the Files location was not opened."
            )
        case .itemNotFound:
            String(localized: "The requested item is no longer present in the current global index.")
        case .itemChanged:
            String(localized: "The indexed item changed. Refresh the index before opening it in Files.")
        case .domainNotInstalled:
            String(
                localized:
                    "The Files location is not installed. Open the app and try again after the location appears in Files."
            )
        case .domainDisabled:
            String(localized: "This share location is disabled. Enable it under Browse in the Files app.")
        case .domainUnavailable:
            String(localized: "The Files location is currently unavailable and was not opened.")
        case .permissionDenied:
            String(localized: "iOS denied permission to open this item in Files.")
        case .systemRejected(let domain, let code):
            String(localized: "iOS rejected the Files open request (\(domain), code \(code)).")
        case .openRejected:
            String(localized: "The Files location could not be opened.")
        }
    }

    fileprivate static func systemError(_ error: Error) -> FileProviderRevealError {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain,
            value.code == CocoaError.fileReadNoPermission.rawValue
                || value.code == CocoaError.fileWriteNoPermission.rawValue
        {
            return .permissionDenied
        }
        if value.domain == NSPOSIXErrorDomain,
            value.code == Int(POSIXErrorCode.EACCES.rawValue)
                || value.code == Int(POSIXErrorCode.EPERM.rawValue)
        {
            return .permissionDenied
        }
        let domain = value.domain == NSFileProviderErrorDomain ? "file_provider" : "system"
        return .systemRejected(domain: domain, code: value.code)
    }
}

enum FileProviderStorageActionError: Error, LocalizedError, Sendable {
    case metadataUnavailable
    case itemNotFound
    case policyDenied(PolicyBlockReason?)
    case domainNotInstalled
    case domainDisabled
    case domainUnavailable
    case unsyncedEdits
    case nonEvictable
    case nonEvictableChildren
    case itemBusy
    case multipleHardLinks
    case permissionDenied
    case coreFinalizationFailed
    case systemRejected(domain: String, code: Int)

    var errorCode: String {
        switch self {
        case .metadataUnavailable: "metadata_unavailable"
        case .itemNotFound: "item_not_found"
        case .policyDenied(let reason): "policy_\(reason?.rawValue ?? "denied")"
        case .domainNotInstalled: "file_provider_domain_not_installed"
        case .domainDisabled: "file_provider_domain_disabled"
        case .domainUnavailable: "file_provider_domain_unavailable"
        case .unsyncedEdits: "file_provider_unsynced_edits"
        case .nonEvictable: "file_provider_non_evictable"
        case .nonEvictableChildren: "file_provider_non_evictable_children"
        case .itemBusy: "file_provider_item_busy"
        case .multipleHardLinks: "file_provider_multiple_hard_links"
        case .permissionDenied: "file_provider_permission_denied"
        case .coreFinalizationFailed: "core_eviction_finalization_failed"
        case .systemRejected(let domain, let code): "system_\(domain)_\(code)"
        }
    }

    var errorDescription: String? {
        switch self {
        case .metadataUnavailable:
            String(localized: "The current indexed metadata could not be verified, so no cache copy was removed.")
        case .itemNotFound:
            String(localized: "The requested item is not in the current global index.")
        case .policyDenied(let reason):
            String(localized: "The Files cache eviction was blocked by policy: \(reason?.rawValue ?? "unknown").")
        case .domainNotInstalled:
            String(
                localized:
                    "The Files location is not installed. Open the app and try again after the location appears in Files."
            )
        case .domainDisabled:
            String(localized: "This share location is disabled. Enable it under Browse in the Files app.")
        case .domainUnavailable:
            String(localized: "The Files location is currently unavailable. No cache copy was removed.")
        case .unsyncedEdits:
            String(localized: "iOS refused to remove the Files cache copy because it contains unsynced edits.")
        case .nonEvictable:
            String(localized: "iOS reported that this Files cache item is not evictable.")
        case .nonEvictableChildren:
            String(localized: "iOS found a protected child item and did not fully evict this folder.")
        case .itemBusy:
            String(localized: "The Files cache item is open or busy. Close it and try again.")
        case .multipleHardLinks:
            String(localized: "iOS refused to evict the Files cache item because it has multiple hard links.")
        case .permissionDenied:
            String(localized: "iOS denied permission to remove the Files cache copy.")
        case .coreFinalizationFailed:
            String(
                localized:
                    "The Files cache was removed, but the embedded core has not yet finalized local source removal. The recoverable transaction will retry."
            )
        case .systemRejected(let domain, let code):
            String(localized: "iOS rejected the Files cache eviction (\(domain), code \(code)).")
        }
    }

    fileprivate static func systemError(_ error: Error) -> FileProviderStorageActionError {
        let value = error as NSError
        if value.domain == NSFileProviderErrorDomain {
            switch value.code {
            case -2006: return .nonEvictableChildren
            case -2007: return .unsyncedEdits
            case -2008: return .nonEvictable
            default: return .systemRejected(domain: "file_provider", code: value.code)
            }
        }
        if value.domain == NSPOSIXErrorDomain {
            switch value.code {
            case Int(POSIXErrorCode.EBUSY.rawValue): return .itemBusy
            case Int(POSIXErrorCode.EMLINK.rawValue): return .multipleHardLinks
            case Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue):
                return .permissionDenied
            default: return .systemRejected(domain: "posix", code: value.code)
            }
        }
        if value.domain == NSCocoaErrorDomain,
            value.code == CocoaError.fileWriteNoPermission.rawValue
                || value.code == CocoaError.fileReadNoPermission.rawValue
        {
            return .permissionDenied
        }
        return .systemRejected(domain: "system", code: value.code)
    }
}

enum CurrentIndexedItemLoader {
    static func load(
        itemID: String,
        paths: SharedContainerPaths
    ) async throws -> IndexedItem {
        let snapshot: CoreSnapshot
        do {
            guard let current = try SharedSnapshotStore(snapshotURL: paths.snapshot).read() else {
                throw FileProviderStorageActionError.metadataUnavailable
            }
            snapshot = current
        } catch let error as FileProviderStorageActionError {
            throw error
        } catch {
            throw FileProviderStorageActionError.metadataUnavailable
        }

        // Storage actions are safety-sensitive and the JSON snapshot is the
        // canonical state. SQLite is only a rebuildable query projection; a
        // same-generation but logically damaged row must never authorize an
        // eviction, download, reveal, or propagating deletion.
        let matches = snapshot.items.filter { $0.id == itemID }
        guard matches.count == 1, let base = matches.first,
            UniqueFolderIdentityIndex(snapshot.folders).folder(base.folderID) != nil
        else {
            throw FileProviderStorageActionError.itemNotFound
        }
        do {
            let projected = try ContentRetentionIntentResolver(
                metadataDatabaseURL: paths.metadataIndex
            ).applying(to: base)
            guard try SharedSnapshotStore(snapshotURL: paths.snapshot).read() == snapshot else {
                throw FileProviderStorageActionError.metadataUnavailable
            }
            return projected
        } catch let error as FileProviderStorageActionError {
            throw error
        } catch {
            throw FileProviderStorageActionError.metadataUnavailable
        }
    }
}

struct FileProviderStorageActionService: Sendable {
    enum Result: Sendable {
        case retained(IndexedItem)
        case waitingForUpload(IndexedItem)
        case evicted(IndexedItem)
        case systemEvictedAwaitingCoreFinalization(IndexedItem)
        case directorySummary(
            directory: IndexedItem,
            removed: Int,
            waitingForUpload: Int,
            failed: Int
        )
    }

    func download(itemID: String) async throws -> IndexedItem {
        let paths = try SharedContainerPaths.resolve()
        let item = try await CurrentIndexedItemLoader.load(itemID: itemID, paths: paths)
        try await FileProviderDomainManager.requestDownload(folderID: item.folderID, itemID: item.id)
        return item
    }

    /// Uses one granted App/BG/Intent opportunity to advance a bounded set of
    /// durable retention intents. The metadata index supplies current exact
    /// versions; the retention store remains the only intent authority.
    func reconcilePendingWork(
        trigger: SyncTrigger,
        maximumItems: Int = 32
    ) async -> Bool {
        guard maximumItems > 0, let paths = try? SharedContainerPaths.resolve() else {
            return false
        }
        let page: IndexedItemPage
        let projected: [IndexedItem]
        let statuses: [String: ContentRetentionStatus]
        do {
            let metadata = try IndexedMetadataStore(
                databaseURL: paths.metadataIndex,
                accessMode: .readOnly,
                recoveryPolicy: .fail
            )
            let retentionStore = ContentRetentionStore(url: paths.contentRetention)
            page = try await metadata.allItems(
                after: retentionStore.backgroundScanCursor(),
                limit: min(IndexedMetadataStore.maximumPageSize, maximumItems)
            )
            try retentionStore.advanceBackgroundScanCursor(to: page.nextCursor)
            let resolver = ContentRetentionIntentResolver(
                metadataDatabaseURL: paths.metadataIndex
            )
            projected = try resolver.applying(to: page.items)
            let incarnations = Dictionary(
                uniqueKeysWithValues: try FolderIncarnationStore(
                    url: paths.folderIncarnations
                ).snapshot().records.map { ($0.folderID, $0.folderIncarnationDigest) }
            )
            statuses = try ContentRetentionStore(url: paths.contentRetention).statuses(
                for: projected,
                folderIncarnations: incarnations
            )
        } catch {
            return false
        }

        var succeeded = true
        for item in projected where !Task.isCancelled {
            guard !item.isDirectory, let status = statuses[item.id] else { continue }
            if status.pendingEvict {
                do {
                    _ = try await evictItem(itemID: item.id, trigger: trigger)
                } catch {
                    succeeded = false
                }
            } else if status.isPinned {
                do {
                    _ = try await ensureDownloadedForCurrentRetentionIntent(
                        itemID: item.id,
                        trigger: trigger
                    )
                } catch {
                    // Offline or policy-denied pins remain durable for a later
                    // opportunity; that is an incomplete run, not lost intent.
                    succeeded = false
                }
            }
        }

        do {
            let retentionStore = ContentRetentionStore(url: paths.contentRetention)
            let intents = try retentionStore.directoryEvictionIntents()
            if !intents.isEmpty {
                let metadata = try IndexedMetadataStore(
                    databaseURL: paths.metadataIndex,
                    accessMode: .readOnly,
                    recoveryPolicy: .fail
                )
                let policy = try SyncPolicyStore(url: paths.policy).load()
                for intent in intents.prefix(maximumItems) where !Task.isCancelled {
                    _ = try await processDirectoryEviction(
                        intent,
                        metadata: metadata,
                        policy: policy,
                        paths: paths,
                        trigger: trigger,
                        maximumPages: 1
                    )
                }
            }
        } catch {
            succeeded = false
        }

        do {
            let transactions = try ContentRetentionStore(url: paths.contentRetention)
                .pendingTransactions()
            let materialized =
                transactions.isEmpty
                ? Set<NSFileProviderItemIdentifier>()
                : try await FileProviderDomainManager.materializedItemIdentifiers()
            for transaction in transactions.prefix(maximumItems) where !Task.isCancelled {
                let retention = ContentRetentionStore(url: paths.contentRetention)
                guard try retention.coreEvictionIsRequested(transactionID: transaction.id) else {
                    try retention.completeEviction(transactionID: transaction.id)
                    continue
                }
                switch transaction.phase {
                case .prepared, .systemAccepted:
                    do {
                        if materialized.contains(
                            NSFileProviderItemIdentifier("item-\(transaction.itemID)")
                        ) {
                            _ = try await evictItem(itemID: transaction.itemID, trigger: trigger)
                        } else {
                            let store = ContentRetentionStore(url: paths.contentRetention)
                            try store.advanceEviction(
                                transactionID: transaction.id,
                                to: .contentRemoved
                            )
                            if !(try await finalizeCoreEviction(
                                transaction,
                                paths: paths,
                                trigger: trigger
                            )) {
                                succeeded = false
                            }
                        }
                    } catch {
                        succeeded = false
                    }
                case .contentRemoved:
                    if !(try await finalizeCoreEviction(transaction, paths: paths, trigger: trigger)) {
                        succeeded = false
                    }
                }
            }
        } catch {
            succeeded = false
        }
        return succeeded && !Task.isCancelled
    }

    func evictItem(itemID: String, trigger: SyncTrigger) async throws -> Result {
        let paths = try SharedContainerPaths.resolve()
        let loaded: (IndexedItem, SyncPolicy, String, String)
        do {
            loaded = try await Task.detached(priority: .userInitiated) {
                let item = try await CurrentIndexedItemLoader.load(itemID: itemID, paths: paths)
                let policy = try SyncPolicyStore(url: paths.policy).load()
                let incarnation = try FolderIncarnationStore(url: paths.folderIncarnations)
                    .policyContext(for: item.folderID).folderIncarnationDigest
                guard
                    let revision = try SharedSnapshotStore(snapshotURL: paths.snapshot)
                        .read()?.configurationRevision,
                    Self.isCanonicalRevision(revision)
                else {
                    throw FileProviderStorageActionError.metadataUnavailable
                }
                return (item, policy, incarnation, revision)
            }.value
        } catch let error as FileProviderStorageActionError {
            throw error
        } catch {
            throw FileProviderStorageActionError.metadataUnavailable
        }

        let item = loaded.0
        if item.isDirectory {
            return try await evictDirectory(
                item,
                policy: loaded.1,
                folderIncarnationDigest: loaded.2,
                paths: paths,
                trigger: trigger,
                configurationRevision: loaded.3
            )
        }
        return try await evictRegularItem(
            item,
            policy: loaded.1,
            folderIncarnationDigest: loaded.2,
            paths: paths,
            trigger: trigger,
            configurationRevision: loaded.3
        )
    }

    private func evictDirectory(
        _ directory: IndexedItem,
        policy: SyncPolicy,
        folderIncarnationDigest: String,
        paths: SharedContainerPaths,
        trigger: SyncTrigger,
        configurationRevision: String
    ) async throws -> Result {
        let retentionStore = ContentRetentionStore(url: paths.contentRetention)
        let metadata: IndexedMetadataStore
        var intent: ContentDirectoryEvictionIntent
        do {
            metadata = try IndexedMetadataStore(
                databaseURL: paths.metadataIndex,
                accessMode: .readOnly,
                recoveryPolicy: .fail
            )
            guard let generation = try await metadata.currentGeneration() else {
                throw FileProviderStorageActionError.metadataUnavailable
            }
            intent = try retentionStore.beginDirectoryEviction(
                itemID: directory.id,
                folderID: directory.folderID,
                relativePath: directory.relativePath,
                folderIncarnationDigest: folderIncarnationDigest,
                configurationRevision: configurationRevision,
                indexGeneration: generation
            )
        } catch {
            throw FileProviderStorageActionError.metadataUnavailable
        }
        let counts = try await processDirectoryEviction(
            intent,
            metadata: metadata,
            policy: policy,
            paths: paths,
            trigger: trigger
        )
        return .directorySummary(
            directory: directory,
            removed: counts.removed,
            waitingForUpload: counts.waiting,
            failed: counts.failed
        )
    }

    private func processDirectoryEviction(
        _ initialIntent: ContentDirectoryEvictionIntent,
        metadata: IndexedMetadataStore,
        policy: SyncPolicy,
        paths: SharedContainerPaths,
        trigger: SyncTrigger,
        maximumPages: Int = .max
    ) async throws -> (removed: Int, waiting: Int, failed: Int) {
        let retentionStore = ContentRetentionStore(url: paths.contentRetention)
        let resolver = ContentRetentionIntentResolver(
            metadataDatabaseURL: paths.metadataIndex
        )
        let normalized = normalizedSelectionPath(initialIntent.relativePath)
        var intent = initialIntent
        var removed = 0
        var waiting = 0
        var failed = 0
        var pages = 0
        while pages < maximumPages {
            try Task.checkCancellation()
            guard let generation = try await metadata.currentGeneration() else {
                throw FileProviderStorageActionError.metadataUnavailable
            }
            if generation != intent.indexGeneration {
                guard
                    let restarted = try retentionStore.restartDirectoryEviction(
                        intentID: intent.id,
                        indexGeneration: generation
                    )
                else { break }
                intent = restarted
            }
            let page = try await metadata.items(
                inFolder: intent.folderID,
                after: intent.cursor,
                limit: IndexedMetadataStore.maximumPageSize
            )
            let candidates = try resolver.applying(to: page.items).filter {
                !$0.isDirectory
                    && selectionPath(
                        normalizedSelectionPath($0.relativePath),
                        isDescendantOf: normalized
                    )
                    && ($0.availability == .local || $0.availability == .uploading)
            }
            for item in candidates {
                do {
                    switch try await evictRegularItem(
                        item,
                        policy: policy,
                        folderIncarnationDigest: intent.folderIncarnationDigest,
                        paths: paths,
                        trigger: trigger,
                        configurationRevision: intent.configurationRevision,
                        preservingCurrentPin: true
                    ) {
                    case .retained:
                        break
                    case .waitingForUpload:
                        waiting += 1
                    case .evicted, .systemEvictedAwaitingCoreFinalization:
                        removed += 1
                    case .directorySummary:
                        break
                    }
                } catch {
                    failed += 1
                }
            }
            guard try await metadata.currentGeneration() == intent.indexGeneration else {
                continue
            }
            try retentionStore.advanceDirectoryEviction(
                intentID: intent.id,
                indexGeneration: intent.indexGeneration,
                nextCursor: page.nextCursor
            )
            pages += 1
            guard let nextCursor = page.nextCursor else { break }
            intent.cursor = nextCursor
        }
        return (removed, waiting, failed)
    }

    private func evictRegularItem(
        _ item: IndexedItem,
        policy: SyncPolicy,
        folderIncarnationDigest: String,
        paths: SharedContainerPaths,
        trigger: SyncTrigger,
        configurationRevision: String,
        preservingCurrentPin: Bool = false
    ) async throws -> Result {
        let retentionStore = ContentRetentionStore(url: paths.contentRetention)
        let disposition: ContentEvictionDisposition
        do {
            disposition = try retentionStore.requestEviction(
                of: item,
                folderIncarnationDigest: folderIncarnationDigest,
                configurationRevision: configurationRevision,
                preservingCurrentPin: preservingCurrentPin
            )
        } catch {
            throw FileProviderStorageActionError.metadataUnavailable
        }
        switch disposition {
        case .retained:
            return .retained(item)
        case .waitingForUpload:
            return .waitingForUpload(item)
        case .ready(let transaction):
            return try await performEviction(
                item,
                transaction: transaction,
                policy: policy,
                retentionStore: retentionStore,
                paths: paths,
                trigger: trigger
            )
        }
    }

    private func performEviction(
        _ item: IndexedItem,
        transaction: ContentEvictionTransaction,
        policy: SyncPolicy,
        retentionStore: ContentRetentionStore,
        paths: SharedContainerPaths,
        trigger: SyncTrigger
    ) async throws -> Result {

        let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
        let policyInput = environment.policyInput(
            trigger: trigger,
            requestedActions: [.evictLocalCopy]
        )
        // Exact-version upload evidence was already consumed by
        // ContentRetentionStore. Policy controls when the local storage work
        // may execute; it does not re-derive release eligibility.
        let decision = SyncPolicyEngine().evaluate(policyInput, policy: policy)
        guard decision.blockedActions.isEmpty else {
            try? retentionStore.failEviction(transactionID: transaction.id)
            throw FileProviderStorageActionError.policyDenied(decision.primaryBlockReason)
        }

        var systemEvictionCompleted = false
        do {
            try await FileProviderDomainManager.evictItemFromSystemCache(
                folderID: item.folderID,
                itemID: item.id
            )
            systemEvictionCompleted = true
            try retentionStore.advanceEviction(
                transactionID: transaction.id,
                to: .systemAccepted
            )
            try retentionStore.advanceEviction(
                transactionID: transaction.id,
                to: .contentRemoved
            )
            if try await finalizeCoreEviction(
                transaction,
                paths: paths,
                trigger: trigger
            ) {
                return .evicted(item)
            }
            return .systemEvictedAwaitingCoreFinalization(item)
        } catch {
            if !systemEvictionCompleted {
                try? retentionStore.failEviction(transactionID: transaction.id)
            }
            throw error
        }
    }

    private func finalizeCoreEviction(
        _ transaction: ContentEvictionTransaction,
        paths: SharedContainerPaths,
        trigger: SyncTrigger
    ) async throws -> Bool {
        let retention = ContentRetentionStore(url: paths.contentRetention)
        if !(try retention.coreEvictionIsRequested(transactionID: transaction.id)) {
            if try retention.pendingTransactions().contains(where: { $0.id == transaction.id }) {
                try retention.completeEviction(transactionID: transaction.id)
            }
            return true
        }
        let queue = CoreCommandQueue(root: paths.commandQueue)
        let command = ContentEvictionFinalization.command(for: transaction, trigger: trigger)
        if try queue.result(for: command.id) == nil,
            !(try queue.pending(limit: .max)).contains(where: { $0.id == command.id })
        {
            try queue.enqueue(command)
        }
        await PlatformCoreBootstrap.install()
        let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
        _ = await CoreCommandExecutor().execute(
            [command], trigger: trigger, paths: paths, environment: environment,
            currentEnvironment: { await SyncEnvironmentSnapshot.captureSystemState(paths: paths) },
            maximumPasses: 8, timeout: .seconds(20))
        guard let result = try queue.result(for: command.id) else { return false }
        switch result.status {
        case .succeeded:
            try ContentRetentionStore(url: paths.contentRetention)
                .completeEviction(transactionID: transaction.id)
            _ = await FileProviderDomainManager.signalWorkingSetChanges()
            return true
        case .retryable:
            return false
        case .blocked, .failed:
            throw FileProviderStorageActionError.coreFinalizationFailed
        }
    }

    func keepDownloaded(itemID: String, trigger: SyncTrigger = .user) async throws -> IndexedItem {
        guard
            let item = try await scheduleRetainedDownload(
                itemID: itemID,
                trigger: trigger,
                recordExplicitPin: true
            )
        else {
            throw FileProviderStorageActionError.metadataUnavailable
        }
        return item
    }

    /// Advances a pin already derived from the applied folder policy without
    /// converting it into a permanent per-item override. A later plan
    /// generation must remain able to stop retaining this item.
    private func ensureDownloadedForCurrentRetentionIntent(
        itemID: String,
        trigger: SyncTrigger
    ) async throws -> IndexedItem? {
        try await scheduleRetainedDownload(
            itemID: itemID,
            trigger: trigger,
            recordExplicitPin: false
        )
    }

    private func scheduleRetainedDownload(
        itemID: String,
        trigger: SyncTrigger,
        recordExplicitPin: Bool
    ) async throws -> IndexedItem? {
        let paths = try SharedContainerPaths.resolve()
        let loaded: (IndexedItem, String, String)?
        do {
            loaded = try await Task.detached(priority: .userInitiated) {
                let item = try await CurrentIndexedItemLoader.load(itemID: itemID, paths: paths)
                let incarnation = try FolderIncarnationStore(url: paths.folderIncarnations)
                    .policyContext(for: item.folderID).folderIncarnationDigest
                guard
                    let revision = try SharedSnapshotStore(snapshotURL: paths.snapshot)
                        .read()?.configurationRevision,
                    Self.isCanonicalRevision(revision)
                else {
                    throw FileProviderStorageActionError.metadataUnavailable
                }
                let retentionStore = ContentRetentionStore(url: paths.contentRetention)
                if recordExplicitPin {
                    try retentionStore.keepDownloaded(
                        itemID: item.id,
                        folderID: item.folderID,
                        relativePath: item.relativePath,
                        isDirectory: item.isDirectory,
                        folderIncarnationDigest: incarnation
                    )
                } else {
                    let status = try retentionStore.status(
                        for: item,
                        folderIncarnationDigest: incarnation
                    )
                    guard status.isPinned else { return nil }
                }
                return (item, incarnation, revision)
            }.value
        } catch let error as FileProviderStorageActionError {
            throw error
        } catch {
            throw FileProviderStorageActionError.metadataUnavailable
        }
        guard let loaded else { return nil }
        if !loaded.0.isDirectory, loaded.0.availability != .local, loaded.0.availability != .uploading {
            let queue = CoreCommandQueue(root: paths.commandQueue)
            let encodedVersion = loaded.0.contentVersion.base64EncodedString()
            let alreadyPending = try queue.pending(limit: .max).contains {
                $0.kind == .pin
                    && $0.folderID == loaded.0.folderID
                    && $0.itemID == loaded.0.id
                    && $0.folderIncarnationDigest == loaded.1
                    && $0.arguments["contentVersion"] == encodedVersion
            }
            if !alreadyPending {
                try queue.enqueue(
                    CoreCommand(
                        kind: .pin,
                        folderID: loaded.0.folderID,
                        itemID: loaded.0.id,
                        arguments: ["contentVersion": encodedVersion],
                        folderIncarnationDigest: loaded.1,
                        commandConfigurationRevision: loaded.2,
                        trigger: trigger
                    )
                )
            }
            await PlatformCoreBootstrap.install()
            let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
            _ = await CoreRuntime.shared.processPending(
                trigger: trigger,
                paths: paths,
                environment: environment,
                currentEnvironment: {
                    await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                }
            )
        }
        // Pin intent is authoritative and must survive an offline/disabled
        // domain. A later App/BG/File Provider opportunity retries download.
        try? await FileProviderDomainManager.requestDownload(
            folderID: loaded.0.folderID,
            itemID: loaded.0.id
        )
        _ = await FileProviderDomainManager.signalWorkingSetChanges()
        return loaded.0
    }

    private static func isCanonicalRevision(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

private final class AppMaterializedItemSetCollector: NSObject,
    NSFileProviderEnumerationObserver, @unchecked Sendable
{
    private let lock = NSLock()
    private let enumerator: NSFileProviderEnumerator
    private var identifiers: Set<NSFileProviderItemIdentifier> = []
    private var continuation: CheckedContinuation<Set<NSFileProviderItemIdentifier>, Error>?
    private var keepAlive: AppMaterializedItemSetCollector?

    private init(enumerator: NSFileProviderEnumerator) {
        self.enumerator = enumerator
    }

    static func collect(
        from enumerator: NSFileProviderEnumerator
    ) async throws -> Set<NSFileProviderItemIdentifier> {
        let collector = AppMaterializedItemSetCollector(enumerator: enumerator)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.lock.withLock {
                    collector.continuation = continuation
                    collector.keepAlive = collector
                }
                enumerator.enumerateItems(
                    for: collector,
                    startingAt: NSFileProviderPage(Data())
                )
            }
        } onCancel: {
            collector.cancel()
        }
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
        lock.withLock {
            identifiers.formUnion(updatedItems.map(\.itemIdentifier))
        }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage {
            enumerator.enumerateItems(for: self, startingAt: nextPage)
            return
        }
        finish(.success(lock.withLock { identifiers }))
    }

    func finishEnumeratingWithError(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Set<NSFileProviderItemIdentifier>, Error>) {
        let continuation = lock.withLock {
            () -> CheckedContinuation<Set<NSFileProviderItemIdentifier>, Error>? in
            defer {
                self.continuation = nil
                keepAlive = nil
            }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    private func cancel() {
        finish(.failure(CocoaError(.userCancelled)))
        enumerator.invalidate()
    }
}

struct FileProviderRevealFence: Hashable, Sendable {
    let itemID: String
    let folderID: FolderID
    let parentID: String?
    let relativePath: String
    let isDirectory: Bool
    let contentVersion: Data
    let metadataVersion: Data
    let generation: UInt64

    init(item: IndexedItem) {
        itemID = item.id
        folderID = item.folderID
        parentID = item.parentID
        relativePath = item.relativePath
        isDirectory = item.isDirectory
        contentVersion = item.contentVersion
        metadataVersion = item.metadataVersion
        generation = item.generation
    }
}

struct FileProviderRevealService: Sendable {
    func userVisibleURL(
        itemID: String,
        expectedFence: FileProviderRevealFence? = nil
    ) async throws -> (item: IndexedItem, url: URL) {
        let paths = try SharedContainerPaths.resolve()
        let item = try await currentItem(itemID: itemID, paths: paths)
        let candidateFence = FileProviderRevealFence(item: item)
        if let expectedFence, candidateFence != expectedFence {
            throw FileProviderRevealError.itemChanged
        }
        let url = try await FileProviderDomainManager.userVisibleURL(
            folderID: item.folderID,
            itemID: item.id
        )
        let revalidated = try await currentItem(itemID: itemID, paths: paths)
        guard FileProviderRevealFence(item: revalidated) == candidateFence else {
            throw FileProviderRevealError.itemChanged
        }
        return (revalidated, url)
    }

    /// Rechecks the exact item version after the caller has acquired the
    /// security-scoped URL and immediately before handing it to another app.
    /// Resolving a File Provider URL is asynchronous, so the earlier lookup is
    /// only a candidate, not continuing authority.
    func validateCurrent(
        itemID: String,
        expectedFence: FileProviderRevealFence
    ) async throws -> IndexedItem {
        let paths = try SharedContainerPaths.resolve()
        let item = try await currentItem(itemID: itemID, paths: paths)
        guard FileProviderRevealFence(item: item) == expectedFence else {
            throw FileProviderRevealError.itemChanged
        }
        return item
    }

    private func currentItem(
        itemID: String,
        paths: SharedContainerPaths
    ) async throws -> IndexedItem {
        do {
            return try await CurrentIndexedItemLoader.load(itemID: itemID, paths: paths)
        } catch FileProviderStorageActionError.itemNotFound {
            throw FileProviderRevealError.itemNotFound
        } catch FileProviderStorageActionError.metadataUnavailable {
            throw FileProviderRevealError.metadataUnavailable
        } catch let error as FileProviderRevealError {
            throw error
        } catch {
            throw FileProviderRevealError.metadataUnavailable
        }
    }

}
