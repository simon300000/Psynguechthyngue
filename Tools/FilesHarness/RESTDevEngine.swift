import Foundation
import PsySync
import os

/// DEV/TEST ONLY. A tiny `SyncEngine` over the REST API of an *external*
/// Syncthing process (the "phone-side" instance started by
/// `Tools/FilesHarness/e2e.sh`), whose folder path is this simulator's App
/// Group `Folders/<id>/`. It stands in for `LiveSyncEngine` so the
/// Files integration (projector, request server, extension) can be exercised
/// end to end before the bridge exists. Not shipped.
///
/// globalIndex is synthesised from `/rest/db/browse` + `/rest/db/file`
/// (fine for test folders of a few hundred items; production uses the
/// bridge index stream).
final class RESTDevEngine: SyncEngine, @unchecked Sendable {
    let baseURL: URL
    private let apiKey: String
    private let layout: AppGroupLayout
    private let session: URLSession
    private let log = Logger(subsystem: FilesLog.subsystem, category: "harness-engine")
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    private var pump: Task<Void, Never>?

    init(baseURL: URL, apiKey: String, layout: AppGroupLayout) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.layout = layout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 70
        session = URLSession(configuration: config)
    }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw EngineError.rest(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    private func json(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await request(method, path, query: query, body: body), options: [.fragmentsAllowed])
    }

    // MARK: Lifecycle / events

    func start(context: EngineRunContext) async throws {
        guard pump == nil else { return }
        pump = Task { [weak self] in await self?.eventLoop() }
    }

    func stop(deadline: Duration) async throws {
        pump?.cancel()
        pump = nil
    }

    var state: EngineState { get async { pump == nil ? .stopped : .running(since: Date()) } }

    func events() -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    private func emit(_ event: EngineEvent) {
        for c in lock.withLock({ Array(continuations.values) }) { c.yield(event) }
    }

    private func eventLoop() async {
        // Event ids are per subscription (per `events=` mask): always use the
        // same mask. The first masked request creates the subscription, so no
        // history is replayed.
        var since = 0
        while !Task.isCancelled {
            do {
                let events = try await json(
                    "GET", "rest/events",
                    query: ["since": String(since), "timeout": "30",
                            "events": "LocalIndexUpdated,RemoteIndexUpdated,ItemFinished,ConfigSaved"]) as? [[String: Any]] ?? []
                for event in events {
                    since = max(since, event["id"] as? Int ?? since)
                    let data = event["data"] as? [String: Any] ?? [:]
                    let folder = FolderID(rawValue: data["folder"] as? String ?? "")
                    switch event["type"] as? String {
                    case "LocalIndexUpdated", "RemoteIndexUpdated":
                        emit(.indexChanged(folderID: folder, paths: nil))
                    case "ItemFinished":
                        let item = RelativePath(rawValue: data["item"] as? String ?? "")
                        let error = data["error"] as? String
                        log.info("ItemFinished \(item.rawValue, privacy: .public) error=\(error ?? "-", privacy: .public)")
                        emit(.itemFinished(folderID: folder, path: item, error: error))
                    case "ConfigSaved":
                        emit(.configurationChanged)
                    default: break
                    }
                }
            } catch {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Folders

    func folders() async throws -> [Folder] {
        let list = try await json("GET", "rest/config/folders") as? [[String: Any]] ?? []
        let root = layout.foldersRoot.resolvingSymlinksInPath().path(percentEncoded: false)
        return list.compactMap { f in
            guard let id = f["id"] as? String, let path = f["path"] as? String else { return nil }
            let resolved = URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)
            guard resolved.hasPrefix(root) else { return nil }
            let ignores = (try? String(contentsOf: URL(filePath: path).appending(path: ".stignore"), encoding: .utf8)) ?? ""
            return Folder(
                id: FolderID(rawValue: id), label: f["label"] as? String ?? id,
                type: FolderType(rawValue: f["type"] as? String ?? "") ?? .sendReceive, location: .managed,
                contentMode: ignores.contains("Psynguechthyngue managed") ? .onDemand : .everything,
                paused: f["paused"] as? Bool ?? false)
        }
    }

    func scan(_ folder: FolderID, paths: [RelativePath]?) async throws {
        if let paths, !paths.isEmpty {
            for path in paths {
                _ = try await request("POST", "rest/db/scan", query: ["folder": folder.rawValue, "sub": path.rawValue])
            }
        } else {
            _ = try await request("POST", "rest/db/scan", query: ["folder": folder.rawValue])
        }
        log.info("scan \(folder.rawValue, privacy: .public) paths=\(paths?.count ?? -1)")
    }

    func prioritize(_ folder: FolderID, path: RelativePath) async throws {
        _ = try? await request("POST", "rest/db/prio", query: ["folder": folder.rawValue, "file": path.rawValue])
    }

    /// Minimal version of generated rules: `!/path` lines before the trailing `*`.
    func setLocalPresence(_ folder: FolderID, paths: [RelativePath], present: Bool) async throws {
        let current = try await json("GET", "rest/db/ignores", query: ["folder": folder.rawValue]) as? [String: Any]
        var lines = current?["ignore"] as? [String] ?? []
        guard lines.contains(where: { $0.contains("Psynguechthyngue managed") }) else { return }
        let rules = Set(paths.map { "!/" + $0.rawValue })
        lines.removeAll { rules.contains($0) }
        if present {
            let star = lines.lastIndex(of: "*") ?? lines.endIndex
            lines.insert(contentsOf: rules.sorted(), at: star)
        }
        let body = try JSONSerialization.data(withJSONObject: ["ignore": lines])
        _ = try await request("POST", "rest/db/ignores", query: ["folder": folder.rawValue], body: body)
        log.info("ignores \(folder.rawValue, privacy: .public) present=\(present) n=\(paths.count)")
    }

    func globalIndex(_ folder: FolderID, pageSize: Int) -> AsyncThrowingStream<[GlobalIndexEntry], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let tree = try await self.json("GET", "rest/db/browse", query: ["folder": folder.rawValue, "levels": "-1"])
                    var names: [String] = []
                    func walk(_ nodes: [[String: Any]], prefix: String) {
                        for node in nodes {
                            let name = prefix + (node["name"] as? String ?? "")
                            names.append(name)
                            if let children = node["children"] as? [[String: Any]] { walk(children, prefix: name + "/") }
                        }
                    }
                    walk(tree as? [[String: Any]] ?? [], prefix: "")
                    var page: [GlobalIndexEntry] = []
                    for name in names {
                        if let entry = try await self.entry(folder, name) { page.append(entry) }
                        if page.count >= pageSize {
                            continuation.yield(page)
                            page = []
                        }
                    }
                    if !page.isEmpty { continuation.yield(page) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func entry(_ folder: FolderID, _ name: String) async throws -> GlobalIndexEntry? {
        let info = try await json("GET", "rest/db/file", query: ["folder": folder.rawValue, "file": name]) as? [String: Any]
        guard let global = info?["global"] as? [String: Any] else { return nil }
        let local = info?["local"] as? [String: Any]
        let version = (global["version"] as? [String] ?? []).joined(separator: ",")
        let type: GlobalIndexEntry.EntryType =
            switch global["type"] as? String {
            case "FILE_INFO_TYPE_DIRECTORY": .directory
            case "FILE_INFO_TYPE_SYMLINK": .symlink
            default: .file
            }
        var modifiedString = global["modified"] as? String ?? ""
        // Trim nanoseconds to milliseconds for ISO8601DateFormatter.
        if let dot = modifiedString.firstIndex(of: "."), let tz = modifiedString[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = modifiedString[modifiedString.index(after: dot)..<tz]
            modifiedString = String(modifiedString[..<dot]) + "." + fraction.prefix(3) + modifiedString[tz...]
        }
        let localVersion = (local?["version"] as? [String] ?? []).joined(separator: ",")
        let localPresent = local != nil && !(local?["ignored"] as? Bool ?? false) && !(local?["invalid"] as? Bool ?? false)
            && !(local?["deleted"] as? Bool ?? false) && localVersion == version
        return GlobalIndexEntry(
            name: RelativePath(rawValue: name), type: type, size: (global["size"] as? NSNumber)?.int64Value ?? 0,
            modified: Self.dateFormatter.date(from: modifiedString) ?? Date(timeIntervalSince1970: 0),
            deleted: global["deleted"] as? Bool ?? false, invalid: global["invalid"] as? Bool ?? false,
            sequence: (global["sequence"] as? NSNumber)?.int64Value ?? 0, version: version,
            blocksHash: global["blocksHash"] as? String ?? "", localPresent: localPresent)
    }

    // MARK: Unused by the Files harness

    func snapshot() async throws -> EngineStatus { throw EngineError.notRunning }
    var localDeviceID: DeviceID? { get async { nil } }
    func devices() async throws -> [Device] { [] }
    func connections() async throws -> [DeviceConnection] { [] }
    func addDevice(_ device: Device) async throws {}
    func updateDevice(_ device: Device) async throws {}
    func removeDevice(_ id: DeviceID) async throws {}
    func pendingDevices() async throws -> [PendingDevice] { [] }
    func dismissPendingDevice(_ id: DeviceID) async throws {}
    func folderStatus(_ id: FolderID) async throws -> FolderStatus { throw EngineError.notRunning }
    func addFolder(_ folder: Folder) async throws {}
    func updateFolder(_ folder: Folder) async throws {}
    func removeFolder(_ id: FolderID, deleteLocalFiles: Bool) async throws {}
    func pendingFolders() async throws -> [PendingFolder] { [] }
    func acceptPendingFolder(_ pending: PendingFolder, as folder: Folder) async throws {}
    func dismissPendingFolder(_ pending: PendingFolder) async throws {}
    func apply(_ decision: PolicyDecision) async throws {}
}
