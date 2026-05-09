//
//  ProgressCoachContextBuilder.swift
//  WorkoutChallenge
//
//  Async composer for the Progress-tab coach card. Sibling of
//  `CoachContextBuilder`. Differs in two ways:
//
//    1. No "in focus" workout — Progress is a survey-style surface. We
//       collect the most-recent workout to ground "you last trained N
//       days ago" copy, but most facts come from the trailing window
//       and aggregate services (TrainingLoadService, AnalyticsService).
//    2. Pulls VO₂Max + HRV trends from HealthKit so the teaching-voice
//       narrator can comment on them in plain language. The trends are
//       early-window vs. late-window deltas — point-to-point HK readings
//       are too noisy to read at 90-day zoom.
//
//  After building the bundle, we run `ProgressDeterministicCoach.pickFocus`
//  to decide the dominant signal and stamp it onto the context — the
//  narrator branches on `.focus`, and so does the card visuals.
//

import Foundation

@MainActor
enum ProgressCoachContextBuilder {

    /// Build a context for the Progress coach card.
    ///
    /// - Parameters:
    ///   - allWorkouts: Every workout in the store. The builder filters
    ///     internally to whichever windows it needs.
    ///   - challenge: Current `ChallengeModel` (active or paused).
    ///   - config: Resolved active config from `ChallengeService.activeConfig`.
    ///   - healthKit: For VO₂Max + HRV series. Skipped gracefully when
    ///     unavailable — the narrator just won't have those numbers.
    ///   - locale: Output locale (drives narrator/TTS language).
    ///   - now: Injectable clock for tests.
    static func build(
        allWorkouts: [WorkoutModel],
        challenge: ChallengeModel?,
        config: ChallengeService.ActiveConfig,
        healthKit: HealthKitService,
        locale: Locale = .current,
        now: Date = Date()
    ) async -> ProgressCoachContext {

        // -----------------------------------------------------------------
        // Day-of-arc + targets — same logic as CoachContextBuilder so the
        // two surfaces never disagree about what day it is.
        // -----------------------------------------------------------------

        let day: Int = {
            if let challenge { return ChallengeService.currentDay(of: challenge, now: now) }
            let elapsed = now.timeIntervalSince(config.startDate) / 86_400
            return max(1, min(90, Int(elapsed.rounded(.down)) + 1))
        }()

        let phase = ChallengePhase.from(day: day)

        let targetMinutes = Int(SigmoidalService.targetDuration(
            dayIndex: day,
            params: config.sigmoid
        ).rounded())

        let dayKey = now.startOfDay
        let actualMinutesToday = allWorkouts
            .filter { $0.date.startOfDay == dayKey }
            .reduce(0) { $0 + $1.duration }

        // -----------------------------------------------------------------
        // Most-recent workout (across the full store, not just trailing 14).
        // We want this even if the user has been quiet for two weeks.
        // -----------------------------------------------------------------

        let sortedByDate = allWorkouts.sorted { $0.date > $1.date }
        let mostRecent: RecentWorkoutSummary? = sortedByDate.first.map { w in
            let daysAgo = max(0, dayKey.daysUntil(w.date.startOfDay) * -1)
            return RecentWorkoutSummary(
                date: w.date,
                durationMinutes: w.duration,
                typeName: w.workoutType?.name,
                daysAgo: daysAgo
            )
        }

        // -----------------------------------------------------------------
        // Trailing-7 distinct days — used by adherence rules and by the
        // narrator's "you've been showing up X days a week" framing.
        // -----------------------------------------------------------------

        let last7Start = now.addingDays(-7).startOfDay
        let distinctDaysLast7 = Set(
            allWorkouts
                .filter { $0.date >= last7Start && $0.date <= now }
                .map { $0.date.startOfDay }
        )

        // -----------------------------------------------------------------
        // Concurrent: training load math + HK series. All independent.
        // -----------------------------------------------------------------

        async let trainingLoadResult = computeTrainingLoad(
            allWorkouts: allWorkouts,
            now: now
        )
        async let vo2Result = fetchPhysiology(
            healthKit: healthKit,
            sampler: { since, until in
                let samples = await healthKit.fetchVO2MaxSeries(since: since, until: until)
                return samples.map { ($0.date, $0.value) }
            },
            startDate: config.startDate,
            endDate: now
        )
        async let hrvResult = fetchPhysiology(
            healthKit: healthKit,
            sampler: { since, until in
                let samples = await healthKit.fetchHRVSeries(since: since, until: until)
                return samples.map { ($0.date, $0.value) }
            },
            startDate: config.startDate,
            endDate: now
        )

        // -----------------------------------------------------------------
        // Adherence — same shape as CoachContextBuilder, computed on full
        // store. `summary` walks all workouts; cheap.
        // -----------------------------------------------------------------

        let summary = AnalyticsService.summary(from: allWorkouts)

        // Distinct prior workout-days in the trailing 7 (excluding today —
        // today's workout, if any, is folded into actualMinutesToday).
        let priorDistinctDays = Set(
            allWorkouts
                .filter { $0.date >= last7Start && $0.date.startOfDay < dayKey }
                .map { $0.date.startOfDay }
        )

        let isReturnAfterBreak: Bool = {
            // True if today has a logged workout AND the prior workout was
            // ≥2 days ago. This makes the Progress card recognize the same
            // signal as the post-workout card on the same day.
            let todaysWorkouts = allWorkouts.filter { $0.date.startOfDay == dayKey }
            guard !todaysWorkouts.isEmpty else { return false }
            guard let lastPrior = sortedByDate.first(where: {
                $0.date.startOfDay < dayKey
            }) else { return false }
            let gap = dayKey.timeIntervalSince(lastPrior.date.startOfDay) / 86_400
            return gap >= 2.0
        }()

        // Did today's calendar day count toward the weekly target? +1 if
        // the user already logged something today.
        let didToday = (actualMinutesToday > 0) ? 1 : 0
        let missedThisWeek = max(
            0,
            config.daysPerWeek - (priorDistinctDays.count + didToday)
        )

        let adherence = AdherenceSnapshot(
            currentStreakDays: summary.currentStreakDays,
            longestStreakDays: summary.longestStreakDays,
            missedDaysThisWeek: missedThisWeek,
            isReturnAfterBreak: isReturnAfterBreak
        )

        // Await async branches.
        let resolvedLoad = await trainingLoadResult
        let vo2 = await vo2Result
        let hrv = await hrvResult

        // -----------------------------------------------------------------
        // Build the context with focus = .none, then ask the deterministic
        // pass to pick the dominant signal. Avoids a circular dependency
        // (focus rule needs the rest of the context to be built first).
        // -----------------------------------------------------------------

        let pre = ProgressCoachContext(
            day: day,
            totalDays: 90,
            phase: phase,
            targetMinutesToday: targetMinutes,
            actualMinutesToday: actualMinutesToday,
            mostRecentWorkout: mostRecent,
            workoutDaysLast7: distinctDaysLast7.count,
            load: resolvedLoad,
            adherence: adherence,
            vo2Max: vo2,
            hrv: hrv,
            focus: .none,
            locale: locale
        )

        let focus = ProgressDeterministicCoach.pickFocus(pre)

        return ProgressCoachContext(
            day: pre.day,
            totalDays: pre.totalDays,
            phase: pre.phase,
            targetMinutesToday: pre.targetMinutesToday,
            actualMinutesToday: pre.actualMinutesToday,
            mostRecentWorkout: pre.mostRecentWorkout,
            workoutDaysLast7: pre.workoutDaysLast7,
            load: pre.load,
            adherence: pre.adherence,
            vo2Max: pre.vo2Max,
            hrv: pre.hrv,
            focus: focus,
            locale: pre.locale
        )
    }

    // MARK: - Training load (parallel branch)

    /// Same math as `CoachContextBuilder.computeTrainingLoad` — kept here
    /// to avoid coupling the two surfaces' builders. If we ever extract
    /// this into a shared helper, both sides should adopt it together.
    private static func computeTrainingLoad(
        allWorkouts: [WorkoutModel],
        now: Date
    ) async -> TrainingLoadSnapshot {
        let end = now.startOfDay
        let start = end.addingDays(-90)
        let dailyLoads = TrainingLoadService.dailyLoads(
            workouts: allWorkouts,
            startDate: start,
            endDate: end
        )

        let ctlSeries = TrainingLoadService.ctl(loads: dailyLoads)
        let atlSeries = TrainingLoadService.atl(loads: dailyLoads)

        let ctlToday = ctlSeries.last?.value ?? 0
        let atlToday = atlSeries.last?.value ?? 0
        let ctl7DaysAgo: Double = {
            guard ctlSeries.count >= 8 else { return ctlToday }
            return ctlSeries[ctlSeries.count - 8].value
        }()

        return TrainingLoadSnapshot(
            ctlToday: ctlToday,
            ctl7DaysAgo: ctl7DaysAgo,
            atlToday: atlToday
        )
    }

    // MARK: - Physiology trend

    /// Common helper for VO₂Max + HRV series. Both share the same shape:
    /// fetch samples, take latest as `latest`, latest − earliest as `delta`,
    /// count samples. Hides the empty-series and HK-unavailable cases as nil.
    private static func fetchPhysiology(
        healthKit: HealthKitService,
        sampler: (Date, Date) async -> [(Date, Double)],
        startDate: Date,
        endDate: Date
    ) async -> PhysiologyTrend? {
        guard healthKit.isAvailable else { return nil }
        let samples = await sampler(startDate, endDate.addingDays(1))
        guard let first = samples.first?.1, let last = samples.last?.1 else {
            return nil
        }
        return PhysiologyTrend(
            latest: last,
            delta: last - first,
            sampleCount: samples.count
        )
    }
}
