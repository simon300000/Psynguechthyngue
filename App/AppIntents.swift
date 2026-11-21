import AppIntents
import Foundation
import PsyCore
import UIKit

private func intentDialog(_ value: String) -> IntentDialog { "\(value)" }

private func stableIntentCode(_ value: String?) -> String {
    value ?? String(localized: "unknown")
}

@MainActor
private func openFileProviderURL(_ url: URL) async -> Bool {
    await withCheckedContinuation { continuation in
        UIApplication.shared.open(url, options: [:]) { accepted in
            continuation.resume(returning: accepted)
        }
    }
}

private func intentDeviceStateTitle(_ state: DeviceConnectionState) -> String {
    switch state {
    case .disconnected: String(localized: "disconnected")
    case .connecting: String(localized: "connecting")
    case .connected: String(localized: "connected")
    case .paused: String(localized: "paused")
    case .blocked: String(localized: "blocked")
    case .error: String(localized: "error")
    }
}

private struct IntentCommandService: Sendable {
    func submit(
        kind: CoreCommandKind,
        folderIDText: String? = nil,
        itemID: String? = nil,
        arguments: [String: String] = [:],
        temporaryPolicyProfileName: String? = nil
    ) async throws -> String {
        guard kind.embeddedBridgeCapability == .supported else {
            return unsupportedBridgeCommandMessage(kind)
        }
        await PlatformCoreBootstrap.install()
        let paths = try SharedContainerPaths.resolve()
        let folderID = folderIDText.flatMap(FolderID.init(rawValue:))
        if folderIDText != nil, folderID == nil { return String(localized: "The folder ID is invalid.") }
        let temporaryPolicyProfile: TemporarySyncPolicyProfile?
        if let temporaryPolicyProfileName {
            let document = try SyncPolicyStore(url: paths.policy).loadDocument()
            let matches = document.temporaryProfiles.filter {
                $0.name.compare(
                    temporaryPolicyProfileName,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ) == .orderedSame
            }
            guard matches.count == 1 else {
                return String(localized: "The named temporary policy profile is unavailable.")
            }
            temporaryPolicyProfile = matches[0]
        } else {
            temporaryPolicyProfile = nil
        }

        let invocationID = UUID()
        let commands = try ScopedCoreCommandProducer(paths: paths).prepareCommands(
            invocationID: invocationID,
            kind: kind,
            folderID: folderID,
            itemID: itemID,
            arguments: arguments,
            temporaryPolicyProfile: temporaryPolicyProfile,
            trigger: .appIntent
        )
        guard !commands.isEmpty else {
            return String(localized: "There are no configured folders to synchronize.")
        }

        let queue = CoreCommandQueue(root: paths.commandQueue)
        if kind == .sync, folderID == nil {
            try queue.enqueueAtomically(commands, batchID: invocationID)
        } else if let command = commands.first {
            try queue.enqueue(command)
        }
        let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
        let execution = await processQueuedCommands(
            commands,
            paths: paths,
            initialEnvironment: environment
        )
        // Every App Intent run is also an opportunity to deliver a request
        // retained from an earlier domain/system failure.
        _ = await FileProviderDomainManager.signalWorkingSetChanges()
        if execution.results.count == commands.count,
            execution.results.values.allSatisfy({ $0.status == .succeeded })
        {
            return String(localized: "The core reported that the request completed.")
        }
        if let result = commands.compactMap({ execution.results[$0.id] }).first(where: {
            $0.status != .succeeded
        }) {
            switch result.status {
            case .succeeded:
                break
            case .retryable:
                return String(localized: "The request is queued for retry: \(stableIntentCode(result.errorCode)).")
            case .blocked:
                if result.errorCode == "peer_index_proof_unavailable" {
                    return String(
                        localized:
                            "The peer did not provide conclusive index-completion proof. Retry after its index has settled or update the peer. No synchronization success was reported."
                    )
                }
                return String(
                    localized:
                        "The request was blocked and its result was recorded; it will not retry automatically: \(stableIntentCode(result.errorCode))."
                )
            case .failed:
                return String(
                    localized:
                        "The request failed and its result was recorded; it will not retry automatically: \(stableIntentCode(result.errorCode))."
                )
            }
        }
        if case .policyDenied(let reasons) = execution.outcome {
            return String(
                localized: "The request is queued but policy blocked it: \(stableIntentCode(reasons.first?.rawValue)).")
        }
        return String(localized: "The request is queued but not complete. Open the app for details.")
    }

    private func processQueuedCommands(
        _ commands: [CoreCommand],
        paths: SharedContainerPaths,
        initialEnvironment: SyncEnvironmentSnapshot
    ) async -> (outcome: CoreRunOutcome?, results: [UUID: CoreCommandResult]) {
        let report = await CoreCommandExecutor().execute(
            commands, trigger: .appIntent, paths: paths, environment: initialEnvironment,
            currentEnvironment: { await SyncEnvironmentSnapshot.captureSystemState(paths: paths) }
        )
        return (report.outcome, report.results)
    }

    func indexedItemPath(_ itemID: String) async throws -> String {
        let paths = try SharedContainerPaths.resolve()
        guard let item = try await indexedItem(itemID, paths: paths) else {
            throw FileProviderStorageActionError.itemNotFound
        }
        return item.relativePath
    }

    func userVisibleItem(_ itemID: String) async throws -> (item: IndexedItem, url: URL) {
        try await FileProviderRevealService().userVisibleURL(itemID: itemID)
    }

    func evictItem(_ itemID: String) async throws -> String {
        let result = try await FileProviderStorageActionService().evictItem(
            itemID: itemID,
            trigger: .appIntent
        )
        switch result {
        case .retained(let item):
            return String(
                localized:
                    "\(item.relativePath) remains kept downloaded because a newer retention choice was preserved."
            )
        case .waitingForUpload(let item):
            return String(
                localized:
                    "\(item.relativePath) will be removed from this device after another Syncthing device confirms the complete current version."
            )
        case .evicted(let item):
            return String(
                localized:
                    "Removed the local download for \(item.relativePath). The placeholder remains and no remote deletion was created."
            )
        case .systemEvictedAwaitingCoreFinalization(let item):
            return String(
                localized:
                    "iOS removed the local download for \(item.relativePath). The global-index item and peer copies were not deleted."
            )
        case .directorySummary(let directory, let removed, let waiting, let failed):
            return String(
                localized:
                    "For \(directory.relativePath), removed \(removed) downloaded files; \(waiting) are waiting for upload; \(failed) could not be removed."
            )
        }
    }

    func downloadItem(_ itemID: String) async throws -> String {
        let item = try await FileProviderStorageActionService().download(itemID: itemID)
        return String(
            localized: "Requested a download for \(item.relativePath). This does not keep future versions downloaded.")
    }

    func keepDownloaded(_ itemID: String) async throws -> String {
        let item = try await FileProviderStorageActionService().keepDownloaded(
            itemID: itemID,
            trigger: .appIntent
        )
        return String(
            localized:
                "Saved Keep Downloaded for \(item.relativePath). If content is unavailable, it will download when policy and connectivity allow."
        )
    }

    func deleteItemEverywhere(_ itemID: String) async throws -> String {
        let paths = try SharedContainerPaths.resolve()
        guard let item = try await indexedItem(itemID, paths: paths) else {
            throw FileProviderStorageActionError.itemNotFound
        }
        return try await submit(
            kind: .delete,
            folderIDText: item.folderID.rawValue,
            itemID: item.id,
            arguments: [
                "baseContentVersion": item.contentVersion.base64EncodedString(),
                "baseMetadataVersion": item.metadataVersion.base64EncodedString(),
                "propagatesToPeers": "true",
                "recursive": String(item.isDirectory),
            ]
        )
    }

    func overallStatus() throws -> String {
        let paths = try SharedContainerPaths.resolve()
        let snapshot = try SharedSnapshotStore(snapshotURL: paths.snapshot).read() ?? CoreSnapshot()
        guard snapshot.localDeviceID != nil else { return String(localized: "The Syncthing core is not initialized.") }
        let pending = Self.pendingTransferBytes(in: snapshot)
        if let error = snapshot.folders.compactMap(\.error).first {
            return String(localized: "Synchronization is blocked: \(error)")
        }
        if pending == 0 {
            return String(
                localized:
                    "The latest local snapshot reports zero pending bytes. Offline peers and their latest state have not been globally verified."
            )
        }
        return String(localized: "There are \(pending.formatted(.byteCount(style: .file))) waiting to transfer.")
    }

    func whyNotSyncing() async throws -> String {
        let paths = try SharedContainerPaths.resolve()
        let snapshot = try SharedSnapshotStore(snapshotURL: paths.snapshot).read() ?? CoreSnapshot()
        guard snapshot.localDeviceID != nil else {
            return String(localized: "The Syncthing core is not initialized.")
        }
        let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
        let policy = try SyncPolicyStore(url: paths.policy).load()
        let decision = SyncPolicyEngine().evaluate(
            environment.policyInput(
                trigger: .appIntent,
                requestedActions: CoreCommandKind.sync.networkCorePolicyActions,
                safetyScope: .networkCoreRuntime
            ),
            policy: policy
        )
        if let reason = decision.primaryBlockReason {
            return String(
                localized:
                    "Synchronization is currently blocked by policy: \(reason.rawValue). Open the app to review the matching remedy."
            )
        }
        let pending = Self.pendingTransferBytes(in: snapshot)
        if pending > 0 {
            return String(
                localized:
                    "Policy currently allows synchronization. Work may still be waiting for iOS scheduling, a reachable peer, or core ownership."
            )
        }
        return String(
            localized:
                "No synchronization is currently blocked by policy, and the latest local snapshot reports zero pending bytes. Offline peers have not been globally verified."
        )
    }

    func deviceStatus(_ deviceIDText: String) throws -> String {
        guard let deviceID = DeviceID(syncthingString: deviceIDText) else {
            return String(localized: "The device ID is invalid.")
        }
        let paths = try SharedContainerPaths.resolve()
        let snapshot = try SharedSnapshotStore(snapshotURL: paths.snapshot).read() ?? CoreSnapshot()
        guard let device = snapshot.devices.first(where: { $0.id == deviceID }) else {
            return String(localized: "The device is not present in the latest core snapshot.")
        }
        let name = device.name.isEmpty ? device.id.rawValue : device.name
        let paused = device.isPaused ? String(localized: "paused") : String(localized: "active")
        let lastSeen =
            device.lastSeen?.formatted(date: .abbreviated, time: .shortened)
            ?? String(localized: "not reported")
        return String(
            localized:
                "\(name): \(intentDeviceStateTitle(device.state)), \(paused), last seen \(lastSeen), upload \(device.uploadBytesPerSecond.formatted(.byteCount(style: .file)))/s, download \(device.downloadBytesPerSecond.formatted(.byteCount(style: .file)))/s, \(device.pendingBytes.formatted(.byteCount(style: .file))) pending upload."
        )
    }

    func folderStatus(_ folderIDText: String) throws -> String {
        guard let folderID = FolderID(rawValue: folderIDText) else {
            return String(localized: "The folder ID is invalid.")
        }
        let paths = try SharedContainerPaths.resolve()
        let snapshot = try SharedSnapshotStore(snapshotURL: paths.snapshot).read() ?? CoreSnapshot()
        guard let folder = snapshot.folders.first(where: { $0.id == folderID }) else {
            return String(localized: "The folder is not present in the latest core snapshot.")
        }
        if let error = folder.error, !error.isEmpty {
            return String(localized: "\(folder.label): blocked by \(error).")
        }
        let state = folder.isPaused ? String(localized: "paused") : String(localized: "active")
        return String(
            localized:
                "\(folder.label): \(state), \(folder.pendingUploadBytes.formatted(.byteCount(style: .file))) to upload and \(folder.pendingDownloadBytes.formatted(.byteCount(style: .file))) to download."
        )
    }

    func search(_ query: String) async throws -> String {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, normalizedQuery.utf8.count <= 4_096 else {
            return String(localized: "Enter search text before querying the global index.")
        }
        let paths = try SharedContainerPaths.resolve()
        guard let snapshot = try SharedSnapshotStore(snapshotURL: paths.snapshot).read() else {
            throw FileProviderStorageActionError.metadataUnavailable
        }
        let matches: [String]
        do {
            let store = try IndexedMetadataStore(
                databaseURL: paths.metadataIndex,
                accessMode: .readOnly,
                recoveryPolicy: .fail
            )
            guard try await store.currentGeneration() == snapshot.generation else {
                throw FileProviderStorageActionError.metadataUnavailable
            }
            let indexedItems = try await store.search(normalizedQuery, limit: 10).items
            let canonicalItems = Dictionary(grouping: snapshot.items, by: \.id)
            let allIndexedItemsAreCanonical = indexedItems.allSatisfy { item in
                let canonicalMatches = canonicalItems[item.id] ?? []
                return canonicalMatches.count == 1 && canonicalMatches[0] == item
            }
            guard allIndexedItemsAreCanonical else {
                throw FileProviderStorageActionError.metadataUnavailable
            }
            matches = indexedItems.map(\.relativePath)
        } catch {
            let folded = normalizedQuery.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            matches = snapshot.items
                .filter {
                    $0.relativePath.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")
                    ).contains(folded)
                }
                .sorted(by: IndexedMetadataStore.binaryItemOrderPrecedes)
                .prefix(10)
                .map(\.relativePath)
        }
        guard try SharedSnapshotStore(snapshotURL: paths.snapshot).read() == snapshot else {
            throw FileProviderStorageActionError.metadataUnavailable
        }
        return matches.isEmpty ? String(localized: "No indexed path matched.") : matches.joined(separator: "\n")
    }

    private func indexedItem(_ identifier: String, paths: SharedContainerPaths) async throws -> IndexedItem? {
        do {
            return try await CurrentIndexedItemLoader.load(itemID: identifier, paths: paths)
        } catch FileProviderStorageActionError.itemNotFound {
            return nil
        }
    }

    private static func pendingTransferBytes(in snapshot: CoreSnapshot) -> Int64 {
        var total: Int64 = 0
        for folder in snapshot.folders {
            for value in [folder.pendingUploadBytes, folder.pendingDownloadBytes] {
                let nonnegative = max(0, value)
                let (sum, overflowed) = total.addingReportingOverflow(nonnegative)
                total = overflowed ? .max : sum
            }
        }
        return total
    }

    private func unsupportedBridgeCommandMessage(_ kind: CoreCommandKind) -> String {
        String(
            localized:
                "The current embedded bridge does not support \(kind.rawValue). No request was queued."
        )
    }
}

struct OverallSyncStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Sync Status"
    static let description = IntentDescription("Returns the latest reported core status and pending transfer amount.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: intentDialog(try IntentCommandService().overallStatus()))
    }
}

struct WhyNotSyncingIntent: AppIntent {
    static let title: LocalizedStringResource = "Why Is Sync Paused?"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: intentDialog(try await IntentCommandService().whyNotSyncing()))
    }
}

struct DeviceStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Device Status"
    static let description = IntentDescription(
        "Returns the latest device connection state, transfer rates, and pending upload bytes reported by the embedded core."
    )
    @Parameter(title: "Device ID") var deviceID: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: intentDialog(try IntentCommandService().deviceStatus(deviceID)))
    }
}

struct FolderStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Folder Status"
    @Parameter(title: "Folder ID") var folderID: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: intentDialog(try IntentCommandService().folderStatus(folderID)))
    }
}

struct SyncAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync All Folders"
    static let description = IntentDescription("Requests a policy-checked synchronization of all folders.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: intentDialog(try await IntentCommandService().submit(kind: .sync)))
    }
}

struct SyncFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Folder"
    static let description = IntentDescription(
        "Requests a policy-checked folder synchronization, optionally using an exact saved temporary profile."
    )
    @Parameter(title: "Folder ID") var folderID: String
    @Parameter(title: "Temporary Policy Profile Name") var profileName: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(
            dialog: intentDialog(
                try await IntentCommandService().submit(
                    kind: .sync,
                    folderIDText: folderID,
                    temporaryPolicyProfileName: profileName
                )
            )
        )
    }
}

struct SyncAllWithPolicyProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync All with Temporary Policy Profile"
    static let description = IntentDescription(
        "Runs one bounded synchronization using an exact named profile. The profile does not change saved global or folder policy."
    )

    @Parameter(title: "Policy Profile Name") var profileName: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(
            dialog: intentDialog(
                try await IntentCommandService().submit(
                    kind: .sync,
                    temporaryPolicyProfileName: profileName
                )
            )
        )
    }
}

struct TransferFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Transfer Folder in One Direction"
    static let description = IntentDescription(
        "Runs a policy-checked upload-only, download-only, or index-only network session for one folder."
    )

    @Parameter(title: "Folder ID") var folderID: String
    @Parameter(title: "Transfer Direction") var direction: FolderTransferDirection
    @Parameter(title: "Temporary Policy Profile Name") var profileName: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let kind: CoreCommandKind
        switch direction {
        case .uploadOnly: kind = .upload
        case .downloadOnly: kind = .download
        case .exchangeIndexOnly: kind = .exchangeIndex
        }
        return .result(
            dialog: intentDialog(
                try await IntentCommandService().submit(
                    kind: kind,
                    folderIDText: folderID,
                    temporaryPolicyProfileName: profileName
                )
            )
        )
    }
}

enum FolderTransferDirection: String, AppEnum {
    case uploadOnly
    case downloadOnly
    case exchangeIndexOnly

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Transfer Direction")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .uploadOnly: "Upload Only",
        .downloadOnly: "Download Only",
        .exchangeIndexOnly: "Exchange Index Only",
    ]
}

struct FolderControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause, Resume, or Rescan Folder"
    @Parameter(title: "Folder ID") var folderID: String
    @Parameter(title: "Action") var action: FolderControlAction

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let kind: CoreCommandKind
        switch action {
        case .pause: kind = .pause
        case .resume: kind = .resume
        case .rescan: kind = .rescan
        }
        return .result(
            dialog: intentDialog(try await IntentCommandService().submit(kind: kind, folderIDText: folderID)))
    }
}

enum FolderControlAction: String, AppEnum {
    case pause
    case resume
    case rescan

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Folder Action")
    static let caseDisplayRepresentations: [FolderControlAction: DisplayRepresentation] = [
        .pause: "Pause", .resume: "Resume", .rescan: "Rescan",
    ]
}

struct DeviceControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Device"
    static let description = IntentDescription(
        "Queues a real embedded-core device pause or resume request and returns its durable result."
    )

    @Parameter(title: "Device ID") var deviceID: String
    @Parameter(title: "Action") var action: DeviceControlAction

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let validatedDeviceID = DeviceID(syncthingString: deviceID) else {
            return .result(dialog: intentDialog(String(localized: "The device ID is invalid.")))
        }
        let kind: CoreCommandKind
        switch action {
        case .pause: kind = .pause
        case .resume: kind = .resume
        }
        return .result(
            dialog: intentDialog(
                try await IntentCommandService().submit(kind: kind, itemID: validatedDeviceID.rawValue)
            )
        )
    }
}

enum DeviceControlAction: String, AppEnum {
    case pause
    case resume

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Device Action")
    static let caseDisplayRepresentations: [DeviceControlAction: DisplayRepresentation] = [
        .pause: "Pause", .resume: "Resume",
    ]
}

struct SearchGlobalIndexIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Global Index"
    @Parameter(title: "Search Text") var query: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: intentDialog(try await IntentCommandService().search(query)))
    }
}

@available(iOS 18.0, *)
struct OpenIndexedItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Indexed Item in Files"
    static let description = IntentDescription(
        "Opens the current File Provider item in its user-visible Files location."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let openAppWhenRun = true
    @Parameter(title: "Item ID") var itemID: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resolved = try await IntentCommandService().userVisibleItem(itemID)
        guard resolved.url.startAccessingSecurityScopedResource() else {
            throw FileProviderRevealError.permissionDenied
        }
        defer { resolved.url.stopAccessingSecurityScopedResource() }
        _ = try await FileProviderRevealService().validateCurrent(
            itemID: resolved.item.id,
            expectedFence: FileProviderRevealFence(item: resolved.item)
        )
        guard await openFileProviderURL(resolved.url) else {
            throw FileProviderRevealError.openRejected
        }
        return .result(dialog: intentDialog(String(localized: "Opened the item in Files.")))
    }
}

struct EvictItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Download"
    static let description = IntentDescription(
        "Removes only local content when the current version is uploaded. Otherwise saves a durable upload-then-remove request."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Item ID") var itemID: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = IntentCommandService()
        let path = try await service.indexedItemPath(itemID)
        if #available(iOS 18.0, *) {
            try await requestConfirmation(
                conditions: [],
                actionName: .continue,
                dialog: intentDialog(
                    String(
                        localized:
                            "Remove only the iOS Files cache copy of \(path)? Syncthing data and peer copies will remain."
                    )
                )
            )
        } else {
            try await requestConfirmation()
        }
        return .result(dialog: intentDialog(try await service.evictItem(itemID)))
    }
}

struct DownloadIndexedItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Download Indexed Item"
    static let description = IntentDescription(
        "Requests the current global-index version from File Provider without enabling Keep Downloaded."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Item ID") var itemID: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: intentDialog(try await IntentCommandService().downloadItem(itemID)))
    }
}

struct KeepIndexedItemDownloadedIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep Indexed Item Downloaded"
    static let description = IntentDescription(
        "Persists Keep Downloaded and requests the current version when policy and connectivity allow."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Item ID") var itemID: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: intentDialog(try await IntentCommandService().keepDownloaded(itemID)))
    }
}

struct DeleteIndexedItemEverywhereIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Indexed Item Everywhere"
    static let description = IntentDescription(
        "Creates a real Syncthing deletion that propagates to peers. This is not Remove Download."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Item ID") var itemID: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = IntentCommandService()
        let path = try await service.indexedItemPath(itemID)
        if #available(iOS 18.0, *) {
            try await requestConfirmation(
                conditions: [],
                actionName: .continue,
                dialog: intentDialog(
                    String(
                        localized:
                            "Delete \(path) from the Syncthing folder and propagate the deletion to other devices? This does not merely remove a local download."
                    )
                )
            )
        } else {
            try await requestConfirmation()
        }
        return .result(dialog: intentDialog(try await service.deleteItemEverywhere(itemID)))
    }
}

struct PsyAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncAllIntent(), phrases: ["Sync with \(.applicationName)"], shortTitle: "Sync All",
            systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(
            intent: OverallSyncStatusIntent(), phrases: ["Check \(.applicationName) sync status"],
            shortTitle: "Sync Status", systemImageName: "checkmark.circle")
        AppShortcut(
            intent: WhyNotSyncingIntent(), phrases: ["Why is \(.applicationName) paused"], shortTitle: "Why Paused",
            systemImageName: "questionmark.circle")
    }
}
