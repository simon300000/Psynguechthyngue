import Foundation
import Testing
@testable import PsySync

private let f1 = FolderID(rawValue: "f1")

/// Part 8: Files showed no ring for files the App engine downloads on its
/// own. The mirror asks the system to download such a file while it arrives.
@Suite struct FilesDownloadMirrorTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [ItemIdentifier] = []
        /// Requests block until released (a download in progress).
        let gate = AsyncStream<Void>.makeStream()
        func add(_ id: ItemIdentifier) { lock.withLock { list.append(id) } }
        var ids: [ItemIdentifier] { lock.withLock { list } }
    }

    private func progress(_ path: String, _ done: Int64, _ total: Int64) -> EngineEvent {
        .downloadProgress(folderID: f1, path: RelativePath(rawValue: path), bytesDone: done, bytesTotal: total)
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func asksFilesOncePerTransferForLargeFiles() async throws {
        let h = try ContentHarness(mode: .everything)
        try h.project([FilesFixtures.file("big.bin", size: 8 << 20, local: false),
                       FilesFixtures.file("small.txt", size: 100, local: false)])
        let recorder = Recorder()
        let mirror = FilesDownloadMirror(store: h.store) { _, id in recorder.add(id) }
        await mirror.handle(progress("big.bin", 1 << 20, 8 << 20))
        await mirror.handle(progress("big.bin", 2 << 20, 8 << 20))
        await mirror.handle(progress("small.txt", 10, 100))
        await mirror.handle(progress("unknown.bin", 1 << 20, 8 << 20))
        await waitFor { recorder.ids.count == 1 }
        #expect(recorder.ids == [try h.id("big.bin")])
        // Pulled again later (a new version): asked again.
        await mirror.handle(.itemFinished(folderID: f1, path: RelativePath(rawValue: "big.bin"), error: nil))
        await waitFor { true }
        await mirror.handle(progress("big.bin", 1 << 20, 8 << 20))
        await waitFor { recorder.ids.count == 2 }
        #expect(recorder.ids.count == 2)
    }

    @Test func atMostMaxConcurrentAtOnce() async throws {
        let h = try ContentHarness(mode: .everything)
        try h.project((1...4).map { FilesFixtures.file("f\($0).bin", size: 4 << 20, local: false) })
        let recorder = Recorder()
        let gate = recorder.gate
        let mirror = FilesDownloadMirror(store: h.store, maxConcurrent: 2) { _, id in
            recorder.add(id)
            for await _ in gate.stream { break }
        }
        for n in 1...4 { await mirror.handle(progress("f\(n).bin", 1, 4 << 20)) }
        await waitFor { recorder.ids.count == 2 }
        #expect(recorder.ids.count == 2)
        #expect(await mirror.inFlight == 2)
        gate.continuation.finish()
        await waitFor { true }
    }

    @Test func aCompletedTransferIsNotMirrored() async throws {
        let h = try ContentHarness(mode: .everything)
        try h.project([FilesFixtures.file("done.bin", size: 4 << 20, local: false)])
        let recorder = Recorder()
        let mirror = FilesDownloadMirror(store: h.store) { _, id in recorder.add(id) }
        await mirror.handle(progress("done.bin", 4 << 20, 4 << 20))
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.ids.isEmpty)
    }
}
