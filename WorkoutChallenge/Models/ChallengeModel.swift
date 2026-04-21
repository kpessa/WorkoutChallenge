//
//  ChallengeModel.swift
//  WorkoutChallenge
//
//  The lifecycle layer: a challenge has one of four states at any time —
//  `active`, `paused`, `completed`, `abandoned` — and moves between them
//  through user actions (Pause/Resume/Abandon/Complete) or time (reaching
//  day 90 auto-completes). Exactly one challenge may be in state `.active`
//  or `.paused` at a time; the rest live in history.
//
//  The model mirrors the "active" challenge's config fields (`startDate`,
//  `daysPerWeek`, `sigmoid`) from `UserPreferencesModel` so existing views
//  that read from prefs continue to work unchanged during Phase 2. When
//  the user starts a new challenge via the Create flow, both sides are
//  updated together.
//
//  Pause semantics: paused days *do not* count toward your 90. We track
//  `pausedSince` (when pause began) and `totalPausedSeconds` (accumulated)
//  so the "effective day number" is
//  `(now - startDate - totalPausedSeconds)`, which the rest of the app can
//  surface unchanged through `ChallengeService.currentDay(of:)`.
//

import Foundation
import SwiftData

@Model
final class ChallengeModel {

    // MARK: - Identity

    /// Stable id — also serves as the SwiftData primary key.
    var id: UUID = UUID()

    /// Sequential challenge number shown in the UI ("Challenge 01").
    /// CloudKit-safe (no unique constraint); uniqueness is enforced at
    /// creation time by `ChallengeService`.
    var number: Int = 1

    /// Local-day wall-clock when the user first committed to this challenge.
    /// For completed/abandoned entries, this is frozen at the historical
    /// start date.
    var startDate: Date = Date()

    /// How many days per week the user targeted for this challenge (1...7).
    /// Frozen once the challenge is created; edits via "Edit goals" replace
    /// the field on the active challenge only.
    var daysPerWeek: Int = 3

    // MARK: - State machine

    /// Raw enum value — stored as a string so adding states doesn't require
    /// a schema migration. Defaults to "active" so rows synced from older
    /// clients still read sensibly.
    var stateRaw: String = ChallengeState.active.rawValue

    /// When the active challenge was paused (nil when not paused). Cleared
    /// on Resume. Combined with `totalPausedSeconds` this gives us the
    /// challenge's "effective" elapsed time for the 90-day progression.
    var pausedSince: Date?

    /// Accumulated paused time across all prior pauses on this challenge,
    /// in seconds. Not reset on Resume — only grows.
    var totalPausedSeconds: Double = 0

    /// Set when the challenge transitions to `.completed` (day 90 reached)
    /// or `.abandoned` (user ended it early). Frozen in history.
    var endedAt: Date?

    /// Set at creation time; provides a creation-order tiebreaker when
    /// listing history alongside `startDate`.
    var createdAt: Date = Date()

    // MARK: - Sigmoid snapshot

    /// Captured at creation so the challenge's progression curve is
    /// frozen in time — the user can tweak sigmoid params for a *new*
    /// challenge without retroactively altering historical targets.
    var sigmoid: SigmoidParams = SigmoidParams.default

    // MARK: - Commitment moment

    /// Optional pledge/signature captured during the 3-step create flow.
    /// Rendered on the active card + on the history entry. Empty string
    /// = not signed.
    var pledgeSignature: String = ""

    init(
        id: UUID = UUID(),
        number: Int = 1,
        startDate: Date = Date(),
        daysPerWeek: Int = 3,
        state: ChallengeState = .active,
        sigmoid: SigmoidParams = .default,
        pledgeSignature: String = ""
    ) {
        self.id = id
        self.number = number
        self.startDate = startDate
        self.daysPerWeek = daysPerWeek
        self.stateRaw = state.rawValue
        self.sigmoid = sigmoid
        self.pledgeSignature = pledgeSignature
        self.createdAt = Date()
    }
}

// MARK: - State enum

/// The four lifecycle states a challenge passes through. Only one row may
/// be in `.active` or `.paused` at a time; `.completed` / `.abandoned`
/// rows live in the history list.
enum ChallengeState: String, CaseIterable, Codable {
    case active
    case paused
    case completed
    case abandoned

    var isCurrent: Bool {
        self == .active || self == .paused
    }

    /// Short label for UI chips ("ACTIVE", "PAUSED").
    /// Wrapped in `String(localized:)` so Spanish (and any future languages)
    /// resolves correctly when this value is passed to a SwiftUI `Text(String)`
    /// — which uses the verbatim overload and would otherwise skip the catalog.
    var shortLabel: String {
        switch self {
        case .active:    return String(localized: "Active", comment: "ChallengeState.shortLabel")
        case .paused:    return String(localized: "Paused", comment: "ChallengeState.shortLabel")
        case .completed: return String(localized: "Completed", comment: "ChallengeState.shortLabel")
        case .abandoned: return String(localized: "Abandoned", comment: "ChallengeState.shortLabel")
        }
    }
}

// MARK: - Typed accessors

extension ChallengeModel {
    var state: ChallengeState {
        get { ChallengeState(rawValue: stateRaw) ?? .active }
        set { stateRaw = newValue.rawValue }
    }

    /// Challenge length in days — always 90 for this app.
    var totalDays: Int { 90 }

    /// Number of seconds paused *right now*, including the in-progress
    /// pause if any. Used by `ChallengeService.currentDay`.
    var effectivePausedSeconds: Double {
        let inProgress = pausedSince.map { Date().timeIntervalSince($0) } ?? 0
        return totalPausedSeconds + max(0, inProgress)
    }

    /// The projected end date based on startDate + 90 days + paused time.
    /// For completed/abandoned challenges use `endedAt` instead.
    var projectedEndDate: Date {
        let base = startDate.addingDays(totalDays - 1)
        return base.addingTimeInterval(effectivePausedSeconds)
    }
}
