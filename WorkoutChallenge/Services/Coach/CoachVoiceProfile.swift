//
//  CoachVoiceProfile.swift
//  WorkoutChallenge
//
//  A picker-friendly representation of a TTS voice. Identifies the voice
//  by its provider id, carries display copy for the picker UI, and tags
//  the source so the picker can group / style entries.
//
//  Curated catalog kept here rather than fetched live from the ElevenLabs
//  Voices API — the user mostly wants their own clone, with the public-
//  library options as occasional novelty. The fun voices are baked in
//  with stable IDs from the public ElevenLabs library; the user can also
//  paste a custom id (Kind: `.custom`).
//
//  Updating this catalog is a code edit, not a Settings task — that's
//  intentional. We don't want this to grow into a voice-management UI.
//

import Foundation

struct CoachVoiceProfile: Hashable, Sendable, Identifiable, Codable {

    enum Kind: String, Hashable, Sendable, Codable {
        /// User's own cloned voice. Exactly one in the catalog.
        case clone
        /// Curated public-library voices. Stable, well-known IDs from
        /// ElevenLabs's free catalog — picked for variety of character.
        case preset
        /// User-pasted voice ID. Stored in UserPreferencesModel as the
        /// active voice when the user enters one in Settings.
        case custom
    }

    let id: String           // ElevenLabs voice_id
    let displayName: String
    let descriptor: String   // short character note ("calm", "deep", etc.)
    let kind: Kind

    // MARK: - The catalog

    /// Kurt's cloned voice — captured 2026-04-27. The default when the
    /// app first launches with TTS enabled. Stored here as the canonical
    /// record so it survives even if `UserPreferencesModel.coachVoiceID`
    /// gets corrupted.
    static let kurtClone = CoachVoiceProfile(
        id: "mMw2ULSqWjVQbyAWWFRM",
        displayName: "You",
        descriptor: "your cloned voice",
        kind: .clone
    )

    /// Curated public-library voices. IDs are from the standard ElevenLabs
    /// public voices library — these have been stable for years. If any
    /// drift, the picker will surface a 404-ish error on Test and we
    /// update the catalog.
    static let presets: [CoachVoiceProfile] = [
        CoachVoiceProfile(
            id: "21m00Tcm4TlvDq8ikWAM",
            displayName: "Rachel",
            descriptor: "calm, professional",
            kind: .preset
        ),
        CoachVoiceProfile(
            id: "pNInz6obpgDQGcFmaJgB",
            displayName: "Adam",
            descriptor: "deep, narrator",
            kind: .preset
        ),
        CoachVoiceProfile(
            id: "VR6AewLTigWG4xSOukaG",
            displayName: "Arnold",
            descriptor: "crisp, authoritative",
            kind: .preset
        ),
        CoachVoiceProfile(
            id: "ErXwobaYiN019PkySvjV",
            displayName: "Antoni",
            descriptor: "warm, encouraging",
            kind: .preset
        ),
        CoachVoiceProfile(
            id: "AZnzlk1XvdvUeBnXmlld",
            displayName: "Domi",
            descriptor: "strong, energetic",
            kind: .preset
        ),
        CoachVoiceProfile(
            id: "TxGEqnHWrfWFTfGW9XjX",
            displayName: "Josh",
            descriptor: "young, casual",
            kind: .preset
        )
    ]

    /// All catalog entries the picker should show. Clone first (default),
    /// then presets in their declared order.
    static let catalog: [CoachVoiceProfile] = [kurtClone] + presets

    // MARK: - Lookup

    /// Find a profile by id. Returns the catalog entry if known, or a
    /// `.custom` profile constructed from the bare id when the user has
    /// pasted one Settings doesn't know about.
    static func profile(for id: String) -> CoachVoiceProfile {
        if let match = catalog.first(where: { $0.id == id }) {
            return match
        }
        return CoachVoiceProfile(
            id: id,
            displayName: "Custom voice",
            descriptor: id.isEmpty ? "—" : "\(id.prefix(8))…",
            kind: .custom
        )
    }
}
