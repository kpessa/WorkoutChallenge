//
//  CoachContextBuilder.swift
//  WorkoutChallenge
//
//  Async composer that assembles a `CoachContext` from the existing
//  service layer (TrainingLoadService, ChallengeService, AnalyticsService,
//  WeeklyScheduleService, MaxHRService, HealthKitService, SigmoidalService).
//
//  Pure composition — no new analytics live here. If a derived value can
//  be computed by a sibling service, it goes through that service so we
//  don't fork the math. The builder's job is to call those services in the
//  right order, in parallel where independent, and bundle the result.
//
//  Returned context is a value type and Sendable — pass it freely to
//  Layer 1 (DeterministicCoach) on any actor, or hand it across to the
//  narrators (FoundationModel / Anthropic / Gemini) when those land.
//

import Foundation
import HealthKit

@MainActor
enum CoachContextBuilder {

    /// Build the input bundle for a just-completed workout.
    ///
    /// Caller is responsible for passing the resolved active configuration
    /// (`ChallengeService.activeConfig`) and the resolved Max HR
    /// (`MaxHRService.resolve`) so the builder doesn't fork those decisions.
    /// HR-zone enrichment is loaded async from HealthKit; a missing or
    /// HR-less workout simply produces a context with `zones == nil`,
    /// which Layer 1 rules tolerate.
    ///
    /// - Parameters:
    ///   - workout: The just-completed workout. Must be a hydrated
    ///     SwiftData row (so we can read `id`, `date`, `duration`, `workoutType`).
    ///   - allWorkouts: Every workout in the store. The builder filters
    ///     to the trailing 14-day window internally — passing in the full
    ///     log is fine (and arguably preferable for cache stability).
    ///   - challenge: The current `ChallengeModel` (active or paused).
    ///     Pass nil to use the prefs fallback for between-challenge state.
    ///   - config: The resolved active config from `ChallengeService.activeConfig`.
    ///   - maxHR: The resolved Max HR. Nil only on first launch before
    ///     prefs exist; in that case zone math is skipped.
    ///   - restingHR: The resolved resting HR. 0 (default) means the
    ///     user hasn't set it — zone math falls back to %-of-max for
    ///     compatibility. >0 enables HRR/Karvonen, matching the Watch.
    ///   - healthKit: For HR-sample enrichment of the just-completed workout.
    ///   - locale: Output locale (drives narrator/TTS language).
    ///   - now: Injectable clock for tests.
    static func build(
        workout: WorkoutModel,
        allWorkouts: [WorkoutModel],
        challenge: ChallengeModel?,
        config: ChallengeService.ActiveConfig,
        restingHR: Double = 0,
        maxHR: Double?,
        healthKit: HealthKitService,
        locale: Locale = .current,
        now: Date = Date()
    ) async -> CoachContext {

        // -----------------------------------------------------------------
        // Trailing window
        // -----------------------------------------------------------------

        let windowStart = now.addingDays(-14).startOfDay
        let trailing = allWorkouts
            .filter { $0.id != workout.id && $0.date >= windowStart && $0.date <= now }
            .sorted { $0.date > $1.date }   // newest first

        let trailingSummaries = trailing.map { Self.summarize($0) }

        // Distinct workout-days in the trailing 7.
        let last7Start = now.addingDays(-7).startOfDay
        let distinctDaysLast7 = Set(
            trailing
                .filter { $0.date >= last7Start }
                .map { $0.date.startOfDay }
        )

        // -----------------------------------------------------------------
        // Concurrent enrichment / load math
        //
        // Focus enrichment loads HR samples ONCE and derives both zones
        // and the avg HR from the same array — earlier this was split
        // into two parallel `async let` branches that each round-tripped
        // to HealthKit and held their own copy of (potentially thousands
        // of) HR samples in memory. On a 30+ minute workout that doubled
        // peak memory unnecessarily.
        //
        // Training load math is independent and runs in parallel.
        // -----------------------------------------------------------------

        async let focusEnrichment = Self.fetchFocusEnrichment(
            for: workout,
            healthKit: healthKit,
            maxHR: maxHR ?? 190,
            restingHR: restingHR
        )

        async let trainingLoad = Self.computeTrainingLoad(
            allWorkouts: allWorkouts,
            now: now
        )

        // -----------------------------------------------------------------
        // Day-of-arc + targets
        // -----------------------------------------------------------------

        let day: Int = {
            if let challenge { return ChallengeService.currentDay(of: challenge, now: now) }
            // No challenge yet — derive from prefs startDate the same way
            // ChallengeService would for a fresh active.
            let elapsed = now.timeIntervalSince(config.startDate) / 86_400
            return max(1, min(90, Int(elapsed.rounded(.down)) + 1))
        }()

        let phase = ChallengePhase.from(day: day)

        let targetMinutes = Int(SigmoidalService.targetDuration(
            dayIndex: day,
            params: config.sigmoid
        ).rounded())

        let dayKey = workout.date.startOfDay
        let actualMinutesToday = allWorkouts
            .filter { $0.date.startOfDay == dayKey }
            .reduce(0) { $0 + $1.duration }

        // -----------------------------------------------------------------
        // Adherence
        // -----------------------------------------------------------------

        // `summary` walks all workouts; cheap enough to call here.
        let summary = AnalyticsService.summary(from: allWorkouts)

        // Distinct days *prior to today* in the last 7 with workouts.
        let priorWindowStart = now.addingDays(-7).startOfDay
        let priorDistinctDays = Set(
            allWorkouts
                .filter { $0.id != workout.id }
                .filter { $0.date >= priorWindowStart && $0.date < dayKey }
                .map { $0.date.startOfDay }
        )

        // The most recent prior workout, if any. >=2 day gap => return-after-break.
        let mostRecentPrior = trailing.first
        let isReturnAfterBreak: Bool = {
            guard let prior = mostRecentPrior else { return false }
            let gap = workout.date.timeIntervalSince(prior.date) / 86_400
            return gap >= 2.0
        }()

        let missedThisWeek = max(
            0,
            config.daysPerWeek - (priorDistinctDays.count + 1)
        )

        let adherence = AdherenceSnapshot(
            currentStreakDays: summary.currentStreakDays,
            longestStreakDays: summary.longestStreakDays,
            missedDaysThisWeek: missedThisWeek,
            isReturnAfterBreak: isReturnAfterBreak
        )

        // -----------------------------------------------------------------
        // Await focus enrichment + training load. HR-drift baseline depends
        // on the focus average (so we have something to compare against)
        // and on a lightweight statistics query per baseline workout — no
        // full sample arrays held in memory.
        // -----------------------------------------------------------------

        let enrichment = await focusEnrichment
        let resolvedLoad = await trainingLoad

        let resolvedTrend = await Self.computeHRAtPaceTrend(
            focus: workout,
            focusAvgHR: enrichment.avgHR,
            trailing: trailing,
            healthKit: healthKit
        )

        return CoachContext(
            workout: Self.summarize(workout),
            zones: enrichment.zones,
            avgHR: enrichment.avgHR,
            day: day,
            totalDays: 90,
            phase: phase,
            targetMinutesToday: targetMinutes,
            actualMinutesToday: actualMinutesToday,
            recentWorkouts: trailingSummaries,
            workoutDaysLast7: distinctDaysLast7.count,
            hrAtPaceTrend: resolvedTrend,
            load: resolvedLoad,
            adherence: adherence,
            maxHR: maxHR,
            locale: locale
        )
    }

    // MARK: - Private types

    /// Bundle returned by `fetchFocusEnrichment` so callers don't have to
    /// pattern-match across two optionals.
    private struct FocusEnrichment {
        let zones: ZoneBreakdown?
        let avgHR: Double?

        static let empty = FocusEnrichment(zones: nil, avgHR: nil)
    }

    // MARK: - Private helpers

    /// Project a `WorkoutModel` into the Sendable summary the context carries.
    private static func summarize(_ workout: WorkoutModel) -> CoachContext.WorkoutSummary {
        CoachContext.WorkoutSummary(
            id: workout.id,
            date: workout.date,
            durationMinutes: workout.duration,
            typeName: workout.workoutType?.name,
            isImported: workout.isImported
        )
    }

    /// Load HR samples for the focus workout ONCE, then derive both the
    /// zone breakdown and the average BPM from the same array. Used to
    /// be two parallel branches that each round-tripped to HealthKit
    /// (and each held its own copy of the sample array in memory) — that
    /// doubled peak memory on long workouts and contributed to sheet
    /// evictions on memory-constrained device states.
    private static func fetchFocusEnrichment(
        for workout: WorkoutModel,
        healthKit: HealthKitService,
        maxHR: Double,
        restingHR: Double = 0
    ) async -> FocusEnrichment {
        guard healthKit.isAvailable, let uuid = workout.healthKitUUID,
              let hk = await healthKit.fetchWorkout(uuid: uuid)
        else { return .empty }

        let samples = await healthKit.fetchHeartRateSamples(for: hk)
        guard !samples.isEmpty else { return .empty }

        let breakdown = HeartRateAnalysis.breakdown(
            samples: samples,
            maxHR: maxHR,
            restingHR: restingHR,
            workoutEnd: hk.endDate
        )
        let avg = HeartRateAnalysis.summary(samples)?.avg

        return FocusEnrichment(
            zones: breakdown.totalSeconds > 0 ? breakdown : nil,
            avgHR: avg
        )
    }

    /// CTL today vs CTL 7 days ago, plus ATL today. Computed across a
    /// 90-day window ending at `now` so the EWA has space to ramp.
    /// Zones aren't required — fallback to duration is fine for the
    /// trend math.
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

        // CTL 7 days ago: walk back 7 entries from the end. Series is dense
        // (one entry per day), so this is exact.
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

    /// Compare avg HR on the focus workout vs. avg HR across same-type
    /// workouts in the trailing window. Requires at least 2 prior
    /// comparable workouts to avoid noise; nil otherwise.
    ///
    /// Memory-conscious: `focusAvgHR` is passed in (already computed by
    /// `fetchFocusEnrichment` from the focus workout's HR samples), and
    /// each baseline workout is queried via `fetchAverageHeartRate` —
    /// an `HKStatisticsQuery` that returns just the aggregate without
    /// loading the underlying HR sample array. Earlier this loaded full
    /// `[HRSample]` arrays for up to 5 baseline workouts in addition to
    /// the focus, which on a sheet view rendering 30+ minutes of HR data
    /// + a 1900-point GPS route map could push iOS over its
    /// memory-eviction threshold.
    ///
    /// Baseline cap lowered from 5 to 3: the drift signal is stable with
    /// 3 prior workouts, and older comparisons are noisier anyway because
    /// fitness has shifted.
    private static func computeHRAtPaceTrend(
        focus: WorkoutModel,
        focusAvgHR: Double?,
        trailing: [WorkoutModel],
        healthKit: HealthKitService
    ) async -> HRAtPaceTrend? {
        guard let focusAvg = focusAvgHR, healthKit.isAvailable else { return nil }

        // Same workout type within trailing window, with HK source.
        let typeName = focus.workoutType?.name
        let candidates = trailing.filter { w in
            w.workoutType?.name == typeName && w.healthKitUUID != nil
        }

        var baselineSum: Double = 0
        var baselineCount: Int = 0

        for candidate in candidates {
            guard let uuid = candidate.healthKitUUID,
                  let hk = await healthKit.fetchWorkout(uuid: uuid)
            else { continue }
            // Lightweight aggregate query — no sample array allocated.
            if let avg = await healthKit.fetchAverageHeartRate(for: hk) {
                baselineSum += avg
                baselineCount += 1
            }
            if baselineCount >= 3 { break }
        }

        guard baselineCount >= 2 else { return nil }

        return HRAtPaceTrend(
            recentAvgHR: focusAvg,
            baselineAvgHR: baselineSum / Double(baselineCount),
            baselineSampleCount: baselineCount
        )
    }
}
