//
//  Tokens.swift
//  WorkoutChallenge
//
//  Design-system tokens: color palette, spacing, radii, and motion curves.
//  Colors map to asset-catalog entries under Assets.xcassets/Colors/.
//
//  See docs/DESIGN_SYSTEM.md for the source of truth (ported from the
//  ios-handoff package delivered 2026-04-19).
//

import SwiftUI

// MARK: - Color tokens (map to Colors.xcassets)
extension Color {
    // Accents
    static let accentVolt     = Color("Colors/AccentVolt")
    static let accentNeon     = Color("Colors/AccentNeon")
    /// Darkened sibling of Volt for use as a *foreground* on light surfaces —
    /// eyebrow labels, small accent text, small status icons. In dark mode
    /// this collapses back to full Volt. Use Volt (not Ink) for fills,
    /// buttons, chart areas, and any element where dark text sits on top.
    static let accentInk      = Color("Colors/AccentInk")
    /// Mid-darkened Volt (#8FB300 on light, full Volt on dark). Sits between
    /// `accentVolt` and `accentInk`: lighter than Ink (so it still reads as
    /// Volt family) but dark enough to give chart fills and outlines ~4:1
    /// edge contrast on the chalk background. Use for:
    ///   - Bar-chart / area fills that have no ink text over them
    ///   - 1.5px outlines on Volt fills that need stronger edge definition
    /// Do NOT use for small body text — fails 4.5:1 on Surface. Use accentInk
    /// there instead.
    static let accentVoltInk  = Color("Colors/AccentVoltInk")
    // Surfaces
    static let appBg          = Color("Colors/Bg")
    static let appSurface     = Color("Colors/Surface")
    static let appSurface2    = Color("Colors/Surface2")
    static let appSurface3    = Color("Colors/Surface3")
    static let appBorder      = Color("Colors/Border")
    // Text
    static let textPrimary    = Color("Colors/TextPrimary")
    static let textSecondary  = Color("Colors/TextSecondary")
    static let textTertiary   = Color("Colors/TextTertiary")
    // Data (six activity categories)
    static let dataPickleball = Color("Colors/DataPickleball")
    static let dataRoller     = Color("Colors/DataRoller")
    static let dataPadel      = Color("Colors/DataPadel")
    static let dataSpeed      = Color("Colors/DataSpeed")
    static let dataTennis     = Color("Colors/DataTennis")
    static let dataTreadmill  = Color("Colors/DataTreadmill")
    // Semantic
    static let danger         = Color("Colors/Danger")
    static let warn           = Color("Colors/Warn")
}

// MARK: - ShapeStyle shorthand
//
// Mirrors the Color tokens onto `ShapeStyle` so the dot-shorthand works
// with `foregroundStyle`, `fill`, `background`, etc. — e.g.:
//
//     Text("Hi").foregroundStyle(.textPrimary)
//     Circle().fill(.accentVolt)
//
// Without this, `foregroundStyle(_:)` looks up `.textPrimary` on the
// `ShapeStyle` protocol (where it doesn't exist) and fails to compile,
// even though `Color.textPrimary` is defined above. `foregroundColor(_:)`
// doesn't have this problem because it's typed as `Color?`.
extension ShapeStyle where Self == Color {
    // Accents
    static var accentVolt: Color     { .accentVolt }
    static var accentNeon: Color     { .accentNeon }
    static var accentInk: Color      { .accentInk }
    static var accentVoltInk: Color  { .accentVoltInk }
    // Surfaces
    static var appBg: Color          { .appBg }
    static var appSurface: Color     { .appSurface }
    static var appSurface2: Color    { .appSurface2 }
    static var appSurface3: Color    { .appSurface3 }
    static var appBorder: Color      { .appBorder }
    // Text
    static var textPrimary: Color    { .textPrimary }
    static var textSecondary: Color  { .textSecondary }
    static var textTertiary: Color   { .textTertiary }
    // Data
    static var dataPickleball: Color { .dataPickleball }
    static var dataRoller: Color     { .dataRoller }
    static var dataPadel: Color      { .dataPadel }
    static var dataSpeed: Color      { .dataSpeed }
    static var dataTennis: Color     { .dataTennis }
    static var dataTreadmill: Color  { .dataTreadmill }
    // Semantic
    static var danger: Color         { .danger }
    static var warn: Color           { .warn }
}

// MARK: - Spacing (4pt grid)
enum Space {
    static let x1: CGFloat = 4
    static let x2: CGFloat = 8
    static let x3: CGFloat = 12
    static let x4: CGFloat = 16
    static let x5: CGFloat = 20
    static let x6: CGFloat = 24
    static let x8: CGFloat = 32
    static let x10: CGFloat = 40
    static let x14: CGFloat = 56
    static let x18: CGFloat = 72
}

// MARK: - Radius
enum Radius {
    static let ctrl: CGFloat   = 6
    static let input: CGFloat  = 10
    static let button: CGFloat = 14
    static let card: CGFloat   = 20
    static let modal: CGFloat  = 28
    static let pill: CGFloat   = 999
}

// MARK: - Motion
enum Motion {
    static let fast  = Animation.easeOut(duration: 0.14)
    static let base  = Animation.easeOut(duration: 0.22)
    static let slow  = Animation.spring(response: 0.36, dampingFraction: 0.9)
    static let celebration = Animation.spring(response: 0.9, dampingFraction: 0.6)
}
