//
//  VaultSyncKeychain.swift
//  WorkoutChallenge
//
//  Keychain-backed storage for the bearer token used to authenticate
//  outbound pushes to VaultBridge (the consolidated Hummingbird server
//  at ~/code/VaultBridge) — which mirrors received HealthKit data into
//  the LLM Vault at raw/healthkit/. The same token gates
//  /vault/healthkit/workout, /vault/healthkit/daily,
//  /vault/healthkit/backfill, and /apps/workoutchallenge/snapshot.
//
//  Mirrors ReclaimKeychain's pattern exactly:
//    • Device-local (kSecAttrAccessibleWhenUnlockedThisDeviceOnly).
//    • Single (service, account) tuple per stored secret.
//    • Empty string treated as "delete" — never stored as "".
//
//  The server URL itself isn't a secret and lives in UserDefaults; only
//  the token lives in Keychain.
//

import Foundation
import Security

enum VaultSyncKeychain {
    private static let service = "com.kurtpessa.WorkoutChallenge.vaultSync"
    private static let account = "bearerToken"

    enum Error: Swift.Error {
        case unexpectedStatus(OSStatus)
    }

    /// Stores (or replaces) the bearer token. Pass an empty string to clear —
    /// the helper normalizes whitespace-only input to a delete so we never
    /// store "".
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

    /// Returns the stored token, or nil if not set.
    static func getToken() -> String? {
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
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    /// Deletes the stored token. No-op if nothing was stored.
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

    /// Convenience: is a token currently configured?
    static var hasToken: Bool {
        getToken()?.isEmpty == false
    }
}

// MARK: - Server URL (UserDefaults — not secret)

enum VaultSyncConfig {
    private static let serverURLKey = "com.kurtpessa.WorkoutChallenge.vaultSync.serverURL"

    /// The base URL for the WorkoutChallenge server (the Vapor app).
    /// Examples: "http://mac-mini.local:8080" or "http://192.168.1.42:8080".
    /// Returns nil if not yet configured.
    static var serverURL: URL? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: serverURLKey),
                  !raw.isEmpty,
                  let url = URL(string: raw)
            else { return nil }
            return url
        }
        set {
            if let url = newValue {
                UserDefaults.standard.set(url.absoluteString, forKey: serverURLKey)
            } else {
                UserDefaults.standard.removeObject(forKey: serverURLKey)
            }
        }
    }

    /// Convenience setter that accepts a raw string. Trims whitespace and
    /// rejects malformed URLs by returning false.
    @discardableResult
    static func setServerURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            serverURL = nil
            return true
        }
        guard let url = URL(string: trimmed) else { return false }
        serverURL = url
        return true
    }
}
