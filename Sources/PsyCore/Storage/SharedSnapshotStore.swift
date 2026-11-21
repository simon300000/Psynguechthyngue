import Foundation

public enum SharedSnapshotError: Error, Sendable {
    case unsupportedSchema(Int)
    case invalidConfigurationRevision
    case generationRegression(current: UInt64, proposed: UInt64)
    case ownerLeaseMismatch
}

public struct SharedSnapshotStore: Sendable {
    private let snapshotURL: URL
    private let lockURL: URL

    public init(snapshotURL: URL) {
        self.snapshotURL = snapshotURL
        lockURL = snapshotURL.appendingPathExtension("lock")
    }

    public func read() throws -> CoreSnapshot? {
        try FileLock.withExclusiveLock(at: lockURL) {
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let value = try decoder.decode(CoreSnapshot.self, from: Data(contentsOf: snapshotURL))
            guard value.schemaVersion == 1 else { throw SharedSnapshotError.unsupportedSchema(value.schemaVersion) }
            return value
        }
    }

    /// Fast File Provider control plane. Item lookups remain in SQLite, and
    /// fallback readers explicitly request the complete canonical snapshot.
    public func readProviderMetadata() throws -> CoreSnapshot? {
        try FileLock.withExclusiveLock(at: lockURL) {
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
            let stamp = try FileProviderSnapshotMetadata.Stamp(url: snapshotURL)
            let previous = try? JSONDecoder().decode(
                FileProviderSnapshotMetadata.self, from: Data(contentsOf: providerMetadataURL))
            if let previous, previous.stamp == stamp { return previous.snapshot }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(CoreSnapshot.self, from: Data(contentsOf: snapshotURL))
            guard snapshot.schemaVersion == 1 else {
                throw SharedSnapshotError.unsupportedSchema(snapshot.schemaVersion)
            }
            let metadata = FileProviderSnapshotMetadata(snapshot: snapshot, stamp: stamp, previous: previous)
            #if os(iOS)
                try? JSONEncoder().encode(metadata).write(
                    to: providerMetadataURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            #else
                try? JSONEncoder().encode(metadata).write(to: providerMetadataURL, options: .atomic)
            #endif
            return metadata.snapshot
        }
    }

    private var providerMetadataURL: URL { snapshotURL.appendingPathExtension("provider-metadata") }

    public func write(_ snapshot: CoreSnapshot) throws {
        try write(snapshot, leaseValidation: nil)
    }

    public func write(
        _ snapshot: CoreSnapshot,
        lease: CoreOwnerLease,
        ownerMetadataURL: URL
    ) throws {
        guard snapshot.ownerEpoch == lease.epoch, snapshot.instanceID == lease.instanceID else {
            throw SharedSnapshotError.ownerLeaseMismatch
        }
        try CoreOwnerMetadataStore.withValidatedLease(lease, at: ownerMetadataURL) {
            try write(snapshot, leaseValidation: nil)
        }
    }

    private func write(
        _ snapshot: CoreSnapshot,
        leaseValidation: (() throws -> Void)?
    ) throws {
        guard snapshot.schemaVersion == 1 else { throw SharedSnapshotError.unsupportedSchema(snapshot.schemaVersion) }
        if let revision = snapshot.configurationRevision,
            !CoreSessionDigest.isLowercaseSHA256(revision)
        {
            throw SharedSnapshotError.invalidConfigurationRevision
        }
        try FileLock.withExclusiveLock(at: lockURL) {
            try leaseValidation?()
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let current = try decoder.decode(CoreSnapshot.self, from: Data(contentsOf: snapshotURL))
                guard snapshot.generation >= current.generation else {
                    throw SharedSnapshotError.generationRegression(
                        current: current.generation,
                        proposed: snapshot.generation
                    )
                }
            }
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            #if os(iOS)
                let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
            #else
                let writeOptions: Data.WritingOptions = [.atomic]
            #endif
            try encoder.encode(snapshot).write(to: snapshotURL, options: writeOptions)
            // This is rebuildable, not a second source of authority. Publishing
            // canonical bytes must not fail because its optional projection did.
            if let stamp = try? FileProviderSnapshotMetadata.Stamp(url: snapshotURL) {
                let previous = try? JSONDecoder().decode(
                    FileProviderSnapshotMetadata.self, from: Data(contentsOf: providerMetadataURL))
                let metadata = FileProviderSnapshotMetadata(snapshot: snapshot, stamp: stamp, previous: previous)
                try? JSONEncoder().encode(metadata).write(to: providerMetadataURL, options: writeOptions)
            }
        }
    }
}
