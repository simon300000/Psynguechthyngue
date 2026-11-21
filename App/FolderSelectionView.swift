import PsyCore
import SwiftUI

struct FolderSelectionView: View {
    @Environment(AppModel.self) private var model
    let folder: FolderRecord
    let items: [IndexedItem]
    let baselineGeneration: UInt64

    @State private var workingPlan: FolderSelectionPlan
    @State private var savedPlan: FolderSelectionPlan
    @State private var preview: SelectionPlanPreview?
    @State private var previewError: String?
    @State private var draftStatus: String?
    @State private var hasPersistedDraft = false
    @State private var appliedPolicy: ContentRetentionFolderPolicy?
    @State private var hasLoadedAppliedPolicy = false
    @State private var appliedPolicyIssue: String?
    @State private var operationStatus: String?
    @State private var operationError: String?
    @State private var isChangingAppliedPolicy = false
    @State private var pendingConfirmation: PendingSelectionConfirmation?

    private let snapshotPlan: FolderSelectionPlan

    init(folder: FolderRecord, items: [IndexedItem], baselineGeneration: UInt64) {
        self.folder = folder
        self.items = items
        self.baselineGeneration = baselineGeneration
        let initial = FolderSelectionPlan(snapshotMode: folder.selectionMode)
        snapshotPlan = initial
        _workingPlan = State(initialValue: initial)
        _savedPlan = State(initialValue: initial)
    }

    var body: some View {
        Form {
            Section("Content Mode") {
                Picker("Mode", selection: $workingPlan.mode) {
                    ForEach(FolderContentSelectionMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                Text(workingPlan.mode.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(selectionBoundaryDescription)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }

            modeEditor

            Section("Application Preview") {
                if let preview {
                    LabeledContent("Indexed files", value: preview.indexedFiles.formatted())
                    LabeledContent("Matched files", value: preview.matchedFiles.formatted())
                    LabeledContent("Matched size", value: preview.matchedBytes, format: .byteCount(style: .file))
                    LabeledContent("Potential download", value: preview.downloadBytes, format: .byteCount(style: .file))
                    LabeledContent(
                        "Releasable local space", value: preview.releasableBytes, format: .byteCount(style: .file))
                    Text(
                        "This preview changes only which mobile copies are kept downloaded. It never changes, parses, or rewrites .stignore."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else if let previewError {
                    Label(previewError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else {
                    ProgressView("Calculating preview")
                }
            }

            Section("Applied Policy") {
                if !hasLoadedAppliedPolicy {
                    ProgressView("Loading applied policy")
                } else if let appliedPolicy {
                    LabeledContent("Backend", value: String(localized: "Local retention store"))
                    LabeledContent("Applied generation", value: appliedPolicy.generation.formatted())
                    Label(
                        "The retention policy is stored independently. The user-owned .stignore file remains byte-for-byte untouched.",
                        systemImage: "checkmark.shield"
                    )
                    .foregroundStyle(.green)

                    if let previous = appliedPolicy.previousPlan {
                        Button("Roll Back to Previous Applied Version", systemImage: "arrow.uturn.backward.circle") {
                            beginRollback(to: previous)
                        }
                        .disabled(appliedPolicyIssue != nil || isChangingAppliedPolicy)
                        .accessibilityHint(
                            "Restores the previous keep-downloaded policy as a new generation."
                        )
                    }
                } else if appliedPolicyIssue == nil {
                    Text("No retention policy has been applied for this folder.")
                        .foregroundStyle(.secondary)
                }

                if let appliedPolicyIssue {
                    Label(appliedPolicyIssue, systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.red)
                    Text(
                        "Apply and rollback are disabled until the retention state and folder incarnation can be verified."
                    )
                    .font(.footnote)
                    .foregroundStyle(.red)
                }

                Button("Reload Applied State", systemImage: "arrow.clockwise") {
                    Task {
                        await loadAppliedPolicy()
                        await refreshPreview()
                    }
                }
                .disabled(isChangingAppliedPolicy)
            }

            Section("Draft") {
                Button("Save Local Draft", systemImage: "square.and.arrow.down") {
                    Task { await saveDraft(plan: workingPlan, announceSuccess: true) }
                }
                .disabled(workingPlan == savedPlan && hasPersistedDraft)
                .keyboardShortcut("s", modifiers: [.command])
                .accessibilityHint("Saves only a local draft and does not queue a core command.")

                if supportsRetentionApplication {
                    Button("Apply Retention Policy", systemImage: "checkmark.shield") {
                        beginApplication()
                    }
                    .disabled(
                        preview == nil || !workingPlan.validate().isEmpty || !hasLoadedAppliedPolicy
                            || appliedPolicyIssue != nil || isChangingAppliedPolicy
                    )
                    .accessibilityHint(
                        "Atomically records which indexed items should remain downloaded without changing Syncthing ignore rules."
                    )
                }

                if workingPlan != savedPlan {
                    Button("Roll Back Unsaved Changes", systemImage: "arrow.uturn.backward") {
                        workingPlan = savedPlan
                        draftStatus = String(localized: "Unsaved changes were rolled back to the last local draft.")
                    }
                }

                Button("Restore Snapshot Mode", systemImage: "clock.arrow.circlepath") {
                    workingPlan = snapshotPlan
                    draftStatus = String(
                        localized:
                            "The editor was restored to the mode reported by the current snapshot. Save to keep this as a draft."
                    )
                }

                if let draftStatus {
                    Text(draftStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if isChangingAppliedPolicy {
                    ProgressView("Changing applied policy")
                }
                if let operationStatus {
                    Label(operationStatus, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                if let operationError {
                    Label(operationError, systemImage: "xmark.octagon")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Content Selection")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadAppliedPolicy()
            await loadDraft()
            await refreshPreview()
        }
        .task(id: workingPlan) { await refreshPreview() }
        .sheet(item: $pendingConfirmation) { pending in
            SelectionConfirmationView(
                confirmation: pending.preview.confirmation,
                purpose: pending.purpose
            ) { acknowledged, phrase in
                pendingConfirmation = nil
                Task {
                    switch pending.purpose {
                    case .apply:
                        await applySelection(
                            preview: pending.preview,
                            acknowledged: acknowledged,
                            typedPhrase: phrase
                        )
                    case .rollback:
                        await rollbackSelection(
                            preview: pending.preview,
                            acknowledged: acknowledged,
                            typedPhrase: phrase
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modeEditor: some View {
        switch workingPlan.mode {
        case .manualSelection:
            Section("Manual File Tree") {
                NavigationLink {
                    FolderSelectionTreeView(
                        plan: $workingPlan,
                        items: items,
                        generation: baselineGeneration
                    )
                } label: {
                    Label("Search and Select Files", systemImage: "checklist")
                }
                LabeledContent("Explicit directives", value: workingPlan.manualDirectives.count.formatted())
                Text(
                    "A directory choice applies to its current descendants and future children until a more specific choice overrides it."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        case .globRules, .regexRules:
            if let syntax = workingPlan.activeRuleSyntax {
                Section(syntax == .syncthingGlob ? "Ordered Glob Rules" : "Ordered Regex Rules") {
                    NavigationLink {
                        RuleEditorView(
                            plan: $workingPlan,
                            syntax: syntax,
                            rollbackRules: savedPlan.rules(for: syntax),
                            items: items
                        )
                    } label: {
                        Label("Edit \(workingPlan.rules(for: syntax).count) Rules", systemImage: "list.number")
                    }
                    if let firstIssue = workingPlan.validate().first {
                        Label(firstIssue.localizedDescription, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    Text(
                        syntax == .syncthingGlob
                            ? "Rules use Syncthing-style glob syntax and first-match order. They are never interpreted as regular expressions."
                            : "Rules use the existing RE2-safe regular-expression validator and first-match order. They are never converted to globs."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        case .fullSync, .indexOnly, .onDemand, .pinnedOffline:
            Section("Mode Scope") {
                LabeledContent("Indexed snapshot entries", value: items.count.formatted())
                Text(workingPlan.mode.scopeExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshPreview() async {
        let proposed = workingPlan
        let previous = appliedPolicy?.plan ?? snapshotPlan
        let source = items
        do {
            let calculated = try await Task.detached(priority: .utility) {
                try proposed.preview(items: source, comparedTo: previous)
            }.value
            try Task.checkCancellation()
            preview = calculated
            previewError = nil
        } catch is CancellationError {
            return
        } catch {
            preview = nil
            previewError = error.localizedDescription
        }
    }

    private var supportsRetentionApplication: Bool {
        true
    }

    private var selectionBoundaryDescription: String {
        switch workingPlan.mode {
        case .fullSync:
            return String(localized: "Full Sync keeps the entire folder downloaded on this device.")
        case .manualSelection:
            return String(
                localized:
                    "Manual Selection keeps checked indexed files and directories downloaded; directory choices also apply to future descendants."
            )
        case .globRules:
            return String(
                localized:
                    "Glob rules select indexed items to keep downloaded. They are evaluated by the App and never become Syncthing ignore patterns."
            )
        case .regexRules:
            return String(
                localized:
                    "RE2-compatible Regex rules select global-index items to keep downloaded and never modify .stignore."
            )
        case .indexOnly:
            return String(
                localized:
                    "Index Only maintains global-index placeholders without proactively keeping file contents downloaded."
            )
        case .onDemand:
            return String(
                localized:
                    "On Demand downloads a verified version when opened, but does not automatically pin the materialized copy."
            )
        case .pinnedOffline:
            return String(
                localized:
                    "Pinned Offline keeps the entire folder downloaded and proactively refreshes retained files when versions change."
            )
        }
    }

    private func loadAppliedPolicy() async {
        hasLoadedAppliedPolicy = false
        appliedPolicy = nil
        appliedPolicyIssue = nil
        do {
            let context = try model.retentionApplicationContext(for: folder)
            let folderID = folder.id
            let loaded = try await Task.detached(priority: .utility) {
                try context.store.folderPolicy(
                    folderID: folderID,
                    folderIncarnationDigest: context.folderIncarnationDigest
                )
            }.value
            appliedPolicy = loaded
        } catch {
            appliedPolicyIssue = localizedSelectionError(error)
        }
        hasLoadedAppliedPolicy = true
    }

    private func loadDraft() async {
        do {
            let store = try draftStore()
            let folderID = folder.id
            let loaded = try await Task.detached(priority: .utility) {
                try store.load(folderID: folderID)
            }.value
            guard let loaded else {
                if let appliedPolicy {
                    workingPlan = appliedPolicy.plan
                    savedPlan = appliedPolicy.plan
                    draftStatus = String(localized: "No saved draft. The editor starts from the applied policy.")
                } else {
                    draftStatus = String(localized: "No saved draft. The editor starts from the current snapshot mode.")
                }
                return
            }
            workingPlan = loaded.plan
            savedPlan = loaded.plan
            hasPersistedDraft = true
            if loaded.baselineGeneration == baselineGeneration {
                draftStatus = String(localized: "Loaded a local draft. Applied state is shown separately above.")
            } else {
                draftStatus = String(
                    localized:
                        "Loaded a draft from snapshot generation \(loaded.baselineGeneration). Review the new preview before applying it."
                )
            }
        } catch {
            draftStatus = String(localized: "The local draft could not be loaded: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func saveDraft(plan: FolderSelectionPlan, announceSuccess: Bool) async -> Bool {
        do {
            let store = try draftStore()
            let draft = FolderSelectionDraft(
                folderID: folder.id,
                baselineGeneration: baselineGeneration,
                plan: plan
            )
            try await Task.detached(priority: .utility) { try store.save(draft) }.value
            savedPlan = plan
            hasPersistedDraft = true
            if announceSuccess {
                draftStatus = String(localized: "Local draft saved. Nothing was sent to the Syncthing core.")
            }
            return true
        } catch {
            draftStatus = String(localized: "The local draft could not be saved: \(error.localizedDescription)")
            return false
        }
    }

    private func beginApplication() {
        guard let preview else { return }
        if preview.confirmation.requiresAcknowledgement {
            pendingConfirmation = PendingSelectionConfirmation(purpose: .apply, preview: preview)
        } else {
            Task {
                await applySelection(preview: preview, acknowledged: true, typedPhrase: "")
            }
        }
    }

    private func applySelection(
        preview: SelectionPlanPreview,
        acknowledged: Bool,
        typedPhrase: String
    ) async {
        guard supportsRetentionApplication,
            hasLoadedAppliedPolicy,
            appliedPolicyIssue == nil,
            !isChangingAppliedPolicy
        else {
            return
        }
        isChangingAppliedPolicy = true
        operationStatus = nil
        operationError = nil
        defer { isChangingAppliedPolicy = false }

        do {
            let context = try model.retentionApplicationContext(for: folder)
            let plan = workingPlan
            let expectedGeneration = appliedPolicy?.generation ?? 0
            let folderID = folder.id
            guard
                preview.confirmation.accepts(
                    acknowledged: acknowledged,
                    typedPhrase: typedPhrase
                )
            else {
                throw SelectionPlanError.confirmationRequired
            }
            let policy = try await Task.detached(priority: .userInitiated) {
                try context.store.applyPlan(
                    folderID: folderID,
                    folderIncarnationDigest: context.folderIncarnationDigest,
                    expectedGeneration: expectedGeneration,
                    plan: plan
                )
            }.value

            appliedPolicy = policy
            appliedPolicyIssue = nil
            _ = await saveDraft(plan: plan, announceSuccess: false)
            await reconcileAppliedRetentionPolicy()
            await refreshPreview()
        } catch {
            operationError = localizedSelectionError(error)
            if case .generationCollision = error as? ContentRetentionStoreError {
                let conflictMessage = operationError
                await loadAppliedPolicy()
                await refreshPreview()
                operationError = conflictMessage
            }
        }
    }

    private func beginRollback(to plan: FolderSelectionPlan) {
        guard let current = appliedPolicy, !isChangingAppliedPolicy else { return }
        let source = items
        Task {
            do {
                let rollbackPreview = try await Task.detached(priority: .utility) {
                    try plan.preview(items: source, comparedTo: current.plan)
                }.value
                if rollbackPreview.confirmation.requiresAcknowledgement {
                    pendingConfirmation = PendingSelectionConfirmation(
                        purpose: .rollback,
                        preview: rollbackPreview
                    )
                } else {
                    await rollbackSelection(
                        preview: rollbackPreview,
                        acknowledged: true,
                        typedPhrase: ""
                    )
                }
            } catch {
                operationError = localizedSelectionError(error)
            }
        }
    }

    private func rollbackSelection(
        preview: SelectionPlanPreview,
        acknowledged: Bool,
        typedPhrase: String
    ) async {
        guard let current = appliedPolicy,
            current.previousPlan != nil,
            hasLoadedAppliedPolicy,
            appliedPolicyIssue == nil,
            !isChangingAppliedPolicy
        else {
            return
        }
        isChangingAppliedPolicy = true
        operationStatus = nil
        operationError = nil
        defer { isChangingAppliedPolicy = false }

        do {
            let context = try model.retentionApplicationContext(for: folder)
            guard let previous = current.previousPlan,
                preview.confirmation.accepts(
                    acknowledged: acknowledged,
                    typedPhrase: typedPhrase
                )
            else {
                throw SelectionPlanError.confirmationRequired
            }
            let folderID = folder.id
            let policy = try await Task.detached(priority: .userInitiated) {
                try context.store.applyPlan(
                    folderID: folderID,
                    folderIncarnationDigest: context.folderIncarnationDigest,
                    expectedGeneration: current.generation,
                    plan: previous
                )
            }.value

            appliedPolicy = policy
            appliedPolicyIssue = nil
            workingPlan = policy.plan
            _ = await saveDraft(plan: policy.plan, announceSuccess: false)
            await reconcileAppliedRetentionPolicy()
            await refreshPreview()
        } catch {
            operationError = localizedSelectionError(error)
            if case .generationCollision = error as? ContentRetentionStoreError {
                let conflictMessage = operationError
                await loadAppliedPolicy()
                await refreshPreview()
                operationError = conflictMessage
            }
        }
    }

    private func localizedSelectionError(_ error: Error) -> String {
        guard let retentionError = error as? ContentRetentionStoreError else {
            return String(localized: "Selection change was not applied: \(error.localizedDescription)")
        }
        switch retentionError {
        case .generationCollision(let current, let expected):
            return String(
                localized:
                    "The applied retention policy is generation \(current), but this editor expected generation \(expected). The current state was reloaded; review the preview before retrying."
            )
        case .folderIncarnationMismatch:
            return String(localized: "The folder incarnation changed. No retention state was applied.")
        default:
            return String(localized: "The retention store rejected this change and kept the previous state.")
        }
    }

    private func reconcileAppliedRetentionPolicy() async {
        let advanced = await FileProviderStorageActionService().reconcilePendingWork(
            trigger: .user,
            maximumItems: 32
        )
        _ = await FileProviderDomainManager.signalWorkingSetChanges()
        await model.refreshContentRetentionProjection()
        operationStatus =
            advanced
            ? String(
                localized:
                    "The keep-downloaded policy was applied and its first reconciliation pass completed. Syncthing ignore rules were not changed."
            )
            : String(
                localized:
                    "The keep-downloaded policy was applied. Some retained files remain durable for a later retry. Syncthing ignore rules were not changed."
            )
    }

    private func draftStore() throws -> FolderSelectionDraftStore {
        let root = try SharedContainerPaths.resolve().root
            .appendingPathComponent("Metadata/SelectionDrafts", isDirectory: true)
        return FolderSelectionDraftStore(root: root)
    }
}

private struct FolderSelectionTreeView: View {
    @Binding var plan: FolderSelectionPlan
    let items: [IndexedItem]
    let generation: UInt64

    @State private var searchText = ""
    @State private var batchMode = false
    @State private var markedItemIDs: Set<String> = []
    @State private var preparedTree: SelectionFileTree?
    @State private var treeGeneration = 0
    @State private var searchResults: [IndexedItem] = []
    @State private var isSearching = false
    @State private var manualProjection: ManualSelectionProjection?
    @State private var projectedPlan: FolderSelectionPlan?
    @State private var isApplyingBatch = false

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleItems: [IndexedItem] {
        normalizedSearch.isEmpty ? preparedTree?.items ?? [] : searchResults
    }

    private var selectionDataIsCurrent: Bool {
        preparedTree != nil && manualProjection != nil && projectedPlan == plan
    }

    var body: some View {
        List {
            if normalizedSearch.isEmpty, let preparedTree {
                OutlineGroup(preparedTree.roots, children: \.outlineChildren) { node in
                    row(for: node.item)
                }
            } else {
                ForEach(visibleItems) { item in row(for: item) }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Indexed Files",
                    systemImage: "doc.questionmark",
                    description: Text(
                        "The current snapshot has no file tree for this folder. You can still save a mode draft.")
                )
            } else if preparedTree == nil {
                ProgressView("Preparing indexed file tree")
            } else if !selectionDataIsCurrent {
                ProgressView("Updating selection state")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if isSearching {
                ProgressView("Searching indexed files")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle("Manual Selection")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search relative paths")
        .task(id: generation) { await prepareTree() }
        .task(id: ManualSelectionSearchRequest(query: searchText, treeGeneration: treeGeneration)) {
            await refreshSearchResults()
        }
        .task(
            id: ManualSelectionProjectionRequest(
                plan: plan,
                treeGeneration: treeGeneration
            )
        ) {
            await refreshManualProjection()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(batchMode ? "Done" : "Select Multiple") {
                    batchMode.toggle()
                    if !batchMode { markedItemIDs.removeAll() }
                }
                .disabled(preparedTree == nil || isApplyingBatch)
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu("Selection", systemImage: "checkmark.circle") {
                    Button("Select All Files") { plan.selectAllManually() }
                    Button("Deselect All Files") { plan.deselectAllManually() }
                    Button("Invert Selection") { plan.invertManualSelection() }
                }
                .disabled(isApplyingBatch)
            }
            if batchMode {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Mark Visible") { markVisibleItems() }
                        .disabled(visibleItems.isEmpty || isApplyingBatch)
                    Button("Include") { applyBatch(.included) }
                        .disabled(markedItemIDs.isEmpty || !selectionDataIsCurrent || isApplyingBatch)
                    Button("Exclude") { applyBatch(.excluded) }
                        .disabled(markedItemIDs.isEmpty || !selectionDataIsCurrent || isApplyingBatch)
                }
            }
        }
    }

    private func row(for item: IndexedItem) -> some View {
        let itemName = item.relativePath.split(separator: "/").last.map(String.init) ?? item.relativePath
        return HStack(spacing: 12) {
            Button {
                toggleContentSelection(for: item)
            } label: {
                Image(systemName: selectionSymbol(for: item))
                    .foregroundStyle(selectionColor(for: item))
            }
            .buttonStyle(.borderless)
            .disabled(!selectionDataIsCurrent || isApplyingBatch)
            .accessibilityLabel(Text(String(localized: "Selection for \(itemName)")))
            .accessibilityValue(Text(selectionAccessibilityValue(for: item)))
            .accessibilityHint("Double-tap to toggle whether this item is included.")

            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(itemName)
                Text(item.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !item.isDirectory {
                Text(item.size, format: .byteCount(style: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if batchMode {
                Button {
                    if markedItemIDs.contains(item.id) {
                        markedItemIDs.remove(item.id)
                    } else {
                        markedItemIDs.insert(item.id)
                    }
                } label: {
                    Image(systemName: markedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.borderless)
                .disabled(isApplyingBatch)
                .accessibilityLabel(markedItemIDs.contains(item.id) ? "Remove from batch" : "Add to batch")
                .accessibilityHint("Changes only the current batch mark; it does not change inclusion yet.")
            }
        }
        .contextMenu {
            Button("Include", systemImage: "checkmark.circle") {
                plan.setManualValue(.included, for: item.relativePath, isDirectory: item.isDirectory)
            }
            .disabled(!selectionDataIsCurrent || isApplyingBatch)
            Button("Exclude", systemImage: "nosign") {
                plan.setManualValue(.excluded, for: item.relativePath, isDirectory: item.isDirectory)
            }
            .disabled(!selectionDataIsCurrent || isApplyingBatch)
        }
    }

    private func toggleContentSelection(for item: IndexedItem) {
        guard selectionDataIsCurrent else { return }
        let value: ManualSelectionValue
        if item.isDirectory {
            value =
                manualProjection?.directoryState(itemID: item.id) == .included
                ? .excluded
                : .included
        } else {
            value =
                manualProjection?.value(itemID: item.id) == .included
                ? .excluded
                : .included
        }
        plan.setManualValue(value, for: item.relativePath, isDirectory: item.isDirectory)
    }

    private func selectionSymbol(for item: IndexedItem) -> String {
        guard selectionDataIsCurrent else { return "hourglass" }
        if item.isDirectory {
            switch manualProjection?.directoryState(itemID: item.id) {
            case .included: return "checkmark.square.fill"
            case .excluded: return "square"
            case .mixed: return "minus.square.fill"
            case nil: return "square"
            }
        }
        return manualProjection?.value(itemID: item.id) == .included
            ? "checkmark.square.fill"
            : "square"
    }

    private func selectionColor(for item: IndexedItem) -> Color {
        guard selectionDataIsCurrent else { return .secondary }
        if item.isDirectory,
            manualProjection?.directoryState(itemID: item.id) == .mixed
        {
            return .orange
        }
        return manualProjection?.value(itemID: item.id) == .included
            ? .accentColor
            : .secondary
    }

    private func selectionAccessibilityValue(for item: IndexedItem) -> String {
        guard selectionDataIsCurrent else { return String(localized: "Selection state is updating") }
        if item.isDirectory {
            switch manualProjection?.directoryState(itemID: item.id) {
            case .included: return String(localized: "Directory is included")
            case .excluded: return String(localized: "Directory is excluded")
            case .mixed: return String(localized: "Directory has mixed selection")
            case nil: return String(localized: "Directory is excluded")
            }
        }
        return manualProjection?.value(itemID: item.id) == .included
            ? String(localized: "File is included")
            : String(localized: "File is excluded")
    }

    private func prepareTree() async {
        preparedTree = nil
        manualProjection = nil
        projectedPlan = nil
        searchResults = []
        markedItemIDs.removeAll()
        let source = items
        let tree = await Task.detached(priority: .userInitiated) {
            SelectionFileTree(items: source)
        }.value
        guard !Task.isCancelled else { return }
        preparedTree = tree
        treeGeneration &+= 1
    }

    private func refreshSearchResults() async {
        let query = normalizedSearch
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(150))
            guard let tree = preparedTree else { return }
            isSearching = true
            let results = await Task.detached(priority: .userInitiated) {
                tree.search(query)
            }.value
            try Task.checkCancellation()
            searchResults = results
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            isSearching = false
        }
    }

    private func refreshManualProjection() async {
        guard preparedTree != nil else { return }
        let source = items
        let requestedPlan = plan
        let projection = await Task.detached(priority: .userInitiated) {
            requestedPlan.manualSelectionProjection(items: source)
        }.value
        guard !Task.isCancelled, plan == requestedPlan else { return }
        manualProjection = projection
        projectedPlan = requestedPlan
    }

    private func markVisibleItems() {
        guard !isApplyingBatch else { return }
        let source = visibleItems
        isApplyingBatch = true
        Task {
            let identifiers = await Task.detached(priority: .userInitiated) {
                Set(source.map(\.id))
            }.value
            markedItemIDs.formUnion(identifiers)
            isApplyingBatch = false
        }
    }

    private func applyBatch(_ value: ManualSelectionValue) {
        guard selectionDataIsCurrent, !isApplyingBatch else { return }
        let source = preparedTree?.items ?? items
        let identifiers = markedItemIDs
        let requestedPlan = plan
        isApplyingBatch = true
        Task {
            let updated = await Task.detached(priority: .userInitiated) {
                var updated = requestedPlan
                updated.setManualValue(value, forItemIDs: identifiers, items: source)
                return updated
            }.value
            guard plan == requestedPlan else {
                isApplyingBatch = false
                return
            }
            plan = updated
            markedItemIDs.removeAll()
            isApplyingBatch = false
        }
    }
}

private struct ManualSelectionSearchRequest: Hashable {
    let query: String
    let treeGeneration: Int
}

private struct ManualSelectionProjectionRequest: Hashable {
    let plan: FolderSelectionPlan
    let treeGeneration: Int
}

private enum SelectionConfirmationPurpose {
    case apply
    case rollback
}

private struct PendingSelectionConfirmation: Identifiable {
    let id = UUID()
    let purpose: SelectionConfirmationPurpose
    let preview: SelectionPlanPreview
}

private struct SelectionConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    let confirmation: SelectionChangeConfirmation
    let purpose: SelectionConfirmationPurpose
    let onConfirm: (Bool, String) -> Void

    @State private var acknowledged = false
    @State private var typedPhrase = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Review Risks") {
                    ForEach(confirmation.risks) { risk in
                        riskRow(risk)
                    }
                }
                Section("Confirmation") {
                    Toggle(acknowledgementTitle, isOn: $acknowledged)
                    if let phrase = confirmation.requiredPhrase {
                        TextField("Type \(phrase)", text: $typedPhrase)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Text(confirmationFootnote(phrase: phrase))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) { onConfirm(acknowledged, typedPhrase) }
                        .disabled(!confirmation.accepts(acknowledged: acknowledged, typedPhrase: typedPhrase))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var acknowledgementTitle: String {
        switch purpose {
        case .apply:
            String(
                localized:
                    "I reviewed the affected files and understand this changes which content is kept downloaded on this device."
            )
        case .rollback:
            String(
                localized:
                    "I reviewed the affected files and understand this restores the previous policy as a new applied generation."
            )
        }
    }

    private var navigationTitle: String {
        switch purpose {
        case .apply: String(localized: "Confirm Application")
        case .rollback: String(localized: "Confirm Rollback")
        }
    }

    private var actionTitle: String {
        switch purpose {
        case .apply: String(localized: "Apply")
        case .rollback: String(localized: "Restore")
        }
    }

    private func confirmationFootnote(phrase: String) -> String {
        switch purpose {
        case .apply:
            String(
                localized:
                    "Type `\(phrase)` exactly. Applying may download or release local content without changing Syncthing ignore rules."
            )
        case .rollback:
            String(
                localized: "Type `\(phrase)` exactly. Restoring changes only this device's keep-downloaded policy.")
        }
    }

    private func riskRow(_ risk: SelectionChangeRisk) -> some View {
        let icon = risk.severity == .destructive ? "exclamationmark.triangle.fill" : "externaldrive"
        let color: Color = risk.severity == .destructive ? .red : .orange
        return Label {
            VStack(alignment: .leading) {
                Text(risk.kind.title)
                if risk.affectedFiles > 0 {
                    Text("\(risk.affectedFiles) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if risk.affectedBytes > 0 {
                    Text(risk.affectedBytes, format: .byteCount(style: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(color)
    }
}

extension FolderContentSelectionMode {
    fileprivate var requiresAuthoritativeSnapshot: Bool {
        switch self {
        case .regexRules, .indexOnly, .onDemand, .pinnedOffline: true
        case .fullSync, .manualSelection, .globRules: false
        }
    }

    fileprivate var title: String {
        switch self {
        case .fullSync: String(localized: "Full Sync")
        case .manualSelection: String(localized: "Manual Selection")
        case .globRules: String(localized: "Glob Rules")
        case .regexRules: String(localized: "RE2-safe Regex Rules")
        case .indexOnly: String(localized: "Index Only")
        case .onDemand: String(localized: "On Demand")
        case .pinnedOffline: String(localized: "Pinned Offline")
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .fullSync: "arrow.triangle.2.circlepath"
        case .manualSelection: "checklist"
        case .globRules: "asterisk"
        case .regexRules: "textformat.abc"
        case .indexOnly: "list.bullet.rectangle"
        case .onDemand: "icloud.and.arrow.down"
        case .pinnedOffline: "pin.fill"
        }
    }

    fileprivate var explanation: String {
        switch self {
        case .fullSync: String(localized: "Include every item and target all content for normal synchronization.")
        case .manualSelection:
            String(localized: "Include explicit files or directories; directory choices inherit to future children.")
        case .globRules:
            String(localized: "Evaluate ordered include/exclude Syncthing-style glob rules; the first match wins.")
        case .regexRules:
            String(localized: "Evaluate ordered include/exclude RE2-safe regular expressions; the first match wins.")
        case .indexOnly: String(localized: "Keep index metadata without targeting file contents for local storage.")
        case .onDemand:
            String(localized: "Index all items and fetch content when requested rather than keeping it offline.")
        case .pinnedOffline: String(localized: "Target all content for local materialization and offline retention.")
        }
    }

    fileprivate var scopeExplanation: String {
        switch self {
        case .fullSync: String(localized: "All indexed files are included and may require download.")
        case .indexOnly:
            String(
                localized:
                    "All names and metadata remain indexed; an exact Uploaded state makes a local download eligible for removal."
            )
        case .onDemand:
            String(localized: "All files remain addressable, but local copies are not required until requested.")
        case .pinnedOffline: String(localized: "All remote-only content contributes to the potential download preview.")
        case .manualSelection, .globRules, .regexRules: ""
        }
    }
}

extension SelectionChangeRiskKind {
    fileprivate var title: String {
        switch self {
        case .localCopiesMayBeReleased: String(localized: "Local copies may become releasable")
        }
    }
}
