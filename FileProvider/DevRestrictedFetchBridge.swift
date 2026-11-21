#if DEBUG
import Foundation
import PsySync

/// DEBUG-only stand-in for psybridge.FetchFile until WP-A's adapter is linked.
/// Active only when `<AppGroup>/DevFetchSource/` exists (created by the
/// simulator acceptance script); serves `DevFetchSource/<folder>/<path>` as
/// if a peer had sent it, block by block, honouring cancellation. Everything
/// around it (engine lock, staging, move into the folder, journal, App rescan)
/// is the production code path.
struct DevRestrictedFetchBridge: RestrictedFetchBridge {
    static let identity = DeviceIdentity(
        certificatePEM: Data(), privateKeyPEM: Data(), deviceID: DeviceID(rawValue: "DEV-FETCH"))

    let source: URL

    init?(layout: AppGroupLayout) {
        let source = layout.root.appending(path: "DevFetchSource", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { return nil }
        self.source = source
    }

    func fetch(
        homeDirectory: URL, identity: DeviceIdentity, folder: FolderID, path: RelativePath, expectedVersion: String?,
        destination: URL, budget: RestrictedFetchBudget, progress: @escaping @Sendable (Int64, Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> RestrictedFetchResult {
        let file = source.appending(path: folder.rawValue).appending(path: path.rawValue)
        guard let input = FileHandle(forReadingAtPath: file.path(percentEncoded: false)) else {
            throw EngineError.bridge(code: BridgeContract.Code.noPeer.rawValue, detail: "dev source missing")
        }
        defer { try? input.close() }
        let total = Int64((try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? NSNumber)?.int64Value ?? 0)
        guard total <= budget.maxFileBytes else {
            throw EngineError.bridge(code: BridgeContract.Code.tooLarge.rawValue, detail: "")
        }
        FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var done: Int64 = 0
        while let block = try input.read(upToCount: 128 << 10), !block.isEmpty {
            if isCancelled() { throw EngineError.bridge(code: BridgeContract.Code.cancelled.rawValue, detail: "") }
            try output.write(contentsOf: block)
            done += Int64(block.count)
            progress(done, total)
        }
        try output.synchronize()
        // Like FetchFile: carry the source mtime so the App's rescan matches.
        if let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false)))?[.modificationDate] {
            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: destination.path(percentEncoded: false))
        }
        return RestrictedFetchResult(stagedFile: destination, size: done, version: "dev", servedBy: [identity.deviceID])
    }

    /// No engine database to update in the dev stand-in; records the call so
    /// the harness log shows the commit order.
    func recordFetchedFile(
        homeDirectory: URL, identity: DeviceIdentity, folder: FolderID, path: RelativePath, version: String
    ) throws {
        NSLog("DevRestrictedFetchBridge.recordFetchedFile %@ %@", folder.rawValue, path.rawValue)
    }
}
#endif
