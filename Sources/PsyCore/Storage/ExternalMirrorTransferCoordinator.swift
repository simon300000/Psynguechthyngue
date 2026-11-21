import Foundation

public enum ExternalMirrorTransferAccountingError: Error, Hashable, Sendable {
    case invalidPreparedPlan
    case arithmeticOverflow
    case sessionUnavailable
    case sessionSettling
    case sessionAlreadySettled
    case transferNotPlanned(UUID)
    case transferMismatch(UUID)
    case transferNotAuthorized(UUID)
}

/// Creates a live-owner fenced reserve/begin session for one durable controlled
/// mirror journal. Runtime and broker policy capture remain Phase B concerns;
/// this type consumes their already-decided byte limits atomically.
public struct ExternalMirrorTransferCoordinator: Sendable {
    public let store: TransferAccountingStore

    public init(store: TransferAccountingStore) {
        self.store = store
    }

    public func begin(
        preparedPlan: ControlledMirrorPreparedPlan,
        folderID: FolderID,
        folderIncarnationDigest: String,
        taskID: UUID,
        expiresAt: Date,
        at date: Date,
        configuredRunLimitBytes: Int64? = nil,
        globalDailyLimitBytes: Int64? = nil,
        folderDailyLimitBytes: Int64? = nil,
        reservationID: UUID = UUID(),
        ownerID: UUID = UUID(),
        sessionID: UUID = UUID()
    ) throws -> ExternalMirrorTransferSession {
        let pending = preparedPlan.logicalTransfers.filter { !$0.isCompleted }
        guard
            Set(preparedPlan.logicalTransfers.map(\.id)).count
                == preparedPlan.logicalTransfers.count,
            preparedPlan.maximumLogicalProviderBytes >= 0,
            preparedPlan.remainingLogicalProviderBytes >= 0,
            configuredRunLimitBytes.map({ $0 >= 0 }) != false
        else {
            throw ExternalMirrorTransferAccountingError.invalidPreparedPlan
        }
        let maximum = try Self.sum(preparedPlan.logicalTransfers.map(\.byteCount))
        let remaining = try Self.sum(pending.map(\.byteCount))
        guard preparedPlan.logicalTransfers.allSatisfy({ $0.byteCount >= 0 }),
            maximum == preparedPlan.maximumLogicalProviderBytes,
            remaining == preparedPlan.remainingLogicalProviderBytes
        else {
            throw ExternalMirrorTransferAccountingError.invalidPreparedPlan
        }

        // A mirror run intentionally has multiple finite subgrants
        // (observation, apply, and possibly retry). The durable run ceiling is
        // the configured policy limit, not the size of the first subgrant.
        let runLimitBytes = configuredRunLimitBytes
        let binding = TransferAccountingGrantBinding(
            workKind: .externalMirror,
            folderID: folderID,
            folderIncarnationDigest: folderIncarnationDigest,
            taskID: taskID,
            runID: preparedPlan.runID,
            sessionID: sessionID,
            planDigest: preparedPlan.planDigest
        )
        let lease = try TransferAccountingOwnerLease.acquire(
            directoryURL: store.ownerLeaseDirectoryURL,
            ownerID: ownerID
        )
        do {
            let preparedReservation = try store.reserve(
                id: reservationID,
                ownerID: ownerID,
                binding: binding,
                grantBytes: preparedPlan.remainingLogicalProviderBytes,
                runLimitBytes: runLimitBytes,
                globalDailyLimitBytes: globalDailyLimitBytes,
                folderDailyLimitBytes: folderDailyLimitBytes,
                expiresAt: expiresAt,
                at: date
            )
            do {
                let runningReservation = try store.begin(
                    reservationID: preparedReservation.id,
                    ownerID: ownerID,
                    binding: binding,
                    at: date
                )
                return ExternalMirrorTransferSession(
                    store: store,
                    lease: lease,
                    reservation: runningReservation,
                    expectedTransfers: pending
                )
            } catch {
                // No logical mirror I/O can have occurred before `begin`
                // returns. Exact zero is therefore safe; if even this write
                // fails, releasing the lease leaves full-grant stale recovery.
                _ = try? store.settle(
                    reservationID: preparedReservation.id,
                    ownerID: ownerID,
                    binding: binding,
                    outcome: .exact(bytes: 0),
                    at: date
                )
                throw error
            }
        } catch {
            lease.release()
            throw error
        }
    }

    private static func sum(_ values: [Int64]) throws -> Int64 {
        var total: Int64 = 0
        for value in values {
            guard value >= 0 else {
                throw ExternalMirrorTransferAccountingError.invalidPreparedPlan
            }
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else {
                throw ExternalMirrorTransferAccountingError.arithmeticOverflow
            }
            total = next
        }
        return total
    }
}

/// Thread-safe synchronous callbacks used from inside the controlled mirror's
/// coordinated file operation. No session mutex is held while touching the
/// durable ledger, preserving the lock order lease -> ledger -> nonblocking
/// lease probe used by recovery.
public final class ExternalMirrorTransferSession: @unchecked Sendable {
    public let reservation: TransferAccountingReservation
    public let binding: TransferAccountingGrantBinding

    private let store: TransferAccountingStore
    private let lease: TransferAccountingOwnerLease
    private let stateLock = NSLock()
    private let expectedTransfers: [UUID: ControlledMirrorLogicalTransfer]
    private var authorizedTransferIDs: Set<UUID> = []
    private var completedTransferIDs: Set<UUID> = []
    private var hasUncertainTransfer = false
    private var isSettling = false
    private var settledReceipt: TransferAccountingHistoryProjection?
    private var settledFinalizedRun: Bool?
    private var settledAsTerminalFailure: Bool?

    fileprivate init(
        store: TransferAccountingStore,
        lease: TransferAccountingOwnerLease,
        reservation: TransferAccountingReservation,
        expectedTransfers: [ControlledMirrorLogicalTransfer]
    ) {
        self.store = store
        self.lease = lease
        self.reservation = reservation
        binding = reservation.binding
        self.expectedTransfers = Dictionary(
            uniqueKeysWithValues: expectedTransfers.map { ($0.id, $0) }
        )
    }

    public var meter: ControlledMirrorTransferMeter {
        ControlledMirrorTransferMeter(
            authorize: { [weak self] transfer in
                guard let self else {
                    throw ExternalMirrorTransferAccountingError.sessionUnavailable
                }
                try self.authorize(transfer)
            },
            complete: { [weak self] transfer in
                guard let self else {
                    throw ExternalMirrorTransferAccountingError.sessionUnavailable
                }
                try self.complete(transfer)
            },
            markUncertain: { [weak self] transfer in
                self?.markUncertain(transfer)
            }
        )
    }

    /// A successful mirror apply settles exact completed logical bytes unless
    /// any authorized copy became uncertain, in which case it charges the full
    /// durable grant. The run is closed only after settlement is durable.
    public func settleSuccessful(at date: Date) throws -> TransferAccountingHistoryProjection {
        try settle(finalizeRun: true, terminalFailure: false, at: date)
    }

    /// Settles one successful observation subgrant while deliberately keeping
    /// the shared run open for the journal-derived apply subgrant.
    public func settleStageSuccessful(at date: Date) throws -> TransferAccountingHistoryProjection {
        try settle(finalizeRun: false, terminalFailure: false, at: date)
    }

    /// A deterministic pre-I/O or post-completion failure can still settle
    /// exact known bytes. Any authorized-but-not-completed transfer forces the
    /// conservative full grant.
    public func settleFailed(at date: Date) throws -> TransferAccountingHistoryProjection {
        try settle(finalizeRun: false, terminalFailure: false, at: date)
    }

    /// Atomically settles a terminal non-resumable failure and closes its run.
    public func settleTerminalFailure(at date: Date) throws -> TransferAccountingHistoryProjection {
        try settle(finalizeRun: true, terminalFailure: true, at: date)
    }

    /// Used only when a successful observation was already settled but its
    /// journal could not be persisted. No active grant remains at this point.
    public func finalizeSettledRun(at date: Date) throws {
        stateLock.lock()
        guard settledReceipt != nil else {
            stateLock.unlock()
            throw ExternalMirrorTransferAccountingError.sessionUnavailable
        }
        let binding = binding
        stateLock.unlock()
        try store.markRunFinished(binding: binding, at: date)
    }

    deinit {
        // Deliberately do not guess an exact count here. Once the lease drops,
        // stale recovery owns the durable conservative full-grant settlement.
        lease.release()
    }

    private func authorize(_ transfer: ControlledMirrorLogicalTransfer) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        try requireActive()
        guard let expected = expectedTransfers[transfer.id] else {
            throw ExternalMirrorTransferAccountingError.transferNotPlanned(transfer.id)
        }
        guard expected == transfer else {
            throw ExternalMirrorTransferAccountingError.transferMismatch(transfer.id)
        }
        authorizedTransferIDs.insert(transfer.id)
    }

    private func complete(_ transfer: ControlledMirrorLogicalTransfer) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        try requireActive()
        guard let expected = expectedTransfers[transfer.id] else {
            throw ExternalMirrorTransferAccountingError.transferNotPlanned(transfer.id)
        }
        guard expected == transfer else {
            throw ExternalMirrorTransferAccountingError.transferMismatch(transfer.id)
        }
        guard authorizedTransferIDs.contains(transfer.id) else {
            throw ExternalMirrorTransferAccountingError.transferNotAuthorized(transfer.id)
        }
        completedTransferIDs.insert(transfer.id)
    }

    private func markUncertain(_ transfer: ControlledMirrorLogicalTransfer) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard settledReceipt == nil,
            expectedTransfers[transfer.id] == transfer,
            authorizedTransferIDs.contains(transfer.id)
        else {
            return
        }
        hasUncertainTransfer = true
    }

    private func settle(
        finalizeRun: Bool,
        terminalFailure: Bool,
        at date: Date
    ) throws -> TransferAccountingHistoryProjection {
        stateLock.lock()
        if let receipt = settledReceipt {
            let priorFinalized = settledFinalizedRun
            let priorTerminal = settledAsTerminalFailure
            stateLock.unlock()
            guard priorFinalized == finalizeRun, priorTerminal == terminalFailure else {
                throw ExternalMirrorTransferAccountingError.sessionAlreadySettled
            }
            return receipt
        }
        guard !isSettling else {
            stateLock.unlock()
            throw ExternalMirrorTransferAccountingError.sessionSettling
        }
        isSettling = true
        let incompleteAuthorized = !authorizedTransferIDs.isSubset(
            of: completedTransferIDs
        )
        let mustChargeConservatively = hasUncertainTransfer || incompleteAuthorized
        let completed = completedTransferIDs
        stateLock.unlock()

        let outcome: TransferAccountingSettlementOutcome
        if mustChargeConservatively {
            outcome = .conservative
        } else {
            do {
                var exactBytes: Int64 = 0
                for id in completed {
                    guard let transfer = expectedTransfers[id] else {
                        throw ExternalMirrorTransferAccountingError.transferNotPlanned(id)
                    }
                    let (next, overflow) = exactBytes.addingReportingOverflow(
                        transfer.byteCount
                    )
                    guard !overflow else {
                        throw ExternalMirrorTransferAccountingError.arithmeticOverflow
                    }
                    exactBytes = next
                }
                outcome = .exact(bytes: exactBytes)
            } catch {
                stateLock.lock()
                isSettling = false
                stateLock.unlock()
                throw error
            }
        }

        let receipt: TransferAccountingHistoryProjection
        do {
            if terminalFailure {
                receipt = try store.settleTerminalFailureAndFinalizeRun(
                    reservationID: reservation.id,
                    ownerID: reservation.ownerID,
                    binding: binding,
                    outcome: outcome,
                    at: date
                )
            } else if finalizeRun {
                receipt = try store.settleAndFinalizeRun(
                    reservationID: reservation.id,
                    ownerID: reservation.ownerID,
                    binding: binding,
                    outcome: outcome,
                    at: date
                )
            } else {
                receipt = try store.settle(
                    reservationID: reservation.id,
                    ownerID: reservation.ownerID,
                    binding: binding,
                    outcome: outcome,
                    at: date
                )
            }
        } catch {
            stateLock.lock()
            isSettling = false
            stateLock.unlock()
            throw error
        }

        stateLock.lock()
        settledReceipt = receipt
        settledFinalizedRun = finalizeRun
        settledAsTerminalFailure = terminalFailure
        isSettling = false
        stateLock.unlock()
        lease.release()
        return receipt
    }

    private func requireActive() throws {
        if settledReceipt != nil {
            throw ExternalMirrorTransferAccountingError.sessionAlreadySettled
        }
        if isSettling {
            throw ExternalMirrorTransferAccountingError.sessionSettling
        }
    }
}
