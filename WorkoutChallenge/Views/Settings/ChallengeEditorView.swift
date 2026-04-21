//
//  ChallengeEditorView.swift
//  WorkoutChallenge
//
//  Dedicated editor for the schedule + progression-curve sliders, split
//  out of the main Settings list when that list started to feel crowded.
//  Pushed from one of two entry points:
//
//    • ActiveChallengeCard → "Edit schedule & curve" — binds to the live
//      challenge's frozen snapshot, so mid-challenge tweaks redraw the
//      curve globally and re-grade every week.
//    • BetweenChallengesCard → "Edit defaults" — binds to
//      `UserPreferencesModel` as defaults that pre-populate the next
//      Create-Challenge flow.
//
//  Readers elsewhere (CalendarView, ProgressChartView, ProgressBarsView,
//  WeeklyScheduleService) all route through
//  `ChallengeService.activeConfig(...)`, so edits made here propagate to
//  every view without anyone needing to mirror fields back onto prefs.
//

import SwiftUI
import SwiftData

struct ChallengeEditorView: View {
    /// Non-nil when editing a live challenge. Nil when editing prefs as
    /// the "defaults for the next challenge" scope.
    let challenge: ChallengeModel?

    @Query private var preferencesList: [UserPreferencesModel]
    @State private var showResetConfirm = false

    private var prefs: UserPreferencesModel? { preferencesList.first }

    var body: some View {
        Group {
            if let prefs {
                ScreenShell(eyebrow: eyebrow, title: title) {
                    scheduleCard(prefs: prefs)
                    curveCard(prefs: prefs)
                }
            } else {
                ZStack {
                    Color.appBg.ignoresSafeArea()
                    ProgressView().tint(.accentVolt)
                }
            }
        }
        .navigationTitle(navBarTitle)
        .navigationBarTitleDisplayMode(.inline)
        .tint(.accentVolt)
        .confirmationDialog(
            "Reset to defaults?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive, action: resetDefaults)
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Copy

    /// Eyebrow shown above the ScreenShell title. Tells the user which
    /// scope the sliders below are editing — the live challenge, or the
    /// prefs that seed the next Create flow.
    private var eyebrow: String {
        if let challenge {
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "CHALLENGE %02lld · FINE-TUNE",
                    comment: "Eyebrow above the editor when scoped to a live challenge"),
                challenge.number)
        }
        return NSLocalizedString(
            "DEFAULTS · FOR NEXT CHALLENGE",
            comment: "Eyebrow above the editor when scoped to prefs")
    }

    private var title: String {
        challenge != nil
            ? NSLocalizedString("Tune it.", comment: "Editor title for live challenge")
            : NSLocalizedString("Next defaults.", comment: "Editor title for prefs")
    }

    /// Inline navigation-bar title. Shorter than the ScreenShell hero so
    /// the back chevron + title fit together cleanly at the top.
    private var navBarTitle: String {
        if let challenge {
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "Challenge %02lld",
                    comment: "Nav-bar title when editing a challenge"),
                challenge.number)
        }
        return NSLocalizedString(
            "Defaults",
            comment: "Nav-bar title when editing prefs")
    }

    // MARK: - Schedule card

    @ViewBuilder
    private func scheduleCard(prefs: UserPreferencesModel) -> some View {
        // Scope-aware bindings — route writes to the challenge's frozen
        // snapshot when present, fall back to prefs as defaults otherwise.
        // `firstWeekday` is a display preference (Sunday- vs. Monday-start)
        // and always lives on prefs regardless of scope.
        let startDate = Binding<Date>(
            get: { challenge?.startDate ?? prefs.startDate },
            set: {
                if let challenge { challenge.startDate = $0 }
                else { prefs.startDate = $0 }
            }
        )
        let daysPerWeek = Binding<Int>(
            get: { challenge?.daysPerWeek ?? prefs.daysPerWeek },
            set: {
                if let challenge { challenge.daysPerWeek = $0 }
                else { prefs.daysPerWeek = $0 }
            }
        )

        AppSection(title: "Schedule") {
            LabeledRow(label: "Start date") {
                DatePicker(
                    "",
                    selection: startDate,
                    displayedComponents: .date
                )
                .labelsHidden()
                .tint(.accentVolt)
            }

            if challenge != nil {
                // Heads-up: moving the start date slides the whole 90-day
                // window — mid-challenge that's a large operation. Kept
                // inline (rather than a confirmation dialog) because Kurt
                // tinkers often and modal friction wouldn't be worth it.
                Text("Moving the start date shifts the whole 90-day window.")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }

            RowDivider()

            LabeledRow(
                label: "Days per week",
                detail: "\(daysPerWeek.wrappedValue) day\(daysPerWeek.wrappedValue == 1 ? "" : "s")"
            ) {
                HStack(spacing: Space.x2) {
                    stepperButton(symbol: "minus") {
                        daysPerWeek.wrappedValue = max(1, daysPerWeek.wrappedValue - 1)
                    }
                    .disabled(daysPerWeek.wrappedValue <= 1)
                    stepperButton(symbol: "plus") {
                        daysPerWeek.wrappedValue = min(7, daysPerWeek.wrappedValue + 1)
                    }
                    .disabled(daysPerWeek.wrappedValue >= 7)
                }
            }

            RowDivider()

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("Week starts on")
                    .font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                SegmentedControl(
                    items: [(label: "Sunday", value: 1), (label: "Monday", value: 2)],
                    selection: Binding(
                        get: { prefs.firstWeekday },
                        set: { prefs.firstWeekday = $0 }
                    )
                )
            }
        }
    }

    // MARK: - Progression curve card

    @ViewBuilder
    private func curveCard(prefs: UserPreferencesModel) -> some View {
        // Same scope-aware pattern as Schedule. Writes land on either
        // the challenge's frozen sigmoid snapshot or prefs.
        let minBinding = Binding<Double>(
            get: { challenge?.sigmoid.minDuration ?? prefs.sigmoid.minDuration },
            set: { newValue in
                if let challenge { challenge.sigmoid.minDuration = newValue }
                else { prefs.sigmoid.minDuration = newValue }
            }
        )
        let maxBinding = Binding<Double>(
            get: { challenge?.sigmoid.maxDuration ?? prefs.sigmoid.maxDuration },
            set: { newValue in
                if let challenge { challenge.sigmoid.maxDuration = newValue }
                else { prefs.sigmoid.maxDuration = newValue }
            }
        )
        let midBinding = Binding<Double>(
            get: { challenge?.sigmoid.midpoint ?? prefs.sigmoid.midpoint },
            set: { newValue in
                if let challenge { challenge.sigmoid.midpoint = newValue }
                else { prefs.sigmoid.midpoint = newValue }
            }
        )
        let steepBinding = Binding<Double>(
            get: { challenge?.sigmoid.steepness ?? prefs.sigmoid.steepness },
            set: { newValue in
                if let challenge { challenge.sigmoid.steepness = newValue }
                else { prefs.sigmoid.steepness = newValue }
            }
        )

        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Progression curve")
                .tsEyebrow()
                .foregroundStyle(Color.textTertiary)

            VStack(alignment: .leading, spacing: Space.x4) {
                // Hero sigmoid preview — no milestones since these sliders
                // aren't tied to a specific "today".
                SigmoidCurve(progress: 0.6, showMilestones: false)
                    .frame(height: 80)

                SliderRow(
                    title: "Min duration",
                    value: minBinding,
                    range: 5...120, step: 5, unit: "min"
                )
                SliderRow(
                    title: "Max duration",
                    value: maxBinding,
                    range: 10...240, step: 5, unit: "min"
                )
                SliderRow(
                    title: "Midpoint (day)",
                    value: midBinding,
                    range: 1...90, step: 1
                )
                SliderRow(
                    title: "Steepness",
                    value: steepBinding,
                    range: 0.01...1.0, step: 0.01,
                    format: .number.precision(.fractionLength(2))
                )

                SecondaryButton(title: "Reset to defaults") {
                    showResetConfirm = true
                }

                Text("Sigmoid: min + (max − min) / (1 + exp(−steepness × (day − midpoint)))")
                    .font(AppFont.mono(10, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
            .appCard()
        }
    }

    // MARK: - Helpers

    /// Bordered +/− button pair mirroring the one in Settings. Duplicated
    /// here (rather than extracted into the design system) because it's
    /// only used in these two places and inlining keeps the callsite
    /// readable.
    private func stepperButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.textPrimary)
                .frame(width: 34, height: 34)
                .background(Color.appSurface, in: .rect(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.appBorder, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    /// Reset targets whichever scope the sliders are editing. On the
    /// challenge path we leave `startDate` alone — clobbering it would
    /// shift the 90-day window, which is almost never what the user
    /// wants. Between challenges we reset start date to "today" so the
    /// next Create flow picks a sensible default.
    private func resetDefaults() {
        if let challenge {
            challenge.sigmoid = .default
            challenge.daysPerWeek = 3
        } else if let prefs {
            prefs.sigmoid = .default
            prefs.daysPerWeek = 3
            prefs.startDate = Date()
        }
    }
}

#Preview {
    NavigationStack {
        ChallengeEditorView(challenge: nil)
            .modelContainer(try! Persistence.makePreviewContainer())
    }
}
