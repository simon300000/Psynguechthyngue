import Foundation

public enum SelectionRuleSyntax: String, Codable, CaseIterable, Sendable {
    case syncthingGlob
    case re2SafeRegex
}

public enum SelectionRuleAction: String, Codable, CaseIterable, Sendable {
    case include
    case exclude
}

public struct SelectionRule: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var syntax: SelectionRuleSyntax
    public var action: SelectionRuleAction
    public var pattern: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        syntax: SelectionRuleSyntax,
        action: SelectionRuleAction,
        pattern: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.syntax = syntax
        self.action = action
        self.pattern = pattern
        self.isEnabled = isEnabled
    }
}

public enum RuleValidationError: Error, Codable, Hashable, Sendable, LocalizedError {
    case empty
    case tooLong(maximum: Int)
    case invalidGlob(String)
    case unsupportedRegexFeature(String)
    case unsafeRegex(String)
    case invalidRegex(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "The pattern is empty."
        case .tooLong(let maximum): "The pattern exceeds \(maximum) characters."
        case .invalidGlob(let message): "Invalid Syncthing glob: \(message)"
        case .unsupportedRegexFeature(let feature): "Unsupported RE2 feature: \(feature)"
        case .unsafeRegex(let message): "Potentially unsafe regex: \(message)"
        case .invalidRegex(let message): "Invalid regex: \(message)"
        }
    }
}

public struct SelectionEvaluation: Codable, Hashable, Sendable {
    public var action: SelectionRuleAction
    public var matchedRuleID: UUID?

    public init(action: SelectionRuleAction, matchedRuleID: UUID?) {
        self.action = action
        self.matchedRuleID = matchedRuleID
    }
}

public struct SelectionPreview: Codable, Hashable, Sendable {
    public var includedFiles: Int
    public var excludedFiles: Int
    public var includedBytes: Int64
    public var releasableBytes: Int64
    public var matchedByRule: [UUID: Int]

    public init(
        includedFiles: Int = 0,
        excludedFiles: Int = 0,
        includedBytes: Int64 = 0,
        releasableBytes: Int64 = 0,
        matchedByRule: [UUID: Int] = [:]
    ) {
        self.includedFiles = includedFiles
        self.excludedFiles = excludedFiles
        self.includedBytes = includedBytes
        self.releasableBytes = releasableBytes
        self.matchedByRule = matchedByRule
    }
}

public struct SelectionRuleEngine: Sendable {
    public static let maximumPatternLength = 512

    public init() {}

    public func validate(_ rule: SelectionRule) -> Result<Void, RuleValidationError> {
        let pattern = rule.pattern
        guard !pattern.isEmpty else { return .failure(.empty) }
        guard pattern.unicodeScalars.count <= Self.maximumPatternLength else {
            return .failure(.tooLong(maximum: Self.maximumPatternLength))
        }

        switch rule.syntax {
        case .syncthingGlob:
            do {
                _ = try Self.globRegex(pattern)
                return .success(())
            } catch let error as RuleValidationError {
                return .failure(error)
            } catch {
                return .failure(.invalidGlob(error.localizedDescription))
            }
        case .re2SafeRegex:
            return Self.validateSafeRegex(pattern)
        }
    }

    public func evaluate(path: String, isDirectory: Bool, rules: [SelectionRule]) throws -> SelectionEvaluation {
        let normalized = Self.normalize(path)
        for rule in rules where rule.isEnabled {
            switch validate(rule) {
            case .failure(let error): throw error
            case .success: break
            }

            let matched: Bool
            switch rule.syntax {
            case .syncthingGlob:
                matched = try Self.matchesGlob(rule.pattern, path: normalized, isDirectory: isDirectory)
            case .re2SafeRegex:
                matched = try Self.matchesSafeRegex(rule.pattern, path: normalized)
            }
            if matched {
                // Syncthing-style ordered rules use the first matching entry.
                return SelectionEvaluation(action: rule.action, matchedRuleID: rule.id)
            }
        }
        return SelectionEvaluation(action: .include, matchedRuleID: nil)
    }

    public func preview(items: [IndexedItem], rules: [SelectionRule]) throws -> SelectionPreview {
        var preview = SelectionPreview()
        for item in items where !item.isDirectory {
            let result = try evaluate(path: item.relativePath, isDirectory: false, rules: rules)
            if let id = result.matchedRuleID { preview.matchedByRule[id, default: 0] += 1 }
            switch result.action {
            case .include:
                preview.includedFiles += 1
                preview.includedBytes += item.size
            case .exclude:
                preview.excludedFiles += 1
                if item.availability == .local,
                    !item.hasUnuploadedChanges,
                    item.remoteReplicaCount > 0
                {
                    preview.releasableBytes += item.size
                }
            }
        }
        return preview
    }

    private static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func matchesSafeRegex(_ pattern: String, path: String) throws -> Bool {
        try LinearRegexProgram(pattern: pattern).matches(path)
    }

    private static func matchesGlob(_ pattern: String, path: String, isDirectory _: Bool) throws -> Bool {
        let expressions = try globRegex(pattern)
        return expressions.contains { $0.matches(path) }
    }

    private static func validateSafeRegex(_ pattern: String) -> Result<Void, RuleValidationError> {
        do {
            _ = try LinearRegexProgram(pattern: pattern)
            return .success(())
        } catch let error as RuleValidationError {
            return .failure(error)
        } catch {
            return .failure(.invalidRegex(error.localizedDescription))
        }
    }

    /// Mirrors Syncthing's `parseIgnoreFile` and `parseLine` expansion:
    /// unrooted patterns match in the root and subdirectories, and every
    /// non-`/**` pattern also matches descendants of a matching directory.
    private static func globRegex(_ original: String) throws -> [LinearRegexProgram] {
        let parsed = try parsedGlobPrefixes(original)
        var line = parsed.pattern
        guard !line.isEmpty else { throw RuleValidationError.invalidGlob("empty path pattern") }
        if line.hasSuffix("/") { line += "**" }

        let logicalLines = line.hasSuffix("/**") ? [line] : [line, line + "/**"]
        var expanded: [String] = []
        for logicalLine in logicalLines {
            if logicalLine.hasPrefix("/") {
                expanded.append(String(logicalLine.dropFirst()))
            } else if logicalLine.hasPrefix("**/") {
                expanded.append(logicalLine)
                let rootVariant = String(logicalLine.dropFirst(3))
                if !rootVariant.isEmpty { expanded.append(rootVariant) }
            } else {
                expanded.append(logicalLine)
                expanded.append("**/" + logicalLine)
            }
        }

        #if os(macOS) || os(iOS)
            let caseInsensitive = true
        #else
            let caseInsensitive = parsed.caseInsensitive
        #endif

        var seen: Set<String> = []
        return try expanded.compactMap { pattern in
            guard seen.insert(pattern).inserted else { return nil }
            let source = "^" + (try globRegexSource(pattern)) + "$"
            do {
                return try LinearRegexProgram(
                    pattern: source,
                    caseInsensitive: caseInsensitive
                )
            } catch {
                throw RuleValidationError.invalidGlob(error.localizedDescription)
            }
        }
    }

    private static func parsedGlobPrefixes(
        _ original: String
    ) throws -> (pattern: String, caseInsensitive: Bool) {
        var remainder = original[...]
        var sawCaseInsensitive = false
        var sawDeletable = false
        while true {
            if remainder.hasPrefix("(?i)"), !sawCaseInsensitive {
                sawCaseInsensitive = true
                remainder = remainder.dropFirst(4)
            } else if remainder.hasPrefix("(?d)"), !sawDeletable {
                sawDeletable = true
                remainder = remainder.dropFirst(4)
            } else {
                break
            }
        }
        guard !remainder.isEmpty else { throw RuleValidationError.invalidGlob("missing pattern") }
        return (String(remainder), sawCaseInsensitive)
    }

    private static func globRegexSource(_ pattern: String) throws -> String {
        var output = ""
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    output += ".*"
                    index += 1
                } else {
                    output += "[^/]*"
                }
            case "?":
                output += "[^/]"
            case "[":
                guard let close = characters[(index + 1)...].firstIndex(of: "]") else {
                    throw RuleValidationError.invalidGlob("unterminated character class")
                }
                let body = String(characters[(index + 1)..<close])
                guard !body.isEmpty else { throw RuleValidationError.invalidGlob("empty character class") }
                let normalizedBody = body.first == "!" ? "^" + body.dropFirst() : body
                output += "[\(normalizedBody)]"
                index = close
            case "{":
                guard let close = matchingBrace(in: characters, openingAt: index) else {
                    throw RuleValidationError.invalidGlob("unterminated alternative set")
                }
                let body = Array(characters[(index + 1)..<close])
                let alternatives = splitAlternatives(body)
                guard alternatives.count > 1, alternatives.allSatisfy({ !$0.isEmpty }) else {
                    throw RuleValidationError.invalidGlob("invalid alternative set")
                }
                output +=
                    "("
                    + (try alternatives.map { try globRegexSource(String($0)) }).joined(separator: "|")
                    + ")"
                index = close
            case "}":
                throw RuleValidationError.invalidGlob("unmatched closing brace")
            case "\\":
                guard index + 1 < characters.count else {
                    throw RuleValidationError.invalidGlob("trailing escape")
                }
                index += 1
                output += linearRegexEscapedLiteral(characters[index])
            default:
                output += linearRegexEscapedLiteral(character)
            }
            index += 1
        }
        return output
    }

    private static func linearRegexEscapedLiteral(_ character: Character) -> String {
        let reserved = #"\.+*?()|[]{}^$"#
        var output = ""
        for scalar in String(character).unicodeScalars {
            if reserved.unicodeScalars.contains(scalar) { output.append("\\") }
            output.unicodeScalars.append(scalar)
        }
        return output
    }

    private static func matchingBrace(in characters: [Character], openingAt opening: Int) -> Int? {
        var depth = 0
        var escaped = false
        for index in opening..<characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func splitAlternatives(_ characters: [Character]) -> [[Character]] {
        var result: [[Character]] = [[]]
        var depth = 0
        var escaped = false
        for character in characters {
            if escaped {
                result[result.count - 1].append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                result[result.count - 1].append(character)
                escaped = true
            } else if character == "{" {
                depth += 1
                result[result.count - 1].append(character)
            } else if character == "}" {
                depth -= 1
                result[result.count - 1].append(character)
            } else if character == ",", depth == 0 {
                result.append([])
            } else {
                result[result.count - 1].append(character)
            }
        }
        return result
    }
}

public actor IncrementalSelectionPreviewer {
    private let engine: SelectionRuleEngine

    public init(engine: SelectionRuleEngine = .init()) {
        self.engine = engine
    }

    public func preview<S: AsyncSequence>(
        _ items: S,
        rules: [SelectionRule],
        onProgress: @Sendable (SelectionPreview) async -> Void
    ) async throws -> SelectionPreview where S.Element == IndexedItem {
        var accumulated = SelectionPreview()
        var batch: [IndexedItem] = []
        for try await item in items {
            try Task.checkCancellation()
            batch.append(item)
            if batch.count == 512 {
                accumulated = try merge(accumulated, engine.preview(items: batch, rules: rules))
                batch.removeAll(keepingCapacity: true)
                await onProgress(accumulated)
                await Task.yield()
            }
        }
        if !batch.isEmpty {
            accumulated = try merge(accumulated, engine.preview(items: batch, rules: rules))
            await onProgress(accumulated)
        }
        return accumulated
    }

    private func merge(_ lhs: SelectionPreview, _ rhs: SelectionPreview) -> SelectionPreview {
        var counts = lhs.matchedByRule
        for (key, value) in rhs.matchedByRule { counts[key, default: 0] += value }
        return SelectionPreview(
            includedFiles: lhs.includedFiles + rhs.includedFiles,
            excludedFiles: lhs.excludedFiles + rhs.excludedFiles,
            includedBytes: lhs.includedBytes + rhs.includedBytes,
            releasableBytes: lhs.releasableBytes + rhs.releasableBytes,
            matchedByRule: counts
        )
    }
}
