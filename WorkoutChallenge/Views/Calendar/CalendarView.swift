//
//  CalendarView.swift
//  WorkoutChallenge
//
//  iOS mirror of Calendar.svelte. The screen is split into three bands:
//
//    1. A hero with the sigmoid curve + progress chip + VoltProgress bar
//    2. A compact 90-day DayCell grid (the whole challenge at a glance)
//    3. A scrollable week-grouped list of days — logged ones on their
//       actual date (a Sunday workout shows on Sunday, never "banked"
//       onto Monday's slot), plus proposed days front-loaded to the
//       earliest still-open days in the current/future week
//
//  Both the grid and list pull from `WeeklyScheduleService` so they stay
//  in lock-step with the bar-graph view on the Progress tab. Tapping any
//  day (grid or list) opens the logging sheet.
//

import SwiftUI
import SwiftData

struct CalendarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var preferencesList: [UserPreferencesModel]
    @Query private var challenges: [ChallengeModel]
    @Query(sort: \WorkoutModel.date, order: .reverse) private var workouts: [WorkoutModel]

    @State private var selection: DaySelection?

    private struct DaySelection: Identifiable {
        let date: Date
        let proposedDuration: Int?
        let hasWorkouts: Bool
        var id: Date { date }
    }

    private var prefs: UserPreferencesModel? { preferencesList.first }

    /// Resolved schedule config — reads from the active challenge when
    /// one is current, falling back to prefs between challenges. Views
    /// should thread this through rather than reading prefs directly so
    /// edits to the active challenge take effect immediately.
    private var activeConfig: ChallengeService.ActiveConfig? {
        ChallengeService.activeConfig(challenges: challenges, prefs: prefs)
    }

    var body: some View {
        Group {
            if let config = activeConfig {
                content(config: config)
            } else {
                ZStack {
                    Color.appBg.ignoresSafeArea()
                    ProgressView("Loading…").tint(.accentVolt)
                }
            }
        }
        .sheet(item: $selection) { sel in
            if sel.hasWorkouts {
                DayWorkoutsSheet(date: sel.date, proposedDuration: sel.proposedDuration)
            } else {
                LogWorkoutSheet(date: sel.date, proposedDuration: sel.proposedDuration)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(config: ChallengeService.ActiveConfig) -> some View {
        let schedule = SigmoidalService.generateSchedule(
            startDate: config.startDate,
            daysPerWeek: config.daysPerWeek
        )
        let weeks = WeeklyScheduleService.weeks(
            startDate: config.startDate,
            sigmoid: config.sigmoid,
            firstWeekday: config.firstWeekday,
            workouts: workouts,
            schedule: schedule
        )
        // Distinct dates with at least one workout — used both for the
        // 90-day grid's per-slot completion (a scheduled day lights up
        // when a workout was logged on that exact date) and for the
        // hero's "X completed" counter. Mirrors the bar graph's "bar
        // present = day logged" rule.
        let loggedDateSet: Set<Date> = Set(workouts.map { $0.date.startOfDay })
        let today = Date().startOfDay
        // `currentDay` is the scheduled-workout number, not a calendar-day
        // count. The challenge is 90 *workouts* — at Mon-Fri pace that's
        // 18 calendar weeks, not 90 calendar days — so both the hero
        // ("Day N of 90") and the grid need to agree with the schedule
        // list's numbering (ScheduledDay.dayNumber). If today lands on a
        // scheduled day, use its dayNumber directly. On an off-schedule
        // day (e.g. Saturday when the picks are Mon-Fri, or Sunday before
        // Week 1's Monday) fall back to the count of scheduled days up to
        // and including today so progress reads as "last scheduled day
        // reached" rather than jumping forward to the next one.
        let currentDay: Int = {
            if let match = schedule.first(where: {
                Calendar.current.isDate($0.date, inSameDayAs: today)
            }) {
                return match.dayNumber
            }
            let passed = schedule.filter { $0.date.startOfDay <= today }.count
            return max(1, min(90, passed))
        }()
        let completedCount = loggedDateSet.count
        let progressFraction = Double(currentDay) / 90.0

        ScreenShell(
            eyebrow: "DAY \(currentDay) OF 90 · KEEP GOING",
            title: "Ninety days."
        ) {
            // HERO
            heroCard(currentDay: currentDay, completed: completedCount, progress: progressFraction)

            // COMPACT GRID
            gridCard(
                config: config,
                schedule: schedule,
                currentDay: currentDay,
                today: today,
                loggedDateSet: loggedDateSet
            )

            // SCHEDULE LIST (week-grouped)
            scheduleList(weeks: weeks, config: config)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroCard(currentDay: Int, completed: Int, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your curve")
                    .tsEyebrow()
                    .foregroundStyle(Color.textTertiary)
                Spacer()
                Chip(title: completed >= currentDay - 1 ? "On track" : "Catch up",
                     isOn: completed >= currentDay - 1)
            }

            SigmoidCurve(progress: progress)
                .frame(height: 120)

            VStack(alignment: .leading, spacing: Space.x2) {
                VoltProgress(progress: progress)
                HStack {
                    Text("\(currentDay) of 90 days").tsCaption()
                    Spacer()
                    Text("\(completed) completed")
                        .font(AppFont.mono(11, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                }
            }
        }
        .appCard()
    }

    // MARK: - 90-day grid

    @ViewBuilder
    private func gridCard(
        config: ChallengeService.ActiveConfig,
        schedule: [ScheduledDay],
        currentDay: Int,
        today: Date,
        loggedDateSet: Set<Date>
    ) -> some View {
        AppSection(title: "90-day grid") {
            VStack(alignment: .leading, spacing: Space.x3) {
                phaseBands(currentDay: currentDay)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 15),
                    spacing: 4
                ) {
                    ForEach(schedule) { day in
                        Button {
                            selection = makeSelection(for: day.date, config: config)
                        } label: {
                            DayCell(
                                day: day.dayNumber,
                                state: gridState(
                                    for: day,
                                    today: today,
                                    loggedOnDate: loggedDateSet.contains(day.date.startOfDay)
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Design Meld (Lifecycle + Celestial, Part B): three moons across the
    /// 90-day challenge. Each card pairs a moon glyph with the phase label
    /// and day range — 90 ≈ 3 synodic lunar cycles, so each 30-day band
    /// reads as roughly one moon. The phase the user is currently in is
    /// the only one filled; the others fade.
    @ViewBuilder
    private func phaseBands(currentDay: Int) -> some View {
        let phases: [(label: String, glyph: CelestialService.MoonPhase,
                      range: ClosedRange<Int>, ordinal: String)] = [
            ("Habit",    .new,   1...30,  "Moon 1"),
            ("Growth",   .full,  31...60, "Moon 2"),
            ("Plateau",  .lastQuarter, 61...90, "Moon 3")
        ]
        HStack(spacing: Space.x2) {
            ForEach(phases, id: \.label) { phase in
                let active = phase.range.contains(currentDay)
                phaseCard(
                    title: phase.label,
                    ordinal: phase.ordinal,
                    range: String.localizedStringWithFormat(
                        NSLocalizedString("Days %lld–%lld",
                                           comment: "Phase card day range (lower–upper)"),
                        phase.range.lowerBound, phase.range.upperBound),
                    glyph: phase.glyph,
                    active: active
                )
            }
        }
    }

    @ViewBuilder
    private func phaseCard(
        title: String,
        ordinal: String,
        range: String,
        glyph: CelestialService.MoonPhase,
        active: Bool
    ) -> some View {
        let inkOnVolt = Color(red: 0.04, green: 0.04, blue: 0.04)
        VStack(spacing: 4) {
            MoonGlyph(
                phase: glyph,
                size: 22,
                chalkColor: active ? inkOnVolt : Color.appSurface,
                darkColor: active ? Color.textPrimary : Color.textPrimary,
                strokeColor: active ? inkOnVolt : Color.textPrimary,
                strokeWidth: active ? 1.5 : 1
            )
            Text(LocalizedStringKey(ordinal))
                .font(AppFont.mono(8, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(active ? inkOnVolt : Color.textTertiary)
            Text(LocalizedStringKey(title))
                .font(AppFont.ui(11, weight: .bold))
                .foregroundStyle(active ? inkOnVolt : Color.textTertiary)
            // `range` is pre-formatted via localizedStringWithFormat upstream,
            // so render verbatim.
            Text(range)
                .font(AppFont.mono(8, weight: .medium))
                .foregroundStyle(active ? inkOnVolt : Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.x2)
        .padding(.horizontal, 4)
        .background(active ? Color.accentVolt : Color.appSurface,
                    in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(active ? inkOnVolt : Color.appBorder,
                        lineWidth: active ? 1.5 : 1)
        )
    }

    /// Grid state per scheduled slot. A slot is "completed" iff a workout
    /// was logged on that exact date — off-day workouts (e.g. Sunday when
    /// the picks are Mon/Wed/Fri) don't flip a scheduled slot; they show
    /// up in the Schedule list below on their actual date and count toward
    /// the week's target there. This keeps the grid in lock-step with the
    /// bar graph (one green cell per day that has a bar).
    ///
    /// Past/today/upcoming is determined by comparing the slot's calendar
    /// date to `today` — not by comparing `dayNumber` to a scalar — because
    /// `dayNumber` is a scheduled-workout index, not a calendar offset, so
    /// those two spaces diverge when the start date lands on an off-day.
    private func gridState(
        for day: ScheduledDay,
        today: Date,
        loggedOnDate: Bool
    ) -> DayCell.State {
        if loggedOnDate { return .completed }
        let slot = day.date.startOfDay
        let todayStart = today.startOfDay
        if Calendar.current.isDate(slot, inSameDayAs: todayStart) { return .today }
        if slot < todayStart { return .missed }
        return .upcoming
    }

    // MARK: - Schedule list (week-grouped)

    @ViewBuilder
    private func scheduleList(
        weeks: [WeeklyScheduleService.Week],
        config: ChallengeService.ActiveConfig
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Schedule").tsEyebrow().foregroundStyle(Color.textTertiary)
            LazyVStack(spacing: Space.x4) {
                ForEach(weeks) { week in
                    weekSection(week: week, config: config)
                }
            }
        }
    }

    @ViewBuilder
    private func weekSection(
        week: WeeklyScheduleService.Week,
        config: ChallengeService.ActiveConfig
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            weekHeader(week: week)
            VStack(spacing: Space.x2) {
                ForEach(week.entries) { entry in
                    entryRow(entry: entry, config: config)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = makeSelection(for: entry.date, config: config)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func weekHeader(week: WeeklyScheduleService.Week) -> some View {
        let isPast = week.weekEnd < Date().startOfDay
        let statusLabel: String = {
            if week.isComplete { return "Complete" }
            if isPast { return "Missed" }
            return "\(week.completedCount) of \(week.targetCount)"
        }()
        HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
            Text(
                "\(week.weekStart.formatted(.dateTime.month(.abbreviated).day())) – \(week.weekEnd.formatted(.dateTime.month(.abbreviated).day()))"
            )
            .font(AppFont.ui(13, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
            Spacer()
            Chip(title: statusLabel, isOn: week.isComplete)
        }
        .padding(.horizontal, Space.x1)
    }

    private func entryRow(
        entry: WeeklyScheduleService.Entry,
        config: ChallengeService.ActiveConfig
    ) -> some View {
        let isToday = Calendar.current.isDateInToday(entry.date)
        let isComplete = entry.isLogged && entry.loggedMinutes >= entry.targetMinutes
        let entryCount = entry.loggedWorkouts.count

        return HStack(alignment: .center, spacing: Space.x3) {
            // Status pill — Volt fill when the day's target is met;
            // outlined when partially logged; dashed outline when proposed.
            ZStack {
                Circle()
                    .fill(isComplete ? Color.accentVolt : Color.clear)
                    .overlay(
                        Circle().stroke(
                            isComplete ? Color.accentVolt : Color.appBorder,
                            style: StrokeStyle(
                                lineWidth: 1.5,
                                dash: entry.isProposed ? [3, 2] : []
                            )
                        )
                    )
                    .frame(width: 28, height: 28)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.04))
                } else if entry.isLogged {
                    // Partially logged — small dot signal
                    Circle()
                        .fill(Color.accentInk)
                        .frame(width: 8, height: 8)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.x2) {
                    Text(entry.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(AppFont.ui(15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    if isToday {
                        Chip(title: "Today", isOn: true)
                    }
                    if entry.scheduledDayNumber == nil && entry.isLogged {
                        // Flag off-schedule workouts so the "why is this
                        // row here?" is obvious. (e.g. Sunday when the
                        // picked days are Mon/Wed/Fri.)
                        Chip(title: "Off-day")
                    }
                }
                HStack(spacing: Space.x2) {
                    if let dayNo = entry.scheduledDayNumber {
                        Text("Day \(dayNo)")
                            .font(AppFont.mono(11, weight: .medium))
                            .tracking(1.0)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.textTertiary)
                        Text("·").foregroundStyle(Color.textTertiary)
                    }
                    Text("\(entry.targetMinutes) min target")
                        .font(AppFont.ui(12, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
                if entry.loggedMinutes > 0 {
                    Text(
                        "Logged \(entry.loggedMinutes) min\(entryCount > 1 ? " · \(entryCount) entries" : "")"
                    )
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.accentInk)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.horizontal, Space.x4)
        .padding(.vertical, Space.x3)
        .background(Color.appSurface, in: .rect(cornerRadius: Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card)
                .stroke(
                    isToday ? Color.accentVolt : Color.appBorder,
                    style: StrokeStyle(
                        lineWidth: isToday ? 1.5 : 1,
                        // Proposed (not-yet-logged) days get a dashed border
                        // so they read as "planned, not done" in the list —
                        // the same visual language the bar graph uses for
                        // dashed outline bars.
                        dash: entry.isProposed && !isToday ? [4, 3] : []
                    )
                )
        )
    }

    // MARK: - Helpers

    private func makeSelection(for date: Date, config: ChallengeService.ActiveConfig) -> DaySelection {
        let day = date.startOfDay
        let hasLogged = workouts.contains { Calendar.current.isDate($0.date, inSameDayAs: day) }
        let target = SigmoidalService.targetDuration(
            for: day,
            startDate: config.startDate,
            params: config.sigmoid
        )
        return DaySelection(
            date: day,
            proposedDuration: hasLogged ? nil : Int(target.rounded()),
            hasWorkouts: hasLogged
        )
    }

}

#Preview {
    CalendarView()
        .modelContainer(try! Persistence.makePreviewContainer())
        .environmentObject(HealthKitService())
}
