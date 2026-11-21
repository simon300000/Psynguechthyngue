import Foundation

/// Whether our File Provider location is enabled in Files/Finder. On Mac
/// (Designed for iPad) it starts disabled and the user must turn it on in
/// System Settings ▸ General ▸ Login Items & Extensions ▸ File Providers.
/// WP-C's DomainManager supplies the real value through `AppEnvironment.filesStatus`.
enum FilesLocationState: Equatable {
    case unknown
    case enabled
    case disabled
}

@MainActor
protocol FilesLocationStatusProviding: AnyObject {
    func currentState() async -> FilesLocationState
}

/// Fixtures / no Files integration (`-PsyUITestFilesDisabled` forces "disabled" in fixtures).
@MainActor
final class StaticFilesLocationStatus: FilesLocationStatusProviding {
    let state: FilesLocationState
    init(_ state: FilesLocationState) { self.state = state }
    func currentState() async -> FilesLocationState { state }
}
