import Foundation

/// A queue acknowledgement is distinct from a successful operation. Callers
/// must only dismiss an edit form after every exact command has succeeded.
public struct CommandExecutionReport: Sendable {
    public let commandIDs: Set<UUID>
    public let results: [UUID: CoreCommandResult]
    public let outcome: CoreRunOutcome?

    public init(commands: [CoreCommand], results: [UUID: CoreCommandResult], outcome: CoreRunOutcome?) {
        let ids = Set(commands.map(\.id))
        commandIDs = ids
        self.results = results.filter { ids.contains($0.key) && $0.key == $0.value.commandID }
        self.outcome = outcome
    }

    public var succeeded: Bool {
        !commandIDs.isEmpty && results.count == commandIDs.count
            && results.values.allSatisfy { $0.status == .succeeded }
    }

    public var firstUnsuccessfulResult: CoreCommandResult? {
        results.values.filter { $0.status != .succeeded }
            .sorted { $0.commandID.uuidString < $1.commandID.uuidString }.first
    }
}

/// The planner is intentionally independent of peer connection telemetry:
/// disconnected peers need a session in order to reconnect. Paused and
/// explicitly local-only folders do not need automatic network work.
public struct ForegroundFolderSchedule: Sendable {
    private var lastFolderID: FolderID?

    public init() {}

    public mutating func next(in snapshot: CoreSnapshot) -> FolderRecord? {
        let eligible = snapshot.folders.filter {
            !$0.isPaused && $0.deviceIDs?.isEmpty != true
        }.sorted { $0.id.rawValue < $1.id.rawValue }
        guard let first = eligible.first else { return nil }
        let next = eligible.first { $0.id.rawValue > (lastFolderID?.rawValue ?? "") } ?? first
        lastFolderID = next.id
        return next
    }
}
