//
//  CoachNarrator.swift
//  WorkoutChallenge
//
//  Layer 2 of the calibrated-coach pipeline. Takes the structured facts
//  produced by `DeterministicCoach` plus the underlying `CoachContext`,
//  and returns 2-4 sentences of grounded prose. The `CoachVoice` layer
//  (Layer 3) then reads that prose aloud.
//
//  The protocol is provider-agnostic. Implementations:
//
//    • `AnthropicNarrator`     — Sonnet/Opus via /v1/messages
//    • `FoundationModelNarrator` (planned, iOS 26+) — Apple's on-device LLM
//    • `GeminiNarrator`        (planned) — Gemini 2.5 flash/pro
//
//  Picking a narrator at the call site is the loader's job; the protocol
//  just defines the contract. The same prose flows through to the card
//  via `CoachFeedbackLoader.State.ready(facts:body:context:)` regardless
//  of which narrator produced it.
//

import Foundation

protocol CoachNarrator: Sendable {
    /// Produce a short, grounded narrative paragraph from the structured
    /// facts and underlying context. Implementations should:
    ///
    ///   • Lead with the most notable observation (caller pre-orders facts).
    ///   • Refer to specific numbers from `facts.values` — not vague vibes.
    ///   • Stay 2-4 sentences. Audio is short by design.
    ///   • Match the future-self-as-coach persona (terse, evidence-based,
    ///     no generic encouragement).
    ///   • Honor `context.locale` for output language when known.
    ///
    /// Errors should be specific enough that the loader can surface a
    /// useful "Test connection" message in Settings (auth vs network vs
    /// rate-limit), but the loader will fall back to deterministic bullets
    /// silently in the workout flow either way.
    func narrate(facts: CoachFacts, context: CoachContext) async throws -> String
}
