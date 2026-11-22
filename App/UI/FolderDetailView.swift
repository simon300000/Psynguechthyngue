import PsySync
import SwiftUI

struct FolderDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let folderID: FolderID
    @State private var confirmRemove = false
    @State private var issue: SyncIssue?
    @State private var notYetInFiles = 0

    var body: some View {
        if let folder = model.folders.first(where: { $0.id == folderID }) {
            let status = model.status(of: folder)
            Form {
                Section {
                    HStack {
                        Label(status.state.title, systemImage: status.state.symbol).foregroundStyle(status.state.tint)
                        Spacer()
                    }
                    .accessibilityIdentifier("folder.state")
                    FolderWorkProgress(status: status, listing: model.listing(of: folder))
                    // While the file list is still arriving/being processed
                    // upstream's needs are transient, not a transfer.
                    if status.state == .syncing
                        || (status.progress.needBytes > 0 && status.state != .fetchingIndex && status.state != .preparingFiles) {
                        ProgressView(value: status.progress.fractionCompleted)
                        Text("\(Format.bytes(status.progress.needBytes)) left · \(status.progress.needItems) items")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Size") {
                        // Not final while the file list is arriving.
                        if status.progress.sizeIsPartial {
                            Text("At least \(Format.bytes(status.progress.globalBytes))")
                        } else {
                            Text(Format.bytes(status.progress.globalBytes))
                        }
                    }
                    StorageRow(progress: status.progress, onDemand: folder.contentMode == .onDemand)
                    if let scan = status.lastScan {
                        LabeledContent("Last scan") { Text(Format.relative(scan)) }
                    }
                }

                let errors = status.issues.filter { $0.kind != .conflict }
                if !errors.isEmpty {
                    Section("Problems") {
                        ForEach(errors) { i in
                            Button { issue = i } label: { Label(i.kind.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                        }
                    }
                }
                let conflicts = status.issues.filter { $0.kind == .conflict }
                if !conflicts.isEmpty {
                    Section {
                        ForEach(conflicts) { i in
                            Button { issue = i } label: {
                                Label(i.path?.lastComponent ?? String(localized: "File conflict"), systemImage: "doc.on.doc")
                            }
                        }
                    } header: { Text("Conflicts") } footer: { Text(SyncIssue.Kind.conflict.advice) }
                }

                // shareddocuments:// opens the Files app on iPhone/iPad; on Mac
                // (Designed for iPad) there is no Files app and it does nothing.
                if folder.location == .managed && !model.isOnMac {
                    Section {
                        Button { openURL(URL(string: "shareddocuments://")!) } label: { Label("Open in Files", systemImage: "folder") }
                            .accessibilityIdentifier("folder.openfiles")
                    } footer: {
                        // FilesMaterializer hands local files to Files; until the
                        // system has taken them (just synced, App was in the
                        // background, iOS 26 ignores the request) Files shows a
                        // cloud badge on them, but opening needs no network.
                        if notYetInFiles > 0 {
                            Text("Files on this device open offline in the Files app.")
                        }
                    }
                    .task(id: status.progress.localBytes) { notYetInFiles = await model.notYetInFiles(folder.id) }
                }

                Section {
                    Toggle("Pause", isOn: Binding(
                        get: { folder.paused },
                        set: { v in Task { await model.updateFolder(id: folderID) { $0.paused = v } } }
                    ))
                    .accessibilityIdentifier("folder.pause")
                    if folder.location == .managed {
                        Picker("Download", selection: Binding(
                            get: { folder.contentMode },
                            set: { v in Task { await model.updateFolder(id: folderID) { $0.contentMode = v } } }
                        )) {
                            Text("Everything").tag(PsySync.ContentMode.everything)
                            Text("On demand").tag(PsySync.ContentMode.onDemand)
                        }
                    }
                }

                Section("Shared with") {
                    if model.devices.isEmpty { Text("No devices yet.").foregroundStyle(.secondary) }
                    ForEach(model.devices) { d in
                        Toggle(d.name.nilIfEmpty ?? d.id.short, isOn: Binding(
                            get: { folder.devices.contains(d.id) },
                            set: { on in
                                let id = d.id
                                Task {
                                    await model.updateFolder(id: folderID) { f in
                                        if on { if !f.devices.contains(id) { f.devices.append(id) } } else { f.devices.removeAll { $0 == id } }
                                    }
                                }
                            }
                        ))
                    }
                }

                Section {
                    DisclosureGroup("Advanced") {
                        LabeledContent("Folder ID") { Text(folder.id.rawValue).font(.footnote.monospaced()).textSelection(.enabled) }
                        Picker("Type", selection: Binding(
                            get: { folder.type },
                            set: { v in Task { await model.updateFolder(id: folderID) { $0.type = v } } }
                        )) {
                            Text("Send & Receive").tag(FolderType.sendReceive)
                            Text("Send Only").tag(FolderType.sendOnly)
                            Text("Receive Only").tag(FolderType.receiveOnly)
                        }
                        if case let .external(_, path) = folder.location {
                            LabeledContent("Location") { Text(path).font(.footnote).lineLimit(2).truncationMode(.head) }
                        }
                        NavigationLink("Ignore Patterns") { IgnoreRulesEditor(folder: folder) }
                            .accessibilityIdentifier("folder.ignores")
                        Button("Rescan Now") { Task { await model.rescan(folder) } }
                            .accessibilityIdentifier("folder.rescan")
                    }
                }

                Section {
                    Button("Remove Folder", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("folder.remove")
                }
            }
            .glassScreen()
            .navigationTitle(folder.label)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $issue) { IssueDetailView(issue: $0) }
            .confirmationDialog("Remove this folder?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Stop Syncing, Keep Files", role: .destructive) {
                    Task { if await model.remove(folder, deleteLocalFiles: false) { dismiss() } }
                }
                .accessibilityIdentifier("folder.remove.keep")
                if folder.location == .managed {
                    Button("Stop Syncing and Delete Files", role: .destructive) {
                        Task { if await model.remove(folder, deleteLocalFiles: true) { dismiss() } }
                    }
                }
            } message: {
                Text("Other devices keep their copies.")
            }
        } else {
            ContentUnavailableView("Folder removed", systemImage: "trash")
        }
    }
}

/// Folder ▸ Advanced ▸ Ignore Patterns: the user's own `.stignore` rules
/// (for on-demand folders, the user section outside the managed rules).
struct IgnoreRulesEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: Folder
    @State private var text = ""
    @State private var original = ""
    @State private var loaded = false
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 220)
                    .accessibilityIdentifier("ignores.editor")
            } footer: {
                Text("One pattern per line, e.g. *.tmp or /Archive. Matching files are not synced. Lines starting with // are comments.")
            }
        }
        .glassScreen()
        .navigationTitle("Ignore Patterns")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    Task {
                        if await model.setUserIgnoreRules(folder, text: text) { original = text; dismiss() }
                        saving = false
                    }
                }
                .disabled(!loaded || saving || text == original)
                .accessibilityIdentifier("ignores.save")
            }
        }
        .task {
            guard !loaded, let lines = await model.userIgnoreRules(folder) else { return }
            text = lines.joined(separator: "\n")
            original = text
            loaded = true
        }
    }
}

/// Space this folder uses on the device. In on-demand mode it doubles as the
/// "how much has been downloaded so far" gauge (local vs. global bytes; files
/// that are not downloaded are ignored locally and do not count).
struct StorageRow: View {
    let progress: SyncProgress
    let onDemand: Bool

    var body: some View {
        let total = max(progress.globalBytes, 0)
        let local = min(max(progress.localBytes, 0), max(total, progress.localBytes))
        let fraction = total > 0 ? Double(local) / Double(total) : 0
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("On this device") {
                Text(Format.bytes(local)).monospacedDigit()
            }
            if onDemand && total > 0 && !progress.sizeIsPartial {
                ProgressView(value: min(fraction, 1))
                Text("\(Format.bytes(local)) of \(Format.bytes(total)) downloaded (\(fraction, format: .percent.precision(.fractionLength(0))))")
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("folder.storage")
    }
}
