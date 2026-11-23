import PsySync
import SwiftUI
import UIKit

// Settings ▸ Storage: how much space each synced folder takes on this device,
// next to everything else and the free space (like Settings ▸ iPhone Storage).
//
// Data: each folder's "on this device" bytes are the same figure the folder
// detail shows (`AppModel.status(of:).progress.localBytes`); file counts come
// from `SyncEngine.folderDetails`; capacity from the volume's resource values.
// The page keeps its own snapshot and rebuilds it at most once a second, so
// sync events do not re-render it more often.

/// Volume capacity of the device (`URLResourceValues`).
enum DeviceStorage {
    struct Capacity: Equatable {
        var total: Int64
        var available: Int64
    }

    /// Fixture runs show a fixed device so screenshots and UI tests are stable.
    static func current(fixture: Bool) -> Capacity? {
        if fixture { return Capacity(total: 128_000_000_000, available: 41_300_000_000) }
        let url = URL(filePath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, total > 0 else { return nil }
        return Capacity(total: Int64(total), available: v.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

extension StorageBreakdown.Segment.Kind {
    var color: Color {
        switch self {
        case let .folder(_, i): StorageView.palette[i % StorageView.palette.count]
        case .otherFolders: Color(.systemBrown)
        case .other: Color(.systemGray2)
        case .available: Color(.systemGray5)
        }
    }
}

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var breakdown: StorageBreakdown?
    @State private var capacity: DeviceStorage.Capacity?
    @State private var fileCounts: [FolderID: Int64] = [:]

    static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let breakdown {
                    VStack(spacing: 10) {
                        CardHeader(title: "This device", systemImage: Self.deviceSymbol)
                        DeviceStorageCard(breakdown: breakdown, labels: folderLabels(breakdown))
                    }
                    VStack(spacing: 10) {
                        CardHeader(title: "Synced folders", systemImage: "folder")
                        FolderStorageList(breakdown: breakdown)
                    }
                } else {
                    ProgressView().padding(40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .glassScreen()
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshLoop() }
    }

    private static var deviceSymbol: String {
        if ProcessInfo.processInfo.isiOSAppOnMac { return "laptopcomputer" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    private func folderLabels(_ b: StorageBreakdown) -> [FolderID: String] {
        Dictionary(uniqueKeysWithValues: b.folders.map { ($0.id, $0.label) })
    }

    /// Rebuilds the snapshot at most once a second while the page is visible.
    /// Capacity and file counts change slowly: every 10 s.
    private func refreshLoop() async {
        var tick = 0
        while !Task.isCancelled {
            if tick % 10 == 0 {
                capacity = DeviceStorage.current(fixture: model.isFixture)
                await refreshFileCounts()
            }
            let next = makeBreakdown()
            if next != breakdown { breakdown = next }
            tick += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func refreshFileCounts() async {
        guard model.isRunning else { return }
        var counts = fileCounts
        for folder in model.folders {
            if let d = try? await model.engine.folderDetails(folder.id) { counts[folder.id] = d.local.files }
        }
        if counts != fileCounts { fileCounts = counts }
    }

    private func makeBreakdown() -> StorageBreakdown {
        let usages = model.folders.map { f in
            StorageBreakdown.FolderUsage(
                id: f.id, label: f.label, localBytes: model.status(of: f).progress.localBytes,
                contentMode: f.contentMode, paused: f.paused, localFiles: fileCounts[f.id])
        }
        return StorageBreakdown(totalCapacity: capacity?.total ?? 0, availableCapacity: capacity?.available ?? 0, folders: usages)
    }
}

/// "Used X of Y", the segmented bar and its legend.
struct DeviceStorageCard: View {
    let breakdown: StorageBreakdown
    let labels: [FolderID: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if breakdown.hasCapacity {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(MetricsFormat.bytes(breakdown.usedCapacity)) of \(MetricsFormat.bytes(breakdown.totalCapacity)) used")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .accessibilityIdentifier("storage.used")
                    Text("Synced folders use \(MetricsFormat.bytes(breakdown.syncedBytes))")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                StorageBar(breakdown: breakdown)
                    .frame(height: 22)
                    .accessibilityIdentifier("storage.bar")
                legend
            } else {
                Text("The device’s storage could not be read.")
                    .foregroundStyle(.secondary)
                Text("Synced folders use \(MetricsFormat.bytes(breakdown.syncedBytes))")
                    .font(.subheadline).monospacedDigit()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .transaction { $0.animation = nil }
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(breakdown.segments) { s in
                HStack(spacing: 6) {
                    Circle().fill(s.kind.color).frame(width: 10, height: 10)
                        .overlay { Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title(s.kind)).font(.caption).lineLimit(1)
                        Text(MetricsFormat.bytes(s.bytes)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("storage.legend")
    }

    private func title(_ kind: StorageBreakdown.Segment.Kind) -> String {
        switch kind {
        case let .folder(id, _): labels[id] ?? id.rawValue
        case let .otherFolders(n): String(localized: "\(n) more folders")
        case .other: String(localized: "Other apps & system")
        case .available: String(localized: "Available")
        }
    }
}

/// The segmented capsule. Tiny segments get a minimum width so they stay visible.
struct StorageBar: View {
    let breakdown: StorageBreakdown

    var body: some View {
        GeometryReader { geo in
            let widths = breakdown.displayFractions()
            let gaps = CGFloat(max(0, widths.filter { $0 > 0 }.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(Array(zip(breakdown.segments, widths)), id: \.0.id) { s, w in
                    if w > 0 {
                        Rectangle().fill(s.kind.color)
                            .frame(width: max(0, (geo.size.width - gaps) * w))
                    }
                }
            }
            .clipShape(Capsule())
            .overlay { Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Storage"))
        .accessibilityValue(Text("\(MetricsFormat.bytes(breakdown.usedCapacity)) of \(MetricsFormat.bytes(breakdown.totalCapacity)) used"))
    }
}

/// Folders by local size, largest first; tap opens the folder.
struct FolderStorageList: View {
    let breakdown: StorageBreakdown

    var body: some View {
        if breakdown.folders.isEmpty {
            Text("No folders yet")
                .foregroundStyle(.secondary)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(breakdown.folders.enumerated()), id: \.element.id) { index, f in
                    if index > 0 { Divider().padding(.leading, 40) }
                    NavigationLink { FolderDetailView(folderID: f.id) } label: { row(f) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("storage.folder.\(f.label)")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .glassCard()
            .transaction { $0.animation = nil }
        }
    }

    private func row(_ f: StorageBreakdown.FolderUsage) -> some View {
        let color = breakdown.colorIndex(of: f.id).map { StorageView.palette[$0 % StorageView.palette.count] }
            ?? (f.localBytes > 0 ? Color(.systemBrown) : Color(.systemGray4))
        let share = breakdown.shareOfSynced(f)
        return HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.gradient)
                .frame(width: 22, height: 22)
                .overlay { Image(systemName: f.paused ? "pause.fill" : "folder.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(f.label).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(MetricsFormat.bytes(f.localBytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: min(max(share, 0), 1))
                    .tint(color)
                HStack {
                    Text(detail(f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(share, format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func detail(_ f: StorageBreakdown.FolderUsage) -> String {
        var parts = [f.contentMode == .onDemand ? String(localized: "On demand") : String(localized: "Everything")]
        if let n = f.localFiles { parts.append(String(localized: "\(n) files")) }
        if f.paused { parts.append(String(localized: "Paused")) }
        return parts.joined(separator: " · ")
    }
}
