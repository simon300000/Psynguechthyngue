import FileProvider
import PsySync
import Darwin
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
        store = try FilesStore(url: layout.filesDatabase, cacheKiB: 256)
        folder = FolderID(rawValue: domain.identifier.rawValue)
        reader = store.reader(folder: folder)
        containment = PathContainment(root: layout.managedFolder(folder))
        manager = NSFileProviderManager(for: domain)
        let temporary = (try? manager?.temporaryDirectoryURL())
            ?? FileManager.default.temporaryDirectory.appending(path: "psy-fp")
        let services = RestrictedFetchServices.make(layout: layout)
        var configuration = LiveContentProvider.Configuration()
        configuration.afterFetch = services.afterFetch
        #if DEBUG
        // Simulator reproduction: os_proc_available_memory() is 0 there; a
        // number (MiB) in this file stands in for the device headroom.
        let headroomOverride = layout.root.appending(path: "Library/Caches/Diagnostics/debug-available-mib")
        #endif
        configuration.availableMemory = {
            var available = UInt64(os_proc_available_memory())
            #if DEBUG
            if let text = try? String(contentsOf: headroomOverride, encoding: .utf8),
                let mib = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                available = mib << 20
            }
            let limit = RestrictedFetchBudget.default.fitted(availableBytes: available)?.memory.limitMiB ?? -1
            FootprintProbe.file?.append("fetch-budget available=\(available >> 20)MiB gomemlimit=\(limit)MiB")
            #endif
            return available
        }
        let root = layout.managedFolder(folder)
        configuration.isUserIgnored = { path in
            let lines = IgnoreRulesGenerator.userRules(folderRoot: root)
            guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  let matcher = try? PsyBridgeAdapter.makeIgnoreMatcher(folderRoot: root, lines: lines)
            else { return false }
            return matcher.isIgnored(path)
        }
        content = LiveContentProvider(
            layout: layout, store: store, folder: folder, engineLock: FlockEngineLock(layout: layout),
            fetchBridge: services.bridge, identity: services.identity, temporaryDirectory: temporary,
            configuration: configuration)
    }

    var rootID: ItemIdentifier { reader.rootID }

    var folderInfo: FilesFolderInfo? { try? store.folderInfo(folder) }

    var isOnDemand: Bool { (try? store.folderInfo(folder))?.contentMode == .onDemand }

    func item(for record: FileItemRecord) -> FileProviderItem {
        let info = folderInfo
        return FileProviderItem(
            record: record, rootID: rootID, folderLabel: info?.label ?? folder.rawValue, contentMode: info?.contentMode)
    }

    func storeID(_ identifier: NSFileProviderItemIdentifier) -> ItemIdentifier {
        identifier == .rootContainer ? rootID : ItemIdentifier(rawValue: identifier.rawValue)
    }

    func record(_ identifier: NSFileProviderItemIdentifier) throws -> FileItemRecord {
        guard let record = try reader.item(storeID(identifier)) else { throw NSFileProviderError(.noSuchItem) }
        return record
    }
}

/// Bridge + identity for the restricted fetch.
///
/// Production: `PsyBridgeAdapter` (Platform/PsyBridgeAdapter.swift +
/// Artifacts/PsyBridge.xcframework linked into this target) and 
/// `KeychainIdentityStore` on the shared access group (`PsyKeychainAccessGroup`).
/// DEBUG only: if `<AppGroup>/DevFetchSource/` exists, `DevRestrictedFetchBridge`
/// stands in for the network (simulator harness). Without the xcframework the
/// restricted path reports "open the App" (`.unavailable`).
enum RestrictedFetchServices {
    static func make(layout: AppGroupLayout)
        -> (bridge: (any RestrictedFetchBridge)?, identity: DeviceIdentityProvider, afterFetch: (@Sendable () -> Void)?)
    {
        #if DEBUG
        if let dev = DevRestrictedFetchBridge(layout: layout) {
            return (dev, { DevRestrictedFetchBridge.identity }, nil)
        }
        #endif
        #if PSY_RESTRICTED_FETCH || canImport(PsyBridge)
        let group = Bundle.main.object(forInfoDictionaryKey: "PsyKeychainAccessGroup") as? String
        let identityStore = KeychainIdentityStore(accessGroup: group)
        let bridgeLog = Logger(subsystem: FilesLog.subsystem, category: "bridge")
        let sink: PsyBridgeLogHandler = { lvl, message in
            bridgeLog.log("[\(lvl, privacy: .public)] \(message, privacy: .public)")
            #if DEBUG
            FootprintProbe.file?.append("bridge[\(lvl)] \(message)")
            #endif
        }
        #if DEBUG
        // "trace": one line per fetch phase with footprint=/footprintPeak=.
        PsyBridgeAdapter.setRestrictedLog(level: "trace", sink)
        #else
        PsyBridgeAdapter.setRestrictedLog(level: "warn", sink)
        #endif
        let adapter = PsyBridgeAdapter(logLevel: "warn")
        // No engine in the extension → onMemoryWarning() = psybridge.FreeOSMemory().
        return (adapter, { try identityStore.load() }, { adapter.onMemoryWarning() })
        #else
        return (nil, { nil }, nil)
        #endif
    }
}

/// phys_footprint is what jetsam limits (not RSS). Logged at extension init
/// and around each fetchContents so the non-bridge share can be attributed.
enum FootprintProbe {
    struct Sample {
        var footprintMiB: Double
        var peakMiB: Double
        /// os_proc_available_memory(): headroom before jetsam; footprint + this ≈ the limit.
        var availableMiB: Double
    }

    static func sample() -> Sample? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Sample(footprintMiB: Double(info.phys_footprint) / 1_048_576,
                      peakMiB: Double(info.ledger_phys_footprint_peak) / 1_048_576,
                      availableMiB: Double(os_proc_available_memory()) / 1_048_576)
    }

    #if DEBUG
    /// Device acceptance runs: `<AppGroup>/Diagnostics/extension.log`.
    static let file = DiagnosticsFileLog.make(name: "extension")
    #endif

    static func log(_ phase: String) {
        guard let s = sample() else { return }
        #if DEBUG
        file?.append(String(format: "phase=%@ footprint=%.1fMiB peak=%.1fMiB available=%.1fMiB",
                            phase, s.footprintMiB, s.peakMiB, s.availableMiB))
        #endif
        Logger(subsystem: "app.psynguechthyngue.files", category: "footprint")
            .log("phase=\(phase, privacy: .public) footprint=\(s.footprintMiB, format: .fixed(precision: 1))MiB peak=\(s.peakMiB, format: .fixed(precision: 1))MiB available=\(s.availableMiB, format: .fixed(precision: 1))MiB limit≈\(s.footprintMiB + s.availableMiB, format: .fixed(precision: 0))MiB")
    }
}
