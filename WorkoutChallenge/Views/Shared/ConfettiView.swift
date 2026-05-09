//
//  ConfettiView.swift
//  WorkoutChallenge
//
//  Lightweight full-screen confetti burst rendered with Canvas + TimelineView.
//  No external dependencies and no UIKit emitter layer — we simulate ~90
//  paper-sliver particles with simple 2D physics (gravity + horizontal drift
//  + rotation) and draw them each animation frame.
//
//  Used by `CelebrationService` / `RootView` to celebrate the first time a
//  given day's logged minutes cross the sigmoid target. See
//  `CelebrationService.swift` for the trigger logic.
//
//  The view draws particles for `duration` seconds, then its parent is
//  responsible for removing it from the hierarchy (RootView flips the state
//  flag off on a delay). Particles whose lifetime has elapsed simply stop
//  being drawn, which also acts as a graceful fade-out.
//

import SwiftUI

struct ConfettiView: View {
    /// How long the burst lasts, in seconds. Particles beyond their own
    /// per-particle lifetime fade out, but the overall animation duration
    /// is bounded by this value.
    var duration: Double = 2.2

    /// Number of particles per burst. ~90 gives a dense celebration
    /// without hammering the render loop on older devices.
    var particleCount: Int = 90

    /// The moment the view appeared — used as the time origin for all
    /// particle trajectories. `@State` so it's captured once on first render
    /// (re-renders during the burst reuse the same origin).
    @State private var birth: Date = .now

    /// Pre-computed particle fleet. Generated once on appear so random
    /// trajectories stay stable across the burst (otherwise every frame
    /// would re-roll randomness and particles would jitter).
    @State private var particles: [Particle] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(birth)
                guard elapsed <= duration else { return }

                for p in particles {
                    draw(particle: p, elapsed: elapsed, in: &context, size: size)
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
        .onAppear {
            // Generate once — regenerating on every redraw would re-roll
            // randomness each frame and cause visible jitter.
            if particles.isEmpty {
                particles = Self.makeFleet(count: particleCount)
                birth = .now
            }
        }
    }

    // MARK: - Particle drawing

    /// Advance one particle to its `elapsed`-second pose and stroke it into
    /// the canvas. Particles past their own lifetime are silently skipped,
    /// giving us a natural stagger between the first pieces falling offscreen
    /// and the rest finishing up.
    private func draw(
        particle p: Particle,
        elapsed: Double,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let t = elapsed - p.delay
        guard t >= 0, t <= p.lifetime else { return }

        // Position: start at (xStart * width, -20), velocity + gravity.
        let x = p.xStart * size.width + p.vx * CGFloat(t)
        let y = -20 + p.vy * CGFloat(t) + 0.5 * p.gravity * CGFloat(t * t)

        // Skip particles that have already fallen past the bottom — cheap
        // culling so we don't draw stacked invisibles.
        guard y <= size.height + 40 else { return }

        // Fade out over the last 25% of lifetime for a soft tail.
        let fadeStart = p.lifetime * 0.75
        let opacity: Double = t < fadeStart
            ? 1.0
            : max(0, 1.0 - (t - fadeStart) / (p.lifetime - fadeStart))

        // Rotation — spins at a per-particle rate, wrapped around 2π.
        let angle = Angle.radians(p.rotationRate * t + p.rotationPhase)

        // Build the particle shape as a small rect around (0,0), then
        // translate+rotate into place. `GraphicsContext.transform` is cheap
        // for stateless per-particle work.
        var ctx = context
        ctx.translateBy(x: x, y: y)
        ctx.rotate(by: angle)
        ctx.opacity = opacity

        switch p.shape {
        case .rect:
            let rect = CGRect(
                x: -p.size.width / 2,
                y: -p.size.height / 2,
                width: p.size.width,
                height: p.size.height
            )
            ctx.fill(Path(rect), with: .color(p.color))
        case .circle:
            let rect = CGRect(
                x: -p.size.width / 2,
                y: -p.size.height / 2,
                width: p.size.width,
                height: p.size.height
            )
            ctx.fill(Path(ellipseIn: rect), with: .color(p.color))
        case .squiggle:
            // Thin diagonal sliver — gives the burst some shape variety
            // without another asset.
            var path = Path()
            path.move(to: CGPoint(x: -p.size.width / 2, y: 0))
            path.addLine(to: CGPoint(x: p.size.width / 2, y: 0))
            ctx.stroke(
                path,
                with: .color(p.color),
                style: StrokeStyle(lineWidth: p.size.height, lineCap: .round)
            )
        }
    }

    // MARK: - Fleet generator

    /// Colors sampled from the design-system accent palette + a couple of
    /// hard-coded celebratory hues. Volt/Neon anchor the brand; the gold
    /// and coral warm the burst up so it doesn't read as monochrome.
    private static let palette: [Color] = [
        .accentVolt,
        .accentNeon,
        Color(red: 1.00, green: 0.82, blue: 0.25),  // warm gold
        Color(red: 1.00, green: 0.45, blue: 0.55),  // coral pink
        Color(red: 0.36, green: 0.82, blue: 1.00),  // sky blue
        Color(red: 0.70, green: 0.45, blue: 1.00),  // lavender
    ]

    private static func makeFleet(count: Int) -> [Particle] {
        (0..<count).map { _ in
            let shape: Particle.Shape = [
                .rect, .rect, .rect, .circle, .squiggle
            ].randomElement() ?? .rect
            let width: CGFloat = .random(in: 6...11)
            let height: CGFloat = shape == .circle ? width : .random(in: 8...16)

            return Particle(
                xStart: .random(in: 0...1),
                vx: .random(in: -90...90),
                vy: .random(in: 180...380),          // initial downward push
                gravity: .random(in: 420...620),     // accel — feels snappy
                rotationRate: .random(in: -6...6),   // radians/sec
                rotationPhase: .random(in: 0...(.pi * 2)),
                size: CGSize(width: width, height: height),
                color: palette.randomElement() ?? .accentVolt,
                shape: shape,
                delay: .random(in: 0...0.3),          // staggered spawn
                lifetime: .random(in: 1.6...2.4)
            )
        }
    }
}

// MARK: - Particle

private struct Particle {
    enum Shape { case rect, circle, squiggle }

    /// Horizontal spawn position as a fraction of the canvas width (0...1).
    var xStart: CGFloat
    /// Horizontal velocity in points/sec.
    var vx: CGFloat
    /// Vertical velocity at birth in points/sec (positive = down).
    var vy: CGFloat
    /// Vertical acceleration in points/sec². Simulates gravity.
    var gravity: CGFloat
    /// Angular velocity in radians/sec.
    var rotationRate: Double
    /// Starting rotation offset in radians.
    var rotationPhase: Double
    /// Drawn size of the confetti sliver.
    var size: CGSize
    var color: Color
    var shape: Shape
    /// Seconds before this particle starts moving (stagger the spawn).
    var delay: Double
    /// How long this particle lives before being culled + faded.
    var lifetime: Double
}

#Preview("Confetti") {
    ZStack {
        Color.appBg.ignoresSafeArea()
        ConfettiView()
    }
}
