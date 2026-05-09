//
//  CoachFacts.swift
//  WorkoutChallenge
//
//  Structured observations produced by the deterministic Layer 1 pass.
//  These are the *findings* the coach has from the data — small, specific,
//  number-driven. The narrator (Layer 2) consumes a `CoachFacts` bundle
//  and writes the prose. The card (when no narrator is available) renders
//  the facts directly as bullets.
//
//  Design rules:
//
//    • A fact is ALWAYS grounded in a number. The `values` dict carries
//      every substitution the rendering layer needs — no recomputation
//      downstream. If a rule wants to say "Z2 time up 23% week-over-week,"
//      it embeds "23" and "Z2" in `values`, not in the templateKey.
//
//    • Severity gates speech. `notable` facts are loud enough to surface
//      alone. `normal` facts are supporting context. `quiet` facts are
//      logged for narrator priming but may never reach the user. The
//      "coach earns the right to speak" rule lives at this severity gate.
//
//    • Stable ordering. The deterministic pass emits facts in a fixed
//      order so the same context produces the same list — important for
//      caching and for debugging "why did the coach say that?"
//
//    • Localized copy lives in `Localizable.xcstrings` keyed off
//      `templateKey`. The fact carries data, not strings. `values` keys
//      are stable identifiers ("delta", "zone", "minutes") substituted at
//      render time via `String(format:)` or NSLocalizedString-style
//      placeholders.
//

import Foundation

// MARK: - Fact

struct CoachFact: Hashable, Sendable, Identifiable, Codable {

    enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case progress       // overshoot / on-target / short
        case fitnessTrend   // CTL delta
        case recovery       // TSB / fatigue / freshness
        case hrDrift        // HR-at-pace
        case adherence      // streaks, returns, missed days
        case milestone      // day 1/30/60/90, return after break
        case zones          // distribution of time across HR zones
    }

    enum Severity: Int, Hashable, Sendable, Codable, Comparable {
        case quiet  = 0
        case normal = 1
        case notable = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let kind: Kind
    let severity: Severity
    /// Stable key into `Localizable.xcstrings`. Convention: `fact.<kind>.<rule>`.
    let templateKey: String
    /// Substitution values, keys are stable identifiers used in the
    /// catalog template (e.g. "%{delta}%" expands to values["delta"]).
    let values: [String: String]

    var id: String { templateKey }
}

// MARK: - Bundle

/// The full result of a deterministic pass — facts in a stable order,
/// plus convenience accessors for "what should the card show?" decisions.
struct CoachFacts: Sendable {

    /// Facts in the order produced by `DeterministicCoach.observe`.
    /// Stable across runs of the same context.
    let all: [CoachFact]

    /// Facts whose severity is `.notable` — the ones loud enough that the
    /// coach has earned the right to surface them alone.
    var notable: [CoachFact] { all.filter { $0.severity == .notable } }

    /// True when there's at least one notable observation. The card uses
    /// this as its render gate — no notable facts → no card.
    var hasNotable: Bool { !notable.isEmpty }

    /// Facts of `.normal` severity, useful as supporting context to a
    /// notable fact in the narrator's prompt.
    var supporting: [CoachFact] { all.filter { $0.severity == .normal } }

    /// Static empty bundle — used when the context is too thin to say
    /// anything at all (e.g. no challenge, no recent workouts).
    static let empty = CoachFacts(all: [])
}
