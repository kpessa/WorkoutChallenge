//
//  AnalyticsView.swift
//  WorkoutChallenge
//
//  Port of AnalyticsPanel.svelte + WeeklyAnalyticsPanel.svelte. Shows
//  summary stats (StatTiles), a weekly bar chart (Swift Charts), and a
//  recent workouts list. Fully migrated to the design-system ScreenShell.
//

import SwiftUI
import Charts
import SwiftData

struct AnalyticsView: View {
    @Query(sort: \WorkoutModel.date) private var workouts: [WorkoutModel]

    var body: some View {
        ScreenShell(
            eyebrow: "ANALYTICS · YOUR NUMBERS",
            title: "By the numbers."
        ) {
            summaryGrid
            weeklyChart
            recentList
        }
    }

    private var summary: AnalyticsSummary {
        AnalyticsService.summary(from: workouts)
    }

    // MARK: - Summary grid

    private var summaryGrid: some View {
        let s = summary
        return LazyVGrid(
            columns: [.init(.flexible(), spacing: Space.x2),
                      .init(.flexible(), spacing: Space.x2)],
            spacing: Space.x2
        ) {
            StatTile(label: "Current streak", value: "\(s.currentStreakDays)", unit: "d", accent: true)
            StatTile(label: "Longest streak", value: "\(s.longestStreakDays)", unit: "d")
            StatTile(label: "Workouts",       value: "\(s.totalWorkouts)")
            StatTile(label: "Total minutes",  value: "\(s.totalMinutes)", unit: "min")
            StatTile(label: "Avg duration",   value: String(format: "%.0f", s.averageDuration), unit: "min")
        }
    }

    // MARK: - Weekly chart

    private var weeklyChart: some View {
        let buckets = AnalyticsService.weeklyTotals(from: workouts)
        return AppSection(title: "Weekly minutes") {
            if buckets.isEmpty {
                Text("Log a workout to see weekly totals.")
                    .font(AppFont.ui(13))
                    .foregroundStyle(Color.textSecondary)
            } else {
                Chart(buckets) { b in
                    BarMark(
                        x: .value("Week", b.weekStart, unit: .weekOfYear),
                        y: .value("Minutes", b.totalMinutes)
                    )
                    .foregroundStyle(Color.accentVolt)
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(AppFont.mono(10))
                            .foregroundStyle(Color.textSecondary)
                        AxisGridLine().foregroundStyle(Color.appBorder)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel()
                            .font(AppFont.mono(10))
                            .foregroundStyle(Color.textSecondary)
                        AxisGridLine().foregroundStyle(Color.appBorder)
                    }
                }
                .frame(height: 200)
            }
        }
    }

    // MARK: - Recent list

    private var recentList: some View {
        let recent = Array(workouts.reversed().prefix(10))
        return AppSection(title: "Recent workouts") {
            if recent.isEmpty {
                Text("No workouts logged yet.")
                    .font(AppFont.ui(13))
                    .foregroundStyle(Color.textSecondary)
            } else {
                VStack(spacing: Space.x2) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, w in
                        HStack(spacing: Space.x3) {
                            Circle()
                                .fill(w.workoutType?.color ?? Color.accentVolt)
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    .font(AppFont.ui(14, weight: .semibold))
                                    .foregroundStyle(Color.textPrimary)
                                if let type = w.workoutType {
                                    Text(type.name)
                                        .font(AppFont.mono(11, weight: .medium))
                                        .tracking(0.8)
                                        .textCase(.uppercase)
                                        .foregroundStyle(Color.textTertiary)
                                }
                            }
                            Spacer()
                            Text("\(w.duration) min")
                                .font(AppFont.mono(13, weight: .bold))
                                .foregroundStyle(Color.accentInk)
                        }
                        if idx < recent.count - 1 {
                            RowDivider()
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    AnalyticsView()
        .modelContainer(try! Persistence.makePreviewContainer())
}
