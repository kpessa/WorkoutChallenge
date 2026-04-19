//
//  ProgressBarsView.swift
//  WorkoutChallenge
//
//  Port of the D3 ProgressChart.svelte weekly/monthly bar view. Stacked
//  bars by workout type, custom design-system SegmentedControl for the
//  granularity picker, chevron-based date navigator, dashed outlines for
//  proposed workouts, today highlight, and tap-to-edit.
//

import SwiftUI
import Charts
import SwiftData

struct ProgressBarsView: View {
    @Query(sort: \WorkoutModel.date) private var workouts: [WorkoutModel]
    @Query private var preferences: [UserPreferencesModel]

    enum Granularity: String, CaseIterable, Identifiable, Hashable {
        case week = "Week"
        case month = "Month"
        case rolling30 = "30d"
        var id: Self { self }
    }

    @State private var granularity: Granularity = .week
    // Left edge of the visible window. Semantics depend on granularity:
    // - week:      the chosen first-weekday of the week containing today
    // - month:     the 1st of the current calendar month
    // - rolling30: 29 days before today
    @State private var windowStart: Date = Date().startOfDay
    @State private var selection: DaySelection?

    /// A tapped day is routed to either the day-detail sheet (if there are
    /// existing workouts on that day) or straight into the log sheet.
    private struct DaySelection: Identifiable {
        let date: Date
        let proposedDuration: Int?
        let hasWorkouts: Bool
        var id: Date { date }
    }

    private var prefs: UserPreferencesModel? { preferences.first }

    private var window: ClosedRange<Date> {
        switch granularity {
        case .week:
            return windowStart ... windowStart.addingDays(6)
        case .rolling30:
            return windowStart ... windowStart.addingDays(29)
        case .month:
            let end = Calendar.current.date(
                byAdding: DateComponents(month: 1, day: -1),
                to: windowStart
            ) ?? windowStart.addingDays(29)
            return windowStart ... end
        }
    }

    private var windowDays: Int {
        window.lowerBound.daysUntil(window.upperBound) + 1
    }

    private func defaultWindowStart(for g: Granularity) -> Date {
        let today = Date().startOfDay
        switch g {
        case .week:
            var cal = Calendar.current
            cal.firstWeekday = prefs?.firstWeekday ?? 1
            return cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        case .month:
            return Calendar.current.dateInterval(of: .month, for: today)?.start ?? today
        case .rolling30:
            return today.addingDays(-29)
        }
    }

    private var breakdown: DailyBreakdown {
        AnalyticsService.dailyBreakdown(
            workouts: workouts,
            preferences: preferences.first,
            in: window
        )
    }

    /// True when the visible window contains today. Drives both the chart's
    /// today highlight (below) and the TODAY chip's on/off state.
    private var windowContainsToday: Bool {
        window.contains(Date().startOfDay)
    }

    var body: some View {
        ScreenShell(
            eyebrow: "MINUTES · BY WORKOUT TYPE",
            title: "By the bar."
        ) {
            granularityPicker
            dateNavigator
            chartCard
            if let s = summaryForWindow() {
                summaryRow(s)
            }
        }
        .sheet(item: $selection) { sel in
            if sel.hasWorkouts {
                DayWorkoutsSheet(date: sel.date, proposedDuration: sel.proposedDuration)
            } else {
                LogWorkoutSheet(date: sel.date, proposedDuration: sel.proposedDuration)
            }
        }
        .task {
            windowStart = defaultWindowStart(for: granularity)
        }
    }

    // MARK: - Granularity picker

    private var granularityPicker: some View {
        SegmentedControl(
            items: Granularity.allCases.map { (label: $0.rawValue, value: $0) },
            selection: $granularity
        )
        .onChange(of: granularity) { _, new in
            windowStart = defaultWindowStart(for: new)
        }
    }

    // MARK: - Date navigator

    /// Unified date navigator: `‹  [date range]  ›` centered, with a TODAY
    /// chip stacked beneath it. Tapping the center range or the chip jumps
    /// back to the window containing today. The chip is filled (Volt) when
    /// today is already in view and outlined otherwise — acting as both an
    /// at-a-glance indicator and a one-tap jump-back affordance for when
    /// you've paginated away.
    private var dateNavigator: some View {
        VStack(spacing: Space.x2) {
            HStack(spacing: Space.x3) {
                Button { shift(by: -1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(Color.appSurface2, in: Circle())
                        .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    withAnimation(Motion.base) {
                        windowStart = defaultWindowStart(for: granularity)
                    }
                } label: {
                    windowRangeLabel
                        .padding(.horizontal, Space.x4)
                        .padding(.vertical, Space.x2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Jump to today")

                Spacer()

                Button { shift(by: 1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(Color.appSurface2, in: Circle())
                        .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Chip(
                title: "Today",
                isOn: windowContainsToday,
                action: {
                    withAnimation(Motion.base) {
                        windowStart = defaultWindowStart(for: granularity)
                    }
                }
            )
            .accessibilityLabel(windowContainsToday
                                ? "Today is in this view"
                                : "Jump to today")
        }
    }

    @ViewBuilder
    private var windowRangeLabel: some View {
        Group {
            switch granularity {
            case .month:
                Text(windowStart, format: .dateTime.month(.wide).year())
            case .week, .rolling30:
                HStack(spacing: 6) {
                    Text(window.lowerBound, format: .dateTime.month(.abbreviated).day())
                    Text("–")
                    Text(window.upperBound, format: .dateTime.month(.abbreviated).day().year())
                }
            }
        }
        .font(AppFont.ui(14, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
    }

    /// `direction` is +1 or -1. Week advances 7 days, rolling30 advances 30
    /// days, month advances one calendar month to preserve 1st-of-month
    /// alignment across 28/30/31-day months.
    private func shift(by direction: Int) {
        withAnimation(Motion.base) {
            switch granularity {
            case .week:
                windowStart = windowStart.addingDays(7 * direction)
            case .rolling30:
                windowStart = windowStart.addingDays(30 * direction)
            case .month:
                windowStart = Calendar.current.date(
                    byAdding: .month, value: direction, to: windowStart
                ) ?? windowStart
            }
        }
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            chart
        }
        .appCard()
    }

    private var chart: some View {
        let b = breakdown
        let today = Date().startOfDay
        let todayInWindow = window.contains(today)
        let domain = b.colorMapping.map(\.name)
        let range = b.colorMapping.map { Color(hex: $0.hex) ?? .accentVolt }

        return Chart {
            if todayInWindow {
                RectangleMark(
                    xStart: .value("TodayStart", today),
                    xEnd: .value("TodayEnd", today.addingDays(1))
                )
                .foregroundStyle(Color.accentVolt.opacity(0.12))
            }

            ForEach(b.bars) { bar in
                BarMark(
                    x: .value("Day", bar.date, unit: .day),
                    y: .value("Minutes", bar.minutes)
                )
                .foregroundStyle(by: .value("Type", bar.typeName))
            }

            ForEach(b.proposed) { p in
                BarMark(
                    x: .value("Day", p.date, unit: .day),
                    y: .value("Proposed", p.minutes)
                )
                .foregroundStyle(Color.textTertiary.opacity(0.15))
            }
        }
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartXScale(domain: window.lowerBound ... window.upperBound.addingDays(1))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: granularity == .week ? 1 : 5)) { value in
                if granularity == .week, let date = value.as(Date.self) {
                    // Two-line stack: weekday abbrev on top, date number below.
                    AxisValueLabel(centered: true) {
                        VStack(spacing: 2) {
                            Text(date, format: .dateTime.weekday(.abbreviated))
                                .textCase(.uppercase)
                                .font(AppFont.mono(9))
                                .foregroundStyle(Color.textSecondary)
                            Text(date, format: .dateTime.day())
                                .font(AppFont.mono(10))
                                .foregroundStyle(Color.textSecondary)
                                .monospacedDigit()
                        }
                    }
                } else {
                    AxisValueLabel(format: .dateTime.day(), centered: true)
                        .font(AppFont.mono(10))
                        .foregroundStyle(Color.textSecondary)
                }
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        handleTap(at: location, proxy: proxy, geo: geo)
                    }
                dashedOutlines(for: b.proposed, proxy: proxy, geo: geo)
            }
        }
        .frame(height: 280)
    }

    private func handleTap(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plotAnchor = proxy.plotFrame else { return }
        let plotRect = geo[plotAnchor]
        let x = location.x - plotRect.origin.x
        guard x >= 0, x <= plotRect.width else { return }
        guard let date: Date = proxy.value(atX: x) else { return }
        let day = date.startOfDay
        let proposedMinutes = breakdown.proposed.first { $0.date == day }?.minutes
        let hasLogged = workouts.contains { Calendar.current.isDate($0.date, inSameDayAs: day) }
        selection = DaySelection(
            date: day,
            proposedDuration: proposedMinutes,
            hasWorkouts: hasLogged
        )
    }

    @ViewBuilder
    private func dashedOutlines(for proposed: [DailyProposed], proxy: ChartProxy, geo: GeometryProxy) -> some View {
        if let plotAnchor = proxy.plotFrame {
            let plotRect = geo[plotAnchor]
            let barWidth = max(6, plotRect.width / CGFloat(windowDays) * 0.7)
            Path { path in
                for p in proposed {
                    // Center the outline on the day by offsetting 12h.
                    let dayCenter = p.date.addingTimeInterval(12 * 3600)
                    guard let xCenter = proxy.position(forX: dayCenter),
                          let yTop = proxy.position(forY: p.minutes),
                          let yBase = proxy.position(forY: 0) else { continue }
                    let rect = CGRect(
                        x: plotRect.origin.x + xCenter - barWidth / 2,
                        y: plotRect.origin.y + yTop,
                        width: barWidth,
                        height: yBase - yTop
                    )
                    path.addRect(rect)
                }
            }
            .stroke(Color.textSecondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .allowsHitTesting(false)
        }
    }

    // MARK: - Summary

    /// Quick totals for the visible window — rendered as a row of StatTiles
    /// under the chart so you can see the window's totals at a glance.
    private struct WindowSummary {
        var totalMinutes: Int
        var daysLogged: Int
        var peakMinutes: Int
    }

    private func summaryForWindow() -> WindowSummary? {
        let inWindow = workouts.filter { window.contains($0.date.startOfDay) }
        guard !inWindow.isEmpty else { return nil }
        let total = inWindow.reduce(0) { $0 + $1.duration }
        let byDay = Dictionary(grouping: inWindow) { $0.date.startOfDay }
        let days = byDay.keys.count
        let peak = byDay.values
            .map { $0.reduce(0) { $0 + $1.duration } }
            .max() ?? 0
        return WindowSummary(totalMinutes: total, daysLogged: days, peakMinutes: peak)
    }

    private func summaryRow(_ s: WindowSummary) -> some View {
        HStack(spacing: Space.x2) {
            StatTile(label: "Total", value: "\(s.totalMinutes)", unit: "min", accent: true)
            StatTile(label: "Days",  value: "\(s.daysLogged)",   unit: "d")
            StatTile(label: "Peak",  value: "\(s.peakMinutes)",  unit: "min")
        }
    }
}

#Preview {
    ProgressBarsView()
        .modelContainer(try! Persistence.makePreviewContainer())
        .environmentObject(HealthKitService())
}
