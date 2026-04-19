//
//  Persistence.swift
//  WorkoutChallenge
//
//  Central place to build the SwiftData ModelContainer. We use CloudKit's
//  private database so each user's data stays on their iCloud account and
//  automatically syncs between their devices.
//

import Foundation
import SwiftData

enum Persistence {

    /// Builds the app's ModelContainer. All @Model types the app uses must be
    /// listed in the `schema` array.
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            UserPreferencesModel.self,
            WorkoutTypeModel.self,
            WorkoutModel.self
        ])

        // CloudKit sync to the user's private database. `.automatic` reads the
        // container identifier from the entitlements file, syncs when the
        // iCloud capability is present, and falls back to local-only storage
        // when it isn't (e.g. simulators signed into no iCloud account).
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )

        return try ModelContainer(for: schema, configurations: [config])
    }

    /// In-memory container for SwiftUI previews and unit tests.
    static func makePreviewContainer() throws -> ModelContainer {
        let schema = Schema([
            UserPreferencesModel.self,
            WorkoutTypeModel.self,
            WorkoutModel.self
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }
}
