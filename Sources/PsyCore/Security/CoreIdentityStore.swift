import Foundation
import Security

public protocol CoreIdentityStoring: Sendable {
    func load() throws -> Data?
    func saveIfAbsent(_ identity: Data) throws
}

public enum CoreIdentityStoreError: Error, Hashable, Sendable, LocalizedError {
    case emptyIdentity
    case identityAlreadyExists
    case keychainStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .emptyIdentity:
            "The Syncthing device identity is empty."
        case .identityAlreadyExists:
            "A different Syncthing device identity already exists in the Keychain."
        case .keychainStatus(let status):
            "The Keychain operation failed (OSStatus \(status))."
        }
    }
}

/// Stores the opaque certificate and private-key blob produced by the Go bridge.
/// The bytes never need to be written to the App Group container or a temporary file.
public struct KeychainCoreIdentityStore: CoreIdentityStoring, Sendable {
    public static let defaultService = "io.psynguechthyngue.syncthing.identity"
    public static let defaultAccount = "device-certificate"

    private let accessGroup: String?
    private let service: String
    private let account: String

    public init(
        accessGroup: String? = nil,
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        if let accessGroup, !accessGroup.isEmpty, !accessGroup.contains("$(") {
            self.accessGroup = accessGroup
        } else {
            self.accessGroup = nil
        }
        self.service = service
        self.account = account
    }

    public init(bundle: Bundle) {
        self.init(accessGroup: bundle.object(forInfoDictionaryKey: "PsyKeychainAccessGroup") as? String)
    }

    public func load() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else {
                throw CoreIdentityStoreError.emptyIdentity
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CoreIdentityStoreError.keychainStatus(status)
        }
    }

    public func saveIfAbsent(_ identity: Data) throws {
        guard !identity.isEmpty else { throw CoreIdentityStoreError.emptyIdentity }
        var attributes = baseQuery()
        attributes[kSecValueData as String] = identity
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            guard try load() == identity else {
                throw CoreIdentityStoreError.identityAlreadyExists
            }
        default:
            throw CoreIdentityStoreError.keychainStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
