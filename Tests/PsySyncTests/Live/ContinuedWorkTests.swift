import Foundation
import Testing
@testable import PsySync

/// User requirement: accept a share, close the app at once, and the
/// background task keeps going through the file list, the Files list and
/// the sync until the folder is complete.
struct ContinuedWorkTests {
    let f = FolderID(rawValue: "big-folder")
    let g = FolderID(rawValue: "default")

    func status(_ id: FolderID, _ state: FolderSyncState, _ progress: SyncProgress = .init()) -> FolderStatus {
        FolderStatus(folderID: id, state: state, progress: progress)
    }

    @Test func followsEveryPhaseAndEndsOnlyAfterAQuietPeriod() {
        var tracker = ContinuedWorkTracker(quietPeriod: 10)
        let t0 = Date()
        // Just accepted: no status for the folder yet. Not over.
        var step = tracker.step([status(g, .upToDate)], now: t0)
        #expect(step.phase == .idle && !step.finished)

        // File list arriving: progress moves with entries (bytes are 0).
        step = tracker.step([status(f, .fetchingIndex, .init(indexEntriesReceived: 40_000))], now: t0 + 3)
        #expect(step.phase == .fetchingIndex && step.folder == f)
        let first = Double(step.completed) / Double(step.total)
        step = tracker.step([status(f, .fetchingIndex, .init(indexEntriesReceived: 400_000))], now: t0 + 20)
        let later = Double(step.completed) / Double(step.total)
        #expect(later > first && later < 1)

        // Gap between index and projection: idle briefly, not finished.
        step = tracker.step([status(f, .upToDate)], now: t0 + 21)
        #expect(step.phase == .idle && !step.finished)
        step = tracker.step([status(f, .preparingFiles, .init(globalItems: 300))], now: t0 + 25)
        #expect(step.phase == .preparingFiles)

        // Everything mode: downloading by bytes.
        step = tracker.step([status(f, .syncing, .init(globalBytes: 1000, needBytes: 250))], now: t0 + 40)
        #expect(step.phase == .syncing && step.completed == 750 && step.total == 1000)

        // Complete: ends after the quiet period, as done.
        step = tracker.step([status(f, .upToDate, .init(globalBytes: 1000))], now: t0 + 60)
        #expect(!step.finished)
        step = tracker.step([status(f, .upToDate, .init(globalBytes: 1000))], now: t0 + 71)
        #expect(step.finished && !step.stalled)
    }

    @Test func endsStalledWhenNothingCanProgress() {
        var tracker = ContinuedWorkTracker(quietPeriod: 10)
        let t0 = Date()
        let waiting = status(f, .waitingForDevices, .init(globalBytes: 1000, needBytes: 400))
        _ = tracker.step([waiting], now: t0)
        let step = tracker.step([waiting], now: t0 + 10)
        #expect(step.finished && step.stalled)
    }

    @Test func indexPhaseWinsAndNamesTheOtherFolders() {
        var tracker = ContinuedWorkTracker()
        let step = tracker.step([
            status(g, .syncing, .init(globalBytes: 10, needBytes: 5)),
            status(f, .fetchingIndex, .init(indexEntriesReceived: 10)),
            status(FolderID(rawValue: "x"), .fetchingIndex),
        ])
        #expect(step.phase == .fetchingIndex && step.folder == f && step.otherFolders == 1)
    }

    // MARK: Progress the system does not see as stalled

    @Test func reportedProgressNeverGoesBackAcrossPhases() {
        var tracker = ContinuedWorkTracker()
        let t0 = Date()
        var units: [Int64] = []
        let script: [[FolderStatus]] = [
            [status(f, .fetchingIndex, .init(indexEntriesReceived: 10_000))],
            [status(f, .fetchingIndex, .init(indexEntriesReceived: 300_000))],
            [status(f, .upToDate)],                                          // gap
            [status(f, .preparingFiles, .init(globalItems: 300_000))],
            [status(f, .syncing, .init(globalBytes: 1000, needBytes: 900))], // raw fraction drops
            [status(f, .syncing, .init(globalBytes: 1000, needBytes: 100))],
        ]
        for (i, statuses) in script.enumerated() {
            units.append(tracker.step(statuses, now: t0 + Double(i)).units)
        }
        #expect(units == units.sorted())
        #expect(Set(units).count == units.count)            // every change moved it
        #expect(units.last! < ContinuedWorkTracker.unitScale) // full only when done
    }

    @Test func activityWithoutMeasurableProgressStillMovesTheBar() {
        // Device: folders busy (Files list, materialising) while needBytes
        // stayed put; the bar froze and the task expired 3 s after leaving.
        var tracker = ContinuedWorkTracker()
        let t0 = Date()
        let busy = status(f, .syncing, .init(globalBytes: 1000, needBytes: 500))
        var last = tracker.step([busy], appActivity: 0, now: t0).units
        for i in 1...30 {
            let units = tracker.step([busy], appActivity: Int64(i * 7), now: t0 + Double(i)).units
            #expect(units > last)
            last = units
        }
        // Nothing changes: the bar holds (no invented progress).
        let held = tracker.step([busy], appActivity: 210, now: t0 + 31).units
        #expect(held == last)
    }

    @Test func preparingFilesMovesWithTheFilesList() {
        var tracker = ContinuedWorkTracker()
        let t0 = Date()
        let preparing = status(f, .preparingFiles, .init(globalItems: 50_000))
        let a = tracker.step([preparing], appActivity: 1_000, now: t0).units
        let b = tracker.step([preparing], appActivity: 2_000, now: t0 + 1).units
        #expect(b > a)
    }

    // MARK: Ending

    @Test func stuckWorkEndsOnlyInTheBackground() {
        var tracker = ContinuedWorkTracker(quietPeriod: 10, stuckPeriod: 20)
        let t0 = Date()
        let fetching = status(f, .fetchingIndex, .init(indexEntriesReceived: 19))
        _ = tracker.step([fetching], inBackground: false, now: t0)
        // Foreground: the system waits; the task keeps going.
        var step = tracker.step([fetching], inBackground: false, now: t0 + 60)
        #expect(!step.finished)
        // Leaving the app with work that has not changed for a while: end
        // at once, before the system expires the task.
        step = tracker.step([fetching], inBackground: true, now: t0 + 61)
        #expect(step.finished && step.stuck && !step.stalled)
    }

    @Test func activityResetsTheStuckClock() {
        var tracker = ContinuedWorkTracker(quietPeriod: 10, stuckPeriod: 20)
        let t0 = Date()
        for i in 0..<60 {
            let s = status(f, .fetchingIndex, .init(indexEntriesReceived: Int64(i / 5)))   // a batch every 5 s
            let step = tracker.step([s], inBackground: true, now: t0 + Double(i))
            #expect(!step.finished)
        }
        // Last batch arrived at 55 s.
        let s = status(f, .fetchingIndex, .init(indexEntriesReceived: 11))
        #expect(!tracker.step([s], inBackground: true, now: t0 + 74).finished)
        #expect(tracker.step([s], inBackground: true, now: t0 + 75).finished)
    }

    @Test func onlyCutShortTransfersReportFailure() {
        // The system shows "failed" for success: false.
        #expect(ContinuedEnd.done.success)
        #expect(ContinuedEnd.stalled.success)     // peer offline / paused: not our failure
        #expect(ContinuedEnd.stuck.success)
        #expect(ContinuedEnd.expiredIdle.success)
        #expect(!ContinuedEnd.expired.success)
        #expect(!ContinuedEnd.engineUnavailable.success)

        #expect(ContinuedEnd.expired(lastPhase: .idle, needBytes: 0) == .expiredIdle)
        #expect(ContinuedEnd.expired(lastPhase: nil, needBytes: 0) == .expiredIdle)
        #expect(ContinuedEnd.expired(lastPhase: .idle, needBytes: 10) == .expired)
        #expect(ContinuedEnd.expired(lastPhase: .syncing, needBytes: 0) == .expired)
    }

    // MARK: Engine status failures

    @Test func aSingleSnapshotFailureDoesNotEndTheTask() {
        // Device: a folder removed between listing folders and reading its
        // status failed one snapshot, and the task ended as failed.
        var window = SnapshotFailureWindow(window: 20)
        let t0 = Date()
        var gaveUp = window.failed(now: t0)
        #expect(!gaveUp && window.isFailing)
        window.succeeded()
        #expect(!window.isFailing)
        // A new run of failures starts its own window.
        gaveUp = window.failed(now: t0 + 100)
        #expect(!gaveUp)
        gaveUp = window.failed(now: t0 + 119)
        #expect(!gaveUp)
        gaveUp = window.failed(now: t0 + 120)
        #expect(gaveUp)
    }
}

@Suite struct StopDeadlineTests {
    @Test func usesTheBackgroundTimeThereIs() {
        // Still in the foreground (backgroundTimeRemaining is huge): the cap.
        #expect(LifecycleBudget.stopDeadline(remaining: .greatestFiniteMagnitude) == .seconds(20))
        #expect(LifecycleBudget.stopDeadline(remaining: .infinity) == .seconds(20))
        // ~30 s granted after didEnterBackground.
        #expect(LifecycleBudget.stopDeadline(remaining: 29) == .seconds(20))
        #expect(LifecycleBudget.stopDeadline(remaining: 15) == .seconds(10))
        // Expiring task (device: remaining=4 s, a 5 s stop ran past it): short.
        #expect(LifecycleBudget.stopDeadline(remaining: 4) == .seconds(2))
        #expect(LifecycleBudget.stopDeadline(remaining: 0) == .seconds(2))
    }
}
