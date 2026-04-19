//
//  DesignSystemPreview.swift
//  WorkoutChallenge
//
//  Xcode-canvas playground for the design system. Open in Xcode, hit
//  Resume on the canvas, toggle Light/Dark in the #Preview variants below
//  to sanity-check tokens + components in isolation.
//
//  This file is not referenced by the app — it only produces previews.
//

import SwiftUI

struct DesignSystemPreview: View {
    @State private var range: String = "week"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x6) {

                // HEADER
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text("DAY 54 OF 90 · KEEP GOING").tsEyebrow()
                    Text("Ninety days.").tsH1().foregroundStyle(.textPrimary)
                }

                // SIGMOID HERO
                VStack(alignment: .leading, spacing: Space.x3) {
                    HStack {
                        Text("Your curve").tsEyebrow().foregroundStyle(.textTertiary)
                        Spacer()
                        Chip(title: "On track", isOn: true)
                    }
                    SigmoidCurve(progress: 0.6).frame(height: 120)
                }
                .appCard()

                // BUTTONS
                VStack(alignment: .leading, spacing: Space.x3) {
                    Text("Buttons").tsH3().foregroundStyle(.textPrimary)
                    PrimaryButton(title: "Start today's workout", icon: "play.fill", size: .large) {}
                    HStack(spacing: Space.x2) {
                        PrimaryButton(title: "Log workout") {}
                        SecondaryButton(title: "Skip") {}
                    }
                }

                // SEGMENTED + CHIPS
                VStack(alignment: .leading, spacing: Space.x3) {
                    Text("Controls").tsH3().foregroundStyle(.textPrimary)
                    SegmentedControl(items: [
                        (label: "Week", value: "week"),
                        (label: "Month", value: "month"),
                        (label: "Challenge", value: "chal")
                    ], selection: $range)

                    HStack(spacing: Space.x2) {
                        Chip(title: "All", isOn: true)
                        Chip(title: "Rollerblading", dotColor: .dataRoller)
                        Chip(title: "Padel", dotColor: .dataPadel)
                        Chip(title: "Tennis", dotColor: .dataTennis)
                    }
                }

                // STATS
                HStack(spacing: Space.x2) {
                    StatTile(label: "Streak", value: "12", unit: "days")
                    StatTile(label: "This week", value: "22", unit: "min", accent: true)
                    StatTile(label: "Target", value: "240", unit: "min")
                }

                // PROGRESS
                VStack(alignment: .leading, spacing: Space.x3) {
                    Text("Progress").tsH3().foregroundStyle(.textPrimary)
                    VoltProgress(progress: 0.6)
                    Text("54 of 90 days").tsCaption()
                }
                .appCard()

                // DAY GRID (first 45 for preview)
                VStack(alignment: .leading, spacing: Space.x3) {
                    Text("90-day grid").tsH3().foregroundStyle(.textPrimary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 15), spacing: 4) {
                        ForEach(1...45, id: \.self) { day in
                            let state: DayCell.State =
                                day < 41 ? .completed :
                                day == 41 ? .today :
                                day < 45 ? .proposed : .upcoming
                            DayCell(day: day, state: state)
                        }
                    }
                }
                .appCard()

                // CHART
                VStack(alignment: .leading, spacing: Space.x3) {
                    Text("This week").tsH3().foregroundStyle(.textPrimary)
                    HStack(alignment: .bottom, spacing: 6) {
                        ChartBar(value: 100, ratio: 1.0,  color: .dataSpeed, label: "S")
                        ChartBar(value: 22,  ratio: 0.22, color: .accentVolt, label: "M")
                        ChartBar(value: 18,  ratio: 0.18, color: .accentVolt, isProposed: true, label: "T")
                        ChartBar(value: 18,  ratio: 0.18, color: .accentVolt, isProposed: true, label: "W")
                        ChartBar(value: 18,  ratio: 0.18, color: .accentVolt, isProposed: true, label: "T")
                        ChartBar(value: 0,   ratio: 0.05, color: .appSurface2, label: "F")
                        ChartBar(value: 0,   ratio: 0.05, color: .appSurface2, label: "S")
                    }
                    .frame(height: 140)
                }
                .appCard()
            }
            .padding(Space.x5)
        }
        .background(Color.appBg.ignoresSafeArea())
    }
}

#Preview("Dark") {
    DesignSystemPreview().preferredColorScheme(.dark)
}

#Preview("Light") {
    DesignSystemPreview().preferredColorScheme(.light)
}
