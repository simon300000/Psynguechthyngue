import PsyCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ExternalDirectoriesView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var importingNamedChildParent = false
    @State private var namedChildName = ""
    @State private var pendingRemoval: ExternalDirectoryRecord?
    @State private var pendingDeletion: PendingExternalDeletion?
    @State private var pendingRecoveryDisposal: PendingRecoveryDisposal?
    @State private var recoveryExport: ControlledMirrorRecoveryExport?
    @State private var pendingRecoveryExport: ControlledMirrorRecoveryExport?
    @State private var requestedMode: ExternalDirectoryMode = .controlledMirror

    var body: some View {
        VStack(spacing: 0) {
            if runsAsIPadAppOnMac {
                namedChildCreationSection
            }
            Group {
                if model.externalDirectories.isEmpty {
                    ContentUnavailableView(
                        "No External Directories",
                        systemImage: "externaldrive.badge.plus",
                        description: Text(emptyDirectoryDescription)
                    )
                } else {
                    List {
                        ForEach(model.externalDirectories, id: \.id) { record in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label(record.displayName, systemImage: "externaldrive")
                                    Spacer()
                                    Picker(
                                        "Mode",
                                        selection: Binding(
                                            get: { record.mode },
                                            set: { mode in
                                                Task { await model.updateExternalDirectoryMode(record.id, mode: mode) }
                                            }
                                        )
                                    ) {
                                        ForEach(
                                            ExternalDirectoryAccessBroker.allowedModes(for: record.capabilities),
                                            id: \.self
                                        ) { mode in
                                            Text(modeTitle(mode)).tag(mode)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .accessibilityLabel("Mirror mode")
                                    .accessibilityValue(Text(modeTitle(record.mode)))
                                    .accessibilityHint("Selects an allowed direction for future mirror runs.")
                                    .disabled(record.authorizationState == .revoked)
                                }
                                if record.authorizationState == .revoked {
                                    Label(
                                        "Files authorization removed; managed data and the Syncthing folder are retained.",
                                        systemImage: "externaldrive.badge.xmark"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                }
                                capabilitySummary(record.capabilities)
                                bindingSummary(record)
                                statusSummary(record.lastMirrorStatus)
                                if record.authorizationState == .active,
                                    !record.pendingDeletionConfirmations.isEmpty
                                {
                                    DisclosureGroup(
                                        "Review \(record.pendingDeletionConfirmations.count) deletion requests"
                                    ) {
                                        ForEach(record.pendingDeletionConfirmations) { confirmation in
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(confirmation.relativePath)
                                                    .font(.caption.monospaced())
                                                    .lineLimit(2)
                                                Text(deletionTargetDescription(confirmation.kind))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                HStack {
                                                    Button("Keep Surviving Copy") {
                                                        Task {
                                                            await model.resolveExternalDirectoryDeletion(
                                                                recordID: record.id,
                                                                confirmation: confirmation,
                                                                decision: .keepSurvivingCopy
                                                            )
                                                        }
                                                    }
                                                    .buttonStyle(.bordered)
                                                    .contextMenu {
                                                        Button("Keep with Temporary Policy Override") {
                                                            Task {
                                                                await model.resolveExternalDirectoryDeletion(
                                                                    recordID: record.id,
                                                                    confirmation: confirmation,
                                                                    decision: .keepSurvivingCopy,
                                                                    requestedTemporaryOverride: true
                                                                )
                                                            }
                                                        }
                                                    }
                                                    Button("Propagate Deletion", role: .destructive) {
                                                        pendingDeletion = PendingExternalDeletion(
                                                            recordID: record.id,
                                                            confirmation: confirmation
                                                        )
                                                    }
                                                    .buttonStyle(.bordered)
                                                }
                                            }
                                            .padding(.vertical, 4)
                                        }
                                    }
                                }
                                if let recoveryFailureCode =
                                    model.externalDirectoryRecoveryFailureCodes[record.id]
                                {
                                    Label(
                                        "Recovery unavailable: \(recoveryFailureCode)",
                                        systemImage: "archivebox.trianglebadge.exclamationmark"
                                    )
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.orange)
                                }
                                let recoveries = model.externalDirectoryRecoveries[record.id] ?? []
                                if !recoveries.isEmpty {
                                    DisclosureGroup("Review \(recoveries.count) recovery copies") {
                                        Text(
                                            "Recovery copies are retained by default. They are never restored or deleted automatically. Export creates a verified temporary snapshot for the system share sheet; it does not expose or change the retained source. Automatic in-place restore is not available."
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        ForEach(recoveries) { summary in
                                            recoverySummary(
                                                summary,
                                                recordID: record.id,
                                                operationIsRunning: model.runningExternalDirectoryIDs
                                                    .contains(record.id)
                                            )
                                        }
                                    }
                                }
                                HStack {
                                    if record.authorizationState == .active,
                                        record.syncBinding.phase != .verified
                                    {
                                        Button {
                                            Task { await model.repairExternalDirectoryBinding(record.id) }
                                        } label: {
                                            Label("Repair Binding", systemImage: "wrench.and.screwdriver")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .accessibilityHint(
                                            "Rechecks the exact managed root and queues a new add-folder command only when safe."
                                        )
                                    }
                                    Button {
                                        Task { await model.runExternalDirectoryMirror(record.id) }
                                    } label: {
                                        if model.runningExternalDirectoryIDs.contains(record.id) {
                                            ProgressView()
                                                .accessibilityHidden(true)
                                        } else {
                                            Label("Run Mirror", systemImage: "arrow.triangle.2.circlepath")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(
                                        record.authorizationState != .active
                                            || record.syncBinding.phase != .verified
                                            || record.mode == .readOnly
                                            || model.runningExternalDirectoryIDs.contains(record.id)
                                    )
                                    .accessibilityLabel(
                                        Text(
                                            model.runningExternalDirectoryIDs.contains(record.id)
                                                ? String(localized: "Mirror running")
                                                : String(localized: "Run Mirror")
                                        )
                                    )
                                    .accessibilityHint(
                                        "Copies only in the selected mode and preserves unconfirmed deletions.")
                                    if record.mode == .readOnly {
                                        Text("Read-only mode observes changes without copying files.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions {
                                if record.authorizationState == .active {
                                    Button("Remove Authorization", role: .destructive) {
                                        pendingRemoval = record
                                    }
                                }
                            }
                            .contextMenu {
                                Button("Run Mirror", systemImage: "arrow.triangle.2.circlepath") {
                                    Task { await model.runExternalDirectoryMirror(record.id) }
                                }
                                .disabled(
                                    record.authorizationState != .active
                                        || record.syncBinding.phase != .verified
                                        || record.mode == .readOnly
                                        || model.runningExternalDirectoryIDs.contains(record.id)
                                )
                                Button(
                                    "Run with Temporary Policy Override",
                                    systemImage: "arrow.triangle.2.circlepath.circle"
                                ) {
                                    Task {
                                        await model.runExternalDirectoryMirror(
                                            record.id,
                                            requestedTemporaryOverride: true
                                        )
                                    }
                                }
                                .disabled(
                                    record.authorizationState != .active
                                        || record.syncBinding.phase != .verified
                                        || record.mode == .readOnly
                                        || model.runningExternalDirectoryIDs.contains(record.id)
                                )
                                if record.authorizationState == .active {
                                    Button(
                                        "Remove Authorization",
                                        systemImage: "externaldrive.badge.xmark",
                                        role: .destructive
                                    ) {
                                        pendingRemoval = record
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("External Directories")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Picker("New Directory Mode", selection: $requestedMode) {
                    ForEach(ExternalDirectoryMode.productModes, id: \.self) { mode in
                        Text(modeTitle(mode)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityHint("Sets the requested mode for the next directory authorization.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importing = true
                } label: {
                    Label(
                        runsAsIPadAppOnMac ? "Choose Directory in Finder" : "Choose Directory",
                        systemImage: "plus"
                    )
                }
                .keyboardShortcut("n", modifiers: [.command])
                .accessibilityIdentifier("externalDirectoryChoose")
                .accessibilityHint(
                    runsAsIPadAppOnMac
                        ? "Opens the system Finder directory picker."
                        : "Opens the Files directory picker."
                )
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await model.authorizeExternalDirectory(url, requestedMode: requestedMode) }
            }
        }
        .fileImporter(isPresented: $importingNamedChildParent, allowedContentTypes: [.folder]) { result in
            if case .success(let parentURL) = result {
                Task {
                    let authorized = await model.authorizeNamedExternalDirectory(
                        in: parentURL,
                        name: namedChildName,
                        requestedMode: requestedMode
                    )
                    if authorized { namedChildName = "" }
                }
            }
        }
        .confirmationDialog(
            "Stop using this external directory?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Files Authorization", role: .destructive) {
                guard let id = pendingRemoval?.id else { return }
                Task { await model.removeExternalDirectory(id) }
            }
            .accessibilityHint(
                "Keeps external files, managed data, and the separately configured Syncthing folder."
            )
        } message: {
            if let pendingRemoval {
                Text(
                    "This erases the saved Files authorization. It does not delete external files or managed data, and it does not remove Syncthing folder \(pendingRemoval.syncBinding.folderID.rawValue). Remove that folder separately from Folders only if intended."
                )
            }
        }
        .sheet(
            item: $recoveryExport,
            onDismiss: { finishPendingRecoveryExport() },
            content: { export in
                RecoveryExportShareSheet(url: export.url) {
                    finishRecoveryExport(export)
                }
                .onDisappear { finishRecoveryExport(export) }
            }
        )
        .onDisappear { finishPendingRecoveryExport() }
        .confirmationDialog(
            "Propagate this deletion?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete the Unchanged Mirror Copy", role: .destructive) {
                guard let pendingDeletion else { return }
                self.pendingDeletion = nil
                Task {
                    await model.resolveExternalDirectoryDeletion(
                        recordID: pendingDeletion.recordID,
                        confirmation: pendingDeletion.confirmation,
                        decision: .propagateDeletion
                    )
                }
            }
            Button(
                "Delete with Temporary Policy Override",
                role: .destructive
            ) {
                guard let pendingDeletion else { return }
                self.pendingDeletion = nil
                Task {
                    await model.resolveExternalDirectoryDeletion(
                        recordID: pendingDeletion.recordID,
                        confirmation: pendingDeletion.confirmation,
                        decision: .propagateDeletion,
                        requestedTemporaryOverride: true
                    )
                }
            }
        } message: {
            if let pendingDeletion {
                Text(
                    "Only the unchanged copy at \(pendingDeletion.confirmation.relativePath) will be deleted. If either mirror root changed after this prompt was created, the operation fails without deleting anything."
                )
            }
        }
        .confirmationDialog(
            "Permanently delete this recovery copy?",
            isPresented: Binding(
                get: { pendingRecoveryDisposal != nil },
                set: { if !$0 { pendingRecoveryDisposal = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Permanently Delete Recovery Copy", role: .destructive) {
                guard let pendingRecoveryDisposal else { return }
                self.pendingRecoveryDisposal = nil
                Task {
                    await model.resolveExternalDirectoryRecovery(
                        recordID: pendingRecoveryDisposal.recordID,
                        summary: pendingRecoveryDisposal.summary,
                        decision: .deleteAfterUserConfirmation
                    )
                }
            }
        } message: {
            if let pendingRecoveryDisposal {
                Text(
                    "This permanently deletes only the exact retained recovery copy for \(pendingRecoveryDisposal.summary.relativePath). It cannot be undone. The current live mirror item is not restored, changed, or deleted. A provider may synchronize removal of its hidden recovery data."
                )
            }
        }
    }

    private var runsAsIPadAppOnMac: Bool {
        IOSAppOnMacEnvironment.current.allowsNamedChildCreation
    }

    private var emptyDirectoryDescription: String {
        if runsAsIPadAppOnMac {
            return String(
                localized: "Choose an existing or new directory in Finder. App sandbox boundaries still apply."
            )
        }
        return String(
            localized: "Choose a directory exposed through Files. Private app sandboxes are not accessible."
        )
    }

    private var namedChildNameIsValid: Bool {
        (try? ExternalDirectoryChildName(validating: namedChildName)) != nil
    }

    private var namedChildValidationMessage: String? {
        guard !namedChildName.isEmpty else { return nil }
        do {
            _ = try ExternalDirectoryChildName(validating: namedChildName)
            return nil
        } catch let error as ExternalDirectoryChildNameValidationError {
            return localizedExternalDirectoryChildNameError(error)
        } catch {
            return String(localized: "The folder name is invalid.")
        }
    }

    private var namedChildCreationSection: some View {
        GroupBox("Create or Use a Named Folder") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Finder selection remains the primary authorization flow. As a shortcut, enter one folder name, then choose its parent in Finder."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                TextField("New Folder Name", text: $namedChildName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("macNamedFolderName")
                if let namedChildValidationMessage {
                    Text(namedChildValidationMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Button("Choose Parent in Finder", systemImage: "folder.badge.plus") {
                    importingNamedChildParent = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!namedChildNameIsValid)
                .accessibilityIdentifier("macNamedFolderChooseParent")
                .accessibilityHint(
                    "Creates or reuses only that direct child after you authorize its parent."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding([.horizontal, .top])
        .accessibilityIdentifier("macNamedFolderSection")
    }

    private func recoverySummary(
        _ summary: ControlledMirrorRecoverySummary,
        recordID: UUID,
        operationIsRunning: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.relativePath)
                .font(.caption.monospaced())
                .lineLimit(3)
            HStack(spacing: 8) {
                Text(recoveryKindTitle(summary.kind))
                Text(recoveryPayloadTitle(summary.payloadKind))
                Text(ByteCountFormatter.string(fromByteCount: summary.byteCount, countStyle: .file))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(summary.createdAt, format: .dateTime.year().month().day().hour().minute())
                Text(recoveryStatusTitle(summary.status))
                if summary.isReferencedByActiveJournal {
                    Text("Required for mirror recovery")
                }
                Text("Digest \(String(summary.contentDigest.prefix(12)))")
                    .font(.caption2.monospaced())
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Button("Export Recovery Copy") {
                    Task {
                        if let export = await model.prepareExternalDirectoryRecoveryExport(
                            recordID: recordID,
                            summary: summary
                        ) {
                            pendingRecoveryExport = export
                            recoveryExport = export
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(operationIsRunning)
                .accessibilityHint(
                    "Creates a verified temporary snapshot and opens the system share sheet. The retained recovery copy stays unchanged."
                )
                HStack {
                    Button("Keep Recovery Copy") {
                        Task {
                            await model.resolveExternalDirectoryRecovery(
                                recordID: recordID,
                                summary: summary,
                                decision: .retain
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(operationIsRunning)
                    Button("Delete Recovery Copy", role: .destructive) {
                        pendingRecoveryDisposal = PendingRecoveryDisposal(
                            recordID: recordID,
                            summary: summary
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(operationIsRunning || summary.isReferencedByActiveJournal)
                }
            }
            if summary.isReferencedByActiveJournal {
                Text("Resume the mirror before deleting this recovery copy.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func finishRecoveryExport(_ export: ControlledMirrorRecoveryExport) {
        guard pendingRecoveryExport?.id == export.id else { return }
        pendingRecoveryExport = nil
        recoveryExport = nil
        Task { await model.discardExternalDirectoryRecoveryExport(export) }
    }

    private func finishPendingRecoveryExport() {
        guard let pendingRecoveryExport else { return }
        finishRecoveryExport(pendingRecoveryExport)
    }

    private func statusSummary(_ status: ExternalDirectoryMirrorStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Label("\(status.importedFiles) imported", systemImage: "arrow.down.doc")
                Label("\(status.exportedFiles) exported", systemImage: "arrow.up.doc")
                Label("\(status.conflictCount) conflicts", systemImage: "exclamationmark.triangle")
            }
            if status.deleteConfirmationCount > 0 {
                Label(
                    "\(status.deleteConfirmationCount) deletion requests need confirmation; no deletion was applied.",
                    systemImage: "hand.raised"
                )
                .foregroundStyle(.orange)
            } else if let failure = status.failureCode {
                Label("Retryable: \(failure.rawValue)", systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(.orange)
            } else {
                Text(phaseTitle(status.phase))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func bindingSummary(_ record: ExternalDirectoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            switch record.syncBinding.phase {
            case .verified:
                Label("Syncthing managed root verified", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
                Text("Folder ID: \(record.syncBinding.folderID.rawValue)")
                Text("Local-only binding; no peer was selected automatically.")
            case .queued:
                Label("Syncthing folder registration queued", systemImage: "clock.arrow.circlepath")
                Text("Not connected until a core snapshot verifies the exact managed root.")
            case .repairRequired:
                Label("Binding needs explicit repair", systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
                Text("Managed data was retained; the folder was not recreated automatically.")
            case .conflict:
                Label("Binding blocked by a path conflict", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.red)
                Text("No folder replacement or removal was queued.")
            case .failed:
                Label("Syncthing folder registration failed", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                Text("Managed data was retained. Repair creates a new durable command.")
            }
            if let failureCode = record.syncBinding.failureCode {
                Text("Binding code: \(failureCode)")
                    .font(.caption2.monospaced())
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func modeTitle(_ mode: ExternalDirectoryMode) -> String {
        switch mode {
        case .controlledMirror: String(localized: "Controlled Mirror")
        case .importOnly: String(localized: "Import Only")
        case .exportOnly: String(localized: "Export Only")
        case .readOnly: String(localized: "Read Only")
        case .direct: String(localized: "Direct")
        }
    }

    private func capabilitySummary(_ value: ExternalDirectoryCapabilities) -> some View {
        HStack(spacing: 12) {
            Label("Read", systemImage: value.canRead ? "checkmark.circle" : "xmark.circle")
            Label("Write", systemImage: value.canWrite ? "checkmark.circle" : "xmark.circle")
            Label("Rename", systemImage: value.canRename ? "checkmark.circle" : "xmark.circle")
            Label("Delete", systemImage: value.canDelete ? "checkmark.circle" : "xmark.circle")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(.iconOnly)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Directory capabilities")
        .accessibilityValue(
            Text(
                String(
                    localized:
                        "Read \(capabilityState(value.canRead)), write \(capabilityState(value.canWrite)), rename \(capabilityState(value.canRename)), delete \(capabilityState(value.canDelete))"
                )
            )
        )
    }

    private func phaseTitle(_ phase: ExternalDirectoryMirrorPhase) -> String {
        switch phase {
        case .neverRun: String(localized: "Never Run")
        case .running: String(localized: "Running")
        case .succeeded: String(localized: "Succeeded")
        case .requiresConfirmation: String(localized: "Needs Confirmation")
        case .retryableFailure: String(localized: "Retryable Failure")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    private func capabilityState(_ available: Bool) -> String {
        available ? String(localized: "available") : String(localized: "unavailable")
    }

    private func deletionTargetDescription(_ kind: ControlledMirrorConfirmationKind) -> String {
        switch kind {
        case .deleteManaged:
            String(localized: "The external source was deleted; approval removes the managed mirror copy.")
        case .deleteExternal:
            String(localized: "The managed source was deleted; approval removes the external provider copy.")
        }
    }

    private func recoveryKindTitle(_ kind: ControlledMirrorRecoveryKind) -> String {
        switch kind {
        case .copyBackup: String(localized: "Overwrite Backup")
        case .deleteQuarantine: String(localized: "Deletion Quarantine")
        }
    }

    private func recoveryPayloadTitle(_ kind: ControlledMirrorRecoveryPayloadKind) -> String {
        switch kind {
        case .file: String(localized: "File")
        case .directory: String(localized: "Directory")
        }
    }

    private func recoveryStatusTitle(_ status: ControlledMirrorRecoveryStatus) -> String {
        switch status {
        case .prepared: String(localized: "Prepared")
        case .retainedRequiresUserConfirmation: String(localized: "Retained")
        case .conflictRequiresManualCleanup: String(localized: "Conflict — Review Required")
        case .disposalApprovedPendingCleanup: String(localized: "Disposal Pending")
        }
    }
}

private struct PendingExternalDeletion: Identifiable {
    let recordID: UUID
    let confirmation: ControlledMirrorConfirmation

    var id: String { recordID.uuidString + ":" + confirmation.id }
}

private struct PendingRecoveryDisposal: Identifiable {
    let recordID: UUID
    let summary: ControlledMirrorRecoverySummary

    var id: String { recordID.uuidString + ":" + summary.id }
}

private struct RecoveryExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor () -> Void

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in completion() }
        }
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
