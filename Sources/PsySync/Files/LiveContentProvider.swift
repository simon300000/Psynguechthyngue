import Darwin
import Foundation
import os

/// Why the extension could not produce contents. The extension maps these to
/// NSFileProviderError.
public enum FilesContentError: Error, Hashable, Sendable {
    public enum OpenAppReason: String, Sendable {
        /// No reachable peer / deadline (restricted fetch) — "open the app".
        case noPeer
        /// Local index is stale (hash/version mismatch, file vanished upstream).
        case staleIndex
        /// Larger than the restricted-fetch budget.
        case tooLarge
        /// Restricted fetch is unavailable in this build / identity missing.
        case unavailable
        /// App engine owns the lock but did not take the request.
        case appBusy
        /// Too little jetsam headroom left to start the restricted core.
        case lowMemory
        /// No device is reachable now; the download was queued (on-demand
        /// presence rule) and runs as soon as one is ("will download later").
        case queuedNoPeer
    }

    case noSuchItem
    case isDirectory
    /// Excluded by the user's own ignore rules on this device: it would be
    /// written into the folder and never sync.
    case excludedByIgnoreRules
    case openAppRequired(OpenAppReason)
    case cancelled
    case requestFailed(String)
}

/// Supplies the device identity (Keychain, shared access group) to the
/// restricted fetch. Returns nil when no identity exists yet.
public typealias DeviceIdentityProvider = @Sendable () throws -> DeviceIdentity?

/// Extension-side `ContentProviding` (decision tree):
/// localClone → delegatedToApp → restrictedFetch.
public final class LiveContentProvider: ContentProviding, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Delegation: request must reach `accepted` within this time, else
        /// we fall back to the restricted fetch (App is likely suspending).
        public var acceptTimeout: Duration = .seconds(2)
        /// Delegation: longest wait for `completed` without the transfer
        /// moving (a large file that keeps arriving is not cut off).
        public var delegationTimeout: Duration = .seconds(600)
        /// How long to wait for the engine lock before giving up.
        public var lockTimeout: Duration = .seconds(15)
        /// After yielding the lock: how long to wait for the App to hold it.
        public var handOverTimeout: Duration = .seconds(30)
        public var pollInterval: Duration = .milliseconds(500)
        public var fetchBudget: RestrictedFetchBudget = .default
        /// Runs after every restricted fetch (success or failure), on the
        /// blocking thread — e.g. return Go memory to the OS so the
        /// extension's phys_footprint drops back between fetches.
        public var afterFetch: (@Sendable () -> Void)?
        /// Current jetsam headroom in bytes (`os_proc_available_memory()` in
        /// the extension); fits GOMEMLIMIT per fetch. nil / 0 = unknown.
        public var availableMemory: (@Sendable () -> UInt64)?
        /// The user's own rules (IgnoreRulesGenerator.userRules) match this
        /// path. nil = not checked.
        public var isUserIgnored: (@Sendable (RelativePath) -> Bool)?
        public init() {}
    }

    private let layout: AppGroupLayout
    private let store: FilesStore
    private let reader: FolderFilesReader
    private let folder: FolderID
    private let engineLock: any EngineLock
    private let fetchBridge: (any RestrictedFetchBridge)?
    private let identity: DeviceIdentityProvider
    private let temporaryDirectory: URL
    private let configuration: Configuration
    private let containment: PathContainment
    private let gate = AsyncGate()
    private let log = Logger(subsystem: "app.psynguechthyngue.files", category: "content")

    public init(
        layout: AppGroupLayout, store: FilesStore, folder: FolderID, engineLock: any EngineLock,
        fetchBridge: (any RestrictedFetchBridge)?, identity: @escaping DeviceIdentityProvider,
        temporaryDirectory: URL, configuration: Configuration = Configuration()
    ) {
        self.layout = layout
        self.store = store
        self.reader = store.reader(folder: folder)
        self.folder = folder
        self.engineLock = engineLock
        self.fetchBridge = fetchBridge
        self.identity = identity
        self.temporaryDirectory = temporaryDirectory
        self.configuration = configuration
        self.containment = PathContainment(root: layout.managedFolder(folder))
    }

    public func provideContents(for item: ItemIdentifier, requestedVersion: Data?, progress: Progress) async throws
        -> (url: URL, record: FileItemRecord, source: ContentSource)
    {
        guard let record = try reader.item(item) else { throw FilesContentError.noSuchItem }
        guard !record.isDirectory else { throw FilesContentError.isDirectory }
        if let requestedVersion, requestedVersion != record.contentVersion {
            // Not an error: serve the current version; the system
            // updates from the returned item.
            log.info("fetchContents: requested version differs; serving current for \(record.itemID.rawValue, privacy: .public)")
        }
        progress.totalUnitCount = max(record.size, 1)

        let fileURL = try containment.url(for: record.path)
        if !Self.isLocallyAvailable(record, at: fileURL), configuration.isUserIgnored?(record.path) == true {
            throw FilesContentError.excludedByIgnoreRules
        }
        if Self.isLocallyAvailable(record, at: fileURL) {
            let clone = try cloneToTemporary(fileURL)
            progress.completedUnitCount = progress.totalUnitCount
            log.info("fetchContents source=localClone id=\(record.itemID.rawValue, privacy: .public)")
            return (clone, record, .localClone)
        }

        // The App is starting and asked for the lock: hand this to it.
        if engineLock.currentHolder() != .app, yieldMarker.appWantsLock() {
            return try await handOverToApp(record, progress: progress)
        }
        if engineLock.currentHolder() == .app {
            switch try await delegate(record, progress: progress) {
            case .completed(let fresh):
                let url = try containment.url(for: fresh.path)
                guard Self.fileExists(url) else { throw FilesContentError.openAppRequired(.staleIndex) }
                progress.completedUnitCount = progress.totalUnitCount
                log.info("fetchContents source=delegatedToApp id=\(record.itemID.rawValue, privacy: .public)")
                return (try cloneToTemporary(url), fresh, .delegatedToApp)
            case .notAccepted:
                log.info("fetchContents: app did not accept within timeout; trying restricted fetch")
            case .appStopped:
                // The user left the App for Files mid-download: carry on here
                // (the restricted fetch waits for the App to release the lock).
                log.info("fetchContents: app stopped during the download; continuing with restricted fetch")
            }
        }

        let result: (url: URL, record: FileItemRecord, source: ContentSource)
        do {
            result = try await gate.run { try await self.restrictedFetch(record, progress: progress) }
        } catch YieldedToApp.yielded {
            return try await handOverToApp(record, progress: progress)
        }
        log.info("fetchContents source=restrictedFetch id=\(record.itemID.rawValue, privacy: .public)")
        return result
    }

    /// The restricted fetch was cancelled because the App asked for the lock.
    enum YieldedToApp: Error { case yielded }

    private var yieldMarker: EngineYield { EngineYield(lockURL: layout.engineLock) }

    /// Waits for the starting App to hold the lock, then delegates the same
    /// fetch to it: Files sees one download, not a failure and a retry.
    private func handOverToApp(_ record: FileItemRecord, progress: Progress) async throws
        -> (url: URL, record: FileItemRecord, source: ContentSource)
    {
        log.info("fetchContents: handing over to the starting app id=\(record.itemID.rawValue, privacy: .public)")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.handOverTimeout)
        while engineLock.currentHolder() != .app {
            if progress.isCancelled || Task.isCancelled { throw FilesContentError.cancelled }
            guard clock.now < deadline else { throw FilesContentError.openAppRequired(.appBusy) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        switch try await delegate(record, progress: progress) {
        case .completed(let fresh):
            let url = try containment.url(for: fresh.path)
            guard Self.fileExists(url) else { throw FilesContentError.openAppRequired(.staleIndex) }
            progress.completedUnitCount = progress.totalUnitCount
            log.info("fetchContents source=delegatedToApp (after yield) id=\(record.itemID.rawValue, privacy: .public)")
            return (try cloneToTemporary(url), fresh, .delegatedToApp)
        case .notAccepted, .appStopped:
            throw FilesContentError.openAppRequired(.appBusy)
        }
    }

    // MARK: Local

    static func fileExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Local copy is authoritative when the engine reported it present at the
    /// projected version (size check guards against partial files), or when
    /// it is a not-yet-uploaded local write.
    static func isLocallyAvailable(_ record: FileItemRecord, at url: URL) -> Bool {
        guard fileExists(url) else { return false }
        if record.pendingUpload { return true }
        guard record.isLocal else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber)?
            .int64Value
        return size == record.size
    }

    /// APFS clone (copy-on-write) to a fresh temporary URL; falls back to copy.
    func cloneToTemporary(_ source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let destination = temporaryDirectory.appending(path: UUID().uuidString + "-" + source.lastPathComponent)
        if clonefile(source.path(percentEncoded: false), destination.path(percentEncoded: false), 0) != 0 {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }

    // MARK: Delegation (App running)

    enum DelegationOutcome {
        case completed(FileItemRecord)
        case notAccepted
        /// Accepted, then the App engine stopped before the file arrived.
        case appStopped
    }

    private func delegate(_ record: FileItemRecord, progress: Progress) async throws -> DelegationOutcome {
        let request = try store.post(folder, path: record.path, version: record.contentVersion)
        let updates = DarwinNotifier.stream(DarwinNotification.filesRequestUpdated)
        DarwinNotifier.post(DarwinNotification.filesRequestPosted)
        let clock = ContinuousClock()
        let start = clock.now
        var lastMoved = start
        var lastDone: Int64 = 0
        var accepted = false
        defer { _ = updates }
        while true {
            if progress.isCancelled || Task.isCancelled {
                try? store.update(request.id, state: .failed, failureCode: "cancelled")
                throw FilesContentError.cancelled
            }
            if let current = try store.get(request.id) {
                switch current.state {
                case .completed:
                    return .completed(try reader.item(record.itemID) ?? record)
                case .failed:
                    if current.failureCode == ContentRequest.appStoppingCode { return .appStopped }
                    throw Self.mapFailure(current.failureCode)
                case .accepted:
                    accepted = true
                    // Files shows this as the download's progress; never
                    // "done" before the file is actually there.
                    if current.bytesDone > lastDone {
                        lastDone = current.bytesDone
                        lastMoved = clock.now
                        if current.bytesTotal > 0 { progress.totalUnitCount = current.bytesTotal }
                        progress.completedUnitCount = min(current.bytesDone, max(progress.totalUnitCount - 1, 0))
                    }
                case .posted:
                    break
                }
            }
            let elapsed = start.duration(to: clock.now)
            if !accepted && elapsed >= configuration.acceptTimeout {
                try? store.update(request.id, state: .failed, failureCode: "not_accepted")
                return .notAccepted
            }
            if lastMoved.duration(to: clock.now) >= configuration.delegationTimeout {
                try? store.update(request.id, state: .failed, failureCode: "deadline")
                throw FilesContentError.openAppRequired(.noPeer)
            }
            // Wake on notification or poll interval, whichever first.
            await Self.waitForSignal(updates, timeout: configuration.pollInterval)
        }
    }

    private static func waitForSignal(_ stream: AsyncStream<Void>, timeout: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    static func mapFailure(_ code: String?) -> FilesContentError {
        switch code {
        case "cancelled": return .cancelled
        case BridgeContract.Code.tooLarge.rawValue: return .openAppRequired(.tooLarge)
        case BridgeContract.Code.noPeer.rawValue, BridgeContract.Code.deadline.rawValue: return .openAppRequired(.noPeer)
        case ContentRequest.queuedNoPeerCode: return .openAppRequired(.queuedNoPeer)
        case BridgeContract.Code.hashMismatch.rawValue, BridgeContract.Code.versionMismatch.rawValue,
            BridgeContract.Code.fileNotFound.rawValue:
            return .openAppRequired(.staleIndex)
        default: return .requestFailed(code ?? "unknown")
        }
    }

    // MARK: Restricted fetch (App not running)

    private func restrictedFetch(_ record: FileItemRecord, progress: Progress) async throws
        -> (url: URL, record: FileItemRecord, source: ContentSource)
    {
        // Another queued fetch may already have produced this file.
        if let fresh = try reader.item(record.itemID), let url = try? containment.url(for: fresh.path),
            Self.isLocallyAvailable(fresh, at: url)
        {
            return (try cloneToTemporary(url), fresh, .localClone)
        }
        guard let fetchBridge else { throw FilesContentError.openAppRequired(.unavailable) }
        guard record.size <= configuration.fetchBudget.maxFileBytes else {
            throw FilesContentError.openAppRequired(.tooLarge)
        }
        guard let identity = try identity() else { throw FilesContentError.openAppRequired(.unavailable) }

        // Queued behind a fetch that yielded: the App is taking over.
        if yieldMarker.appWantsLock() { throw YieldedToApp.yielded }
        if engineLock.currentHolder() == .app {
            DarwinNotifier.post(DarwinNotification.engineYieldRequested)
        }
        guard let lease = await engineLock.acquire(owner: .fileProviderExtension, timeout: configuration.lockTimeout)
        else {
            throw FilesContentError.openAppRequired(.appBusy)
        }
        defer { lease.release() }

        let cancelFlag = CancelFlag()
        let yieldObservation = DarwinNotifier.observe(DarwinNotification.engineYieldRequested) { cancelFlag.set() }
        defer { yieldObservation.cancel() }

        try FileManager.default.createDirectory(at: layout.staging, withIntermediateDirectories: true)
        let staged = layout.staging.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        var available = configuration.availableMemory?() ?? 0
        if configuration.fetchBudget.fitted(availableBytes: available) == nil, let release = configuration.afterFetch {
            // The previous fetch returns its Go memory asynchronously (afterFetch
            // runs detached); release it now and measure again before refusing.
            try? await BlockingThread.run { release() }
            available = configuration.availableMemory?() ?? 0
        }
        guard let budget = configuration.fetchBudget.fitted(availableBytes: available) else {
            log.error("restricted fetch refused: available \(available >> 20, privacy: .public) MiB")
            throw FilesContentError.openAppRequired(.lowMemory)
        }
        log.info("restricted fetch GOMEMLIMIT \(budget.memory.limitMiB, privacy: .public) MiB (available \(available >> 20, privacy: .public) MiB)")
        let folder = self.folder
        let home = layout.engineHost
        let result: RestrictedFetchResult
        let afterFetch = configuration.afterFetch
        defer { if let afterFetch { Task.detached { _ = try? await BlockingThread.run { afterFetch() } } } }
        do {
            result = try await BlockingThread.run {
                try fetchBridge.fetch(
                    homeDirectory: home, identity: identity, folder: folder, path: record.path, expectedVersion: nil,
                    destination: staged, budget: budget,
                    progress: { done, total in
                        if total > 0 { progress.totalUnitCount = total }
                        progress.completedUnitCount = done
                    },
                    isCancelled: { progress.isCancelled || cancelFlag.isSet })
            }
        } catch {
            if cancelFlag.isSet && !progress.isCancelled {
                log.info("restricted fetch yielded to the app")
                throw YieldedToApp.yielded
            }
            log.error("restricted fetch failed: \(String(describing: error), privacy: .public)")
            let mapped = Self.mapBridgeError(error, cancelled: progress.isCancelled || cancelFlag.isSet)
            if mapped == .openAppRequired(.noPeer), try queueForLater(record) {
                throw FilesContentError.openAppRequired(.queuedNoPeer)
            }
            throw mapped
        }

        // Commit order (record-fetched-file), all under the lock:
        // 1 fetch (done) → 2 rename into folder → 3 recordFetchedFile →
        // 4 `.stignore` `!/path` (on-demand) → 5 journal → (6 unlock in defer).
        let destination = try containment.url(for: record.path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if rename(result.stagedFile.path(percentEncoded: false), destination.path(percentEncoded: false)) != 0 {
            throw FilesContentError.requestFailed("rename errno \(errno)")
        }
        do {
            let version = result.version
            try await BlockingThread.run {
                try fetchBridge.recordFetchedFile(
                    homeDirectory: home, identity: identity, folder: folder, path: record.path, version: version)
            }
        } catch {
            // Fallback = previous behaviour: the App's scan may mint an extra
            // metadata-only version. Harmless, so keep the fetched file.
            log.error("recordFetchedFile failed: \(String(describing: error), privacy: .public)")
        }
        if try store.folderInfo(folder)?.contentMode == .onDemand {
            try Self.addPresentRule(record.path, folderRoot: layout.managedFolder(folder))
        }
        try store.markLocal(record.itemID, isLocal: true)
        try store.append(folder, kind: .modified, path: record.path, previousPath: nil)
        DarwinNotifier.post(DarwinNotification.filesRequestPosted)
        var fresh = try reader.item(record.itemID) ?? record
        fresh.isLocal = true
        return (try cloneToTemporary(destination), fresh, .restrictedFetch)
    }

    /// The user asked for this file and no device is reachable: keep the
    /// request (a presence intent the App turns into a `!/path` rule) so the
    /// engine downloads it once a device is back, and Files gets it through
    /// FilesMaterializer. Only on-demand folders need it ("everything"
    /// downloads anyway). Returns whether it was queued.
    private func queueForLater(_ record: FileItemRecord) throws -> Bool {
        guard try store.folderInfo(folder)?.contentMode == .onDemand else { return false }
        try store.requestPresence(folder, path: record.path, present: true)
        DarwinNotifier.post(DarwinNotification.filesRequestPosted)
        return true
    }

    /// Adds `!/path` to a managed on-demand `.stignore` (same generator the
    /// engine uses; the engine reads rules back from upstream, so they stay
    /// consistent). Unmanaged/user-written files are left alone.
    static func addPresentRule(_ path: RelativePath, folderRoot: URL) throws {
        let url = folderRoot.appending(path: ".stignore")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard IgnoreRulesGenerator.isManaged(lines) else { return }
        var present = IgnoreRulesGenerator.presentPaths(from: lines)
        guard present.insert(path).inserted else { return }
        try Data(IgnoreRulesGenerator.fileContents(present: present).utf8).write(to: url, options: .atomic)
    }

    static func mapBridgeError(_ error: Error, cancelled: Bool) -> FilesContentError {
        if cancelled { return .cancelled }
        if let content = error as? FilesContentError { return content }
        var code: BridgeContract.Code?
        if case EngineError.bridge(let raw, _) = error {
            code = BridgeContract.Code(rawValue: raw)
        } else {
            // PsyBridgeError describes itself as "psy:<code>: <detail>"; raw
            // gomobile NSErrors carry it in localizedDescription.
            code = BridgeContract.parse(String(describing: error)).code
                ?? BridgeContract.parse((error as NSError).localizedDescription).code
        }
        switch code {
        case .cancelled: return .cancelled
        case .tooLarge: return .openAppRequired(.tooLarge)
        case .hashMismatch, .versionMismatch, .fileNotFound: return .openAppRequired(.staleIndex)
        case .noPeer, .deadline: return .openAppRequired(.noPeer)
        default: return .openAppRequired(.noPeer)
        }
    }
}

extension AppGroupLayout {
    /// Alias used by the restricted fetch (Syncthing home).
    var engineHost: URL { engineHome }
}

// MARK: - Helpers

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// FIFO async mutex: restricted fetches run one at a time per process.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await enter()
        defer { leave() }
        return try await body()
    }

    private func enter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if busy {
                    waiters.append(continuation)
                    return false
                }
                busy = true
                return true
            }
            if resumeNow { continuation.resume() }
        }
    }

    private func leave() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                busy = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

/// Runs blocking bridge calls on a dedicated thread, never on the
/// cooperative pool.
public enum BlockingThread {
    public static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try body() })
            }
            thread.name = "psy.blocking"
            thread.stackSize = 1 << 20
            thread.start()
        }
    }
}
