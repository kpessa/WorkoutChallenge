//
//  Celestial.swift
//  WorkoutChallenge
//
//  UI primitives for the "Celestial" layer (Design Meld · Lifecycle +
//  Celestial, Part B). These are intentionally small, self-contained views
//  so they can drop into any screen as ambient context — not a destination.
//
//  - MoonGlyph: eight geometric moon-phase states, rendered from clip paths.
//  - SunArc:    horizon-to-horizon arc with a "now" dot interpolated from
//    sunrise / sunset. Labels are sunrise & sunset, center is current time.
//  - CelestialStrip: the one-line header band (moon glyph + sun times +
//    days-to-next-solstice) that lives at the top of the Bars screen.
//

import SwiftUI

// MARK: - Moon glyph

/// Eight-phase moon icon. Uses the design-system ink/chalk palette via
/// dedicated "dark" and "light" colors so the shape reads on any surface:
/// the lit half draws in `chalkColor`, the dark half in `darkColor`. The
/// glyph is a circle with a clipped shape layered on top — no SF Symbols,
/// no images. 18 / 22 / 32pt render sizes are the spec'd sizes.
struct MoonGlyph: View {
    let phase: CelestialService.MoonPhase
    var size: CGFloat = 22
    /// Lit portion (e.g. chalk / surface).
    var chalkColor: Color = .appSurface
    /// Unlit portion (e.g. ink / text).
    var darkColor: Color = .textPrimary
    /// Stroke around the whole disc.
    var strokeColor: Color = .textPrimary
    var strokeWidth: CGFloat = 1.5

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                              width: r * 2, height: r * 2))

            // Base disc: dark for waxing side, chalk for waning side. This
            // choice keeps the "lit" side always chalk, the "unlit" side
            // always dark — matching how our eyes read phases in the sky.
            let isWaxingOrNew = phase == .new || phase == .waxingCrescent
                || phase == .firstQuarter || phase == .waxingGibbous
            ctx.fill(disc, with: .color(isWaxingOrNew ? darkColor : chalkColor))

            // Overlay shape gives us the lit/unlit crescent or gibbous.
            switch phase {
            case .new:
                // Whole disc is dark — nothing to draw on top.
                break
            case .full:
                // Whole disc is chalk — nothing to draw on top.
                break
            case .waxingCrescent:
                // Lit sliver on the right; draw half-disc chalk, then
                // an ellipse of dark to carve the outer curve.
                drawRightCrescent(
                    ctx: ctx, center: c, radius: r,
                    litColor: chalkColor, darkColor: darkColor,
                    litInset: 0.65
                )
            case .firstQuarter:
                // Right half lit.
                drawHalf(ctx: ctx, center: c, radius: r,
                         color: chalkColor, rightSide: true)
            case .waxingGibbous:
                // Lit >50%, dark sliver on the left.
                drawRightCrescent(
                    ctx: ctx, center: c, radius: r,
                    litColor: chalkColor, darkColor: darkColor,
                    litInset: -0.55
                )
            case .waningGibbous:
                // Lit >50%, dark sliver on the right (mirror of waxingGib).
                drawLeftCrescent(
                    ctx: ctx, center: c, radius: r,
                    litColor: chalkColor, darkColor: darkColor,
                    litInset: -0.55
                )
            case .lastQuarter:
                // Left half lit.
                drawHalf(ctx: ctx, center: c, radius: r,
                         color: chalkColor, rightSide: false)
            case .waningCrescent:
                // Lit sliver on the left.
                drawLeftCrescent(
                    ctx: ctx, center: c, radius: r,
                    litColor: chalkColor, darkColor: darkColor,
                    litInset: 0.65
                )
            }

            // Stroke around the disc last so it crisps both fills.
            ctx.stroke(disc, with: .color(strokeColor), lineWidth: strokeWidth)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(phase.label)
    }

    // MARK: Crescent / gibbous drawing

    private func drawHalf(
        ctx: GraphicsContext,
        center c: CGPoint,
        radius r: CGFloat,
        color: Color,
        rightSide: Bool
    ) {
        var path = Path()
        path.addArc(
            center: c, radius: r,
            startAngle: .degrees(rightSide ? -90 : 90),
            endAngle: .degrees(rightSide ? 90 : 270),
            clockwise: false
        )
        path.closeSubpath()
        ctx.fill(path, with: .color(color))
    }

    /// Carves a crescent shape on the right side of the disc.
    /// `litInset` controls how much of the disc the lit region covers:
    /// positive = narrow (crescent), negative = wide (gibbous).
    private func drawRightCrescent(
        ctx: GraphicsContext,
        center c: CGPoint,
        radius r: CGFloat,
        litColor: Color,
        darkColor: Color,
        litInset: CGFloat
    ) {
        // Draw the full right half in litColor first.
        drawHalf(ctx: ctx, center: c, radius: r, color: litColor, rightSide: true)
        // Then subtract an ellipse to carve the curved terminator.
        let w = r * (1 - abs(litInset))
        let rect = CGRect(x: c.x - w, y: c.y - r, width: w * 2, height: r * 2)
        let carve = Path(ellipseIn: rect)
        let carveColor = litInset > 0 ? darkColor : litColor
        // For gibbous (litInset < 0), the carved ellipse extends past the
        // center toward the dark side — recoloring the narrow sliver at
        // the left back to litColor. Handled by choosing carveColor.
        if litInset > 0 {
            ctx.fill(carve, with: .color(carveColor))
        } else {
            // gibbous: fill the ellipse with chalk so it expands the lit area.
            ctx.fill(carve, with: .color(litColor))
            // then we need to restore the dark left-edge sliver
            var leftSliver = Path()
            leftSliver.move(to: CGPoint(x: c.x, y: c.y - r))
            leftSliver.addArc(
                center: c, radius: r,
                startAngle: .degrees(-90),
                endAngle: .degrees(90),
                clockwise: true
            )
            leftSliver.closeSubpath()
            // Overlay the carved ellipse — but only where it crosses into
            // the original dark half. We achieve this by re-drawing the
            // left half dark, then re-drawing the chalk carve on top
            // (which only extends into the right half anyway).
            ctx.fill(leftSliver, with: .color(darkColor))
            ctx.fill(carve, with: .color(litColor))
        }
    }

    private func drawLeftCrescent(
        ctx: GraphicsContext,
        center c: CGPoint,
        radius r: CGFloat,
        litColor: Color,
        darkColor: Color,
        litInset: CGFloat
    ) {
        drawHalf(ctx: ctx, center: c, radius: r, color: litColor, rightSide: false)
        let w = r * (1 - abs(litInset))
        let rect = CGRect(x: c.x - w, y: c.y - r, width: w * 2, height: r * 2)
        let carve = Path(ellipseIn: rect)
        if litInset > 0 {
            ctx.fill(carve, with: .color(darkColor))
        } else {
            ctx.fill(carve, with: .color(litColor))
            var rightSliver = Path()
            rightSliver.move(to: CGPoint(x: c.x, y: c.y - r))
            rightSliver.addArc(
                center: c, radius: r,
                startAngle: .degrees(-90),
                endAngle: .degrees(90),
                clockwise: false
            )
            rightSliver.closeSubpath()
            ctx.fill(rightSliver, with: .color(darkColor))
            ctx.fill(carve, with: .color(litColor))
        }
    }
}

// MARK: - Sun arc

/// Horizon-to-horizon sun arc card body. Renders sunrise / sunset tick
/// marks on a dashed horizon line, a dashed Volt arc overhead, and a
/// filled "now" dot interpolated between the two times.
struct SunArc: View {
    let sunrise: Date
    let sunset: Date
    var now: Date = Date()
    var arcColor: Color = .accentVolt
    var horizonColor: Color = .appBorder
    var labelColor: Color = .textTertiary
    var dotStrokeColor: Color = .textPrimary

    /// 0 at sunrise, 1 at sunset. Clamped outside (dot snaps to the
    /// horizon) so the arc doesn't wrap around on off-hours.
    private var fraction: Double {
        let total = sunset.timeIntervalSince(sunrise)
        guard total > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(sunrise)
        return max(0, min(1, elapsed / total))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad: CGFloat = 10
            let left = CGPoint(x: pad, y: h - pad)
            let right = CGPoint(x: w - pad, y: h - pad)

            ZStack {
                // Horizon line (dashed).
                Path { p in
                    p.move(to: left)
                    p.addLine(to: right)
                }
                .stroke(horizonColor, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

                // Half-ellipse arc (dashed Volt).
                Path { p in
                    p.move(to: left)
                    p.addQuadCurve(
                        to: right,
                        control: CGPoint(x: w / 2, y: -h * 0.15)
                    )
                }
                .stroke(arcColor.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.2, dash: [3, 4]))

                // Tick dots at horizon endpoints.
                Circle()
                    .fill(Color.textPrimary)
                    .frame(width: 5, height: 5)
                    .position(left)
                Circle()
                    .fill(Color.textPrimary)
                    .frame(width: 5, height: 5)
                    .position(right)

                // Now dot on the arc — quadratic Bezier at t = fraction.
                let t = fraction
                let cx = w / 2
                let cy = -h * 0.15
                let nowX = pow(1 - t, 2) * left.x + 2 * (1 - t) * t * cx
                    + pow(t, 2) * right.x
                let nowY = pow(1 - t, 2) * left.y + 2 * (1 - t) * t * cy
                    + pow(t, 2) * right.y
                Circle()
                    .fill(arcColor)
                    .overlay(Circle().stroke(dotStrokeColor, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                    .position(x: nowX, y: nowY)

                // Sunrise / sunset labels.
                Text(sunrise, format: .dateTime.hour().minute())
                    .font(AppFont.mono(9, weight: .medium))
                    .foregroundStyle(labelColor)
                    .position(x: left.x + 4, y: h - 2)
                Text(sunset, format: .dateTime.hour().minute())
                    .font(AppFont.mono(9, weight: .medium))
                    .foregroundStyle(labelColor)
                    .position(x: right.x - 16, y: h - 2)
            }
        }
    }
}

// MARK: - Celestial strip

/// Ambient header strip that lives at the top of the Bars/Today screen:
///
///   🌗  WAXING GIBBOUS · 89%      13D TO
///       Sunrise 6:42 · Sunset 7:18  SUMMER
///
/// Not a destination — a quiet contextual band. Uses hardcoded Austin, TX
/// coordinates as the fallback per the design spec.
struct CelestialStrip: View {
    var date: Date = Date()
    var coordinate: CelestialService.Coordinate = CelestialService.defaultCoordinate

    private var phase: CelestialService.MoonPhase {
        CelestialService.moonPhase(on: date)
    }
    private var illuminationPct: Int {
        Int((CelestialService.moonIllumination(on: date) * 100).rounded())
    }
    private var sun: (sunrise: Date, sunset: Date)? {
        CelestialService.sunriseSunset(on: date, at: coordinate)
    }
    private var nextEvent: (date: Date, kind: CelestialService.SolarEvent) {
        CelestialService.nextSolarEvent(from: date)
    }
    private var daysToNext: Int {
        max(0, date.daysUntil(nextEvent.date))
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.x3) {
            MoonGlyph(phase: phase, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(phaseHeadline)
                    .font(AppFont.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.textTertiary)
                Text(sunSubhead)
                    .font(AppFont.ui(11, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer(minLength: Space.x2)

            VStack(alignment: .trailing, spacing: 2) {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("%lldd to",
                                       comment: "Celestial widget: days until next event"),
                    daysToNext))
                    .font(AppFont.mono(9, weight: .medium))
                    .foregroundStyle(Color.accentInk)
                Text(nextEvent.kind.shortLabel)
                    .font(AppFont.ui(11, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
            }
        }
        .padding(.vertical, Space.x2)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appBorder)
                .frame(height: 1)
        }
    }

    private var phaseHeadline: String {
        String.localizedStringWithFormat(
            NSLocalizedString("%@ · %lld%%",
                               comment: "Celestial widget: moon phase name + illumination %"),
            phase.label, illuminationPct)
    }

    private var sunSubhead: String {
        guard let sun else {
            return String(localized: "All-day sun",
                          comment: "Celestial subhead when there is no sunrise/sunset (polar day)")
        }
        let f = Date.FormatStyle().hour(.defaultDigits(amPM: .omitted)).minute()
        let rise = sun.sunrise.formatted(f)
        let set = sun.sunset.formatted(f)
        let mins = Int(sun.sunset.timeIntervalSince(sun.sunrise) / 60)
        let h = mins / 60
        let m = mins % 60
        return String.localizedStringWithFormat(
            NSLocalizedString("Sunrise %@ · Sunset %@ · %lldh %lldm",
                               comment: "Celestial subhead: sunrise/sunset times and day length"),
            rise, set, h, m)
    }
}

#Preview("Moon phases") {
    VStack(spacing: 16) {
        ForEach(CelestialService.MoonPhase.allCases, id: \.self) { p in
            HStack(spacing: 12) {
                MoonGlyph(phase: p, size: 32)
                Text(p.label)
                    .font(AppFont.mono(11))
                    .foregroundStyle(Color.textPrimary)
            }
        }
    }
    .padding()
    .background(Color.appBg)
}

#Preview("Celestial strip") {
    CelestialStrip()
        .padding()
        .background(Color.appBg)
}

#Preview("Sun arc") {
    SunArc(
        sunrise: Calendar.current.date(
            bySettingHour: 6, minute: 42, second: 0, of: Date()) ?? Date(),
        sunset: Calendar.current.date(
            bySettingHour: 19, minute: 18, second: 0, of: Date()) ?? Date()
    )
    .frame(height: 120)
    .padding()
    .background(Color.appBg)
}
