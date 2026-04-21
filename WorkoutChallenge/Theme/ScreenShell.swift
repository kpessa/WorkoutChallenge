//
//  ScreenShell.swift
//  WorkoutChallenge
//
//  Composition helpers that sit *above* the design-system primitives in
//  Components.swift. These aren't part of the canonical handoff — they're
//  project-local patterns for applying the system consistently across
//  every screen:
//
//    • ScreenShell        — dark background + scroll container + eyebrow/H1
//    • SheetHeader        — top bar for modal sheets (cancel × + title + confirm)
//    • AppSection         — a titled section of content (eyebrow header + appCard)
//    • LabeledRow         — form-like row: label on the left, trailing content
//    • SliderRow          — label + value + slider, styled for the system
//    • AppToggleRow       — label + stock Toggle tinted Volt
//
//  The goal is that a screen body reads like:
//    ScreenShell(eyebrow: "DAY 54 OF 90", title: "Today") {
//        AppSection(title: "Today's target") { ... }
//        AppSection(title: "Recent") { ... }
//    }
//

import SwiftUI

// MARK: - ScreenShell

/// Standard scroll-based screen. Paints `appBg` to the safe-area edges and
/// renders an eyebrow + H1 header above the caller-supplied content.
///
/// Use `topPadding: 0` inside a `NavigationStack` that still shows a nav
/// bar (rare — we usually hide it) so the header doesn't get shoved down.
struct ScreenShell<Content: View>: View {
    let eyebrow: String?
    let title: String
    var topPadding: CGFloat = Space.x4
    /// Optional pull-to-refresh handler. When provided, the underlying
    /// `ScrollView` gets `.refreshable` attached so the standard iOS swipe-
    /// down gesture triggers this closure (e.g. to re-import from Apple
    /// Health on the Bars tab). Left nil on screens where pull-to-refresh
    /// wouldn't make sense (Settings, Onboarding, etc.).
    var onRefresh: (() async -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            // Conditional wrapper: `.refreshable` has no opt-out once
            // attached, so branching here keeps non-refreshable screens
            // free of the gesture recognizer (which would otherwise
            // compete with scroll interaction on dense dashboards).
            if let onRefresh {
                ScrollView { contentStack }
                    .refreshable { await onRefresh() }
            } else {
                ScrollView { contentStack }
            }
        }
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            ScreenHeader(eyebrow: eyebrow, title: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.x5)
        .padding(.top, topPadding)
        .padding(.bottom, Space.x10)
    }
}

/// Screen-level heading: monospaced Volt eyebrow + Archivo display title.
struct ScreenHeader: View {
    let eyebrow: String?
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            if let eyebrow {
                // Wrap via LocalizedStringKey so literal eyebrow strings
                // flow through the Localizable catalog. Callers that pass
                // pre-localized dynamic strings (e.g. from
                // String.localizedStringWithFormat) will fall through the
                // lookup and render verbatim.
                Text(LocalizedStringKey(eyebrow)).tsEyebrow()
            }
            Text(LocalizedStringKey(title))
                .tsH1()
                .foregroundStyle(Color.textPrimary)
        }
    }
}

// MARK: - SheetHeader

/// Top bar for modal sheets — leading close/cancel, centered title,
/// trailing confirm action. Matches the rest of the system instead of the
/// stock navigation bar.
struct SheetHeader: View {
    let title: String
    var onCancel: (() -> Void)? = nil
    var confirmLabel: String? = nil
    var confirmDisabled: Bool = false
    var onConfirm: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center) {
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(Color.appSurface2, in: Circle())
                        .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel"))
            } else {
                Color.clear.frame(width: 36, height: 36)
            }

            Spacer()

            Text(LocalizedStringKey(title))
                .font(AppFont.ui(15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)

            Spacer()

            if let confirmLabel, let onConfirm {
                Button(action: onConfirm) {
                    Text(LocalizedStringKey(confirmLabel))
                        .font(AppFont.ui(13, weight: .bold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.04))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            confirmDisabled ? Color.appSurface2 : Color.accentVolt,
                            in: .rect(cornerRadius: 10)
                        )
                        .opacity(confirmDisabled ? 0.6 : 1)
                }
                .buttonStyle(.plain)
                .disabled(confirmDisabled)
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, Space.x4)
        .padding(.top, Space.x3)
        .padding(.bottom, Space.x2)
    }
}

// MARK: - AppSection

/// A labeled section of content: small eyebrow header followed by a card
/// containing the caller-supplied content.
struct AppSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(title)).tsEyebrow().foregroundStyle(Color.textTertiary)
                Spacer()
                if let trailing { trailing }
            }
            VStack(alignment: .leading, spacing: Space.x3) {
                content()
            }
            .appCard()
        }
    }
}

// MARK: - LabeledRow

/// A single form-style row inside an AppCard.
///
/// Use this for key/value pairs (e.g. "Start date … [May 14, 2026]") so every
/// settings screen has consistent alignment + type weights.
struct LabeledRow<Trailing: View>: View {
    let label: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Space.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(label))
                    .font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(AppFont.ui(12, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
            }
            Spacer(minLength: Space.x3)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SliderRow

/// Design-system slider: title, live value read-out, and a Volt-tinted
/// slider. Used for the sigmoid parameters on Settings.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var format: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(0))

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(AppFont.ui(14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("\(value, format: format)\(unit.isEmpty ? "" : " \(unit)")")
                    .font(AppFont.mono(12, weight: .medium))
                    .foregroundStyle(Color.accentInk)
            }
            Slider(value: $value, in: range, step: step)
                .tint(.accentVolt)
        }
    }
}

// MARK: - AppToggleRow

/// Row with a label on the left and a stock `Toggle` on the right,
/// Volt-tinted. Stock Toggle is kept because iOS users expect the native
/// knob behavior; only the tint is themed.
struct AppToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(AppFont.ui(12, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .tint(.accentVolt)
    }
}

// MARK: - Divider

/// Thin border divider used between rows inside an appCard.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.appBorder)
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}
