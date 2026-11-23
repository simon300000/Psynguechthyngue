import Darwin
import Foundation
import PsySync

/// Counts one evaluation of a view's body (DEBUG `-PsyDebugPerf YES` only).
/// Usage inside `body`: `let _ = perfProbe("HomeView")`.
@inline(__always)
func perfProbe(_ name: StaticString) {
    #if DEBUG
    PerfCounters.hit("body \(name)")
    #endif
}

/// DEBUG profiling log: every 10 s writes REST calls, upstream events, App
/// events and view body counts, plus process CPU and memory footprint, to the
/// lifecycle log (`app.log`, stage `perf`). Enabled with `-PsyDebugPerf YES`.
enum PerfLog {
    static func startIfRequested() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "PsyDebugPerf"), !PerfCounters.enabled else { return }
        PerfCounters.enabled = true
        Task.detached(priority: .utility) {
            var lastCPU = cpuSeconds()
            var lastWall = Date()
            while true {
                try? await Task.sleep(for: .seconds(10))
                let cpu = cpuSeconds(), now = Date()
                let pct = (cpu - lastCPU) / max(0.001, now.timeIntervalSince(lastWall)) * 100
                lastCPU = cpu
                lastWall = now
                let counts = PerfCounters.drain().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                let mib = (ProcessStats.physicalFootprint() ?? 0) / 1_048_576
                LifecycleLog.shared.record("perf", String(format: "cpu=%.1f%% footprint=%lldMiB ", pct, mib) + counts.joined(separator: " | "))
            }
        }
        #endif
    }

    static func cpuSeconds() -> Double { ProcessStats.cpuSeconds() }
}

enum ProcessStats {
    /// User + system CPU time of this process (all threads, Go included).
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }

    /// `task_vm_info.phys_footprint`: what iOS counts against the app's memory limit.
    static func physicalFootprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
    }
}
