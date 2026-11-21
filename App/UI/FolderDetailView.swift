import PsySync
import SwiftUI

struct FolderDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let folderID: FolderID
    @State private var confirmRemove = false
    @State private var issue: SyncIssue?

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
                    if status.state == .syncing || status.progress.needBytes > 0 {
                        ProgressView(value: status.progress.fractionCompleted)
                        Text("\(Format.bytes(status.progress.needBytes)) left · \(status.progress.needItems) items")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Size") { Text(Format.bytes(status.progress.globalBytes)) }
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

                if folder.location == .managed {
                    Section {
                        Button { openURL(URL(string: "shareddocuments://")!) } label: { Label("Open in Files", systemImage: "folder") }
                            .accessibilityIdentifier("folder.openfiles")
                    }
                }

                Section {
                    Toggle("Pause", isOn: Binding(
                        get: { folder.paused },
                        set: { v in var f = folder; f.paused = v; Task { await model.update(f) } }
                    ))
                    .accessibilityIdentifier("folder.pause")
                    if folder.location == .managed {
                        Picker("Download", selection: Binding(
                            get: { folder.contentMode },
                            set: { v in var f = folder; f.contentMode = v; Task { await model.update(f) } }
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
                                var f = folder
                                if on { if !f.devices.contains(d.id) { f.devices.append(d.id) } } else { f.devices.removeAll { $0 == d.id } }
                                Task { await model.update(f) }
                            }
                        ))
                    }
                }

                Section {
                    DisclosureGroup("Advanced") {
                        LabeledContent("Folder ID") { Text(folder.id.rawValue).font(.footnote.monospaced()).textSelection(.enabled) }
                        Picker("Type", selection: Binding(
                            get: { folder.type },
                            set: { v in var f = folder; f.type = v; Task { await model.update(f) } }
                        )) {
                            Text("Send & Receive").tag(FolderType.sendReceive)
                            Text("Send Only").tag(FolderType.sendOnly)
                            Text("Receive Only").tag(FolderType.receiveOnly)
                        }
                        if case let .external(_, path) = folder.location {
                            LabeledContent("Location") { Text(path).font(.footnote).lineLimit(2).truncationMode(.head) }
                        }
                        Button("Rescan Now") { Task { await model.rescan(folder) } }
                            .accessibilityIdentifier("folder.rescan")
                    }
                }

                Section {
                    Button("Remove Folder", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("folder.remove")
                }
            }
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
