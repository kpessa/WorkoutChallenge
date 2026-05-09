//
//  ProgressChartView.swift
//  WorkoutChallenge
//
//  Swift Charts port of ProgressChart.svelte. Plots the sigmoid target
//  curve against the user's actual logged durations across the 90-day
//  window. Requires iOS 16+ (Swift Charts).
//
//  Progress tab redesign (2026-04-21): the prior layout had two sigmoid
//  cards (a decorative SigmoidCurve hero + the data-bearing chart below)
//  and a standalone sun-arc card. The two sigmoids were the same curve
//  at different zooms; the sun arc was underused. This version collapses
//  everything into a single hero chart that shows the target curve,
//  logged points, and a today marker with the minute-target callout —
//  one graph answering "what's the plan and where am I on it."
//
//  The lunar timeline stays below as a secondary accent. Sun arc is gone.
//

import SwiftUI
import Combine
import Charts
import SwiftData

struct ProgressChartView: View {
    @Query private var preferencesList: [UserPreferencesModel]
    @Query private var challenges: [ChallengeModel]
    @Query(sort: \WorkoutModel.date) private var workouts: [WorkoutModel]

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var healthKit: HealthKitService

    /// View-scoped loader for the Progress coach card. Owns its own task
    /// so cancel-on-disappear is clean. Same lifecycle pattern as
    /// `CoachFeedbackLoader` in `LogWorkoutSheet`.
    @State private var coachLoader = ProgressCoachLoader()

    /// Audio player for the coach narration. Held at this level so
    /// playback survives child re-renders. Stopped explicitly on the
    /// `onDisappear` so the user doesn't carry audio out of the tab.
    @State private var coachAudioPlayer = CoachAudioPlayer()

    private var prefs: UserPreferencesModel? { preferencesList.first }

    /// Resolved schedule config — active challenge if one exists, else
    /// prefs. See `ChallengeService.activeConfig(...)`.
    private var activeConfig: ChallengeService.ActiveConfig? {
        ChallengeService.activeConfig(challenges: challenges, prefs: prefs)
    }

    /// Reload key for the coach loader. Bumps when:
    ///   • the active config changes (new challenge / new sigmoid)
    ///   • the workout count changes (a fresh log invalidates the day's
    ///     fingerprint, even if the persisted insight row hasn't been
    ///     touched yet — the loader will recompute and decide whether to
    ///     re-narrate based on the live fingerprint vs. the cached one)
    private var coachReloadKey: String {
        let startKey = activeConfig?.startDate.timeIntervalSince1970 ?? 0
        return "\(startKey)-\(workouts.count)"
    }

    var body: some View {
        Group {
            if let config = activeConfig {
                let currentDay = max(1, min(90, config.startDate.daysUntil(Date().startOfDay) + 1))
                ScreenShell(
                    eyebrow: "PROGRESSION · SIGMOID",
                    title: "Your curve."
                ) {
                    heroCard(config: config, currentDay: currentDay)
                    // Slot the coach card BETWEEN the hero and the
                    // fitness-trend card. The teach-then-comment voice
                    // sits next to the metric it's most likely to
                    // explain — CTL on the trend card just below.
                    ProgressCoachCard(
                        state: coachLoader.state,
                        audioPlayer: coachAudioPlayer
                    )
                    FitnessCard(
                        workouts: workouts,
                        startDate: config.startDate,
                        endDate: config.startDate.addingDays(89)
                    )
                    PhysiologyCard(
                        startDate: config.startDate,
                        endDate: config.startDate.addingDays(89)
                    )
                    AdaptationsCard(
                        workouts: workouts,
                        startDate: config.startDate,
                        endDate: config.startDate.addingDays(89)
                    )
                    lunarTimelineCard(config: config, currentDay: currentDay)
                }
                .task(id: coachReloadKey) {
                    // Fire the coach load on appear and whenever the
                    // reload key changes. Idempotent against the cache:
                    // when the fingerprint matches the persisted row,
                    // no narrator/network call happens.
                    guard let config = activeConfig else { return }
                    coachLoader.load(
                        allWorkouts: workouts,
                        challenge: ChallengeService.currentChallenge(in: challenges),
                        config: config,
                        healthKit: healthKit,
                        modelContext: modelContext,
                        voiceID: prefs?.coachVoiceID ?? "",
                        locale: .current
                    )
                }
                .onDisappear {
                    coachLoader.cancel()
                    coachAudioPlayer.stop()
                }
            } else {
                ZStack {
                    Color.appBg.ignoresSafeArea()
                    ProgressView().tint(.accentVolt)
                }
            }
        }
    }

    // MARK: - Lunar timeline card

    /// Five moon glyphs across the 90-day span — D1 / D23 / D45 / D68 / D90.
    /// Each glyph reflects the actual moon phase on that day (not a fixed
    /// cycle). The marker between glyphs shows roughly where "today" sits.
    @ViewBuilder
    private func lunarTimelineCard(config: ChallengeService.ActiveConfig, currentDay: Int) -> some View {
        let checkpoints = [1, 23, 45, 68, 90]
        let dates: [(label: String, date: Date)] = checkpoints.map { d in
            ("D\(d)", config.startDate.addingDays(d - 1))
        }
        VStack(alignment: .leading, spacing: Space.x2) {
            Text("LUNAR TIMELINE").tsEyebrow()
                .foregroundStyle(Color.textTertiary)
            HStack {
                ForEach(dates, id: \.label) { entry in
                    let phase = CelestialService.moonPhase(on: entry.date)
                    VStack(spacing: 4) {
                        MoonGlyph(phase: phase, size: 18)
                        Text(entry.label)
                            .font(AppFont.mono(8, weight: .medium))
                            .tracking(0.6)
                            .foregroundStyle(Color.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            // Current-day marker under the timeline.
            GeometryReader { geo in
                let t = max(0, min(1, Double(currentDay - 1) / 89.0))
                Rectangle()
                    .fill(Color.appBorder)
                    .frame(height: 1)
                Circle()
                    .fill(Color.accentVolt)
                    .overlay(Circle().stroke(Color.textPrimary, lineWidth: 1.5))
                    .frame(width: 8, height: 8)
                    .position(x: geo.size.width * t, y: 0)
            }
            .frame(height: 10)
            .padding(.top, 2)
        }
        .appCard()
    }

    // MARK: - Hero (merged sigmoid + data chart)

    /// Single hero card: target sigmoid + logged points + today marker +
    /// minute-target callout. Replaces the prior split between a decorative
    /// `SigmoidCurve` card and a separate data chart.
    @ViewBuilder
    private func heroCard(config: ChallengeService.ActiveConfig, currentDay: Int) -> some View {
        let progress = Double(currentDay) / 90.0
        let todayTarget = SigmoidalService.targetDuration(
            dayIndex: currentDay - 1, params: config.sigmoid
        )
        let todayTargetRounded = Int(todayTarget.rounded())
        VStack(alignment: .leading, spacing: Space.x3) {
            // Header row: eyebrow + day chip.
            HStack(alignment: .firstTextBaseline) {
                Text("TODAY").tsEyebrow().foregroundStyle(Color.textTertiary)
                Spacer()
                Chip(title: "Day \(currentDay) / 90", isOn: true)
            }

            // Callout row: big minute-target + supporting context.
            HStack(alignment: .lastTextBaseline, spacing: Space.x2) {
                // Meld: monospaced digits so the number doesn't jitter when
                // it ticks up from 9 → 10 → 11 min across the early plateau.
                Text("\(todayTargetRounded)")
                    .font(AppFont.display(40))
                    .monospacedDigit()
                    .tracking(-0.8)
                    .foregroundStyle(Color.textPrimary)
                Text("min target")
                    .tsCaption()
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Text("\(Int(progress * 100))% of arc")
                    .font(AppFont.mono(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }

            // The main chart — target curve, logged points, today marker.
            chart(config: config, currentDay: currentDay, todayTarget: todayTarget)
                .frame(height: 240)

            // Inline legend — Target line, Logged dot, Today marker.
            legendRow
        }
        .appCard()
    }

    // MARK: - Legend

    private var legendRow: some View {
        HStack(spacing: Space.x4) {
            HStack(spacing: 6) {
                Capsule().fill(Color.textPrimary).frame(width: 18, height: 2)
                Text("Target")
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            HStack(spacing: 6) {
                // Meld: Volt dot + 1.5pt ink stroke (fails 3:1 without).
                Circle()
                    .fill(Color.accentVolt)
                    .overlay(Circle().stroke(Color.textPrimary, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                Text("Logged")
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            HStack(spacing: 6) {
                // Meld: ink-filled ring with a hollow volt center distinguishes
                // "the target-at-today" marker from logged workout dots.
                Circle()
                    .strokeBorder(Color.textPrimary, lineWidth: 2)
                    .background(Circle().fill(Color.appSurface))
                    .frame(width: 10, height: 10)
                Text("Today")
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private func chart(
        config: ChallengeService.ActiveConfig,
        currentDay: Int,
        todayTarget: Double
    ) -> some View {
        let targetPoints: [ChartPoint] = (0...90).map { day in
            ChartPoint(
                day: day,
                minutes: SigmoidalService.targetDuration(dayIndex: day, params: config.sigmoid)
            )
        }

        let actualPoints: [ChartPoint] = workouts.compactMap { w in
            let dayIndex = config.startDate.daysUntil(w.date)
            guard dayIndex >= 0 else { return nil }
            return ChartPoint(day: dayIndex, minutes: Double(w.duration))
        }

        let todayPoint = ChartPoint(day: currentDay - 1, minutes: todayTarget)

        Chart {
            // Soft fill under target curve — subtle volt wash to visually
            // anchor the growth arc without competing with the line itself.
            ForEach(targetPoints) { p in
                AreaMark(
                    x: .value("Day", p.day),
                    y: .value("Minutes", p.minutes)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.accentVolt.opacity(0.25),
                            Color.accentVolt.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
            }

            // Target sigmoid.
            ForEach(targetPoints) { p in
                LineMark(
                    x: .value("Day", p.day),
                    y: .value("Minutes", p.minutes)
                )
                .foregroundStyle(Color.textPrimary)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }

            // Today marker: hollow ring sitting ON the target curve at
            // currentDay. The minute target is already called out in the
            // card header, so we deliberately don't annotate the marker
            // here — an opaque annotation pill would occlude the logged
            // dots nearby (e.g. early-challenge workouts at day 0/1 when
            // the marker sits at day 3). Rendered *before* logged dots
            // so the logged markers always draw on top.
            RuleMark(x: .value("Today", todayPoint.day))
                .foregroundStyle(Color.textPrimary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

            PointMark(
                x: .value("Day", todayPoint.day),
                y: .value("Minutes", todayPoint.minutes)
            )
            .symbol {
                Circle()
                    .strokeBorder(Color.textPrimary, lineWidth: 2)
                    .background(Circle().fill(Color.appSurface))
                    .frame(width: 12, height: 12)
            }

            // Logged workouts — Volt dots with ink stroke for contrast.
            // Drawn last so they render on top of the today marker and
            // the target line when days overlap.
            ForEach(actualPoints) { p in
                PointMark(
                    x: .value("Day", p.day),
                    y: .value("Minutes", p.minutes)
                )
                .symbol {
                    Circle()
                        .fill(Color.accentVolt)
                        .overlay(Circle().stroke(Color.textPrimary, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                }
            }
        }
        // Lock the x-domain to the 90-day challenge window so wide
        // annotations or sparse data can't auto-expand it past day 0
        // (which previously pushed logged dots out of the visible area).
        .chartXScale(domain: 0...90)
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
        .chartYAxisLabel {
            Text("Minutes").font(AppFont.mono(11, weight: .medium))
                .foregroundStyle(Color.textSecondary)
        }
    }
}

private struct ChartPoint: Identifiable {
    let id = UUID()
    let day: Int
    let minutes: Double
}

#Preview {
    ProgressChartView()
        .modelContainer(try! Persistence.makePreviewContainer())
}
