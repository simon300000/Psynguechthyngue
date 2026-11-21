@preconcurrency import FileProvider
import Foundation
import PsySync
import os

/// One NSFileProvider domain per *managed* folder (DESIGN.md §6.1); external
/// folders are already visible in Files and get none. Domain identifier =
/// folder ID, display name = folder label.
enum DomainManager {
    private static let log = Logger(subsystem: FilesLog.subsystem, category: "domains")

    /// Registers folder metadata for the extension and adds/removes domains so
    /// they match `folders`. Folder rows of removed folders are dropped from
    /// files.sqlite.
    static func reconcile(folders: [Folder], store: FilesStore) async {
        let managed = folders.filter { if case .managed = $0.location { return true } else { return false } }
        for folder in managed {
            try? store.upsertFolder(
                FilesFolderInfo(
                    folderID: folder.id, label: folder.label, isReadOnly: folder.type == .receiveOnly,
                    contentMode: folder.contentMode))
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
            if let domain = present[id], domain.displayName == folder.label { continue }
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id), displayName: folder.label)
            do {
                try await NSFileProviderManager.add(domain)
                log.info("added domain \(id, privacy: .public)")
            } catch {
                log.error("add domain \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
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

    /// Fresh install / reset (DESIGN.md §8.4).
    static func removeAll() async {
        try? await NSFileProviderManager.removeAllDomains()
    }
}
