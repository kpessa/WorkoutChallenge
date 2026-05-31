//
//  DeterministicCoach.swift
//  WorkoutChallenge
//
//  Layer 1 of the calibrated-coach pipeline: pure-function rule pass that
//  reads `CoachContext` and emits `CoachFacts`. No I/O, no async, no
//  randomness — same input, same output, every time.
//
//  The rules here are intentionally simple and conservative. They prefer
//  silence over noise: if a number is in the boring middle of a range, no
//  fact is emitted. The "coach earns the right to speak" UX rule lives
//  inside these thresholds — change them carefully.
//
//  Each rule's threshold has a comment explaining *why* — these are the
//  knobs Kurt will tune as he lives with the output. The reasoning matters
//  for future-Kurt who will want to know whether a rule was carefully
//  picked or guessed at.
//
//  When you add a rule:
//    1. Pick a `templateKey` of form `fact.<kind>.<rule>`.
//    2. Add EN + ES copy to `Localizable.xcstrings`.
//    3. Decide severity carefully — `.notable` should be reserved for
//       observations that genuinely change behavior. Most rules are `.normal`.
//

import Foundation

enum DeterministicCoach {

    /// Run the rule pass over a context. Order of facts in the output is
    /// stable: rules are evaluated top-down and emitted in that order. The
    /// narrator + card both rely on this ordering for prompt construction
    /// and primary-fact selection.
    static func observe(_ ctx: CoachContext) -> CoachFacts {
        var facts: [CoachFact] = []

        // ------------------------------------------------------------------
        // Milestones — anchored to specific day numbers; severity always
        // notable when fired because these are once-per-challenge moments.
        // ------------------------------------------------------------------

        if ctx.day == 1 {
            facts.append(.init(
                kind: .milestone,
                severity: .notable,
                templateKey: "fact.milestone.day_one",
                values: [:]
            ))
        }

        if [30, 60].contains(ctx.day) {
            facts.append(.init(
                kind: .milestone,
                severity: .notable,
                templateKey: "fact.milestone.checkpoint",
                values: ["day": "\(ctx.day)", "total": "\(ctx.totalDays)"]
            ))
        }

        if ctx.day == ctx.totalDays {
            facts.append(.init(
                kind: .milestone,
                severity: .notable,
                templateKey: "fact.milestone.final_day",
                values: [:]
            ))
        }

        // ------------------------------------------------------------------
        // Adherence — return after break is treated as a milestone-class
        // observation because tone calibration matters: lead with the
        // return, not the gap.
        // ------------------------------------------------------------------

        if ctx.adherence.isReturnAfterBreak {
            facts.append(.init(
                kind: .milestone,
                severity: .notable,
                templateKey: "fact.adherence.return_after_break",
                values: [:]
            ))
        }

        // 5+ day streak in the early phase = the habit is locking in.
        // Severity notable because most challenge failures happen here, so
        // recognizing successful early consistency is high-leverage.
        if ctx.phase == .early, ctx.adherence.currentStreakDays >= 5 {
            facts.append(.init(
                kind: .adherence,
                severity: .notable,
                templateKey: "fact.early.consistency_locking_in",
                values: ["streak": "\(ctx.adherence.currentStreakDays)"]
            ))
        }

        // 2+ missed days this week = behind pace. Notable so the coach
        // doesn't gloss over it, but worded as observation not scolding.
        if ctx.adherence.missedDaysThisWeek >= 2 {
            facts.append(.init(
                kind: .adherence,
                severity: .notable,
                templateKey: "fact.adherence.behind_this_week",
                values: ["missed": "\(ctx.adherence.missedDaysThisWeek)"]
            ))
        }

        // ------------------------------------------------------------------
        // Today's progress vs. target. The "1.5x overshoot" threshold is
        // chosen so casually-long workouts (lunch run goes 5 minutes long)
        // don't trigger; only genuine "I went hard today" sessions do.
        // ------------------------------------------------------------------

        let target = max(1, ctx.targetMinutesToday)
        let ratio = Double(ctx.actualMinutesToday) / Double(target)

        if ratio >= 1.5 {
            let overshootPct = Int(((ratio - 1.0) * 100).rounded())
            facts.append(.init(
                kind: .progress,
                severity: .notable,
                templateKey: "fact.progress.overshoot",
                values: [
                    "actual": "\(ctx.actualMinutesToday)",
                    "target": "\(target)",
                    "overshoot": "\(overshootPct)"
                ]
            ))
        } else if ratio < 0.7 {
            facts.append(.init(
                kind: .progress,
                severity: .normal,
                templateKey: "fact.progress.short_of_target",
                values: [
                    "actual": "\(ctx.actualMinutesToday)",
                    "target": "\(target)"
                ]
            ))
        } else if (0.95...1.10).contains(ratio) {
            facts.append(.init(
                kind: .progress,
                severity: ctx.day <= 21 ? .notable : .normal,
                templateKey: "fact.progress.on_target",
                values: [
                    "actual": "\(ctx.actualMinutesToday)",
                    "target": "\(target)"
                ]
            ))
        }

        // ------------------------------------------------------------------
        // Fitness trend — CTL delta over the trailing 7 days. The 3-unit
        // threshold corresponds to roughly one extra Z2 hour per week
        // sustained over the period; smaller deltas are noise. Severity
        // notable because the visible trajectory matters more than today's
        // single workout for long-term habit formation.
        // ------------------------------------------------------------------

        let ctlDelta = ctx.load.ctlDelta
        if ctlDelta >= 3 {
            facts.append(.init(
                kind: .fitnessTrend,
                severity: .normal,
                templateKey: "fact.ctl.rising",
                values: [
                    "delta": String(format: "%.1f", ctlDelta),
                    "ctl": String(format: "%.0f", ctx.load.ctlToday)
                ]
            ))
        } else if ctlDelta <= -3 {
            facts.append(.init(
                kind: .fitnessTrend,
                severity: .normal,
                templateKey: "fact.ctl.falling",
                values: [
                    "delta": String(format: "%.1f", abs(ctlDelta)),
                    "ctl": String(format: "%.0f", ctx.load.ctlToday)
                ]
            ))
        }

        // ------------------------------------------------------------------
        // Recovery — TSB (CTL − ATL). Conventional thresholds from
        // TrainingPeaks: < −20 = high fatigue, > +5 = fresh. We use ±10/+15
        // to bias toward silence (don't speak unless meaningfully out of
        // range). Notable only on the fatigue side — being fresh is good
        // news that doesn't require commentary.
        // ------------------------------------------------------------------

        let tsb = ctx.load.tsbToday
        if tsb < -20 {
            facts.append(.init(
                kind: .recovery,
                severity: .notable,
                templateKey: "fact.recovery.deep_fatigue",
                values: ["tsb": String(format: "%.0f", tsb)]
            ))
        } else if tsb > 15 {
            facts.append(.init(
                kind: .recovery,
                severity: .quiet,
                templateKey: "fact.recovery.fresh",
                values: ["tsb": String(format: "%.0f", tsb)]
            ))
        }

        // ------------------------------------------------------------------
        // HR drift — when comparable history exists. Tiered by magnitude:
        //   < −5 bpm in non-early phase  →  .notable (real aerobic gain)
        //   ≥ +10 bpm any phase           →  .notable (something is off:
        //                                    sleep, heat, illness, dehydration)
        //   ≥ +5 bpm any phase            →  .normal (worth surfacing)
        //   else: silent
        // The asymmetric thresholds reflect that elevated-HR is a louder
        // signal than slightly-lower-HR — small day-to-day variation is
        // common, so we wait until the signal is unambiguous.
        // ------------------------------------------------------------------

        if let trend = ctx.hrAtPaceTrend {
            if trend.deltaBPM <= -5, ctx.phase != .early {
                facts.append(.init(
                    kind: .hrDrift,
                    severity: .notable,
                    templateKey: "fact.aerobic.improving",
                    values: [
                        "delta": String(format: "%.0f", abs(trend.deltaBPM)),
                        "type": ctx.workout.typeName ?? ""
                    ]
                ))
            } else if trend.deltaBPM >= 10 {
                facts.append(.init(
                    kind: .hrDrift,
                    severity: .notable,
                    templateKey: "fact.aerobic.elevated_hr",
                    values: [
                        "delta": String(format: "%.0f", trend.deltaBPM),
                        "type": ctx.workout.typeName ?? ""
                    ]
                ))
            } else if trend.deltaBPM >= 5 {
                facts.append(.init(
                    kind: .hrDrift,
                    severity: .normal,
                    templateKey: "fact.aerobic.elevated_hr",
                    values: [
                        "delta": String(format: "%.0f", trend.deltaBPM),
                        "type": ctx.workout.typeName ?? ""
                    ]
                ))
            }
        }

        // ------------------------------------------------------------------
        // Zone shape of today's workout. Most workouts are mixed; only
        // call out the polarized ends — heavily aerobic (Z1+Z2 dominant)
        // or heavily intense (Z4+Z5 dominant). The middle (mostly Z3)
        // is the no-man's-land called "grey-zone training" in the
        // endurance literature; we don't flag it here, but a future
        // weekly-recap might.
        // ------------------------------------------------------------------

        if let zones = ctx.zones, zones.totalSeconds > 0 {
            let aerobic = zones.seconds(in: HeartRateZone.z1) + zones.seconds(in: HeartRateZone.z2)
            let intense = zones.seconds(in: HeartRateZone.z4) + zones.seconds(in: HeartRateZone.z5)
            let aerobicFrac = aerobic / zones.totalSeconds
            let intenseFrac = intense / zones.totalSeconds

            if aerobicFrac >= 0.75 {
                facts.append(.init(
                    kind: .zones,
                    severity: .normal,
                    templateKey: "fact.zones.aerobic_base",
                    values: ["pct": "\(Int((aerobicFrac * 100).rounded()))"]
                ))
            } else if intenseFrac >= 0.40 {
                facts.append(.init(
                    kind: .zones,
                    severity: .normal,
                    templateKey: "fact.zones.high_intensity",
                    values: ["pct": "\(Int((intenseFrac * 100).rounded()))"]
                ))
            }
        }

        return CoachFacts(all: facts)
    }
}
