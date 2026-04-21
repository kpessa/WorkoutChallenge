//
//  MaxHRService.swift
//  WorkoutChallenge
//
//  Resolves the user's Max HR according to their preferences. This is the
//  central place for the "what number do we plug into the zone math?"
//  decision — the settings UI picks the *method*, this file turns the
//  method + inputs into a concrete BPM.
//
//  Inputs come from three sources:
//   1. The `UserPreferencesModel` row (method, age override, manual BPM,
//      cached observed max).
//   2. HealthKit characteristics (date of birth, biological sex) — used to
//      derive age when no manual override is set, and to suggest Gulati as
//      the default for biologically-female users on first run.
//   3. HealthKit HR samples — fed asynchronously into the cached
//      `observedMaxHRBPM` field so the observed method doesn't re-query on
//      every workout open.
//

import Foundation
import HealthKit

@MainActor
enum MaxHRService {

    /// Final resolved Max HR in BPM, given everything we know. Callers
    /// should pass their current `UserPreferencesModel` row. This always
    /// returns a number — if no inputs are available, we fall back to a
    /// conservative default of 190 BPM so zone math never divides by zero.
    static func resolve(
        preferences: UserPreferencesModel,
        birthdate: DateComponents? = nil
    ) -> Double {
        let method = preferences.maxHRMethod

        switch method {
        case .manual:
            if preferences.maxHRManualBPM > 0 {
                return Double(preferences.maxHRManualBPM)
            }
            // Fall through to Tanaka if manual is selected but unset.
            return tanakaFallback(preferences: preferences, birthdate: birthdate)

        case .observed:
            if preferences.observedMaxHRBPM > 0 {
                return Double(preferences.observedMaxHRBPM)
            }
            // No observation yet — fall back to Tanaka so we always return
            // something reasonable.
            return tanakaFallback(preferences: preferences, birthdate: birthdate)

        case .fox, .tanaka, .gulati, .nes:
            guard let age = age(from: birthdate, override: preferences.maxHRAgeOverride),
                  let estimate = method.estimate(age: age) else {
                // No age known → last-ditch fallback. 190 BPM is roughly the
                // Tanaka estimate for a 26-year-old and is the number the
                // MHR literature tends to cite when age is unknown.
                return 190
            }
            return estimate
        }
    }

    /// Compute the user's age in years. The override wins (0 = unset, so
    /// we read HealthKit in that case).
    static func age(from birthdate: DateComponents?, override: Int) -> Double? {
        if override > 0 { return Double(override) }
        guard let birthdate,
              let dob = Calendar.current.date(from: birthdate) else { return nil }
        let years = Calendar.current.dateComponents([.year], from: dob, to: Date()).year ?? 0
        return years > 0 ? Double(years) : nil
    }

    /// Suggest a reasonable default method for a new user. Gulati when the
    /// biological-sex characteristic says `.female`, otherwise Tanaka.
    /// Used by the Settings screen to seed first-run state when the user
    /// hasn't picked anything yet.
    static func suggestedDefault(sex: HKBiologicalSex?) -> MaxHRMethod {
        switch sex {
        case .some(.female): return .gulati
        default:             return .tanaka
        }
    }

    // MARK: - Private

    private static func tanakaFallback(
        preferences: UserPreferencesModel,
        birthdate: DateComponents?
    ) -> Double {
        if let age = age(from: birthdate, override: preferences.maxHRAgeOverride),
           let tanaka = MaxHRMethod.tanaka.estimate(age: age) {
            return tanaka
        }
        return 190
    }
}
