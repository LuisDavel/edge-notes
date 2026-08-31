import Foundation
import Security
import EdgeNotesCore

/// Stores the Day API token in the macOS Keychain — never in UserDefaults,
/// never written to disk in the clear, and never logged. `DaySettings`
/// pairs this with the (non-secret) base URL kept in UserDefaults.
enum DayKeychain {
    private static let service = "com.luisdavel.edgenotes.day"
    private static let account = "api-token"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Reads the stored token, or nil if none is present or it cannot be
    /// decoded. Never throws and never logs the token value.
    static func readToken() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Writes (adding or updating as needed) the token to the Keychain.
    static func writeToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        if readToken() != nil {
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        } else {
            var attributes = baseQuery()
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    /// Removes any stored token. Safe to call when none exists.
    static func deleteToken() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}

/// Persisted Day API configuration: the base URL lives in UserDefaults (not
/// secret), the token lives only in `DayKeychain`. `credentials` is nil
/// whenever either half is missing, so callers never need to special-case
/// a half-configured state.
enum DaySettings {
    private static let baseURLKey = "day.baseURL"

    static var baseURL: URL? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: baseURLKey) else { return nil }
            return URL(string: raw)
        }
        set {
            UserDefaults.standard.set(newValue?.absoluteString, forKey: baseURLKey)
        }
    }

    static var credentials: DayCredentials? {
        guard let baseURL, let token = DayKeychain.readToken(), !token.isEmpty else {
            return nil
        }
        return DayCredentials(baseURL: baseURL, token: token)
    }
}

extension Notification.Name {
    /// Posted after Day credentials are saved from `DaySettingsWindow`. The
    /// left-edge deck (Task 5) will observe this to reconfigure itself;
    /// this task only posts it.
    static let dayCredentialsChanged = Notification.Name("dayCredentialsChanged")
}
