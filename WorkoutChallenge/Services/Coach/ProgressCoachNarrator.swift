//
//  ProgressCoachNarrator.swift
//  WorkoutChallenge
//
//  Layer 2 for the Progress-tab coach card. Sibling of `CoachNarrator`
//  but with a different persona and a slightly longer cap.
//
//  Design choices:
//
//    • Teach-then-comment voice. The Progress surface earns the "teacher"
//      framing — the user is staring at a CTL line and a VO₂Max overlay
//      and wants to know what they mean. The post-workout coach cannot
//      do this without bloating the audio; the Progress coach can,
//      because it's tap-to-listen rather than auto-played.
//
//    • 3-5 sentences (vs. 2-4 for post-workout). The teach beat takes
//      one sentence; the observation beat takes 1-2; the call-forward
//      beat takes 0-1. Brevity is still the discipline — this isn't a
//      lecture, it's a couple of grounded sentences with one concept
//      defined in plain language.
//
//    • One focus only. The deterministic pass already picked the lead.
//      The narrator must NOT weave; that's what differentiates this
//      surface from the workout-flow card.
//
//  Implementation: same Anthropic plumbing as `AnthropicNarrator`, but
//  with its own system prompt + user-message format. Kept as a separate
//  protocol so future surfaces (Daily Briefing, etc.) can adopt the
//  pattern without polluting `CoachNarrator`.
//

import Foundation

protocol ProgressCoachNarrator: Sendable {
    /// Produce 3-5 sentences of grounded, teach-then-comment prose for
    /// the Progress-tab coach card. Implementations should:
    ///
    ///   • Lead with one short concept-definition sentence aimed at the
    ///     focus (e.g. "CTL is your 42-day rolling fitness average.")
    ///     when the focus implies a metric the user might not know.
    ///   • Follow with the observation grounded in CONTEXT numbers.
    ///   • End with at most one forward-looking implication ("expect
    ///     this week to feel a touch heavier"). Never a prescription.
    ///   • Honor `context.locale` for output language.
    ///   • Stay 3-5 sentences total. Audio reads this aloud.
    func narrate(facts: CoachFacts, context: ProgressCoachContext) async throws -> String
}

// MARK: - Anthropic implementation (extension on AnthropicNarrator)

extension AnthropicNarrator: ProgressCoachNarrator {

    /// System prompt for the Progress surface. Different persona than the
    /// post-workout system prompt: this one is allowed (encouraged, even)
    /// to define a concept in plain language before commenting on it. The
    /// post-workout coach can't afford that beat; the Progress coach can.
    static let progressSystemPrompt: String = """
    You are a calm, plain-spoken endurance coach who also teaches. The user \
    is looking at the Progress tab — a sigmoid target curve and a fitness-\
    trend chart with CTL (training load) and VO₂Max overlays. They want \
    to understand the picture, not be cheered on.

    Hard rules, in priority order:

    1. 3 to 5 sentences. Audio reads this aloud — brevity is the \
    discipline even when teaching.

    2. Lead with the focus the FACTS section names. Never weave multiple \
    notable signals — pick the one and stay with it.

    3. When the focus implies a metric the user might not know (CTL, ATL, \
    TSB, VO₂Max, HRV), open with one short plain-language definition \
    BEFORE the observation. Examples:
       • "CTL is your 42-day rolling fitness average."
       • "TSB is freshness — fitness minus recent fatigue."
       • "VO₂Max is the ceiling on how much oxygen your engine can use."
    Skip the definition only when the focus is purely behavioral \
    (streak, milestone, return-after-break, on-track).

    4. Ground EVERY observation in a number from FACTS or CONTEXT. No \
    generic encouragement. No "great job!" No emojis.

    5. Speak in the present. At most one forward-looking sentence — \
    "expect this week to feel a touch heavier" is fine; "you'll PR by day \
    60" is not.

    6. Tone is the future-self-as-coach voice — terse, evidence-based, \
    second-person. You speak directly to present-Kurt. Not chirpy, not \
    grim. Calm.

    7. Match the user's locale when given (en or es). Default to en.

    8. Never use "amazing", "awesome", "crushing it", or any similar \
    app-speak. You're a real person in his head, not a notification.

    9. When focus is `.none`, return one short sentence acknowledging the \
    quiet patch — no embellishment, no false motivation.
    """

    func narrate(facts: CoachFacts, context ctx: ProgressCoachContext) async throws -> String {
        guard let apiKey = CoachKeychain.token(for: .anthropic), !apiKey.isEmpty else {
            throw NarratorError.missingAPIKey
        }

        let userMessage = Self.buildProgressUserMessage(facts: facts, context: ctx)

        // Reuse the same wire types via the public POST helper. We can't
        // call the private `RequestBody` from the post-workout narrator,
        // so we build the request inline. Same model/tokens/temperature
        // as post-workout — those knobs are already calibrated.
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        // Bumped maxTokens slightly (240 → 320) because Progress prose is
        // 3-5 sentences with a teach beat vs. 2-4 sentences post-workout.
        // Still tight — this is not a license to ramble.
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 320,
            "temperature": temperature,
            "system": Self.progressSystemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NarratorError.unexpectedResponse
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw NarratorError.unauthorized
        case 429:
            throw NarratorError.rateLimited
        default:
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NarratorError.httpError(status: http.statusCode, body: bodyText)
        }

        // Decode minimally — we only need the first text block.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String,
              !text.isEmpty
        else {
            throw NarratorError.emptyResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// User-message format mirrors the post-workout structure (FACTS +
    /// CONTEXT + ASK) so prompt-engineering gains transfer between
    /// surfaces, but the CONTEXT block carries Progress-specific numbers
    /// (VO₂Max + HRV trends, days-since-last-workout, focus).
    private static func buildProgressUserMessage(
        facts: CoachFacts,
        context ctx: ProgressCoachContext
    ) -> String {
        var lines: [String] = []

        lines.append("FACTS (deterministic rule pass — already picked one focus):")
        if facts.all.isEmpty {
            lines.append("  (none — nothing notable today; one short calm sentence acknowledging the quiet)")
        } else {
            for fact in facts.all {
                let valuesPart = fact.values.isEmpty
                    ? ""
                    : " values=" + fact.values.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
                lines.append("  - [\(fact.severity.label)] \(fact.templateKey)\(valuesPart) (kind=\(fact.kind.rawValue))")
            }
        }

        lines.append("")
        lines.append("CONTEXT (raw numbers behind the focus):")
        lines.append("  focus: \(ctx.focus.rawString)")
        lines.append("  day: \(ctx.day) of \(ctx.totalDays) (\(ctx.phase.rawValue) phase)")
        lines.append("  today_minutes: \(ctx.actualMinutesToday) (target \(ctx.targetMinutesToday))")
        lines.append("  CTL_today: \(String(format: "%.1f", ctx.load.ctlToday))")
        lines.append("  CTL_7d_ago: \(String(format: "%.1f", ctx.load.ctl7DaysAgo)) (delta \(String(format: "%+.1f", ctx.load.ctlDelta)))")
        lines.append("  ATL_today: \(String(format: "%.1f", ctx.load.atlToday))")
        lines.append("  TSB_today: \(String(format: "%+.1f", ctx.load.tsbToday))")
        lines.append("  workouts_last_7_days: \(ctx.workoutDaysLast7)")
        lines.append("  current_streak: \(ctx.adherence.currentStreakDays)")
        lines.append("  longest_streak: \(ctx.adherence.longestStreakDays)")
        lines.append("  missed_this_week: \(ctx.adherence.missedDaysThisWeek)")
        lines.append("  return_after_break: \(ctx.adherence.isReturnAfterBreak)")

        if let recent = ctx.mostRecentWorkout {
            let typePart = recent.typeName.map { " (\($0))" } ?? ""
            lines.append("  last_workout: \(recent.daysAgo) day(s) ago, \(recent.durationMinutes) min\(typePart)")
        } else {
            lines.append("  last_workout: none yet")
        }

        if let vo2 = ctx.vo2Max {
            lines.append("  VO2max_latest: \(String(format: "%.1f", vo2.latest)) mL/(kg·min) (delta \(String(format: "%+.1f", vo2.delta)) over \(vo2.sampleCount) samples)")
        } else {
            lines.append("  VO2max: no samples in window")
        }

        if let hrv = ctx.hrv {
            lines.append("  HRV_latest: \(String(format: "%.0f", hrv.latest)) ms (delta \(String(format: "%+.0f", hrv.delta)) over \(hrv.sampleCount) samples)")
        } else {
            lines.append("  HRV: no samples in window")
        }

        lines.append("  locale: \(ctx.locale.identifier)")

        lines.append("")
        lines.append("ASK: Write 3-5 sentences for present-Kurt looking at the Progress tab. Lead with the focus. If the focus implies a metric (CTL, TSB, VO2Max, HRV), open with one short plain-language definition before the observation. Cite specific numbers from CONTEXT. Plain prose only — no lists, no headers, no quotes.")

        return lines.joined(separator: "\n")
    }
}

// MARK: - CoachFact severity label
//
// Same fileprivate label extension as in `AnthropicNarrator.swift`. We
// can't share the one over there because it's `private`, and bumping it
// to `internal` would leak labels into the rest of the app. Cheap
// duplication.

private extension CoachFact.Severity {
    var label: String {
        switch self {
        case .quiet:   return "quiet"
        case .normal:  return "normal"
        case .notable: return "NOTABLE"
        }
    }
}
