//
//  CoachSection.swift
//  WorkoutChallenge
//
//  Settings section for the calibrated-coach API keys + voice picker.
//
//    • Narrator (Anthropic) — claude-sonnet-4-6 for prose
//    • Voice (ElevenLabs) — TTS playback. The user's cloned voice is the
//      default; presets from the public ElevenLabs library let the user
//      try a different character ("calm", "deep", "warm", etc.) at the
//      tap of a chip. A per-voice "Preview" button synthesizes a short
//      sample so the user can hear the voice before committing.
//
//  Both keys live in `CoachKeychain` (device-local). The active voice id
//  lives on `UserPreferencesModel.coachVoiceID` so it syncs to other
//  devices via CloudKit.
//

import SwiftUI
import SwiftData

struct CoachSection: View {
    @Query private var preferencesList: [UserPreferencesModel]

    private var prefs: UserPreferencesModel? { preferencesList.first }

    // MARK: - Narrator state

    @State private var anthropicDraft: String = ""
    @State private var anthropicSavedMasked: String? = nil
    @State private var anthropicTesting = false
    @State private var anthropicTestResult: String? = nil

    // MARK: - Voice state

    @State private var elevenLabsDraft: String = ""
    @State private var elevenLabsSavedMasked: String? = nil
    @State private var elevenLabsTesting = false
    @State private var elevenLabsTestResult: String? = nil

    /// Voice id currently being previewed (so multiple concurrent taps
    /// don't double-fire). Nil when no preview is in flight.
    @State private var previewingVoiceID: String? = nil

    /// Shared audio player for in-Settings voice previews. Lives at the
    /// section level so previews share state and a second tap can stop
    /// the first.
    @State private var previewPlayer = CoachAudioPlayer()

    // MARK: - Body

    var body: some View {
        AppSection(title: "Coach") {
            VStack(alignment: .leading, spacing: Space.x4) {
                narratorBlock
                Divider()
                voiceBlock
                Divider()
                explainerCopy
            }
        }
        .onAppear(perform: loadKeyState)
        .onDisappear { previewPlayer.stop() }
    }

    // MARK: - Narrator block

    @ViewBuilder
    private var narratorBlock: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Narrator")
                .font(AppFont.ui(13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)

            anthropicKeyRow

            HStack(spacing: Space.x2) {
                Button("Save") { saveAnthropic() }
                    .disabled(anthropicDraft.isEmpty)
                Button("Test connection") { Task { await testAnthropic() } }
                    .disabled(anthropicTesting || !CoachKeychain.hasToken(for: .anthropic))
                if anthropicTesting { ProgressView().controlSize(.small) }
            }

            if let anthropicTestResult {
                Text(anthropicTestResult)
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var anthropicKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Anthropic API key")
                .font(AppFont.ui(13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            SecureField(
                anthropicSavedMasked ?? "Paste your Anthropic API key (sk-ant-…)",
                text: $anthropicDraft
            )
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .padding(10)
            .background(Color.appSurface2)
            .cornerRadius(8)

            if let masked = anthropicSavedMasked {
                Text("Saved in iOS Keychain on this device: \(masked)")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            } else if CoachKeychain.isUsingDeveloperDefault(for: .anthropic) {
                Text("Using developer key from Secrets.swift. Paste here to override.")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            } else {
                Text(CoachKeychain.Slot.anthropic.providerHint)
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    // MARK: - Voice block

    @ViewBuilder
    private var voiceBlock: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Voice")
                .font(AppFont.ui(13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)

            elevenLabsKeyRow

            HStack(spacing: Space.x2) {
                Button("Save") { saveElevenLabs() }
                    .disabled(elevenLabsDraft.isEmpty)
                Button("Test key") { Task { await testElevenLabs() } }
                    .disabled(elevenLabsTesting || !CoachKeychain.hasToken(for: .elevenLabs))
                if elevenLabsTesting { ProgressView().controlSize(.small) }
            }

            if let elevenLabsTestResult {
                Text(elevenLabsTestResult)
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if elevenLabsSavedMasked != nil || CoachKeychain.hasToken(for: .elevenLabs) {
                voicePicker
            }
        }
    }

    @ViewBuilder
    private var elevenLabsKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ElevenLabs API key")
                .font(AppFont.ui(13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            SecureField(
                elevenLabsSavedMasked ?? "Paste your ElevenLabs API key",
                text: $elevenLabsDraft
            )
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .padding(10)
            .background(Color.appSurface2)
            .cornerRadius(8)

            if let masked = elevenLabsSavedMasked {
                Text("Saved in iOS Keychain on this device: \(masked)")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            } else if CoachKeychain.isUsingDeveloperDefault(for: .elevenLabs) {
                Text("Using developer key from Secrets.swift. Paste here to override.")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            } else {
                Text(CoachKeychain.Slot.elevenLabs.providerHint)
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    // MARK: - Voice picker

    @ViewBuilder
    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Pick a voice")
                .font(AppFont.ui(13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)

            VStack(spacing: Space.x2) {
                ForEach(CoachVoiceProfile.catalog) { profile in
                    voiceRow(profile)
                }
            }

            Text("Your cloned voice is the default. The presets are public-library voices — try them out, no commitment. The active selection rides via iCloud to your other devices.")
                .font(AppFont.ui(11, weight: .medium))
                .foregroundStyle(Color.textTertiary)
        }
    }

    @ViewBuilder
    private func voiceRow(_ profile: CoachVoiceProfile) -> some View {
        let isSelected = (prefs?.coachVoiceID ?? "") == profile.id
        HStack(spacing: Space.x3) {
            Button(action: { selectVoice(profile) }) {
                HStack(spacing: Space.x3) {
                    ZStack {
                        Circle()
                            .stroke(Color.appBorder, lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                        if isSelected {
                            Circle()
                                .fill(Color.accentVolt)
                                .frame(width: 10, height: 10)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(profile.displayName)
                                .font(AppFont.ui(14, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                            if profile.kind == .clone {
                                Text("CLONE")
                                    .font(AppFont.mono(9, weight: .bold))
                                    .tracking(0.6)
                                    .foregroundStyle(Color.accentInk)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentVolt, in: Capsule())
                            }
                        }
                        Text(profile.descriptor)
                            .font(AppFont.ui(11, weight: .medium))
                            .foregroundStyle(Color.textTertiary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Button(action: { Task { await previewVoice(profile) } }) {
                Image(systemName: previewingVoiceID == profile.id ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Color.appSurface2, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!CoachKeychain.hasToken(for: .elevenLabs))
        }
    }

    // MARK: - Explainer

    @ViewBuilder
    private var explainerCopy: some View {
        Text("With both keys set, every workout you open generates 2-4 sentences of grounded feedback (Sonnet) and reads it aloud in the selected voice (ElevenLabs). Without keys, the card stays at the deterministic bullets layer. Audio is cached on-device and re-opening a workout doesn't re-spend tokens.")
            .font(AppFont.ui(12, weight: .medium))
            .foregroundStyle(Color.textTertiary)
    }

    // MARK: - Actions: narrator

    private func loadKeyState() {
        if let token = CoachKeychain.token(for: .anthropic), !token.isEmpty {
            anthropicSavedMasked = CoachKeychain.mask(token)
        } else {
            anthropicSavedMasked = nil
        }
        if let token = CoachKeychain.token(for: .elevenLabs), !token.isEmpty {
            elevenLabsSavedMasked = CoachKeychain.mask(token)
        } else {
            elevenLabsSavedMasked = nil
        }
    }

    private func saveAnthropic() {
        do {
            try CoachKeychain.setToken(anthropicDraft, for: .anthropic)
            anthropicDraft = ""
            loadKeyState()
            anthropicTestResult = "Saved. Test the connection below."
        } catch {
            anthropicTestResult = "Save failed: \(error.localizedDescription)"
        }
    }

    private func testAnthropic() async {
        anthropicTesting = true
        defer { anthropicTesting = false }

        let narrator = AnthropicNarrator()
        let sampleFacts = CoachFacts(all: [
            CoachFact(
                kind: .milestone,
                severity: .notable,
                templateKey: "fact.connection.test",
                values: [:]
            )
        ])
        let sampleContext = Self.sampleContext()

        do {
            let response = try await narrator.narrate(
                facts: sampleFacts,
                context: sampleContext
            )
            let preview = response.prefix(80)
            anthropicTestResult = "Connected. Sample: \"\(preview)\(response.count > 80 ? "…" : "")\""
        } catch {
            anthropicTestResult = "Failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Actions: voice

    private func saveElevenLabs() {
        do {
            try CoachKeychain.setToken(elevenLabsDraft, for: .elevenLabs)
            elevenLabsDraft = ""
            loadKeyState()
            elevenLabsTestResult = "Saved. Test the key, then preview a voice below."
        } catch {
            elevenLabsTestResult = "Save failed: \(error.localizedDescription)"
        }
    }

    private func testElevenLabs() async {
        elevenLabsTesting = true
        defer { elevenLabsTesting = false }

        let voice = ElevenLabsVoice()
        let voiceID = prefs?.coachVoiceID ?? CoachVoiceProfile.kurtClone.id

        do {
            _ = try await voice.synthesize(
                text: "Connection check.",
                voiceID: voiceID
            )
            elevenLabsTestResult = "Connected. Voice synthesis is hot."
        } catch {
            elevenLabsTestResult = "Failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func selectVoice(_ profile: CoachVoiceProfile) {
        guard let prefs else { return }
        prefs.coachVoiceID = profile.id
    }

    /// Synthesize a short sample with the tapped voice and play it back
    /// in-place. Tapping the same voice's preview again stops playback.
    /// Sample text is short (one sentence) to keep TTS spend negligible —
    /// previewing all 7 voices once is < a penny.
    private func previewVoice(_ profile: CoachVoiceProfile) async {
        if previewingVoiceID == profile.id {
            previewPlayer.stop()
            previewingVoiceID = nil
            return
        }

        previewingVoiceID = profile.id
        defer { previewingVoiceID = nil }

        let voice = ElevenLabsVoice()
        let sample: String
        switch profile.kind {
        case .clone:
            sample = "This is what you sound like. Day 9 of 90, on track."
        case .preset, .custom:
            sample = "Hi, this is \(profile.displayName). I can read your workout reflections aloud."
        }

        do {
            let data = try await voice.synthesize(text: sample, voiceID: profile.id)
            try await previewPlayer.play(data: data)
        } catch {
            elevenLabsTestResult = "Preview failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Sample context for narrator test

    private static func sampleContext() -> CoachContext {
        CoachContext(
            workout: CoachContext.WorkoutSummary(
                id: UUID(),
                date: Date(),
                durationMinutes: 30,
                typeName: "Test",
                isImported: false
            ),
            zones: nil,
            avgHR: nil,
            day: 14,
            totalDays: 90,
            phase: .early,
            targetMinutesToday: 25,
            actualMinutesToday: 30,
            recentWorkouts: [],
            workoutDaysLast7: 4,
            hrAtPaceTrend: nil,
            load: TrainingLoadSnapshot(ctlToday: 18, ctl7DaysAgo: 12, atlToday: 22),
            adherence: AdherenceSnapshot(
                currentStreakDays: 3,
                longestStreakDays: 5,
                missedDaysThisWeek: 0,
                isReturnAfterBreak: false
            ),
            maxHR: 188,
            locale: .current
        )
    }
}
