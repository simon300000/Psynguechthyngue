import Darwin
import os

/// phys_footprint is what jetsam limits (not RSS). Logged at extension init
/// and around each fetchContents so the non-bridge share can be attributed.
enum FootprintProbe {
    struct Sample {
        var footprintMiB: Double
        var peakMiB: Double
    }

    static func sample() -> Sample? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Sample(footprintMiB: Double(info.phys_footprint) / 1_048_576,
                      peakMiB: Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    static func log(_ phase: String) {
        guard let s = sample() else { return }
        Logger(subsystem: "app.psynguechthyngue.files", category: "footprint")
            .log("phase=\(phase, privacy: .public) footprint=\(s.footprintMiB, format: .fixed(precision: 1))MiB peak=\(s.peakMiB, format: .fixed(precision: 1))MiB")
    }
}
