//
//  ElevenLabsVoice.swift
//  WorkoutChallenge
//
//  ElevenLabs TTS implementation. Calls
//  `POST /v1/text-to-speech/{voice_id}` with the configured voice
//  settings and returns raw mp3 bytes.
//
//  Pricing (Creator tier as of 2026-04): ~$0.30 per 1k characters using
//  cloned voices. A 4-sentence narrator output is ~300 chars → ~$0.0009
//  per workout. 90-workout challenge → ~$0.08 in TTS spend. The
//  constraint is taste, not the bill.
//
//  Token plumbing: API key comes from `CoachKeychain` slot `.elevenLabs`.
//  No fallback — if the slot is empty, `synthesize(...)` throws
//  `.missingAPIKey` and the loader silently skips audio (text still works).
//

import Foundation

struct ElevenLabsVoice: CoachVoice {

    // MARK: - Config

    /// Model id. `eleven_multilingual_v2` is the right default — handles
    /// EN+ES (the app's two locales) without per-language voices, and
    /// pairs well with cloned voices. Older `eleven_monolingual_v1` is
    /// English-only.
    let modelID: String

    /// Stability: how consistent the voice sounds across re-generations.
    /// 0.0-1.0; higher = more uniform, lower = more expressive variance.
    /// 0.5 is the ElevenLabs default sweet spot for cloned voices.
    let stability: Double

    /// Similarity boost: how closely the output should match the cloned
    /// voice's training samples. 0.75 is the default; pushing higher can
    /// produce artifacts when the source had background noise.
    let similarityBoost: Double

    /// Style: how much the voice should exaggerate the speaker's
    /// stylistic flourishes. Off (0) for coach-style delivery — we want
    /// the message grounded, not theatrical.
    let style: Double

    /// Speaker boost: an ElevenLabs-internal post-processing pass that
    /// helps cloned-voice clarity. On by default.
    let useSpeakerBoost: Bool

    init(
        modelID: String = "eleven_multilingual_v2",
        stability: Double = 0.5,
        similarityBoost: Double = 0.75,
        style: Double = 0.0,
        useSpeakerBoost: Bool = true
    ) {
        self.modelID = modelID
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.style = style
        self.useSpeakerBoost = useSpeakerBoost
    }

    // MARK: - Synthesize

    func synthesize(text: String, voiceID: String) async throws -> Data {
        guard let apiKey = CoachKeychain.token(for: .elevenLabs), !apiKey.isEmpty else {
            throw VoiceError.missingAPIKey
        }

        guard !voiceID.isEmpty else {
            throw VoiceError.unexpectedResponse
        }

        let urlString = "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)"
        guard let url = URL(string: urlString) else {
            throw VoiceError.unexpectedResponse
        }

        let body = RequestBody(
            text: text,
            model_id: modelID,
            voice_settings: VoiceSettings(
                stability: stability,
                similarity_boost: similarityBoost,
                style: style,
                use_speaker_boost: useSpeakerBoost
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw VoiceError.unexpectedResponse
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw VoiceError.unauthorized
        case 429:
            throw VoiceError.rateLimited
        default:
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw VoiceError.httpError(status: http.statusCode, body: bodyText)
        }

        guard !data.isEmpty else {
            throw VoiceError.emptyResponse
        }

        return data
    }

    // MARK: - Codable wire types

    private struct RequestBody: Encodable {
        let text: String
        let model_id: String
        let voice_settings: VoiceSettings
    }

    private struct VoiceSettings: Encodable {
        let stability: Double
        let similarity_boost: Double
        let style: Double
        let use_speaker_boost: Bool
    }
}
