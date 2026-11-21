import Foundation

/// Resolves the shared App Group container for the App and the File Provider
/// extension. Both Info.plists carry `PsyAppGroupIdentifier = $(APP_GROUP_IDENTIFIER)`.
public enum AppGroupResolver {
    public enum Failure: Error, Sendable {
        case missingIdentifier
        case containerUnavailable(String)
    }

    public static let infoKey = "PsyAppGroupIdentifier"

    public static func layout(bundle: Bundle = .main) throws -> AppGroupLayout {
        guard let identifier = bundle.object(forInfoDictionaryKey: infoKey) as? String,
            !identifier.isEmpty, !identifier.hasPrefix("$(")
        else { throw Failure.missingIdentifier }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw Failure.containerUnavailable(identifier)
        }
        return AppGroupLayout(root: url)
    }
}

/// Log subsystem shared by the App-side Files services and the extension.
public enum FilesLog {
    public static let subsystem = "app.psynguechthyngue.files"
}
