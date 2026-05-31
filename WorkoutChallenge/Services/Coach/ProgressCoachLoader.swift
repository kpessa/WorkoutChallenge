//
//  ProgressCoachLoader.swift
//  WorkoutChallenge
//
//  View-scoped async loader for the Progress-tab coach card. Sibling of
//  `CoachFeedbackLoader` but with different caching semantics:
//
//    Post-workout loader: keyed by `workoutID`. One row per workout, lives
//    forever — the user may revisit a 60-day-old workout and want the same
//    coach copy.
//
//    Progress loader: keyed by `(dateKey, fingerprint)`. One row per
//    calendar day, regenerates only when the underlying picture changes
//    meaningfully (a new workout shifts CTL into a new bucket, a streak
//    ticks over). Re-opening the Progress tab three times in an afternoon
//    re-uses the same row; logging a workout invalidates it.
//
//  Pipeline:
//
//    1. Build `ProgressCoachContext` (async — HK fetches for VO2/HRV).
//    2. Run `ProgressDeterministicCoach.observe(...)` to produce facts.
//    3. Surface state `.ready(facts, body: nil, context, audioURL: nil)`
//       so the card can render bullets + skeleton immediately.
//    4. Cache lookup: fetch the most-recent `ProgressCoachInsightModel`
//       for today's `dateKey`. If the row's fingerprint matches the
//       just-built context, surface its body (and audio if on disk).
//    5. Cache miss: if a narrator is configured AND the focus isn't
//       `.none`, fan out to the narrator. On success persist a row; on
//       failure leave the bullets in place.
//    6. After narration, if the user has an ElevenLabs voice + key,
//       synthesize and cache the mp3 (same path as post-workout loader).
//

import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class ProgressCoachLoader {

    enum State: Equatable {
        case idle
        case loading
        /// Ready to render. `body` is nil when only the deterministic
        /// pass has run. `audioURL` is non-nil when an mp3 file is on disk.
        case ready(
            facts: CoachFacts,
            body: String?,
            context: ProgressCoachContext?,
            audioURL: URL?
        )
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading): return true
            case (.ready, .ready): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: State = .idle

    /// Same nonisolated-unsafe pattern as `CoachFeedbackLoader.task`.
    @ObservationIgnored
    nonisolated(unsafe) private var task: Task<Void, Never>?

    @ObservationIgnored
    private let narrator: any ProgressCoachNarrator

    @ObservationIgnored
    private let voice: any CoachVoice

    init(
        narrator: any ProgressCoachNarrator = AnthropicNarrator(),
        voice: any CoachVoice = ElevenLabsVoice()
    ) {
        self.narrator = narrator
        self.voice = voice
    }

    // MARK: - Load

    /// Kick off a load. Safe to call repeatedly — supersedes any in-flight
    /// task. Idempotent against the cache: if today's row matches the
    /// fingerprint, no narrator/network call happens.
    func load(
        allWorkouts: [WorkoutModel],
        challenge: ChallengeModel?,
        config: ChallengeService.ActiveConfig,
        healthKit: HealthKitService,
        modelContext: ModelContext,
        voiceID: String = "",
        locale: Locale = .current,
        now: Date = Date()
    ) {
        task?.cancel()
        state = .loading

        task = Task { [weak self] in
            guard let self else { return }

            // Step 1: build context.
            let context = await ProgressCoachContextBuilder.build(
                allWorkouts: allWorkouts,
                challenge: challenge,
                config: config,
                healthKit: healthKit,
                locale: locale,
                now: now
            )

            if Task.isCancelled { return }

            // Step 2: deterministic rule pass.
            let facts = ProgressDeterministicCoach.observe(context)

            if Task.isCancelled { return }

            // Step 3: surface bullets immediately.
            self.state = .ready(facts: facts, body: nil, context: context, audioURL: nil)

            // Step 4: cache lookup. Find a row keyed on today's dateKey;
            // if its fingerprint matches the live context, use its body.
            let dateKey = now.startOfDay
            if let cachedRow = Self.cachedRow(
                dateKey: dateKey,
                modelContext: modelContext
            ), cachedRow.fingerprint == context.fingerprint, !cachedRow.body.isEmpty {
                if Task.isCancelled { return }
                let url = CoachAudioStore.audioExists(for: cachedRow.id)
                    ? CoachAudioStore.audioURL(for: cachedRow.id)
                    : nil
                self.state = .ready(
                    facts: facts,
                    body: cachedRow.body,
                    context: context,
                    audioURL: url
                )
                if url == nil,
                   !voiceID.isEmpty,
                   CoachKeychain.hasToken(for: .elevenLabs) {
                    let regeneratedURL = await self.synthesizeAndCache(
                        text: cachedRow.body,
                        voiceID: voiceID,
                        row: cachedRow,
                        modelContext: modelContext
                    )
                    if Task.isCancelled { return }
                    if let regeneratedURL {
                        self.state = .ready(
                            facts: facts,
                            body: cachedRow.body,
                            context: context,
                            audioURL: regeneratedURL
                        )
                    }
                }
                return
            }

            // Step 5: fan out only when the focus is real. `.none` → silence.
            guard context.focus != .none else { return }

            do {
                let body = try await self.narrator.narrate(facts: facts, context: context)
                if Task.isCancelled { return }

                // Replace any stale row for this dateKey with the fresh one.
                // Keeping one-row-per-day prevents unbounded growth and
                // makes "today's insight" trivially queryable.
                let row = Self.replaceRow(
                    dateKey: dateKey,
                    fingerprint: context.fingerprint,
                    body: body,
                    facts: facts,
                    provider: .anthropic,
                    modelContext: modelContext
                )

                self.state = .ready(facts: facts, body: body, context: context, audioURL: nil)

                // Step 6: TTS fan-out. Same gating as post-workout loader.
                if !voiceID.isEmpty,
                   CoachKeychain.hasToken(for: .elevenLabs),
                   let row {
                    let audioURL = await self.synthesizeAndCache(
                        text: body,
                        voiceID: voiceID,
                        row: row,
                        modelContext: modelContext
                    )
                    if Task.isCancelled { return }
                    if let audioURL {
                        self.state = .ready(
                            facts: facts,
                            body: body,
                            context: context,
                            audioURL: audioURL
                        )
                    }
                }
            } catch {
                #if DEBUG
                print("[ProgressCoachLoader] narrator failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Synthesize audio + persist + update the row's voice metadata.
    /// Same shape as `CoachFeedbackLoader.synthesizeAndCache`.
    private func synthesizeAndCache(
        text: String,
        voiceID: String,
        row: ProgressCoachInsightModel,
        modelContext: ModelContext
    ) async -> URL? {
        do {
            let audioData = try await self.voice.synthesize(
                text: text,
                voiceID: voiceID
            )
            let url = try CoachAudioStore.writeAudio(audioData, for: row.id)
            row.voiceProvider = .elevenLabs
            row.voiceID = voiceID
            row.audioGeneratedAt = Date()
            try? modelContext.save()
            return url
        } catch {
            #if DEBUG
            print("[ProgressCoachLoader] voice synth failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }

    // MARK: - Cache helpers

    /// Most-recent row for a given dateKey. We expect one or zero per day
    /// in steady state (see `replaceRow` below), but tolerate >1 — return
    /// the most recent.
    static func cachedRow(
        dateKey: Date,
        modelContext: ModelContext
    ) -> ProgressCoachInsightModel? {
        var descriptor = FetchDescriptor<ProgressCoachInsightModel>(
            predicate: #Predicate { $0.dateKey == dateKey },
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Insert a fresh row for `dateKey` and remove any stale rows for the
    /// same day. We delete rather than mutate to ensure each row's `id`
    /// (and thus its on-disk audio file) is fresh — otherwise an old mp3
    /// keyed on a previous fingerprint could leak through.
    @discardableResult
    private static func replaceRow(
        dateKey: Date,
        fingerprint: String,
        body: String,
        facts: CoachFacts,
        provider: NarratorProvider,
        modelContext: ModelContext
    ) -> ProgressCoachInsightModel? {
        // Delete previous rows for this day and clean their audio.
        let stale = (try? modelContext.fetch(
            FetchDescriptor<ProgressCoachInsightModel>(
                predicate: #Predicate { $0.dateKey == dateKey }
            )
        )) ?? []
        for old in stale {
            CoachAudioStore.deleteAudio(for: old.id)
            modelContext.delete(old)
        }

        let factsJSON = (try? JSONEncoder().encode(facts.all)) ?? Data()
        let row = ProgressCoachInsightModel(
            dateKey: dateKey,
            fingerprint: fingerprint,
            generatedAt: Date(),
            narratorProvider: provider,
            body: body,
            factsJSON: factsJSON
        )
        modelContext.insert(row)
        do {
            try modelContext.save()
            return row
        } catch {
            #if DEBUG
            print("[ProgressCoachLoader] persist failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }
}
