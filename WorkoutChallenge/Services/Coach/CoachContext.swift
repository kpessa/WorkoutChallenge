//
//  CoachContext.swift
//  WorkoutChallenge
//
//  The input bundle for the calibrated coach pipeline. Composed once per
//  feedback request from the existing services (TrainingLoadService,
//  ChallengeService, AnalyticsService, WeeklyScheduleService, MaxHRService,
//  HealthKitService) — purely a value type, no logic.
//
//  The pipeline:
//
//      CoachContext  →  CoachFacts  →  CoachFeedback (text)  →  CoachAudio
//        (input)      (deterministic)     (LLM narrator)         (TTS)
//
//  Each stage is a swap point. Layer 1 (`DeterministicCoach`) reads only
//  this context — no async, no I/O, no SwiftData — so the rule pass is
//  trivial to unit-test and trivial to reason about.
//
//  Field policy: every field is either non-optional with a sensible zero
//  ("no recent workouts" → []) or optional when nil carries actual meaning
//  ("no comparable workouts of the same type yet" vs. "found nothing notable").
//  This keeps Layer 1 rules from defensively re-checking their substrate.
//

import Foundation

// MARK: - Phase

/// Coarse position in the 90-day arc. Drives tone calibration in the
/// narrator more than rule selection — early-arc feedback is about
/// consistency and habit formation; late-arc is about pushing intensity
/// and managing fatigue.
enum ChallengePhase: String, Codable, Sendable {
    case early   // days 1...30
    case mid     // days 31...60
    case late    // days 61...90

    static func from(day: Int) -> ChallengePhase {
        switch day {
        case ..<31: return .early
        case 31...60: return .mid
        default: return .late
        }
    }
}

// MARK: - HR drift

/// Heart-rate-at-comparable-effort trend across the trailing window.
/// Computed only when the most recent workout has at least one prior
/// same-type counterpart with HR data; nil otherwise.
struct HRAtPaceTrend: Sendable, Equatable {
    /// Average HR (bpm) on the just-completed workout.
    let recentAvgHR: Double
    /// Average HR (bpm) on prior same-type workouts in the trailing window.
    let baselineAvgHR: Double
    /// recent − baseline, in bpm. Negative = aerobic improvement (lower HR
    /// at same workout type), positive = under-recovered / sick / heat.
    var deltaBPM: Double { recentAvgHR - baselineAvgHR }
    /// How many prior workouts contributed to the baseline.
    let baselineSampleCount: Int
}

// MARK: - Adherence

/// Snapshot of how the user is showing up to the schedule. `current` and
/// `longest` come from `AnalyticsService.summary`; `missedDaysThisWeek`
/// is derived in the builder against the active week's target count.
struct AdherenceSnapshot: Sendable, Equatable {
    let currentStreakDays: Int
    let longestStreakDays: Int
    /// Days in the current calendar week (using prefs `firstWeekday`) that
    /// were scheduled-or-targeted but had no logged workout. 0 means
    /// on-pace; negative is impossible.
    let missedDaysThisWeek: Int
    /// True if the just-completed workout breaks a multi-day gap (≥2 days
    /// since the prior logged workout). The narrator should lead with the
    /// return rather than the gap when this is set.
    let isReturnAfterBreak: Bool
}

// MARK: - Training-load snapshot

/// CTL/ATL/TSB readout, all in the same arbitrary TRIMP-like units as
/// `TrainingLoadService.load(...)` produces. `tsb` is "form" — positive
/// means rested, negative means accumulated fatigue.
struct TrainingLoadSnapshot: Sendable, Equatable {
    let ctlToday: Double
    let ctl7DaysAgo: Double
    let atlToday: Double
    var tsbToday: Double { ctlToday - atlToday }
    var ctlDelta: Double { ctlToday - ctl7DaysAgo }
}

// MARK: - The bundle

/// Everything the coach needs to know about a single just-completed
/// workout, in one struct. Pure value type — pass freely across actors.
///
/// The struct is intentionally flat (no nested optional structs of
/// optionals) so Layer 1 rules read like English. Where a field can be
/// genuinely absent (no HR samples, no comparable prior workouts), it's
/// optional at the top level — never optional-of-optional.
struct CoachContext: Sendable {

    // MARK: - The workout in focus

    /// The just-completed workout the coach is about to comment on.
    /// Carries id/date/duration/type. Derived facts about it (zones, HR
    /// summary) live in their own fields below.
    let workout: WorkoutSummary

    /// Time-in-zone breakdown, when HR samples were available. Nil for
    /// manual workouts and any workout without an HKWorkout source.
    let zones: ZoneBreakdown?

    /// Average HR across this workout, when HR samples were available.
    let avgHR: Double?

    // MARK: - Challenge arc

    /// 1-indexed day in the 90-day challenge. From `ChallengeService.currentDay`.
    let day: Int
    /// Always 90, but kept explicit so a future variable-length challenge
    /// doesn't require touching every rule.
    let totalDays: Int
    /// Coarse arc bucket — derived from `day` for convenience.
    let phase: ChallengePhase
    /// Today's prescribed minutes from the sigmoid curve.
    let targetMinutesToday: Int
    /// Sum of all workouts logged on the same calendar day as `workout`.
    /// May exceed the just-saved workout's duration when the user logs
    /// twice in a day.
    let actualMinutesToday: Int

    // MARK: - Trailing context

    /// Last ~14 days of workouts (excluding the just-completed one).
    /// Ordered newest-first.
    let recentWorkouts: [WorkoutSummary]

    /// Distinct calendar days in the last 7 with at least one workout.
    /// Used by adherence rules without re-walking `recentWorkouts`.
    let workoutDaysLast7: Int

    /// HR-at-pace drift signal, when comparable history exists.
    let hrAtPaceTrend: HRAtPaceTrend?

    // MARK: - Aggregates

    let load: TrainingLoadSnapshot
    let adherence: AdherenceSnapshot

    // MARK: - User context

    /// Resolved max HR (bpm) used for zone math. Nil only on the very first
    /// launch before prefs exist.
    let maxHR: Double?
    /// User's locale for output language. The narrator and TTS read this.
    let locale: Locale

    // MARK: - Embedded value type

    /// Compact projection of `WorkoutModel` so `CoachContext` doesn't
    /// retain SwiftData references — keeps the struct `Sendable` and safe
    /// to hand to any narrator on any actor.
    struct WorkoutSummary: Sendable, Equatable {
        let id: UUID
        let date: Date
        let durationMinutes: Int
        let typeName: String?
        let isImported: Bool
    }
}
