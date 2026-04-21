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
        observedMaxHRUpdatedAt: Date? = nil
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
