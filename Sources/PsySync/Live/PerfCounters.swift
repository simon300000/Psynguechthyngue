import Foundation

/// Profiling counters (REST calls, upstream events, view body evaluations).
/// Off unless the App enables them (DEBUG `-PsyDebugPerf YES`); when off,
/// `hit` is a single flag read.
public enum PerfCounters {
    nonisolated(unsafe) public static var enabled = false
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    public static func hit(_ key: @autoclosure () -> String) {
        guard enabled else { return }
        let k = key()
        lock.withLock { counts[k, default: 0] += 1 }
    }

    /// Counts since the last drain.
    public static func drain() -> [String: Int] {
        lock.withLock {
            defer { counts = [:] }
            return counts
        }
    }
}
