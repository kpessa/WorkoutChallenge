//
//  ProgressCoachCard.swift
//  WorkoutChallenge
//
//  The Progress-tab teach-then-comment surface. Sibling of
//  `CoachFeedbackCard` (which lives in the workout-log sheet).
//
//  Differences from the post-workout card:
//
//    • Tap-to-listen, not autoplay. The speaker glyph is the affordance.
//      Opening Progress shouldn't blast audio — the user is browsing.
//    • A skeleton state while the narrator's API call is in flight, so
//      the card has a visible footprint immediately even before prose
//      arrives. The post-workout card hides itself until ready; here the
//      reserved space prevents the FitnessTrendCard from jumping when
//      the narrative pops in.
//    • Reserves a "💬 Ask the Coach" affordance (currently disabled) so
//      the multi-turn feature has a discoverable home when it lands.
//      Tapping today shows a "Coming soon" toast in DEBUG, no-op in
//      Release. The seam is intentional — leaving the spot empty would
//      mean re-balancing the card layout when the feature arrives.
//
//  The visual language matches `FitnessTrendCard` (the immediate
//  neighbor): `.appCard()` modifier, `tsEyebrow` header, mono captions.
//

import SwiftUI

struct ProgressCoachCard: View {
    let state: ProgressCoachLoader.State
    /// Optional player. The parent owns the player so playback survives
    /// view transitions and stops cleanly on disappear.
    let audioPlayer: CoachAudioPlayer?
    /// Tapped when the user wants to start a conversational session.
    /// Until "Ask the Coach" ships, parents can pass nil and the
    /// placeholder affordance below will be hidden in Release builds.
    let onAsk: (() -> Void)?

    init(
        state: ProgressCoachLoader.State,
        audioPlayer: CoachAudioPlayer? = nil,
        onAsk: (() -> Void)? = nil
    ) {
        self.state = state
        self.audioPlayer = audioPlayer
        self.onAsk = onAsk
    }

    var body: some View {
        switch state {
        case .idle, .loading:
            skeletonCard

        case .failed:
            // Silent in Release; named in DEBUG so a tuning loop can spot
            // narrator failures without instrumenting the network.
            #if DEBUG
            failureCard
            #else
            EmptyView()
            #endif

        case .ready(let facts, let body, let context, let audioURL):
            if let body, !body.isEmpty {
                narrativeCard(
                    body: body,
                    facts: facts,
                    context: context,
                    audioURL: audioURL
                )
            } else if facts.hasNotable {
                bulletedCard(facts: facts, context: context)
            } else {
                #if DEBUG
                debugOnlyCard(facts: facts, context: context)
                #else
                EmptyView()
                #endif
            }
        }
    }

    // MARK: - Skeleton

    /// Reserved-space placeholder shown while the build/narrate pipeline
    /// is in flight. Renders an eyebrow header + a mono caption so the
    /// user knows the coach is thinking — same gesture-language as the
    /// post-workout card, but bigger because Progress has more vertical
    /// real estate.
    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            header(trailing: nil)
            HStack(spacing: Space.x3) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.accentInk)
                Text("Reading the picture…")
                    .font(AppFont.ui(13, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
            }
            .frame(minHeight: 40)
        }
        .appCard()
    }

    // MARK: - Failure (DEBUG only)

    #if DEBUG
    private var failureCard: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            header(trailing: nil)
            Text("[DEBUG] Loader failed")
                .font(AppFont.mono(11, weight: .bold))
                .foregroundStyle(Color.danger)
            if case .failed(let msg) = state {
                Text(msg)
                    .font(AppFont.mono(11))
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .appCard()
    }
    #endif

    // MARK: - Bulleted (no narrator) card

    /// When no narrator is configured, render the focus fact as a single
    /// terse line. The deterministic pass already picked one focus, so
    /// we don't list — just the lead.
    private func bulletedCard(
        facts: CoachFacts,
        context: ProgressCoachContext?
    ) -> some View {
        let lead = facts.notable.first

        return VStack(alignment: .leading, spacing: Space.x3) {
            header(trailing: focusChip(for: context?.focus))
            if let lead {
                bulletRow(for: lead)
            }
            askPlaceholderIfNeeded()
            #if DEBUG
            debugSections(facts: facts, context: context)
            #endif
        }
        .appCard()
    }

    /// Debug-only render when no notable facts crossed the threshold.
    /// Useful for tuning the focus selector — lets you see what the rule
    /// pass thought about today even when it picked `.none`.
    #if DEBUG
    private func debugOnlyCard(
        facts: CoachFacts,
        context: ProgressCoachContext?
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            header(trailing: focusChip(for: context?.focus))
            Text("[DEBUG] No notable focus. Coach stayed silent.")
                .font(AppFont.mono(11, weight: .medium))
                .foregroundStyle(Color.textTertiary)
            debugSections(facts: facts, context: context)
        }
        .appCard()
    }
    #endif

    // MARK: - Bullet row

    /// Dot + localized template. Uses the same NSLocalizedString-based
    /// interpolation as `CoachFeedbackCard` so EN/ES copy lives in
    /// `Localizable.xcstrings` only.
    private func bulletRow(for fact: CoachFact) -> some View {
        HStack(alignment: .top, spacing: Space.x3) {
            Circle()
                .fill(severityColor(for: fact.severity))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            Text(interpolated(fact.templateKey, with: fact.values))
                .font(AppFont.ui(15, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func severityColor(for severity: CoachFact.Severity) -> Color {
        switch severity {
        case .notable: return .accentVolt
        case .normal:  return .textSecondary
        case .quiet:   return .textTertiary
        }
    }

    // MARK: - Narrative (LLM) card

    /// When the narrator has produced prose, this is the primary render.
    /// Speaker glyph + label gives the user a discoverable tap-to-play
    /// affordance without auto-playing.
    private func narrativeCard(
        body: String,
        facts: CoachFacts,
        context: ProgressCoachContext?,
        audioURL: URL?
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            header(trailing: focusChip(for: context?.focus))

            Text(body)
                .font(AppFont.ui(15, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Speaker glyph row — visible whenever there's audio OR when
            // the parent supplies a player and there *should be* audio
            // (no key, no voice → row is hidden, not just disabled, so
            // the card doesn't carry a dead affordance).
            if let audioURL, let player = audioPlayer {
                speakerRow(url: audioURL, player: player)
            }

            askPlaceholderIfNeeded()

            #if DEBUG
            debugSections(facts: facts, context: context)
            #endif
        }
        .appCard()
    }

    // MARK: - Header

    /// Eyebrow + optional trailing chip (the focus marker). Trailing is
    /// nil during loading/failure; non-nil when we have a context to read
    /// the focus from.
    private func header(trailing: AnyView?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("COACH").tsEyebrow().foregroundStyle(Color.textTertiary)
            Spacer()
            if let trailing { trailing }
        }
    }

    /// Compact focus chip ("Fitness rising", "Behind pace", etc.). Lives
    /// in the header trailing slot so the user can see at a glance what
    /// the card is about. Skipped for `.none` / `.onTrack` to keep the
    /// header quiet when nothing's wrong.
    private func focusChip(for focus: ProgressCoachFocus?) -> AnyView? {
        guard let focus, let label = focusChipLabel(focus) else { return nil }
        return AnyView(Chip(title: label, isOn: true))
    }

    private func focusChipLabel(_ focus: ProgressCoachFocus) -> String? {
        switch focus {
        case .milestone:        return "Milestone"
        case .returnAfterBreak: return "Welcome back"
        case .recoveryDeficit:  return "Recovery"
        case .behindPace:       return "Behind pace"
        case .fitnessRising:    return "Rising"
        case .fitnessFalling:   return "Easing"
        case .streakLockingIn:  return "Streak"
        case .vo2MaxMoving:     return "VO₂Max"
        case .hrvShift:         return "HRV"
        case .onTrack, .none:   return nil
        }
    }

    // MARK: - Speaker row

    /// Tap-to-play affordance. Speaker glyph + status label + thin
    /// progress bar. Layout matches the post-workout card's audio
    /// controls so muscle memory transfers between surfaces.
    @ViewBuilder
    private func speakerRow(url: URL, player: CoachAudioPlayer) -> some View {
        HStack(spacing: Space.x3) {
            Button(action: { handlePlayTap(url: url, player: player) }) {
                ZStack {
                    Circle()
                        .fill(Color.accentVolt)
                        .frame(width: 36, height: 36)
                    Image(systemName: speakerIcon(for: player.state))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.04))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(speakerAccessibilityLabel(for: player.state))

            VStack(alignment: .leading, spacing: 4) {
                Text(speakerStatusLabel(for: player.state))
                    .font(AppFont.mono(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                progressBar(for: player)
            }
        }
    }

    private func handlePlayTap(url: URL, player: CoachAudioPlayer) {
        switch player.state {
        case .playing:
            player.pause()
        case .paused:
            player.resume()
        case .idle, .loading, .error:
            Task {
                try? await player.play(url: url)
            }
        }
    }

    /// Speaker glyph reflects player state. Idle/paused/error → speaker
    /// (the affordance), loading → ellipsis, playing → pause icon. This
    /// is deliberately different from the post-workout card's play arrow
    /// — Progress is a "listen if you want" surface, so the speaker
    /// metaphor maps better than play/pause transport.
    private func speakerIcon(for state: CoachAudioPlayer.State) -> String {
        switch state {
        case .playing: return "pause.fill"
        case .loading: return "ellipsis"
        case .paused:  return "speaker.wave.2.fill"
        case .error:   return "speaker.slash.fill"
        case .idle:    return "speaker.wave.2.fill"
        }
    }

    private func speakerStatusLabel(for state: CoachAudioPlayer.State) -> String {
        switch state {
        case .idle:    return "Listen"
        case .loading: return "Loading…"
        case .playing: return "Playing"
        case .paused:  return "Paused"
        case .error:   return "Tap to retry"
        }
    }

    private func speakerAccessibilityLabel(for state: CoachAudioPlayer.State) -> String {
        switch state {
        case .idle:    return "Listen to coach"
        case .loading: return "Loading coach audio"
        case .playing: return "Pause coach audio"
        case .paused:  return "Resume coach audio"
        case .error:   return "Retry coach audio"
        }
    }

    private func progressBar(for player: CoachAudioPlayer) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.appSurface2)
                    .frame(height: 3)
                Capsule()
                    .fill(Color.accentVolt)
                    .frame(
                        width: geo.size.width * max(0, min(1, player.progress)),
                        height: 3
                    )
            }
        }
        .frame(height: 3)
    }

    // MARK: - Ask-the-Coach placeholder

    /// "💬 Ask the Coach" affordance. Disabled today — when the multi-turn
    /// feature lands, parents pass `onAsk` and this becomes a real button.
    /// In the meantime it shows in DEBUG only as a "Coming soon" tag so
    /// the layout doesn't shift when the feature arrives.
    @ViewBuilder
    private func askPlaceholderIfNeeded() -> some View {
        if let onAsk {
            Button(action: onAsk) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Ask the Coach")
                        .font(AppFont.ui(12, weight: .semibold))
                }
                .foregroundStyle(Color.accentInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .stroke(Color.appBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        } else {
            #if DEBUG
            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10, weight: .medium))
                Text("Ask the Coach · coming soon")
                    .font(AppFont.mono(10, weight: .medium))
            }
            .foregroundStyle(Color.textTertiary)
            #endif
        }
    }

    // MARK: - DEBUG sections

    #if DEBUG
    /// Two collapsible disclosures (matching `CoachFeedbackCard`'s
    /// pattern): every fact the rule pass produced + the underlying
    /// CoachContext numbers. Compiled out in Release.
    @ViewBuilder
    private func debugSections(
        facts: CoachFacts,
        context: ProgressCoachContext?
    ) -> some View {
        Divider().padding(.vertical, Space.x1)

        DisclosureGroup {
            VStack(alignment: .leading, spacing: Space.x2) {
                if facts.all.isEmpty {
                    Text("(no facts produced)")
                        .font(AppFont.mono(11))
                        .foregroundStyle(Color.textTertiary)
                }
                ForEach(facts.all) { fact in
                    HStack(alignment: .top, spacing: Space.x2) {
                        Circle()
                            .fill(severityColor(for: fact.severity))
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(interpolated(fact.templateKey, with: fact.values))
                                .font(AppFont.ui(13, weight: .medium))
                                .foregroundStyle(Color.textPrimary)
                            Text(fact.templateKey)
                                .font(AppFont.mono(10))
                                .foregroundStyle(Color.textTertiary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.top, Space.x2)
        } label: {
            Text("DEBUG · all facts (\(facts.all.count))")
                .font(AppFont.mono(11, weight: .bold))
                .foregroundStyle(Color.textSecondary)
        }

        if let context {
            DisclosureGroup {
                contextReadout(context).padding(.top, Space.x2)
            } label: {
                Text("DEBUG · context")
                    .font(AppFont.mono(11, weight: .bold))
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    /// Compact key/value table of `ProgressCoachContext`. Lets a tuning
    /// loop see "why did the focus selector pick X?" without re-reading
    /// the rule code.
    private func contextReadout(_ ctx: ProgressCoachContext) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row("focus",        ctx.focus.rawString)
            row("day",          "\(ctx.day) of \(ctx.totalDays) (\(ctx.phase.rawValue))")
            row("today",        "\(ctx.actualMinutesToday) min / \(ctx.targetMinutesToday) min")
            row("CTL",          String(format: "%.1f (Δ %+.1f)", ctx.load.ctlToday, ctx.load.ctlDelta))
            row("ATL",          String(format: "%.1f", ctx.load.atlToday))
            row("TSB",          String(format: "%+.1f", ctx.load.tsbToday))
            row("workouts /7",  "\(ctx.workoutDaysLast7)")
            row("streak",       "\(ctx.adherence.currentStreakDays) (longest \(ctx.adherence.longestStreakDays))")
            row("missed /wk",   "\(ctx.adherence.missedDaysThisWeek)")
            row("return?",      ctx.adherence.isReturnAfterBreak ? "yes" : "no")
            if let last = ctx.mostRecentWorkout {
                row("last",     "\(last.daysAgo)d ago · \(last.durationMinutes)m")
            } else {
                row("last",     "—")
            }
            if let v = ctx.vo2Max {
                row("VO₂Max",   String(format: "%.1f (Δ %+.1f, n=%d)", v.latest, v.delta, v.sampleCount))
            } else {
                row("VO₂Max",   "—")
            }
            if let h = ctx.hrv {
                row("HRV",      String(format: "%.0f ms (Δ %+.0f, n=%d)", h.latest, h.delta, h.sampleCount))
            } else {
                row("HRV",      "—")
            }
            row("fingerprint",  ctx.fingerprint)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
            Text(label)
                .font(AppFont.mono(10, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(AppFont.mono(10))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }
    #endif

    // MARK: - Template interpolation

    /// Same NSLocalizedString-based interpolation as `CoachFeedbackCard`.
    /// Keeps copy out of code so EN/ES catalog stays the single source.
    /// Falls back to `Self.englishFallback` when the catalog has no entry
    /// for the key (the case during initial rollout, before the new
    /// Progress-coach keys land in `Localizable.xcstrings`) — without it,
    /// the bullet would render the raw template key, which looks broken.
    private func interpolated(_ key: String, with values: [String: String]) -> String {
        let template = NSLocalizedString(key, comment: "Progress coach fact template")
        // NSLocalizedString returns the key itself when no localization is
        // found. Detect that and substitute the inline fallback.
        let resolved = (template == key) ? (Self.englishFallback[key] ?? template) : template
        var result = resolved
        for (k, v) in values {
            result = result.replacingOccurrences(of: "%{\(k)}%", with: v)
        }
        return result
    }

    /// Inline EN copy for the keys `ProgressDeterministicCoach` emits.
    /// Mirrors what would live in `Localizable.xcstrings` once the
    /// catalog catches up — kept here so DEBUG renders and
    /// no-narrator-key users see real English instead of raw keys.
    /// When the keys land in the catalog, NSLocalizedString returns the
    /// catalog version directly and this dictionary becomes dead code
    /// that's safe to remove.
    private static let englishFallback: [String: String] = [
        "fact.progress.milestone":
            "Day %{day}% of %{total}% — checkpoint.",
        "fact.progress.return_after_break":
            "Back at it after a few days off. Day %{day}%.",
        "fact.progress.recovery_deficit":
            "TSB %{tsb}% — accumulated fatigue is real (CTL %{ctl}%, ATL %{atl}%).",
        "fact.progress.behind_pace":
            "%{missed}% missed days this week — day %{day}% of %{total}%.",
        "fact.progress.fitness_rising":
            "Training load up %{delta}% over the last 7 days (CTL now %{ctl}%).",
        "fact.progress.fitness_falling":
            "Training load drifting down — CTL off %{delta}% this week (now %{ctl}%).",
        "fact.progress.streak_locking_in":
            "%{streak}%-day streak — the habit is locking in.",
        "fact.progress.vo2_rising":
            "VO₂Max trending up — latest %{latest}%, +%{delta}% over the window.",
        "fact.progress.vo2_falling":
            "VO₂Max easing — latest %{latest}%, −%{delta}% over the window.",
        "fact.progress.hrv_rising":
            "HRV up %{delta}% ms over the window — body's recovering.",
        "fact.progress.hrv_falling":
            "HRV down %{delta}% ms over the window — load is biting.",
        "fact.progress.on_track":
            "Day %{day}% of %{total}% — holding the line.",
        "fact.progress.day_position":
            "Day %{day}% of %{total}% (%{phase}% phase).",
        "fact.progress.last_workout":
            "Last workout: %{days_ago}% day(s) ago, %{minutes}% min %{type}%."
    ]
}

// MARK: - Preview

#Preview("Loading") {
    ProgressCoachCard(state: .loading)
        .padding()
        .background(Color.appBg)
}

#Preview("Bulleted (no narrator)") {
    let ctx = ProgressCoachContext(
        day: 18,
        totalDays: 90,
        phase: .early,
        targetMinutesToday: 24,
        actualMinutesToday: 0,
        mostRecentWorkout: RecentWorkoutSummary(
            date: Date().addingDays(-1),
            durationMinutes: 32,
            typeName: "Cycling",
            daysAgo: 1
        ),
        workoutDaysLast7: 4,
        load: TrainingLoadSnapshot(
            ctlToday: 47,
            ctl7DaysAgo: 43,
            atlToday: 52
        ),
        adherence: AdherenceSnapshot(
            currentStreakDays: 6,
            longestStreakDays: 6,
            missedDaysThisWeek: 0,
            isReturnAfterBreak: false
        ),
        vo2Max: PhysiologyTrend(latest: 47, delta: 1.8, sampleCount: 5),
        hrv: nil,
        focus: .fitnessRising,
        locale: .current
    )
    return ProgressCoachCard(state: .ready(
        facts: CoachFacts(all: [
            CoachFact(
                kind: .fitnessTrend,
                severity: .notable,
                templateKey: "fact.progress.fitness_rising",
                values: ["delta": "4.0", "ctl": "47"]
            )
        ]),
        body: nil,
        context: ctx,
        audioURL: nil
    ))
    .padding()
    .background(Color.appBg)
}

#Preview("Narrative + tap-to-play") {
    let ctx = ProgressCoachContext(
        day: 42,
        totalDays: 90,
        phase: .mid,
        targetMinutesToday: 38,
        actualMinutesToday: 0,
        mostRecentWorkout: RecentWorkoutSummary(
            date: Date().addingDays(-1),
            durationMinutes: 45,
            typeName: "Running",
            daysAgo: 1
        ),
        workoutDaysLast7: 5,
        load: TrainingLoadSnapshot(
            ctlToday: 58,
            ctl7DaysAgo: 53,
            atlToday: 62
        ),
        adherence: AdherenceSnapshot(
            currentStreakDays: 9,
            longestStreakDays: 9,
            missedDaysThisWeek: 0,
            isReturnAfterBreak: false
        ),
        vo2Max: PhysiologyTrend(latest: 49, delta: 2.1, sampleCount: 7),
        hrv: PhysiologyTrend(latest: 58, delta: 6, sampleCount: 12),
        focus: .fitnessRising,
        locale: .current
    )
    return ProgressCoachCard(
        state: .ready(
            facts: CoachFacts(all: [
                CoachFact(
                    kind: .fitnessTrend,
                    severity: .notable,
                    templateKey: "fact.progress.fitness_rising",
                    values: ["delta": "5.0", "ctl": "58"]
                )
            ]),
            body: "CTL is your 42-day rolling fitness average — a sense of how much training your body is carrying. Yours is up 5 points this week to 58, which is why this stretch may feel a touch heavier than three weeks ago. Hold the line on Z2 minutes; the body is adapting.",
            context: ctx,
            audioURL: nil
        ),
        audioPlayer: nil
    )
    .padding()
    .background(Color.appBg)
}
