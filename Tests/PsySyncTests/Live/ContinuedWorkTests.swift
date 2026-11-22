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
}
