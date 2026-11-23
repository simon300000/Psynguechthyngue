import Foundation
import Testing
@testable import PsySync

@Suite struct StorageBreakdownTests {
    let gb: Int64 = 1_000_000_000

    func folder(_ id: String, _ bytes: Int64, mode: ContentMode = .everything, paused: Bool = false) -> StorageBreakdown.FolderUsage {
        .init(id: FolderID(rawValue: id), label: id, localBytes: bytes, contentMode: mode, paused: paused)
    }

    @Test func segmentsAreFoldersLargestFirstThenOtherThenAvailable() {
        let b = StorageBreakdown(totalCapacity: 100 * gb, availableCapacity: 40 * gb,
                                 folders: [folder("small", 2 * gb), folder("big", 10 * gb)])
        #expect(b.segments.map(\.kind) == [.folder(FolderID(rawValue: "big"), colorIndex: 0),
                                          .folder(FolderID(rawValue: "small"), colorIndex: 1), .other, .available])
        #expect(b.segments.map(\.bytes) == [10 * gb, 2 * gb, 48 * gb, 40 * gb])
        #expect(b.segments.map(\.fraction) == [0.10, 0.02, 0.48, 0.40])
        #expect(b.segments.reduce(0) { $0 + $1.bytes } == 100 * gb)
        #expect(b.syncedBytes == 12 * gb && b.usedCapacity == 60 * gb)
        #expect(abs(b.shareOfSynced(b.folders[0]) - 10.0 / 12.0) < 1e-9)
    }

    @Test func zeroByteAndPausedFoldersAreListedButEmptyOnesNotDrawn() {
        let b = StorageBreakdown(totalCapacity: 100 * gb, availableCapacity: 50 * gb, folders: [
            folder("empty", 0, mode: .onDemand), folder("paused", 5 * gb, paused: true), folder("negative", -3),
        ])
        #expect(b.folders.map(\.label) == ["paused", "empty", "negative"])   // ties by label
        #expect(b.folders.last?.localBytes == 0)                              // clamped
        #expect(b.segments.map(\.kind) == [.folder(FolderID(rawValue: "paused"), colorIndex: 0), .other, .available])
        #expect(b.colorIndex(of: FolderID(rawValue: "empty")) == nil)
        #expect(b.shareOfSynced(b.folders[1]) == 0)
    }

    @Test func nothingSyncedAndUnknownCapacity() {
        let none = StorageBreakdown(totalCapacity: 64 * gb, availableCapacity: 64 * gb, folders: [])
        #expect(none.segments.map(\.kind) == [.available])
        #expect(none.syncedBytes == 0)
        let unknown = StorageBreakdown(totalCapacity: 0, availableCapacity: 0, folders: [folder("a", gb)])
        #expect(!unknown.hasCapacity)
        #expect(unknown.segments.isEmpty || unknown.segments.allSatisfy { $0.fraction == 0 })
        #expect(unknown.displayFractions().allSatisfy { $0 == 0 })
    }

    @Test func foldersLargerThanUsedSpaceAreScaledToFit() {
        // Stale capacity: folders claim 30 GB but only 20 GB is used.
        let b = StorageBreakdown(totalCapacity: 100 * gb, availableCapacity: 80 * gb,
                                 folders: [folder("a", 20 * gb), folder("b", 10 * gb)])
        #expect(b.segments.map(\.kind).contains(.other) == false)
        let total = b.segments.reduce(Int64(0)) { $0 + $1.bytes }
        #expect(abs(total - 100 * gb) <= 1)
        #expect(b.segments.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
        // Available larger than total is clamped.
        let c = StorageBreakdown(totalCapacity: 10, availableCapacity: 50, folders: [])
        #expect(c.availableCapacity == 10)
    }

    @Test func foldersBeyondThePaletteShareOneSegment() {
        let many = (1...8).map { folder("f\($0)", Int64($0) * gb) }
        let b = StorageBreakdown(totalCapacity: 200 * gb, availableCapacity: 100 * gb, folders: many)
        let folderSegs = b.segments.filter { if case .folder = $0.kind { return true } else { return false } }
        #expect(folderSegs.count == StorageBreakdown.paletteSize - 1)
        #expect(b.segments.contains { $0.kind == .otherFolders(count: 3) && $0.bytes == 6 * gb })   // f1+f2+f3
        #expect(b.colorIndex(of: FolderID(rawValue: "f8")) == 0)
        #expect(b.colorIndex(of: FolderID(rawValue: "f1")) == nil)
    }

    @Test func displayFractionsKeepTinySegmentsVisibleAndSumToOne() {
        let b = StorageBreakdown(totalCapacity: 1000 * gb, availableCapacity: 500 * gb,
                                 folders: [folder("tiny", 1_000_000), folder("big", 100 * gb)])
        let d = b.displayFractions(minimum: 0.01)
        #expect(d.count == b.segments.count)
        #expect(abs(d.reduce(0, +) - 1) < 1e-9)
        #expect(d.allSatisfy { $0 >= 0.01 })
        #expect(d[0] == b.segments[0].fraction)   // the large folder keeps its true size
    }
}
