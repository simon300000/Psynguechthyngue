import Foundation

public enum ScheduledBackgroundTaskKind: String, Codable, CaseIterable, Sendable {
    case refresh
    case processing
}

public enum BackgroundTaskScheduleResult: String, Codable, Sendable {
    case scheduled
    case disabled
    case failed
}

/// Stable, non-sensitive reason codes for background scheduler failures.
/// Raw `NSError` text is deliberately not persisted because it may change
/// across OS releases and is not suitable for user-visible run diagnostics.
public enum BackgroundTaskScheduleFailureCode: String, Codable, CaseIterable, Sendable {
    case identifierMissing = "backgroundTaskIdentifierMissing"
    case registrationFailed = "backgroundTaskRegistrationFailed"
    case containerUnavailable = "backgroundTaskContainerUnavailable"
    case policyUnreadable = "backgroundTaskPolicyUnreadable"
    case snapshotUnreadable = "backgroundTaskSnapshotUnreadable"
    case schedulerUnavailable = "backgroundTaskSchedulerUnavailable"
    case tooManyPendingRequests = "backgroundTaskTooManyPendingRequests"
    case notPermitted = "backgroundTaskNotPermitted"
    case submissionFailed = "backgroundTaskSubmissionFailed"
}

public struct BackgroundTaskScheduleAttempt: Codable, Hashable, Sendable {
    public var kind: ScheduledBackgroundTaskKind
    public var attemptedAt: Date
    public var earliestBeginDate: Date?
    public var requiresNetworkConnectivity: Bool
    public var requiresExternalPower: Bool
    public var result: BackgroundTaskScheduleResult
    public var failureCode: BackgroundTaskScheduleFailureCode?

    public init(
        kind: ScheduledBackgroundTaskKind,
        attemptedAt: Date,
        earliestBeginDate: Date?,
        requiresNetworkConnectivity: Bool,
        requiresExternalPower: Bool,
        result: BackgroundTaskScheduleResult,
        failureCode: BackgroundTaskScheduleFailureCode? = nil
    ) {
        self.kind = kind
        self.attemptedAt = attemptedAt
        self.earliestBeginDate = earliestBeginDate
        self.requiresNetworkConnectivity = requiresNetworkConnectivity
        self.requiresExternalPower = requiresExternalPower
        self.result = result
        self.failureCode = result == .failed ? (failureCode ?? .submissionFailed) : nil
    }
}

public struct BackgroundTaskScheduleStatus: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var refresh: BackgroundTaskScheduleAttempt?
    public var processing: BackgroundTaskScheduleAttempt?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        refresh: BackgroundTaskScheduleAttempt? = nil,
        processing: BackgroundTaskScheduleAttempt? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.refresh = refresh
        self.processing = processing
    }

    public mutating func record(_ attempt: BackgroundTaskScheduleAttempt) {
        switch attempt.kind {
        case .refresh:
            refresh = attempt
        case .processing:
            processing = attempt
        }
    }
}

public enum BackgroundTaskScheduleStatusStoreError: Error, Hashable, Sendable {
    case unsupportedSchema(Int)
}

public struct BackgroundTaskScheduleStatusStore: Sendable {
    private let url: URL
    private let lockURL: URL

    public init(url: URL) {
        self.url = url
        lockURL = url.appendingPathExtension("lock")
    }

    public func read() throws -> BackgroundTaskScheduleStatus {
        try FileLock.withExclusiveLock(at: lockURL) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return BackgroundTaskScheduleStatus()
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let status = try decoder.decode(BackgroundTaskScheduleStatus.self, from: Data(contentsOf: url))
            guard status.schemaVersion == BackgroundTaskScheduleStatus.currentSchemaVersion else {
                throw BackgroundTaskScheduleStatusStoreError.unsupportedSchema(status.schemaVersion)
            }
            return status
        }
    }

    public func record(_ attempt: BackgroundTaskScheduleAttempt) throws {
        try FileLock.withExclusiveLock(at: lockURL) {
            var status: BackgroundTaskScheduleStatus
            if FileManager.default.fileExists(atPath: url.path) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                status = try decoder.decode(BackgroundTaskScheduleStatus.self, from: Data(contentsOf: url))
                guard status.schemaVersion == BackgroundTaskScheduleStatus.currentSchemaVersion else {
                    throw BackgroundTaskScheduleStatusStoreError.unsupportedSchema(status.schemaVersion)
                }
            } else {
                status = BackgroundTaskScheduleStatus()
            }
            status.record(attempt)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            #if os(iOS)
                let options: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
            #else
                let options: Data.WritingOptions = [.atomic]
            #endif
            try encoder.encode(status).write(to: url, options: options)
        }
    }
}

public struct BackgroundTaskSchedulePlan: Hashable, Sendable {
    public var refreshEnabled: Bool
    public var processingEnabled: Bool
    public var refreshEarliestBeginDate: Date
    public var processingEarliestBeginDate: Date
    public var processingRequiresNetworkConnectivity: Bool
    public var processingRequiresExternalPower: Bool
    public var estimatedPendingTransferBytes: Int64

    public init(
        refreshEnabled: Bool,
        processingEnabled: Bool,
        refreshEarliestBeginDate: Date,
        processingEarliestBeginDate: Date,
        processingRequiresNetworkConnectivity: Bool,
        processingRequiresExternalPower: Bool,
        estimatedPendingTransferBytes: Int64
    ) {
        self.refreshEnabled = refreshEnabled
        self.processingEnabled = processingEnabled
        self.refreshEarliestBeginDate = refreshEarliestBeginDate
        self.processingEarliestBeginDate = processingEarliestBeginDate
        self.processingRequiresNetworkConnectivity = processingRequiresNetworkConnectivity
        self.processingRequiresExternalPower = processingRequiresExternalPower
        self.estimatedPendingTransferBytes = max(0, estimatedPendingTransferBytes)
    }
}

/// Produces scheduler hints from the same persisted policy used at execution
/// time. These are requests to iOS, not promises about when work will run.
public struct BackgroundTaskSchedulePlanner: Sendable {
    public var refreshDelay: TimeInterval
    public var processingDelay: TimeInterval

    public init(
        refreshDelay: TimeInterval = 30 * 60,
        processingDelay: TimeInterval = 60 * 60
    ) {
        self.refreshDelay = max(0, refreshDelay)
        self.processingDelay = max(0, processingDelay)
    }

    public func makePlan(
        now: Date,
        policy: SyncPolicy,
        snapshot: CoreSnapshot?
    ) -> BackgroundTaskSchedulePlan {
        let pendingBytes = Self.pendingTransferBytes(in: snapshot)
        let largeTransferRequiresPower =
            policy.requirePowerForLargeTransferBytes.map {
                pendingBytes >= max(0, $0)
            } ?? false
        return BackgroundTaskSchedulePlan(
            refreshEnabled: policy.automaticBackgroundMode != .disabled,
            processingEnabled: policy.automaticBackgroundMode == .refreshAndProcessing,
            refreshEarliestBeginDate: now.addingTimeInterval(refreshDelay),
            processingEarliestBeginDate: now.addingTimeInterval(processingDelay),
            processingRequiresNetworkConnectivity: true,
            processingRequiresExternalPower: policy.requirePowerForAllAutomaticWork || largeTransferRequiresPower,
            estimatedPendingTransferBytes: pendingBytes
        )
    }

    private static func pendingTransferBytes(in snapshot: CoreSnapshot?) -> Int64 {
        guard let snapshot else { return 0 }
        var result: Int64 = 0
        for folder in snapshot.folders {
            for value in [folder.pendingUploadBytes, folder.pendingDownloadBytes] {
                let nonnegative = max(0, value)
                let (sum, overflow) = result.addingReportingOverflow(nonnegative)
                result = overflow ? .max : sum
            }
        }
        return result
    }
}

public enum BackgroundSnapshotRefreshFailureCode: String, Codable, Hashable, Sendable {
    case snapshotUnreadable = "backgroundRefreshSnapshotUnreadable"
    case historyWriteFailed = "backgroundRefreshHistoryWriteFailed"
}

public enum BackgroundSnapshotRefreshOutcome: Hashable, Sendable {
    case validated(snapshotGeneration: UInt64)
    case noSnapshot
    case failed(code: BackgroundSnapshotRefreshFailureCode)

    public var completedSuccessfully: Bool {
        switch self {
        case .validated, .noSnapshot: true
        case .failed: false
        }
    }
}

/// A BGAppRefresh run is deliberately local and bounded: it validates the last
/// durable snapshot and records the result. It never starts the core or consumes
/// queued synchronization commands.
public struct BackgroundSnapshotRefreshService: Sendable {
    public init() {}

    public func run(paths: SharedContainerPaths, now: Date = .now) -> BackgroundSnapshotRefreshOutcome {
        let snapshot: CoreSnapshot?
        do {
            snapshot = try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
        } catch {
            let code = BackgroundSnapshotRefreshFailureCode.snapshotUnreadable
            guard
                appendHistory(
                    paths: paths,
                    startedAt: now,
                    endReason: .failed,
                    failureCode: code.rawValue
                )
            else {
                return .failed(code: .historyWriteFailed)
            }
            return .failed(code: code)
        }

        let outcome: BackgroundSnapshotRefreshOutcome
        let endReason: SyncRunEndReason
        if let snapshot {
            outcome = .validated(snapshotGeneration: snapshot.generation)
            endReason = .completed
        } else {
            outcome = .noSnapshot
            endReason = .noWork
        }
        guard appendHistory(paths: paths, startedAt: now, endReason: endReason, failureCode: nil) else {
            return .failed(code: .historyWriteFailed)
        }
        return outcome
    }

    private func appendHistory(
        paths: SharedContainerPaths,
        startedAt: Date,
        endReason: SyncRunEndReason,
        failureCode: String?
    ) -> Bool {
        do {
            try SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: .backgroundRefresh,
                    startedAt: startedAt,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: 0,
                    networkSentBytes: 0,
                    endReason: endReason,
                    failureCode: failureCode
                )
            )
            return true
        } catch {
            return false
        }
    }
}

/// Thread-safe one-shot delivery for callbacks that can race normal completion
/// against an expiration or cancellation path.
public final class OneShotCompletionGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Value) -> Void)?

    public init(_ completion: @escaping @Sendable (Value) -> Void) {
        self.completion = completion
    }

    @discardableResult
    public func complete(_ value: Value) -> Bool {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        guard let completion else { return false }
        completion(value)
        return true
    }
}
