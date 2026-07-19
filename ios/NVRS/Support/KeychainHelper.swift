import Foundation
import Security

/// Minimal keychain wrapper for the shared secret. `AfterFirstUnlock` so
/// background reconnects can still read it.
enum KeychainHelper {
    private static let service = "com.jonathan859.nvrs"
    private static let account = "shared-secret"

    private static var baseQuery: [String: Any] {
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
        let data = Data(value.utf8)
        let query = baseQuery
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadSecret() -> String {
        var query = baseQuery
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
