import PsySync
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var acceptingFolder: PendingFolder?
    @State private var detailIssue: SyncIssue?
    @Namespace private var glass

    var body: some View {
        let _ = perfProbe("HomeView")
        NavigationStack {
            ScrollView {
                GlassEffectContainer(spacing: 6) {
                    if sizeClass == .regular {
                        // iPad / large windows: status + activity on the left, identity on the right.
                        HStack(alignment: .top, spacing: 20) {
                            VStack(spacing: 20) { primaryCards }
                                .frame(maxWidth: .infinity)
                            VStack(spacing: 20) { identityCard }
                                .frame(width: 340)
                        }
                    } else {
                        VStack(spacing: 20) {
                            primaryCards
                            identityCard
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .animation(.smooth, value: model.pendingCount)
                .animation(.smooth, value: model.allIssues.count)
            }
            .glassScreen()
            .navigationTitle("Sync")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.syncNow() } } label: { Label("Sync now", systemImage: "arrow.clockwise") }
                        .disabled(!model.isRunning || model.folders.isEmpty)
                        .accessibilityIdentifier("home.syncnow")
                }
            }
            .sheet(item: $acceptingFolder) { AcceptFolderSheet(pending: $0).bannerOverlay().environment(model) }
            .sheet(item: $detailIssue) { IssueDetailView(issue: $0) }
        }
    }

    @ViewBuilder private var primaryCards: some View {
        VStack(spacing: 10) {
            CardHeader(title: "Status", systemImage: "waveform.path.ecg")
            StatusCard()
                .glassEffectID("status", in: glass)
        }
        if model.filesLocation == .disabled {
            FilesDisabledCard()
                .padding(18)
                .glassCard(tint: .orange)
        }
        if model.pendingCount > 0 { inbox }
        if !model.syncingFolders.isEmpty || model.hasFileTransfers {
            TransfersCard(glass: glass)
        }
        if !model.allIssues.isEmpty { problems }
    }

    /// iPhone / iPad / Mac (Designed for iPad) glyph for the "This device" card.
    private static var thisDeviceSymbol: String {
        if ProcessInfo.processInfo.isiOSAppOnMac { return "laptopcomputer" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    private var identityCard: some View {
        VStack(spacing: 10) {
            CardHeader(title: "This device", systemImage: Self.thisDeviceSymbol)
            LocalIDCard()
                .padding(18)
                .glassCard()
                .glassEffectID("identity", in: glass)
        }
    }

    // MARK: Inbox

    private var inbox: some View {
        VStack(spacing: 12) {
            CardHeader(title: "Needs your attention", systemImage: "tray.full")
            ForEach(model.pendingDevices) { device in
                InboxCard(
                    symbol: "person.crop.circle.badge.questionmark",
                    title: "\(device.name.nilIfEmpty ?? device.id.short) wants to connect",
                    subtitle: Text(device.id.short).font(.caption.monospaced()),
                    accept: ("Accept", "pending.device.accept", { Task { await model.acceptPending(device) } }),
                    ignore: ("pending.device.ignore", { Task { await model.dismissPending(device) } })
                )
                .glassEffectID("device-\(device.id.rawValue)", in: glass)
                .glassEffectTransition(.matchedGeometry)
            }
            ForEach(model.pendingFolders) { pending in
                InboxCard(
                    symbol: "folder.badge.plus",
                    title: "“\(pending.label)” was shared with you",
                    subtitle: Text("From \(model.deviceName(pending.offeredBy))"),
                    accept: ("Accept…", "pending.folder.accept", { acceptingFolder = pending }),
                    ignore: ("pending.folder.ignore", { Task { await model.dismissPending(pending) } })
                )
                .glassEffectID("folder-\(pending.id)", in: glass)
                .glassEffectTransition(.matchedGeometry)
            }
        }
    }

    // MARK: Problems

    private var problems: some View {
        VStack(spacing: 10) {
            CardHeader(title: "Recent problems", systemImage: "exclamationmark.triangle")
            VStack(spacing: 0) {
                ForEach(Array(model.allIssues.enumerated()), id: \.element.id) { index, issue in
                    if index > 0 { Divider().padding(.leading, 52) }
                    Button { detailIssue = issue } label: {
                        HStack(spacing: 14) {
                            Image(systemName: issue.kind == .conflict ? "doc.on.doc.fill" : "exclamationmark.triangle.fill")
                                .font(.title3)
                                .foregroundStyle(issue.kind == .conflict ? .orange : .red)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.kind.title).foregroundStyle(.primary)
                                if let folder = issue.folderID, let f = model.folders.first(where: { $0.id == folder }) {
                                    Text(f.label).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("issue.\(issue.id)")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .glassCard()
            .glassEffectID("problems", in: glass)
        }
    }
}

/// Home ▸ Transfers: syncing folders and per-file progress. Its own view so
/// progress ticks re-evaluate this card only, not the whole Home page.
struct TransfersCard: View {
    @Environment(AppModel.self) private var model
    /// Per-file progress is collapsed by default: during a big sync the list
    /// changes several times a second and made the whole page jump.
    @State private var showFileTransfers = false
    let glass: Namespace.ID

    /// Collapsed: one fixed-height row with the count. Expanded: at most
    /// `maxFileRows` files in a stable (path) order, so rows do not reshuffle.
    private static let maxFileRows = 6

    private var fileTransfers: some View {
        let files = model.transfers.values.sorted { $0.id < $1.id }
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { showFileTransfers.toggle() }
            } label: {
                HStack {
                    Label("\(files.count) files in progress", systemImage: "doc.on.doc")
                        .font(.subheadline)
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showFileTransfers ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.filetransfers")
            if showFileTransfers {
                ForEach(files.prefix(Self.maxFileRows)) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(t.path.lastComponent, systemImage: "doc").font(.subheadline).lineLimit(1)
                        ProgressView(value: t.fraction)
                    }
                    .transaction { $0.animation = nil }   // progress ticks must not animate layout
                }
                if files.count > Self.maxFileRows {
                    Text("and \(files.count - Self.maxFileRows) more")
                        .font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    var body: some View {
        let _ = perfProbe("TransfersCard")
        VStack(spacing: 10) {
            CardHeader(title: "Transfers", systemImage: "arrow.up.arrow.down")
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.syncingFolders) { folder in
                    let status = model.status(of: folder)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(folder.label).font(.headline)
                            Spacer()
                            Text(status.progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: status.progress.fractionCompleted)
                            .tint(.accentColor)
                        Text("\(Format.bytes(status.progress.needBytes)) left · \(status.progress.needItems) items")
                            .font(.caption).foregroundStyle(.secondary)
                        if let file = status.lastSyncedFile {
                            Text(file.rawValue).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("transfer.\(folder.id.rawValue)")
                }
                if model.hasFileTransfers {
                    fileTransfers
                }
                if model.isContinuingInBackground {
                    Label("Syncing continues in the background", systemImage: "arrow.down.app")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("home.continuing")
                } else if model.canContinueInBackground && !model.syncingFolders.isEmpty
                            && (!model.settings.autoContinueInBackground || model.autoContinueFailed) {
                    // With the automatic setting on, the request is made for
                    // the user and the line above appears; the button is only
                    // offered again if the system refused it.
                    Button { Task { await model.continueInBackground() } } label: {
                        Label("Keep Syncing in Background", systemImage: "arrow.down.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("home.continueinbg")
                }
            }
            .padding(18)
            .glassCard()
            .glassEffectID("transfers", in: glass)
        }
    }
}

/// One pending request (device or folder) with Accept / Ignore glass buttons.
struct InboxCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: Text
    let accept: (title: LocalizedStringKey, id: String, action: () -> Void)
    let ignore: (id: String, action: () -> Void)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium))
                    subtitle.foregroundStyle(.secondary).font(.caption)
                }
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
        }
        .padding(18)
        .glassCard()
    }

    @ViewBuilder private var buttons: some View {
        Button(accept.title, action: accept.action)
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier(accept.id)
        Button("Ignore", role: .cancel, action: ignore.action)
            .buttonStyle(.glass)
            .accessibilityIdentifier(ignore.id)
    }
}

/// Shown when the Files/Finder location is turned off (default on Mac).
struct FilesDisabledCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Files location is turned off", systemImage: "externaldrive.badge.exclamationmark")
                .font(.headline).foregroundStyle(.orange)
            Text(model.isOnMac
                 ? "To see your synced folders in Finder, open System Settings ▸ General ▸ Login Items & Extensions ▸ File Providers and turn on Psynguechthyngue."
                 : "To see your synced folders in Files, open the Files app, tap ••• ▸ Edit, and turn on Psynguechthyngue.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.filesdisabled")
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
        if states.contains(.fetchingIndex) { return Summary(title: "Getting file lists…", symbol: "arrow.down.doc.fill", tint: .blue) }
        if states.contains(.preparingFiles) { return Summary(title: "Preparing file lists…", symbol: "list.bullet.rectangle.fill", tint: .blue) }
        if states.contains(.waitingForDevices) { return Summary(title: "Waiting for devices", symbol: "clock.fill", tint: .orange) }
        if !states.isEmpty, states.allSatisfy({ $0 == .paused }) {
            return Summary(title: "All folders are paused", symbol: "pause.circle.fill", tint: .secondary)
        }
        return Summary(title: "Everything is up to date", symbol: "checkmark.circle.fill", tint: .green)
    }

    var body: some View {
        let _ = perfProbe("StatusCard")
        let s = summary
        HStack(spacing: 14) {
            Image(systemName: s.symbol)
                .font(.system(size: 40, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(s.tint)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 4) {
                Text(s.title).font(.title3.weight(.semibold)).accessibilityIdentifier("home.status.title")
                if let hold = model.policyHold {
                    Text(hold.message).font(.subheadline).foregroundStyle(.secondary)
                } else if model.host.decision.reducedResourceUsage {
                    Text("Syncing more slowly while the system saves resources")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if case let .failed(_, detail) = model.engineState {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                } else if !model.devices.isEmpty {
                    Text("\(model.connectedCount) of \(model.devices.count) devices connected")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if model.isOnMac {
                        Text("Closing the window stops syncing. Minimize it to keep syncing.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("home.machint")
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: s.tint)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.status")
    }
}

/// This device's ID: QR code, copy and share.
struct LocalIDCard: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false
    @ScaledMetric(relativeTo: .body) private var qrSize: CGFloat = 180

    var body: some View {
        let _ = perfProbe("LocalIDCard")
        if let id = model.localID {
            VStack(spacing: 12) {
                QRCodeView(value: id.rawValue)
                    .frame(width: min(qrSize, 240), height: min(qrSize, 240))
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(false)
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
                        .buttonStyle(.glass)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityIdentifier("home.copyid")
                    ShareLink(item: id.rawValue) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.glass)
                }
                Text("On the other device, add this device using its ID or QR code.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
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
