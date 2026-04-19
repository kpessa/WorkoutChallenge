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

    /// When the workout occurred (minute precision).
    var date: Date = Date()

    /// Duration in minutes. Validated >0 at write time.
    var duration: Int = 0

    var createdAt: Date = Date()

    /// Optional link back to a user-defined type. Nullified on type delete.
    var workoutType: WorkoutTypeModel?

    /// If this entry originated from HealthKit, store the HKWorkout UUID so
    /// we can avoid duplicate imports on future syncs.
    var healthKitUUID: UUID?

    init(
        id: UUID = UUID(),
        date: Date,
        duration: Int,
        workoutType: WorkoutTypeModel? = nil,
        healthKitUUID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.duration = duration
        self.workoutType = workoutType
        self.healthKitUUID = healthKitUUID
        self.createdAt = createdAt
    }
}
