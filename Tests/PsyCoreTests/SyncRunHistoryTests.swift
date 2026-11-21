import Foundation
import XCTest

@testable import PsyCore

final class SyncRunHistoryTests: XCTestCase {
    func testNetworkTransferTotalsRequireMonotonicNonoverflowingCounters() {
        let baseline = CoreNetworkTransferTotals(receivedBytes: 10, sentBytes: 20)
        let current = CoreNetworkTransferTotals(receivedBytes: 13, sentBytes: 27)

        XCTAssertEqual(
            current.delta(since: baseline),
            CoreNetworkTransferTotals(receivedBytes: 3, sentBytes: 7)
        )
        XCTAssertEqual(current.delta(since: baseline)?.totalBytes, 10)
        XCTAssertNil(baseline.delta(since: current))
        XCTAssertNil(CoreNetworkTransferTotals(receivedBytes: .max, sentBytes: 1).totalBytes)
    }

    func testHistoryAggregatesMeasuredNetworkBytesAndFailsClosedForUnknownRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = SyncRunHistory(url: root.appendingPathComponent("history.jsonl"))
        try history.append(
            SyncRunRecord(
                trigger: .foreground,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 20),
                transferredBytes: 99,
                networkReceivedBytes: 3,
                networkSentBytes: 4,
                endReason: .completed
            )
        )
        try history.append(
            SyncRunRecord(
                trigger: .backgroundRefresh,
                startedAt: Date(timeIntervalSince1970: 30),
                endedAt: Date(timeIntervalSince1970: 40),
                transferredBytes: 0,
                networkReceivedBytes: 0,
                networkSentBytes: 0,
                endReason: .completed
            )
        )

        XCTAssertEqual(
            try history.measuredNetworkBytes(since: Date(timeIntervalSince1970: 15)),
            7
        )
        XCTAssertEqual(
            try history.measuredNetworkBytes(since: Date(timeIntervalSince1970: 25)),
            0
        )

        try history.append(
            SyncRunRecord(
                trigger: .foreground,
                startedAt: Date(timeIntervalSince1970: 50),
                endedAt: Date(timeIntervalSince1970: 60),
                transferredBytes: 0,
                endReason: .failed
            )
        )
        XCTAssertNil(try history.measuredNetworkBytes(since: Date(timeIntervalSince1970: 15)))
        XCTAssertNil(try history.recent(limit: 1).first?.measuredNetworkBytes)
    }

    func testHistoryPersistsNewestFirstWithoutSensitiveDetails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = SyncRunHistory(url: root.appendingPathComponent("history.jsonl"))
        let first = SyncRunRecord(
            trigger: .backgroundRefresh,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            transferredBytes: 10,
            endReason: .completed
        )
        let second = SyncRunRecord(
            trigger: .fileProvider,
            startedAt: Date(timeIntervalSince1970: 3),
            endedAt: Date(timeIntervalSince1970: 4),
            transferredBytes: 20,
            endReason: .policyDenied,
            failureCode: PolicyBlockReason.expensiveNetworkDenied.rawValue
        )
        try history.append(first)
        try history.append(second)
        XCTAssertEqual(try history.recent().map(\.id), [second.id, first.id])
        XCTAssertEqual(try history.recent(limit: 1).first?.failureCode, "expensiveNetworkDenied")
    }

    func testRecentStreamsAcrossReadChunksAndKeepsOnlyNewestLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = SyncRunHistory(url: root.appendingPathComponent("history.jsonl"))
        var identifiers: [UUID] = []
        for index in 0..<20 {
            let record = SyncRunRecord(
                trigger: .foreground,
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                endedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                transferredBytes: Int64(index),
                networkReceivedBytes: Int64(index),
                networkSentBytes: 0,
                endReason: .completed,
                failureCode: String(repeating: "x", count: 4 * 1_024) + "-\(index)"
            )
            identifiers.append(record.id)
            try history.append(record)
        }

        XCTAssertEqual(
            try history.recent(limit: 3).map(\.id),
            Array(identifiers.suffix(3).reversed())
        )
        XCTAssertEqual(try history.recent(limit: 0), [])
    }

    func testMeasurementSummaryDetectsExternalAppendAndSameSizeRewrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("history.jsonl")
        let history = SyncRunHistory(url: historyURL)
        let since = Date(timeIntervalSince1970: 15)
        try history.append(
            SyncRunRecord(
                trigger: .foreground,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 20),
                transferredBytes: 7,
                networkReceivedBytes: 3,
                networkSentBytes: 4,
                endReason: .completed
            )
        )

        XCTAssertEqual(try history.measuredNetworkBytes(since: since), 7)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: historyURL.appendingPathExtension("network-measurement-v1.json").path
            )
        )

        let externallyAppended = SyncRunRecord(
            trigger: .fileProvider,
            startedAt: Date(timeIntervalSince1970: 30),
            endedAt: Date(timeIntervalSince1970: 40),
            transferredBytes: 11,
            networkReceivedBytes: 5,
            networkSentBytes: 6,
            endReason: .completed
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var appendedData = try encoder.encode(externallyAppended)
        appendedData.append(0x0A)
        let handle = try FileHandle(forWritingTo: historyURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: appendedData)
        try handle.synchronize()
        try handle.close()

        XCTAssertEqual(try history.measuredNetworkBytes(since: since), 18)

        let attributes = try FileManager.default.attributesOfItem(atPath: historyURL.path)
        let modificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let original = try String(contentsOf: historyURL, encoding: .utf8)
        let rewritten = original.replacingOccurrences(
            of: "\"networkReceivedBytes\":3",
            with: "\"networkReceivedBytes\":8"
        )
        XCTAssertNotEqual(rewritten, original)
        XCTAssertEqual(rewritten.utf8.count, original.utf8.count)
        try Data(rewritten.utf8).write(to: historyURL)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: historyURL.path
        )

        XCTAssertEqual(try history.measuredNetworkBytes(since: since), 23)
    }

    func testAppendLeavesPriorSummaryStaleUntilAuthoritativeRebuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("history.jsonl")
        let summaryURL = historyURL.appendingPathExtension("network-measurement-v1.json")
        let history = SyncRunHistory(url: historyURL)
        let since = Date(timeIntervalSince1970: 15)

        try history.append(
            SyncRunRecord(
                trigger: .foreground,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 20),
                transferredBytes: 7,
                networkReceivedBytes: 3,
                networkSentBytes: 4,
                endReason: .completed
            )
        )
        XCTAssertEqual(try history.measuredNetworkBytes(since: since), 7)
        let priorSummary = try Data(contentsOf: summaryURL)

        try history.append(
            SyncRunRecord(
                trigger: .fileProvider,
                startedAt: Date(timeIntervalSince1970: 30),
                endedAt: Date(timeIntervalSince1970: 40),
                transferredBytes: 11,
                networkReceivedBytes: 5,
                networkSentBytes: 6,
                endReason: .completed
            )
        )

        XCTAssertEqual(try Data(contentsOf: summaryURL), priorSummary)
        XCTAssertEqual(try history.measuredNetworkBytes(since: since), 18)
        XCTAssertNotEqual(try Data(contentsOf: summaryURL), priorSummary)
    }

    func testMeasurementSummaryRecoversFromCorruptOrOversizedSidecar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("history.jsonl")
        let summaryURL = historyURL.appendingPathExtension("network-measurement-v1.json")
        let history = SyncRunHistory(url: historyURL)
        let since = Date(timeIntervalSince1970: 15)
        try history.append(
            SyncRunRecord(
                trigger: .foreground,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 20),
                transferredBytes: 7,
                networkReceivedBytes: 3,
                networkSentBytes: 4,
                endReason: .completed
            )
        )
        XCTAssertEqual(try history.measuredNetworkBytes(since: since), 7)

        try Data("not-json".utf8).write(to: summaryURL)
        XCTAssertEqual(try history.measuredNetworkBytes(since: since), 7)
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: Data(contentsOf: summaryURL))
        )

        try Data(repeating: 0x41, count: 32 * 1_024).write(to: summaryURL)
        XCTAssertEqual(try history.measuredNetworkBytes(since: since), 7)
        XCTAssertLessThan(try Data(contentsOf: summaryURL).count, 16 * 1_024)
    }

    func testMeasurementSummaryRejectsSymbolicLinkSidecar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("history.jsonl")
        let summaryURL = historyURL.appendingPathExtension("network-measurement-v1.json")
        let borrowedURL = root.appendingPathComponent("borrowed-summary.json")
        let history = SyncRunHistory(url: historyURL)
        let since = Date(timeIntervalSince1970: 15)
        try history.append(
            SyncRunRecord(
                trigger: .foreground,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 20),
                transferredBytes: 7,
                networkReceivedBytes: 3,
                networkSentBytes: 4,
                endReason: .completed
            )
        )
        XCTAssertEqual(try history.measuredNetworkBytes(since: since), 7)
        try FileManager.default.moveItem(at: summaryURL, to: borrowedURL)
        let borrowed = try Data(contentsOf: borrowedURL)
        try FileManager.default.createSymbolicLink(
            at: summaryURL,
            withDestinationURL: borrowedURL
        )
        XCTAssertNoThrow(
            try FileManager.default.destinationOfSymbolicLink(atPath: summaryURL.path)
        )

        XCTAssertEqual(try history.measuredNetworkBytes(since: since), 7)
        XCTAssertThrowsError(
            try FileManager.default.destinationOfSymbolicLink(atPath: summaryURL.path)
        )
        XCTAssertEqual(try Data(contentsOf: borrowedURL), borrowed)
        XCTAssertLessThan(try Data(contentsOf: summaryURL).count, 16 * 1_024)
    }

    func testHistoryOperationsRejectSymbolicLinkLeafWithoutTouchingTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historyURL = root.appendingPathComponent("history.jsonl")
        let borrowedURL = root.appendingPathComponent("borrowed-history.jsonl")
        let borrowedHistory = SyncRunHistory(url: borrowedURL)
        try borrowedHistory.append(
            SyncRunRecord(
                trigger: .foreground,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 20),
                transferredBytes: 7,
                networkReceivedBytes: 3,
                networkSentBytes: 4,
                endReason: .completed
            )
        )
        let borrowedData = try Data(contentsOf: borrowedURL)
        try FileManager.default.createSymbolicLink(
            at: historyURL,
            withDestinationURL: borrowedURL
        )
        let history = SyncRunHistory(url: historyURL)

        XCTAssertThrowsError(
            try history.append(
                SyncRunRecord(
                    trigger: .fileProvider,
                    startedAt: Date(timeIntervalSince1970: 30),
                    endedAt: Date(timeIntervalSince1970: 40),
                    transferredBytes: 11,
                    networkReceivedBytes: 5,
                    networkSentBytes: 6,
                    endReason: .completed
                )
            )
        )
        XCTAssertThrowsError(try history.recent(limit: 1))
        XCTAssertThrowsError(
            try history.measuredNetworkBytes(since: Date(timeIntervalSince1970: 15))
        )
        XCTAssertNoThrow(
            try FileManager.default.destinationOfSymbolicLink(atPath: historyURL.path)
        )
        XCTAssertEqual(try Data(contentsOf: borrowedURL), borrowedData)
    }

    func testMeasurementRebuildUsesOpenedDescriptorAcrossTemporaryPathReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("history.jsonl")
        let parkedURL = root.appendingPathComponent("parked-history.jsonl")
        let alternateURL = root.appendingPathComponent("alternate-history.jsonl")
        let history = SyncRunHistory(url: historyURL)
        try history.append(
            SyncRunRecord(
                trigger: .foreground,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 20),
                transferredBytes: 7,
                networkReceivedBytes: 3,
                networkSentBytes: 4,
                endReason: .completed
            )
        )
        try SyncRunHistory(url: alternateURL).append(
            SyncRunRecord(
                trigger: .fileProvider,
                startedAt: Date(timeIntervalSince1970: 30),
                endedAt: Date(timeIntervalSince1970: 40),
                transferredBytes: 100,
                networkReceivedBytes: 40,
                networkSentBytes: 60,
                endReason: .completed
            )
        )
        var openHookCount = 0
        var finishHookCount = 0
        var descriptorMeasuredBytes: Int64?
        let summaryURL = historyURL.appendingPathExtension("network-measurement-v1.json")

        XCTAssertThrowsError(
            try history.measuredNetworkBytesForTesting(
                since: Date(timeIntervalSince1970: 15),
                didOpenHistoryForScan: {
                    openHookCount += 1
                    try FileManager.default.moveItem(at: historyURL, to: parkedURL)
                    try FileManager.default.moveItem(at: alternateURL, to: historyURL)
                },
                didFinishReadingHistoryForScan: { measuredBytes in
                    descriptorMeasuredBytes = measuredBytes
                    finishHookCount += 1
                    try FileManager.default.moveItem(at: historyURL, to: alternateURL)
                    try FileManager.default.moveItem(at: parkedURL, to: historyURL)
                }
            )
        )

        // The opened descriptor was still the original seven-byte history,
        // never the 100-byte object temporarily installed at the path. The
        // path mutation itself is rejected by the post-read identity check.
        XCTAssertEqual(descriptorMeasuredBytes, 7)
        XCTAssertEqual(openHookCount, 1)
        XCTAssertEqual(finishHookCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: summaryURL.path))
        XCTAssertEqual(
            try history.measuredNetworkBytes(since: Date(timeIntervalSince1970: 15)),
            7
        )
        XCTAssertEqual(
            try SyncRunHistory(url: alternateURL).measuredNetworkBytes(
                since: Date(timeIntervalSince1970: 15)
            ),
            100
        )
    }

    func testOverlongHistoryLineFailsClosedAndIsNeverSilentlyTruncated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historyURL = root.appendingPathComponent("history.jsonl")
        let summaryURL = historyURL.appendingPathExtension("network-measurement-v1.json")
        var overlongLine = Data(repeating: 0x41, count: 64 * 1_024 + 1)
        overlongLine.append(0x0A)
        try overlongLine.write(to: historyURL)
        let history = SyncRunHistory(url: historyURL)
        let since = Date(timeIntervalSince1970: 15)

        XCTAssertNil(try history.measuredNetworkBytes(since: since))
        let summary = try Data(contentsOf: summaryURL)
        XCTAssertLessThan(summary.count, 16 * 1_024)
        XCTAssertNil(try history.measuredNetworkBytes(since: since))
        XCTAssertEqual(try Data(contentsOf: summaryURL), summary)
        XCTAssertThrowsError(try history.recent(limit: 1))

        let oversizedAppendURL = root.appendingPathComponent("oversized-append.jsonl")
        XCTAssertThrowsError(
            try SyncRunHistory(url: oversizedAppendURL).append(
                SyncRunRecord(
                    trigger: .foreground,
                    startedAt: Date(timeIntervalSince1970: 10),
                    endedAt: Date(timeIntervalSince1970: 20),
                    transferredBytes: 0,
                    networkReceivedBytes: 0,
                    networkSentBytes: 0,
                    endReason: .failed,
                    failureCode: String(repeating: "x", count: 70 * 1_024)
                )
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversizedAppendURL.path))
    }

    func testMeasurementSummaryCachesStableMalformedHistoryAndInvalidatesAfterRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historyURL = root.appendingPathComponent("history.jsonl")
        let summaryURL = historyURL.appendingPathExtension("network-measurement-v1.json")
        let history = SyncRunHistory(url: historyURL)
        let since = Date(timeIntervalSince1970: 15)
        var malformed = Data(repeating: 0x20, count: 2 * 1_024 * 1_024)
        malformed.replaceSubrange(0..<10, with: Data("{not-json\n".utf8))
        try malformed.write(to: historyURL)

        XCTAssertNil(try history.measuredNetworkBytes(since: since))
        let firstSummary = try Data(contentsOf: summaryURL)
        XCTAssertLessThan(firstSummary.count, 16 * 1_024)
        let firstAttributes = try FileManager.default.attributesOfItem(atPath: summaryURL.path)
        let firstFileNumber = try XCTUnwrap(
            (firstAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )

        XCTAssertNil(try history.measuredNetworkBytes(since: since))
        let secondAttributes = try FileManager.default.attributesOfItem(atPath: summaryURL.path)
        XCTAssertEqual(
            (secondAttributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            firstFileNumber
        )
        XCTAssertEqual(try Data(contentsOf: summaryURL), firstSummary)

        let repaired = SyncRunRecord(
            trigger: .foreground,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            transferredBytes: 7,
            networkReceivedBytes: 3,
            networkSentBytes: 4,
            endReason: .completed
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var repairedData = try encoder.encode(repaired)
        repairedData.append(0x0A)
        try repairedData.write(to: historyURL)

        XCTAssertEqual(try history.measuredNetworkBytes(since: since), 7)
    }

    func testBackgroundSchedulePlannerUsesPolicyAndPendingTransferEstimateForPowerHint() throws {
        let folderID = try XCTUnwrap(FolderID(rawValue: "folder"))
        let snapshot = CoreSnapshot(
            generation: 7,
            folders: [
                FolderRecord(
                    id: folderID,
                    label: "Folder",
                    localPath: "/redacted",
                    pendingUploadBytes: 40,
                    pendingDownloadBytes: 60
                )
            ]
        )
        let now = Date(timeIntervalSince1970: 100)
        var policy = SyncPolicy()
        policy.requirePowerForAllAutomaticWork = false
        policy.requirePowerForLargeTransferBytes = 100

        let plan = BackgroundTaskSchedulePlanner(
            refreshDelay: 10,
            processingDelay: 20
        ).makePlan(now: now, policy: policy, snapshot: snapshot)

        XCTAssertEqual(plan.refreshEarliestBeginDate, Date(timeIntervalSince1970: 110))
        XCTAssertEqual(plan.processingEarliestBeginDate, Date(timeIntervalSince1970: 120))
        XCTAssertEqual(plan.estimatedPendingTransferBytes, 100)
        XCTAssertTrue(plan.processingRequiresNetworkConnectivity)
        XCTAssertTrue(plan.processingRequiresExternalPower)
        XCTAssertTrue(plan.refreshEnabled)
        XCTAssertTrue(plan.processingEnabled)

        policy.requirePowerForLargeTransferBytes = 101
        XCTAssertFalse(
            BackgroundTaskSchedulePlanner().makePlan(now: now, policy: policy, snapshot: snapshot)
                .processingRequiresExternalPower
        )
        policy.requirePowerForAllAutomaticWork = true
        XCTAssertTrue(
            BackgroundTaskSchedulePlanner().makePlan(now: now, policy: policy, snapshot: nil)
                .processingRequiresExternalPower
        )
        policy.allowBackgroundDownload = false
        XCTAssertTrue(
            BackgroundTaskSchedulePlanner().makePlan(now: now, policy: policy, snapshot: snapshot)
                .processingEnabled
        )
        policy.automaticBackgroundMode = .refreshOnly
        let refreshOnly = BackgroundTaskSchedulePlanner().makePlan(
            now: now,
            policy: policy,
            snapshot: snapshot
        )
        XCTAssertTrue(refreshOnly.refreshEnabled)
        XCTAssertFalse(refreshOnly.processingEnabled)
        policy.automaticBackgroundMode = .disabled
        let disabled = BackgroundTaskSchedulePlanner().makePlan(
            now: now,
            policy: policy,
            snapshot: snapshot
        )
        XCTAssertFalse(disabled.refreshEnabled)
        XCTAssertFalse(disabled.processingEnabled)
    }

    func testBackgroundScheduleStatusStoreKeepsLatestAttemptForEachKind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackgroundTaskScheduleStatusStore(url: root.appendingPathComponent("schedule.json"))
        let refresh = BackgroundTaskScheduleAttempt(
            kind: .refresh,
            attemptedAt: Date(timeIntervalSince1970: 10),
            earliestBeginDate: Date(timeIntervalSince1970: 20),
            requiresNetworkConnectivity: false,
            requiresExternalPower: false,
            result: .scheduled
        )
        let processing = BackgroundTaskScheduleAttempt(
            kind: .processing,
            attemptedAt: Date(timeIntervalSince1970: 30),
            earliestBeginDate: nil,
            requiresNetworkConnectivity: true,
            requiresExternalPower: true,
            result: .failed,
            failureCode: .notPermitted
        )

        try store.record(refresh)
        try store.record(processing)
        let recovered = try store.read()

        XCTAssertEqual(recovered.refresh, refresh)
        XCTAssertEqual(recovered.processing, processing)
        XCTAssertNil(recovered.refresh?.failureCode)
        XCTAssertEqual(recovered.processing?.failureCode, .notPermitted)
    }

    func testBackgroundRefreshOnlyValidatesPersistedSnapshotAndRecordsOutcome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        try SharedSnapshotStore(snapshotURL: paths.snapshot).write(.init(generation: 42))

        let outcome = BackgroundSnapshotRefreshService().run(
            paths: paths,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(outcome, .validated(snapshotGeneration: 42))
        let record = try XCTUnwrap(SyncRunHistory(url: paths.history).recent(limit: 1).first)
        XCTAssertEqual(record.trigger, .backgroundRefresh)
        XCTAssertEqual(record.endReason, .completed)
        XCTAssertEqual(record.transferredBytes, 0)
        XCTAssertNil(record.failureCode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.commandQueue.path))
    }

    func testBackgroundRefreshRecordsNoWorkWithoutCreatingCoreOrQueueState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)

        XCTAssertEqual(BackgroundSnapshotRefreshService().run(paths: paths), .noSnapshot)
        XCTAssertEqual(
            try SyncRunHistory(url: paths.history).recent(limit: 1).first?.endReason,
            .noWork
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.coreConfiguration.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.commandQueue.path))
    }

    func testBackgroundRefreshMapsCorruptSnapshotToStableCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedContainerPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.snapshot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json /Users/private".utf8).write(to: paths.snapshot)

        XCTAssertEqual(
            BackgroundSnapshotRefreshService().run(paths: paths),
            .failed(code: .snapshotUnreadable)
        )
        let record = try XCTUnwrap(SyncRunHistory(url: paths.history).recent(limit: 1).first)
        XCTAssertEqual(record.failureCode, "backgroundRefreshSnapshotUnreadable")
        XCTAssertFalse(try Data(contentsOf: paths.history).contains(Data("/Users/private".utf8)))
    }

    func testOneShotCompletionGateDeliversOnlyOnceUnderContention() {
        let recorder = LockedCompletionRecorder()
        let gate = OneShotCompletionGate<Int> { recorder.record($0) }

        DispatchQueue.concurrentPerform(iterations: 100) { value in
            _ = gate.complete(value)
        }

        XCTAssertEqual(recorder.count, 1)
        XCTAssertNotNil(recorder.value)
    }
}

private final class LockedCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    var count: Int {
        lock.withLock { values.count }
    }

    var value: Int? {
        lock.withLock { values.first }
    }

    func record(_ value: Int) {
        lock.withLock { values.append(value) }
    }
}
