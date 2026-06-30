import Foundation
import Security

/// Stores the long-lived bearer token in the iOS Keychain.
/// Service name namespaces all entries under the app's bundle id.
/// Access class is `kSecAttrAccessibleAfterFirstUnlock` so silent-push background
/// refresh can read it without unlocking the device.
public final class KeychainStore: Sendable {
    public static let service: String = "com.trilliumsmith.forefront"
    public static let tokenAccount: String = "auth-token"

    public init() {}

    public func storeToken(_ token: String) throws {
        let data = Data(token.utf8)
        // Delete any existing entry first; SecItemUpdate has surprising semantics
        // when the access attribute changes.
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: KeychainStore.service,
            kSecAttrAccount: KeychainStore.tokenAccount
        ] as CFDictionary)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: KeychainStore.service,
            kSecAttrAccount: KeychainStore.tokenAccount,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    public func loadToken() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: KeychainStore.service,
            kSecAttrAccount: KeychainStore.tokenAccount,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    public func deleteToken() throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: KeychainStore.service,
            kSecAttrAccount: KeychainStore.tokenAccount
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }
}

public enum KeychainError: Error, Equatable, Sendable {
    case osStatus(OSStatus)
}
