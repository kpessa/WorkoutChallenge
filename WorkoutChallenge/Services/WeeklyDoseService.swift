//
//  WeeklyDoseService.swift
//  WorkoutChallenge
//
//  Scores a week of activity against the 150 / 300-minute physical-activity
//  guideline (US Physical Activity Guidelines 2018 2nd ed. + WHO 2020).
//
//  The guideline counts in "moderate-equivalent minutes": vigorous activity
//  counts double (its own 2:1 accounting), and the weekly target is
//  150 min (full benefit) → 300 min (extra benefit). See
//  `reference-activity-guidelines-research` for the cited numbers behind
//  the benefit copy.
//
//  Intensity per workout has two sources, in priority order:
//    1. HR-zone refinement (when a `ZoneBreakdown` is supplied for the
//       workout): time in Z4/Z5 is vigorous, Z2/Z3 moderate, Z1 light.
//       This is the accurate, HealthKit-aware path.
//    2. Type-based MET classification (always available): keyword-match
//       the workout type name to a MET estimate. Moderate (3–<6 METs)
//       counts ×1, vigorous (≥6 METs) ×2, light (<3 METs) ×0 — light
//       activity does not count toward the aerobic guideline.
//
//  Math is pure so the meter and any caption read off the same numbers.
//

import Foundation

enum WeeklyDoseService {

    // MARK: - Intensity model

    /// Guideline intensity bands, defined in METs (per US PAG / WHO):
    /// light 1.6–<3.0, moderate 3.0–<6.0, vigorous ≥6.0. Sedentary (≤1.5)
    /// never reaches here — a logged workout is at minimum light.
    enum Intensity {
        case light, moderate, vigorous

        /// Moderate-equivalent multiplier. Vigorous counts double; light
        /// activity doesn't count toward the 150/300 aerobic target.
        var moderateEquivalentFactor: Double {
            switch self {
            case .light:    return 0
            case .moderate: return 1
            case .vigorous: return 2
            }
        }
    }

    /// Which benefit band a weekly moderate-equivalent total lands in.
    enum Band {
        case building   // < 150 — below the guideline minimum
        case full       // 150–<300 — meets the guideline
        case extra      // ≥ 300 — upper guideline range
    }

    struct Result {
        /// Moderate-equivalent minutes for the week (the meter value).
        let moderateEquivalentMinutes: Int
        /// Raw logged minutes, unweighted (for context / debugging).
        let rawMinutes: Int
        /// How many of the moderate-equivalent minutes came from
        /// vigorous-intensity time (already doubled). Drives the
        /// "vigorous counts double" explanation.
        let vigorousEquivalentMinutes: Int

        var band: Band {
            if moderateEquivalentMinutes >= 300 { return .extra }
            if moderateEquivalentMinutes >= 150 { return .full }
            return .building
        }
    }

    // MARK: - Public API

    /// Compute the week's moderate-equivalent minutes.
    ///
    /// - Parameters:
    ///   - workouts: candidate workouts; filtered to `[weekStart, weekStart+7d)` internally.
    ///   - weekStart: start of the week (already aligned to the user's firstWeekday).
    ///   - zonesByWorkoutID: optional HR-zone breakdowns keyed by `WorkoutModel.id`.
    ///     When present for a workout, overrides the type-based estimate.
    static func compute(
        workouts: [WorkoutModel],
        weekStart: Date,
        zonesByWorkoutID: [UUID: ZoneBreakdown] = [:]
    ) -> Result {
        let start = weekStart.startOfDay
        let end = start.addingDays(7)

        var equivalent = 0.0
        var vigorousEquivalent = 0.0
        var raw = 0

        for w in workouts {
            let day = w.date.startOfDay
            guard day >= start, day < end, w.duration > 0 else { continue }
            raw += w.duration

            let minutes = Double(w.duration)
            if let zones = zonesByWorkoutID[w.id], zones.totalSeconds > 0 {
                // HR-refined path: split this workout's minutes by zone.
                let split = zoneSplit(zones)
                equivalent += minutes * split.equivalentFactor
                vigorousEquivalent += minutes * split.vigorousEquivalentFactor
            } else {
                // Type-based fallback.
                let intensity = classify(typeName: w.workoutType?.name)
                let factor = intensity.moderateEquivalentFactor
                equivalent += minutes * factor
                if intensity == .vigorous { vigorousEquivalent += minutes * factor }
            }
        }

        return Result(
            moderateEquivalentMinutes: Int(equivalent.rounded()),
            rawMinutes: raw,
            vigorousEquivalentMinutes: Int(vigorousEquivalent.rounded())
        )
    }

    // MARK: - HR-zone refinement

    /// Convert a zone breakdown into moderate-equivalent factors for the
    /// whole workout. Z4/Z5 → vigorous (×2), Z2/Z3 → moderate (×1), Z1 →
    /// light (×0). Scaled by the fraction of HR-covered time so partial
    /// coverage (HR gaps) degrades gracefully rather than under-counting.
    private static func zoneSplit(
        _ zones: ZoneBreakdown
    ) -> (equivalentFactor: Double, vigorousEquivalentFactor: Double) {
        let total = zones.totalSeconds
        guard total > 0 else { return (1, 0) }
        let vigorousSec = zones.seconds(in: .z4) + zones.seconds(in: .z5)
        let moderateSec = zones.seconds(in: .z2) + zones.seconds(in: .z3)
        // Z1 (recovery) is light → contributes 0.
        let vigorousFrac = vigorousSec / total
        let moderateFrac = moderateSec / total
        let equivalent = moderateFrac * 1 + vigorousFrac * 2
        let vigorousEquivalent = vigorousFrac * 2
        return (equivalent, vigorousEquivalent)
    }

    // MARK: - Type-based MET classification

    /// Classify a workout's intensity from its type name. MET estimates
    /// are population midpoints from the Compendium of Physical Activities;
    /// they're approximations, intentionally forgiving. Unknown names
    /// default to MODERATE — a logged workout is assumed to be at least
    /// brisk (the guideline's canonical moderate example is brisk walking).
    static func classify(typeName: String?) -> Intensity {
        guard let name = typeName?.lowercased(), !name.isEmpty else {
            // Untyped (often a raw HealthKit import) — assume moderate.
            return .moderate
        }
        if vigorousKeywords.contains(where: { name.contains($0) }) { return .vigorous }
        if lightKeywords.contains(where: { name.contains($0) }) { return .light }
        // Everything else (walk, hike, bike, elliptical, strength, …)
        // and unknown names → moderate.
        return .moderate
    }

    /// ≥6 MET activities — count double.
    private static let vigorousKeywords = [
        "run", "jog", "sprint", "skate", "skating", "blade", "rollerblad",
        "inline", "swim", "row", "spin", "spinning", "hiit", "interval",
        "climb", "stair", "boxing", "kickbox", "soccer", "basketball",
        "racquet", "squash", "mountain bike", "mtb", "trail run"
    ]

    /// <3 MET activities — don't count toward the aerobic target.
    private static let lightKeywords = [
        "yoga", "stretch", "flexibility", "mobility", "pilates",
        "meditat", "breath", "tai chi", "restorative", "cooldown",
        "cool down", "warmup", "warm up"
    ]
}
