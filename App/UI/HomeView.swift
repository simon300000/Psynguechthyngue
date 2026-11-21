import PsySync
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var acceptingFolder: PendingFolder?
    @State private var detailIssue: SyncIssue?

    var body: some View {
        NavigationStack {
            List {
                Section { StatusCard() }
                if model.pendingCount > 0 { inbox }
                if !model.syncingFolders.isEmpty || !model.transfers.isEmpty { transfers }
                if !model.allIssues.isEmpty { problems }
                Section("This device") { LocalIDCard() }
            }
            .navigationTitle("Sync")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.syncNow() } } label: { Label("Sync now", systemImage: "arrow.clockwise") }
                        .disabled(!model.isRunning || model.folders.isEmpty)
                        .accessibilityIdentifier("home.syncnow")
                }
            }
            .sheet(item: $acceptingFolder) { AcceptFolderSheet(pending: $0) }
            .sheet(item: $detailIssue) { IssueDetailView(issue: $0) }
        }
    }

    private var inbox: some View {
        Section {
            ForEach(model.pendingDevices) { device in
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("\(device.name.nilIfEmpty ?? device.id.short) wants to connect")
                            Text(device.id.short).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "person.crop.circle.badge.questionmark") }
                    HStack {
                        Button("Accept") { Task { await model.acceptPending(device) } }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("pending.device.accept")
                        Button("Ignore", role: .cancel) { Task { await model.dismissPending(device) } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("pending.device.ignore")
                    }
                }
                .padding(.vertical, 4)
            }
            ForEach(model.pendingFolders) { pending in
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("“\(pending.label)” was shared with you")
                            Text("From \(model.deviceName(pending.offeredBy))").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "folder.badge.plus") }
                    HStack {
                        Button("Accept…") { acceptingFolder = pending }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("pending.folder.accept")
                        Button("Ignore", role: .cancel) { Task { await model.dismissPending(pending) } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("pending.folder.ignore")
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Needs your attention")
        }
    }

    private var transfers: some View {
        Section("Transfers") {
            ForEach(model.syncingFolders) { folder in
                let status = model.status(of: folder)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(folder.label).font(.headline)
                        Spacer()
                        Text(status.progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: status.progress.fractionCompleted)
                    Text("\(Format.bytes(status.progress.needBytes)) left · \(status.progress.needItems) items")
                        .font(.caption).foregroundStyle(.secondary)
                    if let file = status.lastSyncedFile {
                        Text(file.rawValue).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("transfer.\(folder.id.rawValue)")
            }
            ForEach(model.transfers.values.sorted { $0.id < $1.id }) { t in
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.path.lastComponent).lineLimit(1)
                    ProgressView(value: t.fraction)
                }
            }
        }
    }

    private var problems: some View {
        Section("Recent problems") {
            ForEach(model.allIssues) { issue in
                Button { detailIssue = issue } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(issue.kind.title)
                            if let folder = issue.folderID, let f = model.folders.first(where: { $0.id == folder }) {
                                Text(f.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: issue.kind == .conflict ? "doc.on.doc" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.kind == .conflict ? .orange : .red)
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("issue.\(issue.id)")
            }
        }
    }
}

/// Overall state at a glance (engine, policy, devices).
struct StatusCard: View {
    @Environment(AppModel.self) private var model

    private struct Summary {
        var title: LocalizedStringKey
        var symbol: String
        var tint: Color
    }

    private var summary: Summary {
        if case .failed = model.engineState { return Summary(title: "Sync engine stopped", symbol: "exclamationmark.octagon.fill", tint: .red) }
        if !model.isRunning {
            switch model.engineState {
            case .starting: return Summary(title: "Starting…", symbol: "hourglass", tint: .blue)
            default: return Summary(title: "Syncing is paused", symbol: "moon.zzz.fill", tint: .orange)
            }
        }
        if model.policyHold != nil { return Summary(title: "Sync is on hold", symbol: "hand.raised.circle.fill", tint: .orange) }
        if model.devices.isEmpty { return Summary(title: "Add a device to start", symbol: "plus.circle.fill", tint: .blue) }
        let states = model.folders.map { model.status(of: $0).state }
        if states.contains(.error) { return Summary(title: "Some folders have problems", symbol: "exclamationmark.triangle.fill", tint: .red) }
        if states.contains(.syncing) || states.contains(.scanning) { return Summary(title: "Syncing…", symbol: "arrow.triangle.2.circlepath", tint: .blue) }
        if states.contains(.waitingForDevices) { return Summary(title: "Waiting for devices", symbol: "clock.fill", tint: .orange) }
        return Summary(title: "Everything is up to date", symbol: "checkmark.circle.fill", tint: .green)
    }

    var body: some View {
        let s = summary
        HStack(spacing: 14) {
            Image(systemName: s.symbol).font(.largeTitle).foregroundStyle(s.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.title).font(.headline).accessibilityIdentifier("home.status.title")
                if let hold = model.policyHold {
                    Text(hold.message).font(.subheadline).foregroundStyle(.secondary)
                } else if !model.devices.isEmpty {
                    Text("\(model.connectedCount) of \(model.devices.count) devices connected")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if case let .failed(_, detail) = model.engineState {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.status")
    }
}

/// This device's ID: QR code, copy and share.
struct LocalIDCard: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        if let id = model.localID {
            VStack(spacing: 12) {
                QRCodeView(value: id.rawValue)
                    .frame(width: 180, height: 180)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                Text(id.rawValue)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("home.deviceid")
                HStack {
                    Button {
                        UIPasteboard.general.string = id.rawValue
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("home.copyid")
                    ShareLink(item: id.rawValue) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
                Text("On the other device, add this device using its ID or QR code.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        } else {
            HStack { ProgressView(); Text("Preparing this device’s ID…").foregroundStyle(.secondary) }
        }
    }
}

struct IssueDetailView: View {
    let issue: SyncIssue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(issue.kind.title, systemImage: "exclamationmark.triangle")
                    Text(issue.kind.advice)
                }
                if let path = issue.path {
                    Section("File") { Text(path.rawValue).textSelection(.enabled) }
                }
                Section {
                    DisclosureGroup("Technical details") {
                        Text(issue.technicalDetail).font(.caption.monospaced()).textSelection(.enabled)
                        Text(issue.occurredAt, format: .dateTime)
                    }
                }
            }
            .navigationTitle("Problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
