import Foundation

public enum WorkingSetSignalStoreError: Error, Equatable, Sendable {
    case corruptState
    case unsupportedSchema(Int)
}

/// Durable, path-free intent to notify the replicated File Provider domain.
///
/// The state contains only the greatest snapshot generation that still needs
/// signaling. A sender acknowledges exactly the generation it observed; a
/// newer request committed while the system call was in flight remains
/// pending for the next opportunity.
public struct WorkingSetSignalStore: Sendable {
    private struct State: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int = Self.currentSchemaVersion
        var pendingGeneration: UInt64?
    }

    private let stateURL: URL
    private let lockURL: URL

    public init(url: URL) {
        stateURL = url
        lockURL = url.appendingPathExtension("lock")
    }

    /// Records the greatest requested generation and returns the durable value.
    @discardableResult
    public func request(generation: UInt64) throws -> UInt64 {
        try FileLock.withExclusiveLock(at: lockURL) {
            var state = try loadLocked()
            let requested = max(state.pendingGeneration ?? generation, generation)
            if state.pendingGeneration != requested {
                state.pendingGeneration = requested
                try saveLocked(state)
            }
            return requested
        }
    }

    public func pending() throws -> UInt64? {
        try FileLock.withExclusiveLock(at: lockURL) {
            try loadLocked().pendingGeneration
        }
    }

    /// Clears only a request no newer than the generation actually sent.
    /// Returns the remaining pending generation, if a concurrent/newer request
    /// won the race.
    @discardableResult
    public func acknowledge(upTo generation: UInt64) throws -> UInt64? {
        try FileLock.withExclusiveLock(at: lockURL) {
            var state = try loadLocked()
            guard let pendingGeneration = state.pendingGeneration else { return nil }
            guard pendingGeneration <= generation else { return pendingGeneration }
            state.pendingGeneration = nil
            try saveLocked(state)
            return nil
        }
    }

    private func loadLocked() throws -> State {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return State() }
        let state: State
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        } catch {
            throw WorkingSetSignalStoreError.corruptState
        }
        guard state.schemaVersion == State.currentSchemaVersion else {
            throw WorkingSetSignalStoreError.unsupportedSchema(state.schemaVersion)
        }
        return state
    }

    private func saveLocked(_ state: State) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #if os(iOS)
            let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
        #else
            let writeOptions: Data.WritingOptions = [.atomic]
        #endif
        try encoder.encode(state).write(to: stateURL, options: writeOptions)
        guard chmod(stateURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
