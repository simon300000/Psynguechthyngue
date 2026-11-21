import Foundation

/// Shared result handling for App and Shortcuts. Runtime completion means a
/// queue step ran; only durable results establish operation completion.
public struct CoreCommandExecutor: Sendable {
    private let runtime: CoreRuntime

    public init(runtime: CoreRuntime = .shared) { self.runtime = runtime }

    public func execute(
        _ commands: [CoreCommand],
        trigger: SyncTrigger,
        paths: SharedContainerPaths,
        environment: SyncEnvironmentSnapshot,
        currentEnvironment: @escaping @Sendable () async -> SyncEnvironmentSnapshot,
        maximumPasses: Int = CoreCommandQueue.maximumBatchCommands,
        timeout: Duration = .seconds(120)
    ) async -> CommandExecutionReport {
        let ids = Set(commands.map(\.id))
        let queue = CoreCommandQueue(root: paths.commandQueue)
        let pendingCount = (try? queue.pending(limit: .max).count) ?? commands.count
        let maximumAttempts = min(
            maximumPasses, CoreCommandQueue.maximumBatchCommands, max(commands.count, pendingCount))
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var outcome: CoreRunOutcome?
        var results = readResults(ids, queue: queue)
        var advancedPasses = 0
        while advancedPasses < maximumAttempts {
            guard !Task.isCancelled, ContinuousClock.now < deadline, results.count < ids.count else { break }
            let resultCountBefore = results.count
            let pendingBefore = try? Set(queue.pending(limit: .max).map(\.id))
            outcome = await runtime.processPending(
                trigger: trigger, paths: paths, environment: environment,
                currentEnvironment: currentEnvironment
            )
            // Failures can also publish durable results. Always read them before
            // returning, even when the runtime outcome itself is unsuccessful.
            results = readResults(ids, queue: queue)
            if case .coreBusy = outcome {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
                continue
            }
            advancedPasses += 1
            guard case .completed = outcome else { break }
            let pendingAfter = try? Set(queue.pending(limit: .max).map(\.id))
            if pendingBefore == pendingAfter, results.count == resultCountBefore { break }
        }
        return CommandExecutionReport(commands: commands, results: results, outcome: outcome)
    }

    private func readResults(_ ids: Set<UUID>, queue: CoreCommandQueue) -> [UUID: CoreCommandResult] {
        ids.reduce(into: [:]) { results, id in
            if let result = try? queue.result(for: id) { results[id] = result }
        }
    }
}
