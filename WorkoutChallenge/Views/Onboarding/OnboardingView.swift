//
//  OnboardingView.swift
//  WorkoutChallenge
//
//  Seven-step first-run flow (plus a Welcome screen), ported from the v2
//  "science-backed" design (docs: design bundle Onboarding.html, chat1.md).
//  The flow leads with Kurt's credentials, teaches the physiology behind
//  the sigmoid, then collects the inputs that seed a `UserPreferencesModel`
//  before handing off to `RootView`.
//
//  Persistence: final values are written on the Pledge screen (Begin Day 1).
//  Prior screens keep state in the struct so Back/Skip don't commit partial
//  data. Workout types are no longer seeded here (as of 2026-04-20) —
//  `RootView.ensureDefaults()` inserts a single default and users add more
//  from LogWorkoutSheet's "+ New type" chip or Settings → Workout types.
//

import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Persisted keys

/// Namespace for the @AppStorage keys this flow owns. Kept here so callers
/// elsewhere (e.g. the re-engagement "why" card on day 34) can read the
/// same values without re-declaring the strings.
enum OnboardingKey {
    static let completed        = "onboarding.completed"
    static let why              = "onboarding.why"
    static let pledgeSignature  = "onboarding.pledgeSignature"
    static let habitMinutes     = "onboarding.habitMinutes"
    static let goalMinutes      = "onboarding.goalMinutes"
    static let celestialEnabled = "onboarding.celestialEnabled"
    static let creatorName      = "onboarding.creatorName"
}

// MARK: - Steps

private enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case meetKurt
    case science
    case why
    case cadence
    case goal
    case celestial
    case pledge

    /// 1-indexed position among the trackable screens (the non-Welcome ones;
    /// 7 after the 2026-04-20 removal of the Activities step). Screen 01
    /// (Welcome) has no progress dots per the design.
    var progressIndex: Int? {
        self == .welcome ? nil : rawValue
    }

    /// Total number of trackable screens (everything except `.welcome`).
    /// Used by the progress chrome so inserting a new step is one edit.
    static let trackableCount: Int = OnboardingStep.allCases.count - 1
}

// MARK: - Main view

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var preferences: [UserPreferencesModel]

    // Watched so that a fresh install on a *second* device (Mac Catalyst,
    // new iPhone, reinstall) can auto-skip onboarding as soon as CloudKit
    // has replicated an existing challenge into this container. The
    // onboarding flag itself is @AppStorage-backed and therefore NOT
    // CloudKit-synced, so without this query a returning user would be
    // forced through the flow again. See `autoSkipIfSyncedDataArrives()`.
    @Query private var challenges: [ChallengeModel]

    @AppStorage(OnboardingKey.completed)        private var completed: Bool = false
    @AppStorage(OnboardingKey.why)              private var whyStored: String = ""
    @AppStorage(OnboardingKey.pledgeSignature)  private var pledgeStored: String = ""
    @AppStorage(OnboardingKey.habitMinutes)     private var habitMinutesStored: Int = 15
    @AppStorage(OnboardingKey.goalMinutes)      private var goalMinutesStored: Int = 60
    @AppStorage(OnboardingKey.celestialEnabled) private var celestialStored: Bool = true
    @AppStorage(OnboardingKey.creatorName)      private var creatorName: String = "Kurt Pessa"

    // In-flight form state. Committed on the final screen.
    @State private var step: OnboardingStep = .welcome
    /// True when the most recent step change moved *backwards*, so the
    /// screen transition can slide in from the leading edge instead of
    /// trailing. Reset on every forward advance.
    @State private var navigatingBack: Bool = false
    @State private var why: String = ""
    @State private var daysPerWeek: Int = 4
    @State private var habitMinutes: Int = 15
    @State private var goalMinutes: Int = 60
    @State private var startDate: Date = Date()
    @State private var celestialEnabled: Bool = true
    @State private var signed: Bool = false

    // Pill stops for the habit-minimum and goal selectors. Both selectors
    // also render a "Custom" slot backed by a free-form number input, so
    // these arrays are just the common starting points, not a hard allowlist.
    private let habitMinuteStops: [Int] = [5, 10, 15]
    private let goalMinuteStops: [Int]  = [30, 60, 90]

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            content
                .transition(.asymmetric(
                    insertion: .move(edge: navigatingBack ? .leading : .trailing).combined(with: .opacity),
                    removal: .opacity))
                .id(step)
        }
        .animation(Motion.base, value: step)
        // iOS-native edge-swipe-right to go back. Only fires when the drag
        // starts within ~30pt of the leading edge so it doesn't fight with
        // TextEditor selection on the WhyScreen.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let startedAtLeftEdge = value.startLocation.x < 30
                    let draggedRight      = value.translation.width > 80
                    let mostlyHorizontal  = abs(value.translation.height) < 80
                    if startedAtLeftEdge && draggedRight && mostlyHorizontal {
                        goBack()
                    }
                }
        )
        // Cold-launch check: if CloudKit already replicated a challenge
        // into this install before we even appeared, skip the flow.
        .task { autoSkipIfSyncedDataArrives() }
        // Warm-launch check: CloudKit often finishes the initial pull a
        // few seconds after launch. Re-check when the challenges query
        // re-emits, but ONLY while the user is still on the Welcome step —
        // if they've already advanced into the flow, assume they're
        // intentionally redoing onboarding and don't yank them out.
        .onChange(of: challenges.count) { _, _ in
            autoSkipIfSyncedDataArrives()
        }
    }

    /// Flip `completed` to true when CloudKit sync reveals a pre-existing
    /// `ChallengeModel` in this container — i.e. "this user has onboarded
    /// before, just on a different device." Gated on `step == .welcome`
    /// so we don't interrupt a user who's mid-flow.
    ///
    /// We use `ChallengeModel` (not `UserPreferencesModel`) as the signal
    /// because `RootView.ensureDefaults()` seeds a default prefs row on
    /// every cold launch regardless of onboarding state — so prefs isn't
    /// a reliable indicator. A ChallengeModel only exists after onboarding
    /// has completed on some device in the iCloud graph.
    private func autoSkipIfSyncedDataArrives() {
        guard !completed, step == .welcome, !challenges.isEmpty else { return }
        completed = true
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:    WelcomeScreen(onBegin: advance)
        case .meetKurt:   MeetKurtScreen(step: step, name: creatorName, onNext: advance, onBack: goBack, onSkip: skipToCadence)
        case .science:    ScienceScreen(step: step, onNext: advance, onBack: goBack, onSkip: skipToCadence)
        case .why:        WhyScreen(step: step, text: $why, onNext: advance, onBack: goBack, onSkip: advance)
        case .cadence:    CadenceScreen(step: step,
                                       daysPerWeek: $daysPerWeek,
                                       habitMinutes: $habitMinutes,
                                       habitMinuteStops: habitMinuteStops,
                                       startDate: $startDate,
                                       onNext: advance,
                                       onBack: goBack,
                                       onSkip: advance)
        case .goal:       GoalScreen(step: step,
                                     daysPerWeek: daysPerWeek,
                                     habitMinutes: habitMinutes,
                                     goalMinutes: $goalMinutes,
                                     goalMinuteStops: goalMinuteStops,
                                     onNext: advance,
                                     onBack: goBack,
                                     onSkip: advance)
        case .celestial:  CelestialScreen(step: step,
                                         startDate: startDate,
                                         enabled: $celestialEnabled,
                                         onNext: advance,
                                         onBack: goBack,
                                         onSkip: advance)
        case .pledge:     PledgeScreen(step: step,
                                      name: creatorName,
                                      startDate: startDate,
                                      daysPerWeek: daysPerWeek,
                                      habitMinutes: habitMinutes,
                                      goalMinutes: goalMinutes,
                                      signed: $signed,
                                      onBack: goBack,
                                      onBegin: finish)
        }
    }

    // MARK: - Navigation

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        navigatingBack = false
        step = next
    }

    /// Step backwards one screen. No-op on the welcome screen (there is
    /// nothing before it). Partial state collected so far is preserved —
    /// persistence only happens in `finish()`.
    private func goBack() {
        guard let prev = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        navigatingBack = true
        step = prev
    }

    /// Returning-user optimization: Skip on the credential or science
    /// screens jumps straight to the first data-collection screen (Cadence),
    /// bypassing the intro material. Was previously `skipToActivities` when
    /// the flow had an Activities step between Why and Cadence.
    private func skipToCadence() {
        navigatingBack = false
        step = .cadence
    }

    // MARK: - Completion

    /// Persist all collected inputs and flip the onboarding flag. The
    /// parent switches to `RootView` which runs its own first-launch
    /// bootstrap (workout-type seeding, prefs row, challenge migration).
    private func finish() {
        // Prefs: ensure a row exists, then write the challenge config.
        let prefs: UserPreferencesModel
        if let existing = preferences.first {
            prefs = existing
        } else {
            prefs = UserPreferencesModel.makeDefault()
            modelContext.insert(prefs)
        }
        prefs.startDate = startDate
        prefs.daysPerWeek = daysPerWeek
        // Push habit min / goal into the sigmoid shape the rest of the app
        // reads from. Guarantee min ≤ max even if something slipped past
        // the in-flight constraint on the Cadence screen.
        var sigmoid = prefs.sigmoid
        let minD = Double(habitMinutes)
        let maxD = Double(max(goalMinutes, habitMinutes))
        sigmoid.minDuration = minD
        sigmoid.maxDuration = maxD
        prefs.sigmoid = sigmoid

        // Workout types are no longer pre-seeded from onboarding — users add
        // their own (Rollerblading, Speediance, Orange Theory, etc.) from
        // the "+ New type" chip inside LogWorkoutSheet or from
        // Settings → Workout types. `RootView.ensureDefaults()` still inserts
        // a single default "Exercise" type on first launch so the chip row
        // is never empty.

        // Soft-persisted inputs (no model field yet).
        whyStored = why
        habitMinutesStored = habitMinutes
        goalMinutesStored = goalMinutes
        celestialStored = celestialEnabled
        if signed { pledgeStored = creatorName }

        try? modelContext.save()
        completed = true
    }
}

// MARK: - Shell

/// Top chrome shared by screens 02–08: back chevron (from step 2 onwards),
/// step counter + Skip, and the progress indicator (one capsule per
/// trackable step; count is derived from `OnboardingStep.trackableCount`).
private struct OnboardingHeader: View {
    let step: OnboardingStep
    var onBack: (() -> Void)? = nil
    var onSkip: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Space.x3) {
            HStack(spacing: Space.x2) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.textPrimary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Back"))
                }
                Text(String(format: "%02d / %02d", step.rawValue, OnboardingStep.trackableCount))
                    .font(AppFont.mono(10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.accentInk)
                Spacer()
                if let onSkip {
                    Button("Skip", action: onSkip)
                        .font(AppFont.ui(12, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                        .buttonStyle(.plain)
                }
            }
            HStack(spacing: 4) {
                ForEach(1...OnboardingStep.trackableCount, id: \.self) { i in
                    Capsule()
                        .fill(i <= step.rawValue ? Color.accentVoltInk : Color.appSurface2)
                        .frame(height: 3)
                }
            }
        }
    }
}

/// Shared page frame: safe-area padding, header slot, main content, and a
/// sticky primary action at the bottom. Individual screens compose this so
/// the chrome stays consistent.
private struct OnboardingPage<Content: View>: View {
    let step: OnboardingStep
    var onBack: (() -> Void)?
    var onSkip: (() -> Void)?
    let buttonTitle: String
    var buttonDisabled: Bool = false
    let onTap: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingHeader(step: step, onBack: onBack, onSkip: onSkip)
                .padding(.horizontal, Space.x5)
                .padding(.top, Space.x3)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.x5) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.x5)
                .padding(.top, Space.x5)
                .padding(.bottom, Space.x8)
            }
            .scrollIndicators(.hidden)

            PrimaryButton(title: buttonTitle, action: onTap)
                .padding(.horizontal, Space.x5)
                .padding(.bottom, Space.x5)
                .opacity(buttonDisabled ? 0.5 : 1)
                .allowsHitTesting(!buttonDisabled)
        }
    }
}

/// Eyebrow + large display heading, used on most screens.
private struct OnboardingTitle: View {
    let eyebrow: String
    let line1: String
    var line2: String? = nil
    var line2Muted: Bool = false
    var size: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(LocalizedStringKey(eyebrow)).tsEyebrow()
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(line1))
                if let line2 {
                    Text(LocalizedStringKey(line2)).foregroundStyle(line2Muted ? Color.textTertiary : Color.textPrimary)
                }
            }
            .font(AppFont.display(size))
            .tracking(-0.8)
            .foregroundStyle(Color.textPrimary)
            .lineSpacing(-4)
        }
    }
}

// MARK: - 01 · Welcome

private struct WelcomeScreen: View {
    let onBegin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: Space.x8)

            // Hero sigmoid with soft Volt glow behind it.
            ZStack {
                RadialGradient(colors: [Color.accentVolt.opacity(0.18), .clear],
                               center: .center, startRadius: 10, endRadius: 220)
                SigmoidCurve(progress: 0.95,
                             fillOpacity: 0.18,
                             showMilestones: true)
                    .padding(.horizontal, Space.x5)
                    .padding(.vertical, Space.x6)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 280)

            Spacer(minLength: Space.x6)

            VStack(alignment: .leading, spacing: Space.x3) {
                Text("Ninety")
                    .tsEyebrow()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ninety days.")
                    Text("One curve.").foregroundStyle(Color.textTertiary)
                }
                .font(AppFont.display(54))
                .tracking(-1.3)
                .foregroundStyle(Color.textPrimary)
                .lineSpacing(-6)

                Text("Built on exercise physiology. Paced by the body.")
                    .font(AppFont.ui(14))
                    .foregroundStyle(Color.textSecondary)
                    .padding(.top, Space.x2)
            }
            .padding(.horizontal, Space.x5)

            Spacer(minLength: Space.x6)

            VStack(spacing: Space.x3) {
                PrimaryButton(title: "Begin", action: onBegin)
                HStack(spacing: 4) {
                    Text("Already have an account?")
                        .foregroundStyle(Color.textTertiary)
                    Text("Sign in")
                        .foregroundStyle(Color.textPrimary)
                        .underline()
                }
                .font(AppFont.ui(12, weight: .medium))
            }
            .padding(.horizontal, Space.x5)
            .padding(.bottom, Space.x5)
        }
    }
}

// MARK: - 02 · Meet Kurt

private struct MeetKurtScreen: View {
    let step: OnboardingStep
    let name: String
    let onNext: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingPage(step: step, onBack: onBack, onSkip: onSkip, buttonTitle: "Why it works", onTap: onNext) {
            OnboardingTitle(eyebrow: "Meet the builder",
                            line1: "Hi — I'm",
                            line2: "\(name).",
                            size: 34)

            // Italic pull-quote with the left Volt bar.
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(Color.accentVoltInk).frame(width: 2)
                Text("I build physiology-encoded software for hospitals. This app is the same pattern, applied to your body.")
                    .font(AppFont.ui(14))
                    .italic()
                    .foregroundStyle(Color.textPrimary)
                    .lineSpacing(2)
                    .padding(.leading, Space.x3)
                    .padding(.vertical, Space.x2)
            }

            VStack(spacing: Space.x2) {
                CredentialCard(
                    badge: "MS",
                    title: "Exercise & Sports Science",
                    footnote: "APPLIED PHYSIOLOGY · UCF",
                    copy: "VO\u{2082}, mitochondrial density, neural adaptation — the physiology behind the sigmoid.",
                    highlight: false)
                CredentialCard(
                    badge: "PharmD",
                    title: "Doctor of Pharmacy",
                    footnote: "PBA · 2017",
                    copy: "Dose–response curves and pharmacokinetics — why training is prescribed, not guessed.",
                    highlight: false)
                CredentialCard(
                    badge: "CDS",
                    title: "Pharmacy Informatics",
                    footnote: "UHS · 45-HOSPITAL SYSTEM",
                    copy: "I build clinical decision-support software. This app applies that same pattern to personal fitness.",
                    highlight: true)
            }

            Text("Also: Texas state championship tennis (2003). Rice baseball, College World Series (2006). Because discipline transfers.")
                .font(AppFont.mono(10))
                .foregroundStyle(Color.textTertiary)
                .lineSpacing(2)
        }
    }
}

private struct CredentialCard: View {
    let badge: String
    let title: String
    let footnote: String
    let copy: String
    let highlight: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.x2) {
                Text(LocalizedStringKey(badge))
                    .font(AppFont.mono(badge.count > 3 ? 9 : 11, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 3)
                    .foregroundStyle(highlight ? Color(red: 0.04, green: 0.04, blue: 0.04) : Color.accentInk)
                    .frame(width: 30, height: 30)
                    .background(highlight ? Color.accentVolt : Color.appSurface2,
                                in: .rect(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentVoltInk, lineWidth: highlight ? 0 : 1.5))
                Text(LocalizedStringKey(title))
                    .font(AppFont.ui(13, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
            }
            Text(LocalizedStringKey(footnote))
                .font(AppFont.mono(9, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(highlight ? Color.accentInk : Color.textTertiary)
            Text(LocalizedStringKey(copy))
                .font(AppFont.ui(12))
                .foregroundStyle(Color.textSecondary)
                .lineSpacing(2)
        }
        .padding(Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            highlight ? Color.accentVolt.opacity(0.04) : Color.appSurface,
            in: .rect(cornerRadius: Radius.card - 6))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card - 6)
                .stroke(highlight ? Color.accentVoltInk : Color.appBorder, lineWidth: 1))
    }
}

// MARK: - 03 · Science

private struct ScienceScreen: View {
    let step: OnboardingStep
    let onNext: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingPage(step: step, onBack: onBack, onSkip: onSkip, buttonTitle: "I'm in", onTap: onNext) {
            OnboardingTitle(eyebrow: "The science",
                            line1: "Why a sigmoid.",
                            line2: "Why 90 days.",
                            size: 30)

            // Sigmoid diagram with 3 phase bands behind the curve.
            VStack(alignment: .leading, spacing: 6) {
                PhaseBandedSigmoid()
                    .frame(height: 140)
                HStack(spacing: 0) {
                    phaseLabel("HABIT")
                    phaseLabel("GROWTH")
                    phaseLabel("PLATEAU")
                }
            }
            .padding(Space.x3)
            .appCard()

            VStack(alignment: .leading, spacing: Space.x3) {
                PhaseRow(range: "DAYS 1–21",
                         title: "Habit",
                         copy: "Low volume on purpose. Neural adaptation is highest here. Joints, tendons, and skin get to acclimate — no blisters, no overuse.")
                PhaseRow(range: "DAYS 22–60",
                         title: "Growth",
                         copy: "Volume ramps. Aerobic capacity and strength accrue. The curve steepens because your body is ready.")
                PhaseRow(range: "DAYS 61–90",
                         title: "Plateau",
                         copy: "You hold your volume. Gains consolidate. This is where results become visible.")
            }
        }
    }

    private func phaseLabel(_ s: String) -> some View {
        Text(LocalizedStringKey(s))
            .font(AppFont.mono(9, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Color.accentInk)
            .frame(maxWidth: .infinity)
    }
}

private struct PhaseBandedSigmoid: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Phase band widths scaled to 21 / 39 / 30 days out of 90.
            let band1 = w * (21.0 / 90.0)
            let band2 = w * (39.0 / 90.0)
            let band3 = w * (30.0 / 90.0)

            HStack(spacing: 0) {
                Rectangle().fill(Color.accentVolt.opacity(0.05)).frame(width: band1)
                Rectangle().fill(Color.accentVolt.opacity(0.10)).frame(width: band2)
                Rectangle().fill(Color.accentVolt.opacity(0.18)).frame(width: band3)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Sigmoid stroked on top of the bands.
            SigmoidCurve(progress: 0.5,
                         fillColor: .clear,
                         fillOpacity: 0,
                         showMilestones: false)
        }
    }
}

private struct PhaseRow: View {
    let range: String
    let title: String
    let copy: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // `range` is ASCII (e.g. "1–21") — passed through LSK so the
                // catalog can override it (ES uses an en-dash too but future
                // locales might prefer words).
                Text(LocalizedStringKey(range))
                    .font(AppFont.mono(10, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(Color.accentInk)
                Text(LocalizedStringKey(title))
                    .font(AppFont.ui(13, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
            }
            Text(LocalizedStringKey(copy))
                .font(AppFont.ui(12))
                .foregroundStyle(Color.textSecondary)
                .lineSpacing(2)
        }
    }
}

// MARK: - 04 · Your Why

private struct WhyScreen: View {
    let step: OnboardingStep
    @Binding var text: String
    let onNext: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void

    private let maxChars = 140

    var body: some View {
        OnboardingPage(step: step, onBack: onBack, onSkip: onSkip, buttonTitle: "Lock it in", onTap: onNext) {
            OnboardingTitle(eyebrow: "Your why",
                            line1: "Why are you",
                            line2: "doing this?",
                            size: 32)

            Text("One sentence. We'll show it back to you on day 34 when the novelty's worn off.")
                .font(AppFont.ui(13))
                .foregroundStyle(Color.textSecondary)
                .lineSpacing(2)

            VStack(alignment: .leading, spacing: Space.x2) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("I want to feel strong again.\nNot for anyone — for me.")
                            .font(AppFont.ui(14))
                            .foregroundStyle(Color.textTertiary)
                            .lineSpacing(3)
                            .padding(Space.x3)
                    }
                    TextEditor(text: $text)
                        .font(AppFont.ui(14))
                        .foregroundStyle(Color.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(Space.x3 - 4)
                        .tint(.accentVolt)
                        .onChange(of: text) { _, newValue in
                            if newValue.count > maxChars {
                                text = String(newValue.prefix(maxChars))
                            }
                        }
                }
                .frame(minHeight: 130, alignment: .topLeading)
                .background(Color.appSurface, in: .rect(cornerRadius: Radius.input))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.input)
                        .stroke(Color.appBorder, lineWidth: 1))

                HStack {
                    Text("Private · only you")
                    Spacer()
                    Text("\(text.count) / \(maxChars)")
                }
                .font(AppFont.mono(10, weight: .medium))
                .foregroundStyle(Color.textTertiary)
            }
        }
    }
}

// MARK: - 05 · Cadence
//
// Historical note: the flow used to have an "Activities" pick-your-workouts
// screen here (the 2×N grid with Rollerblade / Padel / Pickleball / Run /
// Cycle / etc. + Custom tile). Removed 2026-04-20 — users add their own
// workout types on demand from the "+ New type" chip in LogWorkoutSheet or
// from Settings → Workout types, so pre-seeding a catalog up front was noise.
// Trackable count dropped from 8 to 7 screens as a result.

private struct CadenceScreen: View {
    let step: OnboardingStep
    @Binding var daysPerWeek: Int
    @Binding var habitMinutes: Int
    let habitMinuteStops: [Int]
    @Binding var startDate: Date
    let onNext: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingPage(step: step, onBack: onBack, onSkip: onSkip, buttonTitle: "Next", onTap: onNext) {
            OnboardingTitle(eyebrow: "Cadence",
                            line1: "Pick your",
                            line2: "habit minimum.",
                            size: 28)

            // Kurt says callout with left Volt bar.
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(Color.accentVoltInk).frame(width: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("KURT SAYS")
                        .font(AppFont.mono(9, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.accentInk)
                    Text("Pick something **so easy you can't say no**. The hardest part is putting on your shoes and getting out the door.")
                        .font(AppFont.ui(13))
                        .foregroundStyle(Color.textPrimary)
                        .lineSpacing(2)
                }
                .padding(.leading, Space.x3)
                .padding(.vertical, Space.x3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface2, in: .rect(cornerRadius: 8))

            // Days / week stepper.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Days per week")
                        .font(AppFont.ui(14, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Rec: 4")
                        .font(AppFont.mono(10))
                        .foregroundStyle(Color.textTertiary)
                }
                Spacer()
                StepperControl(value: $daysPerWeek, range: 1...7)
            }
            .appCard()

            // Habit minimum pills + Custom slot.
            VStack(alignment: .leading, spacing: Space.x3) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Habit minimum")
                            .font(AppFont.ui(14, weight: .bold))
                            .foregroundStyle(Color.textPrimary)
                        Text("Floor — the smallest day that still counts.")
                            .font(AppFont.mono(10))
                            .foregroundStyle(Color.textTertiary)
                    }
                    Spacer()
                    minutesReadout(habitMinutes)
                }
                MinutePills(value: $habitMinutes,
                            stops: habitMinuteStops,
                            customRange: 1...45,
                            customPlaceholder: "—")
            }
            .appCard()

            // Start date row.
            HStack {
                Text("Start date")
                    .font(AppFont.ui(14, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                VoltPill(text: startDate.isToday
                    ? String.localizedStringWithFormat(
                        NSLocalizedString("TODAY · %@", comment: "Pill label when start date is today"),
                        startDate.shortMonthDay())
                    : startDate.shortMonthDay().uppercased())
            }
            .appCard()
        }
    }

    private func minutesReadout(_ minutes: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(minutes)")
                .font(AppFont.mono(14, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text(" min")
                .font(AppFont.mono(12, weight: .medium))
                .foregroundStyle(Color.textTertiary)
        }
    }
}

// MARK: - 06 · Goal

/// Picks the upper bound of the 90-day sigmoid. Framed in the 2008 Physical
/// Activity Guidelines for Americans tiers (also echoed by the WHO 2010
/// guidelines Kurt was studying):
///   • 150 min/wk moderate → "substantial health benefits" (baseline)
///   • 300 min/wk moderate → "additional/more extensive benefits"
///   •  ≥450 min/wk        → athletic / elite territory
/// The tier badge below the pill row is derived live from
/// `goalMinutes × daysPerWeek` so the user can see which tier a given
/// selection lands them in for their chosen cadence.
private struct GoalScreen: View {
    let step: OnboardingStep
    let daysPerWeek: Int
    let habitMinutes: Int
    @Binding var goalMinutes: Int
    let goalMinuteStops: [Int]
    let onNext: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void

    private var weeklyMinutes: Int { max(0, goalMinutes) * max(1, daysPerWeek) }

    var body: some View {
        OnboardingPage(step: step, onBack: onBack, onSkip: onSkip, buttonTitle: "Looks right", onTap: onNext) {
            OnboardingTitle(eyebrow: "Goal",
                            line1: "Where you're",
                            line2: "heading.",
                            size: 30)

            Text("Your goal is the volume you believe will show up in your body — the minutes-per-session you're building toward by day 90.")
                .font(AppFont.ui(13))
                .foregroundStyle(Color.textSecondary)
                .lineSpacing(2)

            // Science callout — 2008 PAGA tiers.
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(Color.accentVoltInk).frame(width: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("THE SCIENCE · 2008 PAGA")
                        .font(AppFont.mono(9, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.accentInk)
                    Text("**150 min/wk** moderate activity → substantial health benefits. **300 min/wk** → additional benefits. Pick the tier you want your body in.")
                        .font(AppFont.ui(13))
                        .foregroundStyle(Color.textPrimary)
                        .lineSpacing(2)
                }
                .padding(.leading, Space.x3)
                .padding(.vertical, Space.x3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface2, in: .rect(cornerRadius: 8))

            // Goal pills with per-pill weekly math + Custom slot.
            VStack(alignment: .leading, spacing: Space.x3) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Goal per session")
                            .font(AppFont.ui(14, weight: .bold))
                            .foregroundStyle(Color.textPrimary)
                        Text("Where the curve lands by day 90.")
                            .font(AppFont.mono(10))
                            .foregroundStyle(Color.textTertiary)
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(goalMinutes)")
                            .font(AppFont.mono(14, weight: .bold))
                            .foregroundStyle(Color.textPrimary)
                        Text(" min")
                            .font(AppFont.mono(12, weight: .medium))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                MinutePills(value: $goalMinutes,
                            stops: goalMinuteStops,
                            customRange: max(habitMinutes, 1)...240,
                            customPlaceholder: "—",
                            subLabel: { stop in weeklySubLabel(for: stop) })

                // Tier annotation for the currently-selected goal.
                HStack(spacing: 6) {
                    Circle()
                        .fill(PAGATier.of(weeklyMinutes: weeklyMinutes).color)
                        .frame(width: 8, height: 8)
                    Text("\(daysPerWeek) × \(goalMinutes) = \(weeklyMinutes) min/wk")
                        .font(AppFont.mono(11, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                    Text("· \(PAGATier.of(weeklyMinutes: weeklyMinutes).label)")
                        .font(AppFont.mono(11))
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(.top, 2)
            }
            .appCard()

            // Preview curve habit → goal.
            VStack(alignment: .leading, spacing: 4) {
                Text("PREVIEW · \(habitMinutes)min → \(goalMinutes)min")
                    .font(AppFont.mono(9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.textTertiary)
                SigmoidCurve(progress: 0.8,
                             fillColor: .clear,
                             fillOpacity: 0,
                             showMilestones: false)
                    .frame(height: 48)
            }
            .appCard()
        }
    }

    /// Per-pill weekly-total text — "5× · 150/wk" style. Keeps the tier
    /// math visible as the user changes daysPerWeek upstream.
    private func weeklySubLabel(for stop: Int) -> String {
        let total = stop * max(1, daysPerWeek)
        return "\(daysPerWeek)× · \(total)/wk"
    }
}

/// PAGA (2008) tier buckets by weekly minutes. Used to colorize the goal
/// selection live so the user can see which tier they land in at their
/// chosen days-per-week.
private enum PAGATier {
    case belowBaseline, baseline, advanced, elite

    static func of(weeklyMinutes wk: Int) -> PAGATier {
        switch wk {
        case ..<150:   return .belowBaseline
        case 150..<300: return .baseline
        case 300..<450: return .advanced
        default:        return .elite
        }
    }

    var label: String {
        switch self {
        case .belowBaseline: return "below PAGA minimum"
        case .baseline:      return "baseline · substantial benefits"
        case .advanced:      return "advanced · additional benefits"
        case .elite:         return "elite · athletic territory"
        }
    }

    var color: Color {
        switch self {
        case .belowBaseline: return Color.textTertiary
        case .baseline:      return Color.accentInk
        case .advanced, .elite: return Color.accentVoltInk
        }
    }
}

// MARK: - Pills

/// Segmented minute picker laid out as a single iOS-style segmented control
/// (one rounded container, raised thumb on selection) plus a "Custom" slot
/// backed by a numeric text field.
///
/// Selection model — exactly one segment is active at any time:
///   • `customText` non-empty  → Custom segment is active; value = parsed(text)
///   • `customText` empty      → the preset segment matching `value` is active
///
/// Deriving "is Custom?" from the *text* (not from whether `value` matches a
/// preset) avoids an ambiguous state where a user types "30" into the Custom
/// field and the "30" preset silently lights up underneath — the field stays
/// the source of truth until the user explicitly taps a preset.
///
/// `subLabel` renders an optional second line under each preset (used on the
/// Goal screen for "4× · 120/wk" tier math). `customRange` clamps what the
/// Custom field will accept so the user can't set 0 or 600 min.
private struct MinutePills: View {
    @Binding var value: Int
    let stops: [Int]
    var customRange: ClosedRange<Int> = 1...240
    var customPlaceholder: String = "—"
    var subLabel: ((Int) -> String)? = nil

    @State private var customText: String = ""
    @FocusState private var customFocused: Bool

    /// Geometry of the segmented container. Keeping these named so the thumb
    /// and container corners read consistently.
    private let containerRadius: CGFloat = Radius.ctrl
    private let thumbInset: CGFloat = 3
    private var thumbRadius: CGFloat { max(4, containerRadius - thumbInset) }

    /// Custom mode is driven by text, not by value — see type-level comment.
    private var isCustom: Bool { !customText.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(stops, id: \.self) { stop in
                presetSegment(stop: stop, isOn: !isCustom && value == stop)
            }
            customSegment
        }
        .padding(thumbInset)
        .background(Color.appSurface2, in: .rect(cornerRadius: containerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: containerRadius)
                .stroke(Color.appBorder, lineWidth: 1))
        .onAppear {
            // Seed the custom field when we arrive with a value that isn't a
            // preset (e.g. AppStorage restored 22 from a previous session).
            if !stops.contains(value), customText.isEmpty {
                customText = String(value)
            }
        }
    }

    // MARK: Segments

    private func presetSegment(stop: Int, isOn: Bool) -> some View {
        Button {
            if value != stop || isCustom {
                value = stop
                customText = ""             // drop Custom mode
                customFocused = false
#if canImport(UIKit)
                UISelectionFeedbackGenerator().selectionChanged()
#endif
            }
        } label: {
            segmentContent(isOn: isOn) {
                Text("\(stop)")
                    .font(AppFont.mono(15, weight: .bold))
                    .foregroundStyle(thumbTextColor(isOn: isOn))
                if let subLabel {
                    Text(subLabel(stop))
                        .font(AppFont.mono(8, weight: .medium))
                        .tracking(0.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(thumbSubColor(isOn: isOn))
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var customSegment: some View {
        let isOn = isCustom
        segmentContent(isOn: isOn) {
#if canImport(UIKit)
            TextField(customPlaceholder, text: $customText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(AppFont.mono(15, weight: .bold))
                .foregroundStyle(thumbTextColor(isOn: isOn))
                .focused($customFocused)
                .onChange(of: customText) { _, txt in
                    let digits = txt.filter(\.isNumber)
                    if digits != txt { customText = digits; return }
                    // Empty text keeps `value` stable — the user might still
                    // be editing. isCustom will flip to false for display,
                    // which is fine: the last-selected preset (or no preset)
                    // stays highlighted.
                    guard !digits.isEmpty, let n = Int(digits) else { return }
                    let clamped = min(customRange.upperBound,
                                       max(customRange.lowerBound, n))
                    if clamped != value { value = clamped }
                }
#else
            Text(customPlaceholder)
                .font(AppFont.mono(15, weight: .bold))
                .foregroundStyle(Color.textPrimary)
#endif
            Text("min")
                .font(AppFont.mono(8, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(thumbSubColor(isOn: isOn))
        }
        .onTapGesture {
            // Tapping anywhere inside the Custom segment focuses the field
            // even if the tap misses the narrow TextField rect.
            customFocused = true
        }
    }

    // MARK: Segment chrome

    /// Shared segment frame: the selected segment gets a raised Volt thumb
    /// inside the container; unselected segments are flush with the container
    /// background, following the iOS 13+ segmented control pattern.
    @ViewBuilder
    private func segmentContent<Content: View>(
        isOn: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 2) { content() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.x2)
            .padding(.horizontal, 4)
            .background(
                isOn ? Color.accentVolt : Color.clear,
                in: .rect(cornerRadius: thumbRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: thumbRadius)
                    .stroke(isOn ? Color.accentVoltInk : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
    }

    private func thumbTextColor(isOn: Bool) -> Color {
        isOn ? Color(red: 0.04, green: 0.04, blue: 0.04) : Color.textPrimary
    }

    private func thumbSubColor(isOn: Bool) -> Color {
        isOn ? Color(red: 0.04, green: 0.04, blue: 0.04).opacity(0.65)
             : Color.textTertiary
    }
}

private struct StepperControl: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: Space.x2) {
            Button { if value > range.lowerBound { value -= 1 } } label: {
                Text("−").font(AppFont.ui(16, weight: .bold))
            }
            .buttonStyle(StepperButton())
            .disabled(value <= range.lowerBound)

            Text("\(value)")
                .font(AppFont.display(22))
                .foregroundStyle(Color.textPrimary)
                .frame(minWidth: 24)

            Button { if value < range.upperBound { value += 1 } } label: {
                Text("+").font(AppFont.ui(16, weight: .bold))
            }
            .buttonStyle(StepperButton())
            .disabled(value >= range.upperBound)
        }
    }
}

private struct StepperButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.textPrimary)
            .frame(width: 30, height: 30)
            .background(Color.appBg, in: .rect(cornerRadius: Radius.ctrl))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.ctrl).stroke(Color.appBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct VoltPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(AppFont.mono(10, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.04))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accentVolt, in: Capsule())
            .overlay(Capsule().stroke(Color(red: 0.04, green: 0.04, blue: 0.04), lineWidth: 1.5))
    }
}

// MARK: - 07 · Celestial

private struct CelestialScreen: View {
    let step: OnboardingStep
    let startDate: Date
    @Binding var enabled: Bool
    let onNext: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void

    // 3 moons ≈ 88.6 days. First ≈ full moon lands mid-cycle 1, full of
    // cycle 3 at ~day 74. We use the synodic month to anchor the markers.
    private var fullMoonDate: Date { startDate.addingDays(45) }
    private var endDate: Date { startDate.addingDays(89) }

    var body: some View {
        OnboardingPage(step: step, onBack: onBack, onSkip: onSkip, buttonTitle: "Anchor me", onTap: onNext) {
            OnboardingTitle(eyebrow: "Grounded in the sky",
                            line1: "Three moons.",
                            line2: "One season.",
                            size: 28)

            // Three moons timeline.
            HStack(spacing: Space.x2) {
                MoonStamp(date: startDate, fill: Color.appBg, ring: Color.textPrimary,
                          label: "Start", labelAccent: false)
                Rectangle().fill(Color.appBorder).frame(height: 1)
                MoonStamp(date: fullMoonDate, fill: Color.textPrimary, ring: Color.textPrimary,
                          label: "Full", labelAccent: true)
                Rectangle().fill(Color.appBorder).frame(height: 1)
                MoonStamp(date: endDate, fill: Color.appBg, ring: Color.textPrimary,
                          label: "End", labelAccent: false)
            }

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("I anchor the challenge to three lunar cycles and the seasonal arc because the body already keeps this time.")
                    .font(AppFont.ui(13))
                    .foregroundStyle(Color.textPrimary)
                    .lineSpacing(2)
                Text("Your 90 days span \(Text("3 moons").foregroundStyle(Color.accentInk).font(AppFont.ui(12, weight: .bold))) and cross the \(nextSolarEventLabel()) on day \(daysUntilNextSolarEvent()).")
                    .font(AppFont.ui(12))
                    .foregroundStyle(Color.textSecondary)
                    .lineSpacing(2)
            }
            .appCard()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show celestial context")
                        .font(AppFont.ui(13, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Sunrise, moon, season")
                        .font(AppFont.mono(10))
                        .foregroundStyle(Color.textTertiary)
                }
                Spacer()
                Toggle("", isOn: $enabled).labelsHidden().tint(.accentVolt)
            }
            .appCard()
        }
    }

    private func nextSolarEventLabel() -> String {
        CelestialService.nextSolarEvent(from: startDate).kind.shortLabel
    }

    private func daysUntilNextSolarEvent() -> Int {
        let event = CelestialService.nextSolarEvent(from: startDate)
        let days = Calendar.current.dateComponents([.day], from: startDate, to: event.date).day ?? 0
        return max(1, min(90, days + 1))
    }
}

private struct MoonStamp: View {
    let date: Date
    let fill: Color
    let ring: Color
    let label: String
    let labelAccent: Bool

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(fill)
                .frame(width: 40, height: 40)
                .overlay(Circle().stroke(ring, lineWidth: 1.5))
            Text(date.shortMonthDay().uppercased())
                .font(AppFont.mono(9, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(Color.textTertiary)
            Text(LocalizedStringKey(label))
                .font(AppFont.ui(11, weight: .bold))
                .foregroundStyle(labelAccent ? Color.accentInk : Color.textPrimary)
        }
    }
}

// MARK: - 08 · Pledge

private struct PledgeScreen: View {
    let step: OnboardingStep
    let name: String
    let startDate: Date
    let daysPerWeek: Int
    let habitMinutes: Int
    let goalMinutes: Int
    @Binding var signed: Bool
    let onBack: () -> Void
    let onBegin: () -> Void

    private var endDate: Date { startDate.addingDays(89) }

    var body: some View {
        OnboardingPage(step: step,
                       onBack: onBack,
                       onSkip: nil,
                       buttonTitle: "Begin Day 1",
                       buttonDisabled: !signed,
                       onTap: onBegin) {
            OnboardingTitle(eyebrow: "The pledge",
                            line1: "Sign it.",
                            size: 38)

            // Challenge summary card (Volt border).
            VStack(alignment: .leading, spacing: Space.x3) {
                Text("CHALLENGE 01")
                    .font(AppFont.mono(10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.accentInk)
                VStack(spacing: 6) {
                    pledgeRow("Starts", startDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    pledgeRow("Ends",   endDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    pledgeRow("Habit min", "\(daysPerWeek) × \(habitMinutes) min")
                    pledgeRow("Growth goal", "\(goalMinutes) min")
                }
            }
            .padding(Space.x3)
            .background(Color.appSurface, in: .rect(cornerRadius: Radius.card - 4))
            .overlay(RoundedRectangle(cornerRadius: Radius.card - 4)
                .stroke(Color.accentVoltInk, lineWidth: 1.5))

            // Pledge italic with Volt bar.
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(Color.accentVoltInk).frame(width: 2)
                Text("\u{201C}I show up, even when it's boring. Ninety days, no renegotiation.\u{201D}")
                    .font(AppFont.ui(14))
                    .italic()
                    .foregroundStyle(Color.textPrimary)
                    .lineSpacing(3)
                    .padding(.leading, Space.x3)
                    .padding(.vertical, Space.x2)
            }

            // Signature block.
            VStack(alignment: .leading, spacing: 4) {
                Text("SIGN")
                    .font(AppFont.mono(10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.textTertiary)
                Button {
                    withAnimation(Motion.slow) { signed = true }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(signed ? name : " ")
                            .font(AppFont.display(26))
                            .italic()
                            .foregroundStyle(Color.accentInk)
                            .frame(height: 32, alignment: .bottom)
                        Rectangle()
                            .fill(Color.accentVoltInk)
                            .frame(height: 1.5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(signed ? "SIGNED" : "TAP TO SIGN")
                    .font(AppFont.mono(9, weight: .medium))
                    .tracking(1.0)
                    .foregroundStyle(signed ? Color.accentInk : Color.textTertiary)
            }
        }
    }

    private func pledgeRow(_ label: String, _ value: String) -> some View {
        // `label` is a static English key routed through the catalog;
        // `value` is pre-formatted dynamic content and rendered verbatim.
        HStack {
            Text(LocalizedStringKey(label))
                .font(AppFont.ui(12))
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(AppFont.ui(12, weight: .bold))
                .foregroundStyle(Color.textPrimary)
        }
    }
}

// MARK: - Helpers

private extension Date {
    var isToday: Bool { Calendar.current.isDateInToday(self) }

    func shortMonthDay() -> String {
        formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Preview

#Preview("Onboarding") {
    OnboardingView()
        .modelContainer(try! Persistence.makePreviewContainer())
}
