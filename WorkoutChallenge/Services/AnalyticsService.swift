//
//  AnalyticsService.swift
//  WorkoutChallenge
//
//  Derived computations over a list of logged workouts. Kept pure so it can
//  be reused by the Progress chart, Analytics tab, and Calendar.
//

import Foundation

struct WeeklyBucket: Identifiable, Hashable {
    var id: Date { weekStart }
    let weekStart: Date
    let totalMinutes: Int
    let workoutCount: Int
}

struct AnalyticsSummary {
    let totalWorkouts: Int
    let totalMinutes: Int
    let averageDuration: Double
    let longestStreakDays: Int
    let currentStreakDays: Int
}

/// One segment of a stacked daily bar: minutes logged on `date` under a single
/// workout type. Multiple segments per date stack into one day's total.
struct DailyTypeBar: Identifiable, Hashable {
    let date: Date
    let typeName: String
    let colorHex: String
    let minutes: Int
    var id: String { "\(date.timeIntervalSince1970)|\(typeName)" }
}

/// A proposed/target duration for a day with no logged workout. Rendered as a
/// dashed outline bar in the progress view.
struct DailyProposed: Identifiable, Hashable {
    let date: Date
    let minutes: Int
    var id: Date { date }
}

struct TypeColor: Hashable {
    let name: String
    let hex: String
}

struct DailyBreakdown {
    let bars: [DailyTypeBar]
    let proposed: [DailyProposed]
    /// Stable-ordered unique type→color pairs for `chartForegroundStyleScale`.
    let colorMapping: [TypeColor]
}

enum AnalyticsService {

    static func summary(from workouts: [WorkoutModel]) -> AnalyticsSummary {
        let count = workouts.count
        let total = workouts.reduce(0) { $0 + $1.duration }
        let avg = count > 0 ? Double(total) / Double(count) : 0

        let dayKeys = Set(workouts.map { $0.date.startOfDay })
        let (longest, current) = streakStats(days: dayKeys)

        return AnalyticsSummary(
            totalWorkouts: count,
            totalMinutes: total,
            averageDuration: avg,
            longestStreakDays: longest,
            currentStreakDays: current
        )
    }

    /// Groups workouts into weeks (Monday-start) and returns totals per week.
    static func weeklyTotals(from workouts: [WorkoutModel]) -> [WeeklyBucket] {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2 // Monday

        let grouped = Dictionary(grouping: workouts) { workout -> Date in
            cal.dateInterval(of: .weekOfYear, for: workout.date)?.start
                ?? workout.date.startOfDay
        }

        return grouped.map { (weekStart, items) in
            WeeklyBucket(
                weekStart: weekStart,
                totalMinutes: items.reduce(0) { $0 + $1.duration },
                workoutCount: items.count
            )
        }
        .sorted { $0.weekStart < $1.weekStart }
    }

    /// Per-day breakdown over `range`, grouped by workout type, with a
    /// proposed-duration entry for any scheduled day that has no logged
    /// workouts. Used by the Progress Bars chart.
    ///
    /// `config` is the resolved active-challenge configuration (or the
    /// prefs fallback between challenges) — see
    /// `ChallengeService.activeConfig(...)`. Pass nil on the very first
    /// launch before prefs/challenge rows exist; in that case the
    /// function returns bars only, no proposed outlines.
    static func dailyBreakdown(
        workouts: [WorkoutModel],
        config: ChallengeService.ActiveConfig?,
        in range: ClosedRange<Date>
    ) -> DailyBreakdown {
        let rangeStart = range.lowerBound.startOfDay
        let rangeEnd = range.upperBound.startOfDay

        struct BucketKey: Hashable { let date: Date; let name: String; let hex: String }
        var buckets: [BucketKey: Int] = [:]
        var dailyTotal: [Date: Int] = [:]

        for w in workouts {
            let day = w.date.startOfDay
            guard day >= rangeStart && day <= rangeEnd else { continue }
            let name = w.workoutType?.name ?? "Unassigned"
            let hex = w.workoutType?.colorHex ?? "#9E9E9E"
            buckets[BucketKey(date: day, name: name, hex: hex), default: 0] += w.duration
            dailyTotal[day, default: 0] += w.duration
        }

        let bars: [DailyTypeBar] = buckets.map { key, minutes in
            DailyTypeBar(date: key.date, typeName: key.name,
                         colorHex: key.hex, minutes: minutes)
        }
        .sorted { ($0.date, $0.typeName) < ($1.date, $1.typeName) }

        var proposed: [DailyProposed] = []
        if let config {
            // Route through `WeeklyScheduleService` so the dashed outlines
            // on the bar graph match the proposed rows in the Calendar's
            // Schedule list. Both views now front-load remaining workouts
            // to the earliest still-open day in the week (e.g. if Sun + Mon
            // are logged and the week target is 3, the 3rd proposed day is
            // Tue — not Wed or Fri).
            let schedule = SigmoidalService.generateSchedule(
                startDate: config.startDate,
                daysPerWeek: config.daysPerWeek,
                totalDays: 200
            )
            let proposedPairs = WeeklyScheduleService.proposedDates(
                startDate: config.startDate,
                sigmoid: config.sigmoid,
                firstWeekday: config.firstWeekday,
                workouts: workouts,
                schedule: schedule
            )
            for p in proposedPairs {
                let d = p.date.startOfDay
                guard d >= rangeStart && d <= rangeEnd else { continue }
                proposed.append(DailyProposed(date: d, minutes: p.minutes))
            }
        }

        var seen = Set<String>()
        var mapping: [TypeColor] = []
        for bar in bars where !seen.contains(bar.typeName) {
            seen.insert(bar.typeName)
            mapping.append(TypeColor(name: bar.typeName, hex: bar.colorHex))
        }

        return DailyBreakdown(bars: bars, proposed: proposed, colorMapping: mapping)
    }

    /// Returns (longestStreak, currentStreak) measured in consecutive days
    /// that contain at least one workout.
    private static func streakStats(days: Set<Date>) -> (Int, Int) {
        guard !days.isEmpty else { return (0, 0) }

        let sorted = days.sorted()
        var longest = 1
        var run = 1
        for i in 1..<sorted.count {
            if sorted[i - 1].addingDays(1) == sorted[i] {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }

        // Current streak: count back from today.
        var current = 0
        var cursor = Date().startOfDay
        while days.contains(cursor) {
            current += 1
            cursor = cursor.addingDays(-1)
        }
        return (longest, current)
    }
}
