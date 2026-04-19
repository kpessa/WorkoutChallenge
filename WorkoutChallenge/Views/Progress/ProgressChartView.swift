//
//  ProgressChartView.swift
//  WorkoutChallenge
//
//  Swift Charts port of ProgressChart.svelte. Plots the sigmoid target
//  curve against the user's actual logged durations across the 90-day
//  window. Requires iOS 16+ (Swift Charts).
//
//  Redesigned to use the ScreenShell + appCard system: eyebrow + H1 header
//  on OLED-black, a SigmoidCurve hero, and the data chart in its own card.
//

import SwiftUI
import Charts
import SwiftData

struct ProgressChartView: View {
    @Query private var preferencesList: [UserPreferencesModel]
    @Query(sort: \WorkoutModel.date) private var workouts: [WorkoutModel]

    private var prefs: UserPreferencesModel? { preferencesList.first }

    var body: some View {
        Group {
            if let prefs {
                let currentDay = max(1, min(90, prefs.startDate.daysUntil(Date().startOfDay) + 1))
                ScreenShell(
                    eyebrow: "PROGRESSION · SIGMOID",
                    title: "Your curve."
                ) {
                    heroCard(prefs: prefs, currentDay: currentDay)
                    legendCard
                    chartCard(prefs: prefs)
                }
            } else {
                ZStack {
                    Color.appBg.ignoresSafeArea()
                    ProgressView().tint(.accentVolt)
                }
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroCard(prefs: UserPreferencesModel, currentDay: Int) -> some View {
        let progress = Double(currentDay) / 90.0
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").tsEyebrow().foregroundStyle(Color.textTertiary)
                Spacer()
                Chip(title: "Day \(currentDay) / 90", isOn: true)
            }
            SigmoidCurve(progress: progress).frame(height: 140)
            Text("You're \(Int(progress * 100))% through the challenge.")
                .tsCaption()
        }
        .appCard()
    }

    // MARK: - Legend

    private var legendCard: some View {
        HStack(spacing: Space.x5) {
            HStack(spacing: 6) {
                Capsule().fill(Color.textPrimary).frame(width: 18, height: 2)
                Text("Target")
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            HStack(spacing: 6) {
                Circle().fill(Color.accentVolt).frame(width: 8, height: 8)
                Text("Logged")
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, Space.x2)
    }

    // MARK: - Chart

    @ViewBuilder
    private func chartCard(prefs: UserPreferencesModel) -> some View {
        AppSection(title: "Minutes per day") {
            chart(prefs: prefs)
                .frame(height: 260)
        }
    }

    @ViewBuilder
    private func chart(prefs: UserPreferencesModel) -> some View {
        let targetPoints: [ChartPoint] = (0...90).map { day in
            ChartPoint(
                day: day,
                minutes: SigmoidalService.targetDuration(dayIndex: day, params: prefs.sigmoid)
            )
        }

        let actualPoints: [ChartPoint] = workouts.compactMap { w in
            let dayIndex = prefs.startDate.daysUntil(w.date)
            guard dayIndex >= 0 else { return nil }
            return ChartPoint(day: dayIndex, minutes: Double(w.duration))
        }

        Chart {
            ForEach(targetPoints) { p in
                LineMark(
                    x: .value("Day", p.day),
                    y: .value("Minutes", p.minutes)
                )
                .foregroundStyle(Color.textPrimary)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }

            ForEach(actualPoints) { p in
                PointMark(
                    x: .value("Day", p.day),
                    y: .value("Minutes", p.minutes)
                )
                .foregroundStyle(Color.accentVolt)
                .symbolSize(60)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: 10)) { _ in
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
