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
import HealthKit

struct AnalyticsView: View {
    @Query(sort: \WorkoutModel.date) private var workouts: [WorkoutModel]
    @Query private var preferencesList: [UserPreferencesModel]
    @EnvironmentObject private var healthKit: HealthKitService

    private var firstWeekday: Int { preferencesList.first?.firstWeekday ?? 1 }

    /// HR-refined weekly dose, filled by the `.task` below. Nil until the
    /// async HealthKit pass completes — `dose` falls back to the
    /// synchronous type-based estimate so the meter renders immediately.
    @State private var refinedDose: WeeklyDoseService.Result?
    @State private var showDoseInfo = false

    var body: some View {
        ScreenShell(
            eyebrow: "ANALYTICS · YOUR NUMBERS",
            title: "By the numbers."
        ) {
            summaryGrid
            weeklyDoseSection
            weeklyChart
            recentList
        }
        .task(id: weekStart) { await refineDose() }
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

    // MARK: - Weekly dose (guideline overlay)

    /// Start of the current week, aligned to the user's firstWeekday pref.
    private var weekStart: Date {
        var cal = Calendar.current
        cal.firstWeekday = firstWeekday
        let today = Date().startOfDay
        return cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
    }

    /// The week's moderate-equivalent minutes. Prefers the HR-refined
    /// result once it lands; otherwise the synchronous type-based estimate.
    private var dose: WeeklyDoseService.Result {
        refinedDose ?? WeeklyDoseService.compute(workouts: workouts, weekStart: weekStart)
    }

    private var weeklyDoseSection: some View {
        let d = dose
        return AppSection(title: "Weekly dose") {
            VStack(alignment: .leading, spacing: Space.x3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
                    Text("\(d.moderateEquivalentMinutes)")
                        .font(AppFont.ui(34, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .monospacedDigit()
                    Text("min / week")
                        .font(AppFont.ui(13))
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    Chip(title: bandChipTitle(d.band), isOn: true)
                }
                doseMeter(d)
                Text(benefitLine(d))
                    .font(AppFont.ui(13))
                    .foregroundStyle(Color.textSecondary)
                Button {
                    showDoseInfo = true
                } label: {
                    Text("What counts & why — sources")
                        .font(AppFont.mono(11, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(Color.accentInk)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showDoseInfo) { doseInfoSheet }
    }

    /// Horizontal meter scaled so 300 min = full width, with a tick at the
    /// 150-min guideline minimum. Fill colour tracks the benefit band.
    @ViewBuilder
    private func doseMeter(_ d: WeeklyDoseService.Result) -> some View {
        let target = 300.0
        let frac = min(1.0, Double(d.moderateEquivalentMinutes) / target)
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.appSurface2)
                    Capsule()
                        .fill(meterColor(d.band))
                        .frame(width: max(6, w * frac))
                    // 150-min guideline tick at the 50% mark.
                    Rectangle()
                        .fill(Color.textPrimary.opacity(0.55))
                        .frame(width: 1.5)
                        .offset(x: w * 0.5)
                }
            }
            .frame(height: 12)
            HStack {
                doseTick("0")
                Spacer()
                doseTick("150")
                Spacer()
                doseTick("300")
            }
        }
    }

    private func doseTick(_ label: String) -> some View {
        Text(label)
            .font(AppFont.mono(9, weight: .medium))
            .foregroundStyle(Color.textTertiary)
            .monospacedDigit()
    }

    private func bandChipTitle(_ band: WeeklyDoseService.Band) -> String {
        switch band {
        case .building: return "Building"
        case .full:     return "Full benefit"
        case .extra:    return "Extra benefit"
        }
    }

    private func meterColor(_ band: WeeklyDoseService.Band) -> Color {
        switch band {
        case .building: return Color.warn
        case .full:     return Color.accentVolt
        case .extra:    return Color.accentNeon
        }
    }

    /// Benefit copy. Numbers are observational associations from large
    /// cohort studies (Arem 2015; Garcia 2023) — see `doseInfoSheet`.
    private func benefitLine(_ d: WeeklyDoseService.Result) -> String {
        let vigNote = d.vigorousEquivalentMinutes > 0
            ? " Vigorous minutes count double, so your harder sessions are pulling weight here."
            : ""
        switch d.band {
        case .building:
            return "Any activity counts — even below 150 min/week is linked to ~20% lower all-cause mortality vs being inactive. Keep building.\(vigNote)"
        case .full:
            return "You've passed 150 min/week — the dose linked to ~31–33% lower all-cause mortality vs being inactive.\(vigNote)"
        case .extra:
            return "Past 300 min/week — benefits keep rising toward ~39% lower mortality, with no known harm at higher volumes.\(vigNote)"
        }
    }

    private var doseInfoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x4) {
                    doseInfoBlock(
                        title: "The guideline",
                        body: "150–300 min/week of moderate activity (or 75–150 min vigorous), plus muscle-strengthening on 2+ days. Vigorous activity counts double, and there's no minimum bout length — every minute counts. (US Physical Activity Guidelines 2018, 2nd ed.; WHO 2020.)"
                    )
                    doseInfoBlock(
                        title: "How a minute is counted",
                        body: "Each workout is rated moderate or vigorous from its heart-rate zones when available, otherwise from its activity type. Vigorous minutes (≈6+ METs — running, hard skating, intervals) count double toward the target; light activity like gentle yoga doesn't count toward the aerobic dose."
                    )
                    doseInfoBlock(
                        title: "What the dose buys you",
                        body: "Compared with being inactive: ~20% lower all-cause mortality even below the minimum, ~31–33% at ~150 min/week, plateauing around ~39% at 3–5× the minimum. At the guideline dose, cardiovascular-disease mortality is ~29% lower and cancer mortality ~15% lower. Benefits rise fastest at the start and show no harm at high volumes."
                    )
                    doseInfoBlock(
                        title: "The fine print",
                        body: "These are associations from large observational cohort studies (Arem 2015; Garcia 2023; Paluch 2022; O'Donovan 2017) — they show strong, consistent links, not proof of cause, and individual results vary. This is general information, not medical advice."
                    )
                }
                .padding(Space.x4)
            }
            .background(Color.appBg)
            .navigationTitle("Weekly dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showDoseInfo = false }
                }
            }
        }
    }

    private func doseInfoBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppFont.mono(11, weight: .bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.textTertiary)
            Text(body)
                .font(AppFont.ui(14))
                .foregroundStyle(Color.textPrimary)
        }
    }

    /// HR-refined dose pass. For each HealthKit-backed workout in the week,
    /// fetch its HR samples → zone breakdown and recompute, overriding the
    /// type-based intensity estimate. No-ops gracefully when HealthKit is
    /// unavailable or a workout has no HR data.
    @MainActor
    private func refineDose() async {
        guard healthKit.isAvailable, let prefs = preferencesList.first else { return }
        let birthdate = healthKit.fetchBirthdateComponents()
        let maxHR = MaxHRService.resolve(preferences: prefs, birthdate: birthdate)
        let restingHR = Double(prefs.restingHRBPM)

        let start = weekStart.startOfDay
        let end = start.addingDays(7)
        let weekWorkouts = workouts.filter {
            let day = $0.date.startOfDay
            return day >= start && day < end && $0.healthKitUUID != nil
        }
        guard !weekWorkouts.isEmpty else { return }

        var zones: [UUID: ZoneBreakdown] = [:]
        for w in weekWorkouts {
            guard let uuid = w.healthKitUUID,
                  let hk = await healthKit.fetchWorkout(uuid: uuid) else { continue }
            if Task.isCancelled { return }
            let samples = await healthKit.fetchHeartRateSamples(for: hk)
            let zb = HeartRateAnalysis.breakdown(
                samples: samples,
                maxHR: maxHR,
                restingHR: restingHR,
                workoutEnd: hk.endDate
            )
            if zb.totalSeconds > 0 { zones[w.id] = zb }
        }
        if Task.isCancelled || zones.isEmpty { return }
        refinedDose = WeeklyDoseService.compute(
            workouts: workouts,
            weekStart: weekStart,
            zonesByWorkoutID: zones
        )
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
