import Foundation

/// Full Syncthing device ID in canonical form ("XXXXXXX-XXXXXXX-...", 8 groups).
/// User input is validated and normalised by the App's `DeviceIDParser`;
/// this type only carries canonical values.
public struct DeviceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// First group, as Syncthing shows it in short form.
    public var short: String { String(rawValue.prefix(7)) }
    public var description: String { rawValue }
}

/// Syncthing folder ID (shared between devices; not the label).
public struct FolderID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Folder-relative path, '/' separated, Unicode NFC, never starting with '/'.
public struct RelativePath: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let root = RelativePath(rawValue: "")
    public var isRoot: Bool { rawValue.isEmpty }
    public var lastComponent: String { rawValue.split(separator: "/").last.map(String.init) ?? "" }
    public var parent: RelativePath {
        guard let slash = rawValue.lastIndex(of: "/") else { return .root }
        return RelativePath(rawValue: String(rawValue[..<slash]))
    }
    public func appending(_ component: String) -> RelativePath {
        isRoot ? RelativePath(rawValue: component) : RelativePath(rawValue: rawValue + "/" + component)
    }
    public var description: String { rawValue }
}
