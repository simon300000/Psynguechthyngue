import PsySync
import SwiftUI

struct FoldersView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Group {
                if model.folders.isEmpty {
                    ContentUnavailableView {
                        Label("No folders yet", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Create a folder to share, or accept one that another device offers.")
                    } actions: {
                        Button("New Folder") { creating = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("folders.empty.new")
                    }
                } else {
                    List(model.folders) { folder in
                        NavigationLink(value: folder.id) { FolderRow(folder: folder) }
                            .accessibilityIdentifier("folder.row.\(folder.label)")
                    }
                }
            }
            .navigationTitle("Folders")
            .navigationDestination(for: FolderID.self) { FolderDetailView(folderID: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New Folder", systemImage: "plus") }
                        .accessibilityIdentifier("folders.new")
                }
            }
            .sheet(isPresented: $creating) { NewFolderView() }
        }
    }
}

struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let folder: Folder

    var body: some View {
        let status = model.status(of: folder)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(folder.label).font(.headline)
                Spacer()
                Label(status.state.title, systemImage: status.state.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(status.state.tint)
            }
            if status.state == .syncing {
                ProgressView(value: status.progress.fractionCompleted)
            }
            if status.state == .error, let issue = status.issues.first {
                Text(issue.kind.title).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct NewFolderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var external: ExternalSelection?
    @State private var mode: PsySync.ContentMode = .everything
    @State private var shared: Set<DeviceID> = []
    @State private var seeded = false
    @State private var busy = false
    @State private var optionsKey = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Folder name", text: $name)
                        .accessibilityIdentifier("newfolder.name")
                }
                FolderOptionsSection(external: $external, mode: $mode)
                Section {
                    if model.devices.isEmpty {
                        Text("Add a device first to share this folder.").foregroundStyle(.secondary)
                    }
                    ForEach(model.devices) { d in
                        Toggle(d.name.nilIfEmpty ?? d.id.short, isOn: Binding(
                            get: { shared.contains(d.id) },
                            set: { if $0 { shared.insert(d.id) } else { shared.remove(d.id) } }
                        ))
                        .accessibilityIdentifier("newfolder.share.\(d.id.short)")
                    }
                } header: { Text("Share with") }
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        .accessibilityIdentifier("newfolder.create")
                }
            }
            .onAppear { if !seeded { shared = Set(model.devices.map(\.id)); seeded = true } }
        }
        .presentationDetents([.large])
    }

    private func create() {
        busy = true
        let loc: FolderLocation = external.map { .external(bookmark: $0.bookmark, displayPath: $0.displayPath) } ?? .managed
        Task {
            let ok = await model.createFolder(label: name.trimmingCharacters(in: .whitespaces), location: loc, mode: mode,
                                              devices: model.devices.map(\.id).filter(shared.contains))
            busy = false
            if ok { dismiss() }
        }
    }
}

struct AcceptFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: PendingFolder
    @State private var label = ""
    @State private var external: ExternalSelection?
    @State private var mode: PsySync.ContentMode = .everything
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder name", text: $label).accessibilityIdentifier("acceptfolder.name")
                } header: { Text("Name") } footer: { Text("Shared by \(model.deviceName(pending.offeredBy))") }
                FolderOptionsSection(external: $external, mode: $mode)
            }
            .navigationTitle("Accept Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept") {
                        busy = true
                        let loc: FolderLocation = external.map { .external(bookmark: $0.bookmark, displayPath: $0.displayPath) } ?? .managed
                        Task {
                            let ok = await model.accept(pending, label: label.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? pending.label,
                                                        location: loc, mode: mode)
                            busy = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("acceptfolder.accept")
                }
            }
            .onAppear { if label.isEmpty { label = pending.label } }
        }
        .presentationDetents([.large])
    }
}
