//
//  PausedBanner.swift
//  WorkoutChallenge
//
//  The ink-filled banner that sits at the top of Bars when the current
//  challenge is paused. The design copy is the hero: "Your days wait.
//  Your body doesn't." — paired with a small VO₂ decay readout to make
//  the pause have a real, measurable cost even while the schedule freezes.
//

import SwiftUI

/// Wide ink-filled banner. Renders above all other content on Bars when
/// `challenge.state == .paused`. Offers a quick Resume action; tapping
/// the text area could later surface the fitness decay detail (out of
/// scope for Phase 2).
struct PausedBanner: View {
    let challenge: ChallengeModel
    let onResume: () -> Void

    private var daysPaused: Int {
        guard let since = challenge.pausedSince else { return 0 }
        return max(0, Int(Date().timeIntervalSince(since) / 86_400))
    }

    private var decay: (from: Double, to: Double) {
        ChallengeService.vo2DecayReadout(pausedFor: challenge.effectivePausedSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(alignment: .center, spacing: Space.x3) {
                // Pause bars glyph.
                HStack(spacing: 3) {
                    Rectangle()
                        .fill(Color.accentVolt)
                        .frame(width: 4, height: 14)
                        .cornerRadius(1)
                    Rectangle()
                        .fill(Color.accentVolt)
                        .frame(width: 4, height: 14)
                        .cornerRadius(1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("PAUSED · \(daysPaused) DAY\(daysPaused == 1 ? "" : "S")")
                        .font(AppFont.mono(9, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.accentVolt)
                    Text("Your days wait. Your body doesn't.")
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(Color.appSurface)
                }
                Spacer(minLength: 0)
            }

            // VO₂ decay readout — the "fitness keeps running" twist.
            HStack {
                Text("VO₂ est.")
                    .font(AppFont.mono(9, weight: .medium))
                    .foregroundStyle(Color.appSurface.opacity(0.7))
                Spacer()
                Text("\(decay.from, specifier: "%.1f") → \(decay.to, specifier: "%.1f")")
                    .font(AppFont.mono(11, weight: .bold))
                    .foregroundStyle(Color.appSurface)
            }
            .padding(.horizontal, Space.x2)
            .padding(.vertical, 6)
            .background(Color.textPrimary.opacity(0.3), in: .rect(cornerRadius: 6))

            // Resume button — Volt on ink.
            Button(action: onResume) {
                Text("Resume challenge")
                    .font(AppFont.ui(13, weight: .bold))
                    .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.04))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentVolt, in: .rect(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(red: 0.04, green: 0.04, blue: 0.04),
                                    lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(Space.x4)
        .background(Color.textPrimary, in: .rect(cornerRadius: Radius.card))
    }
}

#Preview {
    PausedBanner(
        challenge: {
            let c = ChallengeModel(number: 1)
            c.state = .paused
            c.pausedSince = Date().addingTimeInterval(-3 * 86_400)
            return c
        }(),
        onResume: {}
    )
    .padding()
    .background(Color.appBg)
}
