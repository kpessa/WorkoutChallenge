//
//  ReclaimSyncService.swift
//  WorkoutChallenge
//
//  Translates a live ChallengeModel into a set of Reclaim tasks. Uses the
//  existing `SigmoidalService.generateSchedule` + `.targetDuration` so the
//  Reclaim schedule stays in lockstep with the in-app Calendar view.
//
//  Phase C.2a adds `ReclaimTaskMappingModel` tracking — one row per
//  (challenge, dayNumber). Behaviour:
//    • If mappings are empty on first run, adopt: GET Reclaim's existing
//      tasks, parse day numbers out of titles like "[Workout Day N] ...",
//      populate mappings. No duplicate tasks get created.
//    • Any future day without a mapping gets a new POST + mapping row.
//    • Days with a mapping are left alone (no update-in-place yet — if the
//      user changes sigmoid params and wants Reclaim rewritten, delete the
//      affected mappings and re-sync. Phase C.2.1 can add update-on-change
//      if the workflow needs it.)
//

import Foundation
import SwiftData

@MainActor
enum ReclaimSyncService {

    struct Outcome {
        let adopted: Int      // first-run reconcile of pre-existing Reclaim tasks
        let created: Int      // new POSTs this run
        let existing: Int     // days already mapped; no action needed
        let skippedPast: Int  // past days, ineligible for scheduling
        let failed: Int
        let firstError: String?
    }

    /// Title pattern `[Workout Day 12] — 30m` → captures day number.
    private static let titleRegex = try! NSRegularExpression(
        pattern: #"^\[Workout Day (\d+)\]"#,
        options: []
    )

    // MARK: - Public entry

    static func syncSchedule(
        challenge: ChallengeModel,
        modelContext: ModelContext,
        today: Date = Date()
    ) async throws -> Outcome {
        guard ReclaimKeychain.hasToken else {
            throw ReclaimAPIError.noToken
        }

        // 1. Load existing mappings for this challenge.
        var mappings = try fetchMappings(challengeID: challenge.id, context: modelContext)

        // 2. Adopt pre-existing Reclaim tasks on first run for this challenge.
        var adopted = 0
        if mappings.isEmpty {
            adopted = try await adoptExistingTasks(
                challenge: challenge,
                modelContext: modelContext
            )
            if adopted > 0 {
                mappings = try fetchMappings(challengeID: challenge.id, context: modelContext)
            }
        }

        let mappedDays = Set(mappings.map(\.dayNumber))

        // 3. Compute the full schedule; split into future / past.
        let startDay = today.startOfDay
        let fullSchedule = SigmoidalService.generateSchedule(
            startDate: challenge.startDate,
            daysPerWeek: challenge.daysPerWeek,
            totalDays: challenge.totalDays
        )
        let (futureDays, pastDays) = fullSchedule.reduce(
            into: ([ScheduledDay](), [ScheduledDay]())
        ) { acc, day in
            if day.date.startOfDay >= startDay { acc.0.append(day) }
            else { acc.1.append(day) }
        }

        // 4. For each future day: create + map if not already mapped.
        var created = 0
        var existing = 0
        var failed = 0
        var firstError: String?

        for day in futureDays {
            if mappedDays.contains(day.dayNumber) {
                existing += 1
                continue
            }
            let minutes = SigmoidalService.targetDuration(
                dayIndex: day.dayNumber - 1,
                params: challenge.sigmoid
            )
            let targetMin = max(15, Int(minutes.rounded()))
            do {
                let result = try await ReclaimAPI.createTask(
                    makePayload(day: day, minutes: targetMin, challengeNumber: challenge.number)
                )
                modelContext.insert(
                    ReclaimTaskMappingModel(
                        challengeID: challenge.id,
                        dayNumber: day.dayNumber,
                        reclaimTaskID: result.id,
                        lastSyncedMinutes: targetMin
                    )
                )
                created += 1
            } catch {
                failed += 1
                if firstError == nil {
                    firstError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }

        try? modelContext.save()

        return Outcome(
            adopted: adopted,
            created: created,
            existing: existing,
            skippedPast: pastDays.count,
            failed: failed,
            firstError: firstError
        )
    }

    /// Best-effort completion sync. Called whenever a WorkoutModel is
    /// inserted (manual log, HealthKit import). Silent on failure — a
    /// Reclaim outage must not block the user's workout save.
    ///
    /// No-op when: token missing, no active challenge, workout date isn't
    /// on a scheduled day (e.g. worked out Sunday with a M/W/F schedule),
    /// no mapping exists yet for that day, or the mapping was already
    /// completed from this device.
    static func completeTaskForWorkout(
        date: Date,
        modelContext: ModelContext
    ) async {
        guard ReclaimKeychain.hasToken else { return }

        // Find active challenge.
        let challengeDescriptor = FetchDescriptor<ChallengeModel>()
        guard let challenges = try? modelContext.fetch(challengeDescriptor),
              let challenge = ChallengeService.currentChallenge(in: challenges)
        else { return }

        // Match the workout date against the sigmoid schedule. Off-schedule
        // workouts (Sunday when your days are M/W/F) simply don't complete
        // a Reclaim task — they still count toward week targets in the app.
        let schedule = SigmoidalService.generateSchedule(
            startDate: challenge.startDate,
            daysPerWeek: challenge.daysPerWeek,
            totalDays: challenge.totalDays
        )
        let workoutDay = date.startOfDay
        guard let scheduledDay = schedule.first(where: {
            $0.date.startOfDay == workoutDay
        }) else { return }

        // Find the mapping.
        let challengeID = challenge.id
        let dayNumber = scheduledDay.dayNumber
        let mappingDescriptor = FetchDescriptor<ReclaimTaskMappingModel>(
            predicate: #Predicate { m in
                m.challengeID == challengeID && m.dayNumber == dayNumber
            }
        )
        guard let mapping = (try? modelContext.fetch(mappingDescriptor))?.first
        else {
            // No mapping means either: user never synced, OR they synced but
            // deleted the mapping. Either way, silent no-op — the user will
            // discover this by opening Reclaim and seeing an uncompleted task.
            return
        }

        // Idempotency guard.
        if mapping.completedAt != nil { return }

        do {
            try await ReclaimAPI.completeTask(id: mapping.reclaimTaskID)
            mapping.completedAt = Date()
            try? modelContext.save()
        } catch {
            // Best-effort — don't surface. The next workout log on the same
            // day won't retry (completedAt stays nil, so it will retry).
            // That's fine for transient network errors.
            #if DEBUG
            print("Reclaim completion failed for day \(dayNumber): \(error)")
            #endif
        }
    }

    /// Drops every mapping for a challenge. Exposed so the Settings UI can
    /// offer a "Reset mappings and re-adopt" escape hatch when Reclaim-side
    /// state diverges (user manually deleted tasks, etc.).
    static func clearMappings(challengeID: UUID, modelContext: ModelContext) throws {
        let mappings = try fetchMappings(challengeID: challengeID, context: modelContext)
        for m in mappings { modelContext.delete(m) }
        try modelContext.save()
    }

    // MARK: - Adoption

    /// Finds every pre-existing Reclaim task whose title matches
    /// `[Workout Day N] ...`, creates a mapping row for each, and returns
    /// the count. Called only when mappings for this challenge are empty.
    ///
    /// Tasks with ambiguous or missing day numbers are skipped — they'd
    /// need to be cleaned up in Reclaim manually.
    private static func adoptExistingTasks(
        challenge: ChallengeModel,
        modelContext: ModelContext
    ) async throws -> Int {
        let tasks = try await ReclaimAPI.listTasks()

        // Group by day number so dupes don't produce two mapping rows.
        var bestByDay: [Int: ReclaimTaskListed] = [:]
        for t in tasks {
            guard let title = t.title,
                  let dayNumber = parseDayNumber(from: title),
                  dayNumber >= 1, dayNumber <= 90
            else { continue }
            // If multiple tasks match the same day, prefer the lowest id
            // (typically the original — dupes from double-syncs get ignored).
            if let existing = bestByDay[dayNumber], existing.id < t.id { continue }
            bestByDay[dayNumber] = t
        }

        for (day, task) in bestByDay {
            let existingMins = (task.timeChunksRequired ?? 0) * 15
            modelContext.insert(
                ReclaimTaskMappingModel(
                    challengeID: challenge.id,
                    dayNumber: day,
                    reclaimTaskID: task.id,
                    lastSyncedMinutes: existingMins
                )
            )
        }
        try? modelContext.save()
        return bestByDay.count
    }

    private static func parseDayNumber(from title: String) -> Int? {
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = titleRegex.firstMatch(in: title, range: range),
              match.numberOfRanges >= 2,
              let numRange = Range(match.range(at: 1), in: title)
        else { return nil }
        return Int(title[numRange])
    }

    // MARK: - Mapping fetch

    private static func fetchMappings(
        challengeID: UUID,
        context: ModelContext
    ) throws -> [ReclaimTaskMappingModel] {
        let descriptor = FetchDescriptor<ReclaimTaskMappingModel>(
            predicate: #Predicate { $0.challengeID == challengeID }
        )
        return try context.fetch(descriptor)
    }

    // MARK: - Payload builder

    private static func makePayload(
        day: ScheduledDay,
        minutes: Int,
        challengeNumber: Int
    ) -> ReclaimTaskCreate {
        let chunks = max(1, (minutes + 14) / 15)
        return ReclaimTaskCreate(
            title: "[Workout Day \(day.dayNumber)] — \(minutes)m",
            notes: "Challenge \(String(format: "%02d", challengeNumber)) · Day \(day.dayNumber) of 90 · Target: \(minutes)m (sigmoid). Logged in Workout Challenge app.",
            eventCategory: "PERSONAL",
            timeChunksRequired: chunks,
            minChunkSize: chunks,
            maxChunkSize: chunks,
            priority: .p1,
            due: isoDateUTC(day.date),
            snoozeUntil: isoStartOfDayUTC(day.date),
            alwaysPrivate: false,
            type: "TASK",
            prioritizableType: "TASK"
        )
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func isoDateUTC(_ date: Date) -> String {
        var cal = Calendar.current
        cal.timeZone = .current
        let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date
        return isoFormatter.string(from: endOfDay)
    }

    /// 6:00 AM local on the scheduled day, as an ISO8601 UTC string.
    /// Used as `snoozeUntil` so Reclaim can't schedule a workout task before its scheduled day —
    /// prevents far-future workouts from greedy-filling earlier weeks.
    private static func isoStartOfDayUTC(_ date: Date) -> String {
        var cal = Calendar.current
        cal.timeZone = .current
        let startOfDay = cal.date(bySettingHour: 6, minute: 0, second: 0, of: date) ?? date
        return isoFormatter.string(from: startOfDay)
    }
}
