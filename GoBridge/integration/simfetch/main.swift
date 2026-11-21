// SPDX-License-Identifier: MIT
//
// Restricted-fetch memory probe for the iOS Simulator (GoBridge/Scripts/
// sim-fetch-memory.sh). Runs PsyBridgeAdapter.fetch in a bare iOS process so
// the bridge's own phys_footprint can be told apart from what the File
// Provider extension (Swift runtime, FileProvider.framework, SQLite of
// files.sqlite, ...) adds on top.
//
// Usage: simfetch <home> <cert.pem> <key.pem> <folder> <path> <dest>

import Darwin
import Foundation
import PsyBridge
import PsySync

func footprintMiB() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

let args = CommandLine.arguments
guard args.count == 7 else {
    print("usage: simfetch <home> <cert.pem> <key.pem> <folder> <path> <dest>")
    exit(64)
}
let base = footprintMiB()
print(String(format: "SIMFETCH baseline footprint=%.1fMiB peak=%.1fMiB", base.now, base.peak))

let bridge = PsyBridgeAdapter()
PsyBridgeAdapter.setRestrictedLog(level: "trace") { level, message in
    if level == "trace" { print("SIMFETCH", message) }
}
do {
    let cert = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let key = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    let identity = DeviceIdentity(certificatePEM: cert, privateKeyPEM: key, deviceID: try bridge.deviceID(certificatePEM: cert))
    let result = try bridge.fetch(
        homeDirectory: URL(fileURLWithPath: args[1]), identity: identity,
        folder: FolderID(rawValue: args[4]), path: RelativePath(rawValue: args[5]),
        expectedVersion: nil, destination: URL(fileURLWithPath: args[6]),
        budget: .default, progress: { _, _ in }, isCancelled: { false })
    let end = footprintMiB()
    print(String(format: "SIMFETCH ok size=%lld footprint=%.1fMiB peak=%.1fMiB", result.size, end.now, end.peak))
} catch {
    print("SIMFETCH error \(error)")
    exit(1)
}
