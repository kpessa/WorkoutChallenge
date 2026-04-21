//
//  TrainingLoadService.swift
//  WorkoutChallenge
//
//  Pure-function computation of training load, CTL ("fitness"), and ATL
//  ("fatigue") from logged workouts.
//
//  The Progress-tab Fitness Trend card consumes `ctl(...)` to draw a
//  smooth long-term capacity line alongside the target sigmoid — the
//  independent signal that tells Kurt whether the prescribed progression
//  is actually producing fitness.
//
//  Model overview:
//    - Each workout contributes a per-day TRIMP-like **load** number.
//      With a zone breakdown available (preferred), the Edwards method
//      weights minutes by zone intensity (Z1=1 … Z5=5). Without zones,
//      we fall back to `duration_minutes × 2` — a Z2-equivalent
//      weighting so duration-only workouts still advance the curve.
//    - Loads are aggregated by calendar day across a contiguous date
//      range (empty days contribute zero — essential so the EWA walks
//      the full time axis rather than skipping rest days).
//    - CTL / ATL are exponentially-weighted averages of daily load
//      with time constants of 42 and 7 days respectively, matching
//      the TrainingPeaks / Banister convention used across the
//      endurance-training literature.
//
//  All functions are `static` and side-effect-free so they're trivial
//  to unit-test and safe to call from any actor context. The service
//  does **not** issue HealthKit queries itself — zone breakdowns, when
//  available, are injected via `zonesByWorkoutID`. This keeps the math
//  pure and the async HK loading a concern of the caller (typically a
//  view-model that batches queries and caches results).
//

import Foundation

enum TrainingLoadService {

    // MARK: - Value types

    /// One calendar day's aggregated training load. `load` is in
    /// arbitrary TRIMP-like units — callers should treat it as a
    /// unitless shape, not a "real" physiological quantity. Zero-load
    /// days are explicit so the EWA has a dense time axis.
    struct DailyLoad: Hashable, Identifiable {
        let date: Date       // always normalized to startOfDay
        let load: Double
        var id: Date { date }
    }

    /// One sample of the CTL or ATL series. Same `(date, value)` shape
    /// for both — callers pick which line to render based on what
    /// they asked for.
    struct LoadPoint: Hashable, Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    // MARK: - Constants

    /// Standard TrainingPeaks time constants. Expressed in days — the
    /// EWA smoothing factor is derived from `1 - exp(-1/tau)`.
    static let ctlTau: Double = 42
    static let atlTau: Double = 7

    /// Edwards TRIMP zone coefficients. Each minute spent in zone N
    /// contributes N load units. The scale choice is conventional, not
    /// physiological — absolute values don't matter as long as they're
    /// applied consistently across all workouts.
    static let edwardsZoneCoefficient: [Int: Double] = [
        1: 1.0,
        2: 2.0,
        3: 3.0,
        4: 4.0,
        5: 5.0
    ]

    /// Fallback intensity multiplier applied to duration when no zone
    /// breakdown is available. 2.0 ≈ treat as all-Z2, which maps cleanly
    /// to the Edwards scale and matches typical "aerobic base" workouts
    /// (most manually-logged or HR-less sessions sit there).
    static let durationFallbackIntensity: Double = 2.0

    // MARK: - Per-workout load

    /// Compute a TRIMP-like load value for a single workout.
    ///
    /// **Primary path — zone-weighted.** When `zones` has any recorded
    /// time, we convert seconds-per-zone into minutes and multiply by
    /// the Edwards coefficient. This is the accurate, HR-aware path and
    /// is the default when HealthKit has supplied zone data.
    ///
    /// **Fallback — duration × default intensity.** When no zones are
    /// supplied (or zones are empty because the workout had no HR
    /// samples), we use `duration_minutes × durationFallbackIntensity`.
    /// This keeps the CTL curve continuous rather than gapping on
    /// every manual/indoor/HR-less workout.
    ///
    /// - Parameters:
    ///   - durationMinutes: The workout's effective duration in minutes.
    ///   - zones: Optional zone breakdown (from `HeartRateAnalysis`).
    ///     Pass `nil` or an `.empty` breakdown to trigger the fallback.
    /// - Returns: Non-negative TRIMP-like load in arbitrary units.
    static func load(
        durationMinutes: Int,
        zones: ZoneBreakdown? = nil
    ) -> Double {
        guard durationMinutes > 0 else { return 0 }

        // Zone-weighted when we have any recorded zone time.
        if let zones, zones.totalSeconds > 0 {
            var sum: Double = 0
            for (zoneIndex, seconds) in zones.secondsByZone {
                let minutes = seconds / 60.0
                let coef = edwardsZoneCoefficient[zoneIndex] ?? 1.0
                sum += minutes * coef
            }
            return sum
        }

        // Duration-only fallback.
        return Double(durationMinutes) * durationFallbackIntensity
    }

    // MARK: - Aggregation

    /// Aggregate a collection of workouts into per-day `DailyLoad`
    /// entries across a contiguous date range.
    ///
    /// The returned array has one entry for every day in
    /// `[startDate, endDate]` inclusive (at `startOfDay` precision),
    /// ordered ascending. Days with no workouts get a zero load so
    /// the downstream EWA can walk the whole time axis uninterrupted.
    /// Multiple workouts on the same day are summed.
    ///
    /// - Parameters:
    ///   - workouts: All candidate workouts — filtering to the date
    ///     range is done internally.
    ///   - startDate: First day to include (normalized to startOfDay).
    ///   - endDate: Last day to include (normalized to startOfDay).
    ///   - zonesByWorkoutID: Optional zone breakdowns keyed by
    ///     `WorkoutModel.id`. Missing entries trigger the duration
    ///     fallback for that workout. Supply an empty dict for a
    ///     strictly duration-based curve.
    static func dailyLoads(
        workouts: [WorkoutModel],
        startDate: Date,
        endDate: Date,
        zonesByWorkoutID: [UUID: ZoneBreakdown] = [:]
    ) -> [DailyLoad] {
        let start = startDate.startOfDay
        let end = endDate.startOfDay
        guard start <= end else { return [] }

        // Bucket workout loads by calendar day.
        var loadByDay: [Date: Double] = [:]
        for w in workouts {
            let day = w.date.startOfDay
            guard day >= start, day <= end else { continue }
            let zones = zonesByWorkoutID[w.id]
            let l = load(durationMinutes: w.duration, zones: zones)
            loadByDay[day, default: 0] += l
        }

        // Emit one entry per day across the full range, filling zeroes
        // so the EWA sees a dense series.
        var result: [DailyLoad] = []
        var cursor = start
        while cursor <= end {
            result.append(DailyLoad(date: cursor, load: loadByDay[cursor] ?? 0))
            cursor = cursor.addingDays(1)
        }
        return result
    }

    // MARK: - Rolling averages (CTL / ATL)

    /// Exponentially-weighted average of a `DailyLoad` series.
    ///
    /// Formula (TrainingPeaks / Banister convention):
    ///   `y_t = y_{t-1} + (load_t − y_{t-1}) · α`, with `α = 1 − exp(−1/tau)`.
    ///
    /// This is equivalent to the canonical continuous-time expression
    /// `y_t = y_{t-1} · exp(−1/tau) + load_t · (1 − exp(−1/tau))`, just
    /// rearranged to be numerically cleaner for the "today's sample is
    /// pulling the running value toward itself" intuition.
    ///
    /// - Parameters:
    ///   - loads: Must be ordered ascending by date and contiguous
    ///     (one entry per day; use `dailyLoads(...)` to produce one).
    ///   - tau: Time constant in days (42 for CTL, 7 for ATL).
    ///   - seed: Initial running value at `loads[0]` (before today's
    ///     sample is applied). Defaults to 0 — meaning a cold start —
    ///     which visually ramps up over the first ~tau days. Callers
    ///     that know a prior CTL (e.g. resumed from persistence) can
    ///     pass it here to skip the ramp.
    /// - Returns: One `LoadPoint` per input day.
    static func rollingAverage(
        loads: [DailyLoad],
        tau: Double,
        seed: Double = 0
    ) -> [LoadPoint] {
        guard !loads.isEmpty, tau > 0 else { return [] }
        let alpha = 1 - exp(-1.0 / tau)
        var running = seed
        var result: [LoadPoint] = []
        result.reserveCapacity(loads.count)
        for entry in loads {
            running = running + (entry.load - running) * alpha
            result.append(LoadPoint(date: entry.date, value: running))
        }
        return result
    }

    /// Convenience: CTL ("fitness") — 42-day EWA of daily load.
    static func ctl(
        loads: [DailyLoad],
        seed: Double = 0
    ) -> [LoadPoint] {
        rollingAverage(loads: loads, tau: ctlTau, seed: seed)
    }

    /// Convenience: ATL ("fatigue") — 7-day EWA of daily load. Pair
    /// with CTL to derive "Form" (CTL − ATL) if/when we add a
    /// Readiness-style view later.
    static func atl(
        loads: [DailyLoad],
        seed: Double = 0
    ) -> [LoadPoint] {
        rollingAverage(loads: loads, tau: atlTau, seed: seed)
    }
}
