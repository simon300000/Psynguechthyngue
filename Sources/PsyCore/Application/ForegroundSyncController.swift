import Foundation
import Observation

public enum ForegroundSyncActivity: Hashable, Sendable {
    case stopped
    case paused
    case running
    case waiting
    case blocked([PolicyBlockReason])
    case failed(String)
}

public struct ForegroundSyncCycle: Sendable {
    public var activity: ForegroundSyncActivity
    public var delay: Duration

    public init(_ activity: ForegroundSyncActivity, delay: Duration = .seconds(10)) {
        self.activity = activity
        self.delay = delay
    }
}

/// One foreground worker shared by every scene. A cancelled worker retains its
/// slot until native cancellation has drained; a new scene or a user operation
/// cannot start a replacement on top of it.
@MainActor
@Observable
public final class ForegroundSyncController {
    public private(set) var activity: ForegroundSyncActivity = .stopped
    public var isEnabled = false {
        didSet { reconcile() }
    }

    @ObservationIgnored private var scenes: Set<UUID> = []
    @ObservationIgnored private var suspensions = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var userOperations: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private let cycle: @MainActor () async -> ForegroundSyncCycle
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        cycle: @escaping @MainActor () async -> ForegroundSyncCycle,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.cycle = cycle
        self.sleep = sleep
    }

    public func setScene(_ id: UUID, active: Bool) {
        if active { scenes.insert(id) } else { scenes.remove(id) }
        reconcile()
    }

    /// Explicit operations get the next ownership opportunity. Cancellation
    /// propagates through the foreground runtime before the operation starts.
    public func withSuspension<T: Sendable>(
        _ operation: @escaping @MainActor () async -> T
    ) async -> T {
        suspensions += 1
        let precedingWorker = worker
        precedingWorker?.cancel()
        let id = UUID()
        let task = Task {
            await precedingWorker?.value
            return await operation()
        }
        userOperations[id] = { task.cancel() }
        defer {
            userOperations[id] = nil
            suspensions -= 1
            reconcile()
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Called on actual background entry, not temporary inactivity (such as
    /// system authentication). Native cancellation handlers then drain leases.
    public func cancelUserOperationsIfInactive() {
        guard scenes.isEmpty else { return }
        for cancel in userOperations.values { cancel() }
    }

    public func waitUntilStopped() async {
        await worker?.value
    }

    private var shouldRun: Bool { isEnabled && !scenes.isEmpty && suspensions == 0 }

    private func reconcile() {
        guard shouldRun else {
            worker?.cancel()
            if worker == nil { activity = isEnabled ? .stopped : .paused }
            return
        }
        guard worker == nil else { return }
        worker = Task {
            defer {
                worker = nil
                activity = isEnabled ? .stopped : .paused
                reconcile()
            }
            while !Task.isCancelled, shouldRun {
                activity = .running
                let result = await cycle()
                guard !Task.isCancelled, shouldRun else { break }
                activity = result.activity
                do { try await sleep(max(result.delay, .milliseconds(250))) } catch { break }
            }
        }
    }
}
