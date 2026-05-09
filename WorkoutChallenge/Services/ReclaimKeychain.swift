//
//  ReclaimKeychain.swift
//  WorkoutChallenge
//
//  Minimal wrapper around the iOS Keychain to store the user's Reclaim.ai
//  API token. Device-local by default — the token is NOT iCloud-synced, so
//  the user pastes it once per device. Keeping it device-local reduces
//  blast radius if a device is compromised and sidesteps the extra
//  entitlement Keychain Sharing would need.
//
//  The token is treated as a plain UTF-8 string. Access class is
//  `WhenUnlockedThisDeviceOnly` — readable while the device is unlocked,
//  not restored to a new device from an iCloud backup.
//

import Foundation
import Security

enum ReclaimKeychain {
    private static let service = "com.kurtpessa.WorkoutChallenge.reclaim"
    private static let account = "apiToken"

    enum Error: Swift.Error {
        case unexpectedStatus(OSStatus)
    }

    /// Stores (or replaces) the Reclaim API token. Pass an empty string to
    /// clear — the helper normalizes to a delete so we never store "".
    static func setToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteToken()
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw Error.unexpectedStatus(errSecParam)
        }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Try update first; if not found, fall through to add.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw Error.unexpectedStatus(updateStatus)
        }

        var addAttrs = base
        addAttrs[kSecValueData as String] = data
        addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw Error.unexpectedStatus(addStatus)
        }
    }

    /// Returns the stored token, or nil if none is set.
    static func token() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    static func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.unexpectedStatus(status)
        }
    }

    /// Convenience: true when a non-empty token is stored.
    static var hasToken: Bool { token()?.isEmpty == false }
}
