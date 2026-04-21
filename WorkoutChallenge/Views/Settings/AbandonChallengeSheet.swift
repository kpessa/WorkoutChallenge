//
//  AbandonChallengeSheet.swift
//  WorkoutChallenge
//
//  The destructive but reassuring modal used to end a challenge early.
//  Per the Lifecycle design: we tell the user exactly what will happen
//  ("moves to history as abandoned · workout log stays · streak resets")
//  before they commit. No backing-out after — this is a one-way action.
//

import SwiftUI

struct AbandonChallengeSheet: View {
    let challenge: ChallengeModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var currentDay: Int { ChallengeService.currentDay(of: challenge) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            // Drag indicator.
            Capsule()
                .fill(Color.appBorder)
                .frame(width: 32, height: 4)
                .frame(maxWidth: .infinity)

            Text("ABANDON CHALLENGE")
                .font(AppFont.mono(10, weight: .bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color.danger)

            Text(headline)
                .font(AppFont.display(22))
                .foregroundStyle(Color.textPrimary)

            Text(bodyCopy)
                .font(AppFont.ui(13, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Reassurance card — "Your log stays."
            HStack(alignment: .top, spacing: Space.x2) {
                Rectangle()
                    .fill(Color.danger)
                    .frame(width: 2)
                Text("You can start a new challenge right after.")
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                    .padding(.vertical, 6)
            }
            .padding(.leading, 4)
            .padding(.trailing, Space.x3)
            .padding(.vertical, 2)
            .background(Color.appSurface2, in: .rect(cornerRadius: 6))

            Button(action: onConfirm) {
                Text("Abandon")
                    .font(AppFont.ui(14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.danger, in: .rect(cornerRadius: 11))
            }
            .buttonStyle(.plain)

            Button(action: onCancel) {
                Text("Keep going")
                    .font(AppFont.ui(14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.appSurface2, in: .rect(cornerRadius: 11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(Color.appBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Space.x5)
        .padding(.top, Space.x3)
        .padding(.bottom, Space.x6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
    }

    private var headline: String {
        String.localizedStringWithFormat(
            NSLocalizedString("End Challenge %02lld?", comment: "Abandon sheet headline"),
            challenge.number
        )
    }

    private var bodyCopy: String {
        String.localizedStringWithFormat(
            NSLocalizedString(
                "You're on day %lld of 90. The challenge will move to your history as abandoned. Your workout log stays. Your streak resets.",
                comment: "Abandon sheet body copy"),
            currentDay
        )
    }
}

#Preview {
    AbandonChallengeSheet(
        challenge: ChallengeModel(number: 1),
        onConfirm: {},
        onCancel: {}
    )
}
