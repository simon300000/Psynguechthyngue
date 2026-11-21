import FileProvider
import PsySync
import os

/// Everything one domain (= one managed folder) needs. Opened once per
/// extension instance; the extension never starts the full engine and never
/// calls REST (invariants I3/I4).
final class ExtensionContext: @unchecked Sendable {
    let layout: AppGroupLayout
    let store: FilesStore
    let folder: FolderID
    let reader: FolderFilesReader
    let containment: PathContainment
    let content: LiveContentProvider
    let manager: NSFileProviderManager?

    init(domain: NSFileProviderDomain) throws {
        layout = try AppGroupResolver.layout()
        store = try FilesStore(url: layout.filesDatabase)
        folder = FolderID(rawValue: domain.identifier.rawValue)
        reader = store.reader(folder: folder)
        containment = PathContainment(root: layout.managedFolder(folder))
        manager = NSFileProviderManager(for: domain)
        let temporary = (try? manager?.temporaryDirectoryURL())
            ?? FileManager.default.temporaryDirectory.appending(path: "psy-fp")
        let services = RestrictedFetchServices.make(layout: layout)
        content = LiveContentProvider(
            layout: layout, store: store, folder: folder, engineLock: FlockEngineLock(layout: layout),
            fetchBridge: services.bridge, identity: services.identity, temporaryDirectory: temporary)
    }

    var rootID: ItemIdentifier { reader.rootID }

    var folderInfo: FilesFolderInfo? { try? store.folderInfo(folder) }

    func item(for record: FileItemRecord) -> FileProviderItem {
        FileProviderItem(record: record, rootID: rootID, folderLabel: folderInfo?.label ?? folder.rawValue)
    }

    func storeID(_ identifier: NSFileProviderItemIdentifier) -> ItemIdentifier {
        identifier == .rootContainer ? rootID : ItemIdentifier(rawValue: identifier.rawValue)
    }

    func record(_ identifier: NSFileProviderItemIdentifier) throws -> FileItemRecord {
        guard let record = try reader.item(storeID(identifier)) else { throw NSFileProviderError(.noSuchItem) }
        return record
    }
}

/// Bridge + identity for the restricted fetch (DESIGN.md §6.4).
///
/// Integration point for WP-A (`PsyBridgeAdapter`, a `RestrictedFetchBridge`)
/// and WP-B (`KeychainIdentityStore`, shared access group). Until both are
/// linked into this target (compile flag `PSY_RESTRICTED_FETCH`), the
/// restricted path reports "open the App" (`.unavailable`). DEBUG builds can
/// exercise the whole extension-side path with `DevRestrictedFetchBridge`.
enum RestrictedFetchServices {
    static func make(layout: AppGroupLayout) -> (bridge: (any RestrictedFetchBridge)?, identity: DeviceIdentityProvider) {
        #if PSY_RESTRICTED_FETCH
        let identityStore = KeychainIdentityStore()
        return (PsyBridgeAdapter(), { try identityStore.load() })
        #else
        #if DEBUG
        if let dev = DevRestrictedFetchBridge(layout: layout) {
            return (dev, { DevRestrictedFetchBridge.identity })
        }
        #endif
        return (nil, { nil })
        #endif
    }
}
