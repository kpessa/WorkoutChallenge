//
//  VaultPushCard.swift
//  WorkoutChallenge
//
//  Per-workout push to the LLM Vault, surfaced inside LogWorkoutSheet's
//  edit-mode details section. Mirrors the HeartRateCard / ExtraStatsCard
//  pattern visually and shows everything the user needs to debug a push:
//
//    • Configured server URL (or warning if unset)
//    • Last-sync timestamp from HealthKitSyncService
//    • Push button (PrimaryButton) + spinner during request
//    • Per-card last response (success body) or error (status + body)
//
//  Only rendered when the workout has a healthKitUUID — manual entries
//  have no HKWorkout sample to mirror, so the wire format's required
//  hk_uuid field can't be populated. Settings → Vault Sync still hosts
//  the bulk backfill + verify actions.
//

import SwiftUI

struct VaultPushCard: View {
    let healthKitUUID: UUID

    @EnvironmentObject private var sync: HealthKitSyncService

    @State private var lastResult: PushResult?
    @State private var isPushing: Bool = false

    private enum PushResult: Equatable {
        case success(body: String, at: Date)
        case failure(message: String, at: Date)
    }

    var body: some View {
        AppSection(title: "LLM Vault") {
            VStack(alignment: .leading, spacing: Space.x3) {
                serverRow
                actionRow
                if let result = lastResult {
                    resultBlock(result)
                }
                if let lastSync = sync.lastSyncAt {
                    Text("Last vault push: \(lastSync.formatted(date: .abbreviated, time: .standard))")
                        .font(AppFont.ui(11, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                }
            }
        }
    }

    // MARK: - Sub-rows

    private var serverRow: some View {
        HStack(alignment: .top, spacing: Space.x2) {
            Image(systemName: serverURL == nil ? "exclamationmark.triangle.fill" : "server.rack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(serverURL == nil ? Color.warn : Color.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Server")
                    .font(AppFont.mono(10, weight: .medium))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.textTertiary)
                Text(serverURL?.absoluteString ?? "Not configured — set in Settings → Vault Sync")
                    .font(AppFont.mono(12, weight: .medium))
                    .foregroundStyle(serverURL == nil ? Color.warn : Color.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private var actionRow: some View {
        HStack(spacing: Space.x2) {
            PrimaryButton(
                title: isPushing ? "Pushing…" : "Push to vault",
                icon: isPushing ? nil : "arrow.up.circle",
                size: .small
            ) {
                Task { await runPush() }
            }
            .disabled(!canPush)

            if isPushing {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.accentVolt)
            }
        }
    }

    @ViewBuilder
    private func resultBlock(_ result: PushResult) -> some View {
        switch result {
        case .success(let body, let at):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Pushed \(at.formatted(date: .omitted, time: .standard))")
                        .font(AppFont.ui(12, weight: .semibold))
                        .foregroundStyle(.green)
                }
                if !body.isEmpty {
                    Text(body)
                        .font(AppFont.mono(11, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                        .padding(Space.x2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.appSurface2, in: .rect(cornerRadius: 8))
                }
            }
        case .failure(let message, let at):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Color.danger)
                    Text("Failed \(at.formatted(date: .omitted, time: .standard))")
                        .font(AppFont.ui(12, weight: .semibold))
                        .foregroundStyle(Color.danger)
                }
                Text(message)
                    .font(AppFont.mono(11, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .padding(Space.x2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appSurface2, in: .rect(cornerRadius: 8))
                Text("Check that the server is running and reachable from this device. The Settings → Vault Sync screen has a verify action that hits /health without auth.")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    // MARK: - Helpers

    private var serverURL: URL? { VaultSyncConfig.serverURL }

    private var canPush: Bool {
        serverURL != nil
            && VaultSyncKeychain.getToken() != nil
            && !isPushing
            && !sync.isWorking
    }

    @MainActor
    private func runPush() async {
        isPushing = true
        defer { isPushing = false }
        do {
            let body = try await sync.pushWorkout(uuid: healthKitUUID)
            lastResult = .success(body: body, at: Date())
        } catch {
            lastResult = .failure(message: error.localizedDescription, at: Date())
        }
    }
}
