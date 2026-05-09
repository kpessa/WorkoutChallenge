//
//  CoachFeedbackCard.swift
//  WorkoutChallenge
//
//  The post-workout reflection surface — Layer 1 (deterministic) renders
//  bullets, Layer 2 (LLM narrator) will render prose, Layer 3 (TTS) will
//  add a play button.
//
//  Render policy at Layer 1:
//    • Release builds: render only when there's at least one `.notable`
//      fact. Show up to 3 notable bullets, severity-aware styling. The
//      "coach earns the right to speak" UX rule lives at this gate.
//    • DEBUG builds: render any time the loader is `.ready`. Notable
//      bullets render as the primary content (same as Release). Below
//      them, a "Show all facts" disclosure exposes every fact the rule
//      pass produced — including `.normal` and `.quiet` ones — with
//      template keys + severity, so you can tell whether a rule fired
//      and was suppressed vs. didn't fire at all. A second "Context"
//      disclosure shows the underlying numbers (day, CTL, ATL, TSB,
//      streak, etc.) so you can debug "why did/didn't rule X fire?"
//      without re-reading the source.
//
//  Each fact is rendered via `LocalizedStringKey(templateKey)`, with the
//  `values` dict substituted at render time. Strings live in
//  `Localizable.xcstrings` and use `%{key}%`-style placeholders that the
//  `interpolated` helper expands. Keeping copy out of code keeps the
//  EN/ES catalog as the single source of truth.
//

import SwiftUI

struct CoachFeedbackCard: View {
    let state: CoachFeedbackLoader.State
    /// Optional audio player. When non-nil, narrative cards render a play
    /// button next to the prose. The card never instantiates a player —
    /// the parent view owns playback so it can stop on dismiss.
    let audioPlayer: CoachAudioPlayer?

    init(state: CoachFeedbackLoader.State, audioPlayer: CoachAudioPlayer? = nil) {
        self.state = state
        self.audioPlayer = audioPlayer
    }

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case .loading:
            loadingPlaceholder

        case .failed:
            // Silent failure in Release — no alarm. The deterministic pass
            // can't really fail except through HK fan-out errors during
            // context building, and even then the rule pass would still
            // produce facts. In DEBUG, surface the failure copy so the
            // tuning loop sees what went wrong.
            #if DEBUG
            failureCard
            #else
            EmptyView()
            #endif

        case .ready(let facts, let body, let context, let audioURL):
            if let body, !body.isEmpty {
                narrativeCard(body: body, facts: facts, context: context, audioURL: audioURL)
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

    // MARK: - Loading

    private var loadingPlaceholder: some View {
        AppSection(title: "Coach") {
            HStack(spacing: Space.x3) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.accentInk)
                Text("Reflecting on this workout…")
                    .font(AppFont.ui(13, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
            }
        }
    }

    // MARK: - Failure (DEBUG only)

    #if DEBUG
    private var failureCard: some View {
        AppSection(title: "Coach") {
            VStack(alignment: .leading, spacing: Space.x2) {
                Text("[DEBUG] Loader failed")
                    .font(AppFont.mono(11, weight: .bold))
                    .foregroundStyle(Color.danger)
                if case .failed(let msg) = state {
                    Text(msg)
                        .font(AppFont.mono(11))
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
    }
    #endif

    // MARK: - Bulleted (Layer 1) card

    /// Up to 3 notable facts, ordered as the deterministic pass emitted
    /// them. The 3-bullet cap is a calibration knob — more than 3 starts
    /// to feel like a list and less like an observation.
    private func bulletedCard(facts: CoachFacts, context: CoachContext?) -> some View {
        let notable = Array(facts.notable.prefix(3))

        return AppSection(title: "Coach") {
            VStack(alignment: .leading, spacing: Space.x3) {
                ForEach(notable) { fact in
                    bulletRow(for: fact, showTemplateKey: false)
                }
                #if DEBUG
                debugSections(facts: facts, context: context)
                #endif
            }
        }
    }

    /// A "DEBUG-only" version of the card that renders even when no
    /// notable facts crossed the threshold. Useful for tuning — lets you
    /// see what the rule pass thought about every workout, including the
    /// quiet ones.
    #if DEBUG
    private func debugOnlyCard(facts: CoachFacts, context: CoachContext?) -> some View {
        AppSection(title: "Coach") {
            VStack(alignment: .leading, spacing: Space.x3) {
                Text("[DEBUG] No notable facts. Coach stayed silent.")
                    .font(AppFont.mono(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
                debugSections(facts: facts, context: context)
            }
        }
    }
    #endif

    // MARK: - Bullet row

    private func bulletRow(for fact: CoachFact, showTemplateKey: Bool) -> some View {
        HStack(alignment: .top, spacing: Space.x3) {
            Circle()
                .fill(severityColor(for: fact.severity))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(interpolated(fact.templateKey, with: fact.values))
                    .font(AppFont.ui(14, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if showTemplateKey {
                    Text(fact.templateKey)
                        .font(AppFont.mono(10))
                        .foregroundStyle(Color.textTertiary)
                }
            }
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

    // MARK: - Narrative (Layer 2+) card

    /// Rendered when an LLM narrator has produced prose. Includes a play
    /// button when audio has been synthesized + cached on disk.
    private func narrativeCard(body: String, facts: CoachFacts, context: CoachContext?, audioURL: URL?) -> some View {
        AppSection(title: "Coach") {
            VStack(alignment: .leading, spacing: Space.x3) {
                Text(body)
                    .font(AppFont.ui(15, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let audioURL, let player = audioPlayer {
                    audioControls(url: audioURL, player: player)
                }

                #if DEBUG
                debugSections(facts: facts, context: context)
                #endif
            }
        }
    }

    /// Play / pause button + lightweight progress bar. Tap toggles
    /// playback; long-running playback shows a thin Volt-tinted bar
    /// underneath. Errors collapse to a re-tappable play button — we
    /// never alarm in the workout flow.
    @ViewBuilder
    private func audioControls(url: URL, player: CoachAudioPlayer) -> some View {
        HStack(spacing: Space.x3) {
            Button(action: { handlePlayTap(url: url, player: player) }) {
                ZStack {
                    Circle()
                        .fill(Color.accentVolt)
                        .frame(width: 36, height: 36)
                    Image(systemName: playButtonIcon(for: player.state))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.04))
                        // Nudge play triangle visually right of center.
                        .offset(x: player.state == .playing ? 0 : 1)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(playStatusLabel(for: player.state))
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

    private func playButtonIcon(for state: CoachAudioPlayer.State) -> String {
        switch state {
        case .playing: return "pause.fill"
        case .loading: return "ellipsis"
        case .paused:  return "play.fill"
        case .error:   return "play.fill"
        case .idle:    return "play.fill"
        }
    }

    private func playStatusLabel(for state: CoachAudioPlayer.State) -> String {
        switch state {
        case .idle:    return "Tap to listen"
        case .loading: return "Loading…"
        case .playing: return "Playing"
        case .paused:  return "Paused"
        case .error:   return "Tap to retry"
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
                    .frame(width: geo.size.width * max(0, min(1, player.progress)), height: 3)
            }
        }
        .frame(height: 3)
    }

    // MARK: - DEBUG sections

    #if DEBUG
    /// Two collapsible disclosures shown under the primary content in
    /// DEBUG builds: every fact the rule pass produced (with template
    /// keys + severity) and the underlying CoachContext numbers. Compiled
    /// out entirely in Release builds via `#if DEBUG`.
    @ViewBuilder
    private func debugSections(facts: CoachFacts, context: CoachContext?) -> some View {
        Divider()
            .padding(.vertical, Space.x1)

        DisclosureGroup {
            VStack(alignment: .leading, spacing: Space.x2) {
                if facts.all.isEmpty {
                    Text("(no facts produced)")
                        .font(AppFont.mono(11))
                        .foregroundStyle(Color.textTertiary)
                }
                ForEach(facts.all) { fact in
                    bulletRow(for: fact, showTemplateKey: true)
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
                contextReadout(context)
                    .padding(.top, Space.x2)
            } label: {
                Text("DEBUG · context")
                    .font(AppFont.mono(11, weight: .bold))
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    /// Compact key/value table of the underlying CoachContext. Each row
    /// is a number that fed the rule pass — the goal is "if a rule didn't
    /// fire, you can see why from these numbers."
    private func contextReadout(_ ctx: CoachContext) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row("day",         "\(ctx.day) of \(ctx.totalDays) (\(ctx.phase.rawValue))")
            row("today",       "\(ctx.actualMinutesToday) min / \(ctx.targetMinutesToday) min target")
            row("CTL today",   String(format: "%.1f", ctx.load.ctlToday))
            row("CTL 7d ago",  String(format: "%.1f (Δ %+.1f)", ctx.load.ctl7DaysAgo, ctx.load.ctlDelta))
            row("ATL today",   String(format: "%.1f", ctx.load.atlToday))
            row("TSB today",   String(format: "%+.1f", ctx.load.tsbToday))
            row("workouts /7", "\(ctx.workoutDaysLast7) days w/ workouts")
            row("streak",      "\(ctx.adherence.currentStreakDays) day(s) — longest \(ctx.adherence.longestStreakDays)")
            row("missed /wk",  "\(ctx.adherence.missedDaysThisWeek)")
            row("return?",     ctx.adherence.isReturnAfterBreak ? "yes (≥2 day gap)" : "no")
            if let avg = ctx.avgHR {
                row("avg HR",  "\(Int(avg.rounded())) bpm")
            } else {
                row("avg HR",  "—")
            }
            if let trend = ctx.hrAtPaceTrend {
                row("HR drift",
                    String(format: "%+.1f bpm vs %d-workout baseline",
                           trend.deltaBPM, trend.baselineSampleCount))
            } else {
                row("HR drift", "— (no comparable history)")
            }
            if let zones = ctx.zones, zones.totalSeconds > 0 {
                let z12 = zones.seconds(in: HeartRateZone.z1) + zones.seconds(in: HeartRateZone.z2)
                let z45 = zones.seconds(in: HeartRateZone.z4) + zones.seconds(in: HeartRateZone.z5)
                let aerobicPct = Int((z12 / zones.totalSeconds * 100).rounded())
                let intensePct = Int((z45 / zones.totalSeconds * 100).rounded())
                row("zones",   "Z1+Z2 \(aerobicPct)% / Z4+Z5 \(intensePct)%")
            } else {
                row("zones",   "— (no HR samples)")
            }
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
            Spacer()
        }
    }
    #endif

    // MARK: - Template interpolation

    /// Look up the localized template for `key`, then expand any
    /// `%{name}%` placeholders against `values`. Falls back to the raw
    /// template (no substitution) if a placeholder has no value — better
    /// to ship odd copy than to crash on a missing key.
    private func interpolated(_ key: String, with values: [String: String]) -> String {
        let template = NSLocalizedString(key, comment: "Coach fact template")
        var result = template
        for (k, v) in values {
            result = result.replacingOccurrences(of: "%{\(k)}%", with: v)
        }
        return result
    }
}

// MARK: - Preview

#Preview("Notable facts") {
    VStack {
        CoachFeedbackCard(state: .ready(
            facts: CoachFacts(all: [
                CoachFact(
                    kind: .fitnessTrend,
                    severity: .notable,
                    templateKey: "fact.ctl.rising",
                    values: ["delta": "4.2", "ctl": "47"]
                ),
                CoachFact(
                    kind: .adherence,
                    severity: .notable,
                    templateKey: "fact.early.consistency_locking_in",
                    values: ["streak": "6"]
                )
            ]),
            body: nil,
            context: nil,
            audioURL: nil
        ))
        .padding()
    }
}

#Preview("Loading") {
    CoachFeedbackCard(state: .loading)
        .padding()
}

#Preview("No notable facts (DEBUG: shows debug-only card)") {
    CoachFeedbackCard(state: .ready(facts: .empty, body: nil, context: nil, audioURL: nil))
        .padding()
}
