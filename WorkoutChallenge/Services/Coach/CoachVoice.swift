//
//  CoachVoice.swift
//  WorkoutChallenge
//
//  Layer 3 of the calibrated-coach pipeline. Takes the prose produced by
//  a `CoachNarrator` and returns audio (mp3) of the same text, spoken in
//  the selected voice. The card plays it back via `CoachAudioPlayer`.
//
//  The protocol is provider-agnostic. Implementations:
//
//    • `ElevenLabsVoice` — primary; supports the user's cloned voice
//      AND the curated public-library presets in `CoachVoiceProfile`.
//    • `SystemVoice` (planned) — `AVSpeechSynthesizer` fallback for
//      offline / no-key / Simulator. Free, lower fidelity, no clone.
//
//  Output is mp3 bytes — caller is responsible for caching to disk
//  (see `CoachAudioStore`) and feeding to `AVAudioPlayer`.
//

import Foundation

protocol CoachVoice: Sendable {
    /// Synthesize `text` in the voice identified by `voiceID`.
    ///
    /// - Parameters:
    ///   - text: The narrator's prose. 2-4 sentences typically; longer
    ///     inputs cost more and may hit per-call limits.
    ///   - voiceID: Provider-specific voice identifier. For ElevenLabs
    ///     this is the `voice_id` from the Voices API; for System voice
    ///     it'd be an `AVSpeechSynthesisVoice.identifier`.
    /// - Returns: Audio data, mp3-encoded.
    /// - Throws: `VoiceError` for predictable failure modes; the loader
    ///   surfaces these in Settings → Test, never in the workout flow.
    func synthesize(text: String, voiceID: String) async throws -> Data
}

// MARK: - Errors

enum VoiceError: LocalizedError {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case unexpectedResponse
    case httpError(status: Int, body: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No ElevenLabs API key set. Add one in Settings → Coach."
        case .unauthorized:
            return "ElevenLabs API key was rejected. Check the key in Settings → Coach."
        case .rateLimited:
            return "Rate-limited by ElevenLabs. Try again in a moment."
        case .unexpectedResponse:
            return "Unexpected response from ElevenLabs."
        case .httpError(let status, let body):
            let preview = String(body.prefix(200))
            return "HTTP \(status) — \(preview)"
        case .emptyResponse:
            return "ElevenLabs returned an empty response."
        }
    }
}
