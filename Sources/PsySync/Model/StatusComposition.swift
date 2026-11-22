import Foundation

/// Progress of the Files list for one folder (App: FilesProjector pass).
public struct FilesListingProgress: Hashable, Sendable {
    /// Index entries read in the running pass.
    public var processed: Int
    /// Rows the Files list had when the pass started.
    public var listedAtStart: Int

    public init(processed: Int, listedAtStart: Int) {
        self.processed = processed
        self.listedAtStart = listedAtStart
    }
}

/// What the App shows for a folder: the engine's status plus App-side work
/// the engine does not know about. "Up to date" only when nothing is left.
public enum FolderStatusComposer {
    public static func compose(
        folderID: FolderID, engine: FolderStatus?, engineRunning: Bool, listing: FilesListingProgress?
    ) -> FolderStatus {
        guard engineRunning else {
            // A stopped/failed engine says nothing current about the folder;
            // keep the last numbers but never "up to date" / "syncing".
            var s = engine ?? FolderStatus(folderID: folderID, state: .offline)
            s.state = .offline
            return s
        }
        // No status yet (just started / just added): nothing is known.
        guard var status = engine else { return FolderStatus(folderID: folderID, state: .fetchingIndex) }
        if status.state == .upToDate, let listing, isAddingRows(listing, total: status.progress.globalItems) {
            status.state = .preparingFiles
        }
        return status
    }

    /// A pass over a list that is already complete (every engine start
    /// re-reads the index) is not user-visible work; one that is filling a
    /// list behind the index (first projection, interrupted pass) is.
    static func isAddingRows(_ listing: FilesListingProgress, total: Int64) -> Bool {
        // Root row + `.stfolder`-style hidden entries make the counts differ
        // slightly; only a real gap counts.
        Int64(listing.listedAtStart) + 1 < total
    }
}
