import Vapor

// MARK: - HealthKit workout payloads
//
// These types are placeholders sized to what HK actually exposes. Once the iOS
// export serializer is wired, we lock the wire format by sharing this file as
// a Swift Package source between the Server and iOS targets (or by codegen
// from a single schema). For now they're best-effort and forgiving — every
// numeric field except the UUID, type, start, end, and duration is optional
// so a partial payload still decodes.

struct WorkoutPayload: Content {
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

    let zones: [HRZone]?
    let splits: [Split]?
    /// Inline GeoJSON FeatureCollection of the route, if present. Written as a
    /// .geojson sidecar by the workout writer.
    let routeGeoJSON: String?

    /// Free-form raw HK metadata dict captured by the iOS exporter. Stored
    /// verbatim in the JSON sidecar so we don't lose fields we forgot to model.
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
}

struct HRZone: Content {
    let zone: Int
    let secondsInZone: Double

    enum CodingKeys: String, CodingKey {
        case zone
        case secondsInZone = "seconds"
    }
}

struct Split: Content {
    let index: Int
    let distanceMeters: Double
    let durationSeconds: Double

    enum CodingKeys: String, CodingKey {
        case index
        case distanceMeters = "distance_m"
        case durationSeconds = "duration_s"
    }
}

// MARK: - Daily ambient samples (sleep, resting HR, HRV, weight, VO2Max, steps, mindful minutes)

struct DailySamplesPayload: Content {
    /// Local calendar date, YYYY-MM-DD, of the day this rollup covers.
    let date: String
    let samples: [DailySample]
}

struct DailySample: Content {
    /// HK quantity/category type identifier, e.g. "HKQuantityTypeIdentifierRestingHeartRate".
    let kind: String
    let value: Double
    let unit: String
    let start: Date
    let end: Date?
}

// MARK: - Backfill (one-shot bulk push)

struct BackfillPayload: Content {
    let workouts: [WorkoutPayload]
    let days: [DailySamplesPayload]
}

// MARK: - WorkoutChallenge app-state snapshot

struct SnapshotPayload: Content {
    let asOf: Date
    /// Day index in the 90-day challenge (scheduled-workout index, not calendar offset —
    /// see project_workoutchallenge_day_numbering memory).
    let dayOf90: Int
    let challengeStart: Date?
    /// Opaque JSON blob — schedule and overrides. Server doesn't validate the
    /// shape, just persists it. The vault reader interprets.
    let scheduleJSON: String?
    let overridesJSON: String?

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case dayOf90 = "day_of_90"
        case challengeStart = "challenge_start"
        case scheduleJSON = "schedule_json"
        case overridesJSON = "overrides_json"
    }
}
