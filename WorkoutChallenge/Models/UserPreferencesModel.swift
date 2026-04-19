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

    init(
        startDate: Date = Date(),
        daysPerWeek: Int = 3,
        firstWeekday: Int = 1,
        sigmoid: SigmoidParams = .default,
        themeRaw: String = ThemePreference.system.rawValue
    ) {
        self.startDate = startDate
        self.daysPerWeek = daysPerWeek
        self.firstWeekday = firstWeekday
        self.sigmoid = sigmoid
        self.themeRaw = themeRaw
    }

    static func makeDefault() -> UserPreferencesModel {
        UserPreferencesModel()
    }
}
