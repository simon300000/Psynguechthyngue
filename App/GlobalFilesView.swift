import PsyCore
import SwiftUI
import UIKit

struct GlobalFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var pendingCacheEviction: IndexedItem?
    @State private var pendingSyncthingDeletion: IndexedItem?
    @State private var showsMutationRecoveries = false

    var body: some View {
        Group {
            if model.isIndexLoading, model.indexedItems.isEmpty {
                ProgressView("Loading index…")
            } else if model.indexedItems.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView(
                        "No files yet", systemImage: "doc",
                        description: Text("Add a shared folder, then sync with your other device to see files here."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                List(model.indexedItems) { item in
                    Button {
                        Task { await model.showIndexedItemInFiles(item) }
                    } label: {
                        indexedItemLabel(item)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        guard item.id == model.indexedItems.last?.id else { return }
                        Task { await model.loadMoreIndexedItems() }
                    }
                    .contextMenu { storageActions(item) }

                }
            }
        }
        .navigationTitle("Global Index")
        .searchable(text: $search, prompt: "Search paths")
        .toolbar {
            Button {
                showsMutationRecoveries = true
            } label: {
                Label(
                    "Mutation Recoveries",
                    systemImage: model.coreMutationRecoveries.isEmpty
                        ? "archivebox" : "archivebox.badge.exclamationmark"
                )
            }
        }
        .refreshable { await model.refresh() }
        .safeAreaInset(edge: .bottom) {
            if model.fileIndex.isUsingSnapshotFallback {
                Text("Showing a limited saved index. Refresh to retry the complete file list.")
                    .font(.footnote).padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
            if let status = model.statusMessage {
                Text(status)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.regularMaterial)
                    .accessibilityLabel("Storage action result")
            }
        }
        .confirmationDialog(
            pendingCacheEviction.map {
                String(localized: "Remove the download of \($0.relativePath)?")
            } ?? String(localized: "Remove Download?"),
            isPresented: Binding(
                get: { pendingCacheEviction != nil },
                set: { if !$0 { pendingCacheEviction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingCacheEviction
        ) { item in
            Button("Remove Download", role: .destructive) {
                pendingCacheEviction = nil
                Task { await model.evictFilesCache(for: item) }
            }
            Button("Cancel", role: .cancel) {
                pendingCacheEviction = nil
            }
        } message: { _ in
            Text(
                "This never deletes the global-index item or propagates a Syncthing deletion. Uploaded files are removed locally now; other files remain until another device confirms the complete current version."
            )
        }
        .confirmationDialog(
            pendingSyncthingDeletion.map {
                String(localized: "Delete \($0.relativePath) from every synchronized device?")
            } ?? String(localized: "Delete Everywhere?"),
            isPresented: Binding(
                get: { pendingSyncthingDeletion != nil },
                set: { if !$0 { pendingSyncthingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingSyncthingDeletion
        ) { item in
            Button("Delete and Propagate", role: .destructive) {
                pendingSyncthingDeletion = nil
                Task { await model.deleteIndexedItemFromSyncthing(item) }
            }
            Button("Cancel", role: .cancel) { pendingSyncthingDeletion = nil }
        } message: { _ in
            Text(
                "This is not Remove Download. It creates a Syncthing tombstone and propagates deletion to peers. Recovery safeguards may retain a separate review copy, but undo is not guaranteed."
            )
        }
        .task(id: search) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                await model.reloadIndex(query: search)
            } catch {
                // A newer search task superseded this request.
            }
        }
        .task { await model.refreshCoreMutationRecoveries() }
        .sheet(isPresented: $showsMutationRecoveries) {
            CoreMutationRecoveryReviewView()
        }
    }

    private func indexedItemLabel(_ item: IndexedItem) -> some View {
        HStack {
            Image(systemName: item.isDirectory ? "folder" : availabilityIcon(item.availability))
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(item.relativePath)
                Text(availabilityTitle(item.availability)).font(.caption).foregroundStyle(.secondary)
                if let status = model.contentRetentionStatuses[item.id] {
                    Text(retentionTitle(status))
                        .font(.caption2)
                        .foregroundStyle(status.pendingEvict ? .orange : .secondary)
                }
            }
            Spacer()
            if !item.isDirectory { Text(item.size, format: .byteCount(style: .file)).font(.caption) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.relativePath))
        .accessibilityValue(Text(accessibilityValue(for: item)))
        .accessibilityHint(
            "Tap to open in Files. Open the context menu for download and storage actions."
        )
    }

    @ViewBuilder
    private func storageActions(_ item: IndexedItem) -> some View {

        Button("Show in Files", systemImage: "folder") {
            Task { await model.showIndexedItemInFiles(item) }
        }
        .accessibilityHint(
            "Opens the current File Provider item in its user-visible Files location."
        )
        Button("Download", systemImage: "arrow.down.circle") {
            Task { await model.downloadIndexedItem(item) }
        }
        .disabled(item.isDirectory || item.availability == .local)
        .accessibilityHint(
            "Downloads this version on demand without keeping it permanently."
        )
        Button("Keep Downloaded", systemImage: "pin.fill") {
            Task { await model.keepIndexedItemDownloaded(item) }
        }
        .accessibilityHint(
            "Persists retention immediately and downloads later if the device is offline."
        )
        Divider()
        Button("Remove Download", role: .destructive) {
            pendingCacheEviction = item
        }
        .accessibilityHint(
            "Removes only this device's content when uploaded, or waits for upload and removes it automatically. It never propagates a deletion."
        )
        Button("Delete Everywhere", role: .destructive) {
            pendingSyncthingDeletion = item
        }
        .accessibilityHint(
            "Creates a real Syncthing deletion that propagates to connected devices."
        )
    }

    private func availabilityIcon(_ state: FileAvailability) -> String {
        switch state {
        case .local: "doc"
        case .remoteOnly: "icloud.and.arrow.down"
        case .downloading: "arrow.down.circle"
        case .uploading: "arrow.up.circle"
        case .conflict: "exclamationmark.triangle"
        case .ignored: "eye.slash"
        case .error: "xmark.octagon"
        }
    }

    private func availabilityTitle(_ state: FileAvailability) -> String {
        switch state {
        case .local: String(localized: "Available Locally")
        case .remoteOnly: String(localized: "Remote Only")
        case .downloading: String(localized: "Downloading")
        case .uploading: String(localized: "Uploading")
        case .conflict: String(localized: "Conflict")
        case .ignored: String(localized: "Ignored")
        case .error: String(localized: "Error")
        }
    }

    private func accessibilityValue(for item: IndexedItem) -> String {
        let retention = model.contentRetentionStatuses[item.id]
        let retentionTitle =
            retention.map(self.retentionTitle)
            ?? String(localized: "Retention state unavailable")
        if item.isDirectory {
            return String(localized: "Folder, \(availabilityTitle(item.availability)), \(retentionTitle)")
        }
        return String(
            localized:
                "File, \(availabilityTitle(item.availability)), \(retentionTitle), \(item.size.formatted(.byteCount(style: .file)))"
        )
    }

    private func retentionTitle(_ status: ContentRetentionStatus) -> String {
        if status.pendingEvict {
            return String(localized: "Waiting for upload, then remove download")
        }
        if status.isPinned {
            return status.isUploaded
                ? String(localized: "Keep Downloaded · Uploaded")
                : String(localized: "Keep Downloaded · Waiting for upload")
        }
        return status.isUploaded
            ? String(localized: "Uploaded")
            : String(localized: "Not uploaded")
    }

}

private struct CoreMutationRecoveryReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingOrdinaryDisposal: CoreMutationRecoverySummary?
    @State private var pendingDangerousReview: CoreMutationRecoverySummary?
    @State private var pendingFinalDangerousDisposal: CoreMutationRecoverySummary?
    @State private var recoveryExport: CoreMutationRecoveryExport?
    @State private var pendingRecoveryExport: CoreMutationRecoveryExport?

    var body: some View {
        NavigationStack {
            Group {
                if model.isCoreMutationRecoveryLoading, model.coreMutationRecoveries.isEmpty {
                    ProgressView("Reviewing mutation recoveries…")
                } else if model.coreMutationRecoveries.isEmpty {
                    ContentUnavailableView(
                        "No Mutation Recovery Copies",
                        systemImage: "archivebox",
                        description: Text(
                            "No Core/File Provider mutation recovery copy currently requires review."
                        )
                    )
                } else {
                    List {
                        Section {
                            Text(
                                "These are App-owned Core/File Provider mutation recovery copies. Export creates a verified temporary snapshot for the system share sheet without changing the retained source or live item. Automatic in-place restore is not available. Cleanup permanently removes only the exact reviewed recovery payload."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Section("Recovery Copies") {
                            ForEach(model.coreMutationRecoveries) { summary in
                                recoveryRow(summary)
                            }
                            if model.hasMoreCoreMutationRecoveries {
                                Button("Load More") {
                                    Task { await model.loadMoreCoreMutationRecoveries() }
                                }
                                .disabled(model.isCoreMutationRecoveryLoading)
                            }
                        }
                    }
                    .refreshable { await model.refreshCoreMutationRecoveries() }
                }
            }
            .navigationTitle("Mutation Recoveries")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let code = model.coreMutationRecoveryFailureCode {
                    Text("Recovery review unavailable: \(code)")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.regularMaterial)
                }
            }
        }
        .sheet(
            item: $recoveryExport,
            onDismiss: { finishPendingRecoveryExport() },
            content: { export in
                MutationRecoveryExportShareSheet(url: export.url) {
                    finishRecoveryExport(export)
                }
                .onDisappear { finishRecoveryExport(export) }
            }
        )
        .onDisappear { finishPendingRecoveryExport() }
        .confirmationDialog(
            "Permanently delete this retained mutation recovery copy?",
            isPresented: Binding(
                get: { pendingOrdinaryDisposal != nil },
                set: { if !$0 { pendingOrdinaryDisposal = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingOrdinaryDisposal
        ) { summary in
            Button("Delete Exact Recovery Copy", role: .destructive) {
                pendingOrdinaryDisposal = nil
                Task {
                    await model.disposeCoreMutationRecovery(
                        summary,
                        afterDangerousReview: false
                    )
                }
            }
            Button("Cancel", role: .cancel) { pendingOrdinaryDisposal = nil }
        } message: { summary in
            Text(
                "This permanently deletes the exact retained recovery payload for \(summary.relativePath). It does not restore, modify, or delete the current synchronized item. The recovery copy may be the only retained fallback for these bytes."
            )
        }
        .confirmationDialog(
            "Dangerous mutation recovery cleanup",
            isPresented: Binding(
                get: { pendingDangerousReview != nil },
                set: { if !$0 { pendingDangerousReview = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDangerousReview
        ) { summary in
            Button("Continue to Final Review", role: .destructive) {
                pendingDangerousReview = nil
                pendingFinalDangerousDisposal = summary
            }
            Button("Cancel", role: .cancel) { pendingDangerousReview = nil }
        } message: { summary in
            Text(
                "This \(statusTitle(summary.status)) record represents an incomplete or conflicting mutation recovery state. Cleanup can remove the only preserved payload needed for manual investigation. It does not restore the item."
            )
        }
        .alert(
            "Final confirmation: delete recovery payload?",
            isPresented: Binding(
                get: { pendingFinalDangerousDisposal != nil },
                set: { if !$0 { pendingFinalDangerousDisposal = nil } }
            ),
            presenting: pendingFinalDangerousDisposal
        ) { summary in
            Button("Permanently Delete Reviewed Payload", role: .destructive) {
                pendingFinalDangerousDisposal = nil
                Task {
                    await model.disposeCoreMutationRecovery(
                        summary,
                        afterDangerousReview: true
                    )
                }
            }
            Button("Cancel", role: .cancel) { pendingFinalDangerousDisposal = nil }
        } message: { summary in
            Text(
                "Path: \(summary.relativePath)\nDigest: \(summary.digest)\nThis cannot be undone and does not restore any live file."
            )
        }
    }

    @ViewBuilder
    private func recoveryRow(_ summary: CoreMutationRecoverySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.relativePath)
                .font(.headline)
                .textSelection(.enabled)
            LabeledContent("Folder", value: folderLabel(for: summary.folderID))
            LabeledContent("Mutation", value: summary.commandKind.rawValue)
            LabeledContent("Payload", value: payloadTitle(summary.payloadKind))
            LabeledContent("Size", value: summary.bytes.formatted(.byteCount(style: .file)))
            LabeledContent("Status", value: statusTitle(summary.status))
            VStack(alignment: .leading, spacing: 2) {
                Text("SHA-256 Digest").font(.caption).foregroundStyle(.secondary)
                Text(summary.digest)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Button("Export Recovery Copy") {
                Task {
                    if let export = await model.prepareCoreMutationRecoveryExport(summary) {
                        pendingRecoveryExport = export
                        recoveryExport = export
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.runningCoreMutationRecoveryExportIDs.contains(summary.recoveryID)
            )
            .accessibilityHint(
                "Creates a verified temporary snapshot and opens the system share sheet. The retained mutation recovery copy stays unchanged."
            )
            switch summary.status {
            case .retainedRequiresUserConfirmation, .disposalApprovedPendingCleanup:
                Button("Review Retained-Copy Cleanup", role: .destructive) {
                    pendingOrdinaryDisposal = summary
                }
            case .prepared, .conflictRequiresManualCleanup:
                Button("Review Dangerous Cleanup", role: .destructive) {
                    pendingDangerousReview = summary
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func finishRecoveryExport(_ export: CoreMutationRecoveryExport) {
        guard pendingRecoveryExport?.id == export.id else { return }
        pendingRecoveryExport = nil
        recoveryExport = nil
        Task { await model.discardCoreMutationRecoveryExport(export) }
    }

    private func finishPendingRecoveryExport() {
        guard let pendingRecoveryExport else { return }
        finishRecoveryExport(pendingRecoveryExport)
    }

    private func payloadTitle(_ payload: CoreMutationRecoveryPayloadKind) -> String {
        switch payload {
        case .file: String(localized: "File")
        case .directory: String(localized: "Directory")
        }
    }

    private func folderLabel(for folderID: FolderID) -> String {
        model.snapshot.folders.first(where: { $0.id == folderID })?.label
            ?? String(localized: "Unavailable")
    }

    private func statusTitle(_ status: CoreMutationRecoveryStatus) -> String {
        switch status {
        case .prepared: String(localized: "Prepared — Dangerous Review Required")
        case .retainedRequiresUserConfirmation: String(localized: "Retained — Confirmation Required")
        case .conflictRequiresManualCleanup: String(localized: "Conflict — Dangerous Review Required")
        case .disposalApprovedPendingCleanup: String(localized: "Disposal Approved — Cleanup Pending")
        }
    }
}

private struct MutationRecoveryExportShareSheet: UIViewControllerRepresentable {
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
