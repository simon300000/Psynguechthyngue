import Foundation
import Network
import Observation
import PsyCore
import UIKit
import UserNotifications

private func reclaimStaleFileProviderStaging(paths: SharedContainerPaths) {
    guard
        let retained = try? CoreCommandQueue(root: paths.commandQueue)
            .retainedFileProviderStagingCommandIDs()
    else { return }
    _ = try? FileProviderStagingStore(root: paths.fileProviderStaging)
        .reclaimStaleDirectories(retaining: retained)
}

enum AppStartupState: Equatable {
    case loading
    case ready
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    var startupState: AppStartupState = .loading
    var isSubmittingCommand = false
    var foregroundSyncEnabled =
        UserDefaults.standard.object(forKey: "foregroundSyncEnabledV1") == nil
        || UserDefaults.standard.bool(forKey: "foregroundSyncEnabledV1")
    @ObservationIgnored var startupTask: Task<Void, Never>?
    @ObservationIgnored let foregroundService = ForegroundSyncService()
    @ObservationIgnored var foregroundController: ForegroundSyncController?

    var syncController: ForegroundSyncController {
        if let foregroundController { return foregroundController }
        let controller = ForegroundSyncController { [weak self] in
            guard let self, let paths = self.paths else { return .init(.stopped) }
            let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
            if !self.snapshot.remoteDevices.isEmpty, self.snapshot.folders.isEmpty,
                (try? CoreCommandQueue(root: paths.commandQueue).pending(limit: 1).isEmpty) == true
            {
                let report = await PendingFolderDiscoveryOpportunity.run(
                    snapshot: self.snapshot, trigger: .foreground, paths: paths,
                    environment: environment,
                    currentEnvironment: { await SyncEnvironmentSnapshot.captureSystemState(paths: paths) }
                )
                if !Task.isCancelled {
                    self.applyPendingFolderDiscoveryReport(report)
                    await self.refresh(bootstrapConfigurationIfNeeded: false)
                }
                switch report.outcome {
                case .policyDenied: return .init(.blocked([]), delay: .seconds(30))
                case .configurationUnavailable, .failed:
                    return .init(.failed("pendingFolderDiscoveryFailed"), delay: .seconds(30))
                default: return .init(.waiting, delay: .seconds(30))
                }
            }
            let result = await self.foregroundService.runCycle(
                paths: paths, environment: environment,
                currentEnvironment: { await SyncEnvironmentSnapshot.captureSystemState(paths: paths) }
            )
            if !Task.isCancelled { await self.refresh(bootstrapConfigurationIfNeeded: false) }
            return result
        }
        foregroundController = controller
        return controller
    }

    func setScene(_ id: UUID, active: Bool) {
        syncController.setScene(id, active: active)
    }

    func setForegroundSyncEnabled(_ enabled: Bool) {
        foregroundSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "foregroundSyncEnabledV1")
        syncController.isEnabled = enabled && startupState == .ready
    }

    func retryStartup() async {
        guard case .failed = startupState else { return }
        startupTask = nil
        await start()
    }

    var snapshot = CoreSnapshot()
    var folderIncarnationDigests: [FolderID: String] = [:]
    var network = NetworkState(kind: .unavailable)
    var policy = SyncPolicy()
    var temporaryPolicyProfiles: [TemporarySyncPolicyProfile] = []
    var currentDecision: SyncPolicyDecision?
    var histories: [SyncRunRecord] = []
    var backgroundTaskScheduleStatus = BackgroundTaskScheduleStatus()
    var fileProviderDomainStatus = FileProviderDomainStatus.checking
    var externalDirectories: [ExternalDirectoryRecord] = []
    var runningExternalDirectoryIDs: Set<UUID> = []
    var externalDirectoryRecoveries: [UUID: [ControlledMirrorRecoverySummary]] = [:]
    var externalDirectoryRecoveryFailureCodes: [UUID: String] = [:]
    var coreMutationRecoveries: [CoreMutationRecoverySummary] = []
    var coreMutationRecoveryFailureCode: String?
    var hasMoreCoreMutationRecoveries = false
    var isCoreMutationRecoveryLoading = false
    var runningCoreMutationRecoveryExportIDs: Set<String> = []
    let fileIndex = FileIndexModel()
    var indexedItems: [IndexedItem] { fileIndex.items }
    var contentRetentionStatuses: [String: ContentRetentionStatus] { fileIndex.retentionStatuses }
    var indexedItemCount: Int { fileIndex.totalCount }
    var hasMoreIndexedItems: Bool { fileIndex.hasMore }
    var isIndexLoading: Bool { fileIndex.isLoading }
    var isRefreshing = false
    var isDiscoveringPendingFolderOffers = false
    var pendingFolderDiscoveryStatusMessage: String?
    var pendingFolderOfferObservationIDs: Set<PendingFolderOffer.Identifier> = []
    var notificationsEnabled = false
    var notificationAuthorizationStatus: NotificationAuthorizationStatus = .notDetermined
    var isUpdatingNotificationSettings = false
    var notificationStateUnavailable = false
    var notificationNavigationDestination: NotificationDestination?
    var statusMessage: String?
    var errorMessage: String?

    let networkMonitor = NetworkStateMonitor()
    var paths: SharedContainerPaths?
    var externalDirectoryBroker: ExternalDirectoryAccessBroker?
    var coreMutationRecoveryCursor: String?
    var pendingCoreMutationRecoveryExportCleanup: [UUID: CoreMutationRecoveryExport] = [:]
    var notificationCoordinator: NotificationEventCoordinator?
    var pendingNotificationResponseDestinations: [NotificationDestination] = []
    var queuedNotificationNavigationDestinations: [NotificationDestination] = []
    var pendingFolderDiscoveryTask: Task<Void, Never>?

    init() {
        SystemNotificationDeliveryClient.shared.installResponseHandler { [weak self] destination in
            Task { @MainActor in
                await self?.handleNotificationResponse(destination)
            }
        }
    }

    func start() async {
        if let startupTask {
            await startupTask.value
            return
        }
        let task = Task { await initialize() }
        startupTask = task
        await task.value
    }

    func initialize() async {
        startupState = .loading
        await PlatformCoreBootstrap.install()
        await refreshFileProviderDomainStatus()
        networkMonitor.onChange = { [weak self] state in
            self?.network = state
            self?.recalculateDecision()
        }
        networkMonitor.start()
        do {
            let paths = try SharedContainerPaths.resolve()
            self.paths = paths
            notificationCoordinator = NotificationEventCoordinator(
                store: NotificationEventStore(url: paths.notificationEvents),
                client: SystemNotificationDeliveryClient.shared
            )
            await reloadNotificationConfiguration()
            externalDirectoryBroker = ExternalDirectoryAccessBroker(
                recordsURL: paths.externalDirectoryRecords,
                managedRootsURL: paths.externalManagedFoldersRoot,
                commandQueueURL: paths.commandQueue
            )
            do {
                try await externalDirectoryBroker?.load()
                _ = await ensureCanonicalConfigurationAvailable(
                    paths: paths,
                    trigger: .foreground
                )
                await Task.detached(priority: .utility) {
                    reclaimStaleFileProviderStaging(paths: paths)
                }.value
                await discardOrphanedCoreMutationRecoveryExports(paths: paths)
                await repairDerivedMetadataIndexIfNeeded(paths: paths)
                _ = await FileProviderStorageActionService().reconcilePendingWork(
                    trigger: .foreground
                )
                await refresh(bootstrapConfigurationIfNeeded: false)
            } catch {
                errorMessage = error.localizedDescription
            }
            await drainPendingNotificationResponses()
        } catch {
            errorMessage = error.localizedDescription
        }
        if snapshot.configurationRevision != nil, snapshot.localDeviceID != nil {
            startupState = .ready
            syncController.isEnabled = foregroundSyncEnabled
        } else {
            startupState = .failed(
                errorMessage ?? statusMessage ?? String(localized: "The sync engine could not start. Try again."))
        }
    }

    /// The SQLite index is a rebuildable projection. A prior transient writer
    /// failure must not leave Files permanently degraded until another network
    /// command happens to publish a snapshot. Avoid all writes when the durable
    /// status already matches the canonical snapshot generation.
    func repairDerivedMetadataIndexIfNeeded(paths: SharedContainerPaths) async {
        let projector = MetadataIndexProjector(
            databaseURL: paths.metadataIndex,
            statusURL: paths.metadataIndexStatus
        )
        guard let snapshot = try? SharedSnapshotStore(snapshotURL: paths.snapshot).read() else {
            return
        }
        if let status = try? projector.readStatus(),
            status.state == .ready,
            status.snapshotGeneration == snapshot.generation
        {
            return
        }
        _ = await projector.project(snapshot)
    }

    func refresh(bootstrapConfigurationIfNeeded: Bool = true) async {
        guard let paths, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshFileProviderDomainStatus()
        if bootstrapConfigurationIfNeeded {
            _ = await ensureCanonicalConfigurationAvailable(
                paths: paths,
                trigger: .foreground
            )
        }
        do {
            let loaded = try await Task.detached(priority: .utility) {
                let snapshotStore = SharedSnapshotStore(snapshotURL: paths.snapshot)
                let persistedSnapshot = try snapshotStore.read()
                let snapshot = persistedSnapshot ?? CoreSnapshot()
                let incarnationStore = FolderIncarnationStore(url: paths.folderIncarnations)
                var folderIncarnationDigests: [FolderID: String] = [:]
                for folder in snapshot.folders {
                    guard folderIncarnationDigests[folder.id] == nil else {
                        throw FolderPolicyEditingError.folderConfigurationChanged
                    }
                    let context = try incarnationStore.policyContext(for: folder.id)
                    folderIncarnationDigests[folder.id] = context.folderIncarnationDigest
                }
                guard try snapshotStore.read() == persistedSnapshot else {
                    throw FolderPolicyEditingError.folderConfigurationChanged
                }
                let policyDocument = try SyncPolicyStore(url: paths.policy).loadDocument()
                let history = try SyncRunHistory(url: paths.history).recent(limit: 100)
                let backgroundTaskScheduleStatus =
                    (try? BackgroundTaskScheduleStatusStore(
                        url: paths.backgroundTaskScheduleStatus
                    ).read()) ?? BackgroundTaskScheduleStatus()
                return (
                    snapshot,
                    policyDocument,
                    history,
                    backgroundTaskScheduleStatus,
                    folderIncarnationDigests
                )
            }.value
            snapshot = loaded.0
            policy = loaded.1.global
            temporaryPolicyProfiles = loaded.1.temporaryProfiles
            histories = loaded.2
            backgroundTaskScheduleStatus = loaded.3
            folderIncarnationDigests = loaded.4
            await FileProviderDomainManager.reconcileDomains(snapshot: loaded.0)
            fileProviderDomainStatus = await FileProviderDomainManager.status(snapshot: loaded.0)
            _ = try await externalDirectoryBroker?.reconcileSyncBindings(snapshot: loaded.0)
            externalDirectories = await externalDirectoryBroker?.allRecords() ?? []
            await refreshExternalDirectoryRecoveries()
            await fileIndex.refresh(paths: paths, snapshot: snapshot, incarnations: folderIncarnationDigests)
            _ = await FileProviderDomainManager.signalWorkingSetChanges(
                snapshotGeneration: loaded.0.generation
            )
            recalculateDecision()
            await deliverNotifications(snapshot: loaded.0)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshFileProviderDomainStatus() async {
        fileProviderDomainStatus = await FileProviderDomainManager.status(snapshot: snapshot)
    }

    @discardableResult
    func ensureCanonicalConfigurationAvailable(
        paths: SharedContainerPaths,
        trigger: SyncTrigger
    ) async -> Bool {
        let persistedSnapshot: CoreSnapshot?
        do {
            persistedSnapshot = try await Task.detached(priority: .userInitiated) {
                try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
            }.value
        } catch {
            statusMessage = String(
                localized:
                    "Configuration could not be read safely. Refresh to try initializing it again."
            )
            return false
        }

        if let persistedSnapshot, persistedSnapshot.configurationRevision != nil {
            snapshot = persistedSnapshot
            return true
        }

        let outcome = await CoreRuntime.shared.refreshConfigurationSnapshot(
            trigger: trigger,
            paths: paths
        )
        switch outcome {
        case .completed:
            do {
                let refreshedSnapshot = try await Task.detached(priority: .userInitiated) {
                    try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
                }.value
                guard
                    let refreshedSnapshot,
                    refreshedSnapshot.configurationRevision != nil
                else {
                    statusMessage = String(
                        localized:
                            "Configuration initialization finished without a verifiable saved revision. Refresh to try again."
                    )
                    return false
                }
                snapshot = refreshedSnapshot
                statusMessage = String(localized: "Configuration is ready.")
                return true
            } catch {
                statusMessage = String(
                    localized:
                        "Configuration initialization finished, but the saved revision could not be verified. Refresh to try again."
                )
                return false
            }
        case .coreBusy:
            statusMessage = String(
                localized:
                    "The core is busy, so configuration was not initialized. Refresh to try again."
            )
            return false
        case .configurationUnavailable:
            statusMessage = String(
                localized:
                    "Configuration storage is unavailable. Restore access, then refresh to try again."
            )
            return false
        case .policyDenied:
            statusMessage = String(
                localized:
                    "Configuration initialization was denied. No configuration revision was assumed."
            )
            return false
        case .failed:
            statusMessage = String(
                localized:
                    "Configuration initialization failed safely. Refresh to try again."
            )
            return false
        }
    }

    func reloadIndex(query: String) async {
        guard let paths else { return }
        await fileIndex.refresh(
            paths: paths, snapshot: snapshot, incarnations: folderIncarnationDigests, query: query, force: true)
    }

    func loadMoreIndexedItems() async {
        guard let paths else { return }
        await fileIndex.loadMore(paths: paths, snapshot: snapshot, incarnations: folderIncarnationDigests)
    }

    func refreshContentRetentionProjection() async {
        guard let paths else { return }
        await fileIndex.refresh(paths: paths, snapshot: snapshot, incarnations: folderIncarnationDigests, force: true)
    }

    func savePolicy(_ value: SyncPolicy) async {
        await savePolicy(value, temporaryProfiles: temporaryPolicyProfiles)
    }

    func savePolicy(
        _ value: SyncPolicy,
        temporaryProfiles: [TemporarySyncPolicyProfile]
    ) async {
        guard let paths else { return }
        do {
            let saved = try await Task.detached(priority: .utility) {
                try SyncPolicyStore(url: paths.policy).saveGlobalAndTemporaryProfiles(
                    global: value,
                    profiles: temporaryProfiles
                )
            }.value
            policy = saved.global
            self.temporaryPolicyProfiles = saved.temporaryProfiles
            recalculateDecision()
            // Apply enable/disable changes immediately: the scheduler cancels
            // request classes no longer permitted by the saved durable mode.
            BackgroundTaskManager.shared.scheduleNextTasks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Requests system notification permission only in response to the
    /// explicit Settings toggle. Passive refresh and background work never
    /// trigger an authorization prompt.
    func loadFolderPolicyConfiguration(
        for folder: FolderRecord
    ) async throws -> FolderPolicyConfiguration {
        guard let paths else {
            throw FolderPolicyEditingError.sharedContainerUnavailable
        }
        guard snapshot.folders.contains(where: { $0.id == folder.id }) else {
            throw FolderPolicyEditingError.folderConfigurationChanged
        }
        let folderID = folder.id
        let loaded = try await Task.detached(priority: .userInitiated) {
            let incarnationStore = FolderIncarnationStore(url: paths.folderIncarnations)
            let firstContext = try incarnationStore.policyContext(for: folderID)
            let configuration = try SyncPolicyStore(url: paths.policy)
                .folderPolicyConfiguration(for: firstContext)
            let finalContext = try incarnationStore.policyContext(for: folderID)
            guard firstContext == finalContext else {
                throw FolderPolicyEditingError.folderIncarnationChanged
            }
            return configuration
        }.value
        guard snapshot.folders.contains(where: { $0.id == folderID }) else {
            throw FolderPolicyEditingError.folderConfigurationChanged
        }
        return loaded
    }

    /// Saves against the context loaded by the editor, then verifies that the
    /// same incarnation is still current. If it changed at any point, the old
    /// override remains bound to the old digest and runtime resolution fails
    /// closed for a newly added folder with the same ID.
    func saveFolderPolicy(
        _ policyOverride: SyncPolicyOverride?,
        queuePriority: FolderQueuePriority,
        expectedContext: FolderPolicyContext,
        folder: FolderRecord
    ) async throws -> FolderPolicyConfiguration {
        guard let paths else {
            throw FolderPolicyEditingError.sharedContainerUnavailable
        }
        guard folder.id == expectedContext.folderID,
            snapshot.folders.contains(where: { $0.id == folder.id })
        else {
            throw FolderPolicyEditingError.folderConfigurationChanged
        }
        let saved = try await Task.detached(priority: .userInitiated) {
            let incarnationStore = FolderIncarnationStore(url: paths.folderIncarnations)
            guard
                try incarnationStore.policyContext(for: folder.id) == expectedContext
            else {
                throw FolderPolicyEditingError.folderIncarnationChanged
            }
            let configuration = try SyncPolicyStore(url: paths.policy).saveFolderPolicy(
                policyOverride,
                queuePriority: queuePriority,
                for: expectedContext
            )
            guard
                try incarnationStore.policyContext(for: folder.id) == expectedContext
            else {
                throw FolderPolicyEditingError.folderIncarnationChanged
            }
            return configuration
        }.value
        guard snapshot.folders.contains(where: { $0.id == folder.id }) else {
            throw FolderPolicyEditingError.folderConfigurationChanged
        }
        statusMessage = String(localized: "Folder policy and queue priority were saved.")
        return saved
    }

    func folderPolicyDecision(
        for folder: FolderRecord,
        effectivePolicy: SyncPolicy
    ) -> SyncPolicyDecision? {
        guard snapshot.folders.contains(where: { $0.id == folder.id }) else {
            return nil
        }
        return SyncPolicyEngine().evaluate(
            policyInput(
                actions: [.exchangeIndex, .upload, .download, .scan],
                trigger: .backgroundProcessing,
                folder: folder
            ),
            policy: effectivePolicy
        )
    }

    /// Creates a local, redacted JSON summary only after an explicit user
    /// action. The exporter reads App Group durable projections and never
    /// starts the core or performs network work.
    func prepareDiagnosticSummaryExport() async -> URL? {
        guard let paths else { return nil }
        let build = DiagnosticBuildMetadata(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unavailable",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unavailable",
            coreRevision: PlatformCoreBootstrap.coreRevision
        )
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PsyDiagnosticExports",
            isDirectory: true
        )
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                let exporter = DiagnosticSummaryExporter(
                    builder: DiagnosticSummaryBuilder(paths: paths, build: build)
                )
                try exporter.removeTemporaryExports(from: outputDirectory)
                return try exporter.export(to: outputDirectory)
            }.value
            statusMessage = String(localized: "Diagnostic summary is ready to share.")
            errorMessage = nil
            return url
        } catch {
            errorMessage = String(localized: "The diagnostic summary could not be created safely.")
            return nil
        }
    }

    func discardDiagnosticSummaryExport(at url: URL) async {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PsyDiagnosticExports",
            isDirectory: true
        )
        do {
            try await Task.detached(priority: .utility) {
                try DiagnosticSummaryExporter.removeExport(at: url, from: outputDirectory)
            }.value
        } catch {
            errorMessage = String(localized: "The temporary diagnostic summary could not be removed.")
        }
    }

    func addDevice(
        id: DeviceID,
        name: String,
        addresses: [String],
        paused: Bool
    ) async -> Bool {
        guard !snapshot.devices.contains(where: { $0.id == id }) else {
            errorMessage = String(localized: "A device with this ID already exists.")
            return false
        }
        return await submitDeviceConfiguration(
            kind: .addDevice,
            id: id,
            name: name,
            addresses: addresses,
            paused: paused
        )
    }

    func editDevice(
        id: DeviceID,
        name: String,
        addresses: [String],
        paused: Bool
    ) async -> Bool {
        guard snapshot.devices.lazy.filter({ $0.id == id }).count == 1 else {
            errorMessage = String(localized: "The device configuration changed. Refresh before trying again.")
            return false
        }
        return await submitDeviceConfiguration(
            kind: .editDevice,
            id: id,
            name: name,
            addresses: addresses,
            paused: paused
        )
    }

    func submitDeviceConfiguration(
        kind: CoreCommandKind,
        id: DeviceID,
        name: String,
        addresses: [String],
        paused: Bool
    ) async -> Bool {
        errorMessage = nil
        statusMessage = nil
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seenAddresses = Set<String>()
        let normalizedAddresses = addresses.compactMap { address -> String? in
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized =
                trimmed.caseInsensitiveCompare("dynamic") == .orderedSame
                ? "dynamic"
                : trimmed
            return seenAddresses.insert(normalized).inserted ? normalized : nil
        }
        let expectedAddresses = normalizedAddresses.isEmpty ? ["dynamic"] : normalizedAddresses
        guard let addressData = try? JSONEncoder().encode(expectedAddresses),
            let encodedAddresses = String(data: addressData, encoding: .utf8)
        else {
            errorMessage = String(localized: "The device addresses could not be encoded safely.")
            return false
        }
        let didSubmit = await submit(
            kind: kind,
            itemID: id.rawValue,
            arguments: [
                "name": normalizedName,
                "addresses": encodedAddresses,
                "paused": String(paused),
            ]
        )
        let matchingDevices = snapshot.devices.filter { $0.id == id }
        guard didSubmit,
            matchingDevices.count == 1,
            let configured = matchingDevices.first,
            configured.name == normalizedName,
            configured.addresses == expectedAddresses,
            configured.isPaused == paused
        else {
            errorMessage =
                errorMessage ?? statusMessage
                ?? String(
                    localized:
                        "The core did not confirm this device configuration in the latest snapshot. Keep the form open, review the request result, and try again."
                )
            return false
        }
        return true
    }

    func addManagedFolder(
        id: FolderID,
        label: String,
        type: FolderType,
        paused: Bool,
        deviceIDs: Set<DeviceID>,
        rescanIntervalS: Int
    ) async -> Bool {
        guard let paths else {
            errorMessage = ManagedFolderInputError.sharedContainerUnavailable.localizedDescription
            return false
        }
        do {
            let normalizedLabel = try validatedManagedFolderLabel(label)
            try validateManagedFolderID(id)
            guard !snapshot.folders.contains(where: { $0.id == id }) else {
                throw ManagedFolderInputError.duplicateFolderID
            }
            try validateRescanInterval(rescanIntervalS)
            let sharedDeviceIDs =
                deviceIDs
                .filter { $0 != snapshot.localDeviceID }
                .map(\.rawValue)
                .sorted()
            let encodedDevices = try JSONEncoder().encode(sharedDeviceIDs)
            guard let deviceList = String(data: encodedDevices, encoding: .utf8) else {
                throw ManagedFolderInputError.deviceListEncodingFailed
            }
            let managedURL = try await Task.detached(priority: .userInitiated) {
                try paths.createManagedFolder(for: id)
            }.value
            // Never remove this directory after creation. A previous attempt may have
            // already placed user data here, and queued configuration remains retryable.
            errorMessage = nil
            statusMessage = nil
            let didSubmit = await submit(
                kind: .addFolder,
                folderID: id,
                arguments: [
                    "label": normalizedLabel,
                    "path": managedURL.path,
                    "type": type.rawValue,
                    "paused": String(paused),
                    "deviceIDs": deviceList,
                    "rescanIntervalS": String(rescanIntervalS),
                ]
            )
            guard didSubmit,
                confirmsManagedFolderConfiguration(
                    id: id,
                    label: normalizedLabel,
                    localURL: managedURL,
                    type: type,
                    paused: paused,
                    deviceIDs: Set(deviceIDs.filter { $0 != snapshot.localDeviceID }),
                    rescanIntervalS: rescanIntervalS
                )
            else {
                preserveFolderConfigurationFailure()
                return false
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func editManagedFolder(
        _ folder: FolderRecord,
        label: String,
        type: FolderType,
        deviceIDs: Set<DeviceID>,
        rescanIntervalS: Int?,
        expectedFolderIncarnationDigest: String
    ) async -> Bool {
        do {
            let normalizedLabel = try validatedManagedFolderLabel(label)
            if let rescanIntervalS { try validateRescanInterval(rescanIntervalS) }
            let configuredPeerIDs = Set(
                snapshot.devices.compactMap { device in
                    device.id == snapshot.localDeviceID ? nil : device.id
                }
            )
            let sharedDeviceIDs = Set(deviceIDs.filter { $0 != snapshot.localDeviceID })
            guard sharedDeviceIDs.isSubset(of: configuredPeerIDs) else {
                throw ManagedFolderInputError.invalidDeviceSelection
            }
            let encodedDevices = try JSONEncoder().encode(
                sharedDeviceIDs.map(\.rawValue).sorted()
            )
            guard let deviceList = String(data: encodedDevices, encoding: .utf8) else {
                throw ManagedFolderInputError.deviceListEncodingFailed
            }
            var arguments = [
                "label": normalizedLabel,
                "type": type.rawValue,
                "deviceIDs": deviceList,
            ]
            if let rescanIntervalS {
                arguments["rescanIntervalS"] = String(rescanIntervalS)
            }
            errorMessage = nil
            statusMessage = nil
            let didSubmit = await submit(
                kind: .editFolder,
                folderID: folder.id,
                arguments: arguments,
                expectedFolderIncarnationDigest: expectedFolderIncarnationDigest
            )
            guard didSubmit,
                confirmsManagedFolderConfiguration(
                    id: folder.id,
                    label: normalizedLabel,
                    localURL: URL(fileURLWithPath: folder.localPath, isDirectory: true),
                    type: type,
                    paused: folder.isPaused,
                    deviceIDs: sharedDeviceIDs,
                    rescanIntervalS: rescanIntervalS ?? folder.rescanIntervalS
                )
            else {
                preserveFolderConfigurationFailure()
                return false
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func confirmsManagedFolderConfiguration(
        id: FolderID,
        label: String,
        localURL: URL,
        type: FolderType,
        paused: Bool,
        deviceIDs: Set<DeviceID>,
        rescanIntervalS: Int?
    ) -> Bool {
        let matchingFolders = snapshot.folders.filter { $0.id == id }
        guard matchingFolders.count == 1,
            let configured = matchingFolders.first,
            configured.label == label,
            URL(fileURLWithPath: configured.localPath, isDirectory: true).standardizedFileURL
                == localURL.standardizedFileURL,
            configured.type == type,
            configured.isPaused == paused,
            let configuredDeviceIDs = configured.deviceIDs,
            Set(configuredDeviceIDs) == deviceIDs,
            configuredDeviceIDs.count == deviceIDs.count,
            configured.rescanIntervalS == rescanIntervalS
        else {
            return false
        }
        return true
    }

    func preserveFolderConfigurationFailure() {
        errorMessage =
            errorMessage ?? statusMessage
            ?? String(
                localized:
                    "The core did not confirm this folder configuration in the latest snapshot. Keep the form open, review the request result, and try again."
            )
    }

    func isInternallyManagedFolder(_ folder: FolderRecord) -> Bool {
        guard let paths,
            let expected = try? paths.managedFolder(for: folder.id)
        else {
            return false
        }
        return URL(fileURLWithPath: folder.localPath).standardizedFileURL
            == expected.standardizedFileURL
    }

    func retentionApplicationContext(for folder: FolderRecord) throws -> FolderRetentionApplicationContext {
        guard let paths else { throw ManagedFolderInputError.sharedContainerUnavailable }
        let matches = snapshot.folders.filter { $0.id == folder.id }
        guard matches.count == 1, let current = matches.first,
            current.localPath == folder.localPath
        else {
            throw FolderSelectionContextError.folderConfigurationChanged
        }
        let incarnation = try FolderIncarnationStore(url: paths.folderIncarnations)
            .policyContext(for: current.id)
        return FolderRetentionApplicationContext(
            store: ContentRetentionStore(url: paths.contentRetention),
            folderIncarnationDigest: incarnation.folderIncarnationDigest
        )
    }

    var localDeviceIDText: String {
        snapshot.localDeviceID?.rawValue ?? String(localized: "Core identity is not available")
    }

    func validateManagedFolderID(_ id: FolderID) throws {
        guard id.rawValue.unicodeScalars.count <= 64,
            id.rawValue.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw ManagedFolderInputError.invalidFolderID
        }
    }

    func validatedManagedFolderLabel(_ label: String) throws -> String {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            normalized.utf8.count <= 256,
            normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw ManagedFolderInputError.invalidLabel
        }
        return normalized
    }

    func validateRescanInterval(_ value: Int) throws {
        guard (0...managedFolderMaximumRescanIntervalS).contains(value) else {
            throw ManagedFolderInputError.invalidRescanInterval
        }
    }

    func recalculateDecision() {
        currentDecision = SyncPolicyEngine().evaluate(
            policyInput(actions: [.exchangeIndex, .upload, .download], trigger: .foreground),
            policy: policy
        )
    }

    func policyInput(
        actions: Set<SyncAction>,
        trigger: SyncTrigger,
        override: Bool = false,
        folder: FolderRecord? = nil
    ) -> SyncPolicyInput {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let rawBattery = UIDevice.current.batteryLevel
        let battery = rawBattery < 0 ? nil : Double(rawBattery)
        let thermal: ThermalLevel
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .serious
        }
        let available =
            (try? paths?.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let folders = folder.map { [$0] } ?? snapshot.folders
        return SyncPolicyInput(
            trigger: trigger,
            requestedActions: actions,
            network: network,
            power: PowerState(
                batteryLevel: battery,
                isExternalPowerConnected: UIDevice.current.batteryState == .charging
                    || UIDevice.current.batteryState == .full,
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalLevel: thermal
            ),
            transfer: .init(
                largestFileBytes: 0,
                totalBytes: folders.reduce(0) {
                    $0 + $1.pendingDownloadBytes + $1.pendingUploadBytes
                },
                pendingDownloadBytes: folders.reduce(0) {
                    $0 + $1.pendingDownloadBytes
                }
            ),
            safety: .init(availableDiskBytes: available),
            requestedTemporaryOverride: override,
            safetyScope: .networkCoreRuntime
        )
    }

}
