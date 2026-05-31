//
//  StrokeVolumeAnimationView.swift
//  WorkoutChallenge
//
//  The "stroke volume" Adaptations explainer, animated. Endurance training
//  enlarges the left-ventricle chamber so each beat ejects more blood —
//  this view shows a beating heart whose chamber grows with the user's
//  accumulated aerobic dose.
//
//  Two rendering paths, chosen at runtime:
//    • Rive (when the RiveRuntime package is linked AND a `stroke_volume.riv`
//      asset is bundled) — the state-machine input `doseFraction` (0…1)
//      drives the chamber size. See the state-machine contract below.
//    • Native SwiftUI fallback (always available) — a Canvas-free,
//      TimelineView-driven beating heart. This ships today and guarantees
//      the row never renders blank while the Rive art is being authored.
//
//  ── Rive state-machine contract (build this in the Rive editor) ─────────
//    File:           stroke_volume.riv
//    State machine:  "StrokeSM"
//    Inputs:
//      • doseFraction : Number (0…1) — resting chamber size / fill. 0 = an
//        untrained heart, 1 = full modeled stroke-volume dose.
//      • beat         : Trigger (optional) — pulse to force a contraction;
//        if omitted, the art should auto-loop its own beat.
//  ─────────────────────────────────────────────────────────────────────
//

import SwiftUI

#if canImport(RiveRuntime)
import RiveRuntime
#endif

/// Public entry point used by `AdaptationsCard`. Picks Rive when both the
/// runtime and the `.riv` asset are present; otherwise the native fallback.
struct StrokeVolumeAnimationView: View {
    /// 0…1 — the stroke-volume adaptation's dose fraction.
    let doseFraction: Double

    var body: some View {
        #if canImport(RiveRuntime)
        if Bundle.main.url(forResource: "stroke_volume", withExtension: "riv") != nil {
            StrokeVolumeRiveView(doseFraction: doseFraction)
        } else {
            StrokeVolumeFallbackView(doseFraction: doseFraction)
        }
        #else
        StrokeVolumeFallbackView(doseFraction: doseFraction)
        #endif
    }
}

// MARK: - Rive path (compiled only once RiveRuntime is linked)

#if canImport(RiveRuntime)
struct StrokeVolumeRiveView: View {
    let doseFraction: Double

    @StateObject private var vm = RiveViewModel(
        fileName: "stroke_volume",
        stateMachineName: "StrokeSM"
    )

    var body: some View {
        vm.view()
            .frame(height: 140)
            .onAppear { pushDose(doseFraction) }
            .onChange(of: doseFraction) { _, newValue in pushDose(newValue) }
    }

    private func pushDose(_ value: Double) {
        // No-ops gracefully inside RiveViewModel if the input is absent.
        vm.setInput("doseFraction", value: min(1, max(0, value)))
    }
}
#endif

// MARK: - Native fallback

/// A beating heart whose chamber size scales with `doseFraction`. Pure
/// SwiftUI + TimelineView so it needs no assets or third-party runtime.
struct StrokeVolumeFallbackView: View {
    let doseFraction: Double

    /// Resting size grows with dose: an untrained heart is smaller, a
    /// well-adapted one fills more of the frame (bigger chamber per beat).
    private var restingScale: Double { 0.78 + 0.22 * clampedDose }
    private var clampedDose: Double { min(1, max(0, doseFraction)) }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let scale = beatScale(at: t) * restingScale
            ZStack {
                HeartShape()
                    .fill(
                        RadialGradient(
                            colors: [Color.danger.opacity(0.95), Color.danger.opacity(0.55)],
                            center: .center,
                            startRadius: 2,
                            endRadius: 60
                        )
                    )
                    .overlay(
                        HeartShape().stroke(Color.textPrimary.opacity(0.25), lineWidth: 1.5)
                    )
                    .frame(width: 84, height: 84)
                    .scaleEffect(scale)
                    .shadow(color: Color.danger.opacity(0.4 * beatGlow(at: t)), radius: 14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .animation(nil, value: scale) // TimelineView drives it; no implicit anim
        }
        .accessibilityElement()
        .accessibilityLabel("Animated heart. Chamber size reflects your stroke-volume adaptation dose.")
    }

    /// A "lub-dub" contraction once per cardiac cycle. Returns a multiplier
    /// in roughly [0.88, 1.0] — the heart squeezes (gets smaller) on systole.
    private func beatScale(at t: TimeInterval) -> Double {
        let period = 0.92 // ~65 bpm at rest
        let phase = t.truncatingRemainder(dividingBy: period) / period
        // Two quick thumps (lub, then dub) early in the cycle.
        let lub = gaussian(phase, center: 0.08, width: 0.05)
        let dub = gaussian(phase, center: 0.22, width: 0.06) * 0.6
        let squeeze = min(1.0, lub + dub)
        return 1.0 - 0.12 * squeeze
    }

    /// Glow pulse synced to the beat (0…1), brightest at contraction.
    private func beatGlow(at t: TimeInterval) -> Double {
        let period = 0.92
        let phase = t.truncatingRemainder(dividingBy: period) / period
        return gaussian(phase, center: 0.08, width: 0.06)
    }

    private func gaussian(_ x: Double, center: Double, width: Double) -> Double {
        exp(-pow((x - center) / width, 2))
    }
}

/// A simple symmetric heart silhouette normalized to its bounding rect.
private struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        // Bottom tip.
        p.move(to: CGPoint(x: w * 0.5, y: h * 0.95))
        // Left lobe up to the top dip.
        p.addCurve(
            to: CGPoint(x: w * 0.5, y: h * 0.28),
            control1: CGPoint(x: w * -0.05, y: h * 0.55),
            control2: CGPoint(x: w * 0.12, y: h * 0.05)
        )
        // Right lobe back down to the tip.
        p.addCurve(
            to: CGPoint(x: w * 0.5, y: h * 0.95),
            control1: CGPoint(x: w * 0.88, y: h * 0.05),
            control2: CGPoint(x: w * 1.05, y: h * 0.55)
        )
        p.closeSubpath()
        return p
    }
}

#Preview {
    VStack(spacing: 24) {
        StrokeVolumeAnimationView(doseFraction: 0.2)
        StrokeVolumeAnimationView(doseFraction: 0.9)
    }
    .padding()
    .background(Color.appBg)
}
