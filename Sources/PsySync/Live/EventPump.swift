import Foundation

/// Fan-out of `EngineEvent`s to any number of `AsyncStream` subscribers.
/// Each subscriber sees events from subscription time on (hot stream).
public final class EventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    public init() {}

    public func stream(bufferingNewest limit: Int = 512) -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .bufferingNewest(limit))
        let id = UUID()
        lock.withLock { continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    public func yield(_ event: EngineEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        for c in targets { c.yield(event) }
    }

    var subscriberCount: Int { lock.withLock { continuations.count } }
}

/// What the engine should do in response to one upstream event.
enum EventAction: Hashable, Sendable {
    case emit(EngineEvent)
    case refreshPendingDevices
    case refreshPendingFolders
    case refreshFolder(FolderID)
    case refreshAllFolders
    /// Events were lost (upstream's buffered subscription overflowed or
    /// dropped some): refresh everything derived from events.
    case resync
}

/// Pure translation of upstream `/rest/events` entries (DESIGN.md §3.2).
enum EventTranslator {
    static let mask = [
        "DeviceConnected", "DeviceDisconnected", "DevicePaused", "DeviceResumed",
        "PendingDevicesChanged", "PendingFoldersChanged",
        "StateChanged", "FolderSummary", "FolderCompletion", "FolderErrors", "FolderPaused", "FolderResumed",
        "ConfigSaved", "LocalIndexUpdated", "RemoteIndexUpdated",
        "ItemStarted", "ItemFinished", "DownloadProgress",
    ]

    /// Upstream numbers events per subscription (one per mask) without gaps
    /// and keeps only the newest N in a ring buffer; a poll that falls behind
    /// gets a batch whose first id is past `since + 1`. `since == 0` is the
    /// first poll (nothing to miss yet).
    static func missedEvents(since: Int, ids: [Int]) -> Bool {
        guard since > 0, let first = ids.filter({ $0 > since }).min() else { return false }
        return first > since + 1
    }

    static func translate(_ e: RawEventDTO) -> [EventAction] {
        let d = e.data
        func folder(_ key: String = "folder") -> FolderID? { d?[key]?.string.map(FolderID.init(rawValue:)) }
        switch e.type {
        case "DeviceConnected":
            guard let id = d?["id"]?.string else { return [] }
            let conn = DeviceConnection(
                deviceID: DeviceID(rawValue: id),
                state: .connected,
                transport: d?["type"]?.string,
                address: d?["addr"]?.string,
                clientVersion: d?["clientVersion"]?.string,
                lastSeen: e.time.flatMap(SyncthingDate.parse)
            )
            return [.emit(.deviceConnectionChanged(conn)), .refreshAllFolders]
        case "DeviceDisconnected":
            guard let id = d?["id"]?.string else { return [] }
            let conn = DeviceConnection(deviceID: DeviceID(rawValue: id), state: .disconnected, lastSeen: e.time.flatMap(SyncthingDate.parse))
            return [.emit(.deviceConnectionChanged(conn)), .refreshAllFolders]
        case "DevicePaused":
            guard let id = d?["device"]?.string else { return [] }
            return [.emit(.deviceConnectionChanged(DeviceConnection(deviceID: DeviceID(rawValue: id), state: .paused))), .refreshAllFolders]
        case "DeviceResumed":
            guard let id = d?["device"]?.string else { return [] }
            return [.emit(.deviceConnectionChanged(DeviceConnection(deviceID: DeviceID(rawValue: id), state: .disconnected))), .refreshAllFolders]
        case "PendingDevicesChanged":
            return [.refreshPendingDevices]
        case "PendingFoldersChanged":
            return [.refreshPendingFolders]
        case "StateChanged", "FolderSummary", "FolderErrors", "FolderPaused", "FolderResumed":
            return folder().map { [.refreshFolder($0)] } ?? []
        case "FolderCompletion":
            return folder().map { [.refreshFolder($0)] } ?? []
        case "ConfigSaved":
            return [.emit(.configurationChanged), .refreshAllFolders]
        case "LocalIndexUpdated":
            guard let f = folder() else { return [] }
            let names = d?["filenames"]?.array?.compactMap(\.string).map(RelativePath.init(rawValue:))
            return [.emit(.indexChanged(folderID: f, paths: names))]
        case "RemoteIndexUpdated":
            guard let f = folder() else { return [] }
            return [.emit(.indexChanged(folderID: f, paths: nil))]
        case "ItemStarted":
            guard let f = folder(), let item = d?["item"]?.string else { return [] }
            return [.emit(.itemStarted(folderID: f, path: RelativePath(rawValue: item)))]
        case "ItemFinished":
            guard let f = folder(), let item = d?["item"]?.string else { return [] }
            return [.emit(.itemFinished(folderID: f, path: RelativePath(rawValue: item), error: d?["error"]?.string))]
        case "DownloadProgress":
            // {"<folder>": {"<file>": {"bytesDone":…, "bytesTotal":…, …}}}
            guard let folders = d?.object else { return [] }
            var out: [EventAction] = []
            for (f, files) in folders.sorted(by: { $0.key < $1.key }) {
                for (file, p) in (files.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                    out.append(.emit(.downloadProgress(
                        folderID: FolderID(rawValue: f),
                        path: RelativePath(rawValue: file),
                        bytesDone: p["bytesDone"]?.int64 ?? 0,
                        bytesTotal: p["bytesTotal"]?.int64 ?? 0
                    )))
                }
            }
            return out
        default:
            return []
        }
    }
}

/// Long-polls `/rest/events` and hands translated actions to `handle`.
/// Runs as an unstructured task; `cancel()` stops it promptly (the in-flight
/// request is cancelled with the task).
final class EventPump: Sendable {
    private let task: Task<Void, Never>

    /// - Parameters:
    ///   - onUnreachable: called once after `failureThreshold` consecutive
    ///     transport failures (engine likely exited).
    init(
        client: SyncthingRESTClient,
        pollTimeout: Int = 50,
        failureThreshold: Int = 6,
        handle: @escaping @Sendable ([EventAction]) async -> Void,
        onUnreachable: @escaping @Sendable (EngineError) async -> Void
    ) {
        task = Task.detached(priority: .utility) {
            var since = 0
            var failures = 0
            while !Task.isCancelled {
                do {
                    let events = try await client.events(since: since, mask: EventTranslator.mask, timeout: pollTimeout)
                    failures = 0
                    if EventTranslator.missedEvents(since: since, ids: events.map(\.id)) {
                        await handle([.resync])
                    }
                    for e in events.sorted(by: { $0.id < $1.id }) where e.id > since {
                        since = e.id
                        PerfCounters.hit("upstream \(e.type)")
                        let actions = EventTranslator.translate(e)
                        if !actions.isEmpty { await handle(actions) }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    if failures == failureThreshold {
                        await onUnreachable(error as? EngineError ?? .rest(status: 0, body: "\(error)"))
                    }
                    try? await Task.sleep(for: .milliseconds(min(5000, 250 * failures)))
                }
            }
        }
    }

    func cancel() { task.cancel() }
}
