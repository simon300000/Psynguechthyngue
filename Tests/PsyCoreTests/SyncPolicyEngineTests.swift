import Foundation
import XCTest

@testable import PsyCore

final class SyncPolicyEngineTests: XCTestCase {
    private let engine = SyncPolicyEngine()

    func testWifiAllowsAutomaticTransferByDefault() {
        let decision = engine.evaluate(
            input(actions: [.upload, .download]),
            policy: .init()
        )
        XCTAssertEqual(decision.allowedActions, [.upload, .download])
        XCTAssertTrue(decision.blockedActions.isEmpty)
    }

    func testExpensiveWifiIsNotAssumedSafe() {
        var value = input(actions: [.upload, .download])
        value.network = .init(kind: .wifi, isExpensive: true)
        let decision = engine.evaluate(value, policy: .init())
        XCTAssertTrue(decision.allowedActions.isEmpty)
        XCTAssertEqual(decision.primaryBlockReason, .expensiveNetworkDenied)
    }

    func testConstrainedPathBlocksNetworkWorkButNotLocalScan() {
        var value = input(actions: [.exchangeIndex, .scan])
        value.network = .init(kind: .wifi, isConstrained: true)
        let decision = engine.evaluate(value, policy: .init())
        XCTAssertEqual(decision.allowedActions, [.scan])
        XCTAssertEqual(decision.blockedActions, [.exchangeIndex])
        XCTAssertEqual(decision.primaryBlockReason, .constrainedNetworkDenied)
    }

    func testCellularUploadOnlyBlocksDownload() {
        var policy = SyncPolicy()
        policy.cellularAccess = .uploadOnly
        policy.allowExpensive = true
        var value = input(actions: [.upload, .download])
        value.network = .init(kind: .cellular, isExpensive: true)
        let decision = engine.evaluate(value, policy: policy)
        XCTAssertEqual(decision.allowedActions, [.upload])
        XCTAssertEqual(decision.blockedActions, [.download])
        XCTAssertEqual(decision.primaryBlockReason, .cellularDirectionDenied)
    }

    func testDailyLimitFailsClosedWhenAccurateDailyCounterIsUnavailable() {
        var policy = SyncPolicy()
        policy.allowExpensive = true
        policy.dailyExpensiveBytes = 100
        var value = input(actions: [.upload])
        value.network = .init(kind: .wifi, isExpensive: true)
        value.transfer = .init(totalBytes: 200, alreadyTransferredTodayBytes: nil)

        let unavailable = engine.evaluate(value, policy: policy)
        XCTAssertTrue(unavailable.allowedActions.isEmpty)
        XCTAssertEqual(unavailable.primaryBlockReason, .dailyTransferAccountingUnavailable)

        value.transfer.alreadyTransferredTodayBytes = 1
        let measuredDecision = engine.evaluate(value, policy: policy)
        XCTAssertTrue(measuredDecision.allowedActions.isEmpty)
        XCTAssertEqual(measuredDecision.primaryBlockReason, .dailyTransferLimit)
    }

    func testDailyLimitAdditionOverflowFailsClosed() {
        var policy = SyncPolicy()
        policy.allowExpensive = true
        policy.dailyExpensiveBytes = .max
        var value = input(actions: [.download])
        value.network = .init(kind: .wifi, isExpensive: true)
        value.transfer = .init(totalBytes: 2, alreadyTransferredTodayBytes: .max)

        let decision = engine.evaluate(value, policy: policy)

        XCTAssertTrue(decision.allowedActions.isEmpty)
        XCTAssertEqual(decision.primaryBlockReason, .dailyTransferLimit)
    }

    func testTemporaryOverrideDoesNotBypassDataSafety() {
        var value = input(actions: [.download], trigger: .fileProvider)
        value.requestedTemporaryOverride = true
        value.safety.hasUnuploadedChanges = true
        value.network = .init(kind: .cellular, isExpensive: true, isConstrained: true)
        let decision = engine.evaluate(value, policy: .init())
        XCTAssertTrue(decision.allowedActions.isEmpty)
        XCTAssertTrue(decision.explanations.contains { $0.reason == .unuploadedChanges })
    }

    func testDirtyOrConflictedStateBlocksDownloadButEvictionUsesUploadedAuthority() {
        var value = input(actions: SyncAction.networkCoreRuntimeEnvelope, trigger: .user)
        value.safety.hasUnuploadedChanges = true
        value.safety.hasConflict = true
        value.safetyScope = .networkCoreRuntime

        let runtime = engine.evaluate(value, policy: .init())
        XCTAssertTrue(runtime.blockedActions.isEmpty)
        XCTAssertTrue(runtime.allowedActions.contains(.upload))
        XCTAssertTrue(runtime.allowedActions.contains(.download))

        value.safetyScope = .operationSpecific
        let destructiveDownload = engine.evaluate(value, policy: .init())
        XCTAssertTrue(destructiveDownload.blockedActions.contains(.download))

        value.requestedActions = [.evictLocalCopy]
        value.safetyScope = .networkCoreRuntime
        XCTAssertEqual(
            engine.evaluate(value, policy: .init()).blockedActions,
            []
        )
    }

    func testLegacyPolicyInputWithoutSafetyScopeDecodesOperationSpecific() throws {
        let value = input(actions: [.download])
        let encoded = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "safetyScope")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        XCTAssertEqual(
            try JSONDecoder().decode(SyncPolicyInput.self, from: legacy).safetyScope,
            .operationSpecific
        )
    }

    func testTemporaryOverrideCanBypassNetworkPreference() {
        var value = input(actions: [.download], trigger: .fileProvider)
        value.requestedTemporaryOverride = true
        value.network = .init(kind: .cellular, isExpensive: true, isConstrained: true)
        let decision = engine.evaluate(value, policy: .init())
        XCTAssertEqual(decision.allowedActions, [.download])
        XCTAssertTrue(decision.explanations.isEmpty)
    }

    func testTemporaryOverrideCannotBypassTransferCapsOrMissingAccounting() {
        var policy = SyncPolicy()
        policy.allowExpensive = true
        policy.maxExpensiveRunBytes = 100
        policy.dailyExpensiveBytes = 1_000

        var value = input(actions: [.upload], trigger: .user)
        value.requestedTemporaryOverride = true
        value.network = .init(kind: .wifi, isExpensive: true)
        value.transfer = .init(totalBytes: 101, alreadyTransferredTodayBytes: 0)

        let runLimit = engine.evaluate(value, policy: policy)
        XCTAssertEqual(runLimit.blockedActions, [.upload])
        XCTAssertEqual(runLimit.primaryBlockReason, .runTransferLimit)
        XCTAssertFalse(runLimit.explanations[0].canTemporarilyOverride)

        policy.maxExpensiveRunBytes = nil
        value.transfer = .init(totalBytes: 1, alreadyTransferredTodayBytes: nil)
        let unavailable = engine.evaluate(value, policy: policy)
        XCTAssertEqual(unavailable.blockedActions, [.upload])
        XCTAssertEqual(unavailable.primaryBlockReason, .dailyTransferAccountingUnavailable)
        XCTAssertFalse(unavailable.explanations[0].canTemporarilyOverride)

        value.transfer = .init(totalBytes: 2, alreadyTransferredTodayBytes: 999)
        let dailyLimit = engine.evaluate(value, policy: policy)
        XCTAssertEqual(dailyLimit.blockedActions, [.upload])
        XCTAssertEqual(dailyLimit.primaryBlockReason, .dailyTransferLimit)
        XCTAssertFalse(dailyLimit.explanations[0].canTemporarilyOverride)
    }

    func testLowPowerIndexOnlyMode() {
        var value = input(actions: [.exchangeIndex, .upload, .scan])
        value.power.isLowPowerModeEnabled = true
        let decision = engine.evaluate(value, policy: .init())
        XCTAssertEqual(decision.allowedActions, [.exchangeIndex])
        XCTAssertEqual(decision.blockedActions, [.upload, .scan])
    }

    func testAutomaticBackgroundModeStopsProcessingWithoutBlockingForegroundWork() {
        var policy = SyncPolicy()
        policy.automaticBackgroundMode = .refreshOnly
        let actions: Set<SyncAction> = [.exchangeIndex, .upload, .download, .scan]

        let background = engine.evaluate(
            input(actions: actions, trigger: .backgroundProcessing),
            policy: policy
        )
        XCTAssertTrue(background.allowedActions.isEmpty)
        XCTAssertEqual(background.blockedActions, actions)
        XCTAssertEqual(background.primaryBlockReason, .backgroundActionDisabled)

        let foreground = engine.evaluate(input(actions: actions, trigger: .user), policy: policy)
        XCTAssertEqual(foreground.allowedActions, actions)
        XCTAssertTrue(foreground.blockedActions.isEmpty)

        policy.automaticBackgroundMode = .disabled
        let refresh = engine.evaluate(
            input(actions: [.exchangeIndex], trigger: .backgroundRefresh),
            policy: policy
        )
        XCTAssertEqual(refresh.blockedActions, [.exchangeIndex])
    }

    func testThermalPressureKeepsIndexExchangeAvailable() {
        var value = input(actions: [.exchangeIndex, .upload, .hash])
        value.power.thermalLevel = .serious
        let decision = engine.evaluate(value, policy: .init())
        XCTAssertEqual(decision.allowedActions, [.exchangeIndex])
        XCTAssertEqual(decision.blockedActions, [.upload, .hash])
    }

    func testOvernightWindowUsesPreviousWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let window = TimeWindow(weekdays: [2], startMinute: 22 * 60, endMinute: 2 * 60)
        let formatter = ISO8601DateFormatter()
        let tuesdayMorning = try XCTUnwrap(formatter.date(from: "2026-08-11T01:00:00Z"))
        XCTAssertTrue(window.contains(tuesdayMorning, calendar: calendar))
        let wednesdayMorning = try XCTUnwrap(formatter.date(from: "2026-08-12T01:00:00Z"))
        XCTAssertFalse(window.contains(wednesdayMorning, calendar: calendar))
    }

    func testInsufficientDiskCannotBeOverridden() {
        var value = input(actions: [.download], trigger: .user)
        value.requestedTemporaryOverride = true
        value.safety.availableDiskBytes = 10
        let decision = engine.evaluate(value, policy: .init(minimumFreeDiskBytes: 100))
        XCTAssertTrue(decision.allowedActions.isEmpty)
        XCTAssertEqual(decision.primaryBlockReason, .insufficientDisk)
    }

    func testDownloadRequiresMinimumFreeSpacePlusUnreservedBytes() {
        var value = input(actions: [.download], trigger: .fileProvider)
        value.transfer = .init(totalBytes: 50)
        value.safety.availableDiskBytes = 149
        let policy = SyncPolicy(minimumFreeDiskBytes: 100)

        let denied = engine.evaluate(value, policy: policy)
        XCTAssertTrue(denied.explanations.contains(where: { $0.reason == .insufficientDisk }))

        value.safety.availableDiskBytes = 150
        let exactBoundary = engine.evaluate(value, policy: policy)
        XCTAssertFalse(exactBoundary.explanations.contains(where: { $0.reason == .insufficientDisk }))

        value.additionalDiskBytes = 0
        value.safety.availableDiskBytes = 100
        let alreadyReserved = engine.evaluate(value, policy: policy)
        XCTAssertFalse(alreadyReserved.explanations.contains(where: { $0.reason == .insufficientDisk }))
    }

    func testPendingUploadDoesNotConsumeDownloadDiskBudgetButPendingDownloadDoes() {
        var value = input(actions: SyncAction.networkCoreRuntimeEnvelope, trigger: .user)
        value.safetyScope = .networkCoreRuntime
        value.safety.availableDiskBytes = 100
        value.transfer = .init(
            totalBytes: 1_000_000_000,
            pendingDownloadBytes: 0
        )
        let policy = SyncPolicy(minimumFreeDiskBytes: 100)

        XCTAssertTrue(engine.evaluate(value, policy: policy).blockedActions.isEmpty)

        value.transfer.pendingDownloadBytes = 1
        XCTAssertTrue(
            engine.evaluate(value, policy: policy).blockedActions.contains(.download)
        )
    }

    func testDownloadDiskRequirementOverflowFailsClosed() {
        var value = input(actions: [.download], trigger: .fileProvider)
        value.additionalDiskBytes = .max
        value.safety.availableDiskBytes = .max

        let decision = engine.evaluate(value, policy: SyncPolicy(minimumFreeDiskBytes: 1))

        XCTAssertTrue(decision.allowedActions.isEmpty)
        XCTAssertEqual(decision.primaryBlockReason, .insufficientDisk)
    }

    func testLocalCacheEvictionDoesNotRequireNetworkOrFreeDiskSpace() {
        var value = input(actions: [.evictLocalCopy])
        value.network = .init(kind: .unavailable, isExpensive: true, isConstrained: true)
        value.safety.availableDiskBytes = 0

        let decision = engine.evaluate(value, policy: SyncPolicy())

        XCTAssertEqual(decision.allowedActions, [.evictLocalCopy])
        XCTAssertTrue(decision.blockedActions.isEmpty)
    }

    func testLocalCacheEvictionDoesNotDuplicateUploadedEvidenceChecks() {
        var value = input(actions: [.evictLocalCopy])
        value.safety.hasConflict = true
        XCTAssertEqual(
            engine.evaluate(value, policy: SyncPolicy()).blockedActions,
            []
        )

        value.safety.hasConflict = false
        value.safety.hasUnuploadedChanges = true
        XCTAssertEqual(
            engine.evaluate(value, policy: SyncPolicy()).blockedActions,
            []
        )
    }

    private func input(
        actions: Set<SyncAction>,
        trigger: SyncTrigger = .foreground
    ) -> SyncPolicyInput {
        SyncPolicyInput(
            trigger: trigger,
            requestedActions: actions,
            network: .init(kind: .wifi),
            power: .init(
                batteryLevel: 0.8,
                isExternalPowerConnected: true,
                isLowPowerModeEnabled: false,
                thermalLevel: .nominal
            )
        )
    }
}
