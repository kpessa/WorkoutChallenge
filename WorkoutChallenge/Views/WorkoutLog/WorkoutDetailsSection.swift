//
//  WorkoutDetailsSection.swift
//  WorkoutChallenge
//
//  Rendering for the per-workout enrichment surfaced under the edit sheet
//  once a `WorkoutDetails` payload has been loaded. Split into self-
//  contained subviews so each one can `if`-out cleanly when HealthKit
//  didn't hand us that particular field:
//
//    • HeartRateCard    — min/avg/max tiles + 5-zone stacked bar + HR chart
//    • ExtraStatsCard   — active kcal, distance, flights climbed (as tiles)
//
//  The route map lives in `WorkoutRouteMap.swift` to isolate the MapKit
//  import from this file's Charts import.
//

import SwiftUI
import Charts

// MARK: - Heart-rate card

struct HeartRateCard: View {
    let details: WorkoutDetails

    var body: some View {
        if details.hrSamples.isEmpty {
            emptyState
        } else {
            AppSection(title: "Heart rate") {
                VStack(alignment: .leading, spacing: Space.x4) {
                    if let summary = details.hrSummary {
                        HeartRateStatsRow(summary: summary)
                    }
                    HeartRateZoneBar(
                        breakdown: details.zones,
                        maxHR: details.maxHRUsed
                    )
                    HeartRateChart(
                        samples: details.hrSamples,
                        maxHR: details.maxHRUsed,
                        domain: details.workoutStart...details.workoutEnd
                    )
                    .frame(height: 140)
                    maxHRFootnote
                }
            }
        }
    }

    /// Tiny caveat line under the chart so users know which MHR we used —
    /// makes the zone labels interpretable even when their MHR preference
    /// disagrees with their intuition.
    private var maxHRFootnote: some View {
        Text("Zones calculated against \(Int(details.maxHRUsed.rounded())) BPM max. Adjust in Settings → Max heart rate.")
            .font(AppFont.ui(11, weight: .medium))
            .foregroundStyle(Color.textTertiary)
    }

    /// Rendered when the workout exists in HealthKit but had no HR samples
    /// (common for manual entries). We surface an explicit note rather than
    /// silently omitting the section, so the user knows why they don't see
    /// zones / chart.
    private var emptyState: some View {
        AppSection(title: "Heart rate") {
            HStack(spacing: Space.x3) {
                Image(systemName: "heart.slash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No heart-rate data")
                        .font(AppFont.ui(14, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Workouts logged manually (or outside an Apple Watch session) don't carry HR samples.")
                        .font(AppFont.ui(12, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Stats row

/// Three side-by-side StatTiles: Min / Avg / Max BPM. Avg is accented
/// because it's the stat most users scan for first.
struct HeartRateStatsRow: View {
    let summary: (min: Double, avg: Double, max: Double)

    var body: some View {
        HStack(spacing: Space.x2) {
            StatTile(label: "MIN", value: "\(Int(summary.min.rounded()))", unit: "BPM")
            StatTile(label: "AVG", value: "\(Int(summary.avg.rounded()))", unit: "BPM", accent: true)
            StatTile(label: "MAX", value: "\(Int(summary.max.rounded()))", unit: "BPM")
        }
    }
}

// MARK: - Zone bar

/// Stacked horizontal bar showing the fraction of workout time in each
/// zone. Below the bar we list each zone with its BPM range and a
/// formatted duration so users can read exact values — the bar alone is
/// too coarse for the short-duration workouts this app targets.
struct HeartRateZoneBar: View {
    let breakdown: ZoneBreakdown
    let maxHR: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack {
                Text("Time in zones").tsEyebrow().foregroundStyle(Color.textTertiary)
                Spacer()
                Text(Self.formatDuration(breakdown.totalSeconds))
                    .font(AppFont.mono(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }

            stackedBar

            VStack(alignment: .leading, spacing: Space.x2) {
                ForEach(HeartRateZone.standard) { zone in
                    zoneRow(zone)
                }
            }
        }
    }

    private var stackedBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(HeartRateZone.standard) { zone in
                    let f = breakdown.fraction(in: zone)
                    if f > 0 {
                        Rectangle()
                            .fill(zone.color)
                            .frame(width: max(2, geo.size.width * f))
                    }
                }
                // Fill the remainder with an empty surface so the rounded
                // cap still renders at the right edge when zones don't sum
                // to the full duration (very rare — long gaps get clipped).
                if breakdown.totalSeconds == 0 {
                    Rectangle().fill(Color.appSurface2)
                }
            }
        }
        .frame(height: 14)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.appBorder, lineWidth: 1))
    }

    private func zoneRow(_ zone: HeartRateZone) -> some View {
        let seconds = breakdown.seconds(in: zone)
        let fraction = breakdown.fraction(in: zone)
        let range = zone.bpmRange(maxHR: maxHR)
        return HStack(spacing: Space.x3) {
            Circle()
                .fill(zone.color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Z\(zone.index)")
                        .font(AppFont.mono(11, weight: .bold))
                        .foregroundStyle(Color.textSecondary)
                    Text(zone.localizedName)
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                }
                Text("\(range.lowerBound)–\(range.upperBound) BPM · \(Int((zone.minPercent * 100).rounded()))–\(Int((zone.maxPercent * 100).rounded()))%")
                    .font(AppFont.mono(10))
                    .foregroundStyle(Color.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.formatDuration(seconds))
                    .font(AppFont.mono(12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(AppFont.mono(10, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    /// m:ss for short durations, h:mm:ss for longer ones. Workouts in this
    /// app usually cap under 2h so m:ss is the common case.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}

// MARK: - HR chart

/// Line chart of BPM over the workout duration with translucent zone
/// bands behind it so the intensity is immediately legible.
struct HeartRateChart: View {
    let samples: [HealthKitService.HRSample]
    let maxHR: Double
    let domain: ClosedRange<Date>

    /// Sensible Y-axis range: from 40 below Z1's floor to 10 above MHR.
    /// Locks it so the chart height is comparable across workouts.
    private var yRange: ClosedRange<Double> {
        let low = max(40.0, (HeartRateZone.z1.minPercent * maxHR) - 10)
        let high = maxHR + 10
        return low...high
    }

    var body: some View {
        Chart {
            // Zone bands — use RectangleMark so the color survives the
            // axis-style clipping that `.chartPlotStyle` applies.
            ForEach(HeartRateZone.standard) { zone in
                RectangleMark(
                    xStart: .value("Start", domain.lowerBound),
                    xEnd: .value("End", domain.upperBound),
                    yStart: .value("Min", zone.minPercent * maxHR),
                    yEnd: .value("Max", zone.maxPercent * maxHR)
                )
                .foregroundStyle(zone.color.opacity(0.12))
            }

            ForEach(samples) { s in
                LineMark(
                    x: .value("Time", s.date),
                    y: .value("BPM", s.bpm)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentInk)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: yRange)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel(format: .dateTime.hour().minute(),
                               anchor: .top)
                    .font(AppFont.mono(9))
                    .foregroundStyle(Color.textTertiary)
                AxisGridLine()
                    .foregroundStyle(Color.appBorder)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel()
                    .font(AppFont.mono(9))
                    .foregroundStyle(Color.textTertiary)
                AxisGridLine()
                    .foregroundStyle(Color.appBorder)
            }
        }
    }
}

// MARK: - Extra stats

/// Tiles for active calories, distance, and elevation gain. Each tile is
/// omitted if the corresponding field is nil; the whole card collapses if
/// nothing is present so we don't render an empty section.
struct ExtraStatsCard: View {
    let details: WorkoutDetails

    private var hasAny: Bool {
        details.activeKcal != nil
            || details.distanceMeters != nil
            || details.flightsClimbed != nil
    }

    var body: some View {
        if hasAny {
            AppSection(title: "Stats") {
                VStack(spacing: Space.x2) {
                    HStack(spacing: Space.x2) {
                        if let kcal = details.activeKcal {
                            StatTile(
                                label: "CALORIES",
                                value: Self.formatCalories(kcal),
                                unit: "kcal"
                            )
                        }
                        if let meters = details.distanceMeters {
                            let (value, unit) = Self.formatDistance(meters: meters)
                            StatTile(label: "DISTANCE", value: value, unit: unit, accent: true)
                        }
                    }
                    if let flights = details.flightsClimbed {
                        HStack(spacing: Space.x2) {
                            StatTile(
                                label: "ELEVATION",
                                value: "\(Int(flights.rounded()))",
                                unit: flights == 1 ? "flight" : "flights"
                            )
                            // Meters estimate alongside (1 flight ≈ 3m per
                            // Apple's internal definition). Labeled as an
                            // approximation so users don't treat it as GPS
                            // altitude data.
                            StatTile(
                                label: "APPROX",
                                value: "\(Int((flights * 3).rounded()))",
                                unit: "m gain"
                            )
                        }
                    }
                }
            }
        }
    }

    private static func formatCalories(_ kcal: Double) -> String {
        if kcal >= 1000 {
            return String(format: "%.1fk", kcal / 1000.0)
        }
        return "\(Int(kcal.rounded()))"
    }

    /// Respects the user's Locale — miles for US/UK/LR, km everywhere else.
    /// Returns (formatted number string, unit label).
    private static func formatDistance(meters: Double) -> (String, String) {
        let usesMetric = Locale.current.measurementSystem == .metric
        if usesMetric {
            let km = meters / 1000.0
            return (String(format: km < 10 ? "%.2f" : "%.1f", km), "km")
        } else {
            let miles = meters / 1609.344
            return (String(format: miles < 10 ? "%.2f" : "%.1f", miles), "mi")
        }
    }
}
