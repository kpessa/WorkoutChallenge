//
//  CalendarView.swift
//  WorkoutChallenge
//
//  iOS mirror of Calendar.svelte. The screen is split into three bands:
//
//    1. A hero with the sigmoid curve + progress chip + VoltProgress bar
//    2. A compact 90-day DayCell grid (the whole challenge at a glance)
//    3. A scrollable list of scheduled days with target durations
//
//  Tapping any day (grid *or* list) opens the logging sheet. The screen
//  uses the design-system ScreenShell — no stock nav bar.
//

import SwiftUI
import SwiftData

struct CalendarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var preferencesList: [UserPreferencesModel]
    @Query(sort: \WorkoutModel.date, order: .reverse) private var workouts: [WorkoutModel]

    @State private var selection: DaySelection?

    private struct DaySelection: Identifiable {
        let date: Date
        let proposedDuration: Int?
        let hasWorkouts: Bool
        var id: Date { date }
    }

    private var prefs: UserPreferencesModel? { preferencesList.first }

    var body: some View {
        Group {
            if let prefs {
                content(prefs: prefs)
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
    private func content(prefs: UserPreferencesModel) -> some View {
        let schedule = SigmoidalService.generateSchedule(
            startDate: prefs.startDate,
            daysPerWeek: prefs.daysPerWeek
        )
        let today = Date().startOfDay
        let currentDay = max(1, min(90, prefs.startDate.daysUntil(today) + 1))
        let completedCount = completedScheduledCount(schedule: schedule)
        let progressFraction = Double(currentDay) / 90.0

        ScreenShell(
            eyebrow: "DAY \(currentDay) OF 90 · KEEP GOING",
            title: "Ninety days."
        ) {
            // HERO
            heroCard(currentDay: currentDay, completed: completedCount, progress: progressFraction)

            // COMPACT GRID
            gridCard(prefs: prefs, schedule: schedule, currentDay: currentDay)

            // SCHEDULE LIST
            scheduleList(schedule: schedule, prefs: prefs)
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
    private func gridCard(prefs: UserPreferencesModel, schedule: [ScheduledDay], currentDay: Int) -> some View {
        AppSection(title: "90-day grid") {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 15),
                spacing: 4
            ) {
                ForEach(schedule) { day in
                    Button {
                        selection = makeSelection(for: day, prefs: prefs)
                    } label: {
                        DayCell(day: day.dayNumber, state: gridState(for: day, currentDay: currentDay))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func gridState(for day: ScheduledDay, currentDay: Int) -> DayCell.State {
        let completed = workouts.contains { Calendar.current.isDate($0.date, inSameDayAs: day.date) }
        if completed { return .completed }
        if day.dayNumber == currentDay { return .today }
        if day.dayNumber < currentDay { return .upcoming }   // missed / past
        return .proposed
    }

    // MARK: - Schedule list

    @ViewBuilder
    private func scheduleList(schedule: [ScheduledDay], prefs: UserPreferencesModel) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Schedule").tsEyebrow().foregroundStyle(Color.textTertiary)
            LazyVStack(spacing: Space.x2) {
                ForEach(schedule) { day in
                    scheduleRow(day: day, prefs: prefs)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = makeSelection(for: day, prefs: prefs)
                        }
                }
            }
        }
    }

    private func scheduleRow(day: ScheduledDay, prefs: UserPreferencesModel) -> some View {
        let target = SigmoidalService.targetDuration(
            for: day.date,
            startDate: prefs.startDate,
            params: prefs.sigmoid
        )
        let dayWorkouts = workouts.filter { Calendar.current.isDate($0.date, inSameDayAs: day.date) }
        let completedMinutes = dayWorkouts.reduce(0) { $0 + $1.duration }
        let isComplete = completedMinutes >= Int(target.rounded())
        let isToday = Calendar.current.isDateInToday(day.date)

        return HStack(alignment: .center, spacing: Space.x3) {
            // Status pill — Volt when complete, Border outline when not.
            ZStack {
                Circle()
                    .fill(isComplete ? Color.accentVolt : Color.clear)
                    .overlay(Circle().stroke(
                        isComplete ? Color.accentVolt : Color.appBorder,
                        lineWidth: 1.5))
                    .frame(width: 28, height: 28)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.04))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.x2) {
                    Text(day.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(AppFont.ui(15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    if isToday {
                        Chip(title: "Today", isOn: true)
                    }
                }
                HStack(spacing: Space.x2) {
                    Text("Day \(day.dayNumber)")
                        .font(AppFont.mono(11, weight: .medium))
                        .tracking(1.0)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.textTertiary)
                    Text("·").foregroundStyle(Color.textTertiary)
                    Text("\(Int(target.rounded())) min target")
                        .font(AppFont.ui(12, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
                if completedMinutes > 0 {
                    Text("Logged \(completedMinutes) min\(dayWorkouts.count > 1 ? " · \(dayWorkouts.count) entries" : "")")
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
                .stroke(isToday ? Color.accentVolt : Color.appBorder,
                        lineWidth: isToday ? 1.5 : 1)
        )
    }

    // MARK: - Helpers

    private func makeSelection(for day: ScheduledDay, prefs: UserPreferencesModel) -> DaySelection {
        let hasLogged = workouts.contains { Calendar.current.isDate($0.date, inSameDayAs: day.date) }
        let target = SigmoidalService.targetDuration(
            for: day.date,
            startDate: prefs.startDate,
            params: prefs.sigmoid
        )
        return DaySelection(
            date: day.date,
            proposedDuration: hasLogged ? nil : Int(target.rounded()),
            hasWorkouts: hasLogged
        )
    }

    /// How many *scheduled* days have been completed so far. A day is
    /// "completed" when logged-minutes ≥ target-minutes.
    private func completedScheduledCount(schedule: [ScheduledDay]) -> Int {
        guard let prefs else { return 0 }
        return schedule.reduce(0) { acc, day in
            let target = SigmoidalService.targetDuration(
                for: day.date,
                startDate: prefs.startDate,
                params: prefs.sigmoid
            )
            let logged = workouts
                .filter { Calendar.current.isDate($0.date, inSameDayAs: day.date) }
                .reduce(0) { $0 + $1.duration }
            return acc + (logged >= Int(target.rounded()) ? 1 : 0)
        }
    }
}

#Preview {
    CalendarView()
        .modelContainer(try! Persistence.makePreviewContainer())
        .environmentObject(HealthKitService())
}
