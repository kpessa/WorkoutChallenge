//
//  ChallengeSection.swift
//  WorkoutChallenge
//
//  The Settings → Challenge subsection. Shows the current challenge card
//  (Pause / Resume / Edit / Abandon) and the history list underneath.
//  Between challenges, a small "Start Challenge NN" card replaces the
//  active card so the user has a single place to create the next one.
//

import SwiftUI
import SwiftData

/// Top-of-Settings block that owns the lifecycle actions. Reads all
/// challenge rows and splits them into "current" (active/paused) and
/// "history" via `ChallengeService`.
struct ChallengeSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var challenges: [ChallengeModel]
    @Query private var preferencesList: [UserPreferencesModel]
    @Query(sort: \WorkoutModel.date, order: .reverse) private var workouts: [WorkoutModel]

    @State private var showAbandonSheet = false
    @State private var showCreateFlow = false

    private var current: ChallengeModel? {
        ChallengeService.currentChallenge(in: challenges)
    }
    private var history: [ChallengeModel] {
        ChallengeService.history(in: challenges)
    }
    private var prefs: UserPreferencesModel? { preferencesList.first }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Challenge").tsEyebrow().foregroundStyle(Color.textTertiary)

            if let current {
                ActiveChallengeCard(
                    challenge: current,
                    workouts: workouts,
                    onPause: { ChallengeService.pause(current) },
                    onResume: { ChallengeService.resume(current) },
                    onAbandon: { showAbandonSheet = true }
                )
            } else {
                BetweenChallengesCard(
                    nextNumber: (challenges.map(\.number).max() ?? 0) + 1,
                    onStart: { showCreateFlow = true }
                )
            }

            if !history.isEmpty {
                Text("History · \(history.count)")
                    .tsEyebrow()
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, Space.x2)
                VStack(spacing: Space.x2) {
                    ForEach(history) { ch in
                        HistoryRow(challenge: ch, workouts: workouts)
                    }
                }
            }
        }
        .sheet(isPresented: $showAbandonSheet) {
            if let current {
                AbandonChallengeSheet(
                    challenge: current,
                    onConfirm: {
                        ChallengeService.abandon(current)
                        showAbandonSheet = false
                    },
                    onCancel: { showAbandonSheet = false }
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $showCreateFlow) {
            CreateChallengeView(
                nextNumber: (challenges.map(\.number).max() ?? 0) + 1,
                defaultSigmoid: prefs?.sigmoid ?? .default,
                onCreate: { startDate, daysPerWeek, sigmoid, pledge in
                    // Readers now pull from `ChallengeService.activeConfig`,
                    // which prefers the current challenge's frozen snapshot
                    // over `prefs`. So we no longer mirror the new
                    // challenge's fields back onto prefs — doing so would
                    // silently overwrite the user's "defaults for next
                    // challenge" sliders every time they started a run.
                    _ = ChallengeService.startNew(
                        context: modelContext,
                        existing: challenges,
                        startDate: startDate,
                        daysPerWeek: daysPerWeek,
                        sigmoid: sigmoid,
                        pledgeSignature: pledge
                    )
                    showCreateFlow = false
                },
                onCancel: { showCreateFlow = false }
            )
        }
    }
}

// MARK: - Active card

/// The hero card at the top of the Challenge section when there's a
/// current challenge. Shows day/90 progress, a progress bar, and the
/// Pause/Resume + Abandon actions.
private struct ActiveChallengeCard: View {
    let challenge: ChallengeModel
    let workouts: [WorkoutModel]
    let onPause: () -> Void
    let onResume: () -> Void
    let onAbandon: () -> Void

    private var currentDay: Int { ChallengeService.currentDay(of: challenge) }
    private var progress: Double { ChallengeService.progress(of: challenge) }
    private var isPaused: Bool { challenge.state == .paused }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(alignment: .center) {
                Text(numberLabel)
                    .font(AppFont.mono(10, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Chip(title: "Day \(currentDay) / 90", isOn: !isPaused)
            }

            Text(challenge.startDate, format: .dateTime.month(.wide).day().year())
                .font(AppFont.display(20))
                .foregroundStyle(Color.textPrimary)

            Text(subtitle)
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(Color.textSecondary)

            VoltProgress(progress: progress)

            // Edit row — pushes ChallengeEditorView scoped to this
            // challenge. Sits above the Pause/Abandon action row because
            // "tweak the schedule or curve" is the most frequent action on
            // this card (daily-weekly cadence) whereas Pause/Abandon are
            // rare lifecycle events.
            NavigationLink {
                ChallengeEditorView(challenge: challenge)
            } label: {
                HStack(spacing: Space.x2) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Edit schedule & curve")
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                }
                .padding(.horizontal, Space.x3)
                .padding(.vertical, Space.x2)
                .frame(maxWidth: .infinity)
                .background(Color.appSurface2, in: .rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.appBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Edit schedule and curve"))

            HStack(spacing: Space.x2) {
                if isPaused {
                    Button(action: onResume) { actionLabel("Resume", filled: true) }
                        .buttonStyle(.plain)
                } else {
                    Button(action: onPause) { actionLabel("Pause") }
                        .buttonStyle(.plain)
                }
                Button(action: onAbandon) {
                    Text("Abandon")
                        .font(AppFont.ui(12, weight: .bold))
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.danger, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .appCard()
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card)
                .stroke(Color.textPrimary, lineWidth: 1.5)
        )
    }

    private var numberLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("Challenge %02lld · %@", comment: "Active challenge number + state"),
            challenge.number,
            challenge.state.shortLabel
        )
    }

    private var subtitle: String {
        let ends = challenge.projectedEndDate.formatted(.dateTime.month(.abbreviated).day())
        return String.localizedStringWithFormat(
            NSLocalizedString("%lld days/week · Ends %@", comment: "Challenge cadence and end date"),
            challenge.daysPerWeek,
            ends
        )
    }

    @ViewBuilder
    private func actionLabel(_ title: String, filled: Bool = false) -> some View {
        let inkOnVolt = Color(red: 0.04, green: 0.04, blue: 0.04)
        Text(title)
            .font(AppFont.ui(12, weight: .bold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(filled ? inkOnVolt : Color.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(filled ? Color.accentVolt : Color.appSurface2,
                        in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(filled ? inkOnVolt : Color.appBorder,
                            lineWidth: filled ? 1.5 : 1)
            )
    }
}

// MARK: - Between-challenges card

/// Shown in the Settings → Challenge section when there's no current
/// challenge. Compact copy + a Volt "Start Challenge NN" button. The
/// full empty-state experience lives on the Bars screen; this is the
/// settings-side pointer.
private struct BetweenChallengesCard: View {
    let nextNumber: Int
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Between challenges")
                .font(AppFont.mono(10, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color.textTertiary)
            Text("What's next?")
                .font(AppFont.display(22))
                .foregroundStyle(Color.textPrimary)
            Text("Start the next challenge whenever you're ready.")
                .font(AppFont.ui(13, weight: .medium))
                .foregroundStyle(Color.textSecondary)
            PrimaryButton(
                title: String.localizedStringWithFormat(
                    NSLocalizedString("Start Challenge %02lld", comment: "Between-challenges CTA"),
                    nextNumber),
                action: onStart)

            // Secondary route into the same editor used mid-challenge, but
            // scoped to prefs (challenge == nil). Lets Kurt pre-tune the
            // defaults that will seed the next Create-Challenge flow,
            // without needing a live challenge to do it.
            NavigationLink {
                ChallengeEditorView(challenge: nil)
            } label: {
                HStack(spacing: Space.x2) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Edit defaults")
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                }
                .padding(.horizontal, Space.x3)
                .padding(.vertical, Space.x2)
                .frame(maxWidth: .infinity)
                .background(Color.appSurface2, in: .rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.appBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Edit defaults for the next challenge"))
        }
        .appCard()
    }
}

// MARK: - History row

private struct HistoryRow: View {
    let challenge: ChallengeModel
    let workouts: [WorkoutModel]

    private var completedDays: Int {
        ChallengeService.completedDayCount(of: challenge, workouts: workouts)
    }

    private var stateColor: Color {
        switch challenge.state {
        case .completed: return .accentVoltInk
        case .abandoned: return .textSecondary
        default:         return .textSecondary
        }
    }

    var body: some View {
        HStack(spacing: Space.x3) {
            // Number badge (e.g. "01").
            Text(String(format: "%02d", challenge.number))
                .font(AppFont.mono(11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.textSecondary)
                .frame(width: 36, height: 36)
                .background(Color.appSurface2, in: .rect(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.appBorder,
                                style: StrokeStyle(
                                    lineWidth: 1.5,
                                    dash: challenge.state == .abandoned ? [3, 2] : []))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("Challenge %02lld", comment: "History row title"),
                    challenge.number))
                    .font(AppFont.ui(14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(detailLine)
                    .font(AppFont.mono(10, weight: .medium))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(stateColor)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.horizontal, Space.x3)
        .padding(.vertical, Space.x2)
        .background(Color.appSurface, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.appBorder, lineWidth: 1)
        )
    }

    private var detailLine: String {
        let state = challenge.state.shortLabel
        return String.localizedStringWithFormat(
            NSLocalizedString("%@ · Day %lld of 90", comment: "History row: state + progress"),
            state,
            completedDays
        )
    }
}

#Preview {
    ChallengeSection()
        .padding()
        .background(Color.appBg)
        .modelContainer(try! Persistence.makePreviewContainer())
}
