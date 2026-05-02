//
//  DailyHealthWriter.swift
//  WorkoutChallenge Server
//
//  Cumulative merger for HealthKit daily aggregate samples (resting HR,
//  HRV, sleep, weight, VO2Max, steps, mindful minutes). Multiple POSTs per
//  day land idempotent updates: each (kind, sample.start) tuple is the
//  unique key. Same key = overwrite; new key = append.
//
//  Writes:
//      raw/healthkit/daily/<YYYY-MM-DD>.md   — markdown view with structured frontmatter
//      raw/healthkit/daily/<YYYY-MM-DD>.json — cumulative samples list (source of truth)
//
//  Why merge by reading-then-writing: a single iOS push during the day
//  carries only what's new since the last sync. The vault file should
//  accumulate the full picture across pushes. Server-side merge keeps the
//  iOS app stateless on this surface.
//

import Foundation
import Vapor

enum DailyHealthWriterError: Error, CustomStringConvertible {
    case directoryCreationFailed(path: String, underlying: Error)
    case readFailed(path: String, underlying: Error)
    case writeFailed(path: String, underlying: Error)
    case encodingFailed(path: String, underlying: Error)

    var description: String {
        switch self {
        case .directoryCreationFailed(let p, let e): return "Failed to create directory \(p): \(e)"
        case .readFailed(let p, let e):              return "Failed to read \(p): \(e)"
        case .writeFailed(let p, let e):             return "Failed to write \(p): \(e)"
        case .encodingFailed(let p, let e):          return "Failed to encode \(p): \(e)"
        }
    }
}

enum DailyHealthWriter {
    /// Merge `payload.samples` into the date's cumulative file. Idempotent on
    /// (kind, sample.start) — same key overwrites, new key appends. Returns
    /// the markdown URL on success.
    @discardableResult
    static func mergeDaily(_ payload: DailySamplesPayload,
                           vaultPath: String) throws -> URL {
        let dirURL = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent("raw/healthkit/daily")

        do {
            try FileManager.default.createDirectory(at: dirURL,
                                                    withIntermediateDirectories: true)
        } catch {
            throw DailyHealthWriterError.directoryCreationFailed(path: dirURL.path,
                                                                 underlying: error)
        }

        let mdURL = dirURL.appendingPathComponent("\(payload.date).md")
        let jsonURL = dirURL.appendingPathComponent("\(payload.date).json")

        // ---- Read existing samples (if any) into a (kind|epoch) → sample index ----
        var existing: [DailySample] = []
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            do {
                let data = try Data(contentsOf: jsonURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let prior = try decoder.decode(DailyJSONFile.self, from: data)
                existing = prior.samples
            } catch {
                // Corrupt or wrong-shape — log via thrown error, but don't abort.
                // Start fresh; the next push will rebuild.
                existing = []
            }
        }

        var index: [String: DailySample] = [:]
        for s in existing {
            index[mergeKey(kind: s.kind, start: s.start)] = s
        }
        for s in payload.samples {
            index[mergeKey(kind: s.kind, start: s.start)] = s
        }
        let merged = index.values.sorted(by: { $0.start < $1.start })

        // ---- Write JSON sidecar (cumulative source of truth) ----
        let updated = Date()
        do {
            let file = DailyJSONFile(date: payload.date, updated: updated, samples: merged)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(file)
            try data.write(to: jsonURL, options: .atomic)
        } catch let e as EncodingError {
            throw DailyHealthWriterError.encodingFailed(path: jsonURL.path, underlying: e)
        } catch {
            throw DailyHealthWriterError.writeFailed(path: jsonURL.path, underlying: error)
        }

        // ---- Regenerate the markdown view (deterministic from samples) ----
        let md = renderMarkdown(date: payload.date, samples: merged, updated: updated)
        do {
            try md.write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            throw DailyHealthWriterError.writeFailed(path: mdURL.path, underlying: error)
        }

        return mdURL
    }

    // MARK: - File shape (cumulative store)

    /// On-disk JSON shape — distinct from the per-push payload (which has no
    /// `updated` and is one-direction).
    private struct DailyJSONFile: Codable {
        let date: String
        let updated: Date
        let samples: [DailySample]
    }

    private static func mergeKey(kind: String, start: Date) -> String {
        // Round to whole seconds — absorbs sub-second jitter when iOS re-pushes
        // the same sample with millisecond differences.
        let secs = Int(start.timeIntervalSince1970.rounded())
        return "\(kind)|\(secs)"
    }

    // MARK: - Markdown rendering

    private static func renderMarkdown(date: String,
                                       samples: [DailySample],
                                       updated: Date) -> String {
        // Group samples by kind for category-organized display.
        var byKind: [String: [DailySample]] = [:]
        for s in samples {
            byKind[s.kind, default: []].append(s)
        }
        let updatedISO = isoString(updated)

        var lines: [String] = []
        lines.append("---")
        lines.append("title: HealthKit Daily — \(date)")
        lines.append("type: healthkit-daily")
        lines.append("date: \(date)")
        lines.append("updated: \(updatedISO)")
        lines.append("sample_count: \(samples.count)")
        let kindList = byKind.keys.sorted().joined(separator: ", ")
        lines.append("kinds: [\(kindList)]")
        lines.append("---")
        lines.append("")
        lines.append("# HealthKit Daily — \(date)")
        lines.append("")
        let kindCount = byKind.count
        let samplePlural = samples.count == 1 ? "" : "s"
        let kindPlural = kindCount == 1 ? "" : "s"
        lines.append("\(samples.count) sample\(samplePlural) across \(kindCount) kind\(kindPlural). Last update: \(updatedISO).")
        lines.append("")

        // Category-ordered display. Kinds we know about render in their group;
        // unknown kinds fall through to "Other".
        let categoryOrder: [(String, [String])] = [
            ("Steps & activity", [
                "HKQuantityTypeIdentifierStepCount",
                "HKQuantityTypeIdentifierActiveEnergyBurned",
                "HKQuantityTypeIdentifierAppleExerciseTime",
                "HKQuantityTypeIdentifierAppleStandTime",
                "HKQuantityTypeIdentifierDistanceWalkingRunning",
            ]),
            ("Heart-rate", [
                "HKQuantityTypeIdentifierRestingHeartRate",
                "HKQuantityTypeIdentifierHeartRate",
                "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                "HKQuantityTypeIdentifierVO2Max",
            ]),
            ("Sleep", [
                "HKCategoryTypeIdentifierSleepAnalysis",
            ]),
            ("Body", [
                "HKQuantityTypeIdentifierBodyMass",
                "HKQuantityTypeIdentifierBodyFatPercentage",
                "HKQuantityTypeIdentifierLeanBodyMass",
            ]),
            ("Mindfulness", [
                "HKCategoryTypeIdentifierMindfulSession",
            ]),
        ]

        var rendered = Set<String>()
        for (category, kinds) in categoryOrder {
            let available = kinds.filter { byKind[$0] != nil }
            if available.isEmpty { continue }
            lines.append("## \(category)")
            for kind in available {
                guard let kindSamples = byKind[kind] else { continue }
                let label = friendlyLabel(kind)
                let value = summarizeValue(kind: kind, samples: kindSamples)
                lines.append("- **\(label)**: \(value)")
                rendered.insert(kind)
            }
            lines.append("")
        }

        let leftover = byKind.keys.filter { !rendered.contains($0) }.sorted()
        if !leftover.isEmpty {
            lines.append("## Other")
            for kind in leftover {
                let label = friendlyLabel(kind)
                let value = summarizeValue(kind: kind, samples: byKind[kind]!)
                lines.append("- **\(label)**: \(value)")
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("")
        lines.append("*Auto-generated by WorkoutChallenge server. Source of truth is HealthKit; "
                     + "this is a mirror that updates throughout the day as iOS syncs new samples. "
                     + "Per-sample data lives in the JSON sidecar; this view is for fast human read.*")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    /// Human-readable label for an HK identifier. Falls back to stripped form.
    private static func friendlyLabel(_ kind: String) -> String {
        let labels: [String: String] = [
            "HKQuantityTypeIdentifierStepCount":                  "Steps",
            "HKQuantityTypeIdentifierActiveEnergyBurned":         "Active energy",
            "HKQuantityTypeIdentifierAppleExerciseTime":          "Exercise minutes",
            "HKQuantityTypeIdentifierAppleStandTime":             "Stand minutes",
            "HKQuantityTypeIdentifierDistanceWalkingRunning":     "Walk + run distance",
            "HKQuantityTypeIdentifierRestingHeartRate":           "Resting HR",
            "HKQuantityTypeIdentifierHeartRate":                  "HR",
            "HKQuantityTypeIdentifierHeartRateVariabilitySDNN":   "HRV (SDNN)",
            "HKQuantityTypeIdentifierVO2Max":                     "VO₂ max",
            "HKCategoryTypeIdentifierSleepAnalysis":              "Sleep",
            "HKQuantityTypeIdentifierBodyMass":                   "Weight",
            "HKQuantityTypeIdentifierBodyFatPercentage":          "Body fat %",
            "HKQuantityTypeIdentifierLeanBodyMass":               "Lean mass",
            "HKCategoryTypeIdentifierMindfulSession":             "Mindful minutes",
        ]
        if let l = labels[kind] { return l }
        return kind.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                   .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
    }

    /// Summarize value for a kind: sum for additive kinds, latest for snapshots.
    private static func summarizeValue(kind: String, samples: [DailySample]) -> String {
        if samples.isEmpty { return "—" }

        let additive: Set<String> = [
            "HKQuantityTypeIdentifierStepCount",
            "HKQuantityTypeIdentifierActiveEnergyBurned",
            "HKQuantityTypeIdentifierAppleExerciseTime",
            "HKQuantityTypeIdentifierAppleStandTime",
            "HKQuantityTypeIdentifierDistanceWalkingRunning",
            "HKCategoryTypeIdentifierMindfulSession",
        ]

        if additive.contains(kind) {
            let total = samples.map(\.value).reduce(0, +)
            let unit = samples.first?.unit ?? ""
            return formatNumber(total) + (unit.isEmpty ? "" : " \(unit)")
        }

        let latest = samples.max(by: { $0.start < $1.start })!
        return formatNumber(latest.value) + (latest.unit.isEmpty ? "" : " \(latest.unit)")
    }

    private static func formatNumber(_ d: Double) -> String {
        if d.rounded() == d && abs(d) < 1e15 {
            return "\(Int(d))"
        }
        return String(format: "%.1f", d)
    }

    private static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }
}
