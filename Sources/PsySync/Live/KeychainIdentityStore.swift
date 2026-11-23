import CryptoKit
import Foundation
import Security

/// Persists the device identity (PEM certificate + private key).
public protocol IdentityStoring: Sendable {
    func load() throws -> DeviceIdentity?
    /// Stores `identity`, replacing any previous one.
    func save(_ identity: DeviceIdentity) throws
}

public enum IdentityStoreError: Error, Hashable, Sendable {
    case keychainStatus(Int32)
    case corrupt(String)
}

/// Raw generic-password storage, injectable for tests (the data-protection
/// keychain needs entitlements unit tests on macOS do not have).
public protocol KeychainBackend: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(service: String, account: String, data: Data) throws
    func delete(service: String, account: String) throws
}

/// Keychain-backed identity (reuses an existing
/// identity so the device ID stays stable).
///
/// - Current format: account `device-identity-v2`, JSON
///   `{"certificatePEM": base64, "privateKeyPEM": base64}`.
/// - Legacy format (GoCore/mobilebridge/identity.go): account
///   `device-certificate`, binary `PSYNGID\0 | u16 version=1 | u32 certLen |
///   u32 keyLen | cert DER | PKCS#8 key DER | sha256(all previous)`.
///   On first `load()` it is converted to PEM, saved in the v2 format and the
///   legacy item is deleted.
public struct KeychainIdentityStore: IdentityStoring {
    public static let service = "io.psynguechthyngue.syncthing.identity"
    public static let account = "device-identity-v2"
    public static let legacyAccount = "device-certificate"

    private let backend: any KeychainBackend

    public init(backend: any KeychainBackend) {
        self.backend = backend
    }

    /// Shared access group (App + File Provider extension) from Info.plist
    /// `PsyKeychainAccessGroup`, same key the legacy store used.
    public init(accessGroup: String?) {
        self.init(backend: SecItemKeychainBackend(accessGroup: accessGroup))
    }

    public func load() throws -> DeviceIdentity? {
        if let data = try backend.read(service: Self.service, account: Self.account) {
            return try Self.decodeV2(data)
        }
        guard let legacy = try backend.read(service: Self.service, account: Self.legacyAccount) else {
            return nil
        }
        let identity = try Self.decodeLegacy(legacy)
        try save(identity)
        try backend.delete(service: Self.service, account: Self.legacyAccount)
        return identity
    }

    public func save(_ identity: DeviceIdentity) throws {
        try backend.write(service: Self.service, account: Self.account, data: Self.encodeV2(identity))
    }

    private struct V2: Codable {
        var certificatePEM: Data
        var privateKeyPEM: Data
    }

    static func encodeV2(_ identity: DeviceIdentity) throws -> Data {
        try JSONEncoder().encode(V2(certificatePEM: identity.certificatePEM, privateKeyPEM: identity.privateKeyPEM))
    }

    static func decodeV2(_ data: Data) throws -> DeviceIdentity {
        guard let v2 = try? JSONDecoder().decode(V2.self, from: data) else {
            throw IdentityStoreError.corrupt("v2 json")
        }
        let id = try DeviceIDCodec.deviceID(certificatePEM: v2.certificatePEM)
        _ = try DeviceIDCodec.derFromPEM(v2.privateKeyPEM, type: "PRIVATE KEY")
        return DeviceIdentity(certificatePEM: v2.certificatePEM, privateKeyPEM: v2.privateKeyPEM, deviceID: id)
    }

    static let legacyMagic = Data("PSYNGID".utf8) + Data([0])
    static let legacyHeaderSize = 8 + 2 + 4 + 4

    static func decodeLegacy(_ blob: Data) throws -> DeviceIdentity {
        let b = [UInt8](blob)
        guard b.count >= legacyHeaderSize + 32, Data(b[0..<8]) == legacyMagic else {
            throw IdentityStoreError.corrupt("legacy header")
        }
        func u16(_ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
        func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        guard u16(8) == 1 else { throw IdentityStoreError.corrupt("legacy version") }
        let certLen = u32(10), keyLen = u32(14)
        let payload = legacyHeaderSize + certLen + keyLen
        guard certLen > 0, keyLen > 0, payload + 32 == b.count else { throw IdentityStoreError.corrupt("legacy lengths") }
        let digest = Data(SHA256Digest(b[0..<payload]))
        guard digest == Data(b[payload...]) else { throw IdentityStoreError.corrupt("legacy checksum") }
        let certDER = Data(b[legacyHeaderSize..<(legacyHeaderSize + certLen)])
        let keyDER = Data(b[(legacyHeaderSize + certLen)..<payload])
        return DeviceIdentity(
            certificatePEM: DeviceIDCodec.pem(der: certDER, type: "CERTIFICATE"),
            privateKeyPEM: DeviceIDCodec.pem(der: keyDER, type: "PRIVATE KEY"),
            deviceID: DeviceIDCodec.deviceID(certificateDER: certDER)
        )
    }
}

private func SHA256Digest(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
    Array(SHA256.hash(data: Data(bytes)))
}

/// `SecItem*` generic passwords in the data-protection keychain,
/// `AfterFirstUnlockThisDeviceOnly`, never synchronised.
public struct SecItemKeychainBackend: KeychainBackend {
    private let accessGroup: String?

    public init(accessGroup: String?) {
        if let accessGroup, !accessGroup.isEmpty, !accessGroup.contains("$(") {
            self.accessGroup = accessGroup
        } else {
            self.accessGroup = nil
        }
    }

    private func query(_ service: String, _ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read(service: String, account: String) throws -> Data? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw IdentityStoreError.keychainStatus(status)
        }
    }

    public func write(service: String, account: String, data: Data) throws {
        let q = query(service, account)
        let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess: return
        case errSecItemNotFound:
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw IdentityStoreError.keychainStatus(status) }
        default:
            throw IdentityStoreError.keychainStatus(update)
        }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityStoreError.keychainStatus(status)
        }
    }
}

/// In-memory backend for tests and previews.
public final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(service: String, account: String) throws -> Data? {
        lock.withLock { items["\(service)/\(account)"] }
    }

    public func write(service: String, account: String, data: Data) throws {
        lock.withLock { items["\(service)/\(account)"] = data }
    }

    public func delete(service: String, account: String) throws {
        _ = lock.withLock { items.removeValue(forKey: "\(service)/\(account)") }
    }
}
