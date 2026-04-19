//
//  RootView.swift
//  WorkoutChallenge
//
//  Top-level tab container. The webapp had a single page with sections; on
//  iOS we split those sections into separate tabs to feel native. The tabs
//  themselves render without stock navigation bars — each screen uses the
//  design-system ScreenShell (eyebrow + H1 heading on an OLED-black field).
//

import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext

    // Load user preferences. We expect exactly one preferences row.
    @Query private var preferences: [UserPreferencesModel]

    // Shadow copy of the theme preference in UserDefaults. The source of
    // truth is `preferences.first?.themeRaw` (so the theme syncs via
    // CloudKit), but `WorkoutChallengeApp.preferredColorScheme` reads
    // @AppStorage so we can apply a theme at cold launch — before the
    // SwiftData container has produced any rows. We mirror model →
    // UserDefaults here whenever the SwiftData value changes (either from
    // a local edit or a CloudKit import), and on first launch seed the
    // model from UserDefaults so existing installs keep their pick.
    @AppStorage(ThemePreference.storageKey) private var themeRaw: String = ThemePreference.system.rawValue

    /// Configure the UIKit tab-bar appearance once per process so it picks
    /// up the design-system palette. Navigation bars are no longer used in
    /// the top-level tabs (each screen paints its own header), so the nav
    /// bar proxy wiring that used to live here has been removed.
    init() { Self.configureAppearance() }

    var body: some View {
        TabView {
            ProgressBarsView()
                .tabItem { Label("Bars", systemImage: "chart.bar.xaxis") }

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }

            ProgressChartView()
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }

            AnalyticsView()
                .tabItem { Label("Analytics", systemImage: "chart.bar.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.accentVolt)
        .onAppear(perform: ensureDefaults)
        // Mirror the SwiftData theme value into @AppStorage whenever it
        // changes — this covers both user edits in SettingsView and theme
        // changes that arrive via CloudKit sync from another device.
        .onChange(of: preferences.first?.themeRaw) { _, newValue in
            if let newValue, newValue != themeRaw {
                themeRaw = newValue
            }
        }
    }

    /// First-run setup: create a default preferences row and a default
    /// workout type if the database is empty.
    private func ensureDefaults() {
        if preferences.isEmpty {
            let defaults = UserPreferencesModel.makeDefault()
            // Carry the existing UserDefaults theme into the new model so
            // users who set a theme before this migration don't lose it.
            defaults.themeRaw = themeRaw
            modelContext.insert(defaults)
        } else if let prefs = preferences.first, prefs.themeRaw != themeRaw {
            // Preferences loaded — align @AppStorage with the model's value
            // (e.g. the model was updated on another device via iCloud).
            themeRaw = prefs.themeRaw
        }

        let typeFetch = FetchDescriptor<WorkoutTypeModel>()
        if let existing = try? modelContext.fetch(typeFetch), existing.isEmpty {
            let defaultType = WorkoutTypeModel(name: "Exercise", colorHex: "#4CAF50")
            modelContext.insert(defaultType)
        }
    }

    // MARK: - Appearance

    /// Wire the design-system tokens into UIKit's tab-bar appearance proxy.
    /// SwiftUI's `.tabViewStyle` doesn't reach every corner (unselected
    /// tint, scroll-edge appearance, separator color), so we do it here.
    private static func configureAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Color.appSurface)
        tab.shadowColor = UIColor(Color.appBorder)

        for item in [tab.stackedLayoutAppearance,
                     tab.inlineLayoutAppearance,
                     tab.compactInlineLayoutAppearance] {
            item.selected.iconColor = UIColor(Color.accentVolt)
            item.selected.titleTextAttributes = [
                .foregroundColor: UIColor(Color.accentVolt),
                .font: UIFont(name: "Inter-SemiBold", size: 10)
                    ?? UIFont.systemFont(ofSize: 10, weight: .semibold)
            ]
            item.normal.iconColor = UIColor(Color.textSecondary)
            item.normal.titleTextAttributes = [
                .foregroundColor: UIColor(Color.textSecondary),
                .font: UIFont(name: "Inter-Medium", size: 10)
                    ?? UIFont.systemFont(ofSize: 10, weight: .medium)
            ]
        }

        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        // The Settings tab still uses a NavigationStack (to push the
        // workout-type manager). Hide its nav bar background so the
        // screen-shell eyebrow/title reads as the page heading.
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = .clear
        nav.shadowColor = .clear
        nav.titleTextAttributes = [
            .foregroundColor: UIColor(Color.textPrimary),
            .font: UIFont(name: "Inter-Bold", size: 17)
                ?? UIFont.systemFont(ofSize: 17, weight: .bold)
        ]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}

#Preview {
    RootView()
        .modelContainer(try! Persistence.makePreviewContainer())
        .environmentObject(HealthKitService())
        .environmentObject(CloudKitStatusService())
}
