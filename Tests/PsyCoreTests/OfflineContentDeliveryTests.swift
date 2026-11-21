import Foundation
import XCTest

@testable import PsyCore

final class OfflineContentDeliveryTests: XCTestCase {
    func testManagedLocalContentOpensOfflineWithoutNetworkPolicyOrPayload() async throws {
        for availability: FileAvailability in [.local, .conflict] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let folder = FolderRecord(
                id: FolderID(rawValue: "share")!, label: "Share", localPath: root.path, isPaused: true)
            let data = Data("available offline".utf8)
            let item = IndexedItem(
                id: "file", folderID: folder.id, relativePath: "file.txt", isDirectory: false, size: Int64(data.count),
                modifiedAt: .now,
                contentVersion: Data([1]), metadataVersion: Data([2]), availability: availability,
                hasUnuploadedChanges: true,
                generation: 1)
            let state = CoreSnapshot(
                generation: 1, configurationRevision: String(repeating: "a", count: 64),
                localDeviceID: DeviceID(rawValue: String(repeating: "A", count: 56)), folders: [folder], items: [item])
            let client = OfflineContentClient(snapshot: state, contents: data)
            var environment = SyncEnvironmentSnapshot.permissiveForTesting
            environment.network.kind = .unavailable
            environment.power.isLowPowerModeEnabled = true
            let offline = environment
            let destination = root.appendingPathComponent("files-copy.txt")
            let outcome = await CoreRuntime(clientFactory: { client }).materialize(
                item, to: destination, trigger: .fileProvider,
                paths: SharedContainerPaths(root: root.appendingPathComponent("state")), environment: offline,
                currentEnvironment: { offline },
                destinationAvailableCapacity: { _ in .max })
            XCTAssertTrue(outcome.completedSuccessfully, "\(outcome)")
            XCTAssertEqual(try Data(contentsOf: destination), data)
            let plans = await client.plans
            XCTAssertEqual(plans.map(\.operation), [.localContent])
            XCTAssertEqual(plans.map(\.maximumNetworkBytes.wireValue), ["0"])
            let commands = await client.commands
            XCTAssertTrue(commands.isEmpty)
        }
    }

    func testExecutorWaitsForTemporarilyHeldLeaseBeforeReportingOwnResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        let state = CoreSnapshot(
            generation: 1, configurationRevision: String(repeating: "a", count: 64),
            localDeviceID: DeviceID(rawValue: String(repeating: "A", count: 56)))
        let client = OfflineContentClient(snapshot: state, contents: nil)
        let owner = CoreProcessCoordinator(lockURL: paths.coreLock)
        _ = try await owner.acquire(as: .mainApp)
        let command = CoreCommand(kind: .disposeRecovery, arguments: ["recoveryID": "fixture"], trigger: .fileProvider)
        try CoreCommandQueue(root: paths.commandQueue).enqueue(command)
        let run = Task {
            await CoreCommandExecutor(runtime: CoreRuntime(clientFactory: { client })).execute(
                [command], trigger: .fileProvider,
                paths: paths, environment: .permissiveForTesting, currentEnvironment: { .permissiveForTesting },
                maximumPasses: 1, timeout: .seconds(3))
        }
        try await Task.sleep(for: .milliseconds(100))
        await owner.release()
        let report = await run.value
        XCTAssertTrue(report.succeeded, "\(String(describing: report.outcome))")
        XCTAssertEqual(report.results[command.id]?.status, .succeeded)
    }

    func testMissingLocalContentFallsBackToNetworkPolicyWithoutAnEmptySuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = FolderRecord(id: FolderID(rawValue: "share")!, label: "Share", localPath: root.path)
        let item = IndexedItem(
            id: "empty", folderID: folder.id, relativePath: "empty.txt", isDirectory: false,
            modifiedAt: .now, contentVersion: Data([1]), metadataVersion: Data([2]), availability: .local, generation: 1
        )
        let state = CoreSnapshot(
            generation: 1, configurationRevision: String(repeating: "a", count: 64),
            localDeviceID: DeviceID(rawValue: String(repeating: "A", count: 56)), folders: [folder], items: [item])
        let client = OfflineContentClient(snapshot: state, contents: nil)
        var environment = SyncEnvironmentSnapshot.permissiveForTesting
        environment.network.kind = .unavailable
        let offline = environment
        let destination = root.appendingPathComponent("empty.txt")
        let outcome = await CoreRuntime(clientFactory: { client }).materialize(
            item, to: destination, trigger: .fileProvider,
            paths: SharedContainerPaths(root: root.appendingPathComponent("state")), environment: offline,
            currentEnvironment: { offline },
            destinationAvailableCapacity: { _ in .max })
        guard case .policyDenied(let reasons) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reasons.contains(.networkUnavailable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

private actor OfflineContentClient: CoreClient {
    let state: CoreSnapshot
    let contents: Data?
    var binding: CoreExplicitSessionBinding?
    var plans: [CoreNetworkSessionPlan] = []
    var commands: [CoreCommand] = []
    init(snapshot: CoreSnapshot, contents: Data?) {
        state = snapshot
        self.contents = contents
    }
    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        throw CoreClientError.notRunning
    }
    func stop() async throws {}
    func snapshot() async throws -> CoreSnapshot { state }
    func execute(_ command: CoreCommand) async throws { commands.append(command) }
    func openConfigurationSession(configurationDirectory: URL, dataDirectory: URL, sessionID: UUID) async throws
        -> CoreExplicitSessionReceipt
    {
        binding = .configuration(sessionID: sessionID)
        return try receipt()
    }
    func openNetworkSession(
        configurationDirectory: URL, dataDirectory: URL, sessionID: UUID, plan: CoreNetworkSessionPlan
    ) async throws -> CoreExplicitSessionReceipt {
        guard plan.operation == .localContent, plan.maximumNetworkBytes.wireValue == "0" else {
            throw CoreClientError.invalidResponse("unexpected_network")
        }
        plans.append(plan)
        binding = .network(sessionID: sessionID, plan: plan)
        return try receipt()
    }
    func closeExplicitSession() async throws -> CoreExplicitSessionReceipt {
        let value = try receipt()
        binding = nil
        return value
    }
    func networkTransferTotals() async throws -> CoreNetworkTransferTotals? {
        .init(
            receivedBytes: 0, sentBytes: 0, budgetLimited: true, budgetLimitBytes: 0, budgetUsedBytes: 0,
            budgetExhausted: true)
    }
    func readRange(_ request: CoreReadRangeRequest) async throws -> Data {
        guard let contents else { throw CoreClientError.coreRejected("local_content_unavailable") }
        guard request.contentVersion == state.items[0].contentVersion else {
            throw CoreClientError.coreRejected("version_conflict")
        }
        return contents.subdata(in: Int(request.offset)..<(Int(request.offset) + request.length))
    }
    private func receipt() throws -> CoreExplicitSessionReceipt {
        try .init(
            binding: binding!, deviceID: state.localDeviceID!, generation: 1,
            configurationRevision: state.configurationRevision!)
    }
}
