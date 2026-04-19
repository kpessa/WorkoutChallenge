//
//  SigmoidalServiceTests.swift
//  WorkoutChallengeTests
//
//  Add this file to a new Unit Test Target named "WorkoutChallengeTests".
//  The test target must link against the app module so it can see
//  `SigmoidalService` and `SigmoidParams`.
//

#if canImport(XCTest)
import XCTest
@testable import WorkoutChallenge

final class SigmoidalServiceTests: XCTestCase {

    func testAtMidpointDurationIsHalfway() {
        // At day == midpoint, sigmoid = 0.5, so duration = min + range * 0.5
        let params = SigmoidParams(steepness: 0.1, midpoint: 30, minDuration: 30, maxDuration: 60)
        let value = SigmoidalService.targetDuration(dayIndex: 30, params: params)
        XCTAssertEqual(value, 45.0, accuracy: 0.0001)
    }

    func testWellBeforeMidpointIsNearMin() {
        let params = SigmoidParams(steepness: 0.5, midpoint: 30, minDuration: 30, maxDuration: 60)
        let value = SigmoidalService.targetDuration(dayIndex: 0, params: params)
        XCTAssertLessThan(value, 31.0)
    }

    func testWellAfterMidpointIsNearMax() {
        let params = SigmoidParams(steepness: 0.5, midpoint: 30, minDuration: 30, maxDuration: 60)
        let value = SigmoidalService.targetDuration(dayIndex: 60, params: params)
        XCTAssertGreaterThan(value, 59.0)
    }

    func testScheduleHas90WorkoutsAt3PerWeek() {
        let start = Date()
        let days = SigmoidalService.generateSchedule(startDate: start, daysPerWeek: 3, totalDays: 90)
        XCTAssertEqual(days.count, 90)
        // First entry is a Monday (weekday 1 in our 0-indexed mapping).
        let firstWeekday = Calendar.current.component(.weekday, from: days[0].date) - 1
        XCTAssertEqual(firstWeekday, 1)
    }
}
#endif
