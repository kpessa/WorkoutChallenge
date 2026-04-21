//
//  WeeklyScheduleService.swift
//  WorkoutChallenge
//
//  Shared source of truth for anything that groups the challenge schedule
//  by week. Both the Calendar's Schedule list and the Progress bar graph's
//  dashed "proposed" outlines consume this service so the two views can't
//  drift out of sync.
//
//  Rules baked in here:
//    - Workouts are bucketed by their ACTUAL date. A Sunday workout shows
//      up on Sunday, not banked onto Monday's scheduled slot. (The prior
//      `ScheduleProgressService.credits` logic pushed off-day credit onto
//      the next scheduled slot — we stopped doing that because it made the
//      Schedule list disagree with the bar graph.)
//    - Completion is measured at the WEEK level: a week is "met" when the
//      distinct number of days logged in that week reaches `daysPerWeek`.
//      The 90-day grid's per-slot completeness is derived from its week.
//    - Proposed entries in the current (or future) week are front-loaded:
//      starting from max(today, weekStart), scan day-by-day and take the
//      first `remaining` days that haven't been logged. So if your week
//      needs 3 workouts and you've logged Sun + Mon, the 3rd proposed day
//      is Tue — not Wed or Fri. For past weeks with unmet targets, the
//      proposed entries fall on the original scheduled skeleton days so
//      they read as "missed on the day they were meant to happen".
//

import Foundation

enum WeeklyScheduleService {

    /// One row in a week's entry list. Either a logged day (has workouts)
    /// or a proposed day (target minutes, no workouts).
    struct Entry: Identifiable {
        let date: Date
        let targetMinutes: Int
        let loggedWorkouts: [WorkoutModel]
        let isProposed: Bool
        /// 1..90 day number from the sigmoid skeleton, if this date happens
        /// to line up with a scheduled day. Nil when the date is only on
        /// the list because the user worked out off-schedule (e.g. Sunday
        /// when the schedule picked Mon/Wed/Fri).
        let scheduledDayNumber: Int?

        var id: Date { date }
        var loggedMinutes: Int { loggedWorkouts.reduce(0) { $0 + $1.duration } }
        var isLogged: Bool { !loggedWorkouts.isEmpty }
    }

    struct Week: Identifiable {
        let weekStart: Date
        let weekEnd: Date       // inclusive: weekStart + 6 days
        let targetCount: Int    // scheduled skeleton days landing in this week
        let completedCount: Int // distinct dates in this week with >=1 workout
        let entries: [Entry]    // merged logged + proposed, in date order
        /// 1..90 day numbers of the scheduled skeleton days for this week.
        let scheduledDayNumbers: [Int]

        var isComplete: Bool { targetCount > 0 && completedCount >= targetCount }
        var id: Date { weekStart }
    }

    /// Build the full week-grouped schedule.
    ///
    /// - Parameters:
    ///   - startDate: the active challenge's first day (or prefs start
    ///     between challenges). Used to anchor per-day target minutes.
    ///   - sigmoid: curve parameters used to compute per-day targets.
    ///   - firstWeekday: 1=Sunday, 2=Monday. A display setting that lives
    ///     on prefs and stays stable across challenges.
    ///   - workouts: every logged workout. Rows outside the challenge range
    ///     are ignored; rows on off-schedule days stay on their actual date.
    ///   - schedule: the sigmoid skeleton from
    ///     `SigmoidalService.generateSchedule`. Determines per-week target
    ///     count (partial first/last weeks handled naturally) and the day
    ///     numbers shown in the 90-day grid.
    ///   - today: injectable for tests. Defaults to `Date()`.
    static func weeks(
        startDate: Date,
        sigmoid: SigmoidParams,
        firstWeekday: Int,
        workouts: [WorkoutModel],
        schedule: [ScheduledDay],
        today: Date = Date()
    ) -> [Week] {
        var cal = Calendar.current
        cal.firstWeekday = firstWeekday
        let todayDay = today.startOfDay

        func weekStart(of date: Date) -> Date {
            cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date.startOfDay
        }

        let workoutsByWeek: [Date: [WorkoutModel]] = Dictionary(
            grouping: workouts, by: { weekStart(of: $0.date) }
        )
        let scheduleByWeek: [Date: [ScheduledDay]] = Dictionary(
            grouping: schedule, by: { weekStart(of: $0.date) }
        )

        let weekStarts = Set(scheduleByWeek.keys).union(workoutsByWeek.keys)

        return weekStarts.sorted().map { ws -> Week in
            let we = ws.addingDays(6)
            let scheduledInWeek = (scheduleByWeek[ws] ?? [])
                .sorted { $0.date < $1.date }
            let workoutsInWeek = workoutsByWeek[ws] ?? []

            let targetCount = scheduledInWeek.count

            // Bucket workouts by actual day (preserves Sunday-on-Sunday).
            let workoutsByDay: [Date: [WorkoutModel]] = Dictionary(
                grouping: workoutsInWeek, by: { $0.date.startOfDay }
            )
            let loggedDaySet = Set(workoutsByDay.keys)
            let completedCount = loggedDaySet.count

            let scheduledByDate: [Date: ScheduledDay] = Dictionary(
                uniqueKeysWithValues: scheduledInWeek.map { ($0.date.startOfDay, $0) }
            )

            // Proposed entries — only when we haven't yet hit the week's
            // target. We pick the proposed dates differently depending on
            // where the week sits relative to today:
            //   - Past week, unmet target → keep the original Mon/Wed/Fri
            //     skeleton so missed slots read as "missed on the day they
            //     were meant to happen".
            //   - Current week → front-load remaining to the earliest
            //     still-open day starting from today (so Sun+Mon logged
            //     with target 3 puts the third proposal on Tue, not Wed).
            //   - Future week → keep the skeleton. The user hasn't
            //     arrived at this week yet, so there's no reason to drag
            //     workouts forward to the weekend just because Sun/Mon
            //     are earlier in the calendar.
            let remaining = max(0, targetCount - completedCount)
            var proposedDates: [Date] = []
            if remaining > 0 {
                let isPastWeek = we < todayDay
                let isCurrentWeek = ws <= todayDay && todayDay <= we

                if isCurrentWeek {
                    let firstProposable = max(todayDay, ws)
                    var cursor = firstProposable
                    while cursor <= we, proposedDates.count < remaining {
                        if !loggedDaySet.contains(cursor) {
                            proposedDates.append(cursor)
                        }
                        cursor = cursor.addingDays(1)
                    }
                    // If the remaining days in the week can't fit the
                    // target (e.g. today is Saturday with 3 left), we just
                    // show what fits — no overflow into next week.
                } else if isPastWeek {
                    proposedDates = Array(
                        scheduledInWeek
                            .map { $0.date.startOfDay }
                            .filter { !loggedDaySet.contains($0) }
                            .prefix(remaining)
                    )
                } else {
                    // Future week — use the Mon/Wed/Fri skeleton.
                    proposedDates = Array(
                        scheduledInWeek
                            .map { $0.date.startOfDay }
                            .filter { !loggedDaySet.contains($0) }
                            .prefix(remaining)
                    )
                }
            }

            var entryDates = loggedDaySet
            for d in proposedDates { entryDates.insert(d) }

            let entries: [Entry] = entryDates.sorted().map { date in
                let logged = workoutsByDay[date] ?? []
                let target = SigmoidalService.targetDuration(
                    for: date,
                    startDate: startDate,
                    params: sigmoid
                )
                return Entry(
                    date: date,
                    targetMinutes: Int(target.rounded()),
                    loggedWorkouts: logged,
                    isProposed: logged.isEmpty,
                    scheduledDayNumber: scheduledByDate[date]?.dayNumber
                )
            }

            let dayNumbers = scheduledInWeek.map { $0.dayNumber }.sorted()

            return Week(
                weekStart: ws,
                weekEnd: we,
                targetCount: targetCount,
                completedCount: completedCount,
                entries: entries,
                scheduledDayNumbers: dayNumbers
            )
        }
    }

    /// Flat list of proposed dates (across all weeks) — convenience for
    /// callers that just need the dashed-outline positions, like the bar
    /// graph. Preserves date order.
    static func proposedDates(
        startDate: Date,
        sigmoid: SigmoidParams,
        firstWeekday: Int,
        workouts: [WorkoutModel],
        schedule: [ScheduledDay],
        today: Date = Date()
    ) -> [(date: Date, minutes: Int)] {
        weeks(
            startDate: startDate,
            sigmoid: sigmoid,
            firstWeekday: firstWeekday,
            workouts: workouts,
            schedule: schedule,
            today: today
        )
        .flatMap { $0.entries }
        .filter { $0.isProposed }
        .map { (date: $0.date, minutes: $0.targetMinutes) }
    }

}
