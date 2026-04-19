//
//  WorkoutTypeModel.swift
//  WorkoutChallenge
//
//  User-defined categories for workouts (e.g. "Running", "Weights").
//  Each type has a display name and a color used in the UI and charts.
//

import Foundation
import SwiftData
import SwiftUI

@Model
final class WorkoutTypeModel {
    /// Stable identifier used for relationship-free references.
    var id: UUID = UUID()

    var name: String = "Exercise"

    /// Hex color like "#4CAF50". Stored as string for Codable/CloudKit.
    var colorHex: String = "#4CAF50"

    var createdAt: Date = Date()

    /// Inverse relationship — all workouts logged under this type.
    @Relationship(deleteRule: .nullify, inverse: \WorkoutModel.workoutType)
    var workouts: [WorkoutModel]? = []

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
}

// MARK: - Color helpers

extension WorkoutTypeModel {
    /// SwiftUI Color computed from the stored hex string.
    var color: Color {
        Color(hex: colorHex) ?? .green
    }
}
