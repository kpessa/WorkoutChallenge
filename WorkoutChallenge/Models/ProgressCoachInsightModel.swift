//
//  ProgressCoachInsightModel.swift
//  WorkoutChallenge
//
//  SwiftData persistence for the Progress-tab coach card. Sibling of
//  `CoachFeedbackModel` but keyed differently — Progress insights aren't
//  tied to a specific workout. They're tied to a calendar day plus a
//  fingerprint of the underlying numbers ("day 42, CTL 47, streak 5,
//  missed 1"), so we regenerate when the picture meaningfully changes
//  (a new workout shifts CTL into a new bucket, a streak ticks over)
//  and re-use the same row when the user just re-opens the Progress tab.
//
//  Same audio policy as `CoachFeedbackModel`: text fields ride CloudKit;
//  mp3 audio lives in `Caches/CoachAudio/{id}.mp3` and is regenerated
//  on demand if iOS evicts it.
//
//  The teaching-voice system prompt for this surface is longer than the
//  post-workout one (3-5 sentences vs. 2-4) because the Progress card is
//  tap-to-listen — it has space for a teach-then-comment beat that the
//  workout-flow card doesn't. The body cap reflects that.
//

import Foundation
import SwiftData

@Model
final class ProgressCoachInsightModel {

    // MARK: - Identity

    var id: UUID = UUID()

    /// Calendar day this insight is *about* (start-of-day in user's TZ).
    /// One row per day per user is the steady state. When the user
    /// triggers a regenerate (e.g. logging a workout invalidates the
    /// fingerprint), the old row is replaced rather than another one
    /// added — see `ProgressCoachLoader.swift`.
    var dateKey: Date = Date()

    /// Compact fingerprint of the underlying numbers — see
    /// `ProgressCoachContext.fingerprint`. When the fingerprint changes
    /// vs. the cached row, the loader treats the cache as stale and
    /// regenerates. Stable across runs of the same context, deterministic.
    var fingerprint: String = ""

    /// When the text portion was produced. `audioGeneratedAt` tracks the
    /// audio separately because text and audio are produced by different
    /// services and may diverge.
    var generatedAt: Date = Date()

    // MARK: - Provenance

    /// Which narrator produced `body`. String-stored so adding providers
    /// doesn't require schema migration.
    /// Values: "deterministic" | "foundationModel" | "anthropic" | "gemini"
    var narratorProviderRaw: String = NarratorProvider.deterministic.rawValue

    /// Which voice tier produced the audio file (if any). Nil when no
    /// audio — the card just renders text.
    /// Values: "elevenLabs" | "system" | nil
    var voiceProviderRaw: String?

    /// Voice ID used (ElevenLabs voice_id, or system voice identifier).
    /// Nil when no audio.
    var voiceID: String?

    /// When the audio file was produced. Used by the player to detect
    /// "audio was meant to exist but the file is gone (Caches eviction)
    /// — regenerate on next play." Nil when no audio.
    var audioGeneratedAt: Date?

    // MARK: - Content

    /// The narrative text. Empty for `.deterministic` rows. For LLM-
    /// narrated rows this is the 3-5 sentence teach-then-observe response.
    var body: String = ""

    /// The facts the narrator was given (JSON-encoded `[CoachFact]`).
    /// Persisted so the card can re-render bullets even when LLM output
    /// is unavailable, AND so future debugging can answer "what did the
    /// model see when it said that?"
    var factsJSON: Data = Data()

    // MARK: - Init

    init(
        id: UUID = UUID(),
        dateKey: Date,
        fingerprint: String,
        generatedAt: Date = Date(),
        narratorProvider: NarratorProvider = .deterministic,
        voiceProvider: VoiceProvider? = nil,
        voiceID: String? = nil,
        audioGeneratedAt: Date? = nil,
        body: String = "",
        factsJSON: Data = Data()
    ) {
        self.id = id
        self.dateKey = dateKey
        self.fingerprint = fingerprint
        self.generatedAt = generatedAt
        self.narratorProviderRaw = narratorProvider.rawValue
        self.voiceProviderRaw = voiceProvider?.rawValue
        self.voiceID = voiceID
        self.audioGeneratedAt = audioGeneratedAt
        self.body = body
        self.factsJSON = factsJSON
    }

    // MARK: - Typed accessors

    var narratorProvider: NarratorProvider {
        get { NarratorProvider(rawValue: narratorProviderRaw) ?? .deterministic }
        set { narratorProviderRaw = newValue.rawValue }
    }

    var voiceProvider: VoiceProvider? {
        get { voiceProviderRaw.flatMap(VoiceProvider.init(rawValue:)) }
        set { voiceProviderRaw = newValue?.rawValue }
    }

    /// Decoded facts. Returns `.empty` if JSON is missing or malformed.
    var facts: CoachFacts {
        guard !factsJSON.isEmpty,
              let decoded = try? JSONDecoder().decode([CoachFact].self, from: factsJSON)
        else { return .empty }
        return CoachFacts(all: decoded)
    }
}
