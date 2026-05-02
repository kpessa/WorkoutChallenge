//
//  WorkoutWriter.swift
//  WorkoutChallenge Server
//
//  File-writer for HealthKit workouts received via POST /health/workout.
//  Writes three artifacts per workout into the LLM Vault:
//
//      raw/healthkit/workouts/<YYYY-MM-DD>/<hk-uuid>.md       — human-readable summary
//      raw/healthkit/workouts/<YYYY-MM-DD>/<hk-uuid>.json     — full payload, lossless
//      raw/healthkit/workouts/<YYYY-MM-DD>/<hk-uuid>.geojson  — only when route present
//
//  Idempotent on the .md file: if it already exists, the writer skips the
//  re-render (a re-push of the same workout is a safe no-op). The .json and
//  .geojson are rewritten so payload-shape corrections propagate.
//
//  The directory layout uses the workout's *local-calendar* start date so
//  late-night sessions land in the day they belong to. The vault's daily
//  briefing reads these directories per-date.
//

import Foundation
import Vapor

enum WorkoutWriterError: Error, CustomStringConvertible {
    case directoryCreationFailed(path: String, underlying: Error)
    case writeFailed(path: String, underlying: Error)
    case encodingFailed(path: String, underlying: Error)

    var description: String {
        switch self {
        case .directoryCreationFailed(let p, let e): return "Failed to create directory \(p): \(e)"
        case .writeFailed(let p, let e):             return "Failed to write \(p): \(e)"
        case .encodingFailed(let p, let e):          return "Failed to encode \(p): \(e)"
        }
    }
}

enum WorkoutWriteOutcome {
    /// New .md file written (workout was not previously in the vault).
    case wrote(URL)
    /// .md file already existed; only the .json (and .geojson) were re-written.
    case skipped(URL)
}

enum WorkoutWriter {
    /// Persist all artifacts for one workout. Returns the .md outcome.
    /// Side effects: writes .json (always, lossless) and .geojson (when present).
    static func writeWorkout(
        _ payload: WorkoutPayload,
        vaultPath: String,
        ingestedBy: String = "WorkoutChallenge iOS auto-push"
    ) throws -> WorkoutWriteOutcome {
        let dateStr = localDateString(payload.start)
        let dirURL = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent("raw/healthkit/workouts/\(dateStr)")

        do {
            try FileManager.default.createDirectory(at: dirURL,
                                                    withIntermediateDirectories: true)
        } catch {
            throw WorkoutWriterError.directoryCreationFailed(path: dirURL.path,
                                                             underlying: error)
        }

        let mdURL = dirURL.appendingPathComponent("\(payload.hkUUID).md")
        let jsonURL = dirURL.appendingPathComponent("\(payload.hkUUID).json")

        // Always rewrite the JSON sidecar so payload-shape corrections propagate.
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: jsonURL, options: .atomic)
        } catch let e as EncodingError {
            throw WorkoutWriterError.encodingFailed(path: jsonURL.path, underlying: e)
        } catch {
            throw WorkoutWriterError.writeFailed(path: jsonURL.path, underlying: error)
        }

        // Optional GeoJSON sidecar for outdoor workouts with a route.
        if let geoJSON = payload.routeGeoJSON, !geoJSON.isEmpty {
            let geoURL = dirURL.appendingPathComponent("\(payload.hkUUID).geojson")
            do {
                try geoJSON.write(to: geoURL, atomically: true, encoding: .utf8)
            } catch {
                throw WorkoutWriterError.writeFailed(path: geoURL.path, underlying: error)
            }
        }

        // Idempotent on .md — a workout's human-readable summary is fixed once
        // ingested. Don't churn `git diff` on re-pushes of the same UUID.
        if FileManager.default.fileExists(atPath: mdURL.path) {
            return .skipped(mdURL)
        }

        let md = renderMarkdown(payload: payload,
                                ingestedBy: ingestedBy,
                                ingestedAt: Date())
        do {
            try md.write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            throw WorkoutWriterError.writeFailed(path: mdURL.path, underlying: error)
        }
        return .wrote(mdURL)
    }

    // MARK: - Markdown rendering

    /// Render the human-readable .md summary. Frontmatter mirrors structured
    /// fields so the daily-briefing's body section + Workout Library `Last done`
    /// can read without parsing prose.
    private static func renderMarkdown(payload: WorkoutPayload,
                                       ingestedBy: String,
                                       ingestedAt: Date) -> String {
        let display = humanWorkoutName(payload.workoutType)
        let dateStr = localDateString(payload.start)
        let timeStr = localTimeString(payload.start)
        let durationMin = payload.durationSeconds / 60.0
        let durationFmt = String(format: "%.1f", durationMin)

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(display) — \(dateStr) \(timeStr)")
        lines.append("type: workout")
        lines.append("hk_uuid: \(payload.hkUUID)")
        lines.append("hk_workout_type: \(payload.workoutType)")
        lines.append("start: \(isoString(payload.start))")
        lines.append("end: \(isoString(payload.end))")
        lines.append("duration_min: \(durationFmt)")
        if let dist = payload.distanceMeters {
            lines.append("distance_mi: \(String(format: "%.2f", dist / 1609.344))")
            lines.append("distance_km: \(String(format: "%.2f", dist / 1000.0))")
        }
        if let kcal = payload.energyActiveKcal {
            lines.append("active_kcal: \(Int(kcal.rounded()))")
        }
        if let kcal = payload.energyTotalKcal {
            lines.append("total_kcal: \(Int(kcal.rounded()))")
        }
        if let hr = payload.avgHR {
            lines.append("hr_avg_bpm: \(Int(hr.rounded()))")
        }
        if let hr = payload.maxHR {
            lines.append("hr_max_bpm: \(Int(hr.rounded()))")
        }
        if let zones = payload.zones, !zones.isEmpty {
            let pairs = zones.sorted(by: { $0.zone < $1.zone })
                .map { "z\($0.zone): \(Int(($0.secondsInZone / 60.0).rounded()))" }
                .joined(separator: ", ")
            lines.append("hr_zones: { \(pairs) }")
        }
        if let device = payload.device {
            lines.append("device: \(yamlEscape(device))")
        }
        if let source = payload.sourceName {
            lines.append("source: \(yamlEscape(source))")
        }
        lines.append("ingested_at: \(isoString(ingestedAt))")
        lines.append("ingested_by: \(yamlEscape(ingestedBy))")
        lines.append("---")
        lines.append("")

        // ----- Body -----
        lines.append("# \(display) — \(dateStr) \(timeStr)")
        lines.append("")

        // Headline summary one-liner: duration · distance · kcal · HR avg
        var headline: [String] = ["\(durationFmt) min"]
        if let dist = payload.distanceMeters {
            headline.append(String(format: "%.2f mi", dist / 1609.344))
        }
        if let kcal = payload.energyActiveKcal {
            headline.append("\(Int(kcal.rounded())) kcal")
        }
        if let hr = payload.avgHR {
            headline.append("HR \(Int(hr.rounded())) avg")
        }
        if let zones = payload.zones,
           let dominant = zones.max(by: { $0.secondsInZone < $1.secondsInZone }),
           dominant.secondsInZone > 0 {
            headline.append("Z\(dominant.zone) dominant")
        }
        lines.append(headline.joined(separator: " · "))
        lines.append("")

        if let zones = payload.zones, !zones.isEmpty {
            lines.append("## Heart-rate zones")
            for z in zones.sorted(by: { $0.zone < $1.zone }) {
                let mins = Int((z.secondsInZone / 60.0).rounded())
                if mins > 0 {
                    lines.append("- Z\(z.zone): \(mins) min")
                }
            }
            lines.append("")
        }

        if let splits = payload.splits, !splits.isEmpty {
            lines.append("## Splits")
            for s in splits {
                let pace = s.distanceMeters > 0
                    ? "\(String(format: "%.2f", s.distanceMeters / 1609.344)) mi in \(String(format: "%.1f", s.durationSeconds / 60.0)) min"
                    : "\(String(format: "%.1f", s.durationSeconds / 60.0)) min"
                lines.append("- Split \(s.index): \(pace)")
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("")
        lines.append("*Auto-generated by WorkoutChallenge server on receipt of a HealthKit "
                     + "workout. Source of truth is HealthKit on Kurt's iPhone; this mirror "
                     + "exists so the vault can read recent workout state for the daily "
                     + "briefing's body section, BrainSpace Exercise tab, and "
                     + "[[Workout Library]] `Last done` updates.*")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Map HKWorkoutActivityType identifier → human display name. Common cases
    /// get an explicit override; unknown identifiers fall back to a camel-case-
    /// split of the suffix.
    private static func humanWorkoutName(_ raw: String) -> String {
        let overrides: [String: String] = [
            "HKWorkoutActivityTypeSkatingSports":               "Rollerblade",
            "HKWorkoutActivityTypeWalking":                     "Walk",
            "HKWorkoutActivityTypeRunning":                     "Run",
            "HKWorkoutActivityTypeCycling":                     "Cycle",
            "HKWorkoutActivityTypeTennis":                      "Tennis",
            "HKWorkoutActivityTypePickleball":                  "Pickleball",
            "HKWorkoutActivityTypeYoga":                        "Yoga",
            "HKWorkoutActivityTypeFunctionalStrengthTraining":  "Functional Strength",
            "HKWorkoutActivityTypeTraditionalStrengthTraining": "Strength Training",
            "HKWorkoutActivityTypeHiking":                      "Hike",
            "HKWorkoutActivityTypeSwimming":                    "Swim",
            "HKWorkoutActivityTypeOther":                       "Workout",
        ]
        if let display = overrides[raw] { return display }

        let stripped = raw.replacingOccurrences(of: "HKWorkoutActivityType", with: "")
        var result = ""
        for ch in stripped {
            if ch.isUppercase && !result.isEmpty {
                result.append(" ")
            }
            result.append(ch)
        }
        return result.isEmpty ? "Workout" : result
    }

    /// Local-calendar YYYY-MM-DD for the workout's start.
    private static func localDateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }

    /// Local-calendar h:mma (lowercased — `11:24a`) for the workout's start.
    private static func localTimeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "a"
        f.pmSymbol = "p"
        f.timeZone = TimeZone.current
        return f.string(from: d).lowercased()
    }

    /// ISO-8601 with timezone offset (no fractional seconds — keeps frontmatter clean).
    private static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }

    /// Minimal YAML string escaping — wrap in double quotes when the value
    /// contains characters that would change YAML parsing.
    private static func yamlEscape(_ s: String) -> String {
        let needsQuoting = s.contains(":") || s.contains("'") || s.contains("\"")
                        || s.hasPrefix("-") || s.hasPrefix("[") || s.hasPrefix("{")
                        || s.hasPrefix(" ") || s.hasSuffix(" ") || s.contains("#")
        if !needsQuoting { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
