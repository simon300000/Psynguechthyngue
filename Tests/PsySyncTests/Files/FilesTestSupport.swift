import Foundation
@testable import PsySync

/// Minimal scriptable SyncEngine for Files tests (independent of WP-D's FakeSyncEngine).
final class FilesFakeEngine: SyncEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var index: [FolderID: [GlobalIndexEntry]] = [:]
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    private(set) var calls: [String] = []
    /// Called when prioritize() is invoked (simulate a pull).
    var onPrioritize: (@Sendable (FolderID, RelativePath) -> Void)?
    var failScan = false
    /// When set, `globalIndex` yields one page per delay from a producer task
    /// (like LiveSyncEngine), so a pass can be interrupted mid-stream.
    var pageDelay: Duration?
    /// Pages delivered by `globalIndex` (tests wait on it).
    private(set) var pagesServed = 0

    func setIndex(_ folder: FolderID, _ entries: [GlobalIndexEntry]) { lock.withLock { index[folder] = entries } }
    func record(_ call: String) { lock.withLock { calls.append(call) } }
    var recordedCalls: [String] { lock.withLock { calls } }

    func emit(_ event: EngineEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        for c in targets { c.yield(event) }
    }

    func start(context: EngineRunContext) async throws {}
    func stop(deadline: Duration) async throws {}
    var state: EngineState { get async { .running(since: Date()) } }
    func events() -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) } }
        }
    }
    func snapshot() async throws -> EngineStatus { throw EngineError.notRunning }
    var localDeviceID: DeviceID? { get async { nil } }
    func devices() async throws -> [Device] { [] }
    func connections() async throws -> [DeviceConnection] { [] }
    func addDevice(_ device: Device) async throws {}
    func updateDevice(_ device: Device) async throws {}
    func removeDevice(_ id: DeviceID) async throws {}
    func pendingDevices() async throws -> [PendingDevice] { [] }
    func dismissPendingDevice(_ id: DeviceID) async throws {}
    func folders() async throws -> [Folder] { [] }
    func folderStatus(_ id: FolderID) async throws -> FolderStatus { throw EngineError.notRunning }
    func addFolder(_ folder: Folder) async throws {}
    func updateFolder(_ folder: Folder) async throws {}
    func removeFolder(_ id: FolderID, deleteLocalFiles: Bool) async throws {}
    func pendingFolders() async throws -> [PendingFolder] { [] }
    func acceptPendingFolder(_ pending: PendingFolder, as folder: Folder) async throws {}
    func dismissPendingFolder(_ pending: PendingFolder) async throws {}
    func scan(_ folder: FolderID, paths: [RelativePath]?) async throws {
        if failScan { throw EngineError.notRunning }
        record("scan \(folder.rawValue) \((paths ?? []).map(\.rawValue).joined(separator: ","))")
    }
    func prioritize(_ folder: FolderID, path: RelativePath) async throws {
        record("prio \(folder.rawValue) \(path.rawValue)")
        onPrioritize?(folder, path)
    }
    func setLocalPresence(_ folder: FolderID, paths: [RelativePath], present: Bool) async throws {
        record("presence \(present) \(paths.map(\.rawValue).joined(separator: ","))")
    }
    func apply(_ decision: PolicyDecision) async throws {}
    func globalIndex(_ folder: FolderID, pageSize: Int) -> AsyncThrowingStream<[GlobalIndexEntry], Error> {
        let entries = lock.withLock { index[folder] ?? [] }
        if let delay = lock.withLock({ pageDelay }) {
            let (stream, continuation) = AsyncThrowingStream<[GlobalIndexEntry], Error>.makeStream()
            let task = Task { [self] in
                var start = 0
                while start < entries.count {
                    if start > 0 { try? await Task.sleep(for: delay) }
                    if Task.isCancelled { return continuation.finish(throwing: CancellationError()) }
                    continuation.yield(Array(entries[start..<min(start + pageSize, entries.count)]))
                    lock.withLock { pagesServed += 1 }
                    start += pageSize
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        }
        return AsyncThrowingStream { continuation in
            var start = 0
            while start < entries.count {
                continuation.yield(Array(entries[start..<min(start + pageSize, entries.count)]))
                start += pageSize
            }
            continuation.finish()
        }
    }
}

enum FilesFixtures {
    static func tempDir(_ name: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "psy-files-tests/\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func file(_ path: String, size: Int64 = 10, version: String = "v1", blocks: String? = nil,
                     local: Bool = true, deleted: Bool = false, sequence: Int64 = 1) -> GlobalIndexEntry
    {
        GlobalIndexEntry(
            name: RelativePath(rawValue: path), type: .file, size: size, modified: Date(timeIntervalSince1970: 1_700_000_000),
            deleted: deleted, invalid: false, sequence: sequence, version: version,
            blocksHash: blocks ?? Data((path + version).utf8).base64EncodedString(), localPresent: local)
    }

    static func dir(_ path: String, version: String = "d1") -> GlobalIndexEntry {
        GlobalIndexEntry(
            name: RelativePath(rawValue: path), type: .directory, size: 128, modified: Date(timeIntervalSince1970: 1_700_000_000),
            deleted: false, invalid: false, sequence: 1, version: version, blocksHash: "", localPresent: true)
    }

    static func store(_ dir: URL, folder: FolderID = FolderID(rawValue: "f1"), mode: ContentMode = .everything) throws -> FilesStore {
        let store = try FilesStore(url: dir.appending(path: "Files/files.sqlite"))
        try store.upsertFolder(FilesFolderInfo(folderID: folder, label: "Folder", isReadOnly: false, contentMode: mode))
        return store
    }
}

func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try await condition()
}
