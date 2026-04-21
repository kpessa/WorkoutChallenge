//
//  WorkoutModel.swift
//  WorkoutChallenge
//
//  A single logged workout entry. Multiple workouts can be logged for a
//  single calendar day; Analytics and the Calendar view aggregate them.
//

import Foundation
import SwiftData

@Model
final class WorkoutModel {
    var id: UUID = UUID()

    /// When the workout occurred (minute precision). For imported-from-
    /// HealthKit rows, this starts as the HK start date but may be
    /// locally overridden by the user. See `hkImportedDate` for the
    /// authoritative HK value at import time.
    var date: Date = Date()

    /// Duration in minutes. Validated >0 at write time. Same dual-role as
    /// `date` for imported rows.
    var duration: Int = 0

    var createdAt: Date = Date()

    /// Optional link back to a user-defined type. Nullified on type delete.
    var workoutType: WorkoutTypeModel?

    /// If this entry originated from HealthKit, store the HKWorkout UUID so
    /// we can avoid duplicate imports on future syncs.
    var healthKitUUID: UUID?

    // MARK: - HealthKit import snapshot
    //
    // When a workout is imported from HealthKit we capture the HK-reported
    // date/duration here. `date`/`duration` remain the "effective" values
    // used everywhere in the app (so analytics, charts, and the calendar
    // don't need to know about the override layer), but these fields let
    // us detect local divergence and offer a "Revert to Apple Health
    // values" action. They stay nil for never-imported workouts.
    //
    // CloudKit-safe: both default to nil, no constraints.

    /// The HKWorkout.startDate at import time.
    var hkImportedDate: Date?

    /// The HKWorkout.duration (minutes, truncated) at import time.
    var hkImportedDuration: Int?

    init(
        id: UUID = UUID(),
        date: Date,
        duration: Int,
        workoutType: WorkoutTypeModel? = nil,
        healthKitUUID: UUID? = nil,
        hkImportedDate: Date? = nil,
        hkImportedDuration: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.duration = duration
        self.workoutType = workoutType
        self.healthKitUUID = healthKitUUID
        self.hkImportedDate = hkImportedDate
        self.hkImportedDuration = hkImportedDuration
        self.createdAt = createdAt
    }

    // MARK: - Derived

    /// True when this row originated from HealthKit. We treat any row with
    /// a stored HK uuid as imported, whether or not it also has the
    /// import-snapshot fields populated (older rows pre-date that field).
    var isImported: Bool { healthKitUUID != nil }

    /// True when the user has locally edited the duration or date of an
    /// imported row so it no longer matches the HK source. Requires the
    /// snapshot fields to be populated — older imported rows that pre-date
    /// the snapshot feature will report false until they're re-imported or
    /// the snapshot is backfilled on first open.
    var hasLocalOverride: Bool {
        guard isImported,
              let snapDate = hkImportedDate,
              let snapDuration = hkImportedDuration
        else { return false }
        return duration != snapDuration || date != snapDate
    }

    /// Copy the effective values into the HK snapshot. Called during import
    /// and as a one-shot backfill when a previously-imported row is opened
    /// for the first time after this field was added — we assume the
    /// current values are still the HK values because older code never
    /// had a chance to diverge without round-tripping through HK.
    func captureHealthKitSnapshot() {
        hkImportedDate = date
        hkImportedDuration = duration
    }
}
