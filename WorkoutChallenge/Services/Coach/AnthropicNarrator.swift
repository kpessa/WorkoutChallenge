//
//  AnthropicNarrator.swift
//  WorkoutChallenge
//
//  Anthropic Messages API narrator for the calibrated coach. Calls
//  claude-sonnet-4-6 via POST /v1/messages with a future-self-as-coach
//  system prompt and a structured user message that hands the model the
//  deterministic facts as JSON plus a compact context readout.
//
//  Pricing (rough): ~2k input tokens + ~150 output tokens per call ≈
//  $0.008–0.012. At one feedback per workout × 90 workouts ≈ $1 per
//  challenge. Constraint is taste, not wallet.
//
//  Token plumbing: API key comes from `CoachKeychain` slot `.anthropic`.
//  No fallback to an env var or compiled-in key — if the slot is empty,
//  `narrate(...)` throws `.missingAPIKey` and the loader silently falls
//  back to deterministic bullets.
//

import Foundation

struct AnthropicNarrator: CoachNarrator {

    // MARK: - Config

    /// Model selection. Sonnet 4.6 is the right default — Opus is overkill
    /// for 4 sentences, Haiku may underread the nuance in elevated-HR /
    /// fatigue trade-offs that matter in this UX.
    let model: String

    /// Maximum output tokens. Keeping this tight is itself a calibration:
    /// the brevity is the discipline. Bumping it past ~250 produces longer
    /// responses that lose the "one observation, not a lecture" feel.
    let maxTokens: Int

    /// Sampling temperature. Slight randomness so two consecutive workouts
    /// don't produce identical-looking phrasings, but kept low so the
    /// output stays grounded in the facts.
    let temperature: Double

    init(
        model: String = "claude-sonnet-4-6",
        maxTokens: Int = 240,
        temperature: Double = 0.4
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    // MARK: - System prompt

    /// The persona. Written carefully — voice (Layer 3) will read this
    /// aloud in Kurt's cloned voice, so the prose must sound like
    /// something *he* would actually say to himself. Generic-fitness-app
    /// cheer in Kurt's own voice would feel uncanny.
    static let systemPrompt: String = """
    You are Kurt three years from now, looking back at the workout he just \
    finished. You're not a generic fitness coach. You know him too well to \
    bullshit him. You speak directly to present-Kurt — second person, \
    terse, evidence-based.

    Hard rules, in priority order:

    1. Always ground every claim in a number from the FACTS or CONTEXT \
    blocks below. No generic encouragement. No "great job!" No emojis.

    2. 2 to 4 sentences. Audio reads this aloud — brevity is the \
    discipline. If you have nothing specific to say, default to one \
    short sentence that names what you saw, not a paragraph.

    3. If the facts include a return-after-break observation, lead with \
    the return — not the gap. Showing up after missing days is the \
    behavior to reinforce.

    4. Speak in the present tense about what happened today. Avoid \
    predictions ("you'll feel great tomorrow"). Observations only.

    5. If multiple facts are notable, weave them — don't list them. The \
    output should feel like one thought, not three.

    5a. In the first 21 days of a challenge, frame target minutes as the \
    sigmoid minimum floor for building the habit. Do not turn early wins \
    into CTL/TSB commentary unless fatigue is genuinely urgent.

    6. Elevated-HR or deep-fatigue observations are honest, not alarming. \
    Name what the data shows; offer one possible cause; don't diagnose. \
    Example tone: "HR is 18 over baseline — sleep, heat, or fighting \
    something off." Not: "You should rest immediately."

    7. Match the user's locale when given (en or es). Default to en.

    8. Never use the word "amazing", "awesome", "crushing it", or any \
    similar app-speak. You're a real person in his head, not a notification.
    """

    // MARK: - Narrate

    func narrate(facts: CoachFacts, context: CoachContext) async throws -> String {
        guard let apiKey = CoachKeychain.token(for: .anthropic), !apiKey.isEmpty else {
            throw NarratorError.missingAPIKey
        }

        let userMessage = Self.buildUserMessage(facts: facts, context: context)
        let body = RequestBody(
            model: model,
            max_tokens: maxTokens,
            temperature: temperature,
            system: Self.systemPrompt,
            messages: [
                Message(role: "user", content: userMessage)
            ]
        )

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(body)

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
            // Try to surface the error message from the body so the user
            // sees something useful in the Settings "Test" result.
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NarratorError.httpError(status: http.statusCode, body: bodyText)
        }

        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text,
              !text.isEmpty
        else {
            throw NarratorError.emptyResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compact, structured user message. We hand the model:
    ///   • A small JSON-shaped FACTS block with templateKey + values per fact
    ///   • A compact CONTEXT block with the numbers behind the facts
    ///   • An explicit ASK that re-states the format constraint
    /// Keeping the prompt deterministic in shape means we can swap the
    /// system prompt without re-tuning the user-message structure.
    private static func buildUserMessage(facts: CoachFacts, context ctx: CoachContext) -> String {
        var lines: [String] = []

        lines.append("FACTS (deterministic rule pass — already filtered to what's worth saying):")
        if facts.all.isEmpty {
            lines.append("  (none — say one short sentence acknowledging the workout, no embellishment)")
        } else {
            for fact in facts.all {
                let valuesPart = fact.values.isEmpty
                    ? ""
                    : " values=" + fact.values.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
                lines.append("  - [\(fact.severity.label)] \(fact.templateKey)\(valuesPart) (kind=\(fact.kind.rawValue))")
            }
        }

        lines.append("")
        lines.append("CONTEXT (raw numbers feeding the facts):")
        lines.append("  day: \(ctx.day) of \(ctx.totalDays) (\(ctx.phase.rawValue))")
        lines.append("  today_minutes: \(ctx.actualMinutesToday) (target \(ctx.targetMinutesToday))")
        lines.append("  sigmoid_target_role: minimum floor, especially during days 1-21")
        lines.append("  CTL_today: \(String(format: "%.1f", ctx.load.ctlToday))")
        lines.append("  CTL_7d_ago: \(String(format: "%.1f", ctx.load.ctl7DaysAgo)) (delta \(String(format: "%+.1f", ctx.load.ctlDelta)))")
        lines.append("  ATL_today: \(String(format: "%.1f", ctx.load.atlToday))")
        lines.append("  TSB_today: \(String(format: "%+.1f", ctx.load.tsbToday))")
        lines.append("  workouts_last_7_days: \(ctx.workoutDaysLast7)")
        lines.append("  current_streak: \(ctx.adherence.currentStreakDays)")
        lines.append("  longest_streak: \(ctx.adherence.longestStreakDays)")
        lines.append("  missed_this_week: \(ctx.adherence.missedDaysThisWeek)")
        lines.append("  return_after_break: \(ctx.adherence.isReturnAfterBreak)")
        if let avgHR = ctx.avgHR {
            lines.append("  avg_HR_today: \(Int(avgHR.rounded())) bpm")
        }
        if let trend = ctx.hrAtPaceTrend {
            lines.append("  HR_drift_vs_baseline: \(String(format: "%+.1f", trend.deltaBPM)) bpm (n=\(trend.baselineSampleCount))")
        }
        if let zones = ctx.zones, zones.totalSeconds > 0 {
            let z12 = zones.seconds(in: HeartRateZone.z1) + zones.seconds(in: HeartRateZone.z2)
            let z45 = zones.seconds(in: HeartRateZone.z4) + zones.seconds(in: HeartRateZone.z5)
            let aerobicPct = Int((z12 / zones.totalSeconds * 100).rounded())
            let intensePct = Int((z45 / zones.totalSeconds * 100).rounded())
            lines.append("  zones: Z1+Z2 \(aerobicPct)% / Z4+Z5 \(intensePct)%")
        }
        if let workoutType = ctx.workout.typeName {
            lines.append("  workout_type: \(workoutType)")
        }
        lines.append("  locale: \(ctx.locale.identifier)")

        lines.append("")
        lines.append("ASK: Write 2-4 sentences for present-Kurt. Lead with the most notable fact. Cite specific numbers from CONTEXT. Plain prose only — no lists, no headers, no quotes.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Codable wire types

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let temperature: Double
        let system: String
        let messages: [Message]
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct MessagesResponse: Decodable {
        let content: [ContentBlock]
    }

    private struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}

// MARK: - Errors

enum NarratorError: LocalizedError {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case unexpectedResponse
    case httpError(status: Int, body: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key set. Add one in Settings → Coach."
        case .unauthorized:
            return "API key was rejected. Check the key in Settings → Coach."
        case .rateLimited:
            return "Rate-limited by the provider. Try again in a moment."
        case .unexpectedResponse:
            return "Unexpected response from the provider."
        case .httpError(let status, let body):
            // Body trimmed so a wall-of-JSON doesn't blow up the UI.
            let preview = String(body.prefix(200))
            return "HTTP \(status) — \(preview)"
        case .emptyResponse:
            return "Provider returned an empty response."
        }
    }
}

// MARK: - CoachFact severity label

private extension CoachFact.Severity {
    var label: String {
        switch self {
        case .quiet:   return "quiet"
        case .normal:  return "normal"
        case .notable: return "NOTABLE"
        }
    }
}
