//
//  ThemePreference.swift
//  WorkoutChallenge
//
//  User-selectable appearance mode. The source of truth is
//  `UserPreferencesModel.themeRaw` (so the preference syncs via CloudKit),
//  but it is also mirrored into @AppStorage via `RootView` so the App-level
//  `preferredColorScheme` can apply the theme at cold launch — before the
//  SwiftData container has produced any rows.
//
//  Scope note: `ColorScheme` returned here is consumed by SwiftUI's
//  `.preferredColorScheme(_:)`, which only affects this app's windows. It
//  does NOT change the device's system-wide Light/Dark setting.
//

import SwiftUI

enum ThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// Key used with @AppStorage. Exposed here so both the app root and the
    /// settings view stay in sync without magic strings.
    static let storageKey = "themePreference"

    var label: String {
        switch self {
        case .system: return String(localized: "System", comment: "ThemePreference label")
        case .light:  return String(localized: "Light", comment: "ThemePreference label")
        case .dark:   return String(localized: "Dark", comment: "ThemePreference label")
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// The value passed to `.preferredColorScheme`. `nil` means "follow the
    /// system setting," which is SwiftUI's default behavior.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
