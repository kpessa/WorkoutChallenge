//
//  CoachAudioPlayer.swift
//  WorkoutChallenge
//
//  `AVAudioPlayer` wrapper exposing a single SwiftUI-observable `state`
//  for the coach card's play button. View-scoped — instantiated as
//  `@State` in `LogWorkoutSheet` and torn down on dismiss.
//
//  AVAudioSession is configured for `.playback` + `.spokenAudio` so the
//  coach's voice ducks Spotify / Apple Music rather than silencing them.
//  Honors the silent-switch by default — if the user has muted the phone,
//  the audio plays silently and the UI's progress bar still advances so
//  it's clear *something* is happening.
//

import Foundation
import AVFoundation
import Observation

@Observable
@MainActor
final class CoachAudioPlayer: NSObject {

    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading),
                 (.playing, .playing), (.paused, .paused):
                return true
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    private(set) var state: State = .idle

    /// Playback progress in 0...1. Updates while playing; resets to 0 on
    /// stop. Pulled by a small repeating Task while `state == .playing`.
    private(set) var progress: Double = 0

    @ObservationIgnored
    private var player: AVAudioPlayer?

    @ObservationIgnored
    nonisolated(unsafe) private var progressTask: Task<Void, Never>?

    // MARK: - Audio session

    /// One-time session setup. `.playback` category + `.spokenAudio` mode
    /// gives us mix-with-others by default and routes through the
    /// "spoken" audio path on iOS so Bluetooth / CarPlay can announce it
    /// appropriately.
    private func configureSessionIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.mixWithOthers, .duckOthers]
            )
            try session.setActive(true, options: [])
        } catch {
            // Non-fatal: most devices will succeed; if this fails the
            // player will still attempt to play, just without ducking.
            #if DEBUG
            print("[CoachAudioPlayer] AVAudioSession setup failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Play / pause / stop

    /// Play raw audio bytes. Stops any current playback first.
    func play(data: Data) async throws {
        stop()
        configureSessionIfNeeded()
        state = .loading

        let p = try AVAudioPlayer(data: data)
        p.delegate = self
        p.prepareToPlay()

        guard p.play() else {
            state = .error("Failed to start playback.")
            return
        }

        player = p
        state = .playing
        startProgressTimer()
    }

    /// Play from a file URL — used when the audio is already on disk.
    func play(url: URL) async throws {
        stop()
        configureSessionIfNeeded()
        state = .loading

        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.prepareToPlay()

        guard p.play() else {
            state = .error("Failed to start playback.")
            return
        }

        player = p
        state = .playing
        startProgressTimer()
    }

    func pause() {
        player?.pause()
        progressTask?.cancel()
        if state == .playing { state = .paused }
    }

    func resume() {
        guard state == .paused, let p = player, p.play() else { return }
        state = .playing
        startProgressTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        progressTask?.cancel()
        progressTask = nil
        progress = 0
        if case .error = state {
            // Preserve error state so UI can reflect it; callers can
            // reset by calling `reset()` if desired.
        } else {
            state = .idle
        }
    }

    func reset() {
        stop()
        state = .idle
    }

    // MARK: - Progress

    /// Lightweight progress polling. Could go through `displayLink` for
    /// smoother updates, but coach playback is short (5–15s) and the
    /// bar doesn't need to be silky.
    private func startProgressTimer() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while let self, await self.state == .playing {
                if let p = await self.player {
                    let total = p.duration
                    let cur = p.currentTime
                    await MainActor.run {
                        self.progress = total > 0 ? cur / total : 0
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
        }
    }

    deinit {
        progressTask?.cancel()
    }
}

// MARK: - AVAudioPlayerDelegate

extension CoachAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.progress = 1.0
            self.state = .idle
            self.progressTask?.cancel()
            self.progressTask = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "Decode error"
        Task { @MainActor [weak self] in
            self?.state = .error(message)
        }
    }
}
