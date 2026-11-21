import Foundation

public enum SafetyDenial: String, Codable, Hashable, Sendable, Error {
    case pathEscapesRoot
    case symbolicLinkEscapesRoot
}

public struct DestructiveOperationGuard: Sendable {
    public init() {}

    public func validateContainedPath(_ candidate: URL, root: URL) -> Result<URL, SafetyDenial> {
        let standardizedRoot = root.standardizedFileURL
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        let standardizedCandidate = candidate.standardizedFileURL
        let resolvedCandidate = Self.resolvingExistingAncestors(of: standardizedCandidate)
        let resolvedRootPath =
            resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path : resolvedRoot.path + "/"

        guard
            resolvedCandidate == resolvedRoot
                || resolvedCandidate.path.hasPrefix(resolvedRootPath)
        else {
            // Classify from the caller's lexical relationship. Darwin may
            // spell the same app-container root as `/var/...` in one URL and
            // `/private/var/...` after filesystem resolution on physical iOS.
            let lexicalRootPath =
                root.path.hasSuffix("/")
                ? root.path : root.path + "/"
            if candidate.path.hasPrefix(lexicalRootPath) {
                return .failure(.symbolicLinkEscapesRoot)
            }
            return .failure(.pathEscapesRoot)
        }
        return .success(resolvedCandidate)
    }

    private static func resolvingExistingAncestors(of url: URL) -> URL {
        var existingAncestor = url
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
            existingAncestor.path != "/"
        {
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }
        var result = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents {
            result.appendPathComponent(component)
        }
        return result.standardizedFileURL
    }
}
