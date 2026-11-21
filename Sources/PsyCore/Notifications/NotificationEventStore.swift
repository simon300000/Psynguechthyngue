import CryptoKit
import Darwin
import Foundation

public enum NotificationAuthorizationStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case notDetermined
    case denied
    case provisional
    case authorized
    case ephemeral

    public var permitsDelivery: Bool {
        switch self {
        case .provisional, .authorized, .ephemeral: true
        case .notDetermined, .denied: false
        }
    }
}

public enum NotificationEventKind: String, Codable, CaseIterable, Hashable, Sendable {
    case pendingDevice
    case pendingFolder
    case snapshotConflict
    case mutationRecovery
}

/// A notification can only request navigation to a broad App-owned surface.
/// The payload deliberately cannot carry a device, folder, item, or recovery
/// identity. The App must re-read authoritative state before using it.
public enum NotificationDestination: String, Codable, CaseIterable, Hashable, Sendable {
    case devices
    case folders
    case globalFiles
}

/// Pure revalidation used after a notification opens the App. Notification
/// payloads are never evidence; only the newest authoritative projection may
/// make a destination actionable.
public enum NotificationDeepLinkValidator {
    public static func isActionable(
        _ destination: NotificationDestination,
        snapshot: CoreSnapshot,
        mutationRecoveries: [CoreMutationRecoverySummary] = [],
        mutationRecoveryStateAvailable: Bool = false
    ) -> Bool {
        switch destination {
        case .devices:
            snapshot.pendingDeviceObservationScope != .unavailable
                && !snapshot.pendingDevices.isEmpty
        case .folders:
            snapshot.pendingFoldersAvailable && !snapshot.pendingFolders.isEmpty
        case .globalFiles:
            snapshot.items.contains(where: { $0.availability == .conflict })
                || (mutationRecoveryStateAvailable && !mutationRecoveries.isEmpty)
        }
    }
}

/// Path-free request passed to the platform notification adapter. Titles and
/// bodies are selected from `kind` by trusted App code; no untrusted snapshot
/// text crosses this boundary.
public struct NotificationDeliveryRequest: Codable, Hashable, Sendable {
    public let identifier: String
    public let kind: NotificationEventKind
    public let destination: NotificationDestination
    public let deepLinkPayload: [String: String]

    fileprivate init(eventDigest: String, kind: NotificationEventKind) {
        identifier = "psy.event." + eventDigest
        self.kind = kind
        switch kind {
        case .pendingDevice:
            destination = .devices
        case .pendingFolder:
            destination = .folders
        case .snapshotConflict, .mutationRecovery:
            destination = .globalFiles
        }
        deepLinkPayload = ["destination": destination.rawValue]
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case kind
        case destination
        case deepLinkPayload
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try values.decode(String.self, forKey: .identifier)
        let kind = try values.decode(NotificationEventKind.self, forKey: .kind)
        guard identifier.hasPrefix("psy.event.") else {
            throw DecodingError.dataCorruptedError(
                forKey: .identifier,
                in: values,
                debugDescription: "Invalid notification identifier"
            )
        }
        let digest = String(identifier.dropFirst("psy.event.".count))
        guard NotificationEventStore.isLowercaseSHA256(digest) else {
            throw DecodingError.dataCorruptedError(
                forKey: .identifier,
                in: values,
                debugDescription: "Invalid notification event digest"
            )
        }
        let expected = NotificationDeliveryRequest(eventDigest: digest, kind: kind)
        guard try values.decode(NotificationDestination.self, forKey: .destination) == expected.destination,
            try values.decode([String: String].self, forKey: .deepLinkPayload)
                == expected.deepLinkPayload
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .deepLinkPayload,
                in: values,
                debugDescription: "Notification payload is not category-only"
            )
        }
        self = expected
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(identifier, forKey: .identifier)
        try values.encode(kind, forKey: .kind)
        try values.encode(destination, forKey: .destination)
        try values.encode(deepLinkPayload, forKey: .deepLinkPayload)
    }
}

public protocol NotificationDeliveryClient: Sendable {
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func requestAuthorization() async throws -> NotificationAuthorizationStatus
    /// Returns only after the platform has made a definite scheduling
    /// decision. Implementations must map a platform error to
    /// `definitelyNotAccepted`; an accepted request must never be surfaced as
    /// an error because the coordinator would otherwise be unable to decide
    /// whether retrying could duplicate an external notification.
    func schedule(_ request: NotificationDeliveryRequest) async -> NotificationSchedulingDisposition
}

public enum NotificationSchedulingDisposition: Hashable, Sendable {
    case accepted
    case definitelyNotAccepted
}

public enum NotificationPreferenceUpdateResult: Hashable, Sendable {
    case enabled(NotificationAuthorizationStatus)
    case disabled
    case permissionDenied
    case authorizationUnavailable
}

public enum NotificationDeliveryOutcome: String, Codable, Hashable, Sendable {
    case scheduled
    case partiallyScheduled
    case schedulingFailed
    case noNewEvents
    case disabled
    case authorizationRequired
    case permissionDenied
    case storeUnavailable
    case cancelled
}

public struct NotificationDeliveryReport: Hashable, Sendable {
    public let outcome: NotificationDeliveryOutcome
    public let scheduledCount: Int
    public let failedCount: Int

    public init(
        outcome: NotificationDeliveryOutcome,
        scheduledCount: Int,
        failedCount: Int
    ) {
        self.outcome = outcome
        self.scheduledCount = max(0, scheduledCount)
        self.failedCount = max(0, failedCount)
    }

    public static let noNewEvents = NotificationDeliveryReport(
        outcome: .noNewEvents,
        scheduledCount: 0,
        failedCount: 0
    )
    public static let disabled = NotificationDeliveryReport(
        outcome: .disabled,
        scheduledCount: 0,
        failedCount: 0
    )
    public static let authorizationRequired = NotificationDeliveryReport(
        outcome: .authorizationRequired,
        scheduledCount: 0,
        failedCount: 0
    )
    public static let permissionDenied = NotificationDeliveryReport(
        outcome: .permissionDenied,
        scheduledCount: 0,
        failedCount: 0
    )
    public static let storeUnavailable = NotificationDeliveryReport(
        outcome: .storeUnavailable,
        scheduledCount: 0,
        failedCount: 0
    )
    public static let cancelled = NotificationDeliveryReport(
        outcome: .cancelled,
        scheduledCount: 0,
        failedCount: 0
    )
}

public struct NotificationEventConfiguration: Hashable, Sendable {
    public let isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }
}

public enum NotificationEventStoreError: Error, Hashable, Sendable {
    case invalidClock
    case invalidDocument
    case unsupportedSchema(Int)
    case capacityExceeded
    case unsafeStateFile
    case staleClaim
}

extension SharedContainerPaths {
    public var notificationEvents: URL {
        root.appendingPathComponent("Metadata/notification-events.json")
    }
}

/// Durable, privacy-minimized notification history. Only one-way event
/// digests, generic kinds, delivery state, and timestamps are persisted. Raw
/// device/folder IDs, offer labels, paths, addresses, and recovery locators are
/// never stored here.
public struct NotificationEventStore: Sendable {
    private static let schemaVersion = 1
    private static let maximumDocumentBytes: Int64 = 2 * 1_024 * 1_024
    private static let defaultMaximumEvents = 8_192
    private static let maximumClaimsPerPass = 64
    private static let abandonedClaimInterval: TimeInterval = 5 * 60
    private static let scheduledRetentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private let url: URL
    private let lockURL: URL
    private let maximumEvents: Int

    public init(url: URL) {
        self.init(url: url, maximumEvents: Self.defaultMaximumEvents)
    }

    init(url: URL, maximumEvents: Int) {
        self.url = url
        lockURL = url.appendingPathExtension("lock")
        self.maximumEvents = max(1, maximumEvents)
    }

    public func configuration() throws -> NotificationEventConfiguration {
        try FileLock.withExclusiveLock(at: lockURL) {
            let document = try readDocumentLocked() ?? Document()
            return NotificationEventConfiguration(isEnabled: document.isEnabled)
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        try FileLock.withExclusiveLock(at: lockURL) {
            var document = try readDocumentLocked() ?? Document()
            document.isEnabled = enabled
            if !enabled {
                document.events.removeAll { $0.status == .claimed }
            }
            try writeDocumentLocked(document)
        }
    }

    func claim(
        _ candidates: [NotificationEventCandidate],
        now: Date
    ) throws -> [NotificationEventClaim] {
        guard now.timeIntervalSince1970.isFinite else {
            throw NotificationEventStoreError.invalidClock
        }
        return try FileLock.withExclusiveLock(at: lockURL) {
            var document = try readDocumentLocked() ?? Document()
            guard document.isEnabled else { return [] }

            let uniqueCandidates = Dictionary(
                candidates.map { ($0.digest, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values.sorted {
                ($0.kind.rawValue, $0.digest) < ($1.kind.rawValue, $1.digest)
            }
            let currentDigests = Set(uniqueCandidates.map(\.digest))
            let countBeforePruning = document.events.count
            document.events.removeAll { event in
                guard !currentDigests.contains(event.digest) else { return false }
                let elapsed = now.timeIntervalSince(event.updatedAt)
                guard elapsed.isFinite, elapsed >= 0 else { return false }
                switch event.status {
                case .claimed:
                    return elapsed > Self.abandonedClaimInterval
                case .dispatching, .scheduled:
                    return elapsed > Self.scheduledRetentionInterval
                }
            }
            let didPrune = document.events.count != countBeforePruning
            var eventIndex = Dictionary(
                uniqueKeysWithValues: document.events.enumerated().map { ($0.element.digest, $0.offset) }
            )
            var claims: [NotificationEventClaim] = []

            for candidate in uniqueCandidates {
                guard claims.count < Self.maximumClaimsPerPass else { break }
                if let index = eventIndex[candidate.digest] {
                    let existing = document.events[index]
                    guard existing.kind == candidate.kind else {
                        throw NotificationEventStoreError.invalidDocument
                    }
                    switch existing.status {
                    case .dispatching, .scheduled:
                        continue
                    case .claimed:
                        let elapsed = now.timeIntervalSince(existing.updatedAt)
                        guard elapsed.isFinite, elapsed >= 0 else { continue }
                        guard elapsed > Self.abandonedClaimInterval else { continue }
                        let token = Self.newClaimToken()
                        document.events[index] = EventRecord(
                            digest: candidate.digest,
                            kind: candidate.kind,
                            status: .claimed,
                            updatedAt: now,
                            claimToken: token
                        )
                        claims.append(
                            NotificationEventClaim(
                                digest: candidate.digest,
                                kind: candidate.kind,
                                token: token,
                                request: NotificationDeliveryRequest(
                                    eventDigest: candidate.digest,
                                    kind: candidate.kind
                                )
                            )
                        )
                        continue
                    }
                } else {
                    if document.events.count >= maximumEvents {
                        let evictionIndex = document.events.indices
                            .filter({ index in
                                let event = document.events[index]
                                return event.status == .scheduled
                                    && !currentDigests.contains(event.digest)
                            })
                            .min(by: { lhs, rhs in
                                let left = document.events[lhs]
                                let right = document.events[rhs]
                                return (left.updatedAt, left.kind.rawValue, left.digest)
                                    < (right.updatedAt, right.kind.rawValue, right.digest)
                            })
                        guard let evictionIndex else {
                            throw NotificationEventStoreError.capacityExceeded
                        }
                        document.events.remove(at: evictionIndex)
                        eventIndex = Dictionary(
                            uniqueKeysWithValues: document.events.enumerated().map {
                                ($0.element.digest, $0.offset)
                            }
                        )
                    }
                    let token = Self.newClaimToken()
                    document.events.append(
                        EventRecord(
                            digest: candidate.digest,
                            kind: candidate.kind,
                            status: .claimed,
                            updatedAt: now,
                            claimToken: token
                        )
                    )
                    eventIndex[candidate.digest] = document.events.count - 1
                    claims.append(
                        NotificationEventClaim(
                            digest: candidate.digest,
                            kind: candidate.kind,
                            token: token,
                            request: NotificationDeliveryRequest(
                                eventDigest: candidate.digest,
                                kind: candidate.kind
                            )
                        )
                    )
                    continue
                }
            }
            if !claims.isEmpty || didPrune { try writeDocumentLocked(document) }
            return claims
        }
    }

    func validate(_ claim: NotificationEventClaim) throws -> Bool {
        try FileLock.withExclusiveLock(at: lockURL) {
            guard let document = try readDocumentLocked(), document.isEnabled else { return false }
            return document.events.contains {
                $0.digest == claim.digest && $0.kind == claim.kind && $0.status == .claimed
                    && $0.claimToken == claim.token
            }
        }
    }

    func beginScheduling(_ claim: NotificationEventClaim, now: Date) throws {
        guard now.timeIntervalSince1970.isFinite else {
            throw NotificationEventStoreError.invalidClock
        }
        try FileLock.withExclusiveLock(at: lockURL) {
            guard var document = try readDocumentLocked(), document.isEnabled,
                let index = document.events.firstIndex(where: { $0.digest == claim.digest }),
                document.events[index].kind == claim.kind,
                document.events[index].status == .claimed,
                document.events[index].claimToken == claim.token
            else {
                throw NotificationEventStoreError.staleClaim
            }
            document.events[index] = EventRecord(
                digest: claim.digest,
                kind: claim.kind,
                status: .dispatching,
                updatedAt: now,
                claimToken: claim.token
            )
            try writeDocumentLocked(document)
        }
    }

    func complete(_ claim: NotificationEventClaim, now: Date) throws {
        guard now.timeIntervalSince1970.isFinite else {
            throw NotificationEventStoreError.invalidClock
        }
        try FileLock.withExclusiveLock(at: lockURL) {
            guard var document = try readDocumentLocked(),
                let index = document.events.firstIndex(where: { $0.digest == claim.digest }),
                document.events[index].kind == claim.kind,
                document.events[index].status == .dispatching,
                document.events[index].claimToken == claim.token
            else {
                throw NotificationEventStoreError.staleClaim
            }
            document.events[index] = EventRecord(
                digest: claim.digest,
                kind: claim.kind,
                status: .scheduled,
                updatedAt: now,
                claimToken: nil
            )
            try writeDocumentLocked(document)
        }
    }

    func abandon(_ claim: NotificationEventClaim) throws {
        try FileLock.withExclusiveLock(at: lockURL) {
            guard var document = try readDocumentLocked() else { return }
            document.events.removeAll {
                $0.digest == claim.digest && $0.kind == claim.kind
                    && ($0.status == .claimed || $0.status == .dispatching)
                    && $0.claimToken == claim.token
            }
            try writeDocumentLocked(document)
        }
    }

    private func readDocumentLocked() throws -> Document? {
        let data = try readStateFileSecurely()
        guard let data else { return nil }
        let decoded: Document
        do {
            decoded = try Self.decoder.decode(Document.self, from: data)
        } catch {
            throw NotificationEventStoreError.invalidDocument
        }
        guard decoded.schemaVersion == Self.schemaVersion else {
            throw NotificationEventStoreError.unsupportedSchema(decoded.schemaVersion)
        }
        guard try Self.encoder.encode(decoded) == data else {
            throw NotificationEventStoreError.invalidDocument
        }
        if decoded.events.contains(where: { $0.status == .claimed && $0.claimToken == nil }) {
            var migrated = decoded
            migrated.events = decoded.events.map { event in
                guard event.status == .claimed, event.claimToken == nil else { return event }
                return EventRecord(
                    digest: event.digest,
                    kind: event.kind,
                    status: .dispatching,
                    updatedAt: event.updatedAt,
                    claimToken: Self.newClaimToken()
                )
            }
            try writeDocumentLocked(migrated)
            return migrated
        }
        try validate(decoded)
        return decoded
    }

    private func writeDocumentLocked(_ proposed: Document) throws {
        var document = proposed
        document.schemaVersion = Self.schemaVersion
        document.events.sort {
            ($0.kind.rawValue, $0.digest) < ($1.kind.rawValue, $1.digest)
        }
        try validate(document)
        let data = try Self.encoder.encode(document)
        guard data.count <= Self.maximumDocumentBytes else {
            throw NotificationEventStoreError.capacityExceeded
        }
        do {
            try SecureLockFile.writeAtomically(data, to: url)
        } catch {
            throw NotificationEventStoreError.unsafeStateFile
        }
    }

    private func validate(_ document: Document) throws {
        guard document.schemaVersion == Self.schemaVersion,
            document.events.count <= maximumEvents,
            Set(document.events.map(\.digest)).count == document.events.count
        else {
            throw NotificationEventStoreError.invalidDocument
        }
        for event in document.events {
            guard Self.isLowercaseSHA256(event.digest),
                event.updatedAt.timeIntervalSince1970.isFinite,
                event.status == .scheduled
                    ? event.claimToken == nil
                    : event.claimToken.map(Self.isClaimToken) == true
            else {
                throw NotificationEventStoreError.invalidDocument
            }
        }
        guard
            document.events
                == document.events.sorted(by: {
                    ($0.kind.rawValue, $0.digest) < ($1.kind.rawValue, $1.digest)
                })
        else {
            throw NotificationEventStoreError.invalidDocument
        }
    }

    /// Uses descriptor-relative O_NOFOLLOW reads and validates identity, size,
    /// type, and owner-only permissions both before and after the read.
    private func readStateFileSecurely() throws -> Data? {
        let traversal: SecureLockFile.Traversal
        do {
            traversal = try SecureLockFile.openTraversal(
                to: url,
                createMissingDirectories: false
            )
        } catch let error as SecureLockFile.OpenError where error.code == ENOENT {
            return nil
        } catch {
            throw NotificationEventStoreError.unsafeStateFile
        }
        defer { SecureLockFile.closeTraversal(traversal) }

        let descriptor = traversal.leafName.withCString {
            openat(
                traversal.parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw NotificationEventStoreError.unsafeStateFile }
        defer { close(descriptor) }

        let before = try validatedStateFile(
            descriptor: descriptor,
            traversal: traversal
        )
        let data: Data
        do {
            data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        } catch {
            throw NotificationEventStoreError.unsafeStateFile
        }
        let after = try validatedStateFile(
            descriptor: descriptor,
            traversal: traversal
        )
        guard before.device == after.device,
            before.inode == after.inode,
            before.size == after.size,
            data.count == after.size
        else {
            throw NotificationEventStoreError.unsafeStateFile
        }
        return data
    }

    private func validatedStateFile(
        descriptor: Int32,
        traversal: SecureLockFile.Traversal
    ) throws -> StateFileIdentity {
        var descriptorStatus = stat()
        var pathStatus = stat()
        let pathResult = traversal.leafName.withCString {
            fstatat(
                traversal.parentDescriptor,
                $0,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard SecureLockFile.validate(traversal),
            fstat(descriptor, &descriptorStatus) == 0,
            pathResult == 0,
            descriptorStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            descriptorStatus.st_nlink > 0,
            descriptorStatus.st_dev == pathStatus.st_dev,
            descriptorStatus.st_ino == pathStatus.st_ino,
            descriptorStatus.st_size >= 0,
            descriptorStatus.st_size <= Self.maximumDocumentBytes,
            descriptorStatus.st_mode & mode_t(0o077) == 0,
            descriptorStatus.st_mode & mode_t(0o600) == mode_t(0o600)
        else {
            throw NotificationEventStoreError.unsafeStateFile
        }
        return StateFileIdentity(
            device: UInt64(descriptorStatus.st_dev),
            inode: UInt64(descriptorStatus.st_ino),
            size: Int(descriptorStatus.st_size)
        )
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    fileprivate static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }

    private static func newClaimToken() -> String {
        UUID().uuidString.lowercased()
    }

    private static func isClaimToken(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value == value.lowercased()
    }
}

/// Serializes permission changes and scheduling for one caller while the
/// store's descriptor-backed lock provides cross-instance crash/restart
/// deduplication.
public actor NotificationEventCoordinator {
    private let store: NotificationEventStore
    private let client: any NotificationDeliveryClient
    private let now: @Sendable () -> Date

    public init(
        store: NotificationEventStore,
        client: any NotificationDeliveryClient,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.store = store
        self.client = client
        self.now = now
    }

    public func configuration() throws -> NotificationEventConfiguration {
        try store.configuration()
    }

    public func authorizationStatus() async -> NotificationAuthorizationStatus {
        await client.authorizationStatus()
    }

    /// This is the only path that requests system authorization. Callers must
    /// invoke it from an explicit Settings action.
    public func setNotificationsEnabled(
        _ enabled: Bool
    ) async throws -> NotificationPreferenceUpdateResult {
        guard enabled else {
            try store.setEnabled(false)
            return .disabled
        }
        var status = await client.authorizationStatus()
        if status == .notDetermined {
            status = try await client.requestAuthorization()
        }
        switch status {
        case .denied:
            try store.setEnabled(false)
            return .permissionDenied
        case .notDetermined:
            try store.setEnabled(false)
            return .authorizationUnavailable
        case .provisional, .authorized, .ephemeral:
            try store.setEnabled(true)
            return .enabled(status)
        }
    }

    /// Schedules only review/attention events already present in an
    /// authoritative snapshot or recovery response. It never starts the core,
    /// reads a network address, or reports synchronization success.
    public func deliverNewEvents(
        snapshot: CoreSnapshot,
        mutationRecoveries: [CoreMutationRecoverySummary] = []
    ) async -> NotificationDeliveryReport {
        if Task.isCancelled { return .cancelled }
        let configuration: NotificationEventConfiguration
        do {
            configuration = try store.configuration()
        } catch {
            return .storeUnavailable
        }
        guard configuration.isEnabled else { return .disabled }

        switch await client.authorizationStatus() {
        case .notDetermined:
            return .authorizationRequired
        case .denied:
            return .permissionDenied
        case .provisional, .authorized, .ephemeral:
            break
        }

        let candidates = NotificationEventCandidate.make(
            snapshot: snapshot,
            mutationRecoveries: mutationRecoveries
        )
        let claims: [NotificationEventClaim]
        do {
            claims = try store.claim(candidates, now: now())
        } catch {
            return .storeUnavailable
        }
        guard !claims.isEmpty else { return .noNewEvents }

        var scheduledCount = 0
        var failedCount = 0
        var durableStateUnavailable = false
        for claim in claims {
            if Task.isCancelled {
                do {
                    try store.abandon(claim)
                    failedCount += 1
                } catch {
                    durableStateUnavailable = true
                    break
                }
                continue
            }
            var platformAccepted = false
            do {
                guard try store.validate(claim) else {
                    failedCount += 1
                    continue
                }
                try store.beginScheduling(claim, now: now())
                let schedulingDisposition = await client.schedule(claim.request)
                guard schedulingDisposition == .accepted else {
                    do {
                        try store.abandon(claim)
                    } catch {
                        durableStateUnavailable = true
                        break
                    }
                    failedCount += 1
                    continue
                }
                platformAccepted = true
                try store.complete(claim, now: now())
                scheduledCount += 1
            } catch {
                if platformAccepted {
                    // The platform side effect is now uncertain. Keep the
                    // durable dispatching tombstone so a crash or state-write
                    // failure can never turn into a duplicate alert.
                    scheduledCount += 1
                    durableStateUnavailable = true
                    break
                }
                do {
                    try store.abandon(claim)
                    failedCount += 1
                } catch {
                    durableStateUnavailable = true
                    break
                }
            }
        }
        let outcome: NotificationDeliveryOutcome
        if durableStateUnavailable {
            outcome = .storeUnavailable
        } else if Task.isCancelled, scheduledCount == 0 {
            outcome = .cancelled
        } else if failedCount > 0, scheduledCount > 0 {
            outcome = .partiallyScheduled
        } else if failedCount > 0 {
            outcome = .schedulingFailed
        } else {
            outcome = .scheduled
        }
        return NotificationDeliveryReport(
            outcome: outcome,
            scheduledCount: scheduledCount,
            failedCount: failedCount
        )
    }
}

struct NotificationEventCandidate: Hashable, Sendable {
    let digest: String
    let kind: NotificationEventKind

    static func make(
        snapshot: CoreSnapshot,
        mutationRecoveries: [CoreMutationRecoverySummary]
    ) -> [NotificationEventCandidate] {
        var result: [NotificationEventCandidate] = []
        if snapshot.pendingDeviceObservationScope != .unavailable {
            result.append(
                contentsOf: snapshot.pendingDevices.map { offer in
                    candidate(
                        kind: .pendingDevice,
                        fields: [offer.deviceID.rawValue, offer.offerVersion]
                    )
                })
        }
        if snapshot.pendingFoldersAvailable {
            result.append(
                contentsOf: snapshot.pendingFolders.map { offer in
                    candidate(
                        kind: .pendingFolder,
                        fields: [
                            offer.folderID.rawValue,
                            offer.offeringDeviceID.rawValue,
                            offer.offerVersion,
                        ]
                    )
                })
        }
        if snapshot.items.contains(where: { $0.availability == .conflict }) {
            result.append(
                candidate(kind: .snapshotConflict, fields: [String(snapshot.generation)])
            )
        }
        result.append(
            contentsOf: mutationRecoveries.map { summary in
                candidate(kind: .mutationRecovery, fields: [summary.recoveryID])
            })
        return result
    }

    private static func candidate(
        kind: NotificationEventKind,
        fields: [String]
    ) -> NotificationEventCandidate {
        var material = Data("psy-notification-event-v1".utf8)
        append(kind.rawValue, to: &material)
        for field in fields { append(field, to: &material) }
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return NotificationEventCandidate(digest: digest, kind: kind)
    }

    private static func append(_ value: String, to material: inout Data) {
        let bytes = Data(value.utf8)
        var count = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &count) { material.append(contentsOf: $0) }
        material.append(bytes)
    }
}

struct NotificationEventClaim: Hashable, Sendable {
    let digest: String
    let kind: NotificationEventKind
    let token: String
    let request: NotificationDeliveryRequest
}

private struct StateFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int
}

private struct Document: Codable, Hashable, Sendable {
    var schemaVersion = 1
    var isEnabled = false
    var events: [EventRecord] = []
}

private struct EventRecord: Codable, Hashable, Sendable {
    let digest: String
    let kind: NotificationEventKind
    let status: EventStatus
    let updatedAt: Date
    let claimToken: String?
}

private enum EventStatus: String, Codable, Hashable, Sendable {
    case claimed
    case dispatching
    case scheduled
}
