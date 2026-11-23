import Foundation

/// Device storage split into synced folders, everything else and free space,
/// for the Storage page's segmented bar (like Settings ▸ iPhone Storage).
///
/// Pure value logic: the App supplies each folder's local bytes (the same
/// "on this device" figure the folder detail shows) and the volume's
/// capacities; this type orders, groups and measures the segments.
public struct StorageBreakdown: Hashable, Sendable {
    public struct FolderUsage: Hashable, Sendable, Identifiable {
        public var id: FolderID
        public var label: String
        public var localBytes: Int64
        public var contentMode: ContentMode
        public var paused: Bool
        /// Local file count when known (nil while loading).
        public var localFiles: Int64?

        public init(id: FolderID, label: String, localBytes: Int64, contentMode: ContentMode = .everything,
                    paused: Bool = false, localFiles: Int64? = nil) {
            self.id = id
            self.label = label
            self.localBytes = localBytes
            self.contentMode = contentMode
            self.paused = paused
            self.localFiles = localFiles
        }
    }

    public struct Segment: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            /// One synced folder; `colorIndex` picks its palette colour.
            case folder(FolderID, colorIndex: Int)
            /// Smaller folders beyond the palette, shown as one segment.
            case otherFolders(count: Int)
            /// Other apps, the system and anything not ours.
            case other
            case available
        }

        public var kind: Kind
        public var bytes: Int64
        /// Share of the device total, 0...1.
        public var fraction: Double
        public var id: Kind { kind }
    }

    /// Distinct folder colours; more folders than this share one "other folders" segment.
    public static let paletteSize = 6

    public let totalCapacity: Int64
    public let availableCapacity: Int64
    /// Folders, largest first (ties by label), including ones using 0 bytes.
    public let folders: [FolderUsage]
    public let segments: [Segment]

    /// - Parameters:
    ///   - totalCapacity: volume size (`volumeTotalCapacity`); ≤ 0 if unknown.
    ///   - availableCapacity: `volumeAvailableCapacityForImportantUsage`.
    public init(totalCapacity: Int64, availableCapacity: Int64, folders: [FolderUsage]) {
        let total = max(0, totalCapacity)
        let available = min(max(0, availableCapacity), total)
        let sorted = folders
            .map { var f = $0; f.localBytes = max(0, f.localBytes); return f }
            .sorted { $0.localBytes != $1.localBytes ? $0.localBytes > $1.localBytes
                                                     : $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        self.totalCapacity = total
        self.availableCapacity = available
        self.folders = sorted

        let used = total - available
        let inBar = sorted.filter { $0.localBytes > 0 }
        // Folder bytes can exceed "used" when the volume figures are stale or
        // the folders sit on another volume: never let segments overflow.
        let syncedTotal = inBar.reduce(Int64(0)) { $0 + $1.localBytes }
        let scale = syncedTotal > used && syncedTotal > 0 ? Double(used) / Double(syncedTotal) : 1
        func frac(_ b: Int64) -> Double { total > 0 ? Double(b) / Double(total) : 0 }

        var segs: [Segment] = []
        let named = inBar.prefix(Self.paletteSize - (inBar.count > Self.paletteSize ? 1 : 0))
        for (i, f) in named.enumerated() {
            let b = Int64((Double(f.localBytes) * scale).rounded())
            segs.append(Segment(kind: .folder(f.id, colorIndex: i), bytes: b, fraction: frac(b)))
        }
        let rest = inBar.dropFirst(named.count)
        if !rest.isEmpty {
            let b = Int64((Double(rest.reduce(Int64(0)) { $0 + $1.localBytes }) * scale).rounded())
            segs.append(Segment(kind: .otherFolders(count: rest.count), bytes: b, fraction: frac(b)))
        }
        let folderBytes = segs.reduce(Int64(0)) { $0 + $1.bytes }
        let other = max(0, used - folderBytes)
        if other > 0 { segs.append(Segment(kind: .other, bytes: other, fraction: frac(other))) }
        if available > 0 { segs.append(Segment(kind: .available, bytes: available, fraction: frac(available))) }
        self.segments = segs
    }

    /// Bytes all synced folders keep on this device.
    public var syncedBytes: Int64 { folders.reduce(0) { $0 + $1.localBytes } }
    public var usedCapacity: Int64 { totalCapacity - availableCapacity }
    public var hasCapacity: Bool { totalCapacity > 0 }

    /// A folder's share of all synced data on this device, 0...1.
    public func shareOfSynced(_ folder: FolderUsage) -> Double {
        let s = syncedBytes
        return s > 0 ? Double(folder.localBytes) / Double(s) : 0
    }

    /// Palette index of a folder's segment, nil when it is grouped or empty.
    public func colorIndex(of id: FolderID) -> Int? {
        for s in segments { if case let .folder(f, i) = s.kind, f == id { return i } }
        return nil
    }

    /// Widths for drawing: every non-empty segment gets at least `minimum`
    /// of the bar so a tiny folder stays visible; the extra is taken from the
    /// largest segments. Sums to 1 when the device total is known.
    public func displayFractions(minimum: Double = 0.012) -> [Double] {
        let raw = segments.map(\.fraction)
        guard !raw.isEmpty, raw.reduce(0, +) > 0 else { return raw }
        var out = raw.map { $0 > 0 ? max($0, minimum) : 0 }
        var excess = out.reduce(0, +) - raw.reduce(0, +)
        // Take the excess from segments above the minimum, largest first.
        for i in out.indices.sorted(by: { out[$0] > out[$1] }) where excess > 1e-12 {
            let room = out[i] - minimum
            guard room > 0 else { continue }
            let take = min(room, excess)
            out[i] -= take
            excess -= take
        }
        return out
    }
}
