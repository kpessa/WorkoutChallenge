//
//  Date+Helpers.swift
//  WorkoutChallenge
//
//  Common date math used across schedule generation, calendar grouping,
//  and analytics.
//

import Foundation

extension Date {
    /// Midnight of `self` in the current calendar/time zone.
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    /// Integer number of days from `self` to `other` at local-day precision.
    /// Negative if `other` is before `self`.
    func daysUntil(_ other: Date) -> Int {
        let a = self.startOfDay
        let b = other.startOfDay
        return Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// Date obtained by adding `days` days to `self`.
    func addingDays(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    /// `self` truncated to the start of the enclosing minute (seconds =
    /// nanoseconds = 0). Used by the HealthKit import dedupe: workouts
    /// stored locally are persisted at minute precision, but HK samples
    /// carry sub-second precision, so a minute-level truncation is the
    /// common grain we compare against.
    var truncatedToMinute: Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: self)
        return cal.date(from: comps) ?? self
    }
}
