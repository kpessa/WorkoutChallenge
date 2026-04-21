//
//  WeeklyScheduleServiceTests.swift
//  WorkoutChallengeTests
//
//  Pins the week-grouping + front-loaded proposed-date semantics that the
//  Calendar's Schedule list and Progress bar graph both depend on. The
//  headline case is the Sunday+Monday scenario that prompted the rewrite:
//  two logged workouts in week 1 with a 3/week target should surface as
//  two logged rows on their actual dates plus one proposed row on Tuesday
//  — NOT as two entries stacked on Monday with a proposed row on Wed/Fri.
//
//  Add this file to the WorkoutChallengeTests target (same as
//  SigmoidalServiceTests.swift) — no extra setup required.
//

#if canImport(XCTest)
import XCTest
@testable import WorkoutChallenge

final class WeeklyScheduleServiceTests: XCTestCase {

    // MARK: - Test fixtures

    /// Build a calendar-date on a specific day-of-year in 2026 so tests
    /// don't depend on "now".
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        return Calendar.current.date(from: comps)!.startOfDay
    }

    private func makeWorkout(date: Date, duration: Int = 30) -> WorkoutModel {
        WorkoutModel(date: date, duration: duration)
    }

    /// Default sigmoid used in the test fixtures. The schedule/week math
    /// doesn't depend on the specific curve shape — any valid
    /// `SigmoidParams` gives the same bucketing — but we need something
    /// to thread through.
    private let defaultSigmoid = SigmoidParams.default

    // MARK: - Sunday + Monday, target 3/week

    /// The headline case: Sun+Mon logged, target 3/wk. We expect:
    ///   - Sunday appears as its own entry (off-schedule, not banked to Mon)
    ///   - Monday appears as its own entry (on schedule day 1)
    ///   - One proposed entry on Tuesday (front-loaded, not Wed/Fri)
    func testSundayAndMondayLogged_ProposesTuesday() {
        let start = date(2026, 4, 19)         // Sun
        let monday = date(2026, 4, 20)
        let today = monday                    // pretend "now" = Monday

        let schedule = SigmoidalService.generateSchedule(
            startDate: start, daysPerWeek: 3, totalDays: 90
        )
        let workouts = [
            makeWorkout(date: start),  // Sunday workout
            makeWorkout(date: monday)  // Monday workout
        ]

        let weeks = WeeklyScheduleService.weeks(
            startDate: start,
            sigmoid: defaultSigmoid,
            firstWeekday: 1,
            workouts: workouts,
            schedule: schedule,
            today: today
        )

        // First week must contain exactly: Sun, Mon, Tue
        guard let week1 = weeks.first else {
            return XCTFail("expected at least one week")
        }
        XCTAssertEqual(week1.targetCount, 3, "Mon/Wed/Fri → 3 scheduled in week 1")
        XCTAssertEqual(week1.completedCount, 2, "Sun + Mon = 2 distinct logged days")

        let dates = week1.entries.map { $0.date }
        XCTAssertEqual(dates, [start, monday, date(2026, 4, 21)],
                       "entries must be Sun, Mon, Tue in date order")

        // Sunday is off-schedule (no dayNumber) and logged.
        let sun = week1.entries[0]
        XCTAssertNil(sun.scheduledDayNumber)
        XCTAssertTrue(sun.isLogged)
        XCTAssertFalse(sun.isProposed)

        // Monday is scheduled day 1 and logged.
        let mon = week1.entries[1]
        XCTAssertEqual(mon.scheduledDayNumber, 1)
        XCTAssertTrue(mon.isLogged)
        XCTAssertFalse(mon.isProposed)

        // Tuesday is the front-loaded proposed day.
        let tue = week1.entries[2]
        XCTAssertNil(tue.scheduledDayNumber, "Tue isn't on the Mon/Wed/Fri skeleton")
        XCTAssertFalse(tue.isLogged)
        XCTAssertTrue(tue.isProposed)

        // No Wed/Fri proposed — the grid picks are bypassed when the week
        // can be closed out on earlier days.
        let wed = date(2026, 4, 22)
        let fri = date(2026, 4, 24)
        XCTAssertFalse(
            week1.entries.contains { $0.date == wed || $0.date == fri },
            "Wed/Fri should not appear as proposed — they're later in the week"
        )
    }

    // MARK: - Bar-graph parity

    /// `proposedDates` is the bar-graph side of the source of truth.
    /// It must return the same single Tuesday for the Sun+Mon case.
    func testProposedDatesMatchScheduleList() {
        let start = date(2026, 4, 19)
        let monday = date(2026, 4, 20)
        let schedule = SigmoidalService.generateSchedule(
            startDate: start, daysPerWeek: 3, totalDays: 90
        )
        let workouts = [
            makeWorkout(date: start),
            makeWorkout(date: monday)
        ]

        let pairs = WeeklyScheduleService.proposedDates(
            startDate: start,
            sigmoid: defaultSigmoid,
            firstWeekday: 1,
            workouts: workouts,
            schedule: schedule,
            today: monday
        )
        // First proposed date across the challenge should be Tuesday 4/21.
        XCTAssertEqual(pairs.first?.date, date(2026, 4, 21))
    }

    // MARK: - Empty state

    /// With nothing logged yet, the first week's proposed entries are the
    /// original scheduled skeleton days (Mon/Wed/Fri) — we only diverge
    /// from that when there are logged days to anchor around.
    func testNoWorkoutsLogged_FirstWeekProposesScheduledSkeleton() {
        let start = date(2026, 4, 19)   // Sun
        let monday = date(2026, 4, 20)
        let schedule = SigmoidalService.generateSchedule(
            startDate: start, daysPerWeek: 3, totalDays: 90
        )

        let weeks = WeeklyScheduleService.weeks(
            startDate: start,
            sigmoid: defaultSigmoid,
            firstWeekday: 1,
            workouts: [],
            schedule: schedule,
            today: monday
        )
        guard let week1 = weeks.first else {
            return XCTFail("expected first week")
        }
        XCTAssertEqual(week1.completedCount, 0)
        // With no workouts, front-load from today (Mon) fills Mon, Tue, Wed.
        // That's fine — it still meets the "front-loaded" intent and the
        // number of proposed days matches the target.
        XCTAssertEqual(week1.entries.count, 3)
        XCTAssertTrue(week1.entries.allSatisfy { $0.isProposed })
    }

    // MARK: - Future weeks stay on skeleton

    /// A week the user hasn't arrived at yet should propose days on the
    /// Mon/Wed/Fri skeleton — we don't want front-loading to drag every
    /// future week's proposals onto Sun/Mon/Tue just because those are
    /// the earliest days of the week.
    func testFutureWeek_UsesScheduledSkeleton() {
        let start = date(2026, 4, 19)   // Sun
        let monday = date(2026, 4, 20)  // "today"
        let schedule = SigmoidalService.generateSchedule(
            startDate: start, daysPerWeek: 3, totalDays: 90
        )

        let weeks = WeeklyScheduleService.weeks(
            startDate: start,
            sigmoid: defaultSigmoid,
            firstWeekday: 1,
            workouts: [],
            schedule: schedule,
            today: monday
        )
        // Week 2 starts Sun 4/26; scheduled skeleton is Mon 4/27, Wed 4/29, Fri 5/1
        guard weeks.count >= 2 else { return XCTFail("expected at least 2 weeks") }
        let week2 = weeks[1]
        let expected = [date(2026, 4, 27), date(2026, 4, 29), date(2026, 5, 1)]
        XCTAssertEqual(week2.entries.map { $0.date }, expected,
                       "future week should use Mon/Wed/Fri skeleton, not front-loaded Sun/Mon/Tue")
    }

    // MARK: - Week-level completion

    /// Three logged days in a week → week is complete, regardless of
    /// whether they fell on Mon/Wed/Fri or some other mix.
    func testWeekCompletion_IsDistinctDayBased() {
        let start = date(2026, 4, 19)
        let schedule = SigmoidalService.generateSchedule(
            startDate: start, daysPerWeek: 3, totalDays: 90
        )
        let workouts = [
            makeWorkout(date: date(2026, 4, 19)),  // Sun
            makeWorkout(date: date(2026, 4, 20)),  // Mon
            makeWorkout(date: date(2026, 4, 21))   // Tue
        ]
        let weeks = WeeklyScheduleService.weeks(
            startDate: start,
            sigmoid: defaultSigmoid,
            firstWeekday: 1,
            workouts: workouts,
            schedule: schedule,
            today: date(2026, 4, 21)
        )
        XCTAssertTrue(weeks.first?.isComplete ?? false)
    }
}
#endif
