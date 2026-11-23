import Foundation
import PsySync

/// Implements `FilesLocationStatusProviding` from the real domain state.
/// `.disabled` when any managed folder's domain is user-disabled (the default
/// on Mac / Designed for iPad), `.enabled` when all
/// are enabled, `.unknown` when there is no managed folder or no domain yet.
@MainActor
final class FilesLocationStatusProvider: FilesLocationStatusProviding {
    private let files: FilesIntegration

    init(files: FilesIntegration) { self.files = files }

    func currentState() async -> FilesLocationState {
        let statuses = await files.refreshDomainStatuses()
        return Self.reduce(Array(statuses.values))
    }

    func notYetInFiles(_ folder: FolderID) async -> Int { files.notYetInFiles(folder) }

    nonisolated static func reduce(_ statuses: [FilesDomainStatus]) -> FilesLocationState {
        if statuses.contains(.disabledByUser) { return .disabled }
        if !statuses.isEmpty, statuses.allSatisfy({ $0 == .enabled }) { return .enabled }
        return .unknown
    }
}
