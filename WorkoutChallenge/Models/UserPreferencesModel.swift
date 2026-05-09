//
//  UserPreferencesModel.swift
//  WorkoutChallenge
//
//  SwiftData model for user-level settings: start date of the challenge,
//  days per week, and the sigmoid curve parameters.
//
//  Note: SwiftData models used with CloudKit must have no required properties
//  without defaults and no unique constraints. All properties here have
//  sensible defaults so CloudKit sync works out of the box.
//

import Foundation
import SwiftData

@Model
final class UserPreferencesModel {
    /// Day the 90-day challenge begins (local-day precision).
    var startDate: Date = Date()

    /// How many days per week the user plans to work out (1...7).
    var daysPerWeek: Int = 3

    /// First day of the calendar week for display purposes. Matches Apple's
    /// `Calendar.firstWeekday`: 1 = Sunday, 2 = Monday.
    var firstWeekday: Int = 1

    // SwiftData supports Codable structs as properties. The sigmoid params
    // struct is stored as an encoded blob.
    var sigmoid: SigmoidParams = SigmoidParams.default

    /// Theme preference (system/light/dark). Stored as the `ThemePreference`
    /// raw string so the enum can evolve without requiring a migration.
    /// Kept here (rather than purely in UserDefaults) so it syncs via
    /// CloudKit alongside the rest of the user's preferences.
    var themeRaw: String = ThemePreference.system.rawValue

    // MARK: - Max heart rate

    /// Strategy used to resolve Max HR. Stored as the raw string of
    /// `MaxHRMethod` so new cases don't require a migration. Default is
    /// `.tanaka` — a reasonable middle-ground when we don't yet know the
    /// user's age or have observed HR data.
    var maxHRMethodRaw: String = MaxHRMethod.tanaka.rawValue

    /// User's age for MHR formulas. 0 means "unset — derive from HealthKit
    /// birthdate when possible". Storing the number (rather than a birthdate)
    /// avoids a sensitive-PII field syncing via CloudKit.
    var maxHRAgeOverride: Int = 0

    /// Manually-specified MHR in BPM. Only used when `maxHRMethodRaw ==
    /// MaxHRMethod.manual.rawValue`. 0 means "unset".
    var maxHRManualBPM: Int = 0

    /// Cached highest HR observed in Apple Health. Refreshed on demand by
    /// `MaxHRService` so we don't re-query HealthKit on every workout open.
    /// 0 means "not computed yet" — treat as unknown.
    var observedMaxHRBPM: Int = 0

    /// When `observedMaxHRBPM` was last refreshed. Nil = never.
    var observedMaxHRUpdatedAt: Date?

    /// Resting HR in BPM. Used by the HR-zone math (Karvonen / Heart-Rate
    /// Reserve formula) to match the Apple Watch's zone calculation:
    ///     target = rest + pct·(max − rest)
    /// 0 means "unset" — the math degenerates to the older %-of-max
    /// behavior (`pct·max`) so existing users see no change until they
    /// fill this in. Refreshable from Apple Health (resting HR is posted
    /// daily by the Watch); also editable manually.
    var restingHRBPM: Int = 0

    /// When `restingHRBPM` was last refreshed from Apple Health. Nil =
    /// manually entered or never.
    var restingHRUpdatedAt: Date?

    // MARK: - Calibrated coach (voice tier)

    /// ElevenLabs voice id for the calibrated-coach narration playback.
    /// Defaults to Kurt's cloned voice (mMw2ULSqWjVQbyAWWFRM, captured
    /// 2026-04-27). Empty string = "no audio, text-only coach card."
    /// CloudKit-safe: defaults so existing rows pick up the clone on
    /// first read after the schema migration.
    var coachVoiceID: String = "mMw2ULSqWjVQbyAWWFRM"

    /// When true, the workout-detail card auto-plays the narration on
    /// first appearance. Default off — auto-play feels great in the demo
    /// and overbearing by week three. The play button is always tappable
    /// regardless of this setting.
    var coachVoiceAutoplay: Bool = false

    init(
        startDate: Date = Date(),
        daysPerWeek: Int = 3,
        firstWeekday: Int = 1,
        sigmoid: SigmoidParams = .default,
        themeRaw: String = ThemePreference.system.rawValue,
        maxHRMethodRaw: String = MaxHRMethod.tanaka.rawValue,
        maxHRAgeOverride: Int = 0,
        maxHRManualBPM: Int = 0,
        observedMaxHRBPM: Int = 0,
        observedMaxHRUpdatedAt: Date? = nil,
        coachVoiceID: String = "mMw2ULSqWjVQbyAWWFRM",
        coachVoiceAutoplay: Bool = false
    ) {
        self.startDate = startDate
        self.daysPerWeek = daysPerWeek
        self.firstWeekday = firstWeekday
        self.sigmoid = sigmoid
        self.themeRaw = themeRaw
        self.maxHRMethodRaw = maxHRMethodRaw
        self.maxHRAgeOverride = maxHRAgeOverride
        self.maxHRManualBPM = maxHRManualBPM
        self.observedMaxHRBPM = observedMaxHRBPM
        self.observedMaxHRUpdatedAt = observedMaxHRUpdatedAt
        self.coachVoiceID = coachVoiceID
        self.coachVoiceAutoplay = coachVoiceAutoplay
    }

    static func makeDefault() -> UserPreferencesModel {
        UserPreferencesModel()
    }
}

extension UserPreferencesModel {
    /// Typed accessor for the persisted max-HR method. Falls back to
    /// `.tanaka` if the stored raw value doesn't decode (e.g. an older row
    /// from before this field existed).
    var maxHRMethod: MaxHRMethod {
        get { MaxHRMethod(rawValue: maxHRMethodRaw) ?? .tanaka }
        set { maxHRMethodRaw = newValue.rawValue }
    }
}
