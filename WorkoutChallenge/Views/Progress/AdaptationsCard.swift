//
//  AdaptationsCard.swift
//  WorkoutChallenge
//
//  Progress tab's "what's actually happening inside your body during
//  this challenge?" card. Three rows — Neural / Mitochondrial / Stroke
//  volume — covering the fast / medium / slow adaptation timescales.
//
//  Each row collapses to a one-line summary with a stage chip and a
//  dose meter, and expands on tap to show:
//    • the mechanism paragraph (the teaching moment)
//    • the stimulus dose explainer
//    • the proxy reading, when one exists, with a favorable-direction
//      tint (resting-HR ↓ is good, VO₂Max ↑ is good)
//    • the deterministic caption tying time + stimulus + proxy together
//
//  All numbers come from `AdaptationProgressService` — the card just
//  renders. We deliberately surface "modeled, not measured" copy so the
//  educational read stays honest.
//

import SwiftUI

struct AdaptationsCard: View {
    let workouts: [WorkoutModel]
    let startDate: Date
    let endDate: Date

    @EnvironmentObject private var healthKit: HealthKitService

    @State private var restingHR: [HealthKitService.RestingHRSample] = []
    @State private var vo2: [HealthKitService.VO2MaxSample] = []
    @State private var expanded: Set<String> = []

    private var progresses: [AdaptationProgress] {
        AdaptationProgressService.compute(
            workouts: workouts,
            startDate: startDate,
            now: Date(),
            restingHRSeries: restingHR,
            vo2Series: vo2
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            header
            ForEach(progresses) { p in
                row(progress: p)
                if p.id != progresses.last?.id {
                    RowDivider()
                }
            }
            footer
        }
        .appCard()
        .task(id: taskKey) { await loadProxies() }
    }

    private var taskKey: String {
        "\(startDate.timeIntervalSince1970)-\(endDate.timeIntervalSince1970)-\(healthKit.isAvailable)"
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("ADAPTATIONS").tsEyebrow().foregroundStyle(Color.textTertiary)
            Spacer()
            Text("Modeled, not measured")
                .font(AppFont.ui(11, weight: .medium))
                .foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(progress p: AdaptationProgress) -> some View {
        let isExpanded = expanded.contains(p.id)
        VStack(alignment: .leading, spacing: Space.x2) {
            Button {
                toggle(p.id)
            } label: {
                rowHeader(progress: p, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)

            doseMeter(progress: p)

            if isExpanded {
                expandedBody(progress: p)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(Motion.base.delay(0.05)),
                        removal: .opacity.animation(Motion.fast)
                    ))
            }
        }
    }

    private func rowHeader(progress p: AdaptationProgress, isExpanded: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(p.adaptation.title)
                        .font(AppFont.ui(14, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                    stageChip(p.stage)
                }
                Text(p.adaptation.tagline)
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
        }
        .contentShape(Rectangle())
    }

    /// Tiny pill showing accumulation/active/matured/maintenance. Color
    /// follows the stage so the eye can scan three rows and immediately
    /// see "where am I on each curve?"
    private func stageChip(_ stage: AdaptationStage) -> some View {
        let tint: Color
        switch stage {
        case .accumulating: tint = Color.textTertiary
        case .active:       tint = Color.accentVolt
        case .matured:      tint = Color.accentNeon
        case .maintenance:  tint = Color.textSecondary
        }
        return Text(stage.label.uppercased())
            .font(AppFont.mono(9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.3), lineWidth: 1))
    }

    /// Horizontal progress meter showing dose-vs-target, capped at 100%
    /// visually but with the label revealing actual values (so the user
    /// can see they're at "12 / 8 sessions" past the target).
    @ViewBuilder
    private func doseMeter(progress p: AdaptationProgress) -> some View {
        let clamped = min(1.0, max(0.0, p.doseFraction))
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.appSurface2)
                        .frame(height: 6)
                    Capsule()
                        .fill(Color.accentVolt)
                        .frame(width: max(2, geo.size.width * clamped), height: 6)
                }
            }
            .frame(height: 6)
            HStack {
                Text(p.doseLabel)
                    .font(AppFont.mono(10))
                    .foregroundStyle(Color.textTertiary)
                Spacer()
                if p.doseFraction >= 1.0 {
                    Text("Target reached")
                        .font(AppFont.mono(10, weight: .bold))
                        .foregroundStyle(Color.accentNeon)
                }
            }
        }
    }

    @ViewBuilder
    private func expandedBody(progress p: AdaptationProgress) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            // Animated explainer — currently only the stroke-volume row has
            // one. Driven by the row's dose fraction; falls back to a native
            // SwiftUI heart until the Rive asset is bundled.
            if p.adaptation == .strokeVolume {
                StrokeVolumeAnimationView(doseFraction: p.doseFraction)
            }

            // Mechanism — the textbook explanation.
            VStack(alignment: .leading, spacing: Space.x1) {
                Text("MECHANISM")
                    .font(AppFont.mono(9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Color.textTertiary)
                Text(p.adaptation.mechanism)
                    .font(AppFont.ui(12))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Proxy — only when the adaptation has a measurable signal.
            if let proxy = p.proxy {
                proxyBlock(proxy)
            } else {
                noProxyNote(adaptation: p.adaptation)
            }

            // Caption — one line that ties stage + dose + proxy together.
            Text(p.caption)
                .font(AppFont.ui(11, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.x3)
        .background(Color.appSurface2, in: .rect(cornerRadius: Radius.input))
    }

    private func proxyBlock(_ proxy: AdaptationProxyReading) -> some View {
        let tint: Color = proxy.isFavorable ? Color.accentNeon : Color.warn
        let sign = proxy.delta >= 0 ? "+" : ""
        let deltaText = String(format: "%@%.1f %@", sign, proxy.delta, proxy.unit)
        return VStack(alignment: .leading, spacing: 4) {
            Text("PROXY SIGNAL")
                .font(AppFont.mono(9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Color.textTertiary)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(proxy.name)
                    .font(AppFont.ui(12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(deltaText)
                    .font(AppFont.mono(12, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
    }

    private func noProxyNote(adaptation: PhysiologicalAdaptation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROXY SIGNAL")
                .font(AppFont.mono(9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Color.textTertiary)
            Text("No consumer-grade signal tracks this — progress shown is modeled from time + stimulus only.")
                .font(AppFont.ui(11))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Text("These are textbook-range estimates of what's happening in your body, modeled from how long you've been training and what kind. None of this is measured directly — your Watch can't see mitochondria. But the science behind each row is real.")
            .tsCaption()
            .foregroundStyle(Color.textSecondary)
    }

    // MARK: - State / loading

    private func toggle(_ id: String) {
        withAnimation(Motion.base) {
            if expanded.contains(id) {
                expanded.remove(id)
            } else {
                expanded.insert(id)
            }
        }
    }

    private func loadProxies() async {
        guard healthKit.isAvailable else {
            restingHR = []; vo2 = []
            return
        }
        let endInclusive = endDate.addingDays(1)
        async let r = healthKit.fetchRestingHRSeries(since: startDate, until: endInclusive)
        async let v = healthKit.fetchVO2MaxSeries(since: startDate, until: endInclusive)
        let (rFetched, vFetched) = await (r, v)
        restingHR = rFetched
        vo2 = vFetched
    }
}
