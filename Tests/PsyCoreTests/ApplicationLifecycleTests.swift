import Foundation
import XCTest

@testable import PsyCore

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    func testScenesShareOneWorkerAndLastSceneStopsIt() async throws {
        let probe = CycleProbe()
        let controller = ForegroundSyncController(cycle: { await probe.run() })
        let first = UUID()
        let second = UUID()
        controller.setScene(first, active: true)
        await Task.yield()
        XCTAssertEqual(probe.starts, 0)
        controller.isEnabled = true
        controller.setScene(first, active: true)
        controller.setScene(second, active: true)
        await until { probe.starts == 1 }
        controller.setScene(first, active: false)
        await Task.yield()
        XCTAssertEqual(probe.active, 1)
        controller.setScene(second, active: false)
        await controller.waitUntilStopped()
        XCTAssertEqual(probe.active, 0)
        XCTAssertEqual(probe.maximumActive, 1)
        XCTAssertEqual(controller.activity, .stopped)
    }

    func testRapidReactivationWaitsForCancelledNativeWorkToDrain() async throws {
        let probe = CycleProbe()
        probe.holdDrain = true
        let controller = ForegroundSyncController(cycle: { await probe.run() })
        controller.isEnabled = true
        let scene = UUID()
        controller.setScene(scene, active: true)
        await until { probe.starts == 1 }
        controller.setScene(scene, active: false)
        controller.setScene(scene, active: true)
        await until { probe.isDraining }
        XCTAssertEqual(probe.starts, 1)
        probe.releaseDrain()
        await until { probe.starts == 2 }
        XCTAssertEqual(probe.maximumActive, 1)
        controller.setScene(scene, active: false)
        await controller.waitUntilStopped()
    }

    func testManualOperationStartsOnlyAfterAutomaticCancellationDrains() async throws {
        let probe = CycleProbe()
        probe.holdDrain = true
        let controller = ForegroundSyncController(cycle: { await probe.run() })
        controller.isEnabled = true
        let scene = UUID()
        controller.setScene(scene, active: true)
        await until { probe.starts == 1 }
        var manualStarted = false
        let manual = Task {
            await controller.withSuspension {
                XCTAssertEqual(probe.active, 0)
                manualStarted = true
            }
        }
        await until { probe.isDraining }
        XCTAssertFalse(manualStarted)
        probe.releaseDrain()
        await manual.value
        XCTAssertTrue(manualStarted)
        await until { probe.starts == 2 }
        controller.isEnabled = false
        await controller.waitUntilStopped()
        XCTAssertEqual(controller.activity, .paused)
        XCTAssertEqual(probe.maximumActive, 1)
    }

    func testDisabledSettingDoesNotResumeAfterManualOperation() async {
        var starts = 0
        let controller = ForegroundSyncController(cycle: {
            starts += 1
            return .init(.waiting)
        })
        controller.setScene(UUID(), active: true)
        await controller.withSuspension {}
        await Task.yield()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(controller.activity, .paused)
    }

    func testBackgroundEntryCancelsAnInteractiveRun() async {
        let controller = ForegroundSyncController(cycle: { .init(.waiting) })
        let scene = UUID()
        controller.setScene(scene, active: true)
        var started = false
        var cancelled = false
        let manual = Task {
            await controller.withSuspension {
                started = true
                do { try await Task.sleep(for: .seconds(3600)) } catch {
                    cancelled = Task.isCancelled
                }
            }
        }
        await until { started }
        controller.setScene(scene, active: false)
        controller.cancelUserOperationsIfInactive()
        await manual.value
        XCTAssertTrue(cancelled)
    }

    func testPairingProjectionExcludesThisDevice() {
        let local = DeviceID(rawValue: String(repeating: "A", count: 56))!
        let remote = DeviceID(rawValue: String(repeating: "B", count: 56))!
        var snapshot = CoreSnapshot(localDeviceID: local, devices: [DeviceRecord(id: local, name: "This iPhone")])
        XCTAssertTrue(snapshot.remoteDevices.isEmpty)
        snapshot.devices.append(DeviceRecord(id: remote, name: "Desktop"))
        XCTAssertEqual(snapshot.remoteDevices.map(\.id), [remote])
        XCTAssertEqual(snapshot.devices.count, 2)
    }

    func testCommandReportRequiresEveryExactSuccess() {
        let first = CoreCommand(kind: .sync, folderID: FolderID(rawValue: "one")!, trigger: .user)
        let second = CoreCommand(kind: .sync, folderID: FolderID(rawValue: "two")!, trigger: .user)
        let success = CoreCommandResult(commandID: first.id, status: .succeeded)
        XCTAssertFalse(CommandExecutionReport(commands: [], results: [:], outcome: nil).succeeded)
        XCTAssertFalse(CommandExecutionReport(commands: [first], results: [:], outcome: nil).succeeded)
        XCTAssertFalse(
            CommandExecutionReport(commands: [first, second], results: [first.id: success], outcome: nil).succeeded)
        XCTAssertTrue(CommandExecutionReport(commands: [first], results: [first.id: success], outcome: nil).succeeded)
        let blocked = CoreCommandResult(commandID: second.id, status: .blocked, errorCode: "networkUnavailable")
        XCTAssertFalse(
            CommandExecutionReport(
                commands: [first, second], results: [first.id: success, second.id: blocked], outcome: nil
            ).succeeded)
        XCTAssertFalse(CommandExecutionReport(commands: [first], results: [first.id: blocked], outcome: nil).succeeded)
    }

    func testFolderScheduleRotatesAndSkipsPausedAndLocalOnlyFolders() {
        func folder(_ id: String, paused: Bool = false, local: Bool = false) -> FolderRecord {
            FolderRecord(
                id: FolderID(rawValue: id)!, label: id, localPath: "/unused/\(id)", isPaused: paused,
                deviceIDs: local ? [] : nil)
        }
        var schedule = ForegroundFolderSchedule()
        var snapshot = CoreSnapshot(folders: [
            folder("b"), folder("a"), folder("c", paused: true), folder("d", local: true),
        ])
        XCTAssertEqual(schedule.next(in: snapshot)?.id.rawValue, "a")
        XCTAssertEqual(schedule.next(in: snapshot)?.id.rawValue, "b")
        XCTAssertEqual(schedule.next(in: snapshot)?.id.rawValue, "a")
        snapshot.folders.removeAll { $0.id.rawValue == "b" }
        XCTAssertEqual(schedule.next(in: snapshot)?.id.rawValue, "a")
        snapshot.folders.removeAll()
        XCTAssertNil(schedule.next(in: snapshot))
    }

    func testForegroundQueueCoalescesWithoutReplacingManualRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CoreCommandQueue(root: root)
        let folder = FolderID(rawValue: "shared")!
        let manual = CoreCommand(kind: .sync, folderID: folder, trigger: .user)
        try queue.enqueue(manual)
        let automatic = CoreCommand(kind: .sync, folderID: folder, trigger: .foreground)
        XCTAssertFalse(try queue.enqueueForegroundSyncIfNeeded(automatic))
        XCTAssertEqual(try queue.pending().map(\.id), [manual.id])
        let other = CoreCommand(kind: .sync, folderID: FolderID(rawValue: "other")!, trigger: .foreground)
        XCTAssertTrue(try queue.enqueueForegroundSyncIfNeeded(other))
        XCTAssertFalse(try queue.enqueueForegroundSyncIfNeeded(other))
        XCTAssertThrowsError(try queue.enqueueForegroundSyncIfNeeded(manual))
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

@MainActor
private final class CycleProbe {
    var starts = 0
    var active = 0
    var maximumActive = 0
    var holdDrain = false
    var isDraining = false
    private var drain: CheckedContinuation<Void, Never>?

    func run() async -> ForegroundSyncCycle {
        starts += 1
        active += 1
        maximumActive = max(maximumActive, active)
        do { try await Task.sleep(for: .seconds(3600)) } catch {}
        if holdDrain {
            isDraining = true
            await withCheckedContinuation { drain = $0 }
            isDraining = false
        }
        active -= 1
        return .init(.waiting)
    }

    func releaseDrain() {
        holdDrain = false
        drain?.resume()
        drain = nil
    }
}
