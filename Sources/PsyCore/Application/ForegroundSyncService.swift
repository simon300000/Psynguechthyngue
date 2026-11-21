import Foundation

/// App-owned automatic orchestration. It uses the same durable commands,
/// retention-aware producer, policy and process ownership as manual/BG work.
/// Each pass advances at most one command and yields ownership to Files.
public actor ForegroundSyncService {
    private var schedule = ForegroundFolderSchedule()
    private let runtime: CoreRuntime

    public init(runtime: CoreRuntime = .shared) {
        self.runtime = runtime
    }

    public func runCycle(
        paths: SharedContainerPaths,
        environment: SyncEnvironmentSnapshot,
        currentEnvironment: @escaping @Sendable () async -> SyncEnvironmentSnapshot
    ) async -> ForegroundSyncCycle {
        do {
            try Task.checkCancellation()
            guard let snapshot = try SharedSnapshotStore(snapshotURL: paths.snapshot).read(),
                snapshot.configurationRevision != nil
            else { return .init(.failed("configurationUnavailable"), delay: .seconds(30)) }

            let queue = CoreCommandQueue(root: paths.commandQueue)
            if let folder = schedule.next(in: snapshot) {
                let context = try FolderIncarnationStore(url: paths.folderIncarnations)
                    .policyContext(for: folder.id)
                // Preparing through the producer preserves selective-folder
                // upload/index behavior; never turn On Demand into full sync.
                let command = try ScopedCoreCommandProducer(paths: paths).prepareCommands(
                    kind: .sync,
                    folderID: folder.id,
                    arguments: ["timeoutMS": "15000", "settleMS": "500"],
                    expectedFolderIncarnationDigest: context.folderIncarnationDigest,
                    trigger: .foreground
                ).first
                if let command {
                    let policy = try SyncPolicyStore(url: paths.policy).loadDocument()
                        .resolvedPolicy(for: folder.id, folderIncarnationDigest: context.folderIncarnationDigest)
                    let decision = SyncPolicyEngine().evaluate(
                        environment.policyInput(
                            trigger: .foreground,
                            requestedActions: command.kind.networkCorePolicyActions,
                            safetyScope: .networkCoreRuntime
                        ),
                        policy: policy
                    )
                    if decision.blockedActions.isEmpty {
                        try Task.checkCancellation()
                        _ = try queue.enqueueForegroundSyncIfNeeded(command)
                    } else if try queue.pending(limit: 1).isEmpty {
                        return .init(.blocked(decision.explanations.map(\.reason)), delay: .seconds(15))
                    }
                }
            }

            guard try !queue.pending(limit: 1).isEmpty else {
                return .init(.waiting, delay: .seconds(15))
            }
            try Task.checkCancellation()
            let pendingBefore = try queue.pending(limit: .max)
            let started = Date()
            let outcome = await runtime.processPending(
                trigger: .foreground,
                paths: paths,
                environment: environment,
                currentEnvironment: currentEnvironment
            )
            switch outcome {
            case .completed:
                let freshResults = try pendingBefore.compactMap { try queue.result(for: $0.id) }
                    .filter { $0.completedAt >= started.addingTimeInterval(-1) }
                if let failure = freshResults.first(where: { $0.status == .blocked || $0.status == .failed }) {
                    return .init(.failed(failure.errorCode ?? "commandFailed"), delay: .seconds(30))
                }
                let needsAnotherSlice = freshResults.contains { $0.status == .retryable }
                return .init(.waiting, delay: needsAnotherSlice ? .seconds(5) : .seconds(30))
            case .coreBusy:
                return .init(.waiting, delay: .seconds(3))
            case .policyDenied(let reasons):
                return .init(.blocked(reasons), delay: .seconds(15))
            case .configurationUnavailable:
                return .init(.failed("configurationUnavailable"), delay: .seconds(30))
            case .failed(let code):
                // A short native slice can finish before a large transfer or
                // disconnected peer settles. Continue on a later opportunity.
                if code == "sync_incomplete" || code == "sync_cancelled" {
                    return .init(.waiting, delay: .seconds(5))
                }
                return .init(.failed(code), delay: .seconds(30))
            }
        } catch is CancellationError {
            return .init(.stopped)
        } catch {
            return .init(.failed("foregroundSyncPreparationFailed"), delay: .seconds(30))
        }
    }
}
