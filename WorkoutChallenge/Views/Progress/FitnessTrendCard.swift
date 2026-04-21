//
//  FitnessTrendCard.swift
//  WorkoutChallenge
//
//  Progress tab's "fitness over time" card. Plots a CTL ("fitness") line
//  derived from the user's workouts and overlays Apple's auto-computed
//  VO₂Max samples as dots — the independent capacity signal that tells
//  the user whether the prescribed sigmoid is actually moving fitness.
//
//  Below the chart, a physiology row surfaces two stat tiles: a latest
//  VO₂Max reading and a latest HRV (SDNN) reading, each paired with an
//  early-window vs. late-window delta. HRV isn't plotted — it's too
//  noisy day-to-day to read meaningfully at the 90-day zoom level and
//  its millisecond scale doesn't share an axis with CTL or VO₂Max. The
//  windowed delta is the useful comparison.
//
//  CTL is computed by `TrainingLoadService` from the workouts already in
//  the SwiftData store (no HealthKit fan-out on the render path — the
//  per-workout zone refinement is a future upgrade). VO₂Max and HRV are
//  pulled async from HealthKit in parallel; tiles and overlays hide
//  gracefully when the corresponding signal is missing.
//
//  The CTL line and VO₂Max dots share a single chart y-axis deliberately:
//  for a regular exerciser both sit in the 30–80 range numerically, so
//  overlaying them reads as "are both lines moving together" at a glance.
//  The card legend calls out units explicitly so the axis isn't misread.
//

import SwiftUI
import Charts
import SwiftData

struct FitnessTrendCard: View {
    let workouts: [WorkoutModel]
    let startDate: Date
    let endDate: Date

    @EnvironmentObject private var healthKit: HealthKitService

    /// VO₂Max samples loaded from HealthKit for the challenge window.
    /// Empty until the `.task` completes or HK read is unavailable.
    @State private var vo2Samples: [HealthKitService.VO2MaxSample] = []

    /// HRV (SDNN, ms) samples loaded from HealthKit for the challenge
    /// window. Used only for a summary "early-window vs. late-window"
    /// delta — raw HRV is too noisy to plot meaningfully over 90 days
    /// and its scale (20–100 ms) doesn't share a y-axis with CTL.
    @State private var hrvSamples: [HealthKitService.HRVSample] = []

    // MARK: - Derived series

    /// Daily loads bucketed across the challenge window. Pure compute
    /// from in-memory workouts; recomputed on view body evaluation
    /// which is cheap (≤90 entries).
    private var dailyLoads: [TrainingLoadService.DailyLoad] {
        TrainingLoadService.dailyLoads(
            workouts: workouts,
            startDate: startDate,
            endDate: endDate
        )
    }

    private var ctlSeries: [TrainingLoadService.LoadPoint] {
        TrainingLoadService.ctl(loads: dailyLoads)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            header
            chart
                .frame(height: 220)
            legendRow
            physiologyRow
            footer
        }
        .appCard()
        .task(id: taskKey) {
            await loadMetrics()
        }
    }

    /// Reload VO₂Max when the challenge window or HK availability flips.
    private var taskKey: String {
        "\(startDate.timeIntervalSince1970)-\(endDate.timeIntervalSince1970)-\(healthKit.isAvailable)"
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("FITNESS TREND").tsEyebrow().foregroundStyle(Color.textTertiary)
            Spacer()
            if let latest = ctlSeries.last?.value {
                Chip(title: "Load \(Int(latest.rounded()))", isOn: true)
            }
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        let windowStart = startDate.startOfDay
        // Convert each CTL LoadPoint to a day-index so x-axis units match
        // the sigmoid hero above (both say "Day" in the axis label,
        // preserving a consistent reading frame across the two cards).
        let ctlPoints: [TrendPoint] = ctlSeries.map {
            TrendPoint(
                day: windowStart.daysUntil($0.date),
                value: $0.value
            )
        }
        let vo2Points: [TrendPoint] = vo2Samples.map {
            TrendPoint(
                day: windowStart.daysUntil($0.date),
                value: $0.value
            )
        }

        Chart {
            // Soft volt wash under the CTL line — mirrors the sigmoid
            // hero's visual language so the two cards feel like one
            // story.
            ForEach(ctlPoints) { p in
                AreaMark(
                    x: .value("Day", p.day),
                    y: .value("Value", p.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.accentVolt.opacity(0.22),
                            Color.accentVolt.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
            }

            // CTL line — primary series, ink stroke.
            ForEach(ctlPoints) { p in
                LineMark(
                    x: .value("Day", p.day),
                    y: .value("Value", p.value),
                    series: .value("Series", "CTL")
                )
                .foregroundStyle(Color.textPrimary)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }

            // VO₂Max dots — secondary overlay. Neon-accent fill with an
            // ink stroke so they read against the volt wash. Annotated
            // with the numeric value since the shared y-axis can make
            // the absolute mL/(kg·min) figure hard to read off.
            ForEach(vo2Points) { p in
                PointMark(
                    x: .value("Day", p.day),
                    y: .value("Value", p.value)
                )
                .symbol {
                    Circle()
                        .fill(Color.accentNeon)
                        .overlay(Circle().stroke(Color.textPrimary, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                }
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text(String(format: "%.0f", p.value))
                        .font(AppFont.mono(8, weight: .bold))
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: 15)) { _ in
                AxisValueLabel()
                    .font(AppFont.mono(10))
                    .foregroundStyle(Color.textSecondary)
                AxisGridLine().foregroundStyle(Color.appBorder)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(AppFont.mono(10))
                    .foregroundStyle(Color.textSecondary)
                AxisGridLine().foregroundStyle(Color.appBorder)
            }
        }
        .chartXAxisLabel {
            Text("Day").font(AppFont.mono(11, weight: .medium))
                .foregroundStyle(Color.textSecondary)
        }
    }

    // MARK: - Legend

    private var legendRow: some View {
        HStack(spacing: Space.x4) {
            HStack(spacing: 6) {
                Capsule().fill(Color.textPrimary).frame(width: 18, height: 2)
                Text("Training load")
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            if !vo2Samples.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.accentNeon)
                        .overlay(Circle().stroke(Color.textPrimary, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                    Text("VO₂Max")
                        .font(AppFont.ui(12, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Physiology row

    /// Compact "is my body changing?" row — pairs a VO₂Max delta (if
    /// Apple has posted samples) with an HRV delta (if the Watch has
    /// recorded any). Each tile shows early-window → late-window
    /// movement, because both signals are individually too noisy for
    /// point-to-point comparisons but their windowed drift is meaningful.
    /// Hidden entirely when neither signal is available.
    @ViewBuilder
    private var physiologyRow: some View {
        let vo2 = windowDelta(from: vo2Samples.map(\.value))
        let hrv = windowDelta(from: hrvSamples.map(\.value))
        if vo2 != nil || hrv != nil {
            HStack(spacing: Space.x3) {
                if let d = vo2 {
                    physiologyTile(
                        label: "VO₂MAX",
                        latest: String(format: "%.0f", d.last),
                        unit: "ml/kg·min",
                        delta: d.delta,
                        deltaFormat: "%+.1f"
                    )
                }
                if let d = hrv {
                    physiologyTile(
                        label: "HRV",
                        latest: String(format: "%.0f", d.last),
                        unit: "ms",
                        delta: d.delta,
                        deltaFormat: "%+.0f"
                    )
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Render one physiology stat tile: small eyebrow label, a big
    /// monospaced latest value, its unit, and a windowed delta with
    /// direction arrow. Arrow thresholds are tuned per signal in the
    /// caller via the raw delta passed in here.
    @ViewBuilder
    private func physiologyTile(
        label: String,
        latest: String,
        unit: String,
        delta: Double,
        deltaFormat: String
    ) -> some View {
        // A deadband of 0.5 keeps tiny noise from flipping the arrow
        // each time a new sample arrives — good enough for both mL/(kg·min)
        // and ms at the scales we display.
        let arrow = delta > 0.5 ? "▲" : (delta < -0.5 ? "▼" : "·")
        let signed = String(format: deltaFormat, delta)
        let tint: Color = delta > 0.5
            ? Color.accentNeon
            : (delta < -0.5 ? Color.textSecondary : Color.textTertiary)
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(AppFont.mono(9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.textTertiary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(latest)
                    .font(AppFont.display(22))
                    .monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
                Text(unit)
                    .font(AppFont.mono(10))
                    .foregroundStyle(Color.textTertiary)
            }
            Text("\(arrow) \(signed) over window")
                .font(AppFont.mono(10, weight: .medium))
                .foregroundStyle(tint)
        }
    }

    /// Computed early-window vs. late-window delta for a numeric series.
    /// Returns `nil` when the series is empty; returns a zero delta when
    /// there's only one sample (so the tile can still display the value).
    private func windowDelta(from values: [Double]) -> (last: Double, delta: Double)? {
        guard let last = values.last else { return nil }
        guard let first = values.first else { return (last, 0) }
        return (last, last - first)
    }

    // MARK: - Footer copy

    /// Narrative footer — explains in plain language what the card's
    /// main line represents. One sentence, always visible. The stat
    /// tiles above handle the "is it moving?" question; this line
    /// handles the "what am I looking at?" question.
    @ViewBuilder
    private var footer: some View {
        if vo2Samples.isEmpty && hrvSamples.isEmpty {
            Text("The line is a rolling average of your training minutes — it rises when you work out consistently and drifts down during rest. Complete a few outdoor runs or walks and Apple will post VO₂Max and HRV estimates that appear here alongside it.")
                .tsCaption()
                .foregroundStyle(Color.textSecondary)
        } else {
            Text("The line tracks your training consistency. The tiles show Apple's independent read on aerobic capacity (VO₂Max) and recovery (HRV) — watch them drift over the challenge.")
                .tsCaption()
                .foregroundStyle(Color.textSecondary)
        }
    }

    // MARK: - Loading

    /// Fetch both VO₂Max and HRV concurrently from HealthKit for the
    /// challenge window, then clamp each to the window boundary. Runs
    /// in parallel so the card hydrates in roughly one HK round-trip
    /// rather than two.
    private func loadMetrics() async {
        guard healthKit.isAvailable else {
            vo2Samples = []
            hrvSamples = []
            return
        }
        let windowStart = startDate.startOfDay
        let windowEnd = endDate.startOfDay
        let endInclusive = endDate.addingDays(1)  // HK `until` is exclusive

        async let vo2 = healthKit.fetchVO2MaxSeries(
            since: startDate, until: endInclusive
        )
        async let hrv = healthKit.fetchHRVSeries(
            since: startDate, until: endInclusive
        )
        let (vo2Fetched, hrvFetched) = await (vo2, hrv)

        // Clamp to the challenge window — HK can return samples at the
        // boundary that round into an adjacent day after timezone shifts.
        vo2Samples = vo2Fetched.filter {
            let d = $0.date.startOfDay
            return d >= windowStart && d <= windowEnd
        }
        hrvSamples = hrvFetched.filter {
            let d = $0.date.startOfDay
            return d >= windowStart && d <= windowEnd
        }
    }
}

/// Intermediate shape used for plotting — keeps both series on a common
/// `(day, value)` coordinate so Swift Charts can render them in one Chart.
private struct TrendPoint: Identifiable {
    let id = UUID()
    let day: Int
    let value: Double
}

#Preview {
    // Preview uses an empty HealthKit service — the card should render
    // the CTL-only path with the "complete a few outdoor runs" footer.
    let start = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()
    let end = Calendar.current.date(byAdding: .day, value: 29, to: Date()) ?? Date()
    return FitnessTrendCard(
        workouts: [],
        startDate: start,
        endDate: end
    )
    .environmentObject(HealthKitService())
    .padding()
    .background(Color.appBg)
}
