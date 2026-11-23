import Foundation

/// App-side: shows the engine's own downloads in Files.
///
/// Files draws a download ring only for a `fetchContents` in progress: the
/// item properties that would say "downloading" (`isDownloading`,
/// `isDownloaded`, `downloadingError`) are ignored for an
/// NSFileProviderReplicatedExtension (NSFileProviderItem.h, iOS 27.2 SDK), and
/// iOS has no call to report a transfer the system did not ask for. So when
/// the engine starts pulling a file (its first DownloadProgress), this asks
/// the system to download that item now (`request`, a coordinated read). The
/// extension hands the fetch to the App (delegatedToApp), whose request
/// follows the transfer's bytes and completes when the engine finishes the
/// file; Files then has the file and shows the ring while it arrives.
///
/// - Only files of at least `minimumBytes` (a short transfer is over before
///   Files could draw anything), at most `maxConcurrent` at once; the rest
///   are made available offline afterwards by `FilesMaterializer`.
/// - Each file once per transfer: a failed or refused request is not retried
///   until the file finishes and is pulled again.
public actor FilesDownloadMirror {
    public typealias Request = @Sendable (FolderID, ItemIdentifier) async throws -> Void
    public typealias Trace = @Sendable (String) -> Void

    private let store: FilesStore
    private let request: Request
    private let trace: Trace?
    private let maxConcurrent: Int
    private let minimumBytes: Int64
    private var active: [String: Task<Void, Never>] = [:]
    private var tried: Set<String> = []

    public init(store: FilesStore, maxConcurrent: Int = 3, minimumBytes: Int64 = 1 << 20, trace: Trace? = nil,
                request: @escaping Request)
    {
        self.store = store
        self.request = request
        self.trace = trace
        self.maxConcurrent = max(1, maxConcurrent)
        self.minimumBytes = minimumBytes
    }

    public func handle(_ event: EngineEvent) {
        switch event {
        case .downloadProgress(let folder, let path, let done, let total):
            let key = Self.key(folder, path)
            guard total >= minimumBytes, done < total, active[key] == nil, !tried.contains(key),
                  active.count < maxConcurrent,
                  let record = try? store.record(folder: folder, path: path), !record.isDirectory
            else { return }
            tried.insert(key)
            let request = request, trace = trace, id = record.itemID
            active[key] = Task { [weak self] in
                do {
                    try await request(folder, id)
                    trace?("mirrored folder=\(folder.rawValue) id=\(id.rawValue)")
                } catch {
                    trace?("mirror failed folder=\(folder.rawValue) id=\(id.rawValue) error=\(error)")
                }
                await self?.finished(key)
            }
        case .itemFinished(let folder, let path, _):
            tried.remove(Self.key(folder, path))
        default:
            break
        }
    }

    /// Requests still waiting for their transfer (tests, diagnostics).
    public var inFlight: Int { active.count }

    /// Forgets everything (engine stopped). Requests already handed to the
    /// system are not withdrawn: the extension fails them over as it does
    /// for any delegated fetch when the App stops.
    public func stop() {
        active.removeAll()
        tried.removeAll()
    }

    private func finished(_ key: String) {
        active[key] = nil
    }

    private static func key(_ folder: FolderID, _ path: RelativePath) -> String {
        folder.rawValue + "\u{0}" + path.rawValue
    }
}
