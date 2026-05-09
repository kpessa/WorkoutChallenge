//
//  ReclaimTaskMappingModel.swift
//  WorkoutChallenge
//
//  Local record of a Reclaim.ai task created for a specific workout day of
//  a specific challenge. Lets `ReclaimSyncService` turn a repeat sync into
//  a no-op instead of creating duplicates.
//
//  One row per (challenge, dayNumber) pair. CloudKit-synced via the default
//  container so mappings follow the user across devices — if you rebuild
//  on a new iPhone, the app won't recreate 90 tasks you already have.
//
//  Adoption: when the user ran a C.1 sync (before this table existed) the
//  mappings are empty but Reclaim already has 89 tasks with titles like
//  `[Workout Day 2] — 18m`. On first C.2 sync, `ReclaimSyncService` parses
//  the day number out of the title and retroactively populates mappings so
//  existing tasks are not re-created.
//

import Foundation
import SwiftData

@Model
final class ReclaimTaskMappingModel {
    /// Stable id — also serves as the SwiftData primary key.
    var id: UUID = UUID()

    /// Which challenge this mapping belongs to. Matches `ChallengeModel.id`
    /// so the sync service can scope queries to the active challenge.
    var challengeID: UUID = UUID()

    /// 1..90. The sigmoid-schedule day number the task represents.
    var dayNumber: Int = 0

    /// Reclaim-assigned task id. Opaque Int from the POST /api/tasks
    /// response. Stable for the life of the task.
    var reclaimTaskID: Int = 0

    /// Duration we asked Reclaim to block when we created or last reconciled
    /// the task. Used by Phase C.2.1 (if we later add update-on-change) to
    /// decide whether to PATCH. Default 0 means "unknown" (from adoption).
    var lastSyncedMinutes: Int = 0

    /// When this workout day's Reclaim task was marked complete via C.2b's
    /// completion sync. Nil means "not completed from this device yet"
    /// — we still fire a POST /done on next workout log attempt. Used as
    /// an idempotency guard so double-logging a workout doesn't double-POST.
    var completedAt: Date?

    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        challengeID: UUID,
        dayNumber: Int,
        reclaimTaskID: Int,
        lastSyncedMinutes: Int = 0,
        completedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.challengeID = challengeID
        self.dayNumber = dayNumber
        self.reclaimTaskID = reclaimTaskID
        self.lastSyncedMinutes = lastSyncedMinutes
        self.completedAt = completedAt
        self.createdAt = createdAt
    }
}
