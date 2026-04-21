//
//  ChallengeService.swift
//  WorkoutChallenge
//
//  Lifecycle helpers for `ChallengeModel`. The rules:
//
//    • Exactly one "current" challenge at any time — either `.active` or
//      `.paused`. Everything else sits in history.
//    • Starting a new challenge requires the previous one to be in a
//      terminal state (`.completed` or `.abandoned`) or for there to be
//      no current challenge at all.
//    • Pause/Resume bookkeeping lives on the model — see
//      `ChallengeModel.effectivePausedSeconds`. We only update the fields
//      here and leave the math to the model.
//    • "Current day" is 1-indexed and clamped to 1...90 so UI copy like
//      "Day 54 of 90" always reads cleanly.
//
//  All mutating helpers are synchronous — they operate on the passed
//  `ModelContext` and return immediately. Callers are responsible for
//  saving the context (SwiftData autosaves, but explicit `try? save()` is
//  safe).
//

import Foundation
import SwiftData

enum ChallengeService {

    // MARK: - Active config

    /// Resolved schedule configuration — what the app should treat as
    /// "the live challenge setup" for everything outside the challenge
    /// lifecycle itself (progression curve, per-day targets, week
    /// grouping, analytics). When a challenge is current (active or
    /// paused), the snapshot on `ChallengeModel` is the source of truth
    /// — that's how we keep history frozen even when the user later
    /// tweaks defaults between challenges. When no challenge is current,
    /// we fall back to `UserPreferencesModel` so the sliders act as
    /// "defaults for next challenge" that pre-populate the Create flow.
    ///
    /// `firstWeekday` always comes from prefs — it's a display setting
    /// (Sunday-start vs. Monday-start), not a challenge term, and it
    /// should stay consistent across challenges.
    struct ActiveConfig: Equatable {
        let startDate: Date
        let daysPerWeek: Int
        let sigmoid: SigmoidParams
        let firstWeekday: Int
    }

    /// Returns the live challenge configuration the rest of the app
    /// should read from. Prefer this over reading prefs directly —
    /// prefs is only correct between challenges.
    ///
    /// Returns nil only when `prefs` is nil (i.e. pre-first-launch);
    /// once the onboarding flow has inserted a prefs row, this is
    /// always populated.
    static func activeConfig(
        challenges: [ChallengeModel],
        prefs: UserPreferencesModel?
    ) -> ActiveConfig? {
        guard let prefs else { return nil }
        if let current = currentChallenge(in: challenges) {
            return ActiveConfig(
                startDate: current.startDate,
                daysPerWeek: current.daysPerWeek,
                sigmoid: current.sigmoid,
                firstWeekday: prefs.firstWeekday
            )
        }
        return ActiveConfig(
            startDate: prefs.startDate,
            daysPerWeek: prefs.daysPerWeek,
            sigmoid: prefs.sigmoid,
            firstWeekday: prefs.firstWeekday
        )
    }

    // MARK: - Reading state

    /// Returns the sole "current" challenge (`.active` or `.paused`) or
    /// `nil` if the user is between challenges. Multiple current rows
    /// would be a data-model bug — the service keeps the invariant by
    /// being the only creator of challenges.
    static func currentChallenge(in challenges: [ChallengeModel]) -> ChallengeModel? {
        challenges.first { $0.state.isCurrent }
    }

    /// Past (completed or abandoned) challenges, newest first.
    static func history(in challenges: [ChallengeModel]) -> [ChallengeModel] {
        challenges
            .filter { !$0.state.isCurrent }
            .sorted { lhs, rhs in
                (lhs.endedAt ?? lhs.startDate) > (rhs.endedAt ?? rhs.startDate)
            }
    }

    /// 1-indexed day number, clamped to [1, 90]. Accounts for paused time
    /// so a 3-day pause on day 10 still reads "Day 10" three days later
    /// instead of "Day 13". Ticks forward even when the challenge is in
    /// `.paused` *for display purposes* — we don't advance while paused.
    static func currentDay(of challenge: ChallengeModel, now: Date = Date()) -> Int {
        let effectiveNow: Date
        if challenge.state == .paused, let pausedSince = challenge.pausedSince {
            // While paused, clock is frozen at pause moment.
            effectiveNow = pausedSince
        } else {
            effectiveNow = now
        }
        let elapsed = effectiveNow.timeIntervalSince(challenge.startDate)
            - challenge.effectivePausedSeconds
        let day = Int((elapsed / 86_400).rounded(.down)) + 1
        return max(1, min(challenge.totalDays, day))
    }

    /// 0...1 progression through the 90-day challenge.
    static func progress(of challenge: ChallengeModel, now: Date = Date()) -> Double {
        let day = currentDay(of: challenge, now: now)
        return Double(day) / Double(challenge.totalDays)
    }

    /// Count of days that have been completed according to the workout
    /// log. Used by the Challenge card to render "54 completed" — this is
    /// a simple distinct-day count across the window and matches what
    /// `WeeklyScheduleService.weeks(...).sum(\.completedCount)` would give
    /// you, at a fraction of the cost.
    static func completedDayCount(
        of challenge: ChallengeModel,
        workouts: [WorkoutModel]
    ) -> Int {
        let windowEnd = challenge.endedAt ?? Date()
        let windowStart = challenge.startDate.startOfDay
        let inWindow = workouts.filter { w in
            let d = w.date
            return d >= windowStart && d <= windowEnd
        }
        let uniqueDays = Set(inWindow.map { $0.date.startOfDay })
        return uniqueDays.count
    }

    // MARK: - Transitions

    /// Pause the active challenge. No-op if already paused or not active.
    static func pause(_ challenge: ChallengeModel, at moment: Date = Date()) {
        guard challenge.state == .active else { return }
        challenge.pausedSince = moment
        challenge.state = .paused
    }

    /// Resume a paused challenge, banking the paused duration into
    /// `totalPausedSeconds`.
    static func resume(_ challenge: ChallengeModel, at moment: Date = Date()) {
        guard challenge.state == .paused, let since = challenge.pausedSince else { return }
        let elapsed = max(0, moment.timeIntervalSince(since))
        challenge.totalPausedSeconds += elapsed
        challenge.pausedSince = nil
        challenge.state = .active
    }

    /// Move the challenge into `.abandoned`. Idempotent — a second call
    /// is a no-op. Banks any in-progress pause before terminating.
    static func abandon(_ challenge: ChallengeModel, at moment: Date = Date()) {
        guard challenge.state.isCurrent else { return }
        if challenge.state == .paused, let since = challenge.pausedSince {
            challenge.totalPausedSeconds += max(0, moment.timeIntervalSince(since))
            challenge.pausedSince = nil
        }
        challenge.state = .abandoned
        challenge.endedAt = moment
    }

    /// Move the challenge into `.completed`. Only valid when the effective
    /// current day has reached `totalDays`, but we leave enforcement to
    /// the UI so the user can manually mark complete if they want to.
    static func complete(_ challenge: ChallengeModel, at moment: Date = Date()) {
        guard challenge.state.isCurrent else { return }
        if challenge.state == .paused, let since = challenge.pausedSince {
            challenge.totalPausedSeconds += max(0, moment.timeIntervalSince(since))
            challenge.pausedSince = nil
        }
        challenge.state = .completed
        challenge.endedAt = moment
    }

    // MARK: - Creation

    /// Start a fresh challenge. Will refuse if one is already current —
    /// callers must abandon/complete first. The new challenge is numbered
    /// `max(history.number) + 1`, or 1 if history is empty.
    @discardableResult
    static func startNew(
        context: ModelContext,
        existing challenges: [ChallengeModel],
        startDate: Date,
        daysPerWeek: Int,
        sigmoid: SigmoidParams,
        pledgeSignature: String = ""
    ) -> ChallengeModel? {
        if currentChallenge(in: challenges) != nil { return nil }
        let maxNumber = challenges.map(\.number).max() ?? 0
        let new = ChallengeModel(
            number: maxNumber + 1,
            startDate: startDate,
            daysPerWeek: daysPerWeek,
            state: .active,
            sigmoid: sigmoid,
            pledgeSignature: pledgeSignature
        )
        context.insert(new)
        return new
    }

    // MARK: - Migration

    /// Auto-create a challenge from existing `UserPreferencesModel` on
    /// first launch. No-op if any challenge row already exists — the
    /// app has been launched at least once on Phase-2 code. Called from
    /// `RootView.ensureDefaults`.
    static func migrateFromPrefsIfNeeded(
        context: ModelContext,
        prefs: UserPreferencesModel?,
        challenges: [ChallengeModel]
    ) {
        guard challenges.isEmpty, let prefs else { return }
        let seeded = ChallengeModel(
            number: 1,
            startDate: prefs.startDate,
            daysPerWeek: prefs.daysPerWeek,
            state: .active,
            sigmoid: prefs.sigmoid
        )
        context.insert(seeded)
    }

    // MARK: - Fitness decay (paused-state readout)

    /// Simple VO₂max decay model used on the paused-state banner. Per the
    /// design copy: "Aerobic capacity drops ~1.2% per week of pause.
    /// Resume within 10 days to stay in growth phase." Linear ~1.2%/week
    /// for the first few weeks is a reasonable approximation.
    ///
    /// Input: pause duration in seconds → output: illustrative delta in
    /// VO₂max (ml·kg⁻¹·min⁻¹), assuming a 42 ml starting baseline.
    static func vo2DecayReadout(pausedFor seconds: Double) -> (from: Double, to: Double) {
        let weeks = seconds / (7 * 86_400)
        let pctLoss = min(0.30, weeks * 0.012)   // cap at 30% loss
        let base = 42.0
        return (base, base * (1 - pctLoss))
    }
}
