import Foundation
import Security

/// Lightweight, zero-dependency iOS Keychain wrapper for persisting Firebase Auth tokens
/// and user credentials securely on-device without requiring any special entitlements.
public enum KeychainHelper {
    public static let defaultService = "com.yuvaraja.buddy.cloudsync"

    @discardableResult
    public static func saveString(_ value: String, account: String, service: String = defaultService) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return saveData(data, account: account, service: service)
    }

    public static func loadString(account: String, service: String = defaultService) -> String? {
        guard let data = loadData(account: account, service: service) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func saveData(_ data: Data, account: String, service: String = defaultService) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Delete existing item first to avoid errSecDuplicateItem across updates.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    public static func loadData(account: String, service: String = defaultService) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    public static func delete(account: String, service: String = defaultService) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
