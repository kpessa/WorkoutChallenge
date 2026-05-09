//
//  ProgressCoachContext.swift
//  WorkoutChallenge
//
//  Input bundle for the Progress-tab coach card. Sibling of `CoachContext`
//  but with a different shape:
//
//    • No "in focus" workout — the Progress surface is about the arc, not
//      a single session. Instead carries `daysSinceLastWorkout` and a
//      compact summary of the most-recent workout for "you last trained
//      2 days ago, that was a 32-min cycle" framing.
//    • Includes VO₂Max + HRV trends (early-window vs. late-window deltas)
//      since those are the headline numbers on the FitnessTrendCard the
//      coach card sits next to. The teaching-voice narrator can explain
//      what they mean in plain language.
//    • Carries an Eisenhower-style "primary focus" slot so the
//      deterministic pass can tell the narrator which fact to lead with —
//      Progress is a survey-style surface and we want one clear thought,
//      not three weaved together.
//
//  Pure value type, Sendable. The fingerprint helper lets the loader
//  cache by "did the underlying picture change meaningfully?" rather than
//  by clock time.
//

import Foundation

/// Trend signal for VO₂Max or HRV over the challenge window. Both signals
/// are noisy enough that point-to-point deltas don't read; we want
/// early-window vs. late-window movement.
struct PhysiologyTrend: Sendable, Equatable {
    /// Most-recent value in the window. `value`'s units are signal-specific
    /// (mL/(kg·min) for VO₂Max, ms for HRV) — the narrator handles units.
    let latest: Double
    /// `latest − earliest` over the window. Positive = improving (VO₂Max
    /// up, HRV up = better recovery), negative = drifting down.
    let delta: Double
    /// Number of samples that contributed. Useful for the narrator to
    /// avoid over-interpreting a series with only 2 points.
    let sampleCount: Int
}

/// Compact projection of the most-recent workout, when one exists. The
/// Progress coach uses this to anchor "you last trained X days ago" copy
/// without retaining a SwiftData reference.
struct RecentWorkoutSummary: Sendable, Equatable {
    let date: Date
    let durationMinutes: Int
    let typeName: String?
    /// Days from `date.startOfDay` to today. 0 = today, 1 = yesterday.
    let daysAgo: Int
}

/// What the deterministic pass picked as the lead observation. The card
/// renders this fact prominently and the narrator is told to lead with it.
/// `.none` means nothing crossed the speak-up threshold — the card stays
/// silent in Release; DEBUG renders a placeholder.
enum ProgressCoachFocus: Sendable, Equatable {
    case onTrack            // ahead of or near the target curve, nothing to flag
    case behindPace         // missed days mounting / falling behind sigmoid target
    case fitnessRising      // CTL trending up — habit is paying off
    case fitnessFalling     // CTL drifting down — extended quiet patch
    case recoveryDeficit    // TSB very negative — accumulated fatigue
    case milestone          // arc checkpoint (day 30, 60, 90, etc.)
    case vo2MaxMoving       // Apple's VO₂Max shifted enough to comment on
    case hrvShift           // HRV trending up or down meaningfully
    case streakLockingIn    // early-phase streak forming
    case returnAfterBreak   // first workout after ≥2-day gap
    case none               // nothing notable; coach stays quiet
}

// MARK: - The bundle

struct ProgressCoachContext: Sendable {

    // MARK: - Where in the arc

    /// 1-indexed day in the 90-day challenge. Same semantics as
    /// `CoachContext.day`.
    let day: Int
    /// Always 90 today; explicit so a future variable-length challenge
    /// doesn't require touching every rule.
    let totalDays: Int
    /// Coarse arc bucket — derived from `day`.
    let phase: ChallengePhase
    /// Today's prescribed minutes from the sigmoid curve.
    let targetMinutesToday: Int
    /// Sum of all minutes logged on today's calendar day.
    let actualMinutesToday: Int

    // MARK: - Most recent activity

    /// Most-recent workout, when one exists. Nil before any workouts are
    /// logged in the active challenge.
    let mostRecentWorkout: RecentWorkoutSummary?

    /// Number of distinct calendar days in the last 7 with at least one
    /// workout. Same semantics as `CoachContext.workoutDaysLast7`.
    let workoutDaysLast7: Int

    // MARK: - Aggregates

    let load: TrainingLoadSnapshot
    let adherence: AdherenceSnapshot

    // MARK: - Physiology (HealthKit)

    /// Apple's auto-computed VO₂Max trend. Nil when there are 0 samples
    /// in the challenge window (happens for users without outdoor runs).
    let vo2Max: PhysiologyTrend?

    /// HRV (SDNN) trend. Nil when no samples exist in the window.
    let hrv: PhysiologyTrend?

    // MARK: - Lead observation

    /// What the deterministic pass picked as the dominant signal for
    /// today's render. Card and narrator both branch on this.
    let focus: ProgressCoachFocus

    // MARK: - User context

    let locale: Locale

    // MARK: - Cache fingerprint

    /// Compact, deterministic string that captures every number the
    /// narrator's output meaningfully depends on. Two contexts with the
    /// same fingerprint should produce the same insight; the loader uses
    /// this to short-circuit redundant API calls.
    ///
    /// CTL/ATL/TSB are bucketed (rounded to nearest unit) so a tiny
    /// rounding tick doesn't invalidate the cache. Day, phase, focus,
    /// streak, missed-this-week, and last-workout-days-ago are exact —
    /// those are the knobs the user actually feels.
    var fingerprint: String {
        let ctl = Int(load.ctlToday.rounded())
        let atl = Int(load.atlToday.rounded())
        let tsb = Int(load.tsbToday.rounded())
        let recent = mostRecentWorkout?.daysAgo.description ?? "-"
        let vo2 = vo2Max.map { "\(Int($0.latest.rounded()))/\(Int($0.delta.rounded()))" } ?? "-"
        let hrvFp = hrv.map { "\(Int($0.latest.rounded()))/\(Int($0.delta.rounded()))" } ?? "-"
        return [
            "d\(day)",
            "p\(phase.rawValue)",
            "f\(focus.rawString)",
            "ctl\(ctl)",
            "atl\(atl)",
            "tsb\(tsb)",
            "today\(actualMinutesToday)/\(targetMinutesToday)",
            "w7\(workoutDaysLast7)",
            "s\(adherence.currentStreakDays)",
            "m\(adherence.missedDaysThisWeek)",
            "r\(adherence.isReturnAfterBreak ? 1 : 0)",
            "last\(recent)",
            "v\(vo2)",
            "h\(hrvFp)"
        ].joined(separator: ".")
    }
}

// MARK: - Focus rawString

extension ProgressCoachFocus {
    /// Stable string for fingerprinting. Switch (not rawValue) so renaming
    /// a case doesn't silently invalidate everyone's cache.
    var rawString: String {
        switch self {
        case .onTrack:          return "on_track"
        case .behindPace:       return "behind_pace"
        case .fitnessRising:    return "fitness_rising"
        case .fitnessFalling:   return "fitness_falling"
        case .recoveryDeficit:  return "recovery_deficit"
        case .milestone:        return "milestone"
        case .vo2MaxMoving:     return "vo2_moving"
        case .hrvShift:         return "hrv_shift"
        case .streakLockingIn:  return "streak_locking"
        case .returnAfterBreak: return "return_after_break"
        case .none:             return "none"
        }
    }
}
