//
//  CoachAudioStore.swift
//  WorkoutChallenge
//
//  File I/O for cached coach narration audio. Audio files (~50–200KB
//  mp3 each) live in the app's `Caches/CoachAudio/` directory keyed by
//  the `CoachFeedbackModel.id` UUID. They deliberately do NOT live on
//  the SwiftData @Model row — putting blobs that size on a CloudKit-
//  synced model would bloat sync.
//
//  iOS may evict the Caches directory under storage pressure. That's
//  fine: `CoachFeedbackModel.audioGeneratedAt` is the truth-or-not
//  signal — when the row says audio existed but the file is gone, the
//  loader regenerates on next play.
//
//  All methods are non-throwing where possible; the player flow tolerates
//  "no file" gracefully (re-fetch on next tap).
//

import Foundation

enum CoachAudioStore {

    private static let directoryName = "CoachAudio"

    // MARK: - Path helpers

    private static func directoryURL() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = caches.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    /// Path on disk where audio for `feedbackID` lives. Path may or may
    /// not exist — callers should test with `audioExists(for:)`.
    static func audioURL(for feedbackID: UUID) -> URL? {
        guard let dir = try? directoryURL() else { return nil }
        return dir.appendingPathComponent("\(feedbackID.uuidString).mp3")
    }

    // MARK: - I/O

    /// Returns true when an mp3 file exists for `feedbackID`. Used to
    /// distinguish "audio was generated, file is on disk" from "audio
    /// was generated, file got evicted by iOS storage pressure" — the
    /// latter triggers a regenerate-on-tap.
    static func audioExists(for feedbackID: UUID) -> Bool {
        guard let url = audioURL(for: feedbackID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Write mp3 bytes to disk. Overwrites any existing file at the path.
    /// Errors propagate — caller decides how loud to be (the loader
    /// swallows them; the Settings test path surfaces them).
    @discardableResult
    static func writeAudio(_ data: Data, for feedbackID: UUID) throws -> URL {
        guard let url = audioURL(for: feedbackID) else {
            throw NSError(
                domain: "CoachAudioStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't resolve Caches directory."]
            )
        }
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// Read cached audio. Nil when no file exists for this id.
    static func readAudio(for feedbackID: UUID) -> Data? {
        guard let url = audioURL(for: feedbackID) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Remove the cached file for `feedbackID`. No-op when no file exists.
    static func deleteAudio(for feedbackID: UUID) {
        guard let url = audioURL(for: feedbackID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Wipe the whole audio cache. Used for a future "clear cache"
    /// settings affordance; not wired anywhere yet.
    static func clearAll() {
        guard let dir = try? directoryURL() else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
