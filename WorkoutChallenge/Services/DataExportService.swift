//
//  DataExportService.swift
//  WorkoutChallenge
//
//  Produces a single self-contained JSON document describing everything the
//  app has stored for the user — challenges, workouts, types, preferences,
//  coach feedback, progress insights, Reclaim mappings — plus, for any
//  workout backed by a HealthKit UUID, the per-workout enrichment we'd
//  otherwise show on the detail screen (HR samples, zone breakdown, active
//  calories, distance, flights climbed, GPS route).
//
//  The export is built off a *fresh* read from the SwiftData store on the
//  main actor (so no model contexts cross actor boundaries) and a parallel
//  fan-out of HealthKit queries per imported workout. Total time is bounded
//  by the slowest HK round-trip × number of workouts, which on real devices
//  with a few hundred imported workouts is comfortably under a few seconds.
//
//  Audio files for coach narrations are intentionally NOT included — they
//  live in the Caches directory, would balloon the export, and the
//  CoachFeedbackModel rows reference them by id so a future "import"
//  workflow can regenerate them on demand.
//
//  Output is a top-level JSON object with a stable `schemaVersion` so a
//  future companion importer (or the next app version) can detect format
//  drift cleanly.
//

import Foundation
import CoreLocation
import HealthKit
import SwiftData

@MainActor
enum DataExportService {

    /// Bumped whenever the JSON shape changes in a backward-incompatible
    /// way. Additive fields (new keys) don't require a bump.
    static let schemaVersion = 1

    // MARK: - Entry point

    /// Build the full export and return pretty-printed JSON `Data`.
    ///
    /// The caller (Settings view) writes this to a temp file and presents
    /// it via the iOS share sheet. We don't write the file ourselves so
    /// the service stays pure — easier to unit-test.
    static func produce(
        modelContext: ModelContext,
        healthKit: HealthKitService
    ) async throws -> Data {

        // 1. Read every model collection from SwiftData. Each fetch is
        //    sorted into a stable order so re-running an export produces
        //    a byte-identical file when nothing has changed (helpful for
        //    diffing two exports during debugging).
        let prefs        = try fetchAll(UserPreferencesModel.self, in: modelContext)
        let types        = try fetchAll(WorkoutTypeModel.self, in: modelContext,
                                        sortBy: [SortDescriptor(\.createdAt)])
        let workouts     = try fetchAll(WorkoutModel.self, in: modelContext,
                                        sortBy: [SortDescriptor(\.date), SortDescriptor(\.createdAt)])
        let challenges   = try fetchAll(ChallengeModel.self, in: modelContext,
                                        sortBy: [SortDescriptor(\.createdAt)])
        let coachFeedback   = try fetchAll(CoachFeedbackModel.self, in: modelContext,
                                           sortBy: [SortDescriptor(\.generatedAt)])
        let progressInsights = try fetchAll(ProgressCoachInsightModel.self, in: modelContext,
                                            sortBy: [SortDescriptor(\.dateKey)])
        let reclaimMappings = try fetchAll(ReclaimTaskMappingModel.self, in: modelContext,
                                           sortBy: [SortDescriptor(\.createdAt)])

        // 2. Resolve Max HR + resting HR once, so per-workout zone
        //    breakdowns are consistent with what the app currently shows.
        //    Resting at 0 = unset → zone math falls back to %-of-max
        //    (the historical export behavior).
        let resolvedMaxHR: Double = {
            guard let row = prefs.first else { return 190 }
            return MaxHRService.resolve(preferences: row)
        }()
        let resolvedRestingHR: Double = Double(prefs.first?.restingHRBPM ?? 0)

        // 3. Map workouts to DTOs, fetching HealthKit enrichment for any
        //    row that has a HealthKit UUID. We honor the user's actual HK
        //    authorization state — if HK isn't available or hasn't been
        //    authorized for this app, we emit `healthKit: { available: false }`
        //    on the workout instead of attempting queries that would
        //    silently return empty.
        let hkUsable = healthKit.isAvailable && healthKit.isAuthorized
        var workoutDTOs: [WorkoutDTO] = []
        workoutDTOs.reserveCapacity(workouts.count)
        for w in workouts {
            let typeID = w.workoutType?.id
            let hkBlock: HealthKitBlockDTO?
            if hkUsable, let uuid = w.healthKitUUID {
                hkBlock = await loadHealthKitBlock(
                    workoutUUID: uuid,
                    fallbackStart: w.date,
                    fallbackDurationMinutes: w.duration,
                    healthKit: healthKit,
                    maxHR: resolvedMaxHR,
                    restingHR: resolvedRestingHR
                )
            } else if w.healthKitUUID != nil {
                // HK row exists but the host can't read it right now.
                // Tell the user explicitly so the export documents *why*
                // there's no enrichment, rather than silently omitting.
                hkBlock = HealthKitBlockDTO(
                    available: false,
                    reason: healthKit.isAvailable ? "not_authorized" : "not_available"
                )
            } else {
                hkBlock = nil
            }
            workoutDTOs.append(WorkoutDTO(
                id: w.id,
                date: w.date,
                duration: w.duration,
                createdAt: w.createdAt,
                workoutTypeID: typeID,
                healthKitUUID: w.healthKitUUID,
                hkImportedDate: w.hkImportedDate,
                hkImportedDuration: w.hkImportedDuration,
                isImported: w.isImported,
                hasLocalOverride: w.hasLocalOverride,
                healthKit: hkBlock
            ))
        }

        // 4. Build the top-level bundle.
        let bundle = ExportBundle(
            schemaVersion: schemaVersion,
            exportedAt: Date(),
            app: AppMetaDTO.current(),
            preferences: prefs.map(PreferencesDTO.init),
            challenges: challenges.map(ChallengeDTO.init),
            workoutTypes: types.map(WorkoutTypeDTO.init),
            workouts: workoutDTOs,
            coachFeedback: coachFeedback.map(CoachFeedbackDTO.init),
            progressInsights: progressInsights.map(ProgressInsightDTO.init),
            reclaimMappings: reclaimMappings.map(ReclaimMappingDTO.init)
        )

        // 5. Encode. Pretty-print + sorted keys so the file is greppable
        //    and stable across runs; ISO-8601 dates so consumers don't
        //    have to know a custom epoch convention.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    /// Convenience wrapper: builds the export and writes it to a unique
    /// temp file. Returns the URL the share sheet should hand to UIKit.
    static func writeToTempFile(
        modelContext: ModelContext,
        healthKit: HealthKitService
    ) async throws -> URL {
        let data = try await produce(modelContext: modelContext, healthKit: healthKit)
        let stamp = Self.fileTimestamp(Date())
        let fileName = "WorkoutChallenge-export-\(stamp).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Helpers

    private static func fetchAll<T: PersistentModel>(
        _ type: T.Type,
        in context: ModelContext,
        sortBy descriptors: [SortDescriptor<T>] = []
    ) throws -> [T] {
        let fd = FetchDescriptor<T>(sortBy: descriptors)
        return try context.fetch(fd)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }

    /// Fetch the per-workout HealthKit details, mirroring what
    /// `WorkoutDetailsLoader` does for the detail UI but flattening the
    /// result into a JSON-friendly DTO.
    // The `restingHR` parameter (default 0) preserves the call-site shape
    // for any older callers; new ones pass the resolved resting HR so the
    // exported zone breakdown uses HRR/Karvonen when available.
    private static func loadHealthKitBlock(
        workoutUUID: UUID,
        fallbackStart: Date,
        fallbackDurationMinutes: Int,
        healthKit: HealthKitService,
        maxHR: Double,
        restingHR: Double = 0
    ) async -> HealthKitBlockDTO {

        let hk = await healthKit.fetchWorkout(uuid: workoutUUID)
        guard let hk else {
            // The HKWorkout was deleted from Apple Health since we
            // imported it. Note the gap so the export reflects ground
            // truth instead of pretending we still have details.
            return HealthKitBlockDTO(available: false, reason: "hk_workout_missing")
        }

        let workoutStart = hk.startDate
        let workoutEnd = hk.endDate

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

        let summary = HeartRateAnalysis.summary(samples)
        let zones = HeartRateAnalysis.breakdown(
            samples: samples,
            maxHR: maxHR,
            restingHR: restingHR,
            workoutEnd: workoutEnd
        )

        return HealthKitBlockDTO(
            available: true,
            reason: nil,
            workoutStart: workoutStart,
            workoutEnd: workoutEnd,
            maxHRUsed: maxHR,
            hrSamples: samples.map { HRSampleDTO(date: $0.date, bpm: $0.bpm) },
            hrSummary: summary.map {
                HRSummaryDTO(min: $0.min, avg: $0.avg, max: $0.max)
            },
            zones: ZonesDTO(
                totalSeconds: zones.totalSeconds,
                // JSON object keys must be strings — emit them as the zone
                // index ("1"…"5"). Consumers can re-key to Int if they want.
                secondsByZone: Dictionary(
                    uniqueKeysWithValues: zones.secondsByZone.map { (String($0.key), $0.value) }
                )
            ),
            activeKcal: kcal,
            distanceMeters: dist,
            flightsClimbed: flight,
            route: locs.map(RoutePointDTO.init(location:))
        )
    }
}

// MARK: - DTOs
//
// The on-the-wire shape of the export. Each DTO owns its own Codable
// surface so changes to the backing @Model classes don't accidentally
// rename JSON keys — the DTO is the public contract.
//

private struct ExportBundle: Encodable {
    let schemaVersion: Int
    let exportedAt: Date
    let app: AppMetaDTO
    let preferences: [PreferencesDTO]
    let challenges: [ChallengeDTO]
    let workoutTypes: [WorkoutTypeDTO]
    let workouts: [WorkoutDTO]
    let coachFeedback: [CoachFeedbackDTO]
    let progressInsights: [ProgressInsightDTO]
    let reclaimMappings: [ReclaimMappingDTO]
}

private struct AppMetaDTO: Encodable {
    let name: String
    let platform: String
    let version: String?
    let build: String?

    static func current() -> AppMetaDTO {
        let info = Bundle.main.infoDictionary
        return AppMetaDTO(
            name: "WorkoutChallenge",
            platform: "iOS",
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }
}

private struct PreferencesDTO: Encodable {
    let startDate: Date
    let daysPerWeek: Int
    let firstWeekday: Int
    let sigmoid: SigmoidParams
    let theme: String
    let maxHRMethod: String
    let maxHRAgeOverride: Int
    let maxHRManualBPM: Int
    let observedMaxHRBPM: Int
    let observedMaxHRUpdatedAt: Date?
    let coachVoiceID: String
    let coachVoiceAutoplay: Bool

    init(_ m: UserPreferencesModel) {
        self.startDate = m.startDate
        self.daysPerWeek = m.daysPerWeek
        self.firstWeekday = m.firstWeekday
        self.sigmoid = m.sigmoid
        self.theme = m.themeRaw
        self.maxHRMethod = m.maxHRMethodRaw
        self.maxHRAgeOverride = m.maxHRAgeOverride
        self.maxHRManualBPM = m.maxHRManualBPM
        self.observedMaxHRBPM = m.observedMaxHRBPM
        self.observedMaxHRUpdatedAt = m.observedMaxHRUpdatedAt
        self.coachVoiceID = m.coachVoiceID
        self.coachVoiceAutoplay = m.coachVoiceAutoplay
    }
}

private struct ChallengeDTO: Encodable {
    let id: UUID
    let number: Int
    let startDate: Date
    let daysPerWeek: Int
    let state: String
    let pausedSince: Date?
    let totalPausedSeconds: Double
    let endedAt: Date?
    let createdAt: Date
    let sigmoid: SigmoidParams
    let pledgeSignature: String

    init(_ m: ChallengeModel) {
        self.id = m.id
        self.number = m.number
        self.startDate = m.startDate
        self.daysPerWeek = m.daysPerWeek
        self.state = m.stateRaw
        self.pausedSince = m.pausedSince
        self.totalPausedSeconds = m.totalPausedSeconds
        self.endedAt = m.endedAt
        self.createdAt = m.createdAt
        self.sigmoid = m.sigmoid
        self.pledgeSignature = m.pledgeSignature
    }
}

private struct WorkoutTypeDTO: Encodable {
    let id: UUID
    let name: String
    let colorHex: String
    let createdAt: Date

    init(_ m: WorkoutTypeModel) {
        self.id = m.id
        self.name = m.name
        self.colorHex = m.colorHex
        self.createdAt = m.createdAt
    }
}

private struct WorkoutDTO: Encodable {
    let id: UUID
    let date: Date
    let duration: Int
    let createdAt: Date
    let workoutTypeID: UUID?
    let healthKitUUID: UUID?
    let hkImportedDate: Date?
    let hkImportedDuration: Int?
    let isImported: Bool
    let hasLocalOverride: Bool
    let healthKit: HealthKitBlockDTO?
}

private struct HealthKitBlockDTO: Encodable {
    let available: Bool
    /// When `available == false`, why: e.g. "not_available", "not_authorized",
    /// or "hk_workout_missing" (we have a UUID but Apple Health no longer
    /// has the matching workout). Nil when `available == true`.
    let reason: String?

    let workoutStart: Date?
    let workoutEnd: Date?
    let maxHRUsed: Double?

    let hrSamples: [HRSampleDTO]?
    let hrSummary: HRSummaryDTO?
    let zones: ZonesDTO?

    let activeKcal: Double?
    let distanceMeters: Double?
    let flightsClimbed: Double?
    let route: [RoutePointDTO]?

    /// "Not available" / authorization-blocked init.
    init(available: Bool, reason: String?) {
        self.available = available
        self.reason = reason
        self.workoutStart = nil
        self.workoutEnd = nil
        self.maxHRUsed = nil
        self.hrSamples = nil
        self.hrSummary = nil
        self.zones = nil
        self.activeKcal = nil
        self.distanceMeters = nil
        self.flightsClimbed = nil
        self.route = nil
    }

    /// Full / loaded init.
    init(
        available: Bool,
        reason: String?,
        workoutStart: Date,
        workoutEnd: Date,
        maxHRUsed: Double,
        hrSamples: [HRSampleDTO],
        hrSummary: HRSummaryDTO?,
        zones: ZonesDTO,
        activeKcal: Double?,
        distanceMeters: Double?,
        flightsClimbed: Double?,
        route: [RoutePointDTO]
    ) {
        self.available = available
        self.reason = reason
        self.workoutStart = workoutStart
        self.workoutEnd = workoutEnd
        self.maxHRUsed = maxHRUsed
        self.hrSamples = hrSamples
        self.hrSummary = hrSummary
        self.zones = zones
        self.activeKcal = activeKcal
        self.distanceMeters = distanceMeters
        self.flightsClimbed = flightsClimbed
        self.route = route
    }
}

private struct HRSampleDTO: Encodable {
    let date: Date
    let bpm: Double
}

private struct HRSummaryDTO: Encodable {
    let min: Double
    let avg: Double
    let max: Double
}

private struct ZonesDTO: Encodable {
    let totalSeconds: TimeInterval
    /// Keyed by zone index as a string ("1"..."5"). Each value is seconds
    /// spent in that zone.
    let secondsByZone: [String: TimeInterval]
}

private struct RoutePointDTO: Encodable {
    let date: Date
    let lat: Double
    let lon: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let speed: Double
    let course: Double

    init(location l: CLLocation) {
        self.date = l.timestamp
        self.lat = l.coordinate.latitude
        self.lon = l.coordinate.longitude
        self.altitude = l.altitude
        self.horizontalAccuracy = l.horizontalAccuracy
        self.verticalAccuracy = l.verticalAccuracy
        self.speed = l.speed
        self.course = l.course
    }
}

private struct CoachFeedbackDTO: Encodable {
    let id: UUID
    let workoutID: UUID
    let generatedAt: Date
    let narratorProvider: String
    let voiceProvider: String?
    let voiceID: String?
    let audioGeneratedAt: Date?
    let body: String
    /// The facts the narrator was given, decoded back from the stored JSON
    /// blob so they appear as structured objects in the export rather than
    /// an opaque base64 chunk.
    let facts: [CoachFact]

    init(_ m: CoachFeedbackModel) {
        self.id = m.id
        self.workoutID = m.workoutID
        self.generatedAt = m.generatedAt
        self.narratorProvider = m.narratorProviderRaw
        self.voiceProvider = m.voiceProviderRaw
        self.voiceID = m.voiceID
        self.audioGeneratedAt = m.audioGeneratedAt
        self.body = m.body
        self.facts = (try? JSONDecoder().decode([CoachFact].self, from: m.factsJSON)) ?? []
    }
}

private struct ProgressInsightDTO: Encodable {
    let id: UUID
    let dateKey: Date
    let fingerprint: String
    let generatedAt: Date
    let narratorProvider: String
    let voiceProvider: String?
    let voiceID: String?
    let audioGeneratedAt: Date?
    let body: String
    let facts: [CoachFact]

    init(_ m: ProgressCoachInsightModel) {
        self.id = m.id
        self.dateKey = m.dateKey
        self.fingerprint = m.fingerprint
        self.generatedAt = m.generatedAt
        self.narratorProvider = m.narratorProviderRaw
        self.voiceProvider = m.voiceProviderRaw
        self.voiceID = m.voiceID
        self.audioGeneratedAt = m.audioGeneratedAt
        self.body = m.body
        self.facts = (try? JSONDecoder().decode([CoachFact].self, from: m.factsJSON)) ?? []
    }
}

private struct ReclaimMappingDTO: Encodable {
    let id: UUID
    let challengeID: UUID
    let dayNumber: Int
    let reclaimTaskID: Int
    let lastSyncedMinutes: Int
    let completedAt: Date?
    let createdAt: Date

    init(_ m: ReclaimTaskMappingModel) {
        self.id = m.id
        self.challengeID = m.challengeID
        self.dayNumber = m.dayNumber
        self.reclaimTaskID = m.reclaimTaskID
        self.lastSyncedMinutes = m.lastSyncedMinutes
        self.completedAt = m.completedAt
        self.createdAt = m.createdAt
    }
}
