//
//  PhysiologyCard.swift
//  WorkoutChallenge
//
//  Progress tab's "Is my body changing?" card. Three independent metrics
//  on three independent y-axes, stacked vertically — sidesteps the dual-
//  axis problem entirely (each row owns its own scale, labelled in its
//  own units). Reads as one card visually but renders as three small
//  charts so users can compare *trends* even when the absolute values
//  live in different ranges.
//
//    1. VO₂Max         — mL/(kg·min). Sparse but high-signal capacity reading.
//    2. Resting HR     — BPM. Apple posts ~daily, dense series. Down-trend
//                        is the most reliable aerobic-adaptation signal.
//    3. HRV (SDNN)     — ms. Noisy day-to-day; a windowed delta is the
//                        useful comparison, not a point-to-point read.
//
//  Each row carries its latest value, a windowed delta tile, and a
//  one-line deterministic caption explaining what the direction means.
//  No LLM call — captions are computed from the same series the chart
//  shows so they can never disagree with the visual.
//

import SwiftUI
import Charts

struct PhysiologyCard: View {
    let startDate: Date
    let endDate: Date

    @EnvironmentObject private var healthKit: HealthKitService

    @State private var vo2: [HealthKitService.VO2MaxSample] = []
    @State private var resting: [HealthKitService.RestingHRSample] = []
    @State private var hrv: [HealthKitService.HRVSample] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            header
            metricRow(
                label: "VO₂ MAX",
                unit: "ml/kg·min",
                series: vo2.map { ($0.date, $0.value) },
                color: Color.accentNeon,
                deltaFormat: "%+.1f",
                deltaThreshold: 0.5,
                interpretationUp: "Aerobic capacity climbing — endurance work paying off.",
                interpretationDown: "Aerobic capacity slipped. Watches are conservative — one outdoor run usually nudges this back.",
                emptyCopy: "Apple posts a VO₂Max reading after outdoor walks/runs with HR. None in the window yet."
            )
            metricRow(
                label: "RESTING HR",
                unit: "BPM",
                series: resting.map { ($0.date, $0.value) },
                color: Color.accentVolt,
                // Resting HR DOWN is the good direction — invert the
                // copy: a negative delta is the favorable reading.
                invertSign: true,
                deltaFormat: "%+.0f",
                deltaThreshold: 1.0,
                interpretationUp: "Resting HR drifted up. Can be normal day-to-day; sustained rises hint at fatigue or illness.",
                interpretationDown: "Resting HR is dropping — your aerobic engine is responding to the training.",
                emptyCopy: "Apple posts a daily resting-HR reading from your Watch. None in the window yet."
            )
            metricRow(
                label: "HRV (SDNN)",
                unit: "ms",
                series: hrv.map { ($0.date, $0.value) },
                color: Color.textPrimary,
                deltaFormat: "%+.0f",
                deltaThreshold: 3.0,
                interpretationUp: "HRV trending up — recovery and parasympathetic tone improving.",
                interpretationDown: "HRV trending down. Sleep, stress, and alcohol all push this — context matters more than the number.",
                emptyCopy: "HRV samples come from Watch breathe sessions, sleep, and still periods. None in the window yet."
            )
            footer
        }
        .appCard()
        .task(id: taskKey) { await loadAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("PHYSIOLOGY").tsEyebrow().foregroundStyle(Color.textTertiary)
            Spacer()
            Text("Body adaptation over the challenge")
                .font(AppFont.ui(11, weight: .medium))
                .foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: - One metric row

    /// Sparkline + latest value + delta tile + interpretation line, all
    /// keyed on a `(date, value)` series. Renders an empty-state pill
    /// when the series is empty so the row isn't just a blank rectangle.
    @ViewBuilder
    private func metricRow(
        label: String,
        unit: String,
        series: [(Date, Double)],
        color: Color,
        invertSign: Bool = false,
        deltaFormat: String,
        deltaThreshold: Double,
        interpretationUp: String,
        interpretationDown: String,
        emptyCopy: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(AppFont.mono(10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color.textTertiary)
                Spacer()
                if let last = series.last {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(formatLatest(last.1, unit: unit))
                            .font(AppFont.display(20))
                            .monospacedDigit()
                            .foregroundStyle(Color.textPrimary)
                        Text(unit)
                            .font(AppFont.mono(10))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
            }
            if series.isEmpty {
                Text(emptyCopy)
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.vertical, Space.x2)
            } else {
                HStack(spacing: Space.x3) {
                    sparkline(series: series, color: color)
                        .frame(height: 36)
                        .frame(maxWidth: .infinity)
                    deltaTile(
                        series: series,
                        format: deltaFormat,
                        invertSign: invertSign,
                        threshold: deltaThreshold
                    )
                }
                Text(captionFor(
                    series: series,
                    invertSign: invertSign,
                    threshold: deltaThreshold,
                    up: interpretationUp,
                    down: interpretationDown
                ))
                .font(AppFont.ui(11, weight: .medium))
                .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private struct SparkPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    /// Tiny line chart; axes hidden, just shape. Independent y-domain
    /// per metric so the resting-HR scale (40–80 BPM) doesn't squash the
    /// VO₂Max scale (35–55 mL/kg·min).
    private func sparkline(series: [(Date, Double)], color: Color) -> some View {
        let points = series.map { SparkPoint(date: $0.0, value: $0.1) }
        return Chart(points) { p in
            LineMark(x: .value("Date", p.date), y: .value("Value", p.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
                .interpolationMethod(.monotone)
            AreaMark(x: .value("Date", p.date), y: .value("Value", p.value))
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.18), color.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    /// Compact ▲/▼/· tile showing the early-window vs. late-window delta.
    /// Color follows the *favorable* direction — resting-HR down is
    /// good (invertSign), so its tile flips.
    private func deltaTile(
        series: [(Date, Double)],
        format: String,
        invertSign: Bool,
        threshold: Double
    ) -> some View {
        let delta = (series.last?.1 ?? 0) - (series.first?.1 ?? 0)
        let arrow = delta > threshold ? "▲" : (delta < -threshold ? "▼" : "·")
        let favorable = invertSign ? (delta < -threshold) : (delta > threshold)
        let unfavorable = invertSign ? (delta > threshold) : (delta < -threshold)
        let tint: Color = favorable ? Color.accentNeon
            : (unfavorable ? Color.warn : Color.textTertiary)
        let signed = String(format: format, delta)
        return VStack(alignment: .trailing, spacing: 2) {
            Text("Δ window")
                .font(AppFont.mono(9, weight: .medium))
                .foregroundStyle(Color.textTertiary)
            Text("\(arrow) \(signed)")
                .font(AppFont.mono(12, weight: .bold))
                .foregroundStyle(tint)
        }
    }

    private func captionFor(
        series: [(Date, Double)],
        invertSign: Bool,
        threshold: Double,
        up: String,
        down: String
    ) -> String {
        let delta = (series.last?.1 ?? 0) - (series.first?.1 ?? 0)
        if delta > threshold { return up }
        if delta < -threshold { return down }
        return "Holding steady over the window — change at this scale takes weeks of consistent stimulus."
    }

    private func formatLatest(_ v: Double, unit: String) -> String {
        // VO₂Max gets a decimal (40.5 reads better than 41); resting HR
        // and HRV are presented as integers since their natural precision
        // is integer-BPM and integer-ms anyway.
        if unit == "ml/kg·min" {
            return String(format: "%.1f", v)
        }
        return "\(Int(v.rounded()))"
    }

    // MARK: - Footer

    private var footer: some View {
        Text("Each row tracks an independent physiology signal. They shift on different timescales: HRV swings nightly, resting HR drifts over weeks, VO₂Max moves over months.")
            .tsCaption()
            .foregroundStyle(Color.textSecondary)
    }

    // MARK: - Loading

    private var taskKey: String {
        "\(startDate.timeIntervalSince1970)-\(endDate.timeIntervalSince1970)-\(healthKit.isAvailable)"
    }

    /// Pull all three series concurrently so the card hydrates in one
    /// HK round-trip. Window clamping mirrors the FitnessTrendCard
    /// pattern — HK can return boundary samples that round into an
    /// adjacent day under timezone shifts.
    private func loadAll() async {
        guard healthKit.isAvailable else {
            vo2 = []; resting = []; hrv = []
            return
        }
        let endInclusive = endDate.addingDays(1)
        async let v = healthKit.fetchVO2MaxSeries(since: startDate, until: endInclusive)
        async let r = healthKit.fetchRestingHRSeries(since: startDate, until: endInclusive)
        async let h = healthKit.fetchHRVSeries(since: startDate, until: endInclusive)
        let (vFetched, rFetched, hFetched) = await (v, r, h)

        let windowStart = startDate.startOfDay
        let windowEnd = endDate.startOfDay
        vo2 = vFetched.filter {
            let d = $0.date.startOfDay
            return d >= windowStart && d <= windowEnd
        }
        resting = rFetched.filter {
            let d = $0.date.startOfDay
            return d >= windowStart && d <= windowEnd
        }
        hrv = hFetched.filter {
            let d = $0.date.startOfDay
            return d >= windowStart && d <= windowEnd
        }
    }
}
