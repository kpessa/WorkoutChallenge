//
//  WorkoutDetailsService.swift
//  WorkoutChallenge
//
//  Pulls together the per-workout enrichment the edit sheet renders: heart
//  rate samples, the zone breakdown, active calories, distance, elevation
//  proxy (flights climbed), and the GPS route.
//
//  Used as a view-scoped `@StateObject` / `@State` in `LogWorkoutSheet`.
//  `load(workout:healthKit:maxHR:)` fans out to HealthKitService and fills
//  in whatever HealthKit actually has — missing fields stay nil so the UI
//  can skip those rows gracefully.
//

import Foundation
import CoreLocation
import HealthKit
import Observation

/// Flattened, UI-ready bundle of everything we know about a single workout
/// beyond its stored duration/type. All fields are optional — HealthKit
/// returns partial data all the time (e.g. manual workouts with no HR
/// samples), so UI code must be prepared to render any subset.
struct WorkoutDetails {
    var hrSamples: [HealthKitService.HRSample] = []
    /// Min / avg / max BPM across `hrSamples`. Nil when there were no samples.
    var hrSummary: (min: Double, avg: Double, max: Double)?
    /// Time-in-zone breakdown built from `hrSamples` and the resolved MHR.
    var zones: ZoneBreakdown = .empty

    var activeKcal: Double?
    var distanceMeters: Double?
    /// Flights climbed (1 flight ≈ 3m). Nil when the workout has no flight
    /// samples. The UI converts to feet/m at render time.
    var flightsClimbed: Double?

    var routeLocations: [CLLocation] = []

    /// Start / end times, carried here so the HR chart has an x-axis domain
    /// even when the HR sample run is shorter than the workout itself.
    var workoutStart: Date
    var workoutEnd: Date

    /// The MHR used to build `zones`. Shown in UI as context ("% of 185 bpm").
    var maxHRUsed: Double

    var hasAny: Bool {
        !hrSamples.isEmpty
            || activeKcal != nil
            || distanceMeters != nil
            || flightsClimbed != nil
            || !routeLocations.isEmpty
    }
}

/// View-scoped async loader. Owns the in-flight task so it can be cancelled
/// if the view disappears, and exposes a single `state` for SwiftUI to
/// observe.
@Observable
@MainActor
final class WorkoutDetailsLoader {

    enum State: Equatable {
        /// No HealthKit UUID or HealthKit unavailable — nothing to load.
        case notAvailable
        case idle
        case loading
        case loaded(WorkoutDetails)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.notAvailable, .notAvailable),
                 (.idle, .idle),
                 (.loading, .loading): return true
            case (.loaded, .loaded): return true // details equality isn't needed
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: State = .idle
    /// `Task.cancel()` is documented thread-safe, and `deinit` on a
    /// `@MainActor` class is nonisolated — so touching `task` from deinit
    /// trips Swift 6's isolation checker. `@ObservationIgnored` opts this
    /// property out of the `@Observable` macro's tracked storage (which
    /// otherwise renders the `nonisolated(unsafe)` marker meaningless on
    /// the macro-expanded backing var, producing a "has no effect" warning).
    @ObservationIgnored
    nonisolated(unsafe) private var task: Task<Void, Never>?

    /// Kick off a load. Safe to call multiple times — a new call cancels
    /// any in-flight work and supersedes it. Callers pass the *resolved*
    /// Max HR so the zone math doesn't pull preferences independently.
    func load(
        workout: WorkoutModel,
        healthKit: HealthKitService,
        maxHR: Double
    ) {
        task?.cancel()

        guard healthKit.isAvailable, let uuid = workout.healthKitUUID else {
            state = .notAvailable
            return
        }

        state = .loading
        let start = workout.date
        let durationSec = TimeInterval(workout.duration * 60)
        let fallbackEnd = start.addingTimeInterval(durationSec)

        task = Task { [weak self] in
            guard let self else { return }

            // Look up the HKWorkout. If it vanished (user deleted it from
            // the Health app), fall back to the locally-stored dates so we
            // can still show loose HR/energy samples in the same window.
            let hk = await healthKit.fetchWorkout(uuid: uuid)
            let workoutStart = hk?.startDate ?? start
            let workoutEnd = hk?.endDate ?? fallbackEnd

            // If we have a live HKWorkout, enrich; otherwise short-circuit
            // to "nothing to show".
            guard let hk else {
                if Task.isCancelled { return }
                self.state = .loaded(WorkoutDetails(
                    workoutStart: workoutStart,
                    workoutEnd: workoutEnd,
                    maxHRUsed: maxHR
                ))
                return
            }

            // Fan out the per-workout queries. These are independent, so
            // issue them concurrently with async let.
            async let hrSamples = healthKit.fetchHeartRateSamples(for: hk)
            async let calories  = healthKit.fetchActiveCalories(for: hk)
            async let distance  = healthKit.fetchDistanceMeters(for: hk)
            async let flights   = healthKit.fetchFlightsClimbed(for: hk)
            async let route     = healthKit.fetchRouteLocations(for: hk)

            let samples = await hrSamples
            let kcal    = await calories
            let dist    = await distance
            let flight  = await flights
            let locs    = await route

            if Task.isCancelled { return }

            let summary = HeartRateAnalysis.summary(samples)
            let zones = HeartRateAnalysis.breakdown(
                samples: samples,
                maxHR: maxHR,
                workoutEnd: workoutEnd
            )

            let details = WorkoutDetails(
                hrSamples: samples,
                hrSummary: summary,
                zones: zones,
                activeKcal: kcal,
                distanceMeters: dist,
                flightsClimbed: flight,
                routeLocations: locs,
                workoutStart: workoutStart,
                workoutEnd: workoutEnd,
                maxHRUsed: maxHR
            )

            self.state = .loaded(details)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
