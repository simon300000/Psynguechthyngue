import Foundation

/// Generates the `.stignore` for on-demand folders (DESIGN.md §6.3):
///
/// ```
/// // === Psynguechthyngue managed — do not edit below ===
/// /.stignore-user
/// #include .stignore-user
/// !/Docs/report.pdf
/// !/Photos/2026
/// *
/// ```
///
/// Upstream semantics relied on: first match wins; an anchored pattern also
/// matches everything below it (`/a` ≡ `/a` + `/a/**`); any `!` pattern
/// disables "skip ignored directories" so negations inside ignored parents
/// work; the puller creates ignored parent directories for needed files.
/// On non-Windows `\` escapes glob metacharacters.
public enum IgnoreRulesGenerator {
    public static let header = "// === Psynguechthyngue managed — do not edit below ==="
    public static let userFile = ".stignore-user"
    public static let includeLine = "#include \(userFile)"
    /// Keeps the app's helper file local. Upstream always ignores `.stignore`
    /// itself but not `.stignore-user`, which therefore synced to every peer
    /// as an ordinary file. Written in both content modes (`everythingLines`).
    public static let helperIgnoreLine = "/\(userFile)"
    /// Marks the helper line in an "everything" folder's `.stignore`, where
    /// the rest of the file is the user's own rules.
    public static let helperComment = "// Psynguechthyngue: keep the app's helper file local"

    public enum RuleError: Error, Hashable, Sendable {
        /// Path cannot be expressed as a pattern (newline, `..`, absolute, empty).
        case unrepresentable(String)
    }

    /// Lines for `POST /rest/db/ignores`. `present` paths are kept local.
    public static func lines(present: some Sequence<RelativePath>) throws -> [String] {
        var unique = Set<String>()
        for p in present {
            unique.insert(try pattern(for: p))
        }
        return [header, helperIgnoreLine, includeLine] + unique.sorted() + ["*"]
    }

    /// `.stignore` of an "everything" folder: the helper ignore line first
    /// (first match wins, so no user rule can un-ignore it), then the user's
    /// rules verbatim.
    public static func everythingLines(user: [String]) -> [String] {
        [helperComment, helperIgnoreLine] + userLines(fromEverything: user)
    }

    /// The user's rules from an "everything" `.stignore` (inverse of
    /// `everythingLines`; files written without the helper line pass through).
    public static func userLines(fromEverything lines: [String]) -> [String] {
        var rest = lines[...]
        if rest.first == helperComment { rest = rest.dropFirst() }
        if rest.first == helperIgnoreLine { rest = rest.dropFirst() }
        return Array(rest)
    }

    /// Upstream's internal files and temporary files: never "present" content.
    public static func isEngineInternal(_ name: String) -> Bool {
        if [".stfolder", ".stignore", userFile, ".stversions"].contains(name) { return true }
        if name.hasPrefix(".syncthing.") && name.hasSuffix(".tmp") { return true }
        if name.hasPrefix("~syncthing~") && name.hasSuffix(".tmp") { return true }
        return false
    }

    public static func fileContents(present: some Sequence<RelativePath>) throws -> String {
        try lines(present: present).joined(separator: "\n") + "\n"
    }

    /// `!/<escaped path>`
    public static func pattern(for path: RelativePath) throws -> String {
        let raw = path.rawValue
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\n"), !raw.contains("\r"), !raw.contains("\0") else {
            throw RuleError.unrepresentable(raw)
        }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw RuleError.unrepresentable(raw)
        }
        return "!/" + escape(raw.precomposedStringWithCanonicalMapping)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if "\\*?[]{}".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static func unescape(_ s: Substring) -> String {
        var out = ""
        var escaping = false
        for ch in s {
            if escaping { out.append(ch); escaping = false }
            else if ch == "\\" { escaping = true }
            else { out.append(ch) }
        }
        return out
    }

    /// Whether the given ignore lines are ours (managed on-demand rules).
    public static func isManaged(_ lines: [String]) -> Bool {
        lines.first == header
    }

    /// Present paths recovered from managed lines (inverse of `lines`).
    public static func presentPaths(from lines: [String]) -> Set<RelativePath> {
        guard isManaged(lines) else { return [] }
        var result = Set<RelativePath>()
        for line in lines where line.hasPrefix("!/") {
            result.insert(RelativePath(rawValue: unescape(line.dropFirst(2))))
        }
        return result
    }
}
