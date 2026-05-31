//
//  HealthKitService.swift
//  WorkoutChallenge
//
//  Thin wrapper around HealthKit that:
//    • Requests authorization for reading/writing HKWorkout samples and
//      reading the supporting data the app renders in the workout detail
//      view (heart rate, active energy, distance, flights climbed, routes,
//      date-of-birth, biological sex).
//    • Saves new workouts to Apple Health when the user logs one in-app.
//    • Imports HKWorkouts from Health into the SwiftData store, de-duping
//      by HKWorkout.uuid.
//    • Fetches per-workout enrichment (HR samples, calories, distance,
//      elevation, route) used by `WorkoutDetailsService`.
//
//  HealthKit is available on real iOS devices, the iOS simulator (with
//  limited fixture data), and on Mac Catalyst / macOS 13+ when the user
//  has enabled Health sync to iCloud. `isHealthDataAvailable()` returns
//  the right thing in all those cases, so the service no-ops gracefully
//  when the host environment can't satisfy it (e.g. a Mac that isn't
//  signed into iCloud Health).
//

import Foundation
import Combine
import CoreLocation
import HealthKit
import SwiftData

@MainActor
final class HealthKitService: ObservableObject {

    // Shared store — HealthKit intends this to be created once per app.
    private let store = HKHealthStore()

    @Published var isAuthorized: Bool = false
    @Published var lastError: String?

    /// True while an import is in flight. Drives spinners on pull-to-refresh
    /// and the Settings "Import from Apple Health" button so concurrent taps
    /// don't fan out into overlapping queries.
    @Published var isImporting: Bool = false

    /// Timestamp of the most recent *successful* import (main-thread read only).
    /// Used by the foreground auto-sync hook to skip re-imports that would
    /// fire within a short window of a previous one (e.g. user backgrounds
    /// the app for 5 seconds and returns).
    @Published var lastImportDate: Date?

    /// UserDefaults key set to `true` the first time the user explicitly taps
    /// "Request access" / "Import from Apple Health" and the system returns
    /// without error. The auto-sync hook uses this as a gate so we never
    /// prompt or probe HealthKit on cold launch for users who haven't opted
    /// in yet. HealthKit itself won't tell us whether read authorization
    /// was granted, so this is the best proxy we have for "user wants the
    /// app to look at their Health data."
    private static let optedInDefaultsKey = "com.kpessa.WorkoutChallenge.healthKitOptedIn"

    /// Whether the user has previously granted (or at least attempted to
    /// grant) HealthKit access via the Settings screen. Persists across app
    /// launches. Read-only from outside the service — updated internally
    /// after a successful `requestAuthorization`.
    var userHasOptedIn: Bool {
        UserDefaults.standard.bool(forKey: Self.optedInDefaultsKey)
    }

    // MARK: - Authorization

    /// Set of types we want to share (write). We currently write only
    /// generic workout samples with a duration.
    private let writeTypes: Set<HKSampleType> = {
        [HKObjectType.workoutType()]
    }()

    /// Set of types we want to read. We read workouts back to display existing
    /// Health data inside the app, heart rate + energy + distance + elevation
    /// + route + characteristics so the workout-detail view can enrich what
    /// we show on top of the bare HKWorkout.
    ///
    /// Note: requesting read access always succeeds silently from the app's
    /// perspective — HealthKit doesn't disclose read denials. If a particular
    /// query returns no data we can't tell "user declined" apart from "no
    /// samples exist". Callers handle empty results as "not available".
    private let readTypes: Set<HKObjectType> = {
        var set: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]
        // Quantity types
        let quantityIDs: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .activeEnergyBurned,
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .flightsClimbed,
            // VO₂Max — Apple auto-computes this from outdoor runs/walks
            // with HR and GPS. Updated every 1–2 weeks; consumed by the
            // Progress tab's Fitness Trend card as the independent
            // aerobic-capacity signal overlaid on CTL.
            .vo2Max,
            // Body mass — needed for smart scales that write weight into
            // Apple Health. VaultBridge can then mirror the daily sample
            // stream into raw/healthkit alongside workouts.
            .bodyMass,
            // Heart-rate variability (SDNN, ms) — recorded mostly by the
            // Watch during sleep/breathe sessions. Used by the Fitness
            // Trend card as a "is physiology changing" recovery signal,
            // distinct from the capacity signal that VO₂Max provides.
            .heartRateVariabilitySDNN,
            // Resting HR — Apple's nightly auto-computed estimate. Drives
            // the HRR/Karvonen zone math so the app's zone classifier
            // matches the Watch's. Updated daily by the Watch.
            .restingHeartRate
        ]
        for id in quantityIDs {
            if let t = HKObjectType.quantityType(forIdentifier: id) {
                set.insert(t)
            }
        }
        // Characteristic types (birthdate/sex). These are read-only on the
        // system side; requesting them lets `dateOfBirthComponents()` +
        // `biologicalSex()` succeed.
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) {
            set.insert(dob)
        }
        if let sex = HKObjectType.characteristicType(forIdentifier: .biologicalSex) {
            set.insert(sex)
        }
        return set
    }()

    /// Returns true if HealthKit is available on this device. Works on
    /// iOS/iPadOS, the iOS simulator, and Mac Catalyst / macOS when the
    /// user has Health sync to iCloud enabled. On a Mac without Health
    /// sync this returns false and the service's public methods become
    /// no-ops — callers already check `isAvailable` / `userHasOptedIn`
    /// before surfacing HK-dependent UI.
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
            // Persist the opt-in signal so the auto-sync hook on subsequent
            // cold launches knows the user has engaged with HK at least once.
            // Idempotent — fine to set repeatedly.
            UserDefaults.standard.set(true, forKey: Self.optedInDefaultsKey)
        } catch {
            lastError = error.localizedDescription
            isAuthorized = false
        }
    }

    // MARK: - Save

    /// Saves a workout to Apple Health. Returns the HKWorkout.uuid on success
    /// so the caller can persist it and avoid re-importing later.
    ///
    /// Uses `HKWorkoutBuilder` (iOS 17+) — `HKWorkout(activityType:start:end:)`
    /// was deprecated in iOS 17.
    @discardableResult
    func saveWorkout(start: Date, durationMinutes: Int) async -> UUID? {
        guard isAvailable else { return nil }

        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        let config = HKWorkoutConfiguration()
        config.activityType = .other

        let builder = HKWorkoutBuilder(
            healthStore: store,
            configuration: config,
            device: nil
        )

        do {
            try await builder.beginCollection(at: start)
            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else {
                return nil
            }
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

    /// Pulls workouts from HealthKit between the given dates and inserts
    /// any that aren't already present in the SwiftData store.
    ///
    /// Dedupe runs in two passes:
    ///   - **Primary:** skip samples whose `uuid` is already attached to
    ///     some row. Cheap and covers the common case.
    ///   - **Secondary (defensive):** for a sample whose uuid is unseen,
    ///     look for an existing row that matches on `(startDate truncated
    ///     to minute, duration)`. When found, adopt the new uuid onto the
    ///     existing row instead of inserting — preserving any workoutType
    ///     tag or local edits the user made. This catches Apple Health's
    ///     habit of emitting a new uuid for a workout that was edited in
    ///     the Health app or finalized late by the Watch, and it also
    ///     reunites locally-logged rows with their Watch-recorded twin.
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

        // Fetch all workouts once so we can do two dedupe passes below
        // (fast primary UUID match + defensive (date, duration) match).
        let allFetch = FetchDescriptor<WorkoutModel>()
        let allWorkouts = (try? context.fetch(allFetch)) ?? []

        // Primary dedupe: by HK uuid. Skips samples we've already imported.
        let existingUUIDs: Set<UUID> = Set(
            allWorkouts.compactMap { $0.healthKitUUID }
        )

        // Secondary-dedupe index by (minute-precision start, duration).
        // Handles two cases where UUID-only dedupe creates a ghost:
        //   1. Apple Health re-emits a workout with a NEW uuid (user edit
        //      in the Health app, delayed Watch finalize, etc.) — without
        //      this check, the next import would create a second row and
        //      the user sees the "un-typed" original reappear alongside
        //      the one they just tagged.
        //   2. User logged a workout locally first (no HK uuid) and the
        //      Watch later posted the same session to Health — attach the
        //      incoming HK uuid to the existing local row rather than
        //      creating a parallel copy.
        //
        // The (minute, duration) tuple is unique enough in practice that
        // false positives (two genuinely distinct workouts starting the
        // same minute with the same duration) are negligible — and the
        // cost of a rare false positive (one row adopts a UUID that
        // matches a very-similar sibling) is still less bad than
        // repeatedly resurrecting duplicate rows.
        struct MatchKey: Hashable { let minute: Date; let minutes: Int }
        var byMatchKey: [MatchKey: WorkoutModel] = [:]
        for w in allWorkouts {
            let key = MatchKey(minute: w.date.truncatedToMinute, minutes: w.duration)
            // First-writer wins — if multiple rows collide, prefer the
            // one already carrying an HK uuid (so a stale duplicate
            // doesn't absorb the incoming uuid ahead of a real row).
            if byMatchKey[key] == nil || byMatchKey[key]?.healthKitUUID == nil {
                byMatchKey[key] = w
            }
        }

        for s in samples {
            let minutes = Int(s.duration / 60.0)
            guard minutes > 0 else { continue }
            if existingUUIDs.contains(s.uuid) { continue }

            // Try to reunite this HK sample with an existing row before
            // creating a new one.
            let key = MatchKey(minute: s.startDate.truncatedToMinute, minutes: minutes)
            if let match = byMatchKey[key] {
                // Adopt the new uuid onto the existing row. If the match
                // already has a (stale) uuid we overwrite it — Apple's
                // latest emission is the authoritative one. Preserve the
                // user's workoutType and any local edits.
                match.healthKitUUID = s.uuid
                if match.hkImportedDate == nil {
                    // First time this row has been associated with HK —
                    // seed the snapshot so revert-to-HK and override
                    // detection work going forward.
                    match.hkImportedDate = s.startDate
                    match.hkImportedDuration = minutes
                }
                continue
            }

            // Genuinely new workout — insert and register it in the
            // match index so subsequent samples in this same batch can
            // also dedupe against it.
            let model = WorkoutModel(
                date: s.startDate,
                duration: minutes,
                healthKitUUID: s.uuid,
                hkImportedDate: s.startDate,
                hkImportedDuration: minutes
            )
            context.insert(model)
            byMatchKey[key] = model

            // Best-effort Reclaim completion sync. Off-schedule dates,
            // past challenges, or missing mappings silently no-op inside
            // the service. We intentionally fire one task per workout
            // rather than batching — simpler to reason about, and a
            // typical import is a handful of rows.
            let importedDate = s.startDate
            Task { @MainActor in
                await ReclaimSyncService.completeTaskForWorkout(
                    date: importedDate,
                    modelContext: context
                )
            }
        }
    }

    // MARK: - Convenience import

    /// Full-funnel import used by the Settings "Import from Apple Health"
    /// button and the foreground auto-sync hook in `RootView`. Wraps the
    /// raw `importWorkouts(from:into:)` with:
    ///
    ///   1. Availability check (HealthKit exists on this device).
    ///   2. Opt-in gate (only runs for users who've previously tapped
    ///      through a `requestAuthorization` call — so cold launch doesn't
    ///      silently probe HK for fresh installs).
    ///   3. Concurrent-import guard (no-ops if an import is already in
    ///      flight — pull-to-refresh + scene-active transition can
    ///      otherwise race).
    ///   4. Optional `minInterval` cooldown to suppress redundant imports
    ///      that fire minutes apart (e.g. user backgrounding for 10s and
    ///      returning). The Settings tap passes nil to force a fresh import
    ///      regardless of cooldown.
    ///   5. Silent re-auth — on cold launch `isAuthorized` is false even
    ///      when the user previously granted access. Calling
    ///      `requestAuthorization` is idempotent and won't re-prompt.
    ///   6. Sets `isImporting` for spinner UIs + records `lastImportDate`
    ///      on completion.
    ///
    /// Returns `true` if an import actually ran; `false` if it was
    /// skipped for any of the reasons above.
    @discardableResult
    func importSinceChallengeStart(
        from startDate: Date,
        into context: ModelContext,
        minInterval: TimeInterval? = nil
    ) async -> Bool {
        guard isAvailable else { return false }
        guard userHasOptedIn else { return false }
        guard !isImporting else { return false }

        if let minInterval,
           let last = lastImportDate,
           Date().timeIntervalSince(last) < minInterval {
            return false
        }

        isImporting = true
        defer { isImporting = false }

        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return false }
        }

        await importWorkouts(from: startDate, into: context)
        lastImportDate = Date()
        return true
    }

    // MARK: - Fetch single workout

    /// Fetch the `HKWorkout` behind a previously-synced `WorkoutModel`.
    /// Returns nil if the sample no longer exists (e.g. the user deleted it
    /// from the Health app) or HealthKit isn't available.
    func fetchWorkout(uuid: UUID) async -> HKWorkout? {
        guard isAvailable else { return nil }
        let predicate = HKQuery.predicateForObject(with: uuid)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, results, _ in
                cont.resume(returning: (results as? [HKWorkout])?.first)
            }
            store.execute(q)
        }
    }

    // MARK: - Per-workout enrichment

    /// One heart-rate sample from within (or adjacent to) a workout window,
    /// flattened to a pure-Swift value so UI code never has to touch HK types.
    struct HRSample: Identifiable, Hashable {
        var id: Date { date }
        let date: Date
        let bpm: Double
    }

    /// Fetch all heart-rate samples within the workout's time range. Returns
    /// an empty array when HR data isn't available — UI should treat empty
    /// as "no chart".
    func fetchHeartRateSamples(for workout: HKWorkout) async -> [HRSample] {
        guard isAvailable,
              let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)
        else { return [] }

        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: [.strictStartDate, .strictEndDate]
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, results, _ in
                cont.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }

        // HR samples are expressed in count/second under the hood; we want
        // BPM which is count/minute.
        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.map { s in
            HRSample(date: s.startDate, bpm: s.quantity.doubleValue(for: unit))
        }
    }

    /// Average heart rate (BPM) across the workout window — computed via
    /// `HKStatisticsQuery` so we never load the full sample array into
    /// memory. Useful when a caller only needs the aggregate (e.g. HR-drift
    /// baseline computation across multiple prior workouts), where loading
    /// thousands of `HRSample` structs would push a sheet over iOS's
    /// memory-eviction threshold.
    ///
    /// Returns nil when there are no HR samples in the workout window.
    func fetchAverageHeartRate(for workout: HKWorkout) async -> Double? {
        guard isAvailable,
              let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)
        else { return nil }

        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: [.strictStartDate, .strictEndDate]
        )

        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(
                quantityType: hrType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                cont.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    /// Active calories (kilocalories) burned during the workout, via the
    /// workout's attached statistics. Returns nil when no energy samples are
    /// associated (manual workouts often lack this).
    func fetchActiveCalories(for workout: HKWorkout) async -> Double? {
        guard isAvailable,
              let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        else { return nil }

        // Prefer the workout's built-in statistics — fast, no extra query.
        if let stats = workout.statistics(for: energyType),
           let quantity = stats.sumQuantity() {
            return quantity.doubleValue(for: .kilocalorie())
        }

        // Fallback: sum loose energy samples inside the workout window.
        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: [.strictStartDate, .strictEndDate]
        )
        let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: energyType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                cont.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        guard !samples.isEmpty else { return nil }
        let total = samples
            .map { $0.quantity.doubleValue(for: .kilocalorie()) }
            .reduce(0, +)
        return total > 0 ? total : nil
    }

    /// Distance covered during the workout, in meters. We try the three
    /// distance identifiers in order (walking/running → cycling → swimming)
    /// and return the first one with data. For HKWorkoutActivityTypes we
    /// don't explicitly enumerate (e.g. rollerblading) the sample's
    /// `distanceWalkingRunning` quantity is typically used.
    func fetchDistanceMeters(for workout: HKWorkout) async -> Double? {
        guard isAvailable else { return nil }

        let candidates: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming
        ]

        for id in candidates {
            guard let type = HKObjectType.quantityType(forIdentifier: id) else { continue }

            if let stats = workout.statistics(for: type),
               let q = stats.sumQuantity() {
                let meters = q.doubleValue(for: .meter())
                if meters > 0 { return meters }
            }

            // Fall through to a fresh query — some third-party writers don't
            // attach distance statistics directly to the workout.
            let predicate = HKQuery.predicateForSamples(
                withStart: workout.startDate,
                end: workout.endDate,
                options: [.strictStartDate, .strictEndDate]
            )
            let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
                let q = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, results, _ in
                    cont.resume(returning: (results as? [HKQuantitySample]) ?? [])
                }
                store.execute(q)
            }
            let meters = samples
                .map { $0.quantity.doubleValue(for: .meter()) }
                .reduce(0, +)
            if meters > 0 { return meters }
        }
        return nil
    }

    /// Total flights climbed during the workout, as a proxy for elevation
    /// gain. A "flight" is ~3m per Apple's definition, so the caller can
    /// multiply by 3 to get an approximate meter value. Returns nil when no
    /// samples exist — manual workouts usually lack elevation data.
    func fetchFlightsClimbed(for workout: HKWorkout) async -> Double? {
        guard isAvailable,
              let flightsType = HKObjectType.quantityType(forIdentifier: .flightsClimbed)
        else { return nil }

        if let stats = workout.statistics(for: flightsType),
           let q = stats.sumQuantity() {
            let flights = q.doubleValue(for: .count())
            return flights > 0 ? flights : nil
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: [.strictStartDate, .strictEndDate]
        )
        let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: flightsType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                cont.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        guard !samples.isEmpty else { return nil }
        let total = samples
            .map { $0.quantity.doubleValue(for: .count()) }
            .reduce(0, +)
        return total > 0 ? total : nil
    }

    /// Fetch the GPS route associated with a workout, flattened to a single
    /// polyline of `CLLocation` points. Returns an empty array when the
    /// workout has no route (manual / stationary workouts) or HealthKit
    /// denies route access.
    func fetchRouteLocations(for workout: HKWorkout) async -> [CLLocation] {
        guard isAvailable else { return [] }

        // Step 1: find route objects owned by this workout.
        let routePredicate = HKQuery.predicateForObjects(from: workout)
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: routePredicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                cont.resume(returning: (results as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(q)
        }
        guard !routes.isEmpty else { return [] }

        // Step 2: for each route, stream out location batches and flatten.
        var locations: [CLLocation] = []
        for route in routes {
            let points: [CLLocation] = await withCheckedContinuation { cont in
                var acc: [CLLocation] = []
                // HKWorkoutRouteQuery delivers batches of locations and
                // finishes with `done == true`.
                let q = HKWorkoutRouteQuery(route: route) { _, batch, done, _ in
                    if let batch { acc.append(contentsOf: batch) }
                    if done { cont.resume(returning: acc) }
                }
                store.execute(q)
            }
            locations.append(contentsOf: points)
        }
        // Sort by timestamp just in case multiple routes/batches arrive out
        // of order (rare but possible).
        return locations.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Observed max HR / characteristics

    /// Highest HR recorded in Apple Health since `since` (defaults to 180
    /// days ago — keeping the window recent biases toward the user's
    /// current fitness). Returns nil when there are no HR samples in range.
    func fetchObservedMaxHR(
        since: Date = Calendar.current.date(byAdding: .day, value: -180, to: Date()) ?? Date.distantPast
    ) async -> Double? {
        guard isAvailable,
              let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)
        else { return nil }

        let predicate = HKQuery.predicateForSamples(
            withStart: since,
            end: Date(),
            options: [.strictStartDate]
        )
        let unit = HKUnit.count().unitDivided(by: .minute())

        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(
                quantityType: hrType,
                quantitySamplePredicate: predicate,
                options: [.discreteMax]
            ) { _, stats, _ in
                let max = stats?.maximumQuantity()?.doubleValue(for: unit)
                cont.resume(returning: max)
            }
            store.execute(q)
        }
    }

    /// Most recent resting-HR reading from Apple Health, in BPM. Apple's
    /// Watch posts a daily auto-computed estimate; we read the latest one
    /// (and its date) so the Settings UI can show "refreshed N days ago"
    /// while the zone math just consumes the BPM. Returns nil if HK isn't
    /// available, isn't authorized, or has never recorded a sample.
    func fetchLatestRestingHR() async -> (bpm: Double, date: Date)? {
        guard isAvailable,
              let type = HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        else { return nil }

        let unit = HKUnit.count().unitDivided(by: .minute())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                guard let sample = (samples as? [HKQuantitySample])?.first else {
                    cont.resume(returning: nil)
                    return
                }
                let bpm = sample.quantity.doubleValue(for: unit)
                cont.resume(returning: (bpm, sample.startDate))
            }
            store.execute(q)
        }
    }

    /// A single VO₂Max sample: date the estimate was recorded and the
    /// value in mL/(kg·min). Apple's Fitness app uses the same unit.
    struct VO2MaxSample: Hashable, Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    /// Fetch VO₂Max samples (mL/(kg·min)) over the given window, ordered
    /// ascending by date. Apple's Watch + iPhone auto-compute VO₂Max
    /// from outdoor runs/walks with HR + motion data and post a new
    /// sample roughly every 1–2 weeks, so even a 90-day window typically
    /// yields a handful of points rather than a dense series.
    ///
    /// Returns an empty array when HealthKit is unavailable, the user
    /// hasn't granted read access, or no samples exist in the window —
    /// callers should degrade gracefully (render CTL-only in that case).
    func fetchVO2MaxSeries(
        since: Date,
        until: Date = Date()
    ) async -> [VO2MaxSample] {
        guard isAvailable,
              let type = HKObjectType.quantityType(forIdentifier: .vo2Max)
        else { return [] }

        let predicate = HKQuery.predicateForSamples(
            withStart: since,
            end: until,
            options: [.strictStartDate]
        )
        // mL/(kg·min) — the literal unit Apple stores vo2Max in.
        let unit = HKUnit(from: "ml/(kg*min)")
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let mapped: [VO2MaxSample] = (samples ?? []).compactMap { s in
                    guard let q = s as? HKQuantitySample else { return nil }
                    return VO2MaxSample(
                        date: q.startDate,
                        value: q.quantity.doubleValue(for: unit)
                    )
                }
                cont.resume(returning: mapped)
            }
            store.execute(q)
        }
    }

    /// A single HRV (SDNN) sample: recording date + value in milliseconds.
    /// Typical healthy-adult SDNN sits in the 20–100 ms range; values drift
    /// with sleep, training load, stress, and age — we use a windowed
    /// delta rather than absolute comparisons.
    struct HRVSample: Hashable, Identifiable {
        let date: Date
        let value: Double   // milliseconds
        var id: Date { date }
    }

    /// Fetch HRV (SDNN) samples over the given window, ordered ascending.
    /// The Watch records these opportunistically (breathe sessions, sleep,
    /// still periods) so density varies by user — some get a sample per
    /// day, others a few per week. Callers should prefer rolling-average
    /// comparisons over raw point-to-point deltas because the raw series
    /// is noisy.
    ///
    /// Returns an empty array when HealthKit is unavailable, the user
    /// hasn't granted read access, or no samples exist in the window —
    /// callers should degrade gracefully (hide the HRV stat entirely).
    func fetchHRVSeries(
        since: Date,
        until: Date = Date()
    ) async -> [HRVSample] {
        guard isAvailable,
              let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        else { return [] }

        let predicate = HKQuery.predicateForSamples(
            withStart: since,
            end: until,
            options: [.strictStartDate]
        )
        // SDNN is stored as a time duration in milliseconds.
        let unit = HKUnit.secondUnit(with: .milli)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let mapped: [HRVSample] = (samples ?? []).compactMap { s in
                    guard let q = s as? HKQuantitySample else { return nil }
                    return HRVSample(
                        date: q.startDate,
                        value: q.quantity.doubleValue(for: unit)
                    )
                }
                cont.resume(returning: mapped)
            }
            store.execute(q)
        }
    }

    /// A single resting-HR sample: the date Apple posted the daily auto-
    /// computed estimate and the BPM value. Apple's Watch posts roughly
    /// one sample per day, so even a 60-day window yields ~60 points —
    /// dense enough to plot a real trend (unlike VO₂Max, which is sparse).
    struct RestingHRSample: Hashable, Identifiable {
        let date: Date
        let value: Double   // BPM
        var id: Date { date }
    }

    /// Fetch resting-HR samples over the given window, ordered ascending.
    /// Used by the Physiology card to plot the long-window adaptation
    /// trend (resting HR drifting down = aerobic engine improving). The
    /// `fetchLatestRestingHR()` helper above is for the single-value
    /// "current resting HR" the zone math needs; this one is for charts.
    ///
    /// Returns an empty array when HealthKit is unavailable, the user
    /// hasn't granted read access, or no samples exist in the window.
    func fetchRestingHRSeries(
        since: Date,
        until: Date = Date()
    ) async -> [RestingHRSample] {
        guard isAvailable,
              let type = HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        else { return [] }

        let predicate = HKQuery.predicateForSamples(
            withStart: since,
            end: until,
            options: [.strictStartDate]
        )
        let unit = HKUnit.count().unitDivided(by: .minute())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let mapped: [RestingHRSample] = (samples ?? []).compactMap { s in
                    guard let q = s as? HKQuantitySample else { return nil }
                    return RestingHRSample(
                        date: q.startDate,
                        value: q.quantity.doubleValue(for: unit)
                    )
                }
                cont.resume(returning: mapped)
            }
            store.execute(q)
        }
    }

    /// A single body-mass sample from Apple Health, normalized to kg.
    /// Smart scales usually write this quantity directly through HealthKit.
    struct BodyMassSample: Hashable, Identifiable {
        let date: Date
        let value: Double   // kilograms
        var id: Date { date }
    }

    /// Fetch body-mass samples over the given window, ordered ascending.
    /// Returns an empty array when no scale/manual weight samples exist or
    /// HealthKit access is unavailable.
    func fetchBodyMassSeries(
        since: Date,
        until: Date = Date()
    ) async -> [BodyMassSample] {
        guard isAvailable,
              let type = HKObjectType.quantityType(forIdentifier: .bodyMass)
        else { return [] }

        let predicate = HKQuery.predicateForSamples(
            withStart: since,
            end: until,
            options: [.strictStartDate]
        )
        let unit = HKUnit.gramUnit(with: .kilo)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let mapped: [BodyMassSample] = (samples ?? []).compactMap { s in
                    guard let q = s as? HKQuantitySample else { return nil }
                    return BodyMassSample(
                        date: q.startDate,
                        value: q.quantity.doubleValue(for: unit)
                    )
                }
                cont.resume(returning: mapped)
            }
            store.execute(q)
        }
    }

    /// Read the user's date-of-birth components from HealthKit. Returns nil
    /// when not set in the Health app or access was denied.
    func fetchBirthdateComponents() -> DateComponents? {
        guard isAvailable else { return nil }
        return try? store.dateOfBirthComponents()
    }

    /// Read the user's biological sex from HealthKit. Returns `.notSet` when
    /// unset or denied. Useful for suggesting Gulati vs. Tanaka/Nes as the
    /// default MHR method.
    func fetchBiologicalSex() -> HKBiologicalSex? {
        guard isAvailable else { return nil }
        return (try? store.biologicalSex().biologicalSex)
    }
}

// MARK: - Debug seeding
//
// The iOS Simulator has its own empty HealthKit store — it does NOT sync
// data from a real iPhone/Watch over iCloud. That means the workout-detail
// UI (HR chart, zones, calories, distance) shows "No heart-rate data" in
// every simulator run, which is painful when iterating on HR visuals.
//
// `seedDebugWorkout` writes a synthetic workout + HR/calorie/distance
// samples straight into the store so the UI can be exercised without a
// physical device. Production builds never see any of this (`#if DEBUG`).
//
// We request write authorization for HR/energy/distance lazily here
// instead of putting them in the always-on `writeTypes` — that way
// release users never get prompted "this app wants to write heart rate
// data to Apple Health", which would be alarming and inaccurate.

#if DEBUG
extension HealthKitService {

    /// Seed the local HealthKit store with a synthetic workout + HR series,
    /// calories, and distance. Returns the seeded `HKWorkout.uuid` on
    /// success (same shape as `saveWorkout`). Intended to be invoked from
    /// a debug-only Settings button.
    ///
    /// Default shape: a 30-minute run that ended 15 minutes ago, with HR
    /// ramping from ~115 → ~170 BPM + small noise, giving visible coverage
    /// across zones Z2 → Z5. Adjustable via parameters.
    @discardableResult
    func seedDebugWorkout(
        endingMinutesAgo: Int = 15,
        durationMinutes: Int = 30,
        hrStartBPM: Double = 115,
        hrEndBPM: Double = 170
    ) async -> UUID? {
        guard isAvailable else {
            lastError = "HealthKit unavailable — can't seed."
            return nil
        }

        // Extra write types needed for the seed. Not in the always-on
        // `writeTypes` because release builds should never request these.
        var debugWriteTypes: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) {
            debugWriteTypes.insert(hr)
        }
        if let e = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            debugWriteTypes.insert(e)
        }
        if let d = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
            debugWriteTypes.insert(d)
        }

        do {
            try await store.requestAuthorization(toShare: debugWriteTypes, read: readTypes)
            isAuthorized = true
        } catch {
            lastError = "Seed auth failed: \(error.localizedDescription)"
            return nil
        }

        let end = Date().addingTimeInterval(-TimeInterval(endingMinutesAgo * 60))
        let start = end.addingTimeInterval(-TimeInterval(durationMinutes * 60))

        let config = HKWorkoutConfiguration()
        config.activityType = .running

        let builder = HKWorkoutBuilder(
            healthStore: store,
            configuration: config,
            device: .local()
        )

        do {
            try await builder.beginCollection(at: start)

            // Heart-rate series: one sample every 10s, ramping linearly
            // from start → end BPM with small +/- 3 BPM noise. That's fine
            // granularity for the chart to look like a real Watch series
            // without being so dense it slows down the UI.
            if let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) {
                let unit = HKUnit.count().unitDivided(by: .minute())
                let step: TimeInterval = 10
                let totalSec = end.timeIntervalSince(start)
                var samples: [HKQuantitySample] = []
                var t: TimeInterval = 0
                while t < totalSec {
                    let progress = t / totalSec
                    let base = hrStartBPM + (hrEndBPM - hrStartBPM) * progress
                    let bpm = base + Double.random(in: -3...3)
                    let sampleStart = start.addingTimeInterval(t)
                    let sampleEnd = sampleStart.addingTimeInterval(1)
                    let q = HKQuantity(unit: unit, doubleValue: bpm)
                    samples.append(
                        HKQuantitySample(
                            type: hrType,
                            quantity: q,
                            start: sampleStart,
                            end: sampleEnd
                        )
                    )
                    t += step
                }
                try await builder.addSamples(samples)
            }

            // Active energy: roughly ~8.5 kcal/min for a moderate run.
            if let eType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
                let kcal = Double(durationMinutes) * 8.5
                let q = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
                try await builder.addSamples([
                    HKQuantitySample(type: eType, quantity: q, start: start, end: end)
                ])
            }

            // Distance: pretend ~10 km/h pace (6 min/km).
            if let dType = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
                let meters = Double(durationMinutes) / 60.0 * 10_000
                let q = HKQuantity(unit: .meter(), doubleValue: meters)
                try await builder.addSamples([
                    HKQuantitySample(type: dType, quantity: q, start: start, end: end)
                ])
            }

            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else { return nil }
            return workout.uuid
        } catch {
            lastError = "Seed failed: \(error.localizedDescription)"
            return nil
        }
    }
}
#endif
