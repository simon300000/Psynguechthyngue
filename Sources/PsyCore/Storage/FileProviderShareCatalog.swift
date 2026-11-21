import CryptoKit
import Foundation

/// Syncthing labels are display text, not path components. This projection
/// supplies deterministic, filesystem-safe sibling names without changing IDs
/// or the user's original labels.
public enum FileProviderShareCatalog {
    public static func names(for folders: [FolderRecord]) -> [FolderID: String] {
        let unique = UniqueFolderIdentityIndex(folders).uniqueFolders
        let bases = Dictionary(
            uniqueKeysWithValues: unique.map { ($0.id, safeComponent($0.label.isEmpty ? $0.id.rawValue : $0.label)) })
        let groups = Dictionary(grouping: unique, by: { comparisonKey(bases[$0.id]!) })
        var used = Set<String>()
        var result: [FolderID: String] = [:]
        let ordered = unique.sorted { $0.id.rawValue < $1.id.rawValue }
        // Reserve ordinary unique labels first so a generated suffix cannot
        // collide with a label the user deliberately chose.
        for folder in ordered where groups[comparisonKey(bases[folder.id]!)]!.count == 1 {
            let base = bases[folder.id]!
            used.insert(comparisonKey(base))
            result[folder.id] = base
        }
        for folder in ordered where result[folder.id] == nil {
            let digest = SHA256.hash(data: Data(folder.id.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
            var candidate = ""
            for length in stride(from: 12, through: 64, by: 4) {
                candidate = "\(bases[folder.id]!) (\(digest.prefix(length)))"
                if used.insert(comparisonKey(candidate)).inserted { break }
            }
            result[folder.id] = candidate
        }
        return result
    }

    public static func safeComponent(_ text: String) -> String {
        var result = ""
        for character in text.precomposedStringWithCanonicalMapping {
            let unsafe =
                character == "/" || character == ":"
                || character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            let next = unsafe ? "_" : String(character)
            if result.utf8.count + next.utf8.count > 180 { break }
            result += next
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") { result.removeLast() }
        return result.isEmpty || result == "." || result == ".." ? "Folder" : result
    }

    /// Binds working-set anchors to the virtual hierarchy. A changed share
    /// namespace invalidates the old anchor and requests a complete catalog,
    /// so additions, renames and removals cannot be lost between item pages.
    public static func revision(for folders: [FolderRecord]) -> Data {
        let unique = UniqueFolderIdentityIndex(folders).uniqueFolders
        let names = names(for: unique)
        var hash = SHA256()
        for folder in unique.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            for value in [folder.id.rawValue, names[folder.id]!, folder.type.rawValue, String(folder.isPaused)] {
                hash.update(data: Data(value.utf8))
                hash.update(data: Data([0]))
            }
        }
        return Data(hash.finalize())
    }

    private static func comparisonKey(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .precomposedStringWithCanonicalMapping
    }
}
