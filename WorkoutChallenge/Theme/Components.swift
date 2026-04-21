//
//  Components.swift
//  WorkoutChallenge
//
//  Design-system components ported from the ios-handoff package
//  (delivered 2026-04-19). These are the *building blocks* screens are
//  composed of: buttons, chips, segmented control, progress bar, stat tile,
//  day cell, chart bar, card modifier, and the sigmoid hero graphic.
//
//  Color/spacing/radius/motion tokens live in Tokens.swift; text styles in
//  Typography.swift. Components reach into those tokens rather than baking
//  hex values inline — the one exception is the literal ink foreground
//  `Color(red: 0.04, green: 0.04, blue: 0.04)` used on Volt surfaces, which
//  the design spec pins to ink (#0A0B0A) *regardless* of light/dark mode.
//

import SwiftUI

// MARK: - Ink (foreground on Volt surfaces)

/// The design system reserves this specific ink color for text/icons that
/// sit *on top of* `accentVolt`. It must not flip in dark mode — Volt always
/// pairs with ink as its foreground, never white.
private let inkOnVolt = Color(red: 0.04, green: 0.04, blue: 0.04)

// MARK: - Buttons

/// Primary call-to-action button. Volt background + ink foreground, bold sans.
struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var size: ButtonSize = .regular
    let action: () -> Void

    enum ButtonSize {
        case small, regular, large
        var padH: CGFloat { self == .small ? 14 : self == .large ? 24 : 20 }
        var padV: CGFloat { self == .small ? 10 : self == .large ? 18 : 14 }
        var font: CGFloat { self == .small ? 13 : self == .large ? 16 : 14.5 }
        var radius: CGFloat { self == .small ? 10 : self == .large ? 14 : 12 }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                // Wrap via LocalizedStringKey so literal-string callers
                // ("Begin", "Continue", …) pick up the Localizable catalog.
                // Callers that pass already-formatted dynamic strings (e.g.
                // via String.localizedStringWithFormat) fall through the
                // lookup and render verbatim.
                Text(LocalizedStringKey(title))
            }
            .font(AppFont.ui(size.font, weight: .bold))
            .foregroundStyle(inkOnVolt)
            .padding(.horizontal, size.padH)
            .padding(.vertical, size.padV)
            .frame(maxWidth: .infinity)
            .background(Color.accentVolt, in: .rect(cornerRadius: size.radius))
        }
        .buttonStyle(.plain)
    }
}

/// Secondary / neutral button. Surface2 fill + border, primary text color.
struct SecondaryButton: View {
    let title: String
    var icon: String? = nil
    var size: PrimaryButton.ButtonSize = .regular
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(LocalizedStringKey(title))
            }
            .font(AppFont.ui(size.font, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, size.padH)
            .padding(.vertical, size.padV)
            .frame(maxWidth: .infinity)
            .background(Color.appSurface2, in: .rect(cornerRadius: size.radius))
            .overlay(
                RoundedRectangle(cornerRadius: size.radius)
                    .stroke(Color.appBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chip

/// Small pill-shaped tag. Can be static, toggled on (Volt fill), or tappable.
struct Chip: View {
    let title: String
    var dotColor: Color? = nil
    var isOn: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        let content = HStack(spacing: 6) {
            if let dotColor {
                Circle().fill(dotColor).frame(width: 8, height: 8)
            }
            Text(LocalizedStringKey(title))
                .font(AppFont.mono(11, weight: isOn ? .bold : .medium))
                .tracking(0.8)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isOn ? inkOnVolt : Color.textSecondary)
        .background(
            isOn ? AnyShapeStyle(Color.accentVolt) : AnyShapeStyle(Color.clear),
            in: Capsule()
        )
        // Meld rule: every Volt fill gets a 1.5pt ink stroke.
        .overlay(
            Capsule().stroke(isOn ? inkOnVolt : Color.appBorder,
                             lineWidth: isOn ? 1.5 : 1)
        )

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - Segmented control

/// Custom segmented control — Volt-on-ink highlight, surface2 background.
/// Generic over the selected value type so it works with enums, strings, ints.
struct SegmentedControl<T: Hashable>: View {
    let items: [(label: String, value: T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let on = item.value == selection
                Button { withAnimation(Motion.fast) { selection = item.value } } label: {
                    Text(item.label)
                        .font(AppFont.ui(13, weight: on ? .bold : .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(on ? inkOnVolt : Color.textSecondary)
                        .background(on ? Color.accentVolt : Color.clear,
                                    in: .rect(cornerRadius: 8))
                        // Meld rule: Volt fill always gets a 1.5pt ink stroke.
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(on ? inkOnVolt : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.appSurface2, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
    }
}

// MARK: - Progress

/// Horizontal progress bar with the signature Volt → Neon gradient fill.
struct VoltProgress: View {
    /// 0.0 – 1.0
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.appSurface2)
                Capsule()
                    .fill(LinearGradient(colors: [.accentVolt, .accentNeon],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: 10)
        .overlay(Capsule().stroke(Color.appBorder, lineWidth: 1))
    }
}

// MARK: - Stat tile

/// Small metric card: eyebrow label + big number + optional unit.
/// Used in grids / rows for quick stats (streak, weekly total, target).
struct StatTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var accent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).tsEyebrow().foregroundStyle(Color.textTertiary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(AppFont.display(28))
                    .foregroundStyle(accent ? Color.accentInk : Color.textPrimary)
                    // Keep 3-digit BPM values like "148" on a single line.
                    // The display font + narrow tile width otherwise wraps
                    // "148" → "14\n8". Shrinking down to 0.6 leaves room for
                    // up to ~4 glyphs worth of digits without clipping.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.appSurface, in: .rect(cornerRadius: Radius.card - 6))
        .overlay(RoundedRectangle(cornerRadius: Radius.card - 6).stroke(Color.appBorder, lineWidth: 1))
    }
}

// MARK: - Day cell (90-day grid)

/// A single square in the challenge's 90-day grid. Five states (per the
/// Design Meld):
/// - completed: solid Volt fill + 1.5pt ink border, ink number
/// - today:     solid Volt fill + 2pt ink border (scale hint via the caller)
/// - missed:    surface fill + 1.5pt dashed ink border — past, not done
/// - upcoming:  flat surface2 fill + 1pt border, tertiary number (future
///              scheduled days; intentionally quiet so completed/today pop)
/// - proposed:  legacy alias retained for backwards compat (same as .missed)
struct DayCell: View {
    enum State { case completed, today, missed, upcoming, proposed }
    let day: Int
    let state: State

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(stroke,
                                style: StrokeStyle(
                                    lineWidth: lineWidth,
                                    dash: dashed ? [3, 2] : []))
                )
            Text("\(day)")
                .font(AppFont.mono(8, weight: .bold))
                .foregroundStyle(textColor)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var dashed: Bool { state == .missed || state == .proposed }
    private var lineWidth: CGFloat {
        switch state {
        case .today: return 2
        case .completed, .missed, .proposed: return 1.5
        case .upcoming: return 1
        }
    }
    private var fill: Color {
        switch state {
        case .completed: return .accentVolt
        case .today:     return .accentVolt
        case .missed, .proposed: return .appSurface
        case .upcoming:  return .appSurface2
        }
    }
    private var stroke: Color {
        switch state {
        case .completed, .today: return .textPrimary
        case .missed, .proposed: return .textPrimary
        case .upcoming: return .appBorder
        }
    }
    private var textColor: Color {
        switch state {
        case .completed, .today: return inkOnVolt
        case .missed, .proposed: return .textSecondary
        case .upcoming: return .textTertiary
        }
    }
}

// MARK: - Chart bar

/// Vertical bar for simple bar charts (e.g. "this week" summary).
/// `ratio` is 0..1 of available height. `isProposed` renders an outlined
/// dashed bar — the webapp uses this for projected/upcoming workouts.
struct ChartBar: View {
    let value: Double       // displayed number
    let ratio: Double       // 0..1 of chart height
    var color: Color = .accentVolt
    var isProposed: Bool = false
    var label: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            Text(Int(value).description)
                .font(AppFont.mono(9, weight: .medium))
                .foregroundStyle(Color.textSecondary)
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isProposed ? Color.clear : color)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isProposed ? color : .clear,
                                        style: StrokeStyle(lineWidth: 2, dash: isProposed ? [3, 2] : []))
                        )
                        .frame(height: geo.size.height * max(0, min(1, ratio)))
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            if let label {
                Text(label)
                    .font(AppFont.mono(9))
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }
}

// MARK: - Card modifier

/// Standard card chrome: Surface fill, border, card-radius, x4 inset.
/// Apply via `.appCard()` — see DesignSystemPreview for usage.
struct AppCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Space.x4)
            .background(Color.appSurface, in: .rect(cornerRadius: Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(Color.appBorder, lineWidth: 1)
            )
    }
}
extension View {
    /// Wrap content in the standard design-system card (surface + border + padding).
    func appCard() -> some View { modifier(AppCard()) }
}

// MARK: - Sigmoid curve (hero graphic)

/// The signature visual — a logistic/S-curve with a marker at `progress`.
/// Mirrors the 90-day progression equation the app uses under the hood.
/// Drop it in an `.appCard()` for the hero block of the home screen.
///
/// **Light vs. dark rendering (a11y):** In light mode the stroke and
/// milestone dots render in ink (`.textPrimary`), with a lower-opacity
/// Volt *fill* under the curve — the line is what carries the shape, and
/// ink reads from anywhere; Volt on a light field is ~1.07:1 and would
/// disappear. In dark mode we flip back to a Volt stroke on the black
/// field, which is the original signature look. Callers can still pass
/// an explicit `strokeColor` to override (e.g. for a single-color preview).
struct SigmoidCurve: View {
    @Environment(\.colorScheme) private var scheme

    /// 0.0 – 1.0 — where "today" sits along the curve.
    var progress: Double = 0.6
    /// Override the auto-resolved stroke/dot color. `nil` → use
    /// `.textPrimary` on light, `.accentVolt` on dark.
    var strokeColor: Color? = nil
    /// Always the Volt fill — doesn't flip, just opacity-adjusted per mode.
    var fillColor: Color = .accentVolt
    var fillOpacity: Double = 0.22
    var showMilestones: Bool = true

    private var resolvedStroke: Color {
        if let strokeColor { return strokeColor }
        return scheme == .dark ? .accentVolt : .textPrimary
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let stroke = resolvedStroke

            // Logistic: y = 1 / (1 + e^(-k(x - x0)))
            let k = 6.0, x0 = 0.55
            let pad: CGFloat = 6
            // NOTE: declared as a closure rather than a nested `func`.
            // `@ViewBuilder` closure bodies (like GeometryReader's) only
            // accept expressions, `let`/`var`, and standard control-flow
            // statements — not nested function declarations. Using a `let`
            // closure keeps this within the builder's supported grammar.
            let pt: (Double) -> CGPoint = { t in
                let x = pad + t * (w - pad * 2)
                let y = 1.0 / (1.0 + exp(-k * (t - x0)))
                return CGPoint(x: x, y: (h - pad) - y * (h - pad * 2))
            }
            let steps = 120
            let points = (0...steps).map { pt(Double($0) / Double(steps)) }

            // Filled area — always Volt, regardless of scheme.
            Path { p in
                p.move(to: CGPoint(x: pad, y: h - pad))
                points.forEach { p.addLine(to: $0) }
                p.addLine(to: CGPoint(x: w - pad, y: h - pad))
                p.closeSubpath()
            }
            .fill(fillColor.opacity(fillOpacity))

            // Curve stroke — ink on light, Volt on dark.
            Path { p in
                p.move(to: points.first!)
                points.dropFirst().forEach { p.addLine(to: $0) }
            }
            .stroke(stroke, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            if showMilestones {
                // Milestones at t = 0.23, progress, 0.92 — match stroke.
                Circle().fill(stroke).frame(width: 7, height: 7)
                    .position(pt(0.23))
                Circle().fill(stroke)
                    .overlay(Circle().stroke(Color.appBg, lineWidth: 2))
                    .frame(width: 10, height: 10)
                    .position(pt(max(0, min(1, progress))))
                Circle().fill(stroke).opacity(0.4).frame(width: 7, height: 7)
                    .position(pt(0.92))
            }
        }
    }
}
