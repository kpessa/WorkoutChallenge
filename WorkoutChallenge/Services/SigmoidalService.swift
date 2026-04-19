//
//  SigmoidalService.swift
//  WorkoutChallenge
//
//  Port of src/lib/utils/sigmoidal.ts. Pure functions — no side effects —
//  which makes them easy to unit-test.
//

import Foundation

enum SigmoidalService {

    /// Target workout duration (in minutes) for `date`, given a challenge
    /// starting on `startDate` and the user's sigmoid parameters.
    ///
    /// Formula (same as the web version):
    ///   duration = min + (max - min) / (1 + exp(-steepness * (dayIndex - midpoint)))
    static func targetDuration(
        for date: Date,
        startDate: Date,
        params: SigmoidParams
    ) -> Double {
        let dayIndex = Double(startDate.daysUntil(date))
        let exponent = -params.steepness * (dayIndex - params.midpoint)
        let range = params.maxDuration - params.minDuration
        return params.minDuration + range / (1.0 + exp(exponent))
    }

    /// Convenience variant when you already know the day index (day 0 = start).
    static func targetDuration(
        dayIndex: Int,
        params: SigmoidParams
    ) -> Double {
        let d = Double(dayIndex)
        let exponent = -params.steepness * (d - params.midpoint)
        let range = params.maxDuration - params.minDuration
        return params.minDuration + range / (1.0 + exp(exponent))
    }

    /// Generates an array of `totalDays` scheduled workout dates starting at
    /// `startDate`. This mirrors the web helper `generateWorkoutSchedule`,
    /// but uses the user's `daysPerWeek` preference to spread workouts more
    /// evenly across the week instead of hard-coding weekdays-only.
    static func generateSchedule(
        startDate: Date,
        daysPerWeek: Int,
        totalDays: Int = 90
    ) -> [ScheduledDay] {
        guard daysPerWeek > 0 else { return [] }

        // Pick `daysPerWeek` evenly-spaced weekdays (0 = Sunday).
        // e.g. 3/week -> [Mon, Wed, Fri]; 4/week -> [Mon, Tue, Thu, Fri].
        let pickedWeekdays = Self.pickWeekdays(count: daysPerWeek)

        var result: [ScheduledDay] = []
        var cursor = startDate.startOfDay
        var workoutCount = 0

        while workoutCount < totalDays {
            let weekday = Calendar.current.component(.weekday, from: cursor) - 1
            if pickedWeekdays.contains(weekday) {
                result.append(
                    ScheduledDay(date: cursor, dayNumber: workoutCount + 1)
                )
                workoutCount += 1
            }
            cursor = cursor.addingDays(1)

            // Safety stop: at worst we advance one day at a time; 90 workouts
            // at 1/week would be ~630 days. Cap at 2 years to avoid runaway.
            if cursor.daysUntil(startDate) < -(365 * 2) { break }
        }
        return result
    }

    /// Picks `count` evenly-spaced weekday indexes (1=Mon ... 5=Fri),
    /// extending into the weekend only when count > 5.
    private static func pickWeekdays(count: Int) -> Set<Int> {
        let order = [1, 3, 5, 2, 4, 6, 0] // Mon, Wed, Fri, Tue, Thu, Sat, Sun
        return Set(order.prefix(count))
    }
}

/// One planned day in the 90-day schedule.
struct ScheduledDay: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let dayNumber: Int  // 1-indexed (day 1..90)
}
