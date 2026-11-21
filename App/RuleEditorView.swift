import PsyCore
import SwiftUI

struct RuleEditorView: View {
    @Binding var plan: FolderSelectionPlan
    let syntax: SelectionRuleSyntax
    let rollbackRules: [SelectionRule]
    let items: [IndexedItem]

    @State private var editingRule: SelectionRule?
    @State private var confirmingRestore = false

    private var rules: [SelectionRule] { plan.rules(for: syntax) }

    var body: some View {
        List {
            Section {
                Text(syntaxExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(
                    "Rules are evaluated from top to bottom; the first enabled match wins. Include and exclude are explicit actions."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Rules") {
                ForEach(rules) { rule in
                    ruleButton(rule)
                }
                .onMove(perform: moveRules)

                if rules.isEmpty {
                    ContentUnavailableView(
                        "No Rules",
                        systemImage: "list.bullet",
                        description: Text("Add at least one enabled rule before preparing application arguments.")
                    )
                }
            }

            Section("Recovery") {
                Button("Roll Back to Saved Draft", systemImage: "arrow.uturn.backward") {
                    plan.setRules(rollbackRules, for: syntax)
                }
                .disabled(rules == rollbackRules)
                Button("Restore Safe Default", systemImage: "arrow.counterclockwise") {
                    confirmingRestore = true
                }
                .accessibilityHint("Opens a confirmation before replacing the current rule draft.")
                Text(defaultExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(syntax == .syncthingGlob ? "Glob Rules" : "Regex Rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add Rule", systemImage: "plus") {
                    Button("Include Rule", systemImage: "checkmark.circle") {
                        addRule(action: .include)
                    }
                    Button("Exclude Rule", systemImage: "nosign") {
                        addRule(action: .exclude)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            ToolbarItem(placement: .secondaryAction) { EditButton() }
        }
        .sheet(
            item: $editingRule,
            onDismiss: { editingRule = nil },
            content: { rule in
                NavigationStack {
                    RuleDetailEditor(rule: rule, items: items) { updated in
                        _ = plan.updateRule(updated)
                        editingRule = nil
                    }
                }
            }
        )
        .confirmationDialog(
            "Restore the default rule?",
            isPresented: $confirmingRestore,
            titleVisibility: .visible
        ) {
            Button("Restore Default", role: .destructive) { plan.restoreDefaultRules(for: syntax) }
        } message: {
            Text(
                String(
                    localized:
                        "This replaces only the current \(syntaxShortTitle) rule draft. It does not apply anything to the core."
                )
            )
        }
    }

    private func ruleRow(_ rule: SelectionRule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: rule.action == .include ? "checkmark.circle.fill" : "minus.circle.fill")
                .foregroundStyle(rule.action == .include ? .green : .red)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(ruleActionTitle(rule.action))
                        .font(.caption.weight(.semibold))
                    Text(ruleSyntaxTitle(rule.syntax))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(rule.pattern)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2)
                if case .failure(let error) = SelectionRuleEngine().validate(rule) {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if !rule.isEnabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .opacity(rule.isEnabled ? 1 : 0.6)
    }

    private func ruleButton(_ rule: SelectionRule) -> some View {
        Button {
            editingRule = rule
        } label: {
            ruleRow(rule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(rule.pattern))
        .accessibilityValue(Text(ruleAccessibilityValue(rule)))
        .accessibilityHint("Opens the rule editor.")
        .swipeActions(edge: .leading) {
            Button(rule.isEnabled ? "Disable" : "Enable") { toggle(rule) }
                .tint(rule.isEnabled ? .gray : .green)
            Button("Duplicate") { _ = plan.duplicateRule(id: rule.id, syntax: syntax) }
                .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) {
                _ = plan.removeRule(id: rule.id, syntax: syntax)
            }
        }
        .contextMenu {
            Button(rule.isEnabled ? "Disable" : "Enable") { toggle(rule) }
            Button("Duplicate") { _ = plan.duplicateRule(id: rule.id, syntax: syntax) }
            Button("Delete", role: .destructive) {
                _ = plan.removeRule(id: rule.id, syntax: syntax)
            }
        }
        .draggable(ruleDragPayload(rule))
        .dropDestination(
            for: String.self,
            action: { payloads, _ in
                moveDroppedRule(payloads, before: rule.id)
            },
            isTargeted: { _ in }
        )
    }

    private func addRule(action: SelectionRuleAction) {
        let id = plan.appendRule(syntax: syntax, action: action)
        let destination = max(0, plan.rules(for: syntax).count - 2)
        _ = plan.moveRule(id: id, syntax: syntax, to: destination)
        editingRule = plan.rules(for: syntax).first(where: { $0.id == id })
    }

    private func toggle(_ rule: SelectionRule) {
        var updated = rule
        updated.isEnabled.toggle()
        _ = plan.updateRule(updated)
    }

    private func moveRules(from offsets: IndexSet, to destination: Int) {
        var updated = rules
        updated.move(fromOffsets: offsets, toOffset: destination)
        plan.setRules(updated, for: syntax)
    }

    private func ruleDragPayload(_ rule: SelectionRule) -> String {
        "psy-selection-rule-v1|\(rule.syntax.rawValue)|\(rule.id.uuidString.lowercased())"
    }

    private func moveDroppedRule(_ payloads: [String], before targetID: UUID) -> Bool {
        guard payloads.count == 1,
            let sourceID = ruleID(fromDragPayload: payloads[0]),
            let sourceIndex = rules.firstIndex(where: { $0.id == sourceID }),
            let targetIndex = rules.firstIndex(where: { $0.id == targetID })
        else {
            return false
        }
        guard sourceID != targetID else { return true }
        let destination = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        return plan.moveRule(id: sourceID, syntax: syntax, to: destination)
    }

    private func ruleID(fromDragPayload payload: String) -> UUID? {
        let components = payload.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 3,
            components[0] == "psy-selection-rule-v1",
            components[1] == Substring(syntax.rawValue),
            let id = UUID(uuidString: String(components[2])),
            rules.contains(where: { $0.id == id })
        else {
            return nil
        }
        return id
    }

    private var syntaxExplanation: String {
        switch syntax {
        case .syncthingGlob:
            String(
                localized:
                    "This list accepts Syncthing-style glob tokens such as `*`, `**`, `?`, and character classes. Regex operators are not inferred."
            )
        case .re2SafeRegex:
            String(
                localized:
                    "This list accepts regular expressions only after the existing RE2-safe validator rejects lookaround, backreferences, and unsafe repetition. Glob syntax is not inferred."
            )
        }
    }

    private var defaultExplanation: String {
        syntax == .syncthingGlob
            ? String(localized: "The safe default is one enabled include rule: `**`.")
            : String(localized: "The safe default is one enabled include rule: `.*`.")
    }

    private var syntaxShortTitle: String {
        syntax == .syncthingGlob ? String(localized: "glob") : String(localized: "regex")
    }

    private func ruleAccessibilityValue(_ rule: SelectionRule) -> String {
        let enabled = rule.isEnabled ? String(localized: "Enabled") : String(localized: "Disabled")
        return String(
            localized: "\(ruleActionTitle(rule.action)), \(ruleSyntaxTitle(rule.syntax)), \(enabled)"
        )
    }
}

private struct RuleDetailEditor: View {
    @Environment(\.dismiss) private var dismiss
    let items: [IndexedItem]
    let onSave: (SelectionRule) -> Void

    @State private var rule: SelectionRule

    init(rule: SelectionRule, items: [IndexedItem], onSave: @escaping (SelectionRule) -> Void) {
        self.items = items
        self.onSave = onSave
        _rule = State(initialValue: rule)
    }

    private var validation: Result<Void, RuleValidationError> {
        SelectionRuleEngine().validate(rule)
    }

    private var matchPreview: RuleMatchPreview? {
        guard case .success = validation, rule.isEnabled else { return nil }
        let engine = SelectionRuleEngine()
        var count = 0
        var bytes: Int64 = 0
        var paths: [String] = []
        do {
            for item in items where !item.isDirectory {
                let evaluation = try engine.evaluate(path: item.relativePath, isDirectory: false, rules: [rule])
                guard evaluation.matchedRuleID == rule.id else { continue }
                count += 1
                bytes += item.size
                if paths.count < 20 { paths.append(item.relativePath) }
            }
            return RuleMatchPreview(count: count, bytes: bytes, paths: paths)
        } catch {
            return nil
        }
    }

    var body: some View {
        Form {
            Section("Rule") {
                LabeledContent(
                    "Syntax",
                    value: ruleSyntaxTitle(rule.syntax)
                )
                Picker("Action", selection: $rule.action) {
                    Text("Include").tag(SelectionRuleAction.include)
                    Text("Exclude").tag(SelectionRuleAction.exclude)
                }
                Toggle("Enabled", isOn: $rule.isEnabled)
                TextField(
                    rule.syntax == .syncthingGlob ? "Glob pattern" : "Regular expression",
                    text: $rule.pattern,
                    axis: .vertical
                )
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            Section("Validation") {
                switch validation {
                case .success:
                    Label(
                        String(localized: "Pattern is valid for \(ruleValidationSyntaxTitle(rule.syntax)) syntax."),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Text(
                    rule.syntax == .syncthingGlob
                        ? "This pattern is compiled only as a glob."
                        : "This pattern is validated as a regular expression; it is not rewritten as a glob."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Rule Preview") {
                if !rule.isEnabled {
                    Text("Enable the rule to preview matches.")
                        .foregroundStyle(.secondary)
                } else if let matchPreview {
                    LabeledContent("Matched files", value: matchPreview.count.formatted())
                    LabeledContent("Matched size", value: matchPreview.bytes, format: .byteCount(style: .file))
                    if matchPreview.paths.isEmpty {
                        Text("No current indexed file matches this rule.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matchPreview.paths, id: \.self) { path in
                            Text(path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        }
                        if matchPreview.count > matchPreview.paths.count {
                            Text("Showing the first \(matchPreview.paths.count) matches.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Fix validation errors to calculate the preview.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Edit Rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(rule) }
                    .disabled(
                        {
                            if case .success = validation { return false }
                            return true
                        }()
                    )
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private func ruleActionTitle(_ action: SelectionRuleAction) -> String {
    switch action {
    case .include: String(localized: "Include")
    case .exclude: String(localized: "Exclude")
    }
}

private func ruleSyntaxTitle(_ syntax: SelectionRuleSyntax) -> String {
    switch syntax {
    case .syncthingGlob: String(localized: "Syncthing Glob")
    case .re2SafeRegex: String(localized: "RE2-safe Regex")
    }
}

private func ruleValidationSyntaxTitle(_ syntax: SelectionRuleSyntax) -> String {
    switch syntax {
    case .syncthingGlob: String(localized: "glob")
    case .re2SafeRegex: String(localized: "RE2-safe regex")
    }
}

private struct RuleMatchPreview {
    var count: Int
    var bytes: Int64
    var paths: [String]
}
