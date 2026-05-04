//
//  VaultSyncSection.swift
//  WorkoutChallenge
//
//  Settings UI for the WorkoutChallenge → LLM Vault sync. Three controls:
//
//    • Server URL  — UserDefaults-backed, no secret. e.g. http://mac-mini.local:8080
//    • Bearer token — Keychain-backed, paste once per device.
//    • Verify / Test push / Backfill — manual triggers for v1.
//
//  Mirrors ReclaimSection's shape — secure-text field for the token, plain
//  text field for the URL, action buttons with status sub-labels.
//

import SwiftUI
import Combine

struct VaultSyncSection: View {
    @EnvironmentObject var sync: HealthKitSyncService

    @State private var serverURLText: String = VaultSyncConfig.serverURL?.absoluteString ?? ""
    @State private var tokenText: String = VaultSyncKeychain.getToken() ?? ""
    @State private var statusLine: String = ""
    @State private var verifyResult: String = ""

    var body: some View {
        Section {
            // Server URL
            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("http://mac-mini.local:8080", text: $serverURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { saveServerURL() }
                Button("Save URL") { saveServerURL() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(serverURLText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Bearer token
            VStack(alignment: .leading, spacing: 6) {
                Text("Bearer token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("WORKOUT_CHALLENGE_TOKEN", text: $tokenText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save token") { saveToken() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(tokenText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Action buttons
            VStack(alignment: .leading, spacing: 8) {
                Button("Verify server (GET /health)") {
                    Task { await runVerify() }
                }
                .disabled(sync.isWorking)

                Button("Test push (latest workout → /vault/healthkit/workout)") {
                    Task { await runTestPush() }
                }
                .disabled(sync.isWorking)

                Button("Backfill all workouts (/vault/healthkit/backfill)") {
                    Task { await runBackfill() }
                }
                .disabled(sync.isWorking)
            }

            if sync.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            if !verifyResult.isEmpty {
                Text(verifyResult)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if let progress = sync.backfillProgress {
                Text("Backfill: \(progress.processed)/\(progress.total) — added \(progress.added), skipped \(progress.skipped), failed \(progress.failed)")
                    .font(.caption.monospaced())
                    .foregroundStyle(progress.failed > 0 ? .orange : .secondary)
            }

            if !statusLine.isEmpty {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(statusLine.hasPrefix("✓") ? .green : .red)
            }

            if let error = sync.lastError {
                Text("Last error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if let last = sync.lastSyncAt {
                Text("Last sync: \(last.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Vault Sync (HealthKit → LLM Vault)")
        } footer: {
            Text("Pushes HealthKit workouts to the WorkoutChallenge server, which mirrors them into the vault at raw/healthkit/. The token must match WORKOUT_CHALLENGE_TOKEN on the server.")
        }
    }

    // MARK: - Actions

    private func saveServerURL() {
        if VaultSyncConfig.setServerURL(serverURLText) {
            statusLine = "✓ Server URL saved"
        } else {
            statusLine = "✗ Invalid URL"
        }
    }

    private func saveToken() {
        do {
            try VaultSyncKeychain.setToken(tokenText)
            statusLine = "✓ Token saved to Keychain"
        } catch {
            statusLine = "✗ Token save failed: \(error)"
        }
    }

    private func runVerify() async {
        statusLine = ""
        verifyResult = ""
        do {
            let result = try await sync.verifyServer()
            verifyResult = "✓ \(result)"
        } catch {
            verifyResult = "✗ \(error.localizedDescription)"
        }
    }

    private func runTestPush() async {
        statusLine = ""
        verifyResult = ""
        do {
            let response = try await sync.pushLatestWorkout()
            verifyResult = "✓ Pushed: \(response)"
        } catch {
            verifyResult = "✗ \(error.localizedDescription)"
        }
    }

    private func runBackfill() async {
        statusLine = ""
        verifyResult = ""
        do {
            let progress = try await sync.backfillAllWorkouts()
            verifyResult = "✓ Backfill done: \(progress.processed) processed, \(progress.added) added, \(progress.skipped) skipped, \(progress.failed) failed"
        } catch {
            verifyResult = "✗ Backfill failed: \(error.localizedDescription)"
        }
    }
}
