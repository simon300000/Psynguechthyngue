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
/// Production: WP-A's `PsyBridgeAdapter` (Platform/PsyBridgeAdapter.swift +
/// Artifacts/PsyBridge.xcframework linked into this target) and WP-B's
/// `KeychainIdentityStore` on the shared access group (`PsyKeychainAccessGroup`).
/// DEBUG only: if `<AppGroup>/DevFetchSource/` exists, `DevRestrictedFetchBridge`
/// stands in for the network (simulator harness). Without the xcframework the
/// restricted path reports "open the App" (`.unavailable`).
enum RestrictedFetchServices {
    static func make(layout: AppGroupLayout) -> (bridge: (any RestrictedFetchBridge)?, identity: DeviceIdentityProvider) {
        #if DEBUG
        if let dev = DevRestrictedFetchBridge(layout: layout) {
            return (dev, { DevRestrictedFetchBridge.identity })
        }
        #endif
        #if PSY_RESTRICTED_FETCH || canImport(PsyBridge)
        let group = Bundle.main.object(forInfoDictionaryKey: "PsyKeychainAccessGroup") as? String
        let identityStore = KeychainIdentityStore(accessGroup: group)
        let bridgeLog = Logger(subsystem: FilesLog.subsystem, category: "bridge")
        #if DEBUG
        let level = "info"
        #else
        let level = "warn"
        #endif
        let adapter = PsyBridgeAdapter(logLevel: level, log: { lvl, message in
            bridgeLog.log("[\(lvl, privacy: .public)] \(message, privacy: .public)")
        })
        return (adapter, { try identityStore.load() })
        #else
        return (nil, { nil })
        #endif
    }
}
