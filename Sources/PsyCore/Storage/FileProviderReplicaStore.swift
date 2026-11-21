import Foundation

/// System replica observations are intentionally separate from Syncthing's
/// source availability. Absence here never authorizes deleting core bytes.
public struct FileProviderReplicaStore: Sendable {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func replaceObservedIdentifiers(_ identifiers: Set<String>) throws {
        try FileLock.withExclusiveLock(at: url.appendingPathExtension("lock")) {
            let ordered = identifiers.sorted()
            if let data = try? Data(contentsOf: url),
                let existing = try? JSONDecoder().decode([String].self, from: data), existing == ordered
            {
                return
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
                try JSONEncoder().encode(ordered).write(
                    to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
                try JSONEncoder().encode(ordered).write(to: url, options: .atomic)
            #endif
        }
    }

    public func observedIdentifiers() throws -> Set<String> {
        try FileLock.withExclusiveLock(at: url.appendingPathExtension("lock")) {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
        }
    }
}
