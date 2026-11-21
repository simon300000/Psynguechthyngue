import Foundation

/// Path safety for every write/delete the extension performs inside a folder
/// root (ported from PsyCore `DestructiveOperationGuard`). Rejects relative
/// paths that escape the root lexically ("..", absolute) or through a symlink
/// in an existing ancestor.
public enum PathContainmentError: Error, Hashable, Sendable {
    case invalidRelativePath(String)
    case escapesRoot
    case symlinkEscapesRoot
}

public struct PathContainment: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// Resolves `relative` under `root`, validating containment.
    public func url(for relative: RelativePath) throws -> URL {
        if relative.isRoot { return root }
        guard Self.isWellFormed(relative) else { throw PathContainmentError.invalidRelativePath(relative.rawValue) }
        let candidate = root.appending(path: relative.rawValue, directoryHint: .inferFromPath)
        try validate(candidate)
        return candidate
    }

    public static func isWellFormed(_ relative: RelativePath) -> Bool {
        let raw = relative.rawValue
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\0") else { return false }
        return !raw.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0.isEmpty || $0 == "." || $0 == ".."
        }
    }

    /// A single new filename (no separators) as received from Files.
    public static func isValidFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && name.utf8.count <= 255
    }

    public func validate(_ candidate: URL) throws {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        let resolved = Self.resolvingExistingAncestors(candidate.standardizedFileURL).path(percentEncoded: false)
        let trimmed = resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
        let rootTrimmed = rootPrefix.hasSuffix("/") ? String(rootPrefix.dropLast()) : rootPrefix
        guard trimmed == rootTrimmed || trimmed.hasPrefix(rootPrefix) else {
            let lexicalRoot = root.path(percentEncoded: false)
            let lexicalPrefix = lexicalRoot.hasSuffix("/") ? lexicalRoot : lexicalRoot + "/"
            if candidate.standardizedFileURL.path(percentEncoded: false).hasPrefix(lexicalPrefix) {
                throw PathContainmentError.symlinkEscapesRoot
            }
            throw PathContainmentError.escapesRoot
        }
    }

    private static func resolvingExistingAncestors(_ url: URL) -> URL {
        var existing = url
        var missing: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path(percentEncoded: false)), existing.path(percentEncoded: false) != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        // Resolve a final-component symlink too (lstat-based check below).
        var result = existing.resolvingSymlinksInPath()
        for component in missing { result.append(path: component) }
        return result.standardizedFileURL
    }
}
