//
//  MaxHRMethod.swift
//  WorkoutChallenge
//
//  Strategy for estimating the user's maximum heart rate (MHR). Heart-rate
//  zones are all expressed as percentages of MHR, so the choice of method
//  has a real downstream effect on the "Zone 3 vs Zone 4" split in the
//  workout details view.
//
//  The enum is stored as its raw string value on `UserPreferencesModel` so
//  adding new cases later doesn't require a SwiftData migration.
//
//  Evidence notes:
//   • Fox/Haskell (220 − age) is the classic rule of thumb. Widely taught,
//     but overestimates MHR for young adults and underestimates for older
//     adults; standard deviation ±12 bpm.
//   • Tanaka (2001, "Age-predicted maximal heart rate revisited") proposed
//     208 − 0.7·age based on a meta-analysis; better group-level accuracy,
//     SD ±7 bpm, but still ±10–15 bpm per individual.
//   • Gulati et al. (2010) — derived from a large all-women cohort treadmill
//     study. Useful when the Tanaka/Fox formulas visibly misestimate.
//   • Nes et al. (2013, HUNT Fitness Study) — 211 − 0.64·age, validated on
//     a large Norwegian cohort including older adults; currently considered
//     one of the more accurate age-based estimates.
//   • Observed — the highest HR recorded by Apple Health over the lookback
//     window. Usually the best single estimate IF the user regularly
//     exercises near max; can under-report for low-intensity athletes.
//

import Foundation

/// Method used to resolve the user's maximum heart rate. See file header for
/// evidence / tradeoff notes on each.
enum MaxHRMethod: String, CaseIterable, Identifiable, Codable {
    /// Highest HR observed in Apple Health over the lookback window. Best
    /// when the user trains near max regularly; falls back to `.tanaka` when
    /// there are no HR samples.
    case observed
    /// 220 − age. Classic rule of thumb; widely taught.
    case fox
    /// 208 − 0.7·age (Tanaka 2001). More accurate at the group level than Fox.
    case tanaka
    /// 206 − 0.88·age (Gulati 2010). Derived from an all-women cohort.
    case gulati
    /// 211 − 0.64·age (Nes 2013 / HUNT). Validated on a large mixed cohort,
    /// good accuracy across older ages.
    case nes
    /// User-entered BPM.
    case manual

    var id: String { rawValue }

    /// Short label for pickers.
    var label: String {
        switch self {
        case .observed: return String(localized: "Observed", comment: "MaxHRMethod label")
        case .fox:      return String(localized: "220 − age", comment: "MaxHRMethod label")
        case .tanaka:   return String(localized: "Tanaka", comment: "MaxHRMethod label")
        case .gulati:   return String(localized: "Gulati", comment: "MaxHRMethod label")
        case .nes:      return String(localized: "HUNT", comment: "MaxHRMethod label")
        case .manual:   return String(localized: "Manual", comment: "MaxHRMethod label")
        }
    }

    /// One-line description for the settings detail row.
    var detail: String {
        switch self {
        case .observed: return String(localized: "Highest HR recorded in Apple Health.", comment: "MaxHRMethod detail")
        case .fox:      return String(localized: "220 − age. Classic rule of thumb.", comment: "MaxHRMethod detail")
        case .tanaka:   return String(localized: "208 − 0.7 × age. Better group accuracy than 220 − age.", comment: "MaxHRMethod detail")
        case .gulati:   return String(localized: "206 − 0.88 × age. Derived from an all-women cohort.", comment: "MaxHRMethod detail")
        case .nes:      return String(localized: "211 − 0.64 × age. HUNT Fitness Study (large cohort).", comment: "MaxHRMethod detail")
        case .manual:   return String(localized: "Set your own max heart rate in BPM.", comment: "MaxHRMethod detail")
        }
    }

    /// Estimate MHR from age for this method. Returns nil for `.observed`
    /// and `.manual` — those draw from different inputs.
    func estimate(age: Double) -> Double? {
        switch self {
        case .fox:    return 220.0 - age
        case .tanaka: return 208.0 - 0.7 * age
        case .gulati: return 206.0 - 0.88 * age
        case .nes:    return 211.0 - 0.64 * age
        case .observed, .manual: return nil
        }
    }
}
