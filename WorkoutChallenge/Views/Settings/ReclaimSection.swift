//
//  ReclaimSection.swift
//  WorkoutChallenge
//
//  Settings section that wires the app to Reclaim.ai. Phase C.1 scope:
//    • Paste + store Reclaim API token (Keychain, device-local)
//    • Verify the token with a test call
//    • Manual "Sync current schedule" button — creates Reclaim tasks for
//      every future workout day of the active challenge.
//
//  Phase C.2 will add automatic hooks (workout completion → mark Reclaim
//  task complete; challenge pause/resume → sync).
//

import SwiftUI
import SwiftData

struct ReclaimSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var challenges: [ChallengeModel]

    // Token entry field. Not bound to Keychain directly — we only write on
    // Save so the user can back out of a paste without committing.
    @State private var tokenDraft: String = ""
    @State private var tokenSavedMasked: String? = nil

    @State private var testing = false
    @State private var syncing = false
    @State private var lastTestResult: String? = nil
    @State private var lastSyncResult: String? = nil

    private var activeChallenge: ChallengeModel? {
        ChallengeService.currentChallenge(in: challenges)
    }

    var body: some View {
        AppSection(title: "Reclaim.ai") {
            VStack(alignment: .leading, spacing: 12) {
                tokenRow
                HStack(spacing: 8) {
                    Button("Save") { saveToken() }
                        .disabled(tokenDraft.isEmpty)
                    Button("Test connection") { Task { await testConnection() } }
                        .disabled(testing || tokenSavedMasked == nil)
                    if testing { ProgressView().controlSize(.small) }
                }
                if let lastTestResult {
                    Text(lastTestResult)
                        .font(AppFont.ui(12, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                }

                Divider().padding(.vertical, 4)

                syncRow

                Text("Creates one Reclaim task per scheduled workout day (only future days). First run adopts any pre-existing Reclaim tasks. Re-running is a no-op for days already mapped.")
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textTertiary)

                Button("Reset mappings (re-adopt on next sync)") {
                    resetMappings()
                }
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(Color.textTertiary)
            }
        }
        .onAppear(perform: loadTokenState)
    }

    // MARK: - Token row

    @ViewBuilder
    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API token")
                .font(AppFont.ui(13, weight: .semibold))
            SecureField(tokenSavedMasked ?? "Paste your Reclaim API token", text: $tokenDraft)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .padding(10)
                .background(Color.appSurface2)
                .cornerRadius(8)
            if let tokenSavedMasked {
                Text("Saved in iOS Keychain on this device: \(tokenSavedMasked)")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            } else {
                Text("Generate at app.reclaim.ai → Settings → Developer. Device-local; paste on each device.")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    // MARK: - Sync row

    @ViewBuilder
    private var syncRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Sync current schedule to Reclaim") {
                    Task { await runSync() }
                }
                .disabled(syncing || activeChallenge == nil || tokenSavedMasked == nil)
                if syncing { ProgressView().controlSize(.small) }
            }
            if activeChallenge == nil {
                Text("No active challenge — start one on the main screen first.")
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
            if let lastSyncResult {
                Text(lastSyncResult)
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    // MARK: - Actions

    private func loadTokenState() {
        if let token = ReclaimKeychain.token(), !token.isEmpty {
            tokenSavedMasked = Self.mask(token)
        } else {
            tokenSavedMasked = nil
        }
    }

    private func saveToken() {
        do {
            try ReclaimKeychain.setToken(tokenDraft)
            tokenDraft = ""
            loadTokenState()
            lastTestResult = "Saved. Test the connection below."
        } catch {
            lastTestResult = "Save failed: \(error.localizedDescription)"
        }
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let user = try await ReclaimAPI.currentUser()
            let label = user.email ?? user.name ?? user.id ?? "unknown user"
            lastTestResult = "Connected as \(label)."
        } catch {
            lastTestResult = "Failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func runSync() async {
        guard let challenge = activeChallenge else { return }
        syncing = true
        defer { syncing = false }
        do {
            let outcome = try await ReclaimSyncService.syncSchedule(
                challenge: challenge,
                modelContext: modelContext
            )
            var parts: [String] = []
            if outcome.adopted > 0 { parts.append("adopted \(outcome.adopted)") }
            parts.append("created \(outcome.created)")
            if outcome.existing > 0 { parts.append("\(outcome.existing) already mapped") }
            if outcome.skippedPast > 0 { parts.append("\(outcome.skippedPast) past") }
            if outcome.failed > 0 { parts.append("\(outcome.failed) failed") }
            var msg = parts.joined(separator: ", ") + "."
            if let err = outcome.firstError { msg += " First error: \(err)" }
            lastSyncResult = msg
        } catch {
            lastSyncResult = "Sync failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func resetMappings() {
        guard let challenge = activeChallenge else { return }
        do {
            try ReclaimSyncService.clearMappings(
                challengeID: challenge.id,
                modelContext: modelContext
            )
            lastSyncResult = "Mappings cleared. Next sync will re-adopt from Reclaim."
        } catch {
            lastSyncResult = "Reset failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    /// Masks a token like "72bc71b2-a884-45ed-98e8-932231f2fb0d" → "72bc…fb0d".
    private static func mask(_ token: String) -> String {
        guard token.count > 8 else { return String(repeating: "•", count: token.count) }
        let prefix = token.prefix(4)
        let suffix = token.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}
