import PsySync
import SwiftUI

struct FoldersView: View {
    @Environment(AppModel.self) var model
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
                            .buttonStyle(.glassProminent)
                            .accessibilityIdentifier("folders.empty.new")
                    }
                } else {
                    ScrollView {
                        GlassEffectContainer(spacing: 4) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                                ForEach(model.folders) { folder in
                                    NavigationLink(value: folder.id) {
                                        FolderRow(folder: folder)
                                            .padding(.horizontal, 18).padding(.vertical, 14)
                                            .glassCard(cornerRadius: GlassMetrics.row, tint: tint(for: folder), interactive: true)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("folder.row.\(folder.label)")
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 96)   // room for the floating button
                    }
                }
            }
            .glassScreen()
            .navigationTitle("Folders")
            .navigationDestination(for: FolderID.self) { FolderDetailView(folderID: $0) }
            .overlay(alignment: .bottomTrailing) {
                if !model.folders.isEmpty {
                    FloatingActionButton(title: "New Folder", systemImage: "plus", identifier: "folders.new") { creating = true }
                }
            }
            .toolbar {
                if model.folders.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { creating = true } label: { Label("New Folder", systemImage: "plus") }
                            .accessibilityIdentifier("folders.new")
                    }
                }
            }
            .sheet(isPresented: $creating) { NewFolderView().bannerOverlay().environment(model) }
            .onChange(of: model.pendingCommand, initial: true) { _, command in
                if command == .newFolder { model.pendingCommand = nil; creating = true }
            }
        }
    }
}

extension FoldersView {
    /// Errors tint the card red; everything else stays neutral glass.
    func tint(for folder: Folder) -> Color? {
        let status = model.status(of: folder)
        if status.state == .error { return .red }
        return status.issues.isEmpty ? nil : .orange
    }
}

struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let folder: Folder

    var body: some View {
        let status = model.status(of: folder)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: folder.location == .managed ? "folder.fill" : "externaldrive.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
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
            FolderWorkProgress(status: status, listing: model.listing(of: folder), compact: true)
            if let issue = status.issues.first {
                Label {
                    if status.issues.count > 1 {
                        Text("\(Text(issue.kind.title)) (+\(status.issues.count - 1))")
                    } else {
                        Text(issue.kind.title)
                    }
                } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(.caption)
                .foregroundStyle(status.state == .error ? .red : .orange)
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
                        .plainNameInput()
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
                    TextField("Folder name", text: $label).plainNameInput().accessibilityIdentifier("acceptfolder.name")
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

/// Background work that keeps a folder from being "up to date": the peer's
/// file list arriving (indeterminate, items received so far) or the Files
/// list being built (N of M). Shown in the folder row and detail.
struct FolderWorkProgress: View {
    let status: FolderStatus
    let listing: FilesListingProgress?
    var compact = false

    var body: some View {
        switch status.state {
        case .fetchingIndex:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView().progressViewStyle(.linear)
                if status.progress.globalItems > 0 {
                    Text("\(status.progress.globalItems) items received so far")
                        .font(compact ? .caption : .footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .accessibilityIdentifier("folder.work")
        case .preparingFiles:
            let total = max(Int(status.progress.globalItems), listing?.processed ?? 0, 1)
            let done = min(listing?.processed ?? 0, total)
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(done), total: Double(total))
                Text("\(done) of \(total) items listed for Files")
                    .font(compact ? .caption : .footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityIdentifier("folder.work")
        case .waitingForDevices where status.progress.needItems > 0:
            // Downloads the user asked for (opened in Files, Keep Downloaded)
            // or that the folder needs: kept, and they start on reconnect.
            Text("\(status.progress.needItems) files waiting for a device")
                .font(compact ? .caption : .footnote).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityIdentifier("folder.work")
        default:
            EmptyView()
        }
    }
}
