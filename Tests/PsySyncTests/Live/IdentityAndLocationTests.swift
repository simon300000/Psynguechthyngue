import CryptoKit
import Foundation
import Testing
@testable import PsySync

@Suite struct DeviceIDCodecTests {
    @Test func matchesUpstreamForFixtureCertificate() throws {
        let pem = try Fixtures.data("identity/cert.pem")
        let expected = String(decoding: try Fixtures.data("identity/device-id.txt"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try DeviceIDCodec.deviceID(certificatePEM: pem).rawValue == expected)
        #expect(DeviceIDCodec.isValid(expected))
    }

    @Test func validatesRecordedIDs() throws {
        let status = try JSONDecoder().decode(SystemStatusDTO.self, from: Fixtures.data("system_status.json"))
        #expect(DeviceIDCodec.isValid(status.myID))
        var corrupted = Array(status.myID)
        corrupted[3] = corrupted[3] == "A" ? "B" : "A"
        #expect(!DeviceIDCodec.isValid(String(corrupted)))
        #expect(!DeviceIDCodec.isValid("short"))
    }

    @Test func randomIDsAreValidAndDistinct() {
        let ids = (0..<50).map { _ in DeviceIDCodec.random() }
        #expect(ids.allSatisfy { DeviceIDCodec.isValid($0.rawValue) })
        #expect(Set(ids).count == 50)
    }

    @Test func rejectsBadPEM() {
        #expect(throws: DeviceIDCodec.CodecError.self) { try DeviceIDCodec.deviceID(certificatePEM: Data("nope".utf8)) }
    }
}

@Suite struct KeychainIdentityStoreTests {
    func certDER() throws -> Data { try DeviceIDCodec.derFromPEM(Fixtures.data("identity/cert.pem"), type: "CERTIFICATE") }

    func legacyBlob(cert: Data, key: Data) -> Data {
        var b = KeychainIdentityStore.legacyMagic
        b.append(contentsOf: [0, 1])
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        b.append(contentsOf: u32(cert.count))
        b.append(contentsOf: u32(key.count))
        b.append(cert)
        b.append(key)
        b.append(Data(SHA256.hash(data: b)))
        return b
    }

    @Test func emptyStoreReturnsNil() throws {
        #expect(try KeychainIdentityStore(backend: InMemoryKeychainBackend()).load() == nil)
    }

    @Test func roundTrip() throws {
        let store = KeychainIdentityStore(backend: InMemoryKeychainBackend())
        let pem = try Fixtures.data("identity/cert.pem")
        let id = DeviceIdentity(certificatePEM: pem, privateKeyPEM: DeviceIDCodec.pem(der: Data([9, 9]), type: "PRIVATE KEY"),
                                deviceID: try DeviceIDCodec.deviceID(certificatePEM: pem))
        try store.save(id)
        #expect(try store.load() == id)
    }

    @Test func migratesLegacyBlobAndKeepsDeviceID() throws {
        let backend = InMemoryKeychainBackend()
        let key = Data((0..<48).map { UInt8($0) })
        try backend.write(service: KeychainIdentityStore.service, account: KeychainIdentityStore.legacyAccount,
                          data: legacyBlob(cert: certDER(), key: key))
        let store = KeychainIdentityStore(backend: backend)
        let identity = try #require(try store.load())
        let expected = String(decoding: try Fixtures.data("identity/device-id.txt"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(identity.deviceID.rawValue == expected)
        #expect(try DeviceIDCodec.derFromPEM(identity.privateKeyPEM, type: "PRIVATE KEY") == key)
        #expect(try backend.read(service: KeychainIdentityStore.service, account: KeychainIdentityStore.legacyAccount) == nil)
        #expect(try store.load() == identity)
    }

    @Test func rejectsCorruptLegacy() throws {
        let backend = InMemoryKeychainBackend()
        var blob = legacyBlob(cert: try certDER(), key: Data([1, 2, 3]))
        blob[30] ^= 0xff
        try backend.write(service: KeychainIdentityStore.service, account: KeychainIdentityStore.legacyAccount, data: blob)
        #expect(throws: IdentityStoreError.self) { try KeychainIdentityStore(backend: backend).load() }
    }
}

@Suite struct ExternalLocationTests {
    @Test func detectsCloudLocations() {
        for p in ["/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Sync",
                  "/Users/x/Library/CloudStorage/Dropbox/a",
                  "/private/var/mobile/Library/Application Support/FileProvider/1234/x",
                  "/private/var/mobile/Containers/Shared/AppGroup/1234/File Provider Storage/x"] {
            #expect(ExternalLocation.isFileProviderBacked(URL(filePath: p)), "\(p)")
        }
        #expect(!ExternalLocation.isFileProviderBacked(URL(filePath: "/private/var/mobile/Containers/Data/Application/1/Documents")))
        #expect(!ExternalLocation.isFileProviderBacked(FileManager.default.temporaryDirectory))
    }

    @Test func classifiesLocalStorageAsLocalAndOtherProvidersAsCloud() {
        typealias F = ExternalLocation.LocationFacts
        let onMyPhone = "/private/var/mobile/Containers/Shared/AppGroup/9C72/File Provider Storage/Sync"
        // "On My iPhone / iPad": the system LocalStorage group container.
        #expect(ExternalLocation.classify(F(path: onMyPhone, groupContainerIdentifier: ExternalLocation.localStorageGroup)) == .local)
        // Same shape, other owner (third-party / Photos / iCloud group) or unknown owner → refused.
        #expect(ExternalLocation.classify(F(path: onMyPhone, groupContainerIdentifier: "group.com.example.cloud")) == .cloud)
        #expect(ExternalLocation.classify(F(path: onMyPhone, groupContainerIdentifier: "group.com.apple.iCloudDrive")) == .cloud)
        #expect(ExternalLocation.classify(F(path: onMyPhone)) == .cloud)
        // Local storage but with dataless / ubiquitous content → refused.
        #expect(ExternalLocation.classify(F(path: onMyPhone, hasDatalessContent: true, groupContainerIdentifier: ExternalLocation.localStorageGroup)) == .cloud)
        #expect(ExternalLocation.classify(F(path: onMyPhone, isUbiquitous: true, groupContainerIdentifier: ExternalLocation.localStorageGroup)) == .cloud)
        // iCloud / FPFS paths are cloud whatever the container says.
        #expect(ExternalLocation.classify(F(path: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/a",
                                            groupContainerIdentifier: ExternalLocation.localStorageGroup)) == .cloud)
        // Ordinary local directories.
        #expect(ExternalLocation.classify(F(path: "/Users/x/Documents/Sync")) == .local)
        #expect(ExternalLocation.classify(F(path: "/Users/x/Documents/Sync", hasDatalessContent: true)) == .cloud)
    }

    @Test func readsGroupContainerIdentifierFromMetadataPlist() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "psy-ext-\(UUID().uuidString)")
        let group = root.appending(path: "Containers/Shared/AppGroup/ABCD")
        let dir = group.appending(path: "File Provider Storage/Sync")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ExternalLocation.isFileProviderBacked(dir))   // owner unknown
        let plist = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": ExternalLocation.localStorageGroup],
                                                       format: .xml, options: 0)
        try plist.write(to: group.appending(path: ".com.apple.mobile_container_manager.metadata.plist"))
        let facts = ExternalLocation.LocationFacts.probe(dir)
        #expect(facts.groupContainerIdentifier == ExternalLocation.localStorageGroup)
        #expect(!facts.hasDatalessContent)
        #expect(!ExternalLocation.isFileProviderBacked(dir))
        guard case .external = try ExternalLocation.makeLocation(for: dir, access: .unscoped) else {
            Issue.record("expected external"); return
        }
    }

    @Test func makeAndOpenUnscoped() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "psy-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .external(let bookmark, _) = try ExternalLocation.makeLocation(for: dir, access: .unscoped) else {
            Issue.record("expected external"); return
        }
        let scope = try ExternalLocation.open(bookmark: bookmark, access: .unscoped)
        #expect(LiveSyncEngine.samePath(scope.path, dir))
        scope.stop()
        scope.stop()
    }

    @Test func rejectsFilesAndCloud() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "psy-ext-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: ExternalLocationError.notADirectory) { try ExternalLocation.makeLocation(for: file, access: .unscoped) }
        #expect(throws: ExternalLocationError.cloudBacked) {
            try ExternalLocation.makeLocation(for: URL(filePath: "/Users/x/Library/Mobile Documents/y"), access: .unscoped)
        }
    }

    @Test func staleBookmarkIsRefreshedAndScopeBalanced() throws {
        let dir = FileManager.default.temporaryDirectory
        let counter = Counter()
        let access = ExternalLocationAccess(
            create: { _ in Data("fresh".utf8) },
            resolve: { _ in (dir, true) },
            beginAccess: { _ in counter.inc(); return true },
            endAccess: { _ in counter.dec() }
        )
        let scope = try ExternalLocation.open(bookmark: Data("old".utf8), access: access)
        #expect(scope.refreshedBookmark == Data("fresh".utf8))
        #expect(counter.value == 1)
        scope.stop()
        #expect(counter.value == 0)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0
    func inc() { lock.withLock { v += 1 } }
    func dec() { lock.withLock { v -= 1 } }
    var value: Int { lock.withLock { v } }
}
