import Foundation

/// Append-only text log in `<AppGroup>/Library/Caches/Diagnostics/<name>.log` (devicectl can only read `Library/` in a group container), for device
/// acceptance runs where unified-log capture over the cable is unreliable
/// (xctrace's os_log instrument drops most lines from already-running
/// processes). Callers gate it with `#if DEBUG`. Read back with
/// `xcrun devicectl device copy from --domain-type appGroupDataContainer`.
/// Never write secrets here.
public final class DiagnosticsFileLog: @unchecked Sendable {
    public static let maxBytes = 2 * 1024 * 1024

    private let url: URL
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(layout: AppGroupLayout, name: String) {
        url = layout.root.appending(path: "Library/Caches/Diagnostics/\(name).log", directoryHint: .notDirectory)
    }

    /// Resolves the App Group from the main bundle; nil when unavailable.
    public static func make(name: String) -> DiagnosticsFileLog? {
        (try? AppGroupResolver.layout()).map { DiagnosticsFileLog(layout: $0, name: name) }
    }

    public func append(_ message: String) {
        let line = "\(formatter.string(from: Date())) pid=\(getpid()) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let path = url.path(percentEncoded: false)
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        if let end = try? handle.seekToEnd(), end > Self.maxBytes {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
