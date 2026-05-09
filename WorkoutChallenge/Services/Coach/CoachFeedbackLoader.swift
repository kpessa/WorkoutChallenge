//
//  CoachFeedbackLoader.swift
//  WorkoutChallenge
//
//  View-scoped async loader for the calibrated-coach card. Owns the
//  in-flight task so it cancels cleanly on view-disappear, and exposes a
//  single `state` for SwiftUI to observe — same pattern as
//  `WorkoutDetailsLoader` for consistency.
//
//  Pipeline:
//
//    1. Build `CoachContext` via `CoachContextBuilder.build(...)` —
//       async because HR enrichment fans out to HealthKit.
//    2. Run `DeterministicCoach.observe(...)` to produce `CoachFacts`.
//    3. Surface state `.ready(facts, body: nil, context)` so the card
//       renders bullets immediately — the user doesn't wait for the
//       network round-trip just to see something.
//    4. Cache lookup: fetch the most recent `CoachFeedbackModel` for
//       this `workoutID`. If a body is cached, transition state to
//       `.ready(facts, body: cached, context)`.
//    5. If no cache AND a narrator is configured AND the deterministic
//       pass produced at least one notable fact, fan out to the narrator.
//       On success, persist a new `CoachFeedbackModel` row and transition
//       state. On failure, leave the bullets in place — silent fallback.
//
//  "Notable facts" gate the narrator call deliberately: spending API
//  tokens to narrate "you did a workout, nothing remarkable" is wasteful,
//  and the deterministic-empty path stays silent in Release builds anyway.
//

import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class CoachFeedbackLoader {

    enum State: Equatable {
        case idle
        case loading
        /// Ready to render. `body` is nil when only the deterministic
        /// pass has run; the card renders bullets from `facts.notable`.
        /// When a narrator has produced prose (live or cached), `body`
        /// is non-nil and the card renders prose instead. `context` is
        /// carried through so DEBUG builds can show the raw numbers
        /// behind the rule pass. `audioURL` is non-nil when an mp3 file
        /// exists on disk for this workout — the card surfaces a play
        /// button when so.
        case ready(facts: CoachFacts, body: String?, context: CoachContext?, audioURL: URL?)
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

    /// `Task.cancel()` is documented thread-safe, and `deinit` on a
    /// `@MainActor` class is nonisolated — touching `task` from deinit
    /// trips Swift 6's isolation checker without `nonisolated(unsafe)`.
    /// `@ObservationIgnored` opts this out of the macro's tracked storage.
    @ObservationIgnored
    nonisolated(unsafe) private var task: Task<Void, Never>?

    /// Narrator instance. Default is `AnthropicNarrator()` — the loader
    /// will skip the narrator step entirely when no Anthropic key is set
    /// in the Keychain, so this default is safe.
    @ObservationIgnored
    private let narrator: any CoachNarrator

    /// Voice instance. Default is `ElevenLabsVoice()` — the loader skips
    /// audio synthesis when no ElevenLabs key is set, OR when the active
    /// voice id is empty in user preferences.
    @ObservationIgnored
    private let voice: any CoachVoice

    init(
        narrator: any CoachNarrator = AnthropicNarrator(),
        voice: any CoachVoice = ElevenLabsVoice()
    ) {
        self.narrator = narrator
        self.voice = voice
    }

    // MARK: - Load

    /// Kick off a load. Safe to call multiple times — a new call cancels
    /// any in-flight work and supersedes it.
    ///
    /// The `modelContext` parameter is required for narrator caching —
    /// the loader reads + writes `CoachFeedbackModel` rows so prose isn't
    /// regenerated on every workout-detail re-open.
    func load(
        workout: WorkoutModel,
        allWorkouts: [WorkoutModel],
        challenge: ChallengeModel?,
        config: ChallengeService.ActiveConfig,
        maxHR: Double?,
        restingHR: Double = 0,
        healthKit: HealthKitService,
        modelContext: ModelContext,
        voiceID: String = "",
        locale: Locale = .current,
        now: Date = Date()
    ) {
        task?.cancel()
        state = .loading

        let workoutID = workout.id

        task = Task { [weak self] in
            guard let self else { return }

            // Step 1: build the context.
            let context = await CoachContextBuilder.build(
                workout: workout,
                allWorkouts: allWorkouts,
                challenge: challenge,
                config: config,
                restingHR: restingHR,
                maxHR: maxHR,
                healthKit: healthKit,
                locale: locale,
                now: now
            )

            if Task.isCancelled { return }

            // Step 2: deterministic rule pass.
            let facts = DeterministicCoach.observe(context)

            if Task.isCancelled { return }

            // Step 3: surface bullets immediately so the card has
            // something to render while the narrator (if any) thinks.
            self.state = .ready(facts: facts, body: nil, context: context, audioURL: nil)

            // Step 4: cache lookup — if a previously-generated row exists
            // for this workoutID, prefer it. Resolve the audio URL only
            // when the file is actually on disk (Caches eviction handled).
            if let cachedRow = Self.cachedFeedbackRow(
                workoutID: workoutID,
                modelContext: modelContext
            ), !cachedRow.body.isEmpty {
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
                return
            }

            // Step 5: fan out to the narrator only when there's something
            // worth narrating. No notable facts → don't spend tokens.
            guard facts.hasNotable else { return }

            do {
                let body = try await self.narrator.narrate(facts: facts, context: context)
                if Task.isCancelled { return }

                // Persist text + facts first so the row exists for the
                // audio file to be keyed against. The row's id becomes
                // the filename for the cached mp3.
                let feedbackRow = Self.persistFeedback(
                    workoutID: workoutID,
                    body: body,
                    facts: facts,
                    provider: .anthropic,
                    modelContext: modelContext
                )

                self.state = .ready(facts: facts, body: body, context: context, audioURL: nil)

                // Fan out TTS — only when the user has selected a voice
                // AND has an ElevenLabs key. Failures are silent (the
                // text is already showing); the player will retry on
                // tap if no audio file is found.
                if !voiceID.isEmpty,
                   CoachKeychain.hasToken(for: .elevenLabs),
                   let row = feedbackRow {
                    let audioURL = await self.synthesizeAndCache(
                        text: body,
                        voiceID: voiceID,
                        feedbackRow: row,
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
                // Silent fallback — bullets are still showing. Surface
                // narrator failures only via Settings "Test connection".
                #if DEBUG
                print("[CoachFeedbackLoader] narrator failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Synthesize audio for the just-generated narration and cache the
    /// mp3 to disk. Updates `CoachFeedbackModel` with voice provenance.
    /// Returns the on-disk URL on success, nil on failure (caller leaves
    /// the bullets/prose visible and the player will retry on tap).
    private func synthesizeAndCache(
        text: String,
        voiceID: String,
        feedbackRow: CoachFeedbackModel,
        modelContext: ModelContext
    ) async -> URL? {
        do {
            let audioData = try await self.voice.synthesize(
                text: text,
                voiceID: voiceID
            )
            let url = try CoachAudioStore.writeAudio(audioData, for: feedbackRow.id)
            feedbackRow.voiceProvider = .elevenLabs
            feedbackRow.voiceID = voiceID
            feedbackRow.audioGeneratedAt = Date()
            try? modelContext.save()
            return url
        } catch {
            #if DEBUG
            print("[CoachFeedbackLoader] voice synth failed: \(error.localizedDescription)")
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

    /// Persist a fresh narrator output. Returns the inserted row so the
    /// caller can attach voice metadata once TTS completes. Swallows
    /// persistence errors — caching is best-effort; the user has already
    /// seen the prose.
    @discardableResult
    private static func persistFeedback(
        workoutID: UUID,
        body: String,
        facts: CoachFacts,
        provider: NarratorProvider,
        modelContext: ModelContext
    ) -> CoachFeedbackModel? {
        let factsJSON = (try? JSONEncoder().encode(facts.all)) ?? Data()
        let row = CoachFeedbackModel(
            workoutID: workoutID,
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
            print("[CoachFeedbackLoader] persist failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // MARK: - Cached audio lookup

    /// Find the most recent feedback row for `workoutID` so the play
    /// button can resolve audio on tap. Returns the row regardless of
    /// whether the audio file is on disk — the caller should test that
    /// separately via `CoachAudioStore.audioExists(for:)`.
    static func cachedFeedbackRow(
        workoutID: UUID,
        modelContext: ModelContext
    ) -> CoachFeedbackModel? {
        var descriptor = FetchDescriptor<CoachFeedbackModel>(
            predicate: #Predicate { $0.workoutID == workoutID },
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
