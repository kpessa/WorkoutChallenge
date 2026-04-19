//
//  HealthKitService.swift
//  WorkoutChallenge
//
//  Thin wrapper around HealthKit that:
//    • Requests authorization for reading/writing HKWorkout samples
//    • Saves new workouts to Apple Health when the user logs one in-app
//    • Imports HKWorkouts from Health into the SwiftData store, de-duping
//      by HKWorkout.uuid.
//
//  HealthKit is only available on real iOS devices and the iOS simulator
//  (simulator support is limited). The service no-ops gracefully on
//  unsupported platforms.
//

import Foundation
import Combine
import HealthKit
import SwiftData

@MainActor
final class HealthKitService: ObservableObject {

    // Shared store — HealthKit intends this to be created once per app.
    private let store = HKHealthStore()

    @Published var isAuthorized: Bool = false
    @Published var lastError: String?

    // MARK: - Authorization

    /// Set of types we want to share (write). We currently write only
    /// generic workout samples with a duration.
    private let writeTypes: Set<HKSampleType> = {
        [HKObjectType.workoutType()]
    }()

    /// Set of types we want to read. We read workouts back so we can show
    /// existing Health data inside the app.
    private let readTypes: Set<HKObjectType> = {
        [HKObjectType.workoutType()]
    }()

    /// Returns true if HealthKit is available on this device. HealthKit is
    /// not available on iPad (pre-iPadOS 17) or on Mac Catalyst.
    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() async {
        guard isAvailable else {
            lastError = "HealthKit is not available on this device."
            return
        }

        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            // HealthKit doesn't actually tell us whether the user granted
            // read access — we can only infer from attempted reads. We
            // assume success here and surface errors at call sites.
            isAuthorized = true
        } catch {
            lastError = error.localizedDescription
            isAuthorized = false
        }
    }

    // MARK: - Save

    /// Saves a workout to Apple Health. Returns the HKWorkout.uuid on success
    /// so the caller can persist it and avoid re-importing later.
    @discardableResult
    func saveWorkout(start: Date, durationMinutes: Int) async -> UUID? {
        guard isAvailable else { return nil }

        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        let workout = HKWorkout(
            activityType: .other,
            start: start,
            end: end
        )

        do {
            try await store.save(workout)
            return workout.uuid
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Delete

    /// Deletes a previously-saved HKWorkout by its UUID. Returns true if a
    /// matching sample was found and removed. Used to propagate local edits
    /// and deletes back to Apple Health — HealthKit has no "update", so an
    /// edit is modeled as delete-then-save.
    @discardableResult
    func deleteWorkout(uuid: UUID) async -> Bool {
        guard isAvailable else { return false }

        let predicate = HKQuery.predicateForObject(with: uuid)
        let samples: [HKSample] = await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, results, _ in
                cont.resume(returning: results ?? [])
            }
            store.execute(query)
        }
        guard let sample = samples.first else { return false }

        do {
            try await store.delete(sample)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Import

    /// Pulls workouts from HealthKit between the given dates and inserts any
    /// that aren't already present in the SwiftData store (dedup by uuid).
    func importWorkouts(
        from startDate: Date,
        to endDate: Date = Date(),
        into context: ModelContext
    ) async {
        guard isAvailable else { return }

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: [.strictStartDate]
        )

        let samples: [HKWorkout] = await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                cont.resume(returning: (results as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }

        // Fetch existing HK uuids to dedupe.
        let fetch = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.healthKitUUID != nil }
        )
        let existingUUIDs: Set<UUID> = Set(
            ((try? context.fetch(fetch)) ?? []).compactMap { $0.healthKitUUID }
        )

        for s in samples where !existingUUIDs.contains(s.uuid) {
            let minutes = Int(s.duration / 60.0)
            guard minutes > 0 else { continue }
            let model = WorkoutModel(
                date: s.startDate,
                duration: minutes,
                healthKitUUID: s.uuid
            )
            context.insert(model)
        }
    }
}
