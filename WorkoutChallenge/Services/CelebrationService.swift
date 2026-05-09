//
//  CelebrationService.swift
//  WorkoutChallenge
//
//  Fires a confetti+haptic celebration the **first time** a given day's
//  logged minutes cross the sigmoid target. Both manual logging
//  (`LogWorkoutSheet.saveNew` / `saveEdit`) and HealthKit import
//  (`HealthKitService.importWorkouts`) funnel into
//  `checkForCrossing(workoutDate:context:)` — whichever pathway pushes the
//  day over the line triggers the celebration.
//
//  Dedupe strategy
//  ---------------
//  To keep the moment meaningful we only fire once per calendar day, even
//  across app launches and CloudKit syncs. The set of celebrated days is
//  persisted in UserDefaults keyed by ISO date (`YYYY-MM-DD` in the user's
//  local timezone). This is intentionally local-device state — we don't
//  want a celebration that fired on iPhone to silently re-fire on Mac
//  Catalyst when CloudKit catches up.
//
//  Why a published `showCelebration` flag
//  --------------------------------------
//  The overlay lives on `RootView` so it can paint over whatever tab the
//  user is on when the threshold is crossed (they might be in Calendar,
//  on the Bars screen, or still in the LogWorkoutSheet). Publishing a
//  simple bool and flipping it off on a timer is the cheapest way to hand
//  the render to the view layer.
//

import Foundation
import Combine
import SwiftUI
import SwiftData
import UIKit

@MainActor
final class CelebrationService: ObservableObject {

    /// When true, `RootView` paints the confetti + "Day complete!" banner
    /// on top of the tab view. Flipped back to false automatically after
    /// `displayDuration` seconds so the overlay self-dismisses.
    @Published var showCelebration: Bool = false

    /// The date whose target was crossed — drives the banner copy
    /// ("Day complete!" when today, "<Short date> complete!" for backdated
    /// logs so the user knows what fired).
    @Published var celebratedDate: Date?

    /// How long the overlay stays up before auto-dismissing. Matches the
    /// confetti animation length + a hair of buffer so the banner fades
    /// after the last particles settle.
    private let displayDuration: TimeInterval = 2.5

    /// UserDefaults key holding the set of already-celebrated ISO day
    /// strings. Stored as an array because UserDefaults doesn't persist
    /// Swift `Set`s directly.
    private static let celebratedDaysKey = "com.kpessa.WorkoutChallenge.celebratedDays"

    /// Bumped whenever the format of celebratedDays changes. Currently
    /// unused but reserved — if we ever widen the dedupe window (e.g. to
    /// per-workout) we can invalidate the stored set by bumping this.
    private static let formatVersionKey = "com.kpessa.WorkoutChallenge.celebratedDaysVersion"

    /// Locale-agnostic date key formatter. `.withFullDate` emits
    /// `YYYY-MM-DD` which is stable across timezones at the local-day
    /// granularity we care about.
    private static let keyFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    /// Success haptic generator. Allocated once and re-prepared on each
    /// fire so the tap lands within the iOS haptic warm-up window.
    private let haptics = UINotificationFeedbackGenerator()

    // MARK: - Threshold check

    /// Check whether the given date has just crossed its sigmoid target,
    /// and if so fire the celebration (haptic + overlay flag).
    ///
    /// - Parameters:
    ///   - workoutDate: The date of the workout that was just logged or
    ///     imported. We key the check on this date's `startOfDay`, not on
    ///     "today" — logging yesterday's workout that completes yesterday
    ///     should still celebrate once.
    ///   - context: SwiftData context used to fetch the day's workouts and
    ///     the active challenge / prefs rows.
    func checkForCrossing(workoutDate: Date, context: ModelContext) {
        let dayStart = workoutDate.startOfDay
        let key = Self.keyFormatter.string(from: dayStart)

        // Already celebrated this day — no-op. This is the "only fire
        // when crossing the threshold" semantics the user picked.
        var celebrated = Self.loadCelebratedDays()
        if celebrated.contains(key) { return }

        // Resolve the schedule config. If no prefs yet (pre-onboarding)
        // we silently skip — no target means no crossing to celebrate.
        let prefsFetch = FetchDescriptor<UserPreferencesModel>()
        let challengeFetch = FetchDescriptor<ChallengeModel>()
        guard let prefs = try? context.fetch(prefsFetch).first else { return }
        let challenges = (try? context.fetch(challengeFetch)) ?? []
        guard let active = ChallengeService.activeConfig(
            challenges: challenges,
            prefs: prefs
        ) else { return }

        // Off-schedule check — the target sigmoid only applies from the
        // challenge start date forward. Pre-challenge backfills shouldn't
        // celebrate.
        if dayStart < active.startDate.startOfDay { return }

        // Compute the target for this specific day.
        let target = SigmoidalService.targetDuration(
            for: dayStart,
            startDate: active.startDate,
            params: active.sigmoid
        )
        let targetMin = Int(target.rounded())
        guard targetMin > 0 else { return }

        // Sum the day's logged minutes. We use a date-range fetch because
        // SwiftData can't filter across @Relationship fields in a predicate
        // and we want to include every row tied to that day regardless of
        // source (manual vs. imported).
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let workoutFetch = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { w in
                w.date >= dayStart && w.date < dayEnd
            }
        )
        let dayWorkouts = (try? context.fetch(workoutFetch)) ?? []
        let loggedMin = dayWorkouts.map(\.duration).reduce(0, +)

        // Not yet across the threshold — no celebration. We do *not* mark
        // the day as celebrated yet, so future saves on the same day still
        // get the chance to cross it.
        guard loggedMin >= targetMin else { return }

        // Crossed! Mark the day celebrated before firing so re-entrant
        // calls (e.g. an HK import that loops over several samples for the
        // same day) don't each trigger a fresh burst.
        celebrated.insert(key)
        Self.saveCelebratedDays(celebrated)

        fireCelebration(for: dayStart)
    }

    // MARK: - Firing

    /// Present the overlay and play the haptic. Auto-dismisses after
    /// `displayDuration` seconds.
    private func fireCelebration(for date: Date) {
        celebratedDate = date
        showCelebration = true

        // Prepare-then-fire warms up the Taptic engine so the notification
        // lands within the same frame as the overlay appearing. Without
        // `prepare()` iOS will delay the first haptic by ~50ms.
        haptics.prepare()
        haptics.notificationOccurred(.success)

        // Self-dismiss on a timer. Using `Task` (not `DispatchQueue`) so
        // we stay on the MainActor and the state mutation is safe.
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(displayDuration * 1_000_000_000))
            await MainActor.run {
                self.showCelebration = false
            }
        }
    }

    // MARK: - Persistence helpers

    /// Load the set of ISO date strings we've already celebrated. Returns
    /// an empty set when UserDefaults has nothing stored yet.
    private static func loadCelebratedDays() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: celebratedDaysKey) ?? []
        return Set(arr)
    }

    /// Persist the celebrated-days set, trimmed to the most recent 365
    /// entries so the array doesn't grow unbounded over a year of use.
    /// The cap is generous — even in the edge case of back-filling a full
    /// year of completed days we'd fit comfortably.
    private static func saveCelebratedDays(_ days: Set<String>) {
        // Keep the list bounded. Sort descending so if we hit the cap we
        // drop the oldest entries.
        let capped = Array(days).sorted(by: >).prefix(400)
        UserDefaults.standard.set(Array(capped), forKey: celebratedDaysKey)
        UserDefaults.standard.set(1, forKey: formatVersionKey)
    }

    // MARK: - Dev / reset helpers

    /// Clear the celebrated-days cache. Exposed for future debug UI (or a
    /// settings toggle) — not currently wired into any visible control.
    func resetCelebrationHistory() {
        UserDefaults.standard.removeObject(forKey: Self.celebratedDaysKey)
    }
}
