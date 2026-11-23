import PsySync
import SwiftUI

// Statistics UI. Numbers that change every poll use `.monospacedDigit()`,
// a minimum width and no animation, so rows do not jump while they tick.

/// "↓ 1.5 MB/s" / "↑ 256 kB/s" with a stable width.
struct RateText: View {
    enum Direction { case down, up }
    let direction: Direction
    let bytesPerSecond: Double
    @ScaledMetric(relativeTo: .subheadline) private var minWidth: CGFloat = 84

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: direction == .down ? "arrow.down" : "arrow.up")
                .imageScale(.small)
                .foregroundStyle(direction == .down ? Color.blue : Color.green)
                .accessibilityHidden(true)
            Text(MetricsFormat.rate(bytesPerSecond))
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: minWidth, alignment: .leading)
        }
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(direction == .down
            ? Text("Download \(MetricsFormat.rate(bytesPerSecond))")
            : Text("Upload \(MetricsFormat.rate(bytesPerSecond))"))
    }
}

/// Download and upload rate side by side.
struct RatePair: View {
    let rate: TransferRate

    var body: some View {
        HStack(spacing: 12) {
            RateText(direction: .down, bytesPerSecond: rate.inPerSecond)
            RateText(direction: .up, bytesPerSecond: rate.outPerSecond)
        }
    }
}

/// Home ▸ Status: total transfer rate while devices are connected. Polls
/// only while Home is visible.
struct HomeTrafficRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        RatePair(rate: model.metrics.totalRate)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home.rates")
            .task { await model.metrics.watchTraffic() }
    }
}

extension DeviceConnection {
    /// "TCP" / "QUIC" / "Relay" from upstream `type` ("tcp-client", "quic-server", "relay-client"…).
    var protocolName: String? {
        guard let t = transport?.lowercased(), !t.isEmpty else { return nil }
        if t.hasPrefix("relay") { return "Relay" }
        if t.hasPrefix("quic") { return "QUIC" }
        if t.hasPrefix("tcp") { return "TCP" }
        return t.uppercased()
    }
}

/// Device detail ▸ Connection: protocol, network, address, connections,
/// version, rates and session totals. Polls only while visible.
struct DeviceConnectionSection: View {
    @Environment(AppModel.self) private var model
    let device: Device

    var body: some View {
        let conn = model.connections[device.id]
        let connected = !device.paused && conn?.state == .connected
        Section("Status") {
            LabeledContent("Connection") {
                if device.paused { Text("Paused") }
                else if connected { Text(Format.connectionLabel(conn)) }
                else { Text("Offline") }
            }
            if connected, let conn {
                if let proto = conn.protocolName {
                    LabeledContent("Connection type") {
                        Text(networkText(proto: proto, local: conn.isLocalNetwork))
                    }
                    .accessibilityIdentifier("device.connectiontype")
                }
                if let address = conn.address {
                    LabeledContent("Address") { Text(address).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle) }
                        .textSelection(.enabled)
                        .accessibilityIdentifier("device.address")
                }
                let traffic = model.metrics.traffic?.devices[device.id]
                if let count = traffic?.connectionCount, count > 0 {
                    LabeledContent("Connections") { Text("\(count) connections").monospacedDigit() }
                        .accessibilityIdentifier("device.connections")
                }
                if let version = conn.clientVersion {
                    LabeledContent("Syncthing version") { Text(version).monospacedDigit() }
                }
                LabeledContent("Transfer rate") { RatePair(rate: model.metrics.deviceRates[device.id] ?? .zero).font(.callout) }
                    .accessibilityIdentifier("device.rates")
                LabeledContent("Received this session") {
                    Text(MetricsFormat.bytes(traffic?.inBytesTotal ?? conn.inBytesTotal)).monospacedDigit()
                }
                .transaction { $0.animation = nil }
                LabeledContent("Sent this session") {
                    Text(MetricsFormat.bytes(traffic?.outBytesTotal ?? conn.outBytesTotal)).monospacedDigit()
                }
                .transaction { $0.animation = nil }
            } else if let seen = conn?.lastSeen {
                LabeledContent("Last seen") { Text(Format.relative(seen)) }
                    .accessibilityIdentifier("device.lastseen")
            }
        }
        .task { await model.metrics.watchTraffic() }
    }

    private func networkText(proto: String, local: Bool?) -> String {
        switch local {
        case true?: String(localized: "\(proto), local network")
        case false?: String(localized: "\(proto), internet")
        case nil: proto
        }
    }
}

/// Folder detail ▸ Contents: item counts, deleted entries, download rate, last synced file.
struct FolderStatisticsSection: View {
    @Environment(AppModel.self) private var model
    let folder: Folder
    let status: FolderStatus

    var body: some View {
        let details = model.metrics.folderDetails[folder.id]
        Section("Contents") {
            if let d = details {
                countRow("Files", global: d.global.files, local: d.local.files)
                    .accessibilityIdentifier("folder.files")
                countRow("Folders", global: d.global.directories, local: d.local.directories)
                if d.global.symlinks > 0 { countRow("Symbolic links", global: d.global.symlinks, local: d.local.symlinks) }
                if d.global.deleted > 0 {
                    LabeledContent("Deleted entries") { Text(MetricsFormat.count(d.global.deleted)).monospacedDigit() }
                        .accessibilityIdentifier("folder.deleted")
                }
            } else {
                LabeledContent("Files") { Text("—") }
                    .accessibilityIdentifier("folder.files")
            }
            if status.state == .syncing {
                LabeledContent("Download rate") {
                    RateText(direction: .down, bytesPerSecond: model.metrics.folderRates[folder.id] ?? 0)
                }
                .accessibilityIdentifier("folder.rate")
            }
            if let file = details?.lastFile ?? status.lastSyncedFile {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(file.lastComponent).lineLimit(1).truncationMode(.middle)
                        if let at = details?.lastFileAt {
                            Text(details?.lastFileDeleted == true ? "Deleted \(Format.relative(at))" : Format.relative(at))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } label: { Text("Last synced file") }
                .accessibilityIdentifier("folder.lastfile")
            }
        }
        .transaction { $0.animation = nil }
        .task(id: folder.id) { await model.metrics.watchFolder(folder.id) }
    }

    /// "1,204" when everything is local, "980 of 1,204" otherwise.
    private func countRow(_ title: LocalizedStringKey, global: Int64, local: Int64) -> some View {
        LabeledContent(title) {
            if local == global {
                Text(MetricsFormat.count(global)).monospacedDigit()
            } else {
                Text("\(MetricsFormat.count(local)) of \(MetricsFormat.count(global)) on this device").monospacedDigit()
            }
        }
    }
}

/// Folder detail ▸ Devices: how far each sharing device has synced this folder.
struct FolderCompletionSection: View {
    @Environment(AppModel.self) private var model
    let folder: Folder
    let status: FolderStatus

    var body: some View {
        let shared = folder.devices.filter { id in model.devices.contains { $0.id == id } }
        if !shared.isEmpty {
            Section {
                ForEach(shared, id: \.self) { id in
                    let pct = status.progress.remoteCompletion[id]
                    LabeledContent {
                        if let pct {
                            Text(pct / 100, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        } else {
                            Text("—")
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.deviceName(id))
                            if let pct, pct < 100 {
                                ProgressView(value: min(max(pct / 100, 0), 1)).frame(maxWidth: 160)
                            }
                        }
                    }
                    .accessibilityIdentifier("folder.completion.\(id.short)")
                }
            } header: { Text("Device completion") } footer: {
                Text("How much of this folder each device has.")
            }
            .transaction { $0.animation = nil }
        }
    }
}

/// Settings ▸ About ▸ Diagnostics: engine version, uptime, memory, listeners,
/// discovery and relays. Polls only while visible.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let info = model.metrics.systemInfo
        Form {
            Section("Sync engine") {
                LabeledContent("Syncthing") { Text(info?.version.nilIfEmpty ?? model.syncthingVersion.nilIfEmpty ?? "—") }
                LabeledContent("Status") {
                    model.isRunning ? Text("Running") : Text("Not running")
                }
                if let info, model.isRunning {
                    LabeledContent("Uptime") { Text(MetricsFormat.duration(info.uptime)).monospacedDigit() }
                        .accessibilityIdentifier("diagnostics.uptime")
                    LabeledContent("Engine memory") {
                        Text("\(MetricsFormat.bytes(info.memoryAllocBytes)) of \(MetricsFormat.bytes(info.memorySysBytes))").monospacedDigit()
                    }
                    .accessibilityIdentifier("diagnostics.enginememory")
                }
                if let footprint = model.metrics.appFootprintBytes {
                    LabeledContent("App memory") { Text(MetricsFormat.bytes(footprint)).monospacedDigit() }
                }
            }
            .transaction { $0.animation = nil }

            Section("Traffic") {
                LabeledContent("Devices connected") {
                    Text("\(model.connectedCount) of \(model.devices.count)").monospacedDigit()
                }
                LabeledContent("Transfer rate") { RatePair(rate: model.metrics.totalRate).font(.callout) }
                    .accessibilityIdentifier("diagnostics.rates")
                if let t = model.metrics.traffic {
                    LabeledContent("Received this session") { Text(MetricsFormat.bytes(t.inBytesTotal)).monospacedDigit() }
                    LabeledContent("Sent this session") { Text(MetricsFormat.bytes(t.outBytesTotal)).monospacedDigit() }
                }
            }
            .transaction { $0.animation = nil }
            .task { await model.metrics.watchTraffic() }

            if let info, model.isRunning {
                Section {
                    ForEach(info.syncListeners, id: \.address) { l in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l.address).font(.callout.monospaced())
                            ForEach(Array(Set(l.lanAddresses + l.wanAddresses)).sorted(), id: \.self) { a in
                                Text(a).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if let e = l.error { Text(e).font(.caption).foregroundStyle(.red) }
                        }
                        .textSelection(.enabled)
                    }
                } header: { Text("Listening addresses") }
                .accessibilityIdentifier("diagnostics.listeners")

                Section("Discovery and relays") {
                    LabeledContent("Discovery") {
                        if !info.discoveryEnabled || info.discovery.isEmpty {
                            Text("Off")
                        } else {
                            Text("\(info.discoveryWorking) of \(info.discovery.count) working").monospacedDigit()
                        }
                    }
                    .accessibilityIdentifier("diagnostics.discovery")
                    ForEach(info.discovery, id: \.method) { d in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.method).font(.callout)
                                if let e = d.error { Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        } icon: {
                            Image(systemName: d.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(d.error == nil ? .green : .orange)
                        }
                    }
                    LabeledContent("Relays") {
                        if info.relayListeners.isEmpty { Text("Off") }
                        else if info.relayConnected { Text("Connected") }
                        else { Text("Not connected") }
                    }
                    .accessibilityIdentifier("diagnostics.relays")
                }
            }
        }
        .glassScreen()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.metrics.watchSystem() }
    }
}
