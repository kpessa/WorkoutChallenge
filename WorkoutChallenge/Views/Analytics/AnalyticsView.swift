//
//  AnalyticsView.swift
//  WorkoutChallenge
//
//  Port of AnalyticsPanel.svelte + WeeklyAnalyticsPanel.svelte. Shows
//  summary stats (StatTiles), a weekly bar chart (Swift Charts), and a
//  recent workouts list. Fully migrated to the design-system ScreenShell.
//

import SwiftUI
import SwiftData

struct AnalyticsView: View {
    @Query(sort: \WorkoutModel.date) private var workouts: [WorkoutModel]
    @Query private var preferencesList: [UserPreferencesModel]

    private var firstWeekday: Int { preferencesList.first?.firstWeekday ?? 1 }

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

    // MARK: - Weekly chart (Design Meld)

    /// The current calendar week aligned to the user's firstWeekday pref.
    /// Each bar is one day — Volt + 1.5pt ink border when logged, surface2
    /// + 1pt border when empty. Callout (minute count) floats above the
    /// tallest bar(s). Per the meld, this replaces the single solid-block
    /// weekly-totals bar that used to live here.
    private struct DayBar: Identifiable {
        let date: Date
        let minutes: Int
        var id: Date { date }
    }

    private var currentWeekDays: [DayBar] {
        var cal = Calendar.current
        cal.firstWeekday = firstWeekday
        let today = Date().startOfDay
        guard let start = cal.dateInterval(of: .weekOfYear, for: today)?.start else {
            return []
        }
        let days = (0..<7).map { start.addingDays($0) }
        let totals: [Date: Int] = Dictionary(
            grouping: workouts,
            by: { $0.date.startOfDay }
        ).mapValues { $0.reduce(0) { $0 + $1.duration } }
        return days.map { DayBar(date: $0, minutes: totals[$0] ?? 0) }
    }

    private var weeklyChart: some View {
        let days = currentWeekDays
        let peak = max(days.map(\.minutes).max() ?? 0, 1)
        let hasData = days.contains { $0.minutes > 0 }
        return AppSection(title: "Weekly minutes") {
            if !hasData {
                Text("Log a workout to see this week's minutes.")
                    .font(AppFont.ui(13))
                    .foregroundStyle(Color.textSecondary)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(days) { day in
                        weekBar(day: day, peak: peak)
                    }
                }
                .frame(height: 160)
            }
        }
    }

    @ViewBuilder
    private func weekBar(day: DayBar, peak: Int) -> some View {
        let isLogged = day.minutes > 0
        let isPeak = day.minutes == peak && isLogged
        VStack(spacing: 4) {
            // Callout sits above the tallest bar; reserve the slot on other
            // bars so they all share a baseline height.
            Text(isPeak ? "\(day.minutes)m" : " ")
                .font(AppFont.mono(9, weight: .bold))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
            GeometryReader { geo in
                let ratio = isLogged
                    ? max(0.08, Double(day.minutes) / Double(peak))
                    : 0.28
                VStack {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isLogged ? Color.accentVolt : Color.appSurface2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isLogged ? Color.textPrimary : Color.appBorder,
                                        lineWidth: isLogged ? 1.5 : 1)
                        )
                        .frame(height: geo.size.height * ratio)
                }
            }
            Text(day.date, format: .dateTime.weekday(.narrow))
                .font(AppFont.mono(10, weight: isPeak ? .bold : .medium))
                .foregroundStyle(isPeak ? Color.textPrimary : Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
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
