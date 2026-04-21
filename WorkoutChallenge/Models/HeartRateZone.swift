//
//  HeartRateZone.swift
//  WorkoutChallenge
//
//  Standard 5-zone model keyed off percent of max heart rate (MHR). The
//  exact boundaries vary across coaches (e.g. Joe Friel's zones, Karvonen
//  HR-reserve zones) — we use the simple %-of-max convention because it
//  matches what the Apple Watch + Fitness app show and because we don't
//  reliably know resting HR.
//
//  Zones are ordered by intensity; boundaries are inclusive on the low end
//  and exclusive on the high end (so 150 bpm at MHR 200 → 75% → Zone 3).
//  The top of Zone 5 is open (> 90% → Zone 5) so spikes above MHR still
//  count.
//

import Foundation
import SwiftUI

struct HeartRateZone: Identifiable, Hashable {
    let index: Int            // 1...5
    let name: String          // "Recovery", "Endurance", …
    let minPercent: Double    // 0.5 = 50% of MHR
    let maxPercent: Double    // upper bound, exclusive except for zone 5
    let color: Color          // plot + bar fill
    var id: Int { index }

    /// Zone 1 — very easy, active recovery.
    static let z1 = HeartRateZone(
        index: 1, name: "Recovery",
        minPercent: 0.50, maxPercent: 0.60,
        color: .textTertiary
    )
    /// Zone 2 — aerobic base, conversational pace.
    static let z2 = HeartRateZone(
        index: 2, name: "Endurance",
        minPercent: 0.60, maxPercent: 0.70,
        color: .accentNeon
    )
    /// Zone 3 — tempo / "comfortably hard".
    static let z3 = HeartRateZone(
        index: 3, name: "Tempo",
        minPercent: 0.70, maxPercent: 0.80,
        color: .accentVolt
    )
    /// Zone 4 — lactate threshold, hard.
    static let z4 = HeartRateZone(
        index: 4, name: "Threshold",
        minPercent: 0.80, maxPercent: 0.90,
        color: .warn
    )
    /// Zone 5 — VO₂ max / maximal effort. Open-ended up top.
    static let z5 = HeartRateZone(
        index: 5, name: "VO₂ Max",
        minPercent: 0.90, maxPercent: 1.20,
        color: .danger
    )

    static let standard: [HeartRateZone] = [.z1, .z2, .z3, .z4, .z5]

    /// Pick the zone a specific BPM value falls into given a user's MHR.
    /// Values below Zone 1's floor are reported as Zone 1 (rather than a
    /// sixth "below recovery" bucket) so the breakdown bars always add to
    /// 100% when HR data exists.
    static func zone(for bpm: Double, maxHR: Double) -> HeartRateZone {
        guard maxHR > 0 else { return .z1 }
        let pct = bpm / maxHR
        // Walk zones descending so the open-ended top of Z5 is evaluated
        // first (any bpm at or above 90% of MHR is Z5).
        for z in standard.reversed() {
            if pct >= z.minPercent { return z }
        }
        return .z1
    }

    /// Range in BPM for this zone given a user's MHR. Useful for labels.
    func bpmRange(maxHR: Double) -> ClosedRange<Int> {
        let lo = Int((minPercent * maxHR).rounded())
        let hi = Int((maxPercent * maxHR).rounded())
        return lo...hi
    }

    /// Localized, user-facing version of `name`. The stored `name` is the
    /// canonical English string (also the key into `Localizable.xcstrings`);
    /// this resolves it through the current locale so UI reads correctly in
    /// Spanish / other languages. Use this instead of `.name` in any `Text`
    /// that the user will see.
    var localizedName: String {
        switch index {
        case 1: return String(localized: "Recovery", comment: "HR Zone 1 name")
        case 2: return String(localized: "Endurance", comment: "HR Zone 2 name")
        case 3: return String(localized: "Tempo", comment: "HR Zone 3 name")
        case 4: return String(localized: "Threshold", comment: "HR Zone 4 name")
        case 5: return String(localized: "VO₂ Max", comment: "HR Zone 5 name")
        default: return name
        }
    }
}

/// Time-in-zone summary built from a sequence of HR samples. Total equals
/// the workout duration the samples were collected over (minus any gap
/// before the first / after the last sample).
struct ZoneBreakdown: Hashable {
    /// Seconds spent in each zone, keyed by zone index (1...5). Zones with
    /// zero time are still present in the dict so UI code can iterate the
    /// full 5-element set without guarding.
    let secondsByZone: [Int: TimeInterval]

    /// Total seconds represented by the breakdown — sum of all zones.
    let totalSeconds: TimeInterval

    func seconds(in zone: HeartRateZone) -> TimeInterval {
        secondsByZone[zone.index] ?? 0
    }

    func fraction(in zone: HeartRateZone) -> Double {
        guard totalSeconds > 0 else { return 0 }
        return seconds(in: zone) / totalSeconds
    }

    static let empty = ZoneBreakdown(
        secondsByZone: Dictionary(uniqueKeysWithValues: HeartRateZone.standard.map { ($0.index, 0) }),
        totalSeconds: 0
    )
}

enum HeartRateAnalysis {
    /// Bucket a sequence of HR samples into time-in-zone seconds.
    ///
    /// Integration is "hold-until-next-sample": the HR reading at sample
    /// `i` is assumed to hold until sample `i+1`. The last sample extends
    /// up to `workoutEnd` so the chart and the bar tell the same story.
    /// Zones are resolved via `HeartRateZone.zone(for:maxHR:)`, so samples
    /// below Z1's floor count toward Z1 (intentional — see that function).
    static func breakdown(
        samples: [HealthKitService.HRSample],
        maxHR: Double,
        workoutEnd: Date? = nil
    ) -> ZoneBreakdown {
        var buckets = Dictionary(
            uniqueKeysWithValues: HeartRateZone.standard.map { ($0.index, TimeInterval(0)) }
        )
        guard samples.count >= 1, maxHR > 0 else { return .empty }

        var total: TimeInterval = 0
        for (i, s) in samples.enumerated() {
            let next = i + 1 < samples.count ? samples[i + 1].date : workoutEnd
            guard let end = next else { continue }
            let dt = max(0, end.timeIntervalSince(s.date))
            // Guard against wildly long gaps (>20 min) — treat them as
            // "paused" and don't attribute that time to a zone.
            let clamped = min(dt, 20 * 60)
            let zone = HeartRateZone.zone(for: s.bpm, maxHR: maxHR)
            buckets[zone.index, default: 0] += clamped
            total += clamped
        }

        return ZoneBreakdown(secondsByZone: buckets, totalSeconds: total)
    }

    /// Compute simple min/avg/max stats over a sequence of HR samples.
    /// Returns nil when the sequence is empty.
    static func summary(_ samples: [HealthKitService.HRSample]) -> (min: Double, avg: Double, max: Double)? {
        guard !samples.isEmpty else { return nil }
        let values = samples.map(\.bpm)
        let mn = values.min() ?? 0
        let mx = values.max() ?? 0
        let avg = values.reduce(0, +) / Double(values.count)
        return (mn, avg, mx)
    }
}
