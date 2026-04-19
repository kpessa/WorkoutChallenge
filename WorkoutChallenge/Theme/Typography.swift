//
//  Typography.swift
//  WorkoutChallenge
//
//  Design-system type scale.
//
//  Custom font families (Archivo Black, Inter, JetBrains Mono) are bundled
//  under WorkoutChallenge/Fonts/ and registered via `UIAppFonts` in Info.plist.
//  If a specific weight isn't registered yet, `AppFont` falls back to the
//  iOS system font — text styles still render, just without the designed
//  typeface. This keeps the app runnable before every TTF has been dropped
//  into the target.
//

import SwiftUI
import UIKit

// MARK: - Font registration check

private enum FontRegistry {
    /// Cache of `PostScript name → isRegistered?` so we only hit UIKit once.
    /// A missing font causes SwiftUI's `.custom(_:size:)` to silently fall
    /// back to the system font, but that fallback is ugly at display sizes,
    /// so we detect missing fonts here and substitute a designed system
    /// font instead.
    private static var cache: [String: Bool] = [:]

    static func isAvailable(_ name: String) -> Bool {
        if let cached = cache[name] { return cached }
        let available = UIFont(name: name, size: 12) != nil
        cache[name] = available
        return available
    }
}

// MARK: - AppFont

enum AppFont {
    /// Display face — Archivo Black. Falls back to system `.heavy` rounded
    /// design when the custom font isn't bundled, which keeps display copy
    /// bold and condensed-looking.
    ///
    /// The PostScript name is `ArchivoBlack-Regular` (not `Archivo-Black` —
    /// the handoff spec had the name wrong). Verified with fontTools against
    /// the TTF shipped under `WorkoutChallenge/Fonts/`.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        let name = "ArchivoBlack-Regular"
        if FontRegistry.isAvailable(name) {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .heavy, design: .default)
    }

    /// UI sans face — Inter. Falls back to the system font at the requested
    /// weight.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Inter-Bold"
        case .semibold:              name = "Inter-SemiBold"
        case .medium:                name = "Inter-Medium"
        default:                     name = "Inter-Regular"
        }
        if FontRegistry.isAvailable(name) {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight)
    }

    /// Mono face — JetBrains Mono. Falls back to the system monospaced
    /// font at the requested weight.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        let name = weight == .bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Medium"
        if FontRegistry.isAvailable(name) {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Text styles

extension View {
    /// Hero display copy (e.g. "Ninety days.").
    func tsDisplay()   -> some View { self.font(AppFont.display(64)).tracking(-1.5) }
    /// Primary headline (e.g. screen titles).
    func tsH1()        -> some View { self.font(AppFont.display(40)).tracking(-1) }
    /// Secondary headline (e.g. section openers).
    func tsH2()        -> some View { self.font(AppFont.display(28)).tracking(-0.6) }
    /// Tertiary headline (e.g. card titles).
    func tsH3()        -> some View { self.font(AppFont.ui(22, weight: .bold)).tracking(-0.2) }
    /// Body copy.
    func tsBody()      -> some View { self.font(AppFont.ui(16)).foregroundStyle(Color.textSecondary) }
    /// Caption / small meta copy.
    func tsCaption()   -> some View { self.font(AppFont.ui(13, weight: .medium)).foregroundStyle(Color.textSecondary) }
    /// Eyebrow labels — monospaced, uppercase, accent-tinted.
    /// Uses `accentInk` (a darkened sibling of Volt) so the label hits
    /// WCAG AA against light surfaces. Collapses back to full Volt in dark
    /// mode.
    func tsEyebrow()   -> some View { self.font(AppFont.mono(11)).tracking(1.5).textCase(.uppercase).foregroundStyle(Color.accentInk) }
    /// Big numeric stat (e.g. "Day 54", streaks).
    func tsStat()      -> some View { self.font(AppFont.display(56)).monospacedDigit().tracking(-1.5) }
}
