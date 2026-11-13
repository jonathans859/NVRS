import Foundation
import Security

/// Minimal keychain wrapper for the shared secret: the active one, plus one
/// per saved connection. `AfterFirstUnlock` so background reconnects can
/// still read it.
enum KeychainHelper {
    private static let service = "com.jonathan859.nvrs"
    private static let activeAccount = "shared-secret"

    private static func savedAccount(_ connectionID: String) -> String {
        "saved-secret:\(connectionID)"
    }

    private static func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        // The iOS-style keychain; the legacy file-based one ignores
        // kSecAttrAccessible. Requires a signed, sandboxed app (ours is).
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    static func saveSecret(_ value: String) {
        save(value, account: activeAccount)
    }

    static func loadSecret() -> String {
        load(account: activeAccount)
    }

    static func saveSecret(_ value: String, forConnection id: String) {
        save(value, account: savedAccount(id))
    }

    static func loadSecret(forConnection id: String) -> String {
        load(account: savedAccount(id))
    }

    static func deleteSecret(forConnection id: String) {
        SecItemDelete(baseQuery(account: savedAccount(id)) as CFDictionary)
    }

    private static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func load(account: String) -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }
}
