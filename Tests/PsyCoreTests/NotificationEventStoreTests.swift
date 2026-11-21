import Foundation
import XCTest

@testable import PsyCore

final class NotificationEventStoreTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testDeliveryIsDisabledUntilExplicitAuthorizationAndPreferenceEnable() async throws {
        let fixture = try Fixture()
        let client = FakeNotificationDeliveryClient(
            authorizationStatus: .notDetermined,
            authorizationAfterRequest: .authorized
        )
        let coordinator = NotificationEventCoordinator(
            store: fixture.store,
            client: client,
            now: { Self.now }
        )

        let disabled = await coordinator.deliverNewEvents(
            snapshot: try notificationSnapshot(),
            mutationRecoveries: [try recovery()]
        )
        XCTAssertEqual(disabled, .disabled)
        let disabledRequests = await client.requests()
        XCTAssertTrue(disabledRequests.isEmpty)

        let enableResult = try await coordinator.setNotificationsEnabled(true)
        XCTAssertEqual(enableResult, .enabled(.authorized))
        let authorizationRequestCount = await client.authorizationRequestCount()
        XCTAssertEqual(authorizationRequestCount, 1)
        XCTAssertTrue(try fixture.store.configuration().isEnabled)

        let delivered = await coordinator.deliverNewEvents(
            snapshot: try notificationSnapshot(),
            mutationRecoveries: [try recovery()]
        )
        XCTAssertEqual(
            delivered,
            NotificationDeliveryReport(
                outcome: .scheduled,
                scheduledCount: 4,
                failedCount: 0
            )
        )
        let deliveredRequests = await client.requests()
        XCTAssertEqual(deliveredRequests.count, 4)
    }

    func testDeniedAndProvisionalAuthorizationAreHandledWithoutImplicitPrompting() async throws {
        let deniedFixture = try Fixture()
        let deniedClient = FakeNotificationDeliveryClient(authorizationStatus: .denied)
        let denied = NotificationEventCoordinator(
            store: deniedFixture.store,
            client: deniedClient,
            now: { Self.now }
        )
        let deniedResult = try await denied.setNotificationsEnabled(true)
        XCTAssertEqual(deniedResult, .permissionDenied)
        XCTAssertFalse(try deniedFixture.store.configuration().isEnabled)
        let deniedRequestCount = await deniedClient.authorizationRequestCount()
        XCTAssertEqual(deniedRequestCount, 0)

        let provisionalFixture = try Fixture()
        let provisionalClient = FakeNotificationDeliveryClient(authorizationStatus: .provisional)
        let provisional = NotificationEventCoordinator(
            store: provisionalFixture.store,
            client: provisionalClient,
            now: { Self.now }
        )
        let provisionalResult = try await provisional.setNotificationsEnabled(true)
        XCTAssertEqual(provisionalResult, .enabled(.provisional))
        let provisionalRequestCount = await provisionalClient.authorizationRequestCount()
        XCTAssertEqual(provisionalRequestCount, 0)
        let report = await provisional.deliverNewEvents(snapshot: try notificationSnapshot())
        XCTAssertEqual(report.scheduledCount, 3)
        XCTAssertEqual(report.failedCount, 0)
    }

    func testSuccessfulEventsDeduplicateAcrossRestartByExactVersionAndGeneration() async throws {
        let fixture = try Fixture()
        let firstClient = FakeNotificationDeliveryClient(authorizationStatus: .authorized)
        let first = NotificationEventCoordinator(
            store: fixture.store,
            client: firstClient,
            now: { Self.now }
        )
        _ = try await first.setNotificationsEnabled(true)
        let snapshot = try notificationSnapshot(generation: 7, offerVersionByte: 1)
        let summary = try recovery(recoveryIDByte: "a")
        let firstDelivery = await first.deliverNewEvents(
            snapshot: snapshot,
            mutationRecoveries: [summary]
        )
        XCTAssertEqual(firstDelivery.scheduledCount, 4)

        let restartedClient = FakeNotificationDeliveryClient(authorizationStatus: .authorized)
        let restarted = NotificationEventCoordinator(
            store: NotificationEventStore(url: fixture.url),
            client: restartedClient,
            now: { Self.now.addingTimeInterval(10) }
        )
        let duplicateDelivery = await restarted.deliverNewEvents(
            snapshot: snapshot,
            mutationRecoveries: [summary]
        )
        XCTAssertEqual(duplicateDelivery, .noNewEvents)
        let duplicateRequests = await restartedClient.requests()
        XCTAssertTrue(duplicateRequests.isEmpty)

        let next = try notificationSnapshot(generation: 8, offerVersionByte: 2)
        let nextRecovery = try recovery(recoveryIDByte: "b")
        let changed = await restarted.deliverNewEvents(
            snapshot: next,
            mutationRecoveries: [nextRecovery]
        )
        XCTAssertEqual(changed.scheduledCount, 4)
        let changedRequests = await restartedClient.requests()
        XCTAssertEqual(Set(changedRequests.map(\.kind)), Set(NotificationEventKind.allCases))
    }

    func testAbsentScheduledEventsAreEventuallyCompactedWithoutRenotifyingContinuousState() async throws {
        let fixture = try Fixture()
        let firstClient = FakeNotificationDeliveryClient(authorizationStatus: .authorized)
        let first = NotificationEventCoordinator(
            store: fixture.store,
            client: firstClient,
            now: { Self.now }
        )
        _ = try await first.setNotificationsEnabled(true)
        let snapshot = try notificationSnapshot()
        let firstDelivery = await first.deliverNewEvents(snapshot: snapshot)
        XCTAssertEqual(firstDelivery.scheduledCount, 3)

        let afterRetention = Self.now.addingTimeInterval(31 * 24 * 60 * 60)
        let restartedClient = FakeNotificationDeliveryClient(authorizationStatus: .authorized)
        let restarted = NotificationEventCoordinator(
            store: NotificationEventStore(url: fixture.url),
            client: restartedClient,
            now: { afterRetention }
        )
        let afterAbsence = await restarted.deliverNewEvents(snapshot: CoreSnapshot())
        XCTAssertEqual(afterAbsence, .noNewEvents)
        let durable = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url))
                as? [String: Any]
        )
        XCTAssertEqual((durable["events"] as? [[String: Any]])?.count, 0)

        let reappeared = await restarted.deliverNewEvents(snapshot: snapshot)
        XCTAssertEqual(reappeared.scheduledCount, 3)
        let reappearedRequests = await restartedClient.requests()
        XCTAssertEqual(reappearedRequests.count, 3)
    }

    func testDispatchingClaimIsAtMostOnceAcrossCrashAndClaimTokensRejectABA() throws {
        let fixture = try Fixture()
        try fixture.store.setEnabled(true)
        let candidate = NotificationEventCandidate(
            digest: String(repeating: "a", count: 64),
            kind: .pendingFolder
        )

        let first = try XCTUnwrap(try fixture.store.claim([candidate], now: Self.now).first)
        let replacement = try XCTUnwrap(
            try fixture.store.claim(
                [candidate],
                now: Self.now.addingTimeInterval(301)
            ).first
        )
        XCTAssertNotEqual(first.token, replacement.token)
        try fixture.store.abandon(first)
        XCTAssertTrue(try fixture.store.validate(replacement))
        XCTAssertThrowsError(try fixture.store.beginScheduling(first, now: Self.now))

        try fixture.store.beginScheduling(replacement, now: Self.now.addingTimeInterval(302))
        XCTAssertTrue(
            try fixture.store.claim(
                [candidate],
                now: Self.now.addingTimeInterval(1_000)
            ).isEmpty
        )
        try fixture.store.abandon(first)
        XCTAssertThrowsError(try fixture.store.complete(first, now: Self.now.addingTimeInterval(303)))
    }

    func testLegacyTokenlessClaimMigratesToAtMostOnceDispatchingState() throws {
        let fixture = try Fixture(createStateParent: true)
        let digest = String(repeating: "b", count: 64)
        let legacy = Data(
            "{\"events\":[{\"digest\":\"\(digest)\",\"kind\":\"pendingFolder\",\"status\":\"claimed\",\"updatedAt\":2000000000}],\"isEnabled\":true,\"schemaVersion\":1}"
                .utf8
        )
        try legacy.write(to: fixture.url)
        XCTAssertEqual(chmod(fixture.url.path, 0o600), 0)

        XCTAssertTrue(try fixture.store.configuration().isEnabled)
        let durable = try String(contentsOf: fixture.url, encoding: .utf8)
        XCTAssertTrue(durable.contains("\"status\":\"dispatching\""))
        XCTAssertTrue(durable.contains("\"claimToken\":"))
        let candidate = NotificationEventCandidate(digest: digest, kind: .pendingFolder)
        XCTAssertTrue(
            try fixture.store.claim(
                [candidate],
                now: Self.now.addingTimeInterval(301)
            ).isEmpty
        )
    }

    func testCapacityPressureEvictsOnlyOldestAbsentScheduledEvent() async throws {
        let fixture = try Fixture()
        let boundedStore = NotificationEventStore(url: fixture.url, maximumEvents: 3)
        let client = FakeNotificationDeliveryClient(authorizationStatus: .authorized)
        let coordinator = NotificationEventCoordinator(
            store: boundedStore,
            client: client,
            now: { Self.now }
        )
        _ = try await coordinator.setNotificationsEnabled(true)
        let original = try notificationSnapshot(generation: 7, offerVersionByte: 1)
        let originalReport = await coordinator.deliverNewEvents(snapshot: original)
        XCTAssertEqual(originalReport.scheduledCount, 3)

        let next = try notificationSnapshot(generation: 8, offerVersionByte: 1)
        let report = await coordinator.deliverNewEvents(snapshot: next)
        XCTAssertEqual(report.scheduledCount, 1)
        XCTAssertEqual(report.failedCount, 0)
        let requests = await client.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.last?.kind, .snapshotConflict)
    }

    func testAcceptedPlatformSideEffectWithFailedDurableCompletionNeverReschedules() async throws {
        let fixture = try Fixture()
        let parent = fixture.url.deletingLastPathComponent()
        let firstClient = FakeNotificationDeliveryClient(
            authorizationStatus: .authorized,
            scheduleSideEffect: { _ in
                _ = chmod(parent.path, 0o500)
            }
        )
        let first = NotificationEventCoordinator(
            store: fixture.store,
            client: firstClient,
            now: { Self.now }
        )
        _ = try await first.setNotificationsEnabled(true)
        let report = await first.deliverNewEvents(snapshot: try notificationSnapshot())
        XCTAssertEqual(report.outcome, .storeUnavailable)
        XCTAssertEqual(report.scheduledCount, 1)
        let acceptedRequests = await firstClient.requests()
        XCTAssertEqual(acceptedRequests.count, 1)
        XCTAssertEqual(chmod(parent.path, 0o700), 0)

        let restartedClient = FakeNotificationDeliveryClient(authorizationStatus: .authorized)
        let restarted = NotificationEventCoordinator(
            store: NotificationEventStore(url: fixture.url),
            client: restartedClient,
            now: { Self.now.addingTimeInterval(301) }
        )
        let retry = await restarted.deliverNewEvents(snapshot: try notificationSnapshot())
        XCTAssertEqual(retry.scheduledCount, 2)
        let retryRequests = await restartedClient.requests()
        XCTAssertFalse(retryRequests.contains(where: { $0.kind == .pendingDevice }))
    }

    func testSchedulingFailureIsNotRecordedAsSuccessAndRetriesAfterRestart() async throws {
        let fixture = try Fixture()
        let failingClient = FakeNotificationDeliveryClient(
            authorizationStatus: .authorized,
            failingKinds: [.pendingFolder]
        )
        let first = NotificationEventCoordinator(
            store: fixture.store,
            client: failingClient,
            now: { Self.now }
        )
        _ = try await first.setNotificationsEnabled(true)
        let report = await first.deliverNewEvents(snapshot: try notificationSnapshot())
        XCTAssertEqual(report.outcome, .partiallyScheduled)
        XCTAssertEqual(report.scheduledCount, 2)
        XCTAssertEqual(report.failedCount, 1)

        let retryClient = FakeNotificationDeliveryClient(authorizationStatus: .authorized)
        let restarted = NotificationEventCoordinator(
            store: NotificationEventStore(url: fixture.url),
            client: retryClient,
            now: { Self.now.addingTimeInterval(1) }
        )
        let retry = await restarted.deliverNewEvents(snapshot: try notificationSnapshot())
        XCTAssertEqual(retry.outcome, .scheduled)
        XCTAssertEqual(retry.scheduledCount, 1)
        XCTAssertEqual(retry.failedCount, 0)
        let retryRequests = await retryClient.requests()
        XCTAssertEqual(retryRequests.map(\.kind), [.pendingFolder])
        XCTAssertEqual(
            Set(NotificationEventKind.allCases),
            [.pendingDevice, .pendingFolder, .snapshotConflict, .mutationRecovery]
        )
    }

    func testDefiniteSchedulingFailureWithFailedAbandonReportsStoreUnavailable() async throws {
        let fixture = try Fixture()
        let parent = fixture.url.deletingLastPathComponent()
        let client = FakeNotificationDeliveryClient(
            authorizationStatus: .authorized,
            failingKinds: [.pendingFolder],
            scheduleSideEffect: { request in
                if request.kind == .pendingFolder {
                    _ = chmod(parent.path, 0o500)
                }
            }
        )
        let coordinator = NotificationEventCoordinator(
            store: fixture.store,
            client: client,
            now: { Self.now }
        )
        _ = try await coordinator.setNotificationsEnabled(true)

        let report = await coordinator.deliverNewEvents(snapshot: try notificationSnapshot())
        XCTAssertEqual(report.outcome, .storeUnavailable)
        XCTAssertEqual(report.scheduledCount, 1)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertEqual(chmod(parent.path, 0o700), 0)

        let durable = try String(contentsOf: fixture.url, encoding: .utf8)
        XCTAssertTrue(durable.contains("\"status\":\"dispatching\""))
    }

    func testDurableStateAndDeliveryRequestsContainNoPrivateIdentifiersOrPaths() async throws {
        let fixture = try Fixture()
        let client = FakeNotificationDeliveryClient(authorizationStatus: .authorized)
        let coordinator = NotificationEventCoordinator(
            store: fixture.store,
            client: client,
            now: { Self.now }
        )
        _ = try await coordinator.setNotificationsEnabled(true)
        let snapshot = try notificationSnapshot()
        let summary = try recovery()
        _ = await coordinator.deliverNewEvents(
            snapshot: snapshot,
            mutationRecoveries: [summary]
        )

        let durable = try String(decoding: Data(contentsOf: fixture.url), as: UTF8.self)
        for privateValue in [
            snapshot.pendingDevices[0].deviceID.rawValue,
            snapshot.pendingFolders[0].offeringDeviceID.rawValue,
            snapshot.pendingFolders[0].folderID.rawValue,
            snapshot.pendingFolders[0].label,
            snapshot.pendingFolders[0].offerVersion,
            snapshot.items[0].relativePath,
            summary.recoveryID,
            summary.relativePath,
            "tcp://private-address:22000",
        ] {
            XCTAssertFalse(durable.contains(privateValue), "leaked \(privateValue)")
        }

        for request in await client.requests() {
            let encoded = try JSONEncoder().encode(request)
            let string = String(decoding: encoded, as: UTF8.self)
            XCTAssertEqual(request.identifier.count, 74)
            XCTAssertTrue(request.identifier.hasPrefix("psy.event."))
            XCTAssertEqual(Set(request.deepLinkPayload.keys), ["destination"])
            for privateValue in [
                snapshot.pendingDevices[0].deviceID.rawValue,
                snapshot.pendingFolders[0].folderID.rawValue,
                snapshot.items[0].relativePath,
                summary.recoveryID,
                summary.relativePath,
            ] {
                XCTAssertFalse(string.contains(privateValue), "request leaked \(privateValue)")
            }
        }
    }

    func testDeliveryRequestDecodingCannotInjectAuthorityOrPrivatePayload() async throws {
        let fixture = try Fixture()
        let client = FakeNotificationDeliveryClient(authorizationStatus: .authorized)
        let coordinator = NotificationEventCoordinator(
            store: fixture.store,
            client: client,
            now: { Self.now }
        )
        _ = try await coordinator.setNotificationsEnabled(true)
        _ = await coordinator.deliverNewEvents(snapshot: try notificationSnapshot())
        let requests = await client.requests()
        let request = try XCTUnwrap(requests.first)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let valid = try encoder.encode(request)
        XCTAssertEqual(try decoder.decode(NotificationDeliveryRequest.self, from: valid), request)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        object["deepLinkPayload"] = [
            "destination": request.destination.rawValue,
            "deviceID": String(repeating: "C", count: 56),
        ]
        XCTAssertThrowsError(
            try decoder.decode(
                NotificationDeliveryRequest.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        object["deepLinkPayload"] = ["destination": request.destination.rawValue]
        object["identifier"] = "psy.event.not-a-digest"
        XCTAssertThrowsError(
            try decoder.decode(
                NotificationDeliveryRequest.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testCorruptOrUnknownSchemaFailsClosedBeforeClientScheduling() async throws {
        let fixture = try Fixture(createStateParent: true)
        try Data(#"{"schemaVersion":999,"isEnabled":true,"events":[]}"#.utf8).write(
            to: fixture.url
        )
        let client = FakeNotificationDeliveryClient(authorizationStatus: .authorized)
        let coordinator = NotificationEventCoordinator(
            store: fixture.store,
            client: client,
            now: { Self.now }
        )
        let report = await coordinator.deliverNewEvents(snapshot: try notificationSnapshot())
        XCTAssertEqual(report, .storeUnavailable)
        let corruptRequests = await client.requests()
        XCTAssertTrue(corruptRequests.isEmpty)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"schemaVersion":999,"isEnabled":true,"events":[]}"#.utf8))
                as? [String: Any]
        )
        var extra = object
        extra["schemaVersion"] = 1
        extra["unexpected"] = true
        try JSONSerialization.data(withJSONObject: extra).write(to: fixture.url)
        XCTAssertThrowsError(try fixture.store.configuration())
    }

    func testStateFileUsesNoFollowAtomicRegularFileAndOwnerOnlyPermissions() async throws {
        let fixture = try Fixture(createStateParent: true)
        let target = fixture.root.appendingPathComponent("attacker-target")
        try Data("do-not-touch".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)
        XCTAssertThrowsError(try fixture.store.setEnabled(true))
        XCTAssertEqual(try Data(contentsOf: target), Data("do-not-touch".utf8))

        try FileManager.default.removeItem(at: fixture.url)
        try fixture.store.setEnabled(true)
        var status = stat()
        XCTAssertEqual(lstat(fixture.url.path, &status), 0)
        XCTAssertEqual(status.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        XCTAssertEqual(status.st_mode & mode_t(0o077), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.url.appendingPathExtension("tmp").path
            )
        )
    }

    func testDeepLinksRequireCurrentAuthoritativeStateRatherThanPayloadAuthority() throws {
        let empty = CoreSnapshot()
        for destination in NotificationDestination.allCases {
            XCTAssertFalse(
                NotificationDeepLinkValidator.isActionable(destination, snapshot: empty)
            )
        }

        let current = try notificationSnapshot()
        XCTAssertTrue(NotificationDeepLinkValidator.isActionable(.devices, snapshot: current))
        XCTAssertTrue(NotificationDeepLinkValidator.isActionable(.folders, snapshot: current))
        XCTAssertTrue(NotificationDeepLinkValidator.isActionable(.globalFiles, snapshot: current))

        var noConflict = current
        noConflict.items = []
        let summary = try recovery()
        XCTAssertFalse(
            NotificationDeepLinkValidator.isActionable(
                .globalFiles,
                snapshot: noConflict,
                mutationRecoveries: [summary],
                mutationRecoveryStateAvailable: false
            )
        )
        XCTAssertTrue(
            NotificationDeepLinkValidator.isActionable(
                .globalFiles,
                snapshot: noConflict,
                mutationRecoveries: [summary],
                mutationRecoveryStateAvailable: true
            )
        )
    }

    private func notificationSnapshot(
        generation: UInt64 = 7,
        offerVersionByte: UInt8 = 1
    ) throws -> CoreSnapshot {
        let localID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let offeringID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let unknownID = try XCTUnwrap(DeviceID(rawValue: String(repeating: "C", count: 56)))
        let folderID = try XCTUnwrap(FolderID(rawValue: "private-folder-identity"))
        let version = canonicalOfferVersion(byte: offerVersionByte)
        let pendingDevice = try PendingDeviceOffer(
            deviceID: unknownID,
            label: "Untrusted peer label",
            lastSeen: Self.now,
            offerVersion: version,
            unverifiedIdentity: true,
            requiresExplicitAcceptance: true
        )
        let pendingFolder = try PendingFolderOffer(
            folderID: folderID,
            label: "Private shared-folder label",
            offeringDeviceID: offeringID,
            lastSeen: Self.now,
            offerVersion: version,
            receiveEncrypted: false,
            remoteEncrypted: false,
            requiresManagedLocalPath: true,
            requiresExplicitDeviceSelection: true
        )
        let conflict = IndexedItem(
            id: "private-item-identity",
            folderID: folderID,
            relativePath: "Private/Conflict/secret.txt",
            isDirectory: false,
            modifiedAt: Self.now,
            contentVersion: Data([1]),
            metadataVersion: Data([2]),
            availability: .conflict,
            generation: generation
        )
        return CoreSnapshot(
            generation: generation,
            generatedAt: Self.now,
            localDeviceID: localID,
            devices: [
                DeviceRecord(id: localID, name: "This device"),
                DeviceRecord(id: offeringID, name: "Peer", addresses: ["tcp://private-address:22000"]),
            ],
            folders: [
                FolderRecord(
                    id: folderID,
                    label: "Private folder",
                    localPath: "/private/mobile/secret",
                    deviceIDs: [offeringID]
                )
            ],
            items: [conflict],
            pendingDevices: [pendingDevice],
            pendingFolders: [pendingFolder],
            pendingDeviceObservationScope: .bridgeEventsPersisted,
            pendingFoldersAvailable: true
        )
    }

    private func recovery(recoveryIDByte: Character = "d") throws -> CoreMutationRecoverySummary {
        try CoreMutationRecoverySummary(
            recoveryID: String(repeating: recoveryIDByte, count: 64),
            folderID: FolderID(rawValue: "private-folder-identity")!,
            commandKind: .modify,
            relativePath: "Private/Recovery/secret.txt",
            payloadKind: .file,
            digest: String(repeating: "e", count: 64),
            bytes: 42,
            createdAt: Self.now,
            status: .retainedRequiresUserConfirmation
        )
    }

    private func canonicalOfferVersion(byte: UInt8) -> String {
        Data(repeating: byte, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct Fixture {
    let root: URL
    let url: URL
    let store: NotificationEventStore

    init(createStateParent: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("Metadata/notification-events.json")
        if createStateParent {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        store = NotificationEventStore(url: url)
    }
}

private actor FakeNotificationDeliveryClient: NotificationDeliveryClient {
    private var status: NotificationAuthorizationStatus
    private let authorizationAfterRequest: NotificationAuthorizationStatus
    private let failingKinds: Set<NotificationEventKind>
    private let scheduleSideEffect: (@Sendable (NotificationDeliveryRequest) -> Void)?
    private var delivered: [NotificationDeliveryRequest] = []
    private var requestCount = 0

    init(
        authorizationStatus: NotificationAuthorizationStatus,
        authorizationAfterRequest: NotificationAuthorizationStatus? = nil,
        failingKinds: Set<NotificationEventKind> = [],
        scheduleSideEffect: (@Sendable (NotificationDeliveryRequest) -> Void)? = nil
    ) {
        status = authorizationStatus
        self.authorizationAfterRequest = authorizationAfterRequest ?? authorizationStatus
        self.failingKinds = failingKinds
        self.scheduleSideEffect = scheduleSideEffect
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus { status }

    func requestAuthorization() async throws -> NotificationAuthorizationStatus {
        requestCount += 1
        status = authorizationAfterRequest
        return status
    }

    func schedule(
        _ request: NotificationDeliveryRequest
    ) async -> NotificationSchedulingDisposition {
        scheduleSideEffect?(request)
        if failingKinds.contains(request.kind) { return .definitelyNotAccepted }
        delivered.append(request)
        return .accepted
    }

    func requests() -> [NotificationDeliveryRequest] { delivered }
    func authorizationRequestCount() -> Int { requestCount }

}
