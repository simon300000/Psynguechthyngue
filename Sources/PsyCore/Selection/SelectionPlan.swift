import Foundation

/// A framework-neutral projection of the mutations a replicated File Provider
/// item may truthfully advertise. Retention policy controls whether bytes are
/// kept locally; it never changes whether a writable Syncthing folder accepts
/// local edits.
public struct FileProviderMutationAccess: Hashable, Sendable {
    public var allowsAddingSubItems: Bool
    public var allowsWriting: Bool
    public var allowsRenaming: Bool
    public var allowsReparenting: Bool
    public var allowsDeleting: Bool

    public init(
        allowsAddingSubItems: Bool = false,
        allowsWriting: Bool = false,
        allowsRenaming: Bool = false,
        allowsReparenting: Bool = false,
        allowsDeleting: Bool = false
    ) {
        self.allowsAddingSubItems = allowsAddingSubItems
        self.allowsWriting = allowsWriting
        self.allowsRenaming = allowsRenaming
        self.allowsReparenting = allowsReparenting
        self.allowsDeleting = allowsDeleting
    }

    public static let readOnly = FileProviderMutationAccess()

    public static func evaluate(
        folder: FolderRecord,
        item: IndexedItem?
    ) -> FileProviderMutationAccess {
        guard !folder.isPaused,
            folder.error?.isEmpty != false,
            folder.type == .sendReceive || folder.type == .sendOnly
        else {
            return .readOnly
        }

        guard let item else {
            return FileProviderMutationAccess(allowsAddingSubItems: true)
        }
        guard item.folderID == folder.id,
            item.availability == .local || item.availability == .uploading
        else {
            return .readOnly
        }

        return FileProviderMutationAccess(
            allowsAddingSubItems: item.isDirectory,
            allowsWriting: true,
            allowsRenaming: true,
            allowsReparenting: true,
            allowsDeleting: true
        )
    }
}

/// Indexes only folder identities that occur exactly once in a snapshot.
/// Duplicate identities are omitted so presentation and callback preflight
/// share the same fail-closed interpretation.
public struct UniqueFolderIdentityIndex: Sendable {
    public let uniqueFolders: [FolderRecord]
    private let foldersByID: [FolderID: FolderRecord]

    public init(_ folders: [FolderRecord]) {
        var counts: [FolderID: Int] = [:]
        for folder in folders {
            counts[folder.id, default: 0] += 1
        }
        uniqueFolders = folders.filter { counts[$0.id] == 1 }
        foldersByID = Dictionary(
            uniqueKeysWithValues: uniqueFolders.map { ($0.id, $0) }
        )
    }

    public func folder(_ folderID: FolderID) -> FolderRecord? {
        foldersByID[folderID]
    }
}

public enum FolderContentSelectionMode: String, Codable, CaseIterable, Sendable {
    case fullSync
    case manualSelection
    case globRules
    case regexRules
    case indexOnly
    case onDemand
    case pinnedOffline
}

public enum ManualSelectionValue: String, Codable, CaseIterable, Sendable {
    case included
    case excluded

    public var inverted: Self { self == .included ? .excluded : .included }
}

public enum DirectorySelectionState: String, Codable, Sendable {
    case included
    case excluded
    case mixed
}

/// A single-pass projection used by large manual-selection views. Computing
/// every directory state independently requires repeatedly scanning all index
/// items; this projection evaluates each item once and rolls its value up only
/// through the item's existing directory ancestors.
public struct ManualSelectionProjection: Sendable {
    private var valuesByItemID: [String: ManualSelectionValue]
    private var directoryStatesByItemID: [String: DirectorySelectionState]

    public init(
        valuesByItemID: [String: ManualSelectionValue] = [:],
        directoryStatesByItemID: [String: DirectorySelectionState] = [:]
    ) {
        self.valuesByItemID = valuesByItemID
        self.directoryStatesByItemID = directoryStatesByItemID
    }

    public func value(itemID: String) -> ManualSelectionValue? {
        valuesByItemID[itemID]
    }

    public func directoryState(itemID: String) -> DirectorySelectionState? {
        directoryStatesByItemID[itemID]
    }
}

public struct ManualSelectionDirective: Codable, Hashable, Sendable {
    public var relativePath: String
    public var isDirectory: Bool
    public var value: ManualSelectionValue

    public init(relativePath: String, isDirectory: Bool, value: ManualSelectionValue) {
        self.relativePath = normalizedSelectionPath(relativePath)
        self.isDirectory = isDirectory
        self.value = value
    }
}

public enum SelectionContentDisposition: String, Codable, Sendable {
    case synchronized
    case excluded
    case indexOnly
    case onDemand
    case pinnedOffline

    fileprivate var isMatched: Bool {
        switch self {
        case .synchronized, .onDemand, .pinnedOffline: true
        case .excluded, .indexOnly: false
        }
    }

    /// Whether this selection plan asks the mobile device to keep the item's
    /// materialized bytes. This is a local retention decision only; it never
    /// changes Syncthing ignore rules or the global index.
    public var keepsDownloaded: Bool {
        switch self {
        case .synchronized, .pinnedOffline: true
        case .excluded, .indexOnly, .onDemand: false
        }
    }
}

public enum SelectionPlanError: Error, Hashable, Sendable, LocalizedError {
    case noRules(SelectionRuleSyntax)
    case noEnabledRules(SelectionRuleSyntax)
    case duplicateRuleIdentifier(UUID)
    case wrongRuleSyntax(expected: SelectionRuleSyntax, actual: SelectionRuleSyntax, ruleID: UUID)
    case invalidRule(UUID, RuleValidationError)
    case unsupportedSchema(Int)
    case folderMismatch
    case confirmationRequired

    public var errorDescription: String? {
        switch self {
        case .noRules(let syntax): "No \(syntax.rawValue) rules are defined."
        case .noEnabledRules(let syntax): "No \(syntax.rawValue) rules are enabled."
        case .duplicateRuleIdentifier(let id): "Rule identifier \(id.uuidString) is duplicated."
        case .wrongRuleSyntax(let expected, let actual, _):
            "A \(actual.rawValue) rule is stored in the \(expected.rawValue) rule set."
        case .invalidRule(_, let error): error.localizedDescription
        case .unsupportedSchema(let schema): "Unsupported selection draft schema \(schema)."
        case .folderMismatch: "The selection draft belongs to another folder."
        case .confirmationRequired: "The required selection-change confirmation was not completed."
        }
    }
}

public struct FolderSelectionPlan: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    private static let defaultGlobRuleID = UUID(
        uuidString: "5053594E-4755-4543-4854-48594E475501"
    )!
    private static let defaultRegexRuleID = UUID(
        uuidString: "5053594E-4755-4543-4854-48594E475502"
    )!

    public var schemaVersion: Int
    public var mode: FolderContentSelectionMode
    public var manualDefault: ManualSelectionValue
    public var manualDirectives: [ManualSelectionDirective]
    public var globRules: [SelectionRule]
    public var regexRules: [SelectionRule]

    public init(
        schemaVersion: Int = Self.schemaVersion,
        mode: FolderContentSelectionMode = .fullSync,
        manualDefault: ManualSelectionValue = .excluded,
        manualDirectives: [ManualSelectionDirective] = [],
        globRules: [SelectionRule] = Self.defaultGlobRules,
        regexRules: [SelectionRule] = Self.defaultRegexRules
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.manualDefault = manualDefault
        self.manualDirectives = manualDirectives
        self.globRules = globRules
        self.regexRules = regexRules
        normalizeManualDirectives()
    }

    public init(snapshotMode: ContentSelectionMode) {
        let mode: FolderContentSelectionMode =
            switch snapshotMode {
            case .full: .fullSync
            case .manual: .manualSelection
            case .rules: .globRules
            case .indexOnly: .indexOnly
            }
        self.init(mode: mode)
    }

    public static var defaultGlobRules: [SelectionRule] {
        [
            SelectionRule(
                id: defaultGlobRuleID,
                syntax: .syncthingGlob,
                action: .include,
                pattern: "**"
            )
        ]
    }

    public static var defaultRegexRules: [SelectionRule] {
        [
            SelectionRule(
                id: defaultRegexRuleID,
                syntax: .re2SafeRegex,
                action: .include,
                pattern: ".*"
            )
        ]
    }

    public var activeRuleSyntax: SelectionRuleSyntax? {
        switch mode {
        case .globRules: .syncthingGlob
        case .regexRules: .re2SafeRegex
        case .fullSync, .manualSelection, .indexOnly, .onDemand, .pinnedOffline: nil
        }
    }

    public func rules(for syntax: SelectionRuleSyntax) -> [SelectionRule] {
        switch syntax {
        case .syncthingGlob: globRules
        case .re2SafeRegex: regexRules
        }
    }

    public mutating func setRules(_ rules: [SelectionRule], for syntax: SelectionRuleSyntax) {
        switch syntax {
        case .syncthingGlob: globRules = rules
        case .re2SafeRegex: regexRules = rules
        }
    }

    @discardableResult
    public mutating func appendRule(
        syntax: SelectionRuleSyntax,
        action: SelectionRuleAction,
        pattern: String? = nil,
        id: UUID = UUID()
    ) -> UUID {
        let rule = SelectionRule(
            id: id,
            syntax: syntax,
            action: action,
            pattern: pattern ?? (syntax == .syncthingGlob ? "**" : ".*")
        )
        var values = rules(for: syntax)
        values.append(rule)
        setRules(values, for: syntax)
        return id
    }

    @discardableResult
    public mutating func updateRule(_ rule: SelectionRule) -> Bool {
        var values = rules(for: rule.syntax)
        guard let index = values.firstIndex(where: { $0.id == rule.id }) else { return false }
        values[index] = rule
        setRules(values, for: rule.syntax)
        return true
    }

    @discardableResult
    public mutating func removeRule(id: UUID, syntax: SelectionRuleSyntax) -> Bool {
        var values = rules(for: syntax)
        guard let index = values.firstIndex(where: { $0.id == id }) else { return false }
        values.remove(at: index)
        setRules(values, for: syntax)
        return true
    }

    @discardableResult
    public mutating func duplicateRule(
        id: UUID,
        syntax: SelectionRuleSyntax,
        newID: UUID = UUID()
    ) -> UUID? {
        var values = rules(for: syntax)
        guard let index = values.firstIndex(where: { $0.id == id }) else { return nil }
        let original = values[index]
        values.insert(
            SelectionRule(
                id: newID,
                syntax: original.syntax,
                action: original.action,
                pattern: original.pattern,
                isEnabled: original.isEnabled
            ),
            at: index + 1
        )
        setRules(values, for: syntax)
        return newID
    }

    @discardableResult
    public mutating func moveRule(id: UUID, syntax: SelectionRuleSyntax, to destination: Int) -> Bool {
        var values = rules(for: syntax)
        guard let source = values.firstIndex(where: { $0.id == id }) else { return false }
        let rule = values.remove(at: source)
        let bounded = min(max(0, destination), values.count)
        values.insert(rule, at: bounded)
        setRules(values, for: syntax)
        return true
    }

    public mutating func restoreDefaultRules(for syntax: SelectionRuleSyntax) {
        setRules(
            syntax == .syncthingGlob ? Self.defaultGlobRules : Self.defaultRegexRules,
            for: syntax
        )
    }

    public mutating func selectAllManually() {
        manualDefault = .included
        manualDirectives.removeAll()
    }

    public mutating func deselectAllManually() {
        manualDefault = .excluded
        manualDirectives.removeAll()
    }

    public mutating func invertManualSelection() {
        manualDefault = manualDefault.inverted
        manualDirectives = manualDirectives.map {
            ManualSelectionDirective(
                relativePath: $0.relativePath,
                isDirectory: $0.isDirectory,
                value: $0.value.inverted
            )
        }
        normalizeManualDirectives()
    }

    public func manualValue(for relativePath: String, isDirectory: Bool) -> ManualSelectionValue {
        manualValue(
            for: normalizedSelectionPath(relativePath),
            isDirectory: isDirectory,
            directives: manualDirectives
        )
    }

    public mutating func setManualValue(
        _ value: ManualSelectionValue,
        for relativePath: String,
        isDirectory: Bool
    ) {
        let path = normalizedSelectionPath(relativePath)
        manualDirectives.removeAll { directive in
            directive.relativePath == path
                || (isDirectory && selectionPath(directive.relativePath, isDescendantOf: path))
        }
        let inherited = manualValue(for: path, isDirectory: isDirectory, directives: manualDirectives)
        if inherited != value {
            manualDirectives.append(
                ManualSelectionDirective(relativePath: path, isDirectory: isDirectory, value: value)
            )
        }
        normalizeManualDirectives()
    }

    public mutating func setManualValue(
        _ value: ManualSelectionValue,
        forItemIDs itemIDs: Set<String>,
        items: [IndexedItem]
    ) {
        let selected = items.filter { itemIDs.contains($0.id) }.sorted {
            let lhsDepth = normalizedSelectionPath($0.relativePath).split(separator: "/").count
            let rhsDepth = normalizedSelectionPath($1.relativePath).split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.relativePath < $1.relativePath
        }
        var coveredDirectories: [String] = []
        for item in selected {
            let path = normalizedSelectionPath(item.relativePath)
            if coveredDirectories.contains(where: { selectionPath(path, isDescendantOf: $0) }) {
                continue
            }
            setManualValue(value, for: path, isDirectory: item.isDirectory)
            if item.isDirectory { coveredDirectories.append(path) }
        }
    }

    public func manualDirectoryState(
        for relativePath: String,
        items: [IndexedItem]
    ) -> DirectorySelectionState {
        let path = normalizedSelectionPath(relativePath)
        let descendants = items.filter {
            selectionPath(normalizedSelectionPath($0.relativePath), isDescendantOf: path)
        }
        guard !descendants.isEmpty else {
            return manualValue(for: path, isDirectory: true) == .included ? .included : .excluded
        }
        var sawIncluded = false
        var sawExcluded = false
        for item in descendants {
            switch manualValue(for: item.relativePath, isDirectory: item.isDirectory) {
            case .included: sawIncluded = true
            case .excluded: sawExcluded = true
            }
            if sawIncluded, sawExcluded { return .mixed }
        }
        return sawIncluded ? .included : .excluded
    }

    public func manualSelectionProjection(items: [IndexedItem]) -> ManualSelectionProjection {
        struct Aggregate {
            var sawIncluded = false
            var sawExcluded = false

            mutating func record(_ value: ManualSelectionValue) {
                switch value {
                case .included: sawIncluded = true
                case .excluded: sawExcluded = true
                }
            }

            var state: DirectorySelectionState? {
                switch (sawIncluded, sawExcluded) {
                case (true, true): .mixed
                case (true, false): .included
                case (false, true): .excluded
                case (false, false): nil
                }
            }
        }

        var valuesByItemID: [String: ManualSelectionValue] = [:]
        valuesByItemID.reserveCapacity(items.count)
        let directivesByPath = Dictionary(
            manualDirectives.map { ($0.relativePath, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var directoryIDsByPath: [String: [String]] = [:]
        directoryIDsByPath.reserveCapacity(items.count / 4)
        for item in items where item.isDirectory {
            directoryIDsByPath[normalizedSelectionPath(item.relativePath), default: []]
                .append(item.id)
        }

        var descendantAggregates: [String: Aggregate] = [:]
        descendantAggregates.reserveCapacity(directoryIDsByPath.count)
        for item in items {
            let normalizedPath = normalizedSelectionPath(item.relativePath)
            let components = normalizedPath.split(separator: "/")
            var value = manualDefault
            if let rootDirective = directivesByPath[""],
                normalizedPath.isEmpty || rootDirective.isDirectory
            {
                value = rootDirective.value
            }
            if !components.isEmpty {
                for depth in 1...components.count {
                    let candidatePath = components.prefix(depth).joined(separator: "/")
                    guard let directive = directivesByPath[candidatePath] else { continue }
                    if depth == components.count || directive.isDirectory {
                        value = directive.value
                    }
                }
            }
            valuesByItemID[item.id] = value

            if !normalizedPath.isEmpty,
                let rootDirectoryIDs = directoryIDsByPath[""]
            {
                for directoryID in rootDirectoryIDs {
                    descendantAggregates[directoryID, default: Aggregate()].record(value)
                }
            }
            guard components.count > 1 else { continue }
            for ancestorDepth in 1..<components.count {
                let ancestorPath = components.prefix(ancestorDepth).joined(separator: "/")
                guard let directoryIDs = directoryIDsByPath[ancestorPath] else { continue }
                for directoryID in directoryIDs {
                    descendantAggregates[directoryID, default: Aggregate()].record(value)
                }
            }
        }

        var directoryStatesByItemID: [String: DirectorySelectionState] = [:]
        directoryStatesByItemID.reserveCapacity(directoryIDsByPath.count)
        for item in items where item.isDirectory {
            if let state = descendantAggregates[item.id]?.state {
                directoryStatesByItemID[item.id] = state
            } else {
                directoryStatesByItemID[item.id] =
                    valuesByItemID[item.id] == .included ? .included : .excluded
            }
        }
        return ManualSelectionProjection(
            valuesByItemID: valuesByItemID,
            directoryStatesByItemID: directoryStatesByItemID
        )
    }

    public func validate(engine: SelectionRuleEngine = .init()) -> [SelectionPlanError] {
        guard schemaVersion == Self.schemaVersion else { return [.unsupportedSchema(schemaVersion)] }
        guard let syntax = activeRuleSyntax else { return [] }
        let activeRules = rules(for: syntax)
        guard !activeRules.isEmpty else { return [.noRules(syntax)] }
        var issues: [SelectionPlanError] = []
        var identifiers: Set<UUID> = []
        for rule in activeRules {
            if !identifiers.insert(rule.id).inserted { issues.append(.duplicateRuleIdentifier(rule.id)) }
            if rule.syntax != syntax {
                issues.append(.wrongRuleSyntax(expected: syntax, actual: rule.syntax, ruleID: rule.id))
                continue
            }
            if case .failure(let error) = engine.validate(rule) { issues.append(.invalidRule(rule.id, error)) }
        }
        if !activeRules.contains(where: \.isEnabled) { issues.append(.noEnabledRules(syntax)) }
        return issues
    }

    public func disposition(
        for item: IndexedItem,
        engine: SelectionRuleEngine = .init()
    ) throws -> SelectionContentDisposition {
        switch mode {
        case .fullSync: return .synchronized
        case .manualSelection:
            return manualValue(for: item.relativePath, isDirectory: item.isDirectory) == .included
                ? .synchronized
                : .excluded
        case .globRules, .regexRules:
            if let issue = validate(engine: engine).first { throw issue }
            guard let syntax = activeRuleSyntax else { return .excluded }
            let evaluation = try engine.evaluate(
                path: item.relativePath,
                isDirectory: item.isDirectory,
                rules: rules(for: syntax)
            )
            return evaluation.action == .include ? .synchronized : .excluded
        case .indexOnly: return .indexOnly
        case .onDemand: return .onDemand
        case .pinnedOffline: return .pinnedOffline
        }
    }

    public func preview(
        items: [IndexedItem],
        comparedTo previous: FolderSelectionPlan? = nil,
        engine: SelectionRuleEngine = .init()
    ) throws -> SelectionPlanPreview {
        if let issue = validate(engine: engine).first { throw issue }
        if let previous, let issue = previous.validate(engine: engine).first { throw issue }

        var result = SelectionPlanPreview()
        for item in items where !item.isDirectory {
            result.totalFiles += 1
            result.totalBytes += item.size
            let proposed = try disposition(for: item, engine: engine)
            // Retention never removes global-index metadata from Files.
            result.indexedFiles += 1
            if proposed.isMatched {
                result.matchedFiles += 1
                result.matchedBytes += item.size
            } else if proposed == .excluded {
                result.excludedFiles += 1
            }
            if proposed.keepsDownloaded, item.availability == .remoteOnly {
                result.downloadBytes += item.size
            }
            if !proposed.keepsDownloaded,
                item.availability == .local,
                item.isUploaded
            {
                result.releasableBytes += item.size
            }
        }
        return result
    }

    private func manualValue(
        for path: String,
        isDirectory: Bool,
        directives: [ManualSelectionDirective]
    ) -> ManualSelectionValue {
        let applicable = directives.enumerated().filter { _, directive in
            directive.relativePath == path
                || (directive.isDirectory && selectionPath(path, isDescendantOf: directive.relativePath))
        }
        return applicable.max { lhs, rhs in
            let lhsLength = lhs.element.relativePath.count
            let rhsLength = rhs.element.relativePath.count
            return lhsLength == rhsLength ? lhs.offset < rhs.offset : lhsLength < rhsLength
        }?.element.value ?? manualDefault
    }

    private mutating func normalizeManualDirectives() {
        var byPath: [String: ManualSelectionDirective] = [:]
        for directive in manualDirectives {
            let normalized = ManualSelectionDirective(
                relativePath: directive.relativePath,
                isDirectory: directive.isDirectory,
                value: directive.value
            )
            byPath[normalized.relativePath] = normalized
        }
        manualDirectives = byPath.values.sorted {
            if $0.relativePath.count != $1.relativePath.count {
                return $0.relativePath.count < $1.relativePath.count
            }
            return $0.relativePath < $1.relativePath
        }
    }
}

public struct SelectionPlanPreview: Codable, Hashable, Sendable {
    public var totalFiles: Int
    public var totalBytes: Int64
    public var indexedFiles: Int
    public var matchedFiles: Int
    public var matchedBytes: Int64
    public var excludedFiles: Int
    public var downloadBytes: Int64
    public var releasableBytes: Int64

    public init(
        totalFiles: Int = 0,
        totalBytes: Int64 = 0,
        indexedFiles: Int = 0,
        matchedFiles: Int = 0,
        matchedBytes: Int64 = 0,
        excludedFiles: Int = 0,
        downloadBytes: Int64 = 0,
        releasableBytes: Int64 = 0
    ) {
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.indexedFiles = indexedFiles
        self.matchedFiles = matchedFiles
        self.matchedBytes = matchedBytes
        self.excludedFiles = excludedFiles
        self.downloadBytes = downloadBytes
        self.releasableBytes = releasableBytes
    }

    public var confirmation: SelectionChangeConfirmation {
        var risks: [SelectionChangeRisk] = []
        if releasableBytes > 0 {
            risks.append(
                SelectionChangeRisk(
                    kind: .localCopiesMayBeReleased,
                    severity: .caution,
                    affectedFiles: 0,
                    affectedBytes: releasableBytes
                )
            )
        }
        let needsTypedPhrase = risks.contains(where: { $0.severity == .destructive })
        return SelectionChangeConfirmation(
            risks: risks,
            requiresAcknowledgement: !risks.isEmpty,
            requiredPhrase: needsTypedPhrase ? "PREPARE CHANGE" : nil
        )
    }
}

public enum SelectionChangeRiskKind: String, Codable, Sendable {
    case localCopiesMayBeReleased
}

public enum SelectionChangeRiskSeverity: String, Codable, Sendable {
    case caution
    case destructive
}

public struct SelectionChangeRisk: Codable, Hashable, Sendable, Identifiable {
    public var id: SelectionChangeRiskKind { kind }
    public var kind: SelectionChangeRiskKind
    public var severity: SelectionChangeRiskSeverity
    public var affectedFiles: Int
    public var affectedBytes: Int64

    public init(
        kind: SelectionChangeRiskKind,
        severity: SelectionChangeRiskSeverity,
        affectedFiles: Int,
        affectedBytes: Int64
    ) {
        self.kind = kind
        self.severity = severity
        self.affectedFiles = affectedFiles
        self.affectedBytes = affectedBytes
    }
}

public struct SelectionChangeConfirmation: Codable, Hashable, Sendable {
    public var risks: [SelectionChangeRisk]
    public var requiresAcknowledgement: Bool
    public var requiredPhrase: String?

    public init(
        risks: [SelectionChangeRisk] = [],
        requiresAcknowledgement: Bool = false,
        requiredPhrase: String? = nil
    ) {
        self.risks = risks
        self.requiresAcknowledgement = requiresAcknowledgement
        self.requiredPhrase = requiredPhrase
    }

    public func accepts(acknowledged: Bool, typedPhrase: String) -> Bool {
        if requiresAcknowledgement, !acknowledged { return false }
        guard let requiredPhrase else { return true }
        return typedPhrase.trimmingCharacters(in: .whitespacesAndNewlines) == requiredPhrase
    }
}

public struct FolderSelectionDraft: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var folderID: FolderID
    public var baselineGeneration: UInt64
    public var plan: FolderSelectionPlan
    public var updatedAt: Date

    public init(
        schemaVersion: Int = Self.schemaVersion,
        folderID: FolderID,
        baselineGeneration: UInt64,
        plan: FolderSelectionPlan,
        updatedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.folderID = folderID
        self.baselineGeneration = baselineGeneration
        self.plan = plan
        self.updatedAt = updatedAt
    }
}

public struct FolderSelectionDraftStore: Sendable {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func load(folderID: FolderID) throws -> FolderSelectionDraft? {
        let url = draftURL(for: folderID)
        return try FileLock.withExclusiveLock(at: url.appendingPathExtension("lock")) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let draft = try decoder.decode(FolderSelectionDraft.self, from: Data(contentsOf: url))
            guard draft.schemaVersion == FolderSelectionDraft.schemaVersion else {
                throw SelectionPlanError.unsupportedSchema(draft.schemaVersion)
            }
            guard draft.plan.schemaVersion == FolderSelectionPlan.schemaVersion else {
                throw SelectionPlanError.unsupportedSchema(draft.plan.schemaVersion)
            }
            guard draft.folderID == folderID else { throw SelectionPlanError.folderMismatch }
            return draft
        }
    }

    public func save(_ draft: FolderSelectionDraft) throws {
        guard draft.schemaVersion == FolderSelectionDraft.schemaVersion else {
            throw SelectionPlanError.unsupportedSchema(draft.schemaVersion)
        }
        guard draft.plan.schemaVersion == FolderSelectionPlan.schemaVersion else {
            throw SelectionPlanError.unsupportedSchema(draft.plan.schemaVersion)
        }
        let url = draftURL(for: draft.folderID)
        try FileLock.withExclusiveLock(at: url.appendingPathExtension("lock")) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            #if os(iOS)
                let options: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
            #else
                let options: Data.WritingOptions = [.atomic]
            #endif
            try encoder.encode(draft).write(to: url, options: options)
        }
    }

    private func draftURL(for folderID: FolderID) -> URL {
        let encoded = Data(folderID.rawValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return root.appendingPathComponent("\(encoded).json")
    }
}

public struct SelectionTreeNode: Hashable, Sendable, Identifiable {
    public var id: String { item.id }
    public var item: IndexedItem
    public var children: [SelectionTreeNode]

    public init(item: IndexedItem, children: [SelectionTreeNode] = []) {
        self.item = item
        self.children = children
    }

    public var outlineChildren: [SelectionTreeNode]? { children.isEmpty ? nil : children }
}

public struct SelectionFileTree: Hashable, Sendable {
    public var roots: [SelectionTreeNode]
    public var items: [IndexedItem]

    public init(items: [IndexedItem]) {
        let unique = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.items = unique.values.sorted(by: Self.sortItems)

        var directoryIDByPath: [String: String] = [:]
        for item in self.items where item.isDirectory {
            let path = normalizedSelectionPath(item.relativePath)
            if let existing = directoryIDByPath[path] {
                directoryIDByPath[path] = min(existing, item.id)
            } else {
                directoryIDByPath[path] = item.id
            }
        }

        var childIDs: [String: [String]] = [:]
        var rootIDs: [String] = []
        for item in self.items {
            let path = normalizedSelectionPath(item.relativePath)
            let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
            if !parentPath.isEmpty,
                let parentID = directoryIDByPath[parentPath],
                parentID != item.id
            {
                childIDs[parentID, default: []].append(item.id)
            } else {
                rootIDs.append(item.id)
            }
        }

        let byID = unique
        func makeNode(_ id: String, ancestry: Set<String>) -> SelectionTreeNode? {
            guard let item = byID[id] else { return nil }
            guard !ancestry.contains(id) else { return SelectionTreeNode(item: item) }
            var next = ancestry
            next.insert(id)
            let children = (childIDs[id] ?? []).compactMap { makeNode($0, ancestry: next) }
                .sorted { Self.sortItems($0.item, $1.item) }
            return SelectionTreeNode(item: item, children: children)
        }
        roots = rootIDs.compactMap { makeNode($0, ancestry: []) }
            .sorted { Self.sortItems($0.item, $1.item) }
    }

    public func search(_ query: String) -> [IndexedItem] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !tokens.isEmpty else { return items }
        return items.filter { item in
            let haystack = normalizedSelectionPath(item.relativePath).lowercased()
            return tokens.allSatisfy(haystack.contains)
        }
    }

    private static func sortItems(_ lhs: IndexedItem, _ rhs: IndexedItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        let left = normalizedSelectionPath(lhs.relativePath).lowercased()
        let right = normalizedSelectionPath(rhs.relativePath).lowercased()
        return left == right ? lhs.id < rhs.id : left < right
    }
}

public func normalizedSelectionPath(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "/")
        .split(separator: "/", omittingEmptySubsequences: true)
        .joined(separator: "/")
}

public func selectionPath(_ path: String, isDescendantOf ancestor: String) -> Bool {
    guard !ancestor.isEmpty else { return !path.isEmpty }
    return path.hasPrefix(ancestor + "/")
}
