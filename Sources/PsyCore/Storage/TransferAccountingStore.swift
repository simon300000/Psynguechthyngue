import Foundation

public enum TransferAccountingError: Error, Hashable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidLedger
    case invalidBudgetTimeZoneIdentifier(String)
    case budgetTimeZoneMismatch(expected: String, actual: String)
    case dailyLimitExceeded
    case folderDailyLimitExceeded
    case runLimitExceeded
    case runBindingMismatch
    case runAlreadyFinished
    case arithmeticOverflow
    case duplicateIdentifier
    case reservationIdentifierReused
    case reservationNotFound
    case reservationOwnerMismatch
    case reservationBindingMismatch
    case reservationExpired
    case invalidStateTransition
    case invalidByteCount
    case invalidBinding(String)
    case exactBytesExceedGrant
    case settlementConflict
}

public enum TransferAccountingWorkKind: String, Codable, Hashable, Sendable {
    case coreNetwork
    case externalMirror
}

public struct TransferAccountingGrantBinding: Codable, Hashable, Sendable {
    public var workKind: TransferAccountingWorkKind
    public var folderID: FolderID
    public var folderIncarnationDigest: String
    public var taskID: UUID
    public var runID: UUID
    public var sessionID: UUID
    public var planDigest: String

    public init(
        workKind: TransferAccountingWorkKind,
        folderID: FolderID,
        folderIncarnationDigest: String,
        taskID: UUID,
        runID: UUID,
        sessionID: UUID,
        planDigest: String
    ) {
        self.workKind = workKind
        self.folderID = folderID
        self.folderIncarnationDigest = folderIncarnationDigest
        self.taskID = taskID
        self.runID = runID
        self.sessionID = sessionID
        self.planDigest = planDigest
    }

    /// Compatibility initializer for the native core. A native network
    /// session is also its accounting run until the runtime adopts explicit
    /// cross-session run identities.
    public init(
        folderID: FolderID,
        folderIncarnationDigest: String,
        taskID: UUID,
        sessionID: UUID,
        planDigest: String
    ) {
        self.init(
            workKind: .coreNetwork,
            folderID: folderID,
            folderIncarnationDigest: folderIncarnationDigest,
            taskID: taskID,
            runID: sessionID,
            sessionID: sessionID,
            planDigest: planDigest
        )
    }
}

public enum TransferAccountingReservationState: String, Codable, Hashable, Sendable {
    case prepared
    case running
}

public struct TransferAccountingFolderDayUsage: Codable, Hashable, Sendable {
    public var folderID: FolderID
    public var folderIncarnationDigest: String
    public var committedBytes: Int64

    public init(
        folderID: FolderID,
        folderIncarnationDigest: String,
        committedBytes: Int64
    ) {
        self.folderID = folderID
        self.folderIncarnationDigest = folderIncarnationDigest
        self.committedBytes = committedBytes
    }
}

public struct TransferAccountingDayBucket: Codable, Hashable, Sendable {
    public var dayKey: String
    /// Global committed usage. Validation proves it is exactly the sum of the
    /// per-folder incarnation entries below.
    public var committedBytes: Int64
    public var folderUsage: [TransferAccountingFolderDayUsage]
    public var updatedAt: Date

    public init(
        dayKey: String,
        committedBytes: Int64,
        folderUsage: [TransferAccountingFolderDayUsage],
        updatedAt: Date
    ) {
        self.dayKey = dayKey
        self.committedBytes = committedBytes
        self.folderUsage = folderUsage
        self.updatedAt = updatedAt
    }
}

public struct TransferAccountingReservation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var ownerID: UUID
    public var workKind: TransferAccountingWorkKind
    public var folderID: FolderID
    public var folderIncarnationDigest: String
    public var taskID: UUID
    public var runID: UUID
    public var sessionID: UUID
    public var planDigest: String
    public var dayKey: String
    public var grantBytes: Int64
    public var runLimitBytes: Int64?
    public var state: TransferAccountingReservationState
    public var createdAt: Date
    public var expiresAt: Date
    public var grantSequence: UInt64

    public var binding: TransferAccountingGrantBinding {
        TransferAccountingGrantBinding(
            workKind: workKind,
            folderID: folderID,
            folderIncarnationDigest: folderIncarnationDigest,
            taskID: taskID,
            runID: runID,
            sessionID: sessionID,
            planDigest: planDigest
        )
    }
}

public enum TransferAccountingSettlementKind: String, Codable, Hashable, Sendable {
    case exact
    case conservative
    case staleOwnerFullGrant
    case terminalFailureExact
    case terminalFailureConservative
}

public enum TransferAccountingSettlementOutcome: Hashable, Sendable {
    case exact(bytes: Int64)
    case conservative
}

/// This record is both the durable idempotency receipt and the payload waiting
/// to be projected into human-facing run history. Acknowledging history removes
/// only the pending projection copy; the receipt remains for the retention
/// window and prevents the same reservation UUID from being charged twice.
public struct TransferAccountingHistoryProjection: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var ownerID: UUID
    public var workKind: TransferAccountingWorkKind
    public var folderID: FolderID
    public var folderIncarnationDigest: String
    public var taskID: UUID
    public var runID: UUID
    public var sessionID: UUID
    public var planDigest: String
    public var dayKey: String
    public var grantedBytes: Int64
    public var chargedBytes: Int64
    public var runLimitBytes: Int64?
    public var kind: TransferAccountingSettlementKind
    public var settledAt: Date
    public var grantSequence: UInt64

    public var binding: TransferAccountingGrantBinding {
        TransferAccountingGrantBinding(
            workKind: workKind,
            folderID: folderID,
            folderIncarnationDigest: folderIncarnationDigest,
            taskID: taskID,
            runID: runID,
            sessionID: sessionID,
            planDigest: planDigest
        )
    }
}

public struct TransferAccountingUsage: Codable, Hashable, Sendable {
    public var dayKey: String
    public var committedBytes: Int64
    public var activeReservedBytes: Int64
    public var effectiveBytes: Int64
    public var folderCommittedBytes: Int64
    public var folderActiveReservedBytes: Int64
    public var folderEffectiveBytes: Int64
}

public struct TransferAccountingRunUsage: Codable, Hashable, Sendable {
    public var workKind: TransferAccountingWorkKind
    public var folderID: FolderID
    public var folderIncarnationDigest: String
    public var taskID: UUID
    public var runID: UUID
    public var planDigest: String
    public var committedBytes: Int64
    /// `nil` is an explicitly persisted unlimited run. Keeping the run record
    /// still binds its plan digest and committed bytes across later sessions.
    public var limitBytes: Int64?
    public var updatedAt: Date
    public var finishedAt: Date?

    public var binding: TransferAccountingGrantBinding {
        TransferAccountingGrantBinding(
            workKind: workKind,
            folderID: folderID,
            folderIncarnationDigest: folderIncarnationDigest,
            taskID: taskID,
            runID: runID,
            sessionID: runID,
            planDigest: planDigest
        )
    }
}

public struct TransferAccountingRunUsageSnapshot: Codable, Hashable, Sendable {
    public var committedBytes: Int64
    public var activeReservedBytes: Int64
    public var effectiveBytes: Int64
    public var limitBytes: Int64?
    public var isFinished: Bool
}

public struct TransferAccountingLedger: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var budgetTimeZoneIdentifier: String
    public var nextGrantSequence: UInt64
    public var dayBuckets: [TransferAccountingDayBucket]
    public var activeReservations: [TransferAccountingReservation]
    public var runUsages: [TransferAccountingRunUsage]
    public var settledReceipts: [TransferAccountingHistoryProjection]
    public var pendingHistoryProjections: [TransferAccountingHistoryProjection]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        budgetTimeZoneIdentifier: String,
        nextGrantSequence: UInt64 = 1,
        dayBuckets: [TransferAccountingDayBucket] = [],
        activeReservations: [TransferAccountingReservation] = [],
        runUsages: [TransferAccountingRunUsage] = [],
        settledReceipts: [TransferAccountingHistoryProjection] = [],
        pendingHistoryProjections: [TransferAccountingHistoryProjection] = []
    ) {
        self.schemaVersion = schemaVersion
        self.budgetTimeZoneIdentifier = budgetTimeZoneIdentifier
        self.nextGrantSequence = nextGrantSequence
        self.dayBuckets = dayBuckets
        self.activeReservations = activeReservations
        self.runUsages = runUsages
        self.settledReceipts = settledReceipts
        self.pendingHistoryProjections = pendingHistoryProjections
    }
}

/// Atomic, fail-closed accounting for the native protocol limiter. Every grant
/// consumes both the global and exact folder-incarnation budget while active.
/// Crashed/expired owners are charged their full grant.
public struct TransferAccountingStore: Sendable {
    public static let maximumLedgerBytes: Int64 = 1_048_576
    public static let maximumEntriesPerSection = 4_096
    public static let settledReceiptRetention: TimeInterval = 8 * 24 * 60 * 60

    private let url: URL
    private let lockURL: URL
    private let budgetTimeZoneIdentifier: String

    public var ownerLeaseDirectoryURL: URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("TransferAccountingOwners", isDirectory: true)
    }

    public init(url: URL, budgetTimeZoneIdentifier: String) {
        self.url = url
        lockURL = url.appendingPathExtension("lock")
        self.budgetTimeZoneIdentifier = budgetTimeZoneIdentifier
    }

    public func reserve(
        id: UUID = UUID(),
        ownerID: UUID,
        binding: TransferAccountingGrantBinding,
        grantBytes: Int64,
        runLimitBytes: Int64? = nil,
        globalDailyLimitBytes: Int64?,
        folderDailyLimitBytes: Int64?,
        expiresAt: Date,
        at date: Date
    ) throws -> TransferAccountingReservation {
        try Self.validate(binding)
        guard grantBytes >= 0,
            runLimitBytes.map({ $0 >= 0 }) != false,
            globalDailyLimitBytes.map({ $0 >= 0 }) != false,
            folderDailyLimitBytes.map({ $0 >= 0 }) != false,
            date.timeIntervalSince1970.isFinite,
            expiresAt.timeIntervalSince1970.isFinite,
            expiresAt > date
        else {
            throw TransferAccountingError.invalidByteCount
        }

        return try FileLock.withExclusiveLock(at: lockURL) {
            var ledger = try readUnlocked()
            let dayKey = try self.dayKey(for: date)
            if let existing = ledger.activeReservations.first(where: { $0.id == id }) {
                guard existing.ownerID == ownerID,
                    existing.binding == binding,
                    existing.dayKey == dayKey,
                    existing.grantBytes == grantBytes,
                    existing.expiresAt == expiresAt
                else {
                    throw TransferAccountingError.reservationIdentifierReused
                }
                // Policy limits are not reservation identity. The first
                // durable grant is authoritative, including any tighter run
                // limit inherited from an earlier session in this run.
                return existing
            }
            guard !ledger.settledReceipts.contains(where: { $0.id == id }) else {
                throw TransferAccountingError.reservationIdentifierReused
            }

            Self.pruneAcknowledgedReceipts(in: &ledger, relativeTo: date)
            Self.pruneFinishedRunUsages(in: &ledger, relativeTo: date)
            let usage = try Self.usage(in: ledger, dayKey: dayKey, binding: binding)
            let runUsage = try Self.runUsage(in: ledger, binding: binding)
            guard !runUsage.isFinished else {
                throw TransferAccountingError.runAlreadyFinished
            }
            let (globalProjected, globalOverflow) = usage.effectiveBytes.addingReportingOverflow(
                grantBytes
            )
            let (folderProjected, folderOverflow) = usage.folderEffectiveBytes.addingReportingOverflow(
                grantBytes
            )
            guard !globalOverflow, !folderOverflow else {
                throw TransferAccountingError.arithmeticOverflow
            }
            if let globalDailyLimitBytes, globalProjected > globalDailyLimitBytes {
                throw TransferAccountingError.dailyLimitExceeded
            }
            if let folderDailyLimitBytes, folderProjected > folderDailyLimitBytes {
                throw TransferAccountingError.folderDailyLimitExceeded
            }
            let effectiveRunLimit = Self.minimumLimit(runUsage.limitBytes, runLimitBytes)
            let (runProjected, runOverflow) = runUsage.effectiveBytes.addingReportingOverflow(
                grantBytes
            )
            guard !runOverflow else { throw TransferAccountingError.arithmeticOverflow }
            if let effectiveRunLimit, runProjected > effectiveRunLimit {
                throw TransferAccountingError.runLimitExceeded
            }
            guard ledger.nextGrantSequence > 0,
                ledger.nextGrantSequence < UInt64.max
            else {
                throw TransferAccountingError.arithmeticOverflow
            }
            let reservation = TransferAccountingReservation(
                id: id,
                ownerID: ownerID,
                workKind: binding.workKind,
                folderID: binding.folderID,
                folderIncarnationDigest: binding.folderIncarnationDigest,
                taskID: binding.taskID,
                runID: binding.runID,
                sessionID: binding.sessionID,
                planDigest: binding.planDigest,
                dayKey: dayKey,
                grantBytes: grantBytes,
                runLimitBytes: effectiveRunLimit,
                state: .prepared,
                createdAt: date,
                expiresAt: expiresAt,
                grantSequence: ledger.nextGrantSequence
            )
            ledger.nextGrantSequence += 1
            ledger.activeReservations.append(reservation)
            try writeUnlocked(ledger)
            return reservation
        }
    }

    public func begin(
        reservationID: UUID,
        ownerID: UUID,
        binding: TransferAccountingGrantBinding,
        at date: Date
    ) throws -> TransferAccountingReservation {
        try Self.validate(binding)
        return try FileLock.withExclusiveLock(at: lockURL) {
            var ledger = try readUnlocked()
            guard let index = ledger.activeReservations.firstIndex(where: { $0.id == reservationID }) else {
                throw TransferAccountingError.reservationNotFound
            }
            guard ledger.activeReservations[index].ownerID == ownerID else {
                throw TransferAccountingError.reservationOwnerMismatch
            }
            guard ledger.activeReservations[index].binding == binding else {
                throw TransferAccountingError.reservationBindingMismatch
            }
            guard date < ledger.activeReservations[index].expiresAt else {
                throw TransferAccountingError.reservationExpired
            }
            switch ledger.activeReservations[index].state {
            case .prepared:
                ledger.activeReservations[index].state = .running
                try writeUnlocked(ledger)
            case .running:
                break
            }
            return ledger.activeReservations[index]
        }
    }

    public func usage(at date: Date) throws -> TransferAccountingUsage {
        try FileLock.withExclusiveLock(at: lockURL) {
            try Self.usage(
                in: readUnlocked(),
                dayKey: dayKey(for: date),
                binding: nil
            )
        }
    }

    public func usage(
        for binding: TransferAccountingGrantBinding,
        at date: Date
    ) throws -> TransferAccountingUsage {
        try Self.validate(binding)
        return try FileLock.withExclusiveLock(at: lockURL) {
            try Self.usage(
                in: readUnlocked(),
                dayKey: dayKey(for: date),
                binding: binding
            )
        }
    }

    public func runUsage(
        for binding: TransferAccountingGrantBinding
    ) throws -> TransferAccountingRunUsageSnapshot {
        try Self.validate(binding)
        return try FileLock.withExclusiveLock(at: lockURL) {
            try Self.runUsage(in: readUnlocked(), binding: binding)
        }
    }

    public func markRunFinished(
        binding: TransferAccountingGrantBinding,
        at date: Date
    ) throws {
        try Self.validate(binding)
        try FileLock.withExclusiveLock(at: lockURL) {
            var ledger = try readUnlocked()
            if try Self.finalizeRun(binding: binding, at: date, in: &ledger) {
                try writeUnlocked(ledger)
            }
        }
    }

    public func settle(
        reservationID: UUID,
        ownerID: UUID,
        binding: TransferAccountingGrantBinding,
        outcome: TransferAccountingSettlementOutcome,
        at date: Date
    ) throws -> TransferAccountingHistoryProjection {
        try settle(
            reservationID: reservationID,
            ownerID: ownerID,
            binding: binding,
            outcome: outcome,
            finalizeRun: false,
            terminalFailure: false,
            at: date
        )
    }

    /// Atomically persists the settlement receipt, removes the active grant,
    /// and closes the exact run in one ledger replacement. Retrying after an
    /// uncertain caller outcome returns the same receipt and completes any
    /// legacy unfinalized receipt without charging twice.
    public func settleAndFinalizeRun(
        reservationID: UUID,
        ownerID: UUID,
        binding: TransferAccountingGrantBinding,
        outcome: TransferAccountingSettlementOutcome,
        at date: Date
    ) throws -> TransferAccountingHistoryProjection {
        try settle(
            reservationID: reservationID,
            ownerID: ownerID,
            binding: binding,
            outcome: outcome,
            finalizeRun: true,
            terminalFailure: false,
            at: date
        )
    }

    /// Terminal non-resumable failures settle and close atomically. Only
    /// zero-charge exact failures use a bounded durable tombstone window;
    /// charged failures remain ordinary auditable receipts and pending
    /// history until explicitly acknowledged and retained for the normal
    /// receipt window.
    public func settleTerminalFailureAndFinalizeRun(
        reservationID: UUID,
        ownerID: UUID,
        binding: TransferAccountingGrantBinding,
        outcome: TransferAccountingSettlementOutcome,
        at date: Date
    ) throws -> TransferAccountingHistoryProjection {
        try settle(
            reservationID: reservationID,
            ownerID: ownerID,
            binding: binding,
            outcome: outcome,
            finalizeRun: true,
            terminalFailure: true,
            at: date
        )
    }

    private func settle(
        reservationID: UUID,
        ownerID: UUID,
        binding: TransferAccountingGrantBinding,
        outcome: TransferAccountingSettlementOutcome,
        finalizeRun: Bool,
        terminalFailure: Bool,
        at date: Date
    ) throws -> TransferAccountingHistoryProjection {
        try Self.validate(binding)
        return try FileLock.withExclusiveLock(at: lockURL) {
            var ledger = try readUnlocked()
            Self.pruneAcknowledgedReceipts(in: &ledger, relativeTo: date)
            if let receipt = ledger.settledReceipts.first(where: { $0.id == reservationID }) {
                guard receipt.ownerID == ownerID,
                    receipt.binding == binding,
                    Self.matches(
                        projection: receipt,
                        outcome: outcome,
                        terminalFailure: terminalFailure
                    )
                else {
                    throw TransferAccountingError.settlementConflict
                }
                if finalizeRun,
                    try Self.finalizeRun(binding: binding, at: date, in: &ledger)
                {
                    try writeUnlocked(ledger)
                }
                return receipt
            }
            if terminalFailure {
                Self.compactZeroChargeTerminalTombstones(in: &ledger, keeping: 63)
            }
            guard let index = ledger.activeReservations.firstIndex(where: { $0.id == reservationID }) else {
                throw TransferAccountingError.reservationNotFound
            }
            let reservation = ledger.activeReservations[index]
            guard reservation.ownerID == ownerID else {
                throw TransferAccountingError.reservationOwnerMismatch
            }
            guard reservation.binding == binding else {
                throw TransferAccountingError.reservationBindingMismatch
            }

            let chargedBytes: Int64
            let kind: TransferAccountingSettlementKind
            switch outcome {
            case .exact(let bytes):
                guard bytes >= 0 else { throw TransferAccountingError.invalidByteCount }
                guard bytes <= reservation.grantBytes else {
                    throw TransferAccountingError.exactBytesExceedGrant
                }
                chargedBytes = bytes
                kind = terminalFailure ? .terminalFailureExact : .exact
            case .conservative:
                chargedBytes = reservation.grantBytes
                kind = terminalFailure ? .terminalFailureConservative : .conservative
            }
            let projection = Self.projection(
                from: reservation,
                chargedBytes: chargedBytes,
                kind: kind,
                settledAt: date
            )
            try Self.commit(projection, to: &ledger)
            ledger.activeReservations.remove(at: index)
            if finalizeRun {
                _ = try Self.finalizeRun(binding: binding, at: date, in: &ledger)
            }
            if terminalFailure {
                if Self.isZeroChargeTerminalTombstone(projection) {
                    ledger.pendingHistoryProjections.removeAll { $0.id == projection.id }
                    Self.compactZeroChargeTerminalTombstones(in: &ledger, keeping: 64)
                    ledger.runUsages.removeAll {
                        Self.sameRun($0, binding)
                            && $0.finishedAt != nil
                            && $0.committedBytes == 0
                    }
                }
            }
            try writeUnlocked(ledger)
            return projection
        }
    }

    public func recoverStaleReservations(
        activeOwnerIDs: Set<UUID>,
        at date: Date
    ) throws -> [TransferAccountingHistoryProjection] {
        try recoverStaleReservations(
            protectedOwnerIDs: activeOwnerIDs,
            at: date
        )
    }

    /// Protects in-process owners by identifier while also probing every other
    /// owner's nonblocking liveness lease. CoreRuntime uses this mixed-owner
    /// API so a live external mirror can never be recovered as stale merely
    /// because its owner UUID is not the core's current UUID.
    public func recoverStaleReservations(
        protectedOwnerIDs: Set<UUID>,
        at date: Date
    ) throws -> [TransferAccountingHistoryProjection] {
        try recoverStaleReservations(
            activeOwnerIDs: protectedOwnerIDs,
            honorOwnerLivenessLeases: true,
            at: date
        )
    }

    /// Recovers owners solely from their process-liveness locks. This is the
    /// preferred API for mixed core and external-mirror reservations.
    public func recoverStaleReservations(
        at date: Date
    ) throws -> [TransferAccountingHistoryProjection] {
        try recoverStaleReservations(
            activeOwnerIDs: [],
            honorOwnerLivenessLeases: true,
            at: date
        )
    }

    private func recoverStaleReservations(
        activeOwnerIDs: Set<UUID>,
        honorOwnerLivenessLeases: Bool,
        at date: Date
    ) throws -> [TransferAccountingHistoryProjection] {
        try FileLock.withExclusiveLock(at: lockURL) {
            var ledger = try readUnlocked()
            Self.pruneAcknowledgedReceipts(in: &ledger, relativeTo: date)
            Self.pruneFinishedRunUsages(in: &ledger, relativeTo: date)
            var liveness: [UUID: Bool] = [:]
            var stale: [TransferAccountingReservation] = []
            for reservation in ledger.activeReservations {
                if activeOwnerIDs.contains(reservation.ownerID) { continue }
                let isLive: Bool
                if honorOwnerLivenessLeases {
                    if let cached = liveness[reservation.ownerID] {
                        isLive = cached
                    } else {
                        isLive = try TransferAccountingOwnerLease.isLive(
                            ownerID: reservation.ownerID,
                            directoryURL: ownerLeaseDirectoryURL
                        )
                        liveness[reservation.ownerID] = isLive
                    }
                } else {
                    isLive = false
                }
                // A positive liveness proof is authoritative even after the
                // reservation's nominal expiry. Expiry is only evidence for
                // recovery after the owner has first been proven absent.
                if isLive { continue }
                stale.append(reservation)
            }
            stale.sort { $0.grantSequence < $1.grantSequence }
            guard !stale.isEmpty else {
                return []
            }
            var recovered: [TransferAccountingHistoryProjection] = []
            for reservation in stale {
                let projection = Self.projection(
                    from: reservation,
                    chargedBytes: reservation.grantBytes,
                    kind: .staleOwnerFullGrant,
                    settledAt: date
                )
                try Self.commit(projection, to: &ledger)
                recovered.append(projection)
            }
            let staleIDs = Set(stale.map(\.id))
            ledger.activeReservations.removeAll { staleIDs.contains($0.id) }
            try writeUnlocked(ledger)
            return recovered
        }
    }

    public func pendingHistoryProjections() throws -> [TransferAccountingHistoryProjection] {
        try FileLock.withExclusiveLock(at: lockURL) {
            try readUnlocked().pendingHistoryProjections.sorted {
                $0.grantSequence < $1.grantSequence
            }
        }
    }

    public func acknowledgeHistoryProjection(_ id: UUID) throws {
        try FileLock.withExclusiveLock(at: lockURL) {
            var ledger = try readUnlocked()
            let previousCount = ledger.pendingHistoryProjections.count
            ledger.pendingHistoryProjections.removeAll { $0.id == id }
            if ledger.pendingHistoryProjections.count != previousCount {
                try writeUnlocked(ledger)
            }
        }
    }

    public func snapshot() throws -> TransferAccountingLedger {
        try FileLock.withExclusiveLock(at: lockURL) { try readUnlocked() }
    }

    func replaceForTesting(_ ledger: TransferAccountingLedger) throws {
        try FileLock.withExclusiveLock(at: lockURL) { try writeUnlocked(ledger) }
    }

    private func readUnlocked() throws -> TransferAccountingLedger {
        try Self.validateTimeZoneIdentifier(budgetTimeZoneIdentifier)
        guard
            let data = try SecureLockFile.readRegularFileIfPresent(
                at: url,
                maximumSize: Self.maximumLedgerBytes
            )
        else {
            return TransferAccountingLedger(
                budgetTimeZoneIdentifier: budgetTimeZoneIdentifier
            )
        }
        guard !data.isEmpty else { throw TransferAccountingError.invalidLedger }
        do {
            let version = try StrictAccountingSchema.validate(StrictJSONDocument.parse(data))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if version == 1 {
                return try validatedCanonicalLedger(
                    Self.migrateV1(
                        decoder.decode(LegacyTransferAccountingLedgerV1.self, from: data)
                    )
                )
            }
            return try validatedCanonicalLedger(
                decoder.decode(TransferAccountingLedger.self, from: data)
            )
        } catch let error as TransferAccountingError {
            throw error
        } catch {
            throw TransferAccountingError.invalidLedger
        }
    }

    private func writeUnlocked(_ ledger: TransferAccountingLedger) throws {
        let canonical = try validatedCanonicalLedger(ledger)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(canonical)
        guard Int64(data.count) <= Self.maximumLedgerBytes else {
            throw TransferAccountingError.invalidLedger
        }
        do {
            _ = try StrictAccountingSchema.validate(StrictJSONDocument.parse(data))
        } catch let error as TransferAccountingError {
            throw error
        } catch {
            throw TransferAccountingError.invalidLedger
        }
        try SecureLockFile.writeAtomically(data, to: url)
    }

    private static func migrateV1(
        _ legacy: LegacyTransferAccountingLedgerV1
    ) -> TransferAccountingLedger {
        let reservations = legacy.activeReservations.map { value in
            TransferAccountingReservation(
                id: value.id,
                ownerID: value.ownerID,
                workKind: .coreNetwork,
                folderID: value.folderID,
                folderIncarnationDigest: value.folderIncarnationDigest,
                taskID: value.taskID,
                runID: value.sessionID,
                sessionID: value.sessionID,
                planDigest: value.planDigest,
                dayKey: value.dayKey,
                grantBytes: value.grantBytes,
                runLimitBytes: nil,
                state: value.state,
                createdAt: value.createdAt,
                expiresAt: value.expiresAt,
                grantSequence: value.grantSequence
            )
        }
        let migrateProjection:
            (LegacyTransferAccountingProjectionV1) ->
                TransferAccountingHistoryProjection = { value in
                    TransferAccountingHistoryProjection(
                        id: value.id,
                        ownerID: value.ownerID,
                        workKind: .coreNetwork,
                        folderID: value.folderID,
                        folderIncarnationDigest: value.folderIncarnationDigest,
                        taskID: value.taskID,
                        runID: value.sessionID,
                        sessionID: value.sessionID,
                        planDigest: value.planDigest,
                        dayKey: value.dayKey,
                        grantedBytes: value.grantedBytes,
                        chargedBytes: value.chargedBytes,
                        runLimitBytes: nil,
                        kind: value.kind,
                        settledAt: value.settledAt,
                        grantSequence: value.grantSequence
                    )
                }
        return TransferAccountingLedger(
            budgetTimeZoneIdentifier: legacy.budgetTimeZoneIdentifier,
            nextGrantSequence: legacy.nextGrantSequence,
            dayBuckets: legacy.dayBuckets,
            activeReservations: reservations,
            runUsages: [],
            settledReceipts: legacy.settledReceipts.map(migrateProjection),
            pendingHistoryProjections: legacy.pendingHistoryProjections.map(migrateProjection)
        )
    }

    private func validatedCanonicalLedger(
        _ value: TransferAccountingLedger
    ) throws -> TransferAccountingLedger {
        var candidate = value
        guard candidate.schemaVersion == TransferAccountingLedger.currentSchemaVersion else {
            throw TransferAccountingError.unsupportedSchemaVersion(candidate.schemaVersion)
        }
        try Self.validateTimeZoneIdentifier(candidate.budgetTimeZoneIdentifier)
        guard candidate.budgetTimeZoneIdentifier == budgetTimeZoneIdentifier else {
            throw TransferAccountingError.budgetTimeZoneMismatch(
                expected: budgetTimeZoneIdentifier,
                actual: candidate.budgetTimeZoneIdentifier
            )
        }
        guard candidate.nextGrantSequence > 0,
            candidate.dayBuckets.count <= Self.maximumEntriesPerSection,
            candidate.activeReservations.count <= Self.maximumEntriesPerSection,
            candidate.runUsages.count <= Self.maximumEntriesPerSection,
            candidate.settledReceipts.count <= Self.maximumEntriesPerSection,
            candidate.pendingHistoryProjections.count <= Self.maximumEntriesPerSection
        else {
            throw TransferAccountingError.invalidLedger
        }

        var dayKeys = Set<String>()
        for bucket in candidate.dayBuckets {
            guard dayKeys.insert(bucket.dayKey).inserted,
                Self.isValidDayKey(bucket.dayKey),
                bucket.committedBytes >= 0,
                bucket.updatedAt.timeIntervalSince1970.isFinite,
                bucket.folderUsage.count <= Self.maximumEntriesPerSection
            else {
                throw TransferAccountingError.invalidLedger
            }
            var folderKeys = Set<FolderIncarnationKey>()
            var folderTotal: Int64 = 0
            for usage in bucket.folderUsage {
                let key = FolderIncarnationKey(
                    folderID: usage.folderID,
                    digest: usage.folderIncarnationDigest
                )
                guard folderKeys.insert(key).inserted,
                    Self.isCanonicalDigest(usage.folderIncarnationDigest),
                    usage.committedBytes >= 0
                else {
                    throw TransferAccountingError.invalidLedger
                }
                let (sum, overflow) = folderTotal.addingReportingOverflow(usage.committedBytes)
                guard !overflow else { throw TransferAccountingError.arithmeticOverflow }
                folderTotal = sum
            }
            guard folderTotal == bucket.committedBytes else {
                throw TransferAccountingError.invalidLedger
            }
        }

        var activeIDs = Set<UUID>()
        var receiptIDs = Set<UUID>()
        var sequences = Set<UInt64>()
        var greatestSequence: UInt64 = 0
        for reservation in candidate.activeReservations {
            try Self.validate(reservation.binding)
            guard activeIDs.insert(reservation.id).inserted,
                sequences.insert(reservation.grantSequence).inserted,
                Self.isValidDayKey(reservation.dayKey),
                reservation.grantBytes >= 0,
                reservation.runLimitBytes.map({ $0 >= 0 && reservation.grantBytes <= $0 })
                    != false,
                reservation.grantSequence > 0,
                reservation.createdAt.timeIntervalSince1970.isFinite,
                reservation.expiresAt.timeIntervalSince1970.isFinite,
                reservation.expiresAt > reservation.createdAt
            else {
                throw TransferAccountingError.invalidLedger
            }
            greatestSequence = max(greatestSequence, reservation.grantSequence)
        }
        for receipt in candidate.settledReceipts {
            try Self.validate(receipt.binding)
            guard receiptIDs.insert(receipt.id).inserted,
                !activeIDs.contains(receipt.id),
                sequences.insert(receipt.grantSequence).inserted,
                Self.isValidDayKey(receipt.dayKey),
                receipt.grantedBytes >= 0,
                receipt.chargedBytes >= 0,
                receipt.chargedBytes <= receipt.grantedBytes,
                receipt.runLimitBytes.map({ $0 >= 0 && receipt.grantedBytes <= $0 })
                    != false,
                receipt.grantSequence > 0,
                receipt.settledAt.timeIntervalSince1970.isFinite
            else {
                throw TransferAccountingError.invalidLedger
            }
            if receipt.kind != .exact,
                receipt.kind != .terminalFailureExact,
                receipt.chargedBytes != receipt.grantedBytes
            {
                throw TransferAccountingError.invalidLedger
            }
            greatestSequence = max(greatestSequence, receipt.grantSequence)
        }
        var runKeys = Set<TransferAccountingRunKey>()
        for usage in candidate.runUsages {
            try Self.validate(usage.binding)
            let key = TransferAccountingRunKey(usage)
            guard runKeys.insert(key).inserted,
                usage.committedBytes >= 0,
                usage.limitBytes.map({ $0 >= 0 && usage.committedBytes <= $0 }) != false,
                usage.updatedAt.timeIntervalSince1970.isFinite,
                usage.finishedAt?.timeIntervalSince1970.isFinite != false
            else {
                throw TransferAccountingError.invalidLedger
            }
        }
        try Self.restoreMissingRunUsages(in: &candidate)
        for usage in candidate.runUsages {
            let binding = usage.binding
            let snapshot = try Self.runUsage(in: candidate, binding: binding)
            guard usage.limitBytes.map({ snapshot.effectiveBytes <= $0 }) != false,
                usage.finishedAt == nil || snapshot.activeReservedBytes == 0
            else {
                throw TransferAccountingError.invalidLedger
            }
        }
        // Also validate runs that have only active, uncapped compatibility
        // reservations. This rejects one run identity being rebound to a
        // different plan before a run-usage record exists.
        for reservation in candidate.activeReservations {
            let snapshot = try Self.runUsage(
                in: candidate,
                binding: reservation.binding
            )
            guard !snapshot.isFinished else {
                throw TransferAccountingError.invalidLedger
            }
        }
        guard greatestSequence < candidate.nextGrantSequence else {
            throw TransferAccountingError.invalidLedger
        }

        var pendingIDs = Set<UUID>()
        for pending in candidate.pendingHistoryProjections {
            guard pendingIDs.insert(pending.id).inserted,
                let receipt = candidate.settledReceipts.first(where: { $0.id == pending.id }),
                receipt == pending
            else {
                throw TransferAccountingError.invalidLedger
            }
        }
        for dayKey in Set(
            candidate.dayBuckets.map(\.dayKey)
                + candidate.activeReservations.map(\.dayKey)
        ) {
            _ = try Self.usage(in: candidate, dayKey: dayKey, binding: nil)
        }

        var canonical = candidate
        canonical.dayBuckets.sort { $0.dayKey < $1.dayKey }
        for index in canonical.dayBuckets.indices {
            canonical.dayBuckets[index].folderUsage.sort(by: Self.folderUsageSort)
        }
        canonical.activeReservations.sort { $0.grantSequence < $1.grantSequence }
        canonical.runUsages.sort(by: Self.runUsageSort)
        canonical.settledReceipts.sort { $0.grantSequence < $1.grantSequence }
        canonical.pendingHistoryProjections.sort { $0.grantSequence < $1.grantSequence }
        return canonical
    }

    private func dayKey(for date: Date) throws -> String {
        try Self.validateTimeZoneIdentifier(budgetTimeZoneIdentifier)
        guard date.timeIntervalSince1970.isFinite,
            let timeZone = TimeZone(identifier: budgetTimeZoneIdentifier)
        else {
            throw TransferAccountingError.invalidLedger
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            throw TransferAccountingError.invalidLedger
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func usage(
        in ledger: TransferAccountingLedger,
        dayKey: String,
        binding: TransferAccountingGrantBinding?
    ) throws -> TransferAccountingUsage {
        let bucket = ledger.dayBuckets.first(where: { $0.dayKey == dayKey })
        let committed = bucket?.committedBytes ?? 0
        var active: Int64 = 0
        var folderActive: Int64 = 0
        for reservation in ledger.activeReservations where reservation.dayKey == dayKey {
            active = try checkedAdd(active, reservation.grantBytes)
            if let binding,
                reservation.folderID == binding.folderID,
                reservation.folderIncarnationDigest == binding.folderIncarnationDigest
            {
                folderActive = try checkedAdd(folderActive, reservation.grantBytes)
            }
        }
        let folderCommitted: Int64
        if let binding {
            folderCommitted =
                bucket?.folderUsage.first {
                    $0.folderID == binding.folderID
                        && $0.folderIncarnationDigest == binding.folderIncarnationDigest
                }?.committedBytes ?? 0
        } else {
            folderCommitted = 0
        }
        return TransferAccountingUsage(
            dayKey: dayKey,
            committedBytes: committed,
            activeReservedBytes: active,
            effectiveBytes: try checkedAdd(committed, active),
            folderCommittedBytes: folderCommitted,
            folderActiveReservedBytes: folderActive,
            folderEffectiveBytes: try checkedAdd(folderCommitted, folderActive)
        )
    }

    private static func runUsage(
        in ledger: TransferAccountingLedger,
        binding: TransferAccountingGrantBinding
    ) throws -> TransferAccountingRunUsageSnapshot {
        let index = try runUsageIndex(in: ledger, binding: binding)
        let terminalTombstones = ledger.settledReceipts.filter {
            isZeroChargeTerminalTombstone($0) && sameRun($0.binding, binding)
        }
        for tombstone in terminalTombstones {
            guard tombstone.planDigest == binding.planDigest else {
                throw TransferAccountingError.runBindingMismatch
            }
        }
        let committed = index.map { ledger.runUsages[$0].committedBytes } ?? 0
        var active: Int64 = 0
        var limit = index.flatMap { ledger.runUsages[$0].limitBytes }
        for reservation in ledger.activeReservations where sameRun(reservation.binding, binding) {
            guard reservation.planDigest == binding.planDigest else {
                throw TransferAccountingError.runBindingMismatch
            }
            active = try checkedAdd(active, reservation.grantBytes)
            limit = minimumLimit(limit, reservation.runLimitBytes)
        }
        return TransferAccountingRunUsageSnapshot(
            committedBytes: committed,
            activeReservedBytes: active,
            effectiveBytes: try checkedAdd(committed, active),
            limitBytes: limit,
            isFinished: index.flatMap { ledger.runUsages[$0].finishedAt } != nil
                || !terminalTombstones.isEmpty
        )
    }

    private static func runUsageIndex(
        in ledger: TransferAccountingLedger,
        binding: TransferAccountingGrantBinding
    ) throws -> Int? {
        let matches = ledger.runUsages.indices.filter {
            sameRun(ledger.runUsages[$0], binding)
        }
        guard matches.count <= 1 else { throw TransferAccountingError.invalidLedger }
        guard let index = matches.first else { return nil }
        guard ledger.runUsages[index].planDigest == binding.planDigest else {
            throw TransferAccountingError.runBindingMismatch
        }
        return index
    }

    private static func sameRun(
        _ lhs: TransferAccountingGrantBinding,
        _ rhs: TransferAccountingGrantBinding
    ) -> Bool {
        lhs.workKind == rhs.workKind
            && lhs.folderID == rhs.folderID
            && lhs.folderIncarnationDigest == rhs.folderIncarnationDigest
            && lhs.taskID == rhs.taskID
            && lhs.runID == rhs.runID
    }

    private static func sameRun(
        _ lhs: TransferAccountingRunUsage,
        _ rhs: TransferAccountingGrantBinding
    ) -> Bool {
        lhs.workKind == rhs.workKind
            && lhs.folderID == rhs.folderID
            && lhs.folderIncarnationDigest == rhs.folderIncarnationDigest
            && lhs.taskID == rhs.taskID
            && lhs.runID == rhs.runID
    }

    private static func commit(
        _ projection: TransferAccountingHistoryProjection,
        to ledger: inout TransferAccountingLedger
    ) throws {
        guard !ledger.settledReceipts.contains(where: { $0.id == projection.id }),
            ledger.settledReceipts.count < maximumEntriesPerSection,
            ledger.pendingHistoryProjections.count < maximumEntriesPerSection
        else {
            throw TransferAccountingError.duplicateIdentifier
        }
        let bucketIndex: Int
        if let existing = ledger.dayBuckets.firstIndex(where: { $0.dayKey == projection.dayKey }) {
            bucketIndex = existing
        } else {
            guard ledger.dayBuckets.count < maximumEntriesPerSection else {
                throw TransferAccountingError.invalidLedger
            }
            ledger.dayBuckets.append(
                TransferAccountingDayBucket(
                    dayKey: projection.dayKey,
                    committedBytes: 0,
                    folderUsage: [],
                    updatedAt: projection.settledAt
                )
            )
            bucketIndex = ledger.dayBuckets.count - 1
        }
        ledger.dayBuckets[bucketIndex].committedBytes = try checkedAdd(
            ledger.dayBuckets[bucketIndex].committedBytes,
            projection.chargedBytes
        )
        ledger.dayBuckets[bucketIndex].updatedAt = projection.settledAt
        if let folderIndex = ledger.dayBuckets[bucketIndex].folderUsage.firstIndex(where: {
            $0.folderID == projection.folderID
                && $0.folderIncarnationDigest == projection.folderIncarnationDigest
        }) {
            ledger.dayBuckets[bucketIndex].folderUsage[folderIndex].committedBytes = try checkedAdd(
                ledger.dayBuckets[bucketIndex].folderUsage[folderIndex].committedBytes,
                projection.chargedBytes
            )
        } else {
            ledger.dayBuckets[bucketIndex].folderUsage.append(
                TransferAccountingFolderDayUsage(
                    folderID: projection.folderID,
                    folderIncarnationDigest: projection.folderIncarnationDigest,
                    committedBytes: projection.chargedBytes
                )
            )
        }
        let runIndex: Int
        if let existing = try runUsageIndex(in: ledger, binding: projection.binding) {
            runIndex = existing
            ledger.runUsages[runIndex].limitBytes = minimumLimit(
                ledger.runUsages[runIndex].limitBytes,
                projection.runLimitBytes
            )
            ledger.runUsages[runIndex].committedBytes = try checkedAdd(
                ledger.runUsages[runIndex].committedBytes,
                projection.chargedBytes
            )
            ledger.runUsages[runIndex].updatedAt = projection.settledAt
        } else {
            guard ledger.runUsages.count < maximumEntriesPerSection else {
                throw TransferAccountingError.invalidLedger
            }
            ledger.runUsages.append(
                TransferAccountingRunUsage(
                    workKind: projection.workKind,
                    folderID: projection.folderID,
                    folderIncarnationDigest: projection.folderIncarnationDigest,
                    taskID: projection.taskID,
                    runID: projection.runID,
                    planDigest: projection.planDigest,
                    committedBytes: projection.chargedBytes,
                    limitBytes: projection.runLimitBytes,
                    updatedAt: projection.settledAt,
                    finishedAt: nil
                )
            )
            runIndex = ledger.runUsages.count - 1
        }
        if let limit = ledger.runUsages[runIndex].limitBytes,
            ledger.runUsages[runIndex].committedBytes > limit
        {
            throw TransferAccountingError.runLimitExceeded
        }
        ledger.settledReceipts.append(projection)
        ledger.pendingHistoryProjections.append(projection)
    }

    private static func finalizeRun(
        binding: TransferAccountingGrantBinding,
        at date: Date,
        in ledger: inout TransferAccountingLedger
    ) throws -> Bool {
        guard
            !ledger.activeReservations.contains(where: {
                sameRun($0.binding, binding)
            })
        else {
            throw TransferAccountingError.invalidStateTransition
        }
        guard let index = try runUsageIndex(in: ledger, binding: binding) else {
            return false
        }
        guard ledger.runUsages[index].finishedAt == nil else { return false }
        ledger.runUsages[index].finishedAt = date
        ledger.runUsages[index].updatedAt = date
        return true
    }

    /// Schema-v2 ledgers written before unlimited runs were projected can
    /// still contain durable receipts without a run-usage record. Restore only
    /// missing keys from those receipts; existing records may legitimately
    /// outlive receipt retention and remain authoritative.
    private static func restoreMissingRunUsages(
        in ledger: inout TransferAccountingLedger
    ) throws {
        let existingKeys = Set(ledger.runUsages.map(TransferAccountingRunKey.init))
        var restoredKeys = Set<TransferAccountingRunKey>()
        for receipt in ledger.settledReceipts.sorted(by: { $0.grantSequence < $1.grantSequence }) {
            if receipt.kind == .terminalFailureExact
                || receipt.kind == .terminalFailureConservative
            {
                continue
            }
            let binding = receipt.binding
            let key = TransferAccountingRunKey(binding)
            if existingKeys.contains(key) { continue }
            if let index = try runUsageIndex(in: ledger, binding: binding) {
                guard restoredKeys.contains(key) else { continue }
                ledger.runUsages[index].limitBytes = minimumLimit(
                    ledger.runUsages[index].limitBytes,
                    receipt.runLimitBytes
                )
                ledger.runUsages[index].committedBytes = try checkedAdd(
                    ledger.runUsages[index].committedBytes,
                    receipt.chargedBytes
                )
                ledger.runUsages[index].updatedAt = max(
                    ledger.runUsages[index].updatedAt,
                    receipt.settledAt
                )
            } else {
                guard ledger.runUsages.count < maximumEntriesPerSection else {
                    throw TransferAccountingError.invalidLedger
                }
                ledger.runUsages.append(
                    TransferAccountingRunUsage(
                        workKind: receipt.workKind,
                        folderID: receipt.folderID,
                        folderIncarnationDigest: receipt.folderIncarnationDigest,
                        taskID: receipt.taskID,
                        runID: receipt.runID,
                        planDigest: receipt.planDigest,
                        committedBytes: receipt.chargedBytes,
                        limitBytes: receipt.runLimitBytes,
                        updatedAt: receipt.settledAt,
                        finishedAt: nil
                    )
                )
                restoredKeys.insert(key)
            }
        }
    }

    private static func projection(
        from reservation: TransferAccountingReservation,
        chargedBytes: Int64,
        kind: TransferAccountingSettlementKind,
        settledAt: Date
    ) -> TransferAccountingHistoryProjection {
        TransferAccountingHistoryProjection(
            id: reservation.id,
            ownerID: reservation.ownerID,
            workKind: reservation.workKind,
            folderID: reservation.folderID,
            folderIncarnationDigest: reservation.folderIncarnationDigest,
            taskID: reservation.taskID,
            runID: reservation.runID,
            sessionID: reservation.sessionID,
            planDigest: reservation.planDigest,
            dayKey: reservation.dayKey,
            grantedBytes: reservation.grantBytes,
            chargedBytes: chargedBytes,
            runLimitBytes: reservation.runLimitBytes,
            kind: kind,
            settledAt: settledAt,
            grantSequence: reservation.grantSequence
        )
    }

    private static func matches(
        projection: TransferAccountingHistoryProjection,
        outcome: TransferAccountingSettlementOutcome,
        terminalFailure: Bool = false
    ) -> Bool {
        switch outcome {
        case .exact(let bytes):
            let expected: TransferAccountingSettlementKind =
                terminalFailure ? .terminalFailureExact : .exact
            return projection.kind == expected && projection.chargedBytes == bytes
        case .conservative:
            let expected: TransferAccountingSettlementKind =
                terminalFailure ? .terminalFailureConservative : .conservative
            return projection.kind == expected
                && projection.chargedBytes == projection.grantedBytes
        }
    }

    private static func isZeroChargeTerminalTombstone(
        _ receipt: TransferAccountingHistoryProjection
    ) -> Bool {
        receipt.kind == .terminalFailureExact && receipt.chargedBytes == 0
    }

    private static func compactZeroChargeTerminalTombstones(
        in ledger: inout TransferAccountingLedger,
        keeping maximumCount: Int
    ) {
        let terminal = ledger.settledReceipts.filter {
            isZeroChargeTerminalTombstone($0)
        }.sorted { $0.grantSequence > $1.grantSequence }
        let retained = Set(terminal.prefix(max(0, maximumCount)).map(\.id))
        let removed = Set(terminal.map(\.id)).subtracting(retained)
        guard !removed.isEmpty else { return }
        ledger.settledReceipts.removeAll { removed.contains($0.id) }
        ledger.pendingHistoryProjections.removeAll { removed.contains($0.id) }
    }

    private static func pruneAcknowledgedReceipts(
        in ledger: inout TransferAccountingLedger,
        relativeTo date: Date
    ) {
        let cutoff = date.addingTimeInterval(-settledReceiptRetention)
        let pendingIDs = Set(ledger.pendingHistoryProjections.map(\.id))
        ledger.settledReceipts.removeAll {
            !pendingIDs.contains($0.id) && $0.settledAt < cutoff
        }
    }

    private static func pruneFinishedRunUsages(
        in ledger: inout TransferAccountingLedger,
        relativeTo date: Date
    ) {
        let cutoff = date.addingTimeInterval(-settledReceiptRetention)
        ledger.runUsages.removeAll { usage in
            guard let finishedAt = usage.finishedAt, finishedAt < cutoff else { return false }
            return !ledger.activeReservations.contains {
                sameRun(usage, $0.binding)
            }
        }
    }

    private static func minimumLimit(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case (let value?, nil), (nil, let value?): value
        case (let lhs?, let rhs?): min(lhs, rhs)
        }
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw TransferAccountingError.arithmeticOverflow }
        return sum
    }

    private static func validate(_ binding: TransferAccountingGrantBinding) throws {
        guard isCanonicalDigest(binding.folderIncarnationDigest) else {
            throw TransferAccountingError.invalidBinding("folderIncarnationDigest")
        }
        guard isCanonicalDigest(binding.planDigest) else {
            throw TransferAccountingError.invalidBinding("planDigest")
        }
    }

    private static func validateTimeZoneIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty,
            identifier.utf8.count <= 128,
            !identifier.contains("\0"),
            TimeZone(identifier: identifier) != nil
        else {
            throw TransferAccountingError.invalidBudgetTimeZoneIdentifier(identifier)
        }
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func isValidDayKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.utf8.count == 10,
            parts.count == 3,
            parts[0].count == 4,
            parts[1].count == 2,
            parts[2].count == 2,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }

    private static func folderUsageSort(
        _ lhs: TransferAccountingFolderDayUsage,
        _ rhs: TransferAccountingFolderDayUsage
    ) -> Bool {
        if lhs.folderID.rawValue != rhs.folderID.rawValue {
            return lhs.folderID.rawValue < rhs.folderID.rawValue
        }
        return lhs.folderIncarnationDigest < rhs.folderIncarnationDigest
    }

    private static func runUsageSort(
        _ lhs: TransferAccountingRunUsage,
        _ rhs: TransferAccountingRunUsage
    ) -> Bool {
        let left = TransferAccountingRunKey(lhs).sortComponents
        let right = TransferAccountingRunKey(rhs).sortComponents
        return left.lexicographicallyPrecedes(right)
    }
}

private struct FolderIncarnationKey: Hashable {
    var folderID: FolderID
    var digest: String
}

private struct TransferAccountingRunKey: Hashable {
    var workKind: TransferAccountingWorkKind
    var folderID: FolderID
    var folderIncarnationDigest: String
    var taskID: UUID
    var runID: UUID

    init(_ usage: TransferAccountingRunUsage) {
        workKind = usage.workKind
        folderID = usage.folderID
        folderIncarnationDigest = usage.folderIncarnationDigest
        taskID = usage.taskID
        runID = usage.runID
    }

    init(_ binding: TransferAccountingGrantBinding) {
        workKind = binding.workKind
        folderID = binding.folderID
        folderIncarnationDigest = binding.folderIncarnationDigest
        taskID = binding.taskID
        runID = binding.runID
    }

    var sortComponents: [String] {
        [
            workKind.rawValue,
            folderID.rawValue,
            folderIncarnationDigest,
            taskID.uuidString.lowercased(),
            runID.uuidString.lowercased(),
        ]
    }
}

private struct LegacyTransferAccountingReservationV1: Decodable {
    var id: UUID
    var ownerID: UUID
    var folderID: FolderID
    var folderIncarnationDigest: String
    var taskID: UUID
    var sessionID: UUID
    var planDigest: String
    var dayKey: String
    var grantBytes: Int64
    var state: TransferAccountingReservationState
    var createdAt: Date
    var expiresAt: Date
    var grantSequence: UInt64
}

private struct LegacyTransferAccountingProjectionV1: Decodable {
    var id: UUID
    var ownerID: UUID
    var folderID: FolderID
    var folderIncarnationDigest: String
    var taskID: UUID
    var sessionID: UUID
    var planDigest: String
    var dayKey: String
    var grantedBytes: Int64
    var chargedBytes: Int64
    var kind: TransferAccountingSettlementKind
    var settledAt: Date
    var grantSequence: UInt64
}

private struct LegacyTransferAccountingLedgerV1: Decodable {
    var schemaVersion: Int
    var budgetTimeZoneIdentifier: String
    var nextGrantSequence: UInt64
    var dayBuckets: [TransferAccountingDayBucket]
    var activeReservations: [LegacyTransferAccountingReservationV1]
    var settledReceipts: [LegacyTransferAccountingProjectionV1]
    var pendingHistoryProjections: [LegacyTransferAccountingProjectionV1]
}

private enum StrictAccountingSchema {
    static func validate(_ value: StrictJSONValue) throws -> Int {
        do {
            guard case .number(let rawVersion)? = value.value(for: "schemaVersion"),
                let version = Int(rawVersion)
            else {
                throw TransferAccountingError.invalidLedger
            }
            guard version == 1 || version == TransferAccountingLedger.currentSchemaVersion else {
                throw TransferAccountingError.unsupportedSchemaVersion(version)
            }
            var rootKeys: Set<String> = [
                "schemaVersion",
                "budgetTimeZoneIdentifier",
                "nextGrantSequence",
                "dayBuckets",
                "activeReservations",
                "settledReceipts",
                "pendingHistoryProjections",
            ]
            if version >= 2 { rootKeys.insert("runUsages") }
            try validateObject(
                value,
                allowed: rootKeys
            )
            try validateDayBuckets(value.value(for: "dayBuckets"))
            var reservationKeys: Set<String> = [
                "id", "ownerID", "folderID", "folderIncarnationDigest",
                "taskID", "sessionID", "planDigest", "dayKey", "grantBytes",
                "state", "createdAt", "expiresAt", "grantSequence",
            ]
            if version >= 2 {
                reservationKeys.formUnion(["workKind", "runID", "runLimitBytes"])
            }
            try validateArray(
                value.value(for: "activeReservations"),
                keys: reservationKeys
            )
            var receiptKeys: Set<String> = [
                "id", "ownerID", "folderID", "folderIncarnationDigest",
                "taskID", "sessionID", "planDigest", "dayKey", "grantedBytes",
                "chargedBytes", "kind", "settledAt", "grantSequence",
            ]
            if version >= 2 {
                receiptKeys.formUnion(["workKind", "runID", "runLimitBytes"])
                try validateArray(
                    value.value(for: "runUsages"),
                    keys: [
                        "workKind", "folderID", "folderIncarnationDigest", "taskID",
                        "runID", "planDigest", "committedBytes", "limitBytes",
                        "updatedAt", "finishedAt",
                    ]
                )
            }
            try validateArray(value.value(for: "settledReceipts"), keys: receiptKeys)
            try validateArray(value.value(for: "pendingHistoryProjections"), keys: receiptKeys)
            return version
        } catch let error as TransferAccountingError {
            throw error
        } catch {
            throw TransferAccountingError.invalidLedger
        }
    }

    private static func validateDayBuckets(_ value: StrictJSONValue?) throws {
        guard case .array(let entries)? = value else {
            throw TransferAccountingError.invalidLedger
        }
        for entry in entries {
            try validateObject(
                entry,
                allowed: ["dayKey", "committedBytes", "folderUsage", "updatedAt"]
            )
            try validateArray(
                entry.value(for: "folderUsage"),
                keys: ["folderID", "folderIncarnationDigest", "committedBytes"]
            )
        }
    }

    private static func validateArray(
        _ value: StrictJSONValue?,
        keys: Set<String>
    ) throws {
        guard case .array(let entries)? = value else {
            throw TransferAccountingError.invalidLedger
        }
        for entry in entries { try validateObject(entry, allowed: keys) }
    }

    private static func validateObject(
        _ value: StrictJSONValue,
        allowed: Set<String>
    ) throws {
        guard let entries = value.objectEntries else {
            throw TransferAccountingError.invalidLedger
        }
        guard entries.allSatisfy({ allowed.contains($0.0) }) else {
            throw TransferAccountingError.invalidLedger
        }
    }
}
