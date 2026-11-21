import Foundation
import OSLog
import PsySync

/// Lifecycle trace used to verify the background drain sequence
/// (beginBackgroundTask → stop → lock released → endBackgroundTask).
/// Entries go to the unified log (`subsystem: app.psynguechthyngue`, category
/// `lifecycle`) and to an in-memory ring for tests and diagnostics export.
final class LifecycleLog: @unchecked Sendable {
    static let shared = LifecycleLog()

    struct Entry: Sendable {
        let date: Date
        let stage: String
        let detail: String
    }

    private let logger = Logger(subsystem: "app.psynguechthyngue", category: "lifecycle")
    #if DEBUG
    /// Device acceptance runs: `<AppGroup>/Diagnostics/app.log`.
    private let file = DiagnosticsFileLog.make(name: "app")
    #endif
    private let lock = NSLock()
    private var ring: [Entry] = []

    func record(_ stage: String, _ detail: String = "") {
        let entry = Entry(date: Date(), stage: stage, detail: detail)
        lock.lock()
        ring.append(entry)
        if ring.count > 200 { ring.removeFirst(ring.count - 200) }
        lock.unlock()
        logger.notice("[lifecycle] \(stage, privacy: .public) \(detail, privacy: .public)")
        #if DEBUG
        file?.append("\(stage) \(detail)")
        #endif
    }

    var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return ring
    }
}
