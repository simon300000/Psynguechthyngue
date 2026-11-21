import BackgroundTasks
import Foundation
import OSLog
import PsyCore

@MainActor
final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    nonisolated static var refreshIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "PsyRefreshTaskIdentifier") as? String ?? ""
    }
    nonisolated static var processingIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "PsyProcessingTaskIdentifier") as? String ?? ""
    }

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Psynguechthyngue",
        category: "BackgroundTasks"
    )
    private var didRegister = false

    func register() {
        guard !didRegister else { return }
        didRegister = true

        let refreshIdentifier = Self.refreshIdentifier
        if refreshIdentifier.isEmpty {
            Self.persistRegistrationFailure(kind: .refresh, code: .identifierMissing)
        } else {
            let registered = Self.registerRefreshHandler(identifier: refreshIdentifier)
            if !registered {
                Self.persistRegistrationFailure(kind: .refresh, code: .registrationFailed)
            }
        }

        let processingIdentifier = Self.processingIdentifier
        if processingIdentifier.isEmpty {
            Self.persistRegistrationFailure(kind: .processing, code: .identifierMissing)
        } else {
            let registered = Self.registerProcessingHandler(identifier: processingIdentifier)
            if !registered {
                Self.persistRegistrationFailure(kind: .processing, code: .registrationFailed)
            }
        }
    }

    /// BGTaskScheduler invokes launch handlers on its own queue. Define the
    /// closures in a nonisolated context so Swift 6 does not inherit this
    /// manager's MainActor isolation and trap before the handler body starts.
    nonisolated private static func registerRefreshHandler(identifier: String) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handle(refresh, trigger: .backgroundRefresh)
        }
    }

    nonisolated private static func registerProcessingHandler(identifier: String) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handle(processing, trigger: .backgroundProcessing)
        }
    }

    /// Requests future opportunities from iOS. `earliestBeginDate` is only a
    /// lower bound; the system chooses whether and when either task runs.
    func scheduleNextTasks() {
        let refreshIdentifier = Self.refreshIdentifier
        let processingIdentifier = Self.processingIdentifier
        Task.detached(priority: .utility) {
            _ = Self.submitNextTasks(
                refreshIdentifier: refreshIdentifier,
                processingIdentifier: processingIdentifier
            )
        }
    }

    nonisolated private static func handle(_ task: BGTask, trigger: SyncTrigger) {
        let taskBox = BackgroundTaskBox(task)
        let completion = OneShotCompletionGate<Bool> { success in
            taskBox.task.setTaskCompleted(success: success)
        }
        let cancellation = BackgroundWorkCancellation()
        let cancellationContext = CoreRunCancellationContext(endReason: .expired)
        let mirrorCancellation = ExternalDirectoryMirrorCancellation()

        taskBox.task.expirationHandler = {
            mirrorCancellation.cancel()
            cancellation.cancel()
        }

        let refreshIdentifier = Self.refreshIdentifier
        let processingIdentifier = Self.processingIdentifier
        let work = Task.detached(priority: .utility) { () -> Bool in
            guard let paths = try? SharedContainerPaths.resolve() else {
                Self.logger.error("Background execution failed [backgroundTaskContainerUnavailable]")
                return false
            }

            // Apple recommends submitting the next request at the beginning of
            // the launch handler. Awaiting the synchronous submission attempts
            // keeps them inside this task's granted execution window.
            let scheduling = Self.submitNextTasks(
                refreshIdentifier: refreshIdentifier,
                processingIdentifier: processingIdentifier,
                paths: paths
            )
            guard !Task.isCancelled else { return false }

            if trigger == .backgroundRefresh {
                guard scheduling.mode != .disabled else {
                    return scheduling.succeeded
                }
                guard
                    scheduling.mode == .refreshOnly
                        || scheduling.mode == .refreshAndProcessing
                else {
                    return false
                }
                // Refresh is intentionally local and bounded. It never consumes
                // queued commands or starts the embedded core.
                let outcome = BackgroundSnapshotRefreshService().run(paths: paths)
                guard outcome.completedSuccessfully, !Task.isCancelled else { return false }
                if case .validated = outcome,
                    let snapshot = try? SharedSnapshotStore(snapshotURL: paths.snapshot).read(),
                    !Task.isCancelled
                {
                    _ = await AppNotificationDelivery.deliver(
                        paths: paths,
                        snapshot: snapshot
                    )
                }
                return scheduling.succeeded && !Task.isCancelled
            }

            // A request submitted under an older policy may still be launched
            // after the user turns processing off. Re-check the same durable
            // policy used to cancel/resubmit requests before doing any work.
            guard scheduling.mode == .refreshAndProcessing else {
                return scheduling.mode == .disabled || scheduling.mode == .refreshOnly
                    ? scheduling.succeeded : false
            }

            await PlatformCoreBootstrap.install()
            let processingStartedAt = Date()
            let producedCommands: [CoreCommand]
            let insertedCommands: [CoreCommand]
            do {
                let invocationID = UUID()
                producedCommands = try ScopedCoreCommandProducer(paths: paths).prepareCommands(
                    invocationID: invocationID,
                    kind: .sync,
                    trigger: .backgroundProcessing
                )
                if producedCommands.isEmpty {
                    insertedCommands = []
                } else {
                    let queue = CoreCommandQueue(root: paths.commandQueue)
                    insertedCommands = try queue.enqueueBackgroundBatchIfNeeded(
                        producedCommands,
                        batchID: invocationID
                    )
                }
            } catch {
                Self.recordProcessingFailure(
                    paths: paths,
                    startedAt: processingStartedAt,
                    code: "backgroundProcessingQueueUnavailable"
                )
                return false
            }

            let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
            guard !Task.isCancelled else { return false }
            var outcome: CoreRunOutcome?
            let queue = CoreCommandQueue(root: paths.commandQueue)
            let insertedIDs = Set(insertedCommands.map(\.id))
            let maximumAttempts = max(1, insertedCommands.count)
            for _ in 0..<maximumAttempts {
                guard !Task.isCancelled else { return false }
                let current = await CoreRuntime.shared.processPending(
                    trigger: .backgroundProcessing,
                    paths: paths,
                    environment: environment,
                    currentEnvironment: {
                        await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                    },
                    cancellationContext: cancellationContext
                )
                outcome = current
                let completedOwnCount = insertedIDs.reduce(into: 0) { count, id in
                    if (try? queue.result(for: id)) != nil { count += 1 }
                }
                if completedOwnCount == insertedIDs.count, !insertedIDs.isEmpty { break }
                guard case .completed = current else { break }
            }
            guard !Task.isCancelled else { return false }

            // Pending-folder discovery is allowed only because iOS has
            // launched this processing handler. The shared opportunity runner
            // claims a rotating, finite device batch before opening any core
            // work; merely scheduling the next task never reaches this path.
            let discoverySnapshot: CoreSnapshot
            do {
                guard
                    let latest = try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
                else {
                    Self.recordProcessingFailure(
                        paths: paths,
                        startedAt: processingStartedAt,
                        code: "backgroundPendingFolderDiscoverySnapshotUnavailable"
                    )
                    return false
                }
                discoverySnapshot = latest
            } catch {
                Self.recordProcessingFailure(
                    paths: paths,
                    startedAt: processingStartedAt,
                    code: "backgroundPendingFolderDiscoverySnapshotUnavailable"
                )
                return false
            }
            let discoveryEnvironment = await SyncEnvironmentSnapshot.captureSystemState(
                paths: paths
            )
            let discoveryReport = await PendingFolderDiscoveryOpportunity.run(
                snapshot: discoverySnapshot,
                trigger: .backgroundProcessing,
                paths: paths,
                environment: discoveryEnvironment,
                currentEnvironment: {
                    await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                }
            )
            guard !Task.isCancelled else { return false }

            // Processing is a retry opportunity even when this run found no
            // new generation; the durable store may contain an older failure.
            _ = await FileProviderDomainManager.signalWorkingSetChanges()
            let retentionSucceeded = await FileProviderStorageActionService()
                .reconcilePendingWork(
                    trigger: .backgroundProcessing,
                    maximumItems: 32
                )

            var mirrorsSucceeded: Bool
            do {
                let broker = ExternalDirectoryAccessBroker(
                    recordsURL: paths.externalDirectoryRecords,
                    managedRootsURL: paths.externalManagedFoldersRoot
                )
                try await broker.load()
                let executions = await broker.runEligibleMirrors(
                    trigger: .backgroundProcessing,
                    maximumRecords: 2,
                    cancellation: mirrorCancellation,
                    currentEnvironment: {
                        await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                    }
                )
                mirrorsSucceeded = !executions.contains {
                    $0.status.phase == .retryableFailure || $0.status.phase == .cancelled
                }
                if mirrorsSucceeded {
                    // Successful managed-root mirror mutations durably enqueue
                    // an exact-folder rescan in the broker. Give those rescans
                    // the same granted background window; policy denial or a
                    // busy owner leaves the durable command pending.
                    let rescanEnvironment = await SyncEnvironmentSnapshot.captureSystemState(
                        paths: paths
                    )
                    let rescanOutcome = await CoreRuntime.shared.processPending(
                        trigger: .backgroundProcessing,
                        paths: paths,
                        environment: rescanEnvironment,
                        currentEnvironment: {
                            await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                        },
                        cancellationContext: cancellationContext
                    )
                    switch rescanOutcome {
                    case .completed, .policyDenied, .coreBusy:
                        break
                    case .configurationUnavailable, .failed:
                        mirrorsSucceeded = false
                    }
                }
            } catch {
                Self.recordProcessingFailure(
                    paths: paths,
                    startedAt: processingStartedAt,
                    code: "backgroundMirrorPreparationFailed"
                )
                return false
            }

            guard !Task.isCancelled, !mirrorCancellation.isCancelled else { return false }
            let coreSucceeded: Bool
            switch outcome {
            case .completed?, .policyDenied?, .coreBusy?, nil:
                coreSucceeded = true
            case .configurationUnavailable?, .failed?:
                coreSucceeded = false
            }
            let succeeded =
                scheduling.succeeded && coreSucceeded && discoveryReport.allowsBackgroundCompletion
                && mirrorsSucceeded && retentionSucceeded
            guard succeeded, !Task.isCancelled, !mirrorCancellation.isCancelled else {
                return false
            }
            if let snapshot = try? SharedSnapshotStore(snapshotURL: paths.snapshot).read(),
                !Task.isCancelled
            {
                _ = await AppNotificationDelivery.deliver(
                    paths: paths,
                    snapshot: snapshot
                )
            }
            return !Task.isCancelled
        }

        cancellation.install { work.cancel() }
        Task.detached(priority: .utility) {
            let success = await work.value
            let completedBeforeExpiration = !cancellation.wasCancelled
            cancellation.clear()
            completion.complete(success && completedBeforeExpiration)
        }
    }

    nonisolated private static func submitNextTasks(
        refreshIdentifier: String,
        processingIdentifier: String,
        paths suppliedPaths: SharedContainerPaths? = nil
    ) -> (succeeded: Bool, mode: AutomaticBackgroundMode?) {
        let paths: SharedContainerPaths
        do {
            paths = try suppliedPaths ?? SharedContainerPaths.resolve()
        } catch {
            logger.error("Background scheduling failed [backgroundTaskContainerUnavailable]")
            return (false, nil)
        }

        let attemptedAt = Date()
        let policy: SyncPolicy
        do {
            policy = try SyncPolicyStore(url: paths.policy).load()
        } catch {
            for (kind, requiresNetwork) in [
                (ScheduledBackgroundTaskKind.refresh, false),
                (.processing, true),
            ] {
                _ = record(
                    .init(
                        kind: kind,
                        attemptedAt: attemptedAt,
                        earliestBeginDate: nil,
                        requiresNetworkConnectivity: requiresNetwork,
                        requiresExternalPower: false,
                        result: .failed,
                        failureCode: .policyUnreadable
                    ),
                    paths: paths
                )
            }
            if !refreshIdentifier.isEmpty {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
            }
            if !processingIdentifier.isEmpty {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingIdentifier)
            }
            return (false, nil)
        }

        // Scheduling remains possible when the snapshot is absent or corrupt;
        // the launched handler records the exact validation/runtime failure.
        let snapshot = try? SharedSnapshotStore(snapshotURL: paths.snapshot).read()

        let plan = BackgroundTaskSchedulePlanner().makePlan(
            now: attemptedAt,
            policy: policy,
            snapshot: snapshot ?? nil
        )

        let refreshSucceeded: Bool
        if !plan.refreshEnabled {
            if !refreshIdentifier.isEmpty {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
            }
            refreshSucceeded = record(
                .init(
                    kind: .refresh,
                    attemptedAt: attemptedAt,
                    earliestBeginDate: nil,
                    requiresNetworkConnectivity: false,
                    requiresExternalPower: false,
                    result: .disabled
                ),
                paths: paths
            )
        } else if refreshIdentifier.isEmpty {
            _ = record(
                .init(
                    kind: .refresh,
                    attemptedAt: attemptedAt,
                    earliestBeginDate: nil,
                    requiresNetworkConnectivity: false,
                    requiresExternalPower: false,
                    result: .failed,
                    failureCode: .identifierMissing
                ),
                paths: paths
            )
            refreshSucceeded = false
        } else {
            let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
            request.earliestBeginDate = plan.refreshEarliestBeginDate
            refreshSucceeded = submit(
                request,
                attempt: .init(
                    kind: .refresh,
                    attemptedAt: attemptedAt,
                    earliestBeginDate: request.earliestBeginDate,
                    requiresNetworkConnectivity: false,
                    requiresExternalPower: false,
                    result: .scheduled
                ),
                paths: paths
            )
        }

        let processingSucceeded: Bool
        if !plan.processingEnabled {
            if !processingIdentifier.isEmpty {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingIdentifier)
            }
            processingSucceeded = record(
                .init(
                    kind: .processing,
                    attemptedAt: attemptedAt,
                    earliestBeginDate: nil,
                    requiresNetworkConnectivity: plan.processingRequiresNetworkConnectivity,
                    requiresExternalPower: plan.processingRequiresExternalPower,
                    result: .disabled
                ),
                paths: paths
            )
        } else if processingIdentifier.isEmpty {
            _ = record(
                .init(
                    kind: .processing,
                    attemptedAt: attemptedAt,
                    earliestBeginDate: nil,
                    requiresNetworkConnectivity: plan.processingRequiresNetworkConnectivity,
                    requiresExternalPower: plan.processingRequiresExternalPower,
                    result: .failed,
                    failureCode: .identifierMissing
                ),
                paths: paths
            )
            processingSucceeded = false
        } else {
            let request = BGProcessingTaskRequest(identifier: processingIdentifier)
            request.requiresNetworkConnectivity = plan.processingRequiresNetworkConnectivity
            request.requiresExternalPower = plan.processingRequiresExternalPower
            request.earliestBeginDate = plan.processingEarliestBeginDate
            processingSucceeded = submit(
                request,
                attempt: .init(
                    kind: .processing,
                    attemptedAt: attemptedAt,
                    earliestBeginDate: request.earliestBeginDate,
                    requiresNetworkConnectivity: request.requiresNetworkConnectivity,
                    requiresExternalPower: request.requiresExternalPower,
                    result: .scheduled
                ),
                paths: paths
            )
        }
        return (refreshSucceeded && processingSucceeded, policy.automaticBackgroundMode)
    }

    nonisolated private static func submit(
        _ request: BGTaskRequest,
        attempt: BackgroundTaskScheduleAttempt,
        paths: SharedContainerPaths
    ) -> Bool {
        do {
            try BGTaskScheduler.shared.submit(request)
            return record(attempt, paths: paths)
        } catch {
            var failedAttempt = attempt
            failedAttempt.result = .failed
            failedAttempt.failureCode = scheduleFailureCode(for: error)
            _ = record(failedAttempt, paths: paths)
            logger.error(
                "Background scheduling failed [\(failedAttempt.failureCode?.rawValue ?? "backgroundTaskSubmissionFailed", privacy: .public)]"
            )
            return false
        }
    }

    nonisolated private static func scheduleFailureCode(for error: Error) -> BackgroundTaskScheduleFailureCode {
        let nsError = error as NSError
        guard nsError.domain == BGTaskScheduler.errorDomain,
            let code = BGTaskScheduler.Error.Code(rawValue: nsError.code)
        else {
            return .submissionFailed
        }
        switch code {
        case .unavailable:
            return .schedulerUnavailable
        case .tooManyPendingTaskRequests:
            return .tooManyPendingRequests
        case .notPermitted:
            return .notPermitted
        default:
            return .submissionFailed
        }
    }

    nonisolated private static func persistRegistrationFailure(
        kind: ScheduledBackgroundTaskKind,
        code: BackgroundTaskScheduleFailureCode
    ) {
        Task.detached(priority: .utility) {
            guard let paths = try? SharedContainerPaths.resolve() else {
                logger.error("Background registration failed [\(code.rawValue, privacy: .public)]")
                return
            }
            _ = record(
                .init(
                    kind: kind,
                    attemptedAt: .now,
                    earliestBeginDate: nil,
                    requiresNetworkConnectivity: kind == .processing,
                    requiresExternalPower: false,
                    result: .failed,
                    failureCode: code
                ),
                paths: paths
            )
        }
    }

    nonisolated private static func record(
        _ attempt: BackgroundTaskScheduleAttempt,
        paths: SharedContainerPaths
    ) -> Bool {
        do {
            try BackgroundTaskScheduleStatusStore(url: paths.backgroundTaskScheduleStatus).record(attempt)
            return true
        } catch {
            logger.error("Background scheduler status write failed [backgroundTaskStatusWriteFailed]")
            return false
        }
    }

    nonisolated private static func recordProcessingFailure(
        paths: SharedContainerPaths,
        startedAt: Date,
        code: String
    ) {
        do {
            try SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: .backgroundProcessing,
                    startedAt: startedAt,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: 0,
                    networkSentBytes: 0,
                    endReason: .failed,
                    failureCode: code
                )
            )
        } catch {
            logger.error("Background processing history write failed [backgroundProcessingHistoryWriteFailed]")
        }
    }
}

private final class BackgroundTaskBox: @unchecked Sendable {
    let task: BGTask
    init(_ task: BGTask) { self.task = task }
}

private final class BackgroundWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var action: (@Sendable () -> Void)?

    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            action()
            return
        }
        self.action = action
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let action = action
        self.action = nil
        lock.unlock()
        action?()
    }

    func clear() {
        lock.lock()
        action = nil
        lock.unlock()
    }

    var wasCancelled: Bool {
        lock.withLock { isCancelled }
    }
}

struct PendingFolderDiscoveryOpportunityReport: Sendable {
    enum Outcome: Sendable {
        case completed
        case noEligibleDevices
        case cancelled
        case configurationChanged
        case environmentChanged
        case policyDenied
        case coreBusy
        case configurationUnavailable
        case failed
    }

    let outcome: Outcome
    let selectedDeviceCount: Int
    let attemptedDeviceCount: Int
    let completedDeviceCount: Int
    let discoveredOfferCount: Int
    let offersTruncated: Bool

    var allowsBackgroundCompletion: Bool {
        switch outcome {
        case .completed, .noEligibleDevices, .policyDenied, .coreBusy:
            true
        case .cancelled, .configurationChanged, .environmentChanged,
            .configurationUnavailable, .failed:
            false
        }
    }
}

/// Shared by the foreground button and a processing task that iOS has already
/// launched. It selects at most two configured, unpaused peers per opportunity
/// and advances a numeric cursor before any networking begins. The durable
/// cursor never contains a device identifier or any connection metadata.
enum PendingFolderDiscoveryOpportunity {
    static let maximumDevicesPerOpportunity = 2

    static func eligibleDeviceCount(in snapshot: CoreSnapshot) -> Int {
        eligibleDeviceIDs(in: snapshot).count
    }

    static func run(
        snapshot: CoreSnapshot,
        trigger: SyncTrigger,
        paths: SharedContainerPaths,
        environment: SyncEnvironmentSnapshot,
        currentEnvironment: @escaping @Sendable () async -> SyncEnvironmentSnapshot
    ) async -> PendingFolderDiscoveryOpportunityReport {
        let targets = await PendingFolderDiscoveryRotation.shared.claimEligibleDeviceIDs(
            in: snapshot
        )
        guard !targets.isEmpty else {
            return report(outcome: .noEligibleDevices, selectedDeviceCount: 0)
        }

        var attemptedDeviceCount = 0
        var completedDeviceCount = 0
        var discoveredOfferCount = 0
        var offersTruncated = false

        for target in targets {
            guard !Task.isCancelled else {
                return report(
                    outcome: .cancelled,
                    selectedDeviceCount: targets.count,
                    attemptedDeviceCount: attemptedDeviceCount,
                    completedDeviceCount: completedDeviceCount,
                    discoveredOfferCount: discoveredOfferCount,
                    offersTruncated: offersTruncated
                )
            }
            attemptedDeviceCount += 1
            let outcome = await CoreRuntime.shared.discoverPendingFolderOffers(
                offeringDeviceID: target,
                trigger: trigger,
                paths: paths,
                environment: environment,
                currentEnvironment: currentEnvironment
            )
            if Task.isCancelled {
                return report(
                    outcome: .cancelled,
                    selectedDeviceCount: targets.count,
                    attemptedDeviceCount: attemptedDeviceCount,
                    completedDeviceCount: completedDeviceCount,
                    discoveredOfferCount: discoveredOfferCount,
                    offersTruncated: offersTruncated
                )
            }

            switch outcome {
            case .completed(let capture, _, _):
                completedDeviceCount += 1
                discoveredOfferCount += capture.offers.count
                offersTruncated = offersTruncated || capture.truncated
            case .coreBusy:
                return report(
                    outcome: .coreBusy,
                    selectedDeviceCount: targets.count,
                    attemptedDeviceCount: attemptedDeviceCount,
                    completedDeviceCount: completedDeviceCount,
                    discoveredOfferCount: discoveredOfferCount,
                    offersTruncated: offersTruncated
                )
            case .configurationUnavailable:
                return report(
                    outcome: .configurationUnavailable,
                    selectedDeviceCount: targets.count,
                    attemptedDeviceCount: attemptedDeviceCount,
                    completedDeviceCount: completedDeviceCount,
                    discoveredOfferCount: discoveredOfferCount,
                    offersTruncated: offersTruncated
                )
            case .policyDenied:
                return report(
                    outcome: .policyDenied,
                    selectedDeviceCount: targets.count,
                    attemptedDeviceCount: attemptedDeviceCount,
                    completedDeviceCount: completedDeviceCount,
                    discoveredOfferCount: discoveredOfferCount,
                    offersTruncated: offersTruncated
                )
            case .failed(let code):
                let failureOutcome: PendingFolderDiscoveryOpportunityReport.Outcome
                if code == "cancelled" {
                    failureOutcome = .cancelled
                } else if configurationChangeCodes.contains(code) {
                    failureOutcome = .configurationChanged
                } else if code == "budget_day_changed" {
                    failureOutcome = .environmentChanged
                } else if code == "policyConfigurationUnavailable" {
                    failureOutcome = .configurationUnavailable
                } else {
                    failureOutcome = .failed
                }
                return report(
                    outcome: failureOutcome,
                    selectedDeviceCount: targets.count,
                    attemptedDeviceCount: attemptedDeviceCount,
                    completedDeviceCount: completedDeviceCount,
                    discoveredOfferCount: discoveredOfferCount,
                    offersTruncated: offersTruncated
                )
            }
        }

        return report(
            outcome: .completed,
            selectedDeviceCount: targets.count,
            attemptedDeviceCount: attemptedDeviceCount,
            completedDeviceCount: completedDeviceCount,
            discoveredOfferCount: discoveredOfferCount,
            offersTruncated: offersTruncated
        )
    }

    fileprivate static func eligibleDeviceIDs(in snapshot: CoreSnapshot) -> [DeviceID] {
        snapshot.devices
            .filter {
                $0.id != snapshot.localDeviceID && !$0.isPaused && $0.state != .paused
            }
            .map(\.id)
            .sorted { $0.rawValue < $1.rawValue }
    }

    private static let configurationChangeCodes: Set<String> = [
        "configuration_revision_changed",
        "offering_device_not_configured",
        "offering_device_paused",
    ]

    private static func report(
        outcome: PendingFolderDiscoveryOpportunityReport.Outcome,
        selectedDeviceCount: Int,
        attemptedDeviceCount: Int = 0,
        completedDeviceCount: Int = 0,
        discoveredOfferCount: Int = 0,
        offersTruncated: Bool = false
    ) -> PendingFolderDiscoveryOpportunityReport {
        PendingFolderDiscoveryOpportunityReport(
            outcome: outcome,
            selectedDeviceCount: selectedDeviceCount,
            attemptedDeviceCount: attemptedDeviceCount,
            completedDeviceCount: completedDeviceCount,
            discoveredOfferCount: discoveredOfferCount,
            offersTruncated: offersTruncated
        )
    }
}

private actor PendingFolderDiscoveryRotation {
    static let shared = PendingFolderDiscoveryRotation()

    private static let defaultsKey = "PendingFolderDiscoveryNextOffsetV1"
    private let defaults: UserDefaults
    private var nextOffset: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        nextOffset = max(0, defaults.integer(forKey: Self.defaultsKey))
    }

    func claimEligibleDeviceIDs(in snapshot: CoreSnapshot) -> [DeviceID] {
        let eligible = PendingFolderDiscoveryOpportunity.eligibleDeviceIDs(in: snapshot)
        guard !eligible.isEmpty else { return [] }
        let start = nextOffset % eligible.count
        let count = min(
            PendingFolderDiscoveryOpportunity.maximumDevicesPerOpportunity,
            eligible.count
        )
        let claimed = (0..<count).map { eligible[(start + $0) % eligible.count] }
        nextOffset = (start + count) % eligible.count
        defaults.set(nextOffset, forKey: Self.defaultsKey)
        return claimed
    }
}
