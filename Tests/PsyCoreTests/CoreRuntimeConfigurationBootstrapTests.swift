import Foundation
import XCTest

@testable import PsyCore

final class CoreRuntimeConfigurationBootstrapTests: XCTestCase {
    private let revision = String(repeating: "a", count: 64)
    private let changedRevision = String(repeating: "b", count: 64)
    private let localDeviceID = DeviceID(rawValue: String(repeating: "A", count: 56))!
    private let otherDeviceID = DeviceID(rawValue: String(repeating: "B", count: 56))!

    func testEmptyContainerRefreshPersistsCanonicalIdentityAndUnlocksFirstConfigurationCommands()
        async throws
    {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        XCTAssertNil(try SharedSnapshotStore(snapshotURL: paths.snapshot).read())

        let client = ConfigurationBootstrapTestClient(
            snapshot: canonicalSnapshot(),
            openRevision: revision,
            closeRevision: revision,
            receiptDeviceID: localDeviceID
        )
        let outcome = await CoreRuntime(clientFactory: { client })
            .refreshConfigurationSnapshot(trigger: .foreground, paths: paths)

        XCTAssertEqual(outcome, .completed(processedCommands: 0, snapshotGeneration: 7))
        let events = await client.events()
        XCTAssertEqual(events, ["open:configuration", "snapshot", "close"])
        let persisted = try XCTUnwrap(
            try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
        )
        XCTAssertEqual(persisted.generation, 7)
        XCTAssertEqual(persisted.configurationRevision, revision)
        XCTAssertEqual(persisted.localDeviceID, localDeviceID)

        let producer = ScopedCoreCommandProducer(paths: paths)
        let addDevice = try XCTUnwrap(
            producer.prepareCommands(
                kind: .addDevice,
                itemID: otherDeviceID.rawValue,
                trigger: .user
            ).first
        )
        let addFolder = try XCTUnwrap(
            producer.prepareCommands(
                kind: .addFolder,
                folderID: FolderID(rawValue: "first-clean-install-folder"),
                trigger: .user
            ).first
        )
        XCTAssertEqual(addDevice.commandConfigurationRevision, revision)
        XCTAssertEqual(addFolder.commandConfigurationRevision, revision)
        XCTAssertNil(addFolder.folderIncarnationDigest)
    }

    func testBusyOwnerDoesNotOpenCoreOrCreateSnapshot() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let client = ConfigurationBootstrapTestClient(
            snapshot: canonicalSnapshot(),
            openRevision: revision,
            closeRevision: revision,
            receiptDeviceID: localDeviceID
        )
        let blocker = CoreProcessCoordinator(lockURL: paths.coreLock)
        _ = try await blocker.acquire(as: .fileProvider)

        let outcome = await CoreRuntime(clientFactory: { client })
            .refreshConfigurationSnapshot(trigger: .foreground, paths: paths)

        await blocker.release()
        XCTAssertEqual(outcome, .coreBusy)
        let events = await client.events()
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(try SharedSnapshotStore(snapshotURL: paths.snapshot).read())
    }

    func testOpenAndCloseFailuresNeverPublishAnUnclosedSnapshot() async throws {
        for behavior in [
            ConfigurationBootstrapTestClient.Failure.open,
            .close,
        ] {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            let client = ConfigurationBootstrapTestClient(
                snapshot: canonicalSnapshot(),
                openRevision: revision,
                closeRevision: revision,
                receiptDeviceID: localDeviceID,
                failure: behavior
            )

            let outcome = await CoreRuntime(clientFactory: { client })
                .refreshConfigurationSnapshot(trigger: .foreground, paths: paths)

            guard case .failed = outcome else {
                return XCTFail("unexpected outcome for \(behavior): \(outcome)")
            }
            XCTAssertNil(try SharedSnapshotStore(snapshotURL: paths.snapshot).read())
            let events = await client.events()
            XCTAssertFalse(events.contains("start:legacy"))
            XCTAssertFalse(events.contains("execute"))
            XCTAssertFalse(events.contains("stop:legacy"))
        }
    }

    func testRevisionAndDeviceMismatchFailClosedWithoutPublishingSnapshot() async throws {
        let wrongDeviceID = DeviceID(rawValue: String(repeating: "C", count: 56))!
        let cases: [(String, CoreSnapshot, DeviceID)] = [
            (changedRevision, canonicalSnapshot(), localDeviceID),
            (revision, canonicalSnapshot(localDeviceID: wrongDeviceID), localDeviceID),
        ]

        for (closeRevision, snapshot, receiptDeviceID) in cases {
            let paths = try makePaths()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            let client = ConfigurationBootstrapTestClient(
                snapshot: snapshot,
                openRevision: revision,
                closeRevision: closeRevision,
                receiptDeviceID: receiptDeviceID
            )

            let outcome = await CoreRuntime(clientFactory: { client })
                .refreshConfigurationSnapshot(trigger: .foreground, paths: paths)

            XCTAssertEqual(outcome, .failed(code: "coreInvalidResponse"))
            XCTAssertNil(try SharedSnapshotStore(snapshotURL: paths.snapshot).read())
            let events = await client.events()
            XCTAssertEqual(events, ["open:configuration", "snapshot", "close"])
        }
    }

    private func canonicalSnapshot(localDeviceID: DeviceID? = nil) -> CoreSnapshot {
        let deviceID = localDeviceID ?? self.localDeviceID
        return CoreSnapshot(
            generation: 7,
            configurationRevision: revision,
            localDeviceID: deviceID,
            devices: [DeviceRecord(id: deviceID, name: "This device")]
        )
    }

    private func makePaths() throws -> SharedContainerPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "core-runtime-configuration-bootstrap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return SharedContainerPaths(root: root)
    }
}

private actor ConfigurationBootstrapTestClient: CoreClient {
    enum Failure: CustomStringConvertible, Equatable {
        case open
        case close

        var description: String {
            switch self {
            case .open: "open"
            case .close: "close"
            }
        }
    }

    private let canonicalSnapshot: CoreSnapshot
    private let openRevision: String
    private let closeRevision: String
    private let receiptDeviceID: DeviceID
    private let failure: Failure?
    private var activeBinding: CoreExplicitSessionBinding?
    private var recordedEvents: [String] = []

    init(
        snapshot: CoreSnapshot,
        openRevision: String,
        closeRevision: String,
        receiptDeviceID: DeviceID,
        failure: Failure? = nil
    ) {
        canonicalSnapshot = snapshot
        self.openRevision = openRevision
        self.closeRevision = closeRevision
        self.receiptDeviceID = receiptDeviceID
        self.failure = failure
    }

    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        recordedEvents.append("start:legacy")
        throw CoreClientError.invalidResponse("legacy_start_used")
    }

    func openConfigurationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID
    ) async throws -> CoreExplicitSessionReceipt {
        recordedEvents.append("open:configuration")
        if failure == .open { throw CoreClientError.bridgeUnavailable }
        let binding = CoreExplicitSessionBinding.configuration(sessionID: sessionID)
        activeBinding = binding
        return try receipt(binding: binding, generation: 1, revision: openRevision)
    }

    func closeExplicitSession() async throws -> CoreExplicitSessionReceipt {
        recordedEvents.append("close")
        if failure == .close { throw CoreClientError.coreRejected("close_failed") }
        guard let binding = activeBinding else { throw CoreClientError.notRunning }
        activeBinding = nil
        return try receipt(binding: binding, generation: 2, revision: closeRevision)
    }

    func stop() async throws {
        recordedEvents.append("stop:legacy")
        throw CoreClientError.invalidResponse("legacy_stop_used")
    }

    func snapshot() async throws -> CoreSnapshot {
        guard activeBinding != nil else { throw CoreClientError.notRunning }
        recordedEvents.append("snapshot")
        return canonicalSnapshot
    }

    func execute(_ command: CoreCommand) async throws {
        recordedEvents.append("execute")
        throw CoreClientError.invalidResponse("execute_used")
    }

    func events() -> [String] { recordedEvents }

    private func receipt(
        binding: CoreExplicitSessionBinding,
        generation: UInt64,
        revision: String
    ) throws -> CoreExplicitSessionReceipt {
        try CoreExplicitSessionReceipt(
            binding: binding,
            deviceID: receiptDeviceID,
            generation: generation,
            configurationRevision: revision
        )
    }
}
