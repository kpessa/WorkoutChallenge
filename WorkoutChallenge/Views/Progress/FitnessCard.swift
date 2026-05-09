//
//  FitnessCard.swift
//  WorkoutChallenge
//
//  Progress tab's "Am I getting fitter? Am I cooked?" card. Plots the two
//  Banister-model load lines (CTL = fitness, ATL = fatigue) on a shared
//  training-load axis and surfaces Form (CTL − ATL) as a tile alongside
//  delta tiles for each line.
//
//  CTL and ATL share an axis because they're the same units (training-
//  load score, ~0–80 for typical recreational athletes) — overlaying
//  them is the whole point of the Banister chart. VO₂Max / HRV /
//  resting-HR live on the separate PhysiologyCard so the two scales
//  never share a plot.
//
//  Math comes straight from `TrainingLoadService` — pure-function CTL
//  and ATL EWAs over a 90-day daily-load series. Captions are
//  deterministic (no LLM call); they read off the same series the chart
//  is rendering, so they can never disagree with the visual.
//

import SwiftUI
import Charts

struct FitnessCard: View {
    let workouts: [WorkoutModel]
    let startDate: Date
    let endDate: Date

    /// Daily-load → CTL/ATL pipeline. Recomputed on body evaluation —
    /// cheap (≤90 entries, two EWAs) so we don't bother caching.
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
    private var atlSeries: [TrainingLoadService.LoadPoint] {
        TrainingLoadService.atl(loads: dailyLoads)
    }

    /// Day-indexed plotting points so x-axis units match the sigmoid hero.
    private struct Point: Identifiable {
        let id = UUID()
        let day: Int
        let value: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            header
            chart
                .frame(height: 200)
            legendRow
            statsRow
            footer
        }
        .appCard()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("FITNESS").tsEyebrow().foregroundStyle(Color.textTertiary)
            Spacer()
            if let form = currentForm {
                Chip(title: formChipTitle(form), isOn: true)
            }
        }
    }

    /// Form (CTL − ATL) at the latest point. Positive = "fresh", negative
    /// = "fatigued" in the Banister vocabulary. Returns nil if either
    /// series is empty.
    private var currentForm: Double? {
        guard let ctl = ctlSeries.last?.value,
              let atl = atlSeries.last?.value else { return nil }
        return ctl - atl
    }

    private func formChipTitle(_ form: Double) -> String {
        let sign = form >= 0 ? "+" : ""
        return "Form \(sign)\(Int(form.rounded()))"
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        let windowStart = startDate.startOfDay
        let ctlPoints: [Point] = ctlSeries.map {
            Point(day: windowStart.daysUntil($0.date), value: $0.value)
        }
        let atlPoints: [Point] = atlSeries.map {
            Point(day: windowStart.daysUntil($0.date), value: $0.value)
        }

        Chart {
            // Soft volt wash under the CTL line for the "fitness rising"
            // visual. ATL gets no fill — it's the secondary line.
            ForEach(ctlPoints) { p in
                AreaMark(
                    x: .value("Day", p.day),
                    y: .value("Value", p.value),
                    series: .value("Series", "CTL")
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
            // ATL — danger-tinted, dashed so it reads as the "watch out"
            // signal next to the steady CTL trend line.
            ForEach(atlPoints) { p in
                LineMark(
                    x: .value("Day", p.day),
                    y: .value("Value", p.value),
                    series: .value("Series", "ATL")
                )
                .foregroundStyle(Color.danger)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .interpolationMethod(.monotone)
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
                Text("Fitness (CTL)")
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            HStack(spacing: 6) {
                Capsule().fill(Color.danger).frame(width: 18, height: 2)
                Text("Fatigue (ATL)")
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: - Stats row

    /// Three tiles: latest CTL / latest ATL / Form. Form's tint flips
    /// sign-aware — positive Form (fresh) reads as accentNeon, negative
    /// (fatigued) as warn. The 5-point deadband matches the chart's
    /// effective resolution at day-scale EWAs.
    @ViewBuilder
    private var statsRow: some View {
        if let ctl = ctlSeries.last?.value, let atl = atlSeries.last?.value {
            HStack(spacing: Space.x2) {
                StatTile(
                    label: "FITNESS",
                    value: "\(Int(ctl.rounded()))",
                    unit: "CTL",
                    accent: true
                )
                StatTile(
                    label: "FATIGUE",
                    value: "\(Int(atl.rounded()))",
                    unit: "ATL"
                )
                StatTile(
                    label: "FORM",
                    value: formString(ctl - atl),
                    unit: formLabel(ctl - atl)
                )
            }
        }
    }

    private func formString(_ form: Double) -> String {
        let sign = form >= 0 ? "+" : ""
        return "\(sign)\(Int(form.rounded()))"
    }

    private func formLabel(_ form: Double) -> String {
        if form > 5 { return "FRESH" }
        if form < -5 { return "FATIGUED" }
        return "STEADY"
    }

    // MARK: - Footer (deterministic caption)

    /// Plain-language read of the chart, computed from the same series
    /// the plot uses so it can never disagree. Compares the latest CTL
    /// value to its value 30 days earlier (or as far back as the series
    /// goes if shorter), and pairs that with the current Form bucket.
    @ViewBuilder
    private var footer: some View {
        let copy = generateCaption()
        if !copy.isEmpty {
            Text(copy)
                .tsCaption()
                .foregroundStyle(Color.textSecondary)
        }
    }

    private func generateCaption() -> String {
        guard let ctlNow = ctlSeries.last?.value,
              let atlNow = atlSeries.last?.value,
              !ctlSeries.isEmpty else {
            return "Log a few workouts and your fitness curve (CTL) will start to render here. Fatigue (ATL) responds within days; fitness takes a few weeks to move."
        }

        // CTL trend: last value vs ~30 days earlier (or earliest available).
        let lookbackIndex = max(0, ctlSeries.count - 31)
        let ctlPast = ctlSeries[lookbackIndex].value
        let ctlDelta = ctlNow - ctlPast
        let trendPhrase: String
        if ctlDelta > 3 {
            trendPhrase = "Fitness is up \(Int(ctlDelta.rounded())) in the last 30 days — your body is adapting."
        } else if ctlDelta < -3 {
            trendPhrase = "Fitness has dropped \(Int(abs(ctlDelta).rounded())) in the last 30 days — likely from reduced volume."
        } else {
            trendPhrase = "Fitness is holding roughly flat over the last 30 days."
        }

        // Form bucket: positive = fresh, near zero = steady, negative = fatigued.
        let form = ctlNow - atlNow
        let formPhrase: String
        if form > 8 {
            formPhrase = "Form is \(Int(form.rounded())) — well-rested. Good window for a hard session."
        } else if form < -10 {
            formPhrase = "Form is \(Int(form.rounded())) — fatigued. Consider an easier day or rest."
        } else {
            formPhrase = "Form is \(Int(form.rounded())) — balanced load."
        }

        return "\(trendPhrase) \(formPhrase)"
    }
}
