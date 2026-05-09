//
//  CoachKeychain.swift
//  WorkoutChallenge
//
//  Three-slot Keychain wrapper for the calibrated-coach API tokens:
//    • `.anthropic` — Sonnet/Opus narrator (primary at Layer 2)
//    • `.gemini`    — alternative narrator (parallel to Anthropic)
//    • `.elevenLabs` — TTS for the cloned-voice tier (Layer 3)
//
//  Same access policy as `ReclaimKeychain`: device-local, not iCloud-synced
//  (`WhenUnlockedThisDeviceOnly`). Tokens are pasted once per device. The
//  blast radius for a compromised device stays small, and we don't need
//  the Keychain Sharing entitlement.
//
//  Tokens are stored as plain UTF-8 under a per-slot account so a single
//  `service` namespace holds all three. Reading/writing one slot doesn't
//  touch the others.
//

import Foundation
import Security

enum CoachKeychain {

    // MARK: - Slots

    enum Slot: String, CaseIterable {
        case anthropic
        case gemini
        case elevenLabs

        /// Display label used in Settings rows.
        var displayName: String {
            switch self {
            case .anthropic:  return "Anthropic"
            case .gemini:     return "Gemini"
            case .elevenLabs: return "ElevenLabs"
            }
        }

        /// Where the user generates the key — surfaced as a hint under the
        /// secure-text field so the user knows where to go.
        var providerHint: String {
            switch self {
            case .anthropic:
                return "Generate at console.anthropic.com → API Keys. Device-local; paste on each device."
            case .gemini:
                return "Generate at aistudio.google.com → Get API key. Device-local."
            case .elevenLabs:
                return "Generate at elevenlabs.io → Profile → API Keys. Device-local."
            }
        }
    }

    private static let service = "com.kurtpessa.WorkoutChallenge.coach"

    enum Error: Swift.Error {
        case unexpectedStatus(OSStatus)
    }

    // MARK: - Get / set / clear

    /// Stores (or replaces) the token for `slot`. Empty/whitespace-only
    /// input deletes the slot — we never persist "" so the "is the slot
    /// configured?" check stays simple.
    static func setToken(_ token: String, for slot: Slot) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteToken(for: slot)
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw Error.unexpectedStatus(errSecParam)
        }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue
        ]

        // Try update first; if the slot isn't there yet, fall through to add.
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

    /// Returns the token to use for `slot`. Lookup precedence:
    ///   1. Keychain (set via Settings → Coach) — wins if present
    ///   2. `Secrets.swift` developer-baked default — fallback
    ///   3. Nil — caller throws `.missingAPIKey`
    ///
    /// This way the user (Kurt as developer) can bake keys into
    /// `Secrets.swift` and ship a working build; the Settings UI is an
    /// override path useful for testing against a different key.
    static func token(for slot: Slot) -> String? {
        if let userKey = userTokenFromKeychain(slot: slot), !userKey.isEmpty {
            return userKey
        }
        let devKey = Secrets.developerKey(for: slot)
        return devKey.isEmpty ? nil : devKey
    }

    /// Returns ONLY the user-set Keychain token (no developer-default
    /// fallback). Settings UI uses this to distinguish "user has saved
    /// an override" from "we're using the developer default."
    static func userToken(for slot: Slot) -> String? {
        userTokenFromKeychain(slot: slot)
    }

    private static func userTokenFromKeychain(slot: Slot) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
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

    static func deleteToken(for slot: Slot) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.unexpectedStatus(status)
        }
    }

    /// Convenience: true when *any* non-empty token exists for `slot` —
    /// either user-set in the Keychain or developer-baked in Secrets.
    /// Callers that just need "can I make API calls?" use this.
    static func hasToken(for slot: Slot) -> Bool {
        token(for: slot)?.isEmpty == false
    }

    /// True when the *user* has saved an override key in Settings,
    /// independent of any developer-baked default.
    static func hasUserToken(for slot: Slot) -> Bool {
        userToken(for: slot)?.isEmpty == false
    }

    /// True when only the developer-baked default exists for this slot
    /// (no user override). Settings UI uses this to label the "using
    /// built-in key" state.
    static func isUsingDeveloperDefault(for slot: Slot) -> Bool {
        !hasUserToken(for: slot) && !Secrets.developerKey(for: slot).isEmpty
    }

    // MARK: - Display helpers

    /// Masks a token for display (e.g. "sk-ant-…abcd"). Keeps a 4-char
    /// prefix and 4-char suffix joined by an ellipsis. Tokens shorter than
    /// 8 chars render as bullets.
    static func mask(_ token: String) -> String {
        guard token.count > 8 else {
            return String(repeating: "•", count: token.count)
        }
        let prefix = token.prefix(4)
        let suffix = token.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}
