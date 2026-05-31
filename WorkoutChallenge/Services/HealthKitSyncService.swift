//
//  HealthKitSyncService.swift
//  WorkoutChallenge
//
//  Outbound sync of HealthKit data to VaultBridge (~/code/VaultBridge),
//  the consolidated Hummingbird server that absorbed BrainSpace,
//  QueryMessages, and WorkoutChallenge backend code. HK data lands in
//  the LLM Vault at raw/healthkit/. This service is the iOS-side push
//  half — server-side receiving + writing lives in
//  Sources/VaultBridge/Apps/Vault/Routes/HealthKitRoutes.swift.
//
//  Three push paths, manual-trigger only in v1:
//    • verifyServer()           → GET /health, no auth, proves URL is reachable
//    • pushLatestWorkout()      → POST /vault/healthkit/workout for the most recent HKWorkout
//    • backfillAllWorkouts()    → POST /vault/healthkit/backfill for full HK history
//
//  Auto-triggers (HKObserverQuery for new workouts, BGProcessingTask for
//  hourly daily aggregates) come in v2 once the manual flow is verified
//  end-to-end on real devices.
//
//  Configuration:
//    • Server URL  → UserDefaults via VaultSyncConfig.setServerURL(...)
//    • Bearer token → Keychain via VaultSyncKeychain.setToken(...)
//
//  Both come from Settings UI — see VaultSyncSection.swift for the user-
//  facing controls.
//

import Foundation
import Combine
import HealthKit

/// Note on actor isolation: this class deliberately does NOT carry an
/// `@MainActor` annotation at the type level. ObservableObject's
/// `objectWillChange` protocol requirement is nonisolated, and a fully
/// `@MainActor`-isolated class can't satisfy it under strict-concurrency
/// checking. Instead, the public methods that mutate `@Published` state
/// are individually `@MainActor` — same end-user behavior, clean conformance.
final class HealthKitSyncService: ObservableObject {

    // MARK: - Dependencies

    private let healthKit: HealthKitService

    @MainActor
    init(healthKit: HealthKitService) {
        self.healthKit = healthKit
    }

    // MARK: - Observable state

    @Published var isWorking: Bool = false
    @Published var lastError: String?
    @Published var lastSyncAt: Date?
    @Published var backfillProgress: BackfillProgress?

    struct BackfillProgress: Equatable {
        var processed: Int
        var total: Int
        var added: Int
        var skipped: Int
        var failed: Int
        var daysMerged: Int = 0
        var daysFailed: Int = 0
    }

    // MARK: - Server probe

    /// Hits the unauthed `/health` endpoint to verify the URL is reachable
    /// and the server is up. Doesn't validate the token — that comes through
    /// on the first authed call. Returns the server's reported vault path on
    /// success, or throws.
    @MainActor
    @discardableResult
    func verifyServer() async throws -> String {
        guard let baseURL = VaultSyncConfig.serverURL else {
            throw SyncError.notConfigured(reason: "Server URL not set")
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.httpMethod = "GET"
        req.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("No HTTP response")
        }
        guard http.statusCode == 200 else {
            throw SyncError.serverError(status: http.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "")
        }
        // Best-effort decode of the /health body so we can echo the vault path.
        // tokenConfigured is optional — VaultBridge's /health doesn't surface it
        // (the legacy WC server did). When absent we just omit the token line.
        struct HealthzBody: Decodable {
            let ok: Bool
            let service: String
            let vault: String
            let tokenConfigured: Bool?
            enum CodingKeys: String, CodingKey {
                case ok, service, vault
                case tokenConfigured = "token_configured"
            }
        }
        if let body = try? JSONDecoder().decode(HealthzBody.self, from: data) {
            if let tc = body.tokenConfigured {
                return "vault=\(body.vault) token=\(tc ? "set" : "missing")"
            }
            return "vault=\(body.vault)"
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Single workout push

    /// Pushes the most recent HKWorkout to /vault/healthkit/workout. Used by the
    /// "Test push" button in Settings to verify the round-trip works.
    /// Returns the server's response payload string for display.
    @MainActor
    @discardableResult
    func pushLatestWorkout() async throws -> String {
        guard let baseURL = VaultSyncConfig.serverURL else {
            throw SyncError.notConfigured(reason: "Server URL not set")
        }
        guard let token = VaultSyncKeychain.getToken() else {
            throw SyncError.notConfigured(reason: "Bearer token not set")
        }

        isWorking = true
        defer { isWorking = false }

        let workouts = try await fetchAllWorkouts(limit: 1)
        guard let workout = workouts.first else {
            throw SyncError.noData("No HKWorkout samples found")
        }

        let payload = await makeWorkoutPayload(from: workout)
        let endpoint = baseURL.appendingPathComponent("vault/healthkit/workout")
        let response = try await postJSON(payload, to: endpoint, token: token)
        lastSyncAt = Date()
        return String(data: response, encoding: .utf8) ?? ""
    }

    // MARK: - Single workout push by UUID

    /// Pushes a specific HKWorkout, identified by its HK UUID, to
    /// /vault/healthkit/workout. Used by the per-row "Push to vault" action in the
    /// workout log. Returns the server's response payload string for display.
    @MainActor
    @discardableResult
    func pushWorkout(uuid: UUID) async throws -> String {
        guard let baseURL = VaultSyncConfig.serverURL else {
            throw SyncError.notConfigured(reason: "Server URL not set")
        }
        guard let token = VaultSyncKeychain.getToken() else {
            throw SyncError.notConfigured(reason: "Bearer token not set")
        }

        isWorking = true
        defer { isWorking = false }

        guard let workout = try await fetchWorkout(uuid: uuid) else {
            throw SyncError.noData("HKWorkout \(uuid.uuidString) not found")
        }

        let payload = await makeWorkoutPayload(from: workout)
        let endpoint = baseURL.appendingPathComponent("vault/healthkit/workout")
        let response = try await postJSON(payload, to: endpoint, token: token)
        lastSyncAt = Date()
        return String(data: response, encoding: .utf8) ?? ""
    }

    // MARK: - Bulk backfill

    /// Pushes ALL HKWorkouts via /vault/healthkit/backfill. Idempotent on hk_uuid
    /// server-side, so re-runs are safe and cheap (already-seen workouts
    /// short-circuit to "skipped"). Streams progress to backfillProgress.
    @MainActor
    @discardableResult
    func backfillAllWorkouts() async throws -> BackfillProgress {
        guard let baseURL = VaultSyncConfig.serverURL else {
            throw SyncError.notConfigured(reason: "Server URL not set")
        }
        guard let token = VaultSyncKeychain.getToken() else {
            throw SyncError.notConfigured(reason: "Bearer token not set")
        }

        isWorking = true
        defer {
            isWorking = false
            // Keep backfillProgress visible after completion so the UI can show
            // the final tally; reset on next backfill or app launch.
        }

        let workouts = try await fetchAllWorkouts(limit: 0)  // 0 = no limit
        backfillProgress = BackfillProgress(processed: 0, total: workouts.count,
                                            added: 0, skipped: 0, failed: 0)

        let dailySamples = await fetchDailySamples(
            since: Date(timeIntervalSince1970: 0),
            until: Date()
        )

        // Chunk so a single push doesn't dump thousands of workouts into one
        // request body. 100/chunk is conservative; tune up later if fine.
        let chunkSize = 100
        var added = 0
        var skipped = 0
        var failed = 0
        var daysMerged = 0
        var daysFailed = 0

        if workouts.isEmpty, !dailySamples.isEmpty {
            let bulk = BackfillPayloadDTO(workouts: [], days: dailySamples)
            let endpoint = baseURL.appendingPathComponent("vault/healthkit/backfill")
            do {
                let response = try await postJSON(bulk, to: endpoint, token: token)
                if let parsed = try? JSONDecoder().decode(BackfillResponseDTO.self, from: response) {
                    daysMerged += parsed.daysMerged
                    daysFailed += parsed.daysFailed
                }
            } catch {
                daysFailed += dailySamples.count
                lastError = "Daily samples backfill failed: \(error)"
            }
            backfillProgress = BackfillProgress(
                processed: 0,
                total: 0,
                added: 0,
                skipped: 0,
                failed: 0,
                daysMerged: daysMerged,
                daysFailed: daysFailed
            )
        }

        for chunkStart in stride(from: 0, to: workouts.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, workouts.count)
            let chunk = Array(workouts[chunkStart..<chunkEnd])

            // Build payloads in parallel — HR/distance/route enrichment per
            // workout each goes through HK queries. Sequential would be slow
            // on large histories.
            let payloads = await withTaskGroup(of: WorkoutPayloadDTO.self) { group in
                for w in chunk {
                    group.addTask { [weak self] in
                        await self?.makeWorkoutPayload(from: w)
                            ?? WorkoutPayloadDTO.empty(uuid: w.uuid.uuidString)
                    }
                }
                var collected: [WorkoutPayloadDTO] = []
                for await p in group {
                    collected.append(p)
                }
                return collected
            }

            let daysForChunk = chunkStart == 0 ? dailySamples : []
            let bulk = BackfillPayloadDTO(workouts: payloads, days: daysForChunk)
            let endpoint = baseURL.appendingPathComponent("vault/healthkit/backfill")

            do {
                let response = try await postJSON(bulk, to: endpoint, token: token)
                if let parsed = try? JSONDecoder().decode(BackfillResponseDTO.self, from: response) {
                    added += parsed.workoutsAdded
                    skipped += parsed.workoutsSkipped
                    failed += parsed.workoutsFailed
                    daysMerged += parsed.daysMerged
                    daysFailed += parsed.daysFailed
                }
            } catch {
                failed += chunk.count
                daysFailed += daysForChunk.count
                lastError = "Chunk \(chunkStart)-\(chunkEnd) failed: \(error)"
            }

            backfillProgress = BackfillProgress(
                processed: chunkEnd,
                total: workouts.count,
                added: added, skipped: skipped, failed: failed,
                daysMerged: daysMerged, daysFailed: daysFailed
            )
        }

        lastSyncAt = Date()
        return backfillProgress!
    }

    /// Builds the daily HealthKit sample payload that accompanies a full
    /// VaultBridge backfill. Workouts remain the primary sync unit, while
    /// these samples capture slow-moving physiology and scale readings the
    /// app cares about outside individual workouts.
    private func fetchDailySamples(
        since startDate: Date,
        until endDate: Date
    ) async -> [DailySamplesPayloadDTO] {
        async let bodyMass = healthKit.fetchBodyMassSeries(since: startDate, until: endDate)
        async let restingHR = healthKit.fetchRestingHRSeries(since: startDate, until: endDate)
        async let hrv = healthKit.fetchHRVSeries(since: startDate, until: endDate)
        async let vo2 = healthKit.fetchVO2MaxSeries(since: startDate, until: endDate)

        let (massSamples, restingSamples, hrvSamples, vo2Samples) = await (
            bodyMass, restingHR, hrv, vo2
        )

        var grouped: [String: [DailySampleDTO]] = [:]
        func append(kind: String, value: Double, unit: String, start: Date, end: Date? = nil) {
            grouped[Self.dayKey(for: start), default: []].append(
                DailySampleDTO(
                    kind: kind,
                    value: value,
                    unit: unit,
                    start: start,
                    end: end
                )
            )
        }

        for sample in massSamples {
            append(kind: "HKQuantityTypeIdentifierBodyMass", value: sample.value, unit: "kg", start: sample.date)
        }
        for sample in restingSamples {
            append(kind: "HKQuantityTypeIdentifierRestingHeartRate", value: sample.value, unit: "bpm", start: sample.date)
        }
        for sample in hrvSamples {
            append(kind: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", value: sample.value, unit: "ms", start: sample.date)
        }
        for sample in vo2Samples {
            append(kind: "HKQuantityTypeIdentifierVO2Max", value: sample.value, unit: "ml/kg/min", start: sample.date)
        }

        return grouped.keys.sorted().map { day in
            DailySamplesPayloadDTO(
                date: day,
                samples: grouped[day, default: []].sorted { $0.start < $1.start }
            )
        }
    }

    private static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            comps.year ?? 0,
            comps.month ?? 0,
            comps.day ?? 0
        )
    }

    // MARK: - HK → Payload conversion

    /// Convert an HKWorkout to the server's WorkoutPayload shape. Uses the
    /// existing HealthKitService helpers when available; falls back to bare
    /// fields when enrichment queries return empty.
    private func makeWorkoutPayload(from workout: HKWorkout) async -> WorkoutPayloadDTO {
        let hkType = workout.workoutActivityType.serverIdentifier
        let dist = workout.totalDistance?.doubleValue(for: .meter())
        let energyActive = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        let device = workout.device?.name
        let sourceName = workout.sourceRevision.source.name

        // Avg/Max HR pulled from the existing HK service helper. Returns []
        // if the query yields no samples — leave nil in payload then.
        let hrSamples = await healthKit.fetchHeartRateSamples(for: workout)
        let bpms: [Double] = hrSamples.map { $0.bpm }
        let avgHR: Double? = bpms.isEmpty ? nil : bpms.reduce(0, +) / Double(bpms.count)
        let maxHR: Double? = bpms.max()

        return WorkoutPayloadDTO(
            hkUUID: workout.uuid.uuidString,
            workoutType: hkType,
            start: workout.startDate,
            end: workout.endDate,
            durationSeconds: workout.duration,
            distanceMeters: dist,
            energyActiveKcal: energyActive,
            energyTotalKcal: nil,  // HK doesn't always expose total separately
            avgHR: avgHR,
            maxHR: maxHR,
            device: device,
            sourceName: sourceName,
            zones: nil,         // v2 — compute zones from HR samples + max HR
            splits: nil,        // v2 — compute splits from distance samples
            routeGeoJSON: nil,  // v2 — serialize CLLocation samples
            rawMetadata: nil
        )
    }

    /// Fetch a single HKWorkout by its UUID. Returns nil if no sample
    /// matches — the caller decides how to surface that.
    private func fetchWorkout(uuid: UUID) async throws -> HKWorkout? {
        let store = HKHealthStore()
        let predicate = HKQuery.predicateForObject(with: uuid)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HKWorkout?, Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    cont.resume(throwing: SyncError.transport("HK query: \(error)"))
                    return
                }
                cont.resume(returning: (samples as? [HKWorkout])?.first)
            }
            store.execute(query)
        }
    }

    /// Pull HKWorkouts from Health, sorted newest-first. `limit: 0` means no
    /// limit (backfill). Wraps the raw HK query — kept in this service rather
    /// than HealthKitService because it's specific to the sync flow.
    private func fetchAllWorkouts(limit: Int) async throws -> [HKWorkout] {
        let store = HKHealthStore()
        let predicate = HKQuery.predicateForSamples(withStart: nil, end: nil)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKWorkout], Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: limit == 0 ? HKObjectQueryNoLimit : limit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error = error {
                    cont.resume(throwing: SyncError.transport("HK query: \(error)"))
                    return
                }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    // MARK: - HTTP

    /// POST a Codable payload as JSON, returns the response body data.
    /// Throws on non-2xx so callers can surface the actual server message.
    private func postJSON<P: Encodable>(_ payload: P,
                                        to url: URL,
                                        token: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        req.httpBody = try encoder.encode(payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.serverError(status: http.statusCode, body: body)
        }
        return data
    }
}

// MARK: - Errors

enum SyncError: Error, LocalizedError {
    case notConfigured(reason: String)
    case transport(String)
    case serverError(status: Int, body: String)
    case noData(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r):       return "Not configured: \(r)"
        case .transport(let m):           return "Transport: \(m)"
        case .serverError(let s, let b):  return "Server \(s): \(b.prefix(300))"
        case .noData(let m):              return "No data: \(m)"
        }
    }
}

// MARK: - Wire-format DTOs (must match Server/Sources/Server/Models/Payloads.swift)

struct WorkoutPayloadDTO: Codable {
    let hkUUID: String
    let workoutType: String
    let start: Date
    let end: Date
    let durationSeconds: Double

    let distanceMeters: Double?
    let energyActiveKcal: Double?
    let energyTotalKcal: Double?
    let avgHR: Double?
    let maxHR: Double?
    let device: String?
    let sourceName: String?

    let zones: [HRZoneDTO]?
    let splits: [SplitDTO]?
    let routeGeoJSON: String?
    let rawMetadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case start, end, device, zones, splits
        case hkUUID = "hk_uuid"
        case workoutType = "workout_type"
        case durationSeconds = "duration_s"
        case distanceMeters = "distance_m"
        case energyActiveKcal = "energy_active_kcal"
        case energyTotalKcal = "energy_total_kcal"
        case avgHR = "avg_hr"
        case maxHR = "max_hr"
        case sourceName = "source_name"
        case routeGeoJSON = "route_geojson"
        case rawMetadata = "raw_metadata"
    }

    static func empty(uuid: String) -> WorkoutPayloadDTO {
        WorkoutPayloadDTO(
            hkUUID: uuid, workoutType: "HKWorkoutActivityTypeOther",
            start: Date(), end: Date(), durationSeconds: 0,
            distanceMeters: nil, energyActiveKcal: nil, energyTotalKcal: nil,
            avgHR: nil, maxHR: nil, device: nil, sourceName: nil,
            zones: nil, splits: nil, routeGeoJSON: nil, rawMetadata: nil
        )
    }
}

struct HRZoneDTO: Codable {
    let zone: Int
    let secondsInZone: Double
    enum CodingKeys: String, CodingKey {
        case zone
        case secondsInZone = "seconds"
    }
}

struct SplitDTO: Codable {
    let index: Int
    let distanceMeters: Double
    let durationSeconds: Double
    enum CodingKeys: String, CodingKey {
        case index
        case distanceMeters = "distance_m"
        case durationSeconds = "duration_s"
    }
}

struct BackfillPayloadDTO: Codable {
    let workouts: [WorkoutPayloadDTO]
    let days: [DailySamplesPayloadDTO]
}

struct DailySamplesPayloadDTO: Codable {
    let date: String
    let samples: [DailySampleDTO]
}

struct DailySampleDTO: Codable {
    let kind: String
    let value: Double
    let unit: String
    let start: Date
    let end: Date?
}

struct BackfillResponseDTO: Decodable {
    let ok: Bool
    let workoutsAdded: Int
    let workoutsSkipped: Int
    let workoutsFailed: Int
    let daysMerged: Int
    let daysFailed: Int
    let errorsSample: [String]
    enum CodingKeys: String, CodingKey {
        case ok
        case workoutsAdded = "workouts_added"
        case workoutsSkipped = "workouts_skipped"
        case workoutsFailed = "workouts_failed"
        case daysMerged = "days_merged"
        case daysFailed = "days_failed"
        case errorsSample = "errors_sample"
    }
}

// MARK: - HKWorkoutActivityType identifier mapping

extension HKWorkoutActivityType {
    /// Canonical HK identifier string the server's writer expects. Common
    /// cases mapped explicitly; everything else falls back to a synthetic
    /// "HKWorkoutActivityTypeUnknown_<rawValue>" form that the server's
    /// human-name fallback handles gracefully.
    var serverIdentifier: String {
        switch self {
        case .running:                       return "HKWorkoutActivityTypeRunning"
        case .walking:                       return "HKWorkoutActivityTypeWalking"
        case .cycling:                       return "HKWorkoutActivityTypeCycling"
        case .skatingSports:                 return "HKWorkoutActivityTypeSkatingSports"
        case .tennis:                        return "HKWorkoutActivityTypeTennis"
        case .pickleball:                    return "HKWorkoutActivityTypePickleball"
        case .yoga:                          return "HKWorkoutActivityTypeYoga"
        case .functionalStrengthTraining:    return "HKWorkoutActivityTypeFunctionalStrengthTraining"
        case .traditionalStrengthTraining:   return "HKWorkoutActivityTypeTraditionalStrengthTraining"
        case .hiking:                        return "HKWorkoutActivityTypeHiking"
        case .swimming:                      return "HKWorkoutActivityTypeSwimming"
        case .rowing:                        return "HKWorkoutActivityTypeRowing"
        case .elliptical:                    return "HKWorkoutActivityTypeElliptical"
        case .stairs:                        return "HKWorkoutActivityTypeStairs"
        case .stairClimbing:                 return "HKWorkoutActivityTypeStairClimbing"
        case .highIntensityIntervalTraining: return "HKWorkoutActivityTypeHighIntensityIntervalTraining"
        case .coreTraining:                  return "HKWorkoutActivityTypeCoreTraining"
        case .flexibility:                   return "HKWorkoutActivityTypeFlexibility"
        case .mixedCardio:                   return "HKWorkoutActivityTypeMixedCardio"
        case .other:                         return "HKWorkoutActivityTypeOther"
        default:                             return "HKWorkoutActivityTypeUnknown_\(self.rawValue)"
        }
    }
}
