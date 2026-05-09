//
//  ProgressDeterministicCoach.swift
//  WorkoutChallenge
//
//  Layer 1 for the Progress-tab coach card. Sibling of `DeterministicCoach`
//  but with a different mandate:
//
//    Post-workout coach: weave multiple notable facts about a single
//    completed session ("you went 30% over target AND the streak hit 6").
//
//    Progress coach: pick ONE clear focus for the day. Progress is a
//    survey-style surface — the user is glancing at where they are in the
//    arc, not chewing on a finished session. A single thoughtful sentence
//    beats a paragraph of weaves.
//
//  Two outputs:
//
//    1. `pickFocus(_:)` — runs over a context and chooses the dominant
//       signal (used by `ProgressCoachContextBuilder` to stamp `.focus`
//       onto the context before persistence).
//    2. `observe(_:)` — emits `CoachFacts` matching the chosen focus.
//       The facts list is shorter than the post-workout coach's because
//       Progress wants a clean lead, not a weave. Severity is `.notable`
//       for the focus fact and `.normal` for supporting context.
//
//  Threshold philosophy mirrors `DeterministicCoach`: prefer silence over
//  noise. When nothing crosses a meaningful threshold, focus is `.none`
//  and the card stays quiet (DEBUG-only render).
//

import Foundation

enum ProgressDeterministicCoach {

    // MARK: - Focus selection

    /// Pick the single dominant signal for today's render. Priority order
    /// reflects what the user most needs to hear about — milestones first
    /// (rare, deserve airtime), then anything alarming (deep fatigue,
    /// behind pace), then forward-looking trends (rising fitness, locking
    /// streak), then quieter signals (VO₂Max/HRV drift).
    ///
    /// "Most needs to hear" is a calibration choice, not a universal
    /// truth — adjust the order as you live with it.
    static func pickFocus(_ ctx: ProgressCoachContext) -> ProgressCoachFocus {

        // 1. Once-per-arc moments. Always lead with these on the day.
        if [1, 30, 60, 90].contains(ctx.day) {
            return .milestone
        }

        // 2. Return-after-break — first workout after a ≥2-day gap.
        //    Recognizing the return matters more than commenting on the
        //    gap; this is a high-leverage moment for tone.
        if ctx.adherence.isReturnAfterBreak {
            return .returnAfterBreak
        }

        // 3. Deep fatigue. TSB < −20 = the user is significantly under-
        //    recovered. Naming this protects against overtraining injury.
        if ctx.load.tsbToday < -20 {
            return .recoveryDeficit
        }

        // 4. Behind pace. ≥2 missed days this week is when the pattern
        //    starts to need acknowledgment vs. one-off skip.
        if ctx.adherence.missedDaysThisWeek >= 2 {
            return .behindPace
        }

        // 5. Fitness rising. CTL +3 over the trailing 7 days = roughly
        //    a sustained extra Z2 hour per week. Worth recognizing.
        if ctx.load.ctlDelta >= 3 {
            return .fitnessRising
        }

        // 6. Fitness falling. Same magnitude in the other direction.
        //    Less notable than rising on the Progress surface (the user
        //    is already probably feeling it), but worth one sentence.
        if ctx.load.ctlDelta <= -3 {
            return .fitnessFalling
        }

        // 7. Early-phase streak forming. The phase guard is intentional —
        //    a 5-day streak in week 1 is huge; in week 12 it's the floor.
        if ctx.phase == .early, ctx.adherence.currentStreakDays >= 5 {
            return .streakLockingIn
        }

        // 8. VO₂Max moving. Apple posts these every 1–2 weeks, so by
        //    mid-arc the user typically has 4–8 samples. A ±1.5 mL/(kg·min)
        //    delta over the window is meaningful at the noise floor.
        if let vo2 = ctx.vo2Max,
           vo2.sampleCount >= 3,
           abs(vo2.delta) >= 1.5 {
            return .vo2MaxMoving
        }

        // 9. HRV shift. Larger absolute threshold (8 ms) because HRV is
        //    noisier than VO₂Max at the day-to-day scale. Sample-count
        //    guard same idea.
        if let hrv = ctx.hrv,
           hrv.sampleCount >= 3,
           abs(hrv.delta) >= 8 {
            return .hrvShift
        }

        // 10. On-track when nothing else stands out. This produces a
        //     gentle "you're holding the line" rather than awkward silence
        //     during quiet stretches of the arc. Coach earns the right to
        //     speak by being brief and specific even here.
        if ctx.actualMinutesToday > 0 || ctx.workoutDaysLast7 >= 2 {
            return .onTrack
        }

        // Truly nothing notable AND no recent activity → silent in Release.
        return .none
    }

    // MARK: - Facts

    /// Emit `CoachFacts` matching the chosen focus. The first fact is
    /// always severity `.notable` (the lead), and any supporting facts
    /// are `.normal`.
    static func observe(_ ctx: ProgressCoachContext) -> CoachFacts {
        var facts: [CoachFact] = []

        switch ctx.focus {

        case .milestone:
            facts.append(.init(
                kind: .milestone,
                severity: .notable,
                templateKey: "fact.progress.milestone",
                values: ["day": "\(ctx.day)", "total": "\(ctx.totalDays)"]
            ))

        case .returnAfterBreak:
            facts.append(.init(
                kind: .milestone,
                severity: .notable,
                templateKey: "fact.progress.return_after_break",
                values: ["day": "\(ctx.day)"]
            ))

        case .recoveryDeficit:
            facts.append(.init(
                kind: .recovery,
                severity: .notable,
                templateKey: "fact.progress.recovery_deficit",
                values: [
                    "tsb": String(format: "%.0f", ctx.load.tsbToday),
                    "ctl": String(format: "%.0f", ctx.load.ctlToday),
                    "atl": String(format: "%.0f", ctx.load.atlToday)
                ]
            ))

        case .behindPace:
            facts.append(.init(
                kind: .adherence,
                severity: .notable,
                templateKey: "fact.progress.behind_pace",
                values: [
                    "missed": "\(ctx.adherence.missedDaysThisWeek)",
                    "day": "\(ctx.day)",
                    "total": "\(ctx.totalDays)"
                ]
            ))

        case .fitnessRising:
            facts.append(.init(
                kind: .fitnessTrend,
                severity: .notable,
                templateKey: "fact.progress.fitness_rising",
                values: [
                    "delta": String(format: "%.1f", ctx.load.ctlDelta),
                    "ctl": String(format: "%.0f", ctx.load.ctlToday)
                ]
            ))

        case .fitnessFalling:
            facts.append(.init(
                kind: .fitnessTrend,
                severity: .notable,
                templateKey: "fact.progress.fitness_falling",
                values: [
                    "delta": String(format: "%.1f", abs(ctx.load.ctlDelta)),
                    "ctl": String(format: "%.0f", ctx.load.ctlToday)
                ]
            ))

        case .streakLockingIn:
            facts.append(.init(
                kind: .adherence,
                severity: .notable,
                templateKey: "fact.progress.streak_locking_in",
                values: ["streak": "\(ctx.adherence.currentStreakDays)"]
            ))

        case .vo2MaxMoving:
            if let vo2 = ctx.vo2Max {
                facts.append(.init(
                    kind: .fitnessTrend,
                    severity: .notable,
                    templateKey: vo2.delta > 0
                        ? "fact.progress.vo2_rising"
                        : "fact.progress.vo2_falling",
                    values: [
                        "latest": String(format: "%.0f", vo2.latest),
                        "delta": String(format: "%.1f", abs(vo2.delta))
                    ]
                ))
            }

        case .hrvShift:
            if let hrv = ctx.hrv {
                facts.append(.init(
                    kind: .recovery,
                    severity: .notable,
                    templateKey: hrv.delta > 0
                        ? "fact.progress.hrv_rising"
                        : "fact.progress.hrv_falling",
                    values: [
                        "latest": String(format: "%.0f", hrv.latest),
                        "delta": String(format: "%.0f", abs(hrv.delta))
                    ]
                ))
            }

        case .onTrack:
            facts.append(.init(
                kind: .progress,
                severity: .notable,
                templateKey: "fact.progress.on_track",
                values: [
                    "day": "\(ctx.day)",
                    "total": "\(ctx.totalDays)",
                    "streak": "\(ctx.adherence.currentStreakDays)"
                ]
            ))

        case .none:
            return CoachFacts(all: [])
        }

        // -----------------------------------------------------------------
        // Supporting facts — always-on context the narrator can lean on
        // for the teaching beat. Severity normal so they're carried into
        // the prompt but don't crowd the lead.
        // -----------------------------------------------------------------

        facts.append(.init(
            kind: .progress,
            severity: .normal,
            templateKey: "fact.progress.day_position",
            values: [
                "day": "\(ctx.day)",
                "total": "\(ctx.totalDays)",
                "phase": ctx.phase.rawValue
            ]
        ))

        if let recent = ctx.mostRecentWorkout, ctx.focus != .returnAfterBreak {
            facts.append(.init(
                kind: .adherence,
                severity: .normal,
                templateKey: "fact.progress.last_workout",
                values: [
                    "days_ago": "\(recent.daysAgo)",
                    "minutes": "\(recent.durationMinutes)",
                    "type": recent.typeName ?? ""
                ]
            ))
        }

        return CoachFacts(all: facts)
    }
}
