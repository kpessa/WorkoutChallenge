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
import Combine
import Charts
import SwiftData

struct ProgressBarsView: View {
    @Query(sort: \WorkoutModel.date) private var workouts: [WorkoutModel]
    @Query private var preferences: [UserPreferencesModel]
    @Query private var challenges: [ChallengeModel]

    // Needed to trigger pull-to-refresh imports from Apple Health. Imports
    // add rows via `context.insert`, which @Query picks up automatically,
    // so the bars repaint once the refresh finishes.
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var healthKit: HealthKitService

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

    /// Resolved schedule config — active challenge if one exists, else
    /// prefs. See `ChallengeService.activeConfig(...)`.
    private var activeConfig: ChallengeService.ActiveConfig? {
        ChallengeService.activeConfig(challenges: challenges, prefs: prefs)
    }

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
            config: activeConfig,
            in: window
        )
    }

    /// True when the visible window contains today. Drives both the chart's
    /// today highlight (below) and the TODAY chip's on/off state.
    private var windowContainsToday: Bool {
        window.contains(Date().startOfDay)
    }

    private var currentChallenge: ChallengeModel? {
        ChallengeService.currentChallenge(in: challenges)
    }

    /// Extracted to its own computed property because inlining the
    /// ternary `healthKit.isAvailable ? { await refreshFromHealth() } : nil`
    /// directly in the `ScreenShell(...)` call blows up Swift's type
    /// checker ("Failed to produce diagnostic for expression") when the
    /// same call also supplies a large trailing ViewBuilder. Giving the
    /// optional an explicit type here lets the outer call type-check
    /// cheaply.
    private var refreshHandler: (() async -> Void)? {
        guard healthKit.isAvailable else { return nil }
        return { await refreshFromHealth() }
    }

    var body: some View {
        ScreenShell(
            eyebrow: "MINUTES · BY WORKOUT TYPE",
            title: "By the bar.",
            onRefresh: refreshHandler
        ) {
            CelestialStrip()
            if let current = currentChallenge, current.state == .paused {
                PausedBanner(
                    challenge: current,
                    onResume: { ChallengeService.resume(current) }
                )
            }
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

    /// Unified date navigator: `‹  [date range]  ›` centered. The center
    /// range is a two-line stack — top line is the date span (with weekday
    /// abbreviations on Week view), bottom line is "WEEK X OF 13" context
    /// for the active challenge. Tapping the range jumps back to the
    /// window containing today.
    ///
    /// The TODAY chip only appears when the user has paginated *away* from
    /// today — when today is already in view the filled chip was visual
    /// noise that pushed the chart off the screen. Jumping back via the
    /// center range button still works in either state.
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

            // Only surface the chip as a jump-back affordance when we've
            // navigated off today. Hiding it in the default state keeps the
            // Bars tab on one screen.
            if !windowContainsToday {
                Chip(
                    title: "Today",
                    isOn: false,
                    action: {
                        withAnimation(Motion.base) {
                            windowStart = defaultWindowStart(for: granularity)
                        }
                    }
                )
                .accessibilityLabel("Jump to today")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    @ViewBuilder
    private var windowRangeLabel: some View {
        VStack(spacing: 2) {
            Group {
                switch granularity {
                case .month:
                    Text(windowStart, format: .dateTime.month(.wide).year())
                case .week:
                    // Week view leads with weekday abbrevs so the user can
                    // orient themselves without counting days ("Sun, Apr 19
                    // – Sat, Apr 25" rather than "Apr 19 – Apr 25").
                    HStack(spacing: 4) {
                        Text(window.lowerBound, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        Text("–")
                        Text(window.upperBound, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    }
                case .rolling30:
                    HStack(spacing: 6) {
                        Text(window.lowerBound, format: .dateTime.month(.abbreviated).day())
                        Text("–")
                        Text(window.upperBound, format: .dateTime.month(.abbreviated).day().year())
                    }
                }
            }
            .font(AppFont.ui(14, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

            // Challenge context: "WEEK 3 OF 13". Only shown on Week view
            // when the visible window overlaps the active challenge — for
            // Month / 30d the math is ambiguous (a month spans 4–5 weeks),
            // and paginating past the challenge bounds shouldn't invent a
            // "week 14 of 13" reading.
            if granularity == .week, let ctx = challengeContextLabel {
                Text(LocalizedStringKey(ctx))
                    .font(AppFont.mono(10, weight: .medium))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    /// "Week 3 of 13" subtext for the date navigator on Week view.
    /// Returns nil when no active/paused challenge exists or the visible
    /// week falls outside the challenge's day range.
    private var challengeContextLabel: String? {
        guard let challenge = currentChallenge else { return nil }
        let totalWeeks = Int(ceil(Double(challenge.totalDays) / 7.0))
        let challengeStart = challenge.startDate.startOfDay
        // Compare midweek (windowStart + 3) so a week that straddles the
        // challenge start maps to whichever week contains the majority of
        // its days rather than flipping on the first/last day.
        let midweek = windowStart.addingDays(3)
        let dayOfChallenge = challengeStart.daysUntil(midweek) + 1
        guard dayOfChallenge >= 1, dayOfChallenge <= challenge.totalDays else {
            return nil
        }
        let week = (dayOfChallenge - 1) / 7 + 1
        return "Week \(week) of \(totalWeeks)"
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

    /// Per-day aggregate for the window: total minutes + the distinct
    /// workout-type colors logged that day. Bars render as Volt (brand
    /// hero) and the per-type colors appear as small dots beneath as
    /// metadata — the "Design Meld" rule for By the bar.
    private struct DayAggregate: Identifiable {
        let date: Date
        let total: Int
        let colors: [Color]
        var id: Date { date }
    }

    private func dayAggregates(from bars: [DailyTypeBar]) -> [DayAggregate] {
        Dictionary(grouping: bars, by: { $0.date })
            .map { (date, rows) in
                let colors = rows.map { Color(hex: $0.colorHex) ?? .accentVolt }
                let total = rows.reduce(0) { $0 + $1.minutes }
                return DayAggregate(date: date, total: total, colors: colors)
            }
            .sorted { $0.date < $1.date }
    }

    private var chart: some View {
        let b = breakdown
        let today = Date().startOfDay
        let todayInWindow = window.contains(today)
        let days = dayAggregates(from: b.bars)

        return Chart {
            if todayInWindow {
                RectangleMark(
                    xStart: .value("TodayStart", today),
                    xEnd: .value("TodayEnd", today.addingDays(1))
                )
                .foregroundStyle(Color.accentVolt.opacity(0.12))
            }

            // Meld: every bar is Volt (brand). Per-type color moves to
            // small dots beneath the bar — metadata, not the hero.
            ForEach(days) { d in
                BarMark(
                    x: .value("Day", d.date, unit: .day),
                    y: .value("Minutes", d.total)
                )
                .foregroundStyle(Color.accentVolt)
                .cornerRadius(3)
            }

            ForEach(b.proposed) { p in
                BarMark(
                    x: .value("Day", p.date, unit: .day),
                    y: .value("Proposed", p.minutes)
                )
                .foregroundStyle(Color.textTertiary.opacity(0.15))
            }
        }
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
                inkBorders(for: days, proxy: proxy, geo: geo)
                activityDots(for: days, proxy: proxy, geo: geo)
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

    /// Per-day Volt bar gets a 1.5pt ink stroke for edge definition — the
    /// single most important rule of the Design Meld on light surfaces.
    @ViewBuilder
    private func inkBorders(for days: [DayAggregate], proxy: ChartProxy, geo: GeometryProxy) -> some View {
        if let plotAnchor = proxy.plotFrame {
            let plotRect = geo[plotAnchor]
            let barWidth = max(6, plotRect.width / CGFloat(windowDays) * 0.7)
            Path { path in
                for d in days where d.total > 0 {
                    let dayCenter = d.date.addingTimeInterval(12 * 3600)
                    guard let xCenter = proxy.position(forX: dayCenter),
                          let yTop = proxy.position(forY: d.total),
                          let yBase = proxy.position(forY: 0) else { continue }
                    let rect = CGRect(
                        x: plotRect.origin.x + xCenter - barWidth / 2,
                        y: plotRect.origin.y + yTop,
                        width: barWidth,
                        height: yBase - yTop
                    )
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 3, height: 3))
                }
            }
            .stroke(Color.textPrimary, lineWidth: 1.5)
            .allowsHitTesting(false)
        }
    }

    /// Small activity-color dot(s) under each bar's baseline — the per-type
    /// color becomes metadata instead of the hero fill.
    @ViewBuilder
    private func activityDots(for days: [DayAggregate], proxy: ChartProxy, geo: GeometryProxy) -> some View {
        if let plotAnchor = proxy.plotFrame {
            let plotRect = geo[plotAnchor]
            let dotSize: CGFloat = 5
            let dotGap: CGFloat = 2
            ForEach(days) { d in
                if d.total > 0, !d.colors.isEmpty {
                    let dayCenter = d.date.addingTimeInterval(12 * 3600)
                    if let xCenter = proxy.position(forX: dayCenter),
                       let yBase = proxy.position(forY: 0) {
                        let totalWidth = CGFloat(d.colors.count) * dotSize
                            + CGFloat(max(0, d.colors.count - 1)) * dotGap
                        HStack(spacing: dotGap) {
                            ForEach(Array(d.colors.enumerated()), id: \.offset) { _, c in
                                Circle()
                                    .fill(c)
                                    .overlay(Circle().stroke(Color.textPrimary, lineWidth: 0.75))
                                    .frame(width: dotSize, height: dotSize)
                            }
                        }
                        .frame(width: totalWidth, height: dotSize)
                        .position(
                            x: plotRect.origin.x + xCenter,
                            y: plotRect.origin.y + yBase - dotSize / 2 - 3
                        )
                    }
                }
            }
        }
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

    // MARK: - Pull-to-refresh

    /// Pull-to-refresh handler. Re-imports from Apple Health using the
    /// active challenge's start date as the lower bound (matching the
    /// Settings "Import from Apple Health" button). No-ops quietly when
    /// HealthKit isn't available or the user hasn't opted in via Settings
    /// yet — the refresh gesture still works as a pleasant visual
    /// acknowledgement, but nothing talks to HK.
    ///
    /// The `HealthKitService.importSinceChallengeStart` helper handles the
    /// concurrent-import guard, silent re-auth, and cooldown logic — we
    /// pass no cooldown here because a deliberate pull-to-refresh tap
    /// should always attempt to fetch the latest samples.
    private func refreshFromHealth() async {
        // Prefer the active challenge's start so pull-to-refresh on an
        // in-progress challenge imports from the first day the user
        // committed — not wherever prefs happens to sit. Falls back to
        // prefs between challenges and finally to a 90-day window if
        // neither exists.
        let start = activeConfig?.startDate
            ?? Calendar.current.date(byAdding: .day, value: -90, to: Date())
            ?? Date.distantPast
        await healthKit.importSinceChallengeStart(
            from: start,
            into: modelContext
        )
    }
}

#Preview {
    ProgressBarsView()
        .modelContainer(try! Persistence.makePreviewContainer())
        .environmentObject(HealthKitService())
}
