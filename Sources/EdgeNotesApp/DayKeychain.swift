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

    /// True when an item already exists for our service/account, checked
    /// without asking the Keychain to decrypt/return the secret data —
    /// existence doesn't depend on the stored bytes being decodable, unlike
    /// `readToken()`.
    private static func exists() -> Bool {
        var query = baseQuery()
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Writes (adding or updating as needed) the token to the Keychain.
    /// Returns whether the write actually succeeded — callers must not
    /// assume success just because this returned. Handles the races where
    /// the existence check and the write disagree (`errSecItemNotFound` on
    /// update, `errSecDuplicateItem` on add) by retrying the other branch
    /// once.
    @discardableResult
    static func writeToken(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        let valueUpdate: [String: Any] = [kSecValueData as String: data]

        if exists() {
            let status = SecItemUpdate(baseQuery() as CFDictionary, valueUpdate as CFDictionary)
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else { return false }
            // Lost a race: the item disappeared between the existence check
            // and the update. Fall through to add.
        }

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        guard addStatus == errSecDuplicateItem else { return false }
        // Lost the opposite race: the item appeared between the existence
        // check and the add. Fall back to update.
        return SecItemUpdate(baseQuery() as CFDictionary, valueUpdate as CFDictionary) == errSecSuccess
    }

    /// Removes any stored token. Safe to call when none exists — that
    /// counts as success, since the postcondition (no token stored) holds.
    @discardableResult
    static func deleteToken() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
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
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: baseURLKey)
                return
            }
            // Normalize away a trailing slash so "https://day.example/" and
            // "https://day.example" are stored (and later joined by
            // DayClient) identically.
            var text = newValue.absoluteString
            if text.hasSuffix("/") {
                text.removeLast()
            }
            UserDefaults.standard.set(text, forKey: baseURLKey)
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

    /// Posted by a Day surface's status banner (I1) — the deck, the kanban
    /// window — when the user clicks the "Open Day Settings" action on an
    /// expired-token (401) notice. `AppDelegate` is the only thing that
    /// owns `DaySettingsWindowController`, so a plain SwiftUI view has no
    /// direct way to call `.show()`; posting this notification is the same
    /// indirection `dayCredentialsChanged` already uses in the other
    /// direction.
    static let openDaySettingsRequested = Notification.Name("openDaySettingsRequested")
}
