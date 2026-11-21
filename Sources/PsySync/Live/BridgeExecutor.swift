import Foundation

/// Runs blocking bridge (gomobile) and Keychain calls on a dedicated serial
/// GCD queue and resumes the caller via a continuation, so the Swift
/// cooperative thread pool is never blocked (DESIGN.md §4.3, AUDIT P1).
public final class BridgeExecutor: Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()

    public init(label: String = "app.psynguechthyngue.bridge") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        queue.setSpecific(key: key, value: 1)
    }

    public func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    /// True when called on this executor's queue (used by assertions in tests).
    public func isCurrent() -> Bool {
        DispatchQueue.getSpecific(key: key) == 1
    }
}

/// App-only folder attributes and policy bookkeeping that Syncthing's
/// config.xml cannot hold. Stored next to config.xml in the engine home.
struct LiveEngineAppState: Codable, Hashable, Sendable {
    struct FolderAttributes: Codable, Hashable, Sendable {
        var contentMode: ContentMode
        var bookmark: Data?
        var displayPath: String?
    }

    var folders: [String: FolderAttributes] = [:]
    /// Devices *we* paused for a policy hold (so resume never un-pauses a
    /// device the user paused). Persisted for crash recovery.
    var policyPausedDevices: Set<String> = []
    var decision: PolicyDecision = .run
    /// Sync listen port chosen instead of 22000 (ListenAddressPlanner); nil = default.
    var listenPort: Int?
    /// Options overridden by reduced-load mode, restored when it ends.
    var savedLoadOptions: SavedLoadOptions?

    struct SavedLoadOptions: Codable, Hashable, Sendable {
        var maxFolderConcurrency: Int
        var limitBandwidthInLan: Bool
    }

    static let fileName = "psy-app-state.json"

    static func load(from home: URL) -> LiveEngineAppState {
        let url = home.appending(path: fileName)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(LiveEngineAppState.self, from: data) else { return .init() }
        return state
    }

    func save(to home: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: home.appending(path: Self.fileName), options: .atomic)
    }
}
