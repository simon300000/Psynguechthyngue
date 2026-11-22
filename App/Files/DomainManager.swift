@preconcurrency import FileProvider
import Foundation
import PsySync
import os

/// One NSFileProvider domain per *managed* folder (DESIGN.md §6.1); external
/// folders are already visible in Files and get none. Domain identifier =
/// folder ID, display name = folder label.
/// User-visible state of a folder's Files location (Mac spike: domains start
/// user-disabled on Designed-for-iPad and must be enabled in System Settings).
enum FilesDomainStatus: Equatable, Sendable {
    case enabled
    /// Present but turned off by the user (Files on iOS / System Settings on macOS).
    case disabledByUser
    case notInstalled
}

enum DomainManager {
    private static let log = Logger(subsystem: FilesLog.subsystem, category: "domains")

    /// Registers folder metadata for the extension and adds/removes domains so
    /// they match `folders`. Folder rows of removed folders are dropped from
    /// files.sqlite.
    static func reconcile(folders: [Folder], store: FilesStore) async {
        let managed = folders.filter { if case .managed = $0.location { return true } else { return false } }
        var touched: [FolderID] = []
        for folder in managed {
            let before = (try? store.currentAnchor()) ?? 0
            try? store.upsertFolder(
                FilesFolderInfo(
                    folderID: folder.id, label: folder.label, isReadOnly: folder.type == .receiveOnly,
                    contentMode: folder.contentMode))
            // Type / label / content mode changes re-announce items; without a
            // signal the system only saw them after the next index change.
            if ((try? store.currentAnchor()) ?? 0) != before { touched.append(folder.id) }
        }
        // Installs that lost items to the materialization window (see
        // FilesStore.setMaterialized) recover once here.
        if let repaired = try? store.repairWorkingSetIfNeeded(), !repaired.isEmpty {
            log.info("working-set repair folders=\(repaired.count)")
            for id in repaired where !touched.contains(id) { touched.append(id) }
        }
        // Item capabilities changed (FilesItemPolicy.capabilityRevision):
        // re-announce every row once so the system re-reads them.
        if let changed = try? store.reannounceForCapabilitiesIfNeeded(), !changed.isEmpty {
            log.info("capability re-announce folders=\(changed.count)")
            for id in changed where !touched.contains(id) { touched.append(id) }
        }
        let wanted = Dictionary(uniqueKeysWithValues: managed.map { ($0.id.rawValue, $0) })
        let existing: [NSFileProviderDomain]
        do {
            existing = try await NSFileProviderManager.domains()
        } catch {
            log.error("domains() failed: \(String(describing: error), privacy: .public)")
            return
        }
        for domain in existing where wanted[domain.identifier.rawValue] == nil {
            do {
                try await NSFileProviderManager.remove(domain)
                _ = try? store.removeFolder(FolderID(rawValue: domain.identifier.rawValue))
                log.info("removed domain \(domain.identifier.rawValue, privacy: .public)")
            } catch {
                log.error("remove domain failed: \(String(describing: error), privacy: .public)")
            }
        }
        let present = Dictionary(uniqueKeysWithValues: existing.map { ($0.identifier.rawValue, $0) })
        for (id, folder) in wanted {
            if let domain = present[id], domain.displayName == folder.label, !domain.supportsSyncingTrash { continue }
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id), displayName: folder.label)
            // We do not sync a trash container; without this the system (default
            // YES) asks for NSFileProviderTrashContainerItemIdentifier and Finder
            // keeps reporting errors (Mac spike).
            domain.supportsSyncingTrash = false
            do {
                try await NSFileProviderManager.add(domain)
                log.info("added domain \(id, privacy: .public)")
            } catch {
                log.error("add domain \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        for id in touched { await signal(id) }
    }

    /// Per-folder Files location state for the UI (e.g. "Enable in Settings" hint on Mac).
    static func statuses(for folders: [FolderID]) async -> [FolderID: FilesDomainStatus] {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        let byID = Dictionary(uniqueKeysWithValues: domains.map { ($0.identifier.rawValue, $0) })
        var result: [FolderID: FilesDomainStatus] = [:]
        for folder in folders {
            guard let domain = byID[folder.rawValue] else {
                result[folder] = .notInstalled
                continue
            }
            result[folder] = domain.userEnabled ? .enabled : .disabledByUser
        }
        return result
    }

    /// Tells the system the working set of `folder` changed.
    static func signal(_ folder: FolderID) async {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(folder.rawValue), displayName: "")
        guard let manager = NSFileProviderManager(for: domain) else { return }
        do {
            try await manager.signalEnumerator(for: .workingSet)
        } catch {
            log.debug("signal \(folder.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Asks the system to download `item` now (FilesMaterializer). The
    /// extension serves it with a local clone of the engine copy.
    static func requestDownload(_ folder: FolderID, item: ItemIdentifier) async throws {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(folder.rawValue), displayName: "")
        guard let manager = NSFileProviderManager(for: domain) else { return }
        try await manager.requestDownloadForItem(withIdentifier: NSFileProviderItemIdentifier(item.rawValue))
    }

    /// Makes the system download an item now: a coordinated read of its
    /// user-visible URL (the system materializes a dataless file before it
    /// grants the read, i.e. calls fetchContents; the extension answers a
    /// local file with a clone). `requestDownloadForItem` is acknowledged but
    /// never executed on iOS 26 and on device (iOS 27.3: 996 requests, ~121
    /// fetches in total), so it is only the fallback.
    static func materialize(_ folder: FolderID, item: ItemIdentifier) async throws {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(folder.rawValue), displayName: "")
        guard let manager = NSFileProviderManager(for: domain) else { return }
        let identifier = NSFileProviderItemIdentifier(item.rawValue)
        let url: URL
        do {
            url = try await manager.getUserVisibleURL(for: identifier)
        } catch {
            try await manager.requestDownloadForItem(withIdentifier: identifier)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileCoordinator(filePresenter: nil).coordinate(
                with: [.readingIntent(with: url, options: [])], queue: coordinationQueue
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static let coordinationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "psy.files.materialize"
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    /// The extension answers `.serverUnreachable` / `.notAuthenticated` when it
    /// cannot serve contents (no peer, App busy, restricted core refused).
    /// The system then shows the domain as "paused" and backs off *until it is
    /// signalled* (NSFileProviderReplicatedExtension.h, fetchContents) — a
    /// plain `signalEnumerator` does not lift that. The App calls this
    /// whenever the engine is running (it can now serve delegated fetches).
    static func resolveErrors(_ folders: [FolderID]) async {
        for folder in folders {
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(folder.rawValue), displayName: "")
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            for code in [NSFileProviderError.Code.serverUnreachable, .notAuthenticated] {
                do {
                    try await manager.signalErrorResolved(NSFileProviderError(code))
                } catch {
                    log.debug("signalErrorResolved \(folder.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        LifecycleLog.shared.record("files-errors-resolved", "folders=\(folders.count)")
    }

    /// DEBUG/diagnostics: the system's view of each domain.
    static func logDomainStates() async {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        for d in domains {
            LifecycleLog.shared.record(
                "files-domain",
                "id=\(d.identifier.rawValue) enabled=\(d.userEnabled) replicated=\(d.isReplicated) testing=\(d.testingModes.rawValue)")
        }
    }

    /// Fresh install / reset (DESIGN.md §8.4).
    static func removeAll() async {
        try? await NSFileProviderManager.removeAllDomains()
    }
}
