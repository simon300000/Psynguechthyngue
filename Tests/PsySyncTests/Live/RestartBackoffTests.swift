import Foundation
import Testing
@testable import PsySync

@Suite struct EngineRestartBackoffTests {
    @Test func growsAndCaps() {
        var b = EngineRestartBackoff()
        let t0 = ContinuousClock.now
        let delays = (0..<9).map { _ in b.nextDelay(now: t0) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
    }

    @Test func stableRunResets() {
        var b = EngineRestartBackoff()
        let t0 = ContinuousClock.now
        _ = b.nextDelay(now: t0)
        _ = b.nextDelay(now: t0)
        // A start that dies quickly keeps backing off…
        b.noteStarted(at: t0)
        #expect(b.nextDelay(now: t0 + .seconds(5)) == .seconds(4))
        // …one that ran for a minute starts over.
        b.noteStarted(at: t0 + .seconds(10))
        #expect(b.nextDelay(now: t0 + .seconds(80)) == .seconds(1))
    }
}

extension LiveSyncEngineTests {
    /// The bridge's exit callback marks a running engine failed at once (the
    /// host restarts on `.failed`), and a later start recovers.
    @Test func bridgeExitMarksEngineFailedAndRestartWorks() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        await h.engine.bridgeExited(code: "database", detail: "boom")
        #expect(await h.engine.state == .failed(code: "database", detail: "boom"))
        try await h.engine.stop(deadline: .seconds(1))
        try await h.engine.start(context: .foreground)
        guard case .running = await h.engine.state else { Issue.record("not running after restart"); return }
        try await h.engine.stop(deadline: .seconds(1))
        // Not running: ignored.
        await h.engine.bridgeExited(code: nil, detail: "late")
        #expect(await h.engine.state == .stopped)
    }
}
