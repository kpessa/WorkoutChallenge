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

    // Drives the foreground auto-sync hook — we kick off a HealthKit
    // re-import whenever the app transitions to `.active` (i.e. the user
    // foregrounded it after working out). Combined with a `.task` at
    // mount time to cover cold launches, this is the "automatic sync"
    // pathway that removes the old need to drop into Settings → Import.
    @Environment(\.scenePhase) private var scenePhase

    // Injected at the App level (see WorkoutChallengeApp). We don't
    // construct a fresh HealthKitService here — the shared instance owns
    // auth state, the in-flight import guard, and the opt-in flag.
    @EnvironmentObject private var healthKit: HealthKitService

    // Load user preferences. We expect exactly one preferences row.
    @Query private var preferences: [UserPreferencesModel]

    // All challenges (active, paused, and history). Used to seed a
    // Phase-2 `ChallengeModel` from the existing prefs on first launch.
    @Query private var challenges: [ChallengeModel]

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
        // Use `accentInk` (not `accentVolt`) for the tab-bar tint — SwiftUI's
        // `.tint` drives the selected icon/label color, and Volt at ~1.07:1
        // on light Surface fails WCAG. accentInk darkens in light mode and
        // collapses to full Volt in dark mode.
        .tint(.accentInk)
        .onAppear(perform: ensureDefaults)
        // Mirror the SwiftData theme value into @AppStorage whenever it
        // changes — this covers both user edits in SettingsView and theme
        // changes that arrive via CloudKit sync from another device.
        .onChange(of: preferences.first?.themeRaw) { _, newValue in
            if let newValue, newValue != themeRaw {
                themeRaw = newValue
            }
        }
        // Foreground auto-sync from Apple Health. Runs on cold launch
        // (via .task) and every subsequent transition back to .active.
        // Gated internally on `userHasOptedIn` so fresh installs won't
        // quietly probe HealthKit — the user must tap through Settings →
        // Apple Health → Request access once before this does anything.
        // A 60-second cooldown suppresses redundant imports when the user
        // briefly toggles to another app and back (common iOS flow).
        .task {
            await autoImportFromHealth(minInterval: nil)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await autoImportFromHealth(minInterval: 60) }
        }
    }

    /// Resolve the challenge start date (falling back to 90 days ago for
    /// safety in the unlikely case prefs hasn't been seeded yet) and
    /// delegate to the shared HealthKit import helper. Intentionally thin —
    /// all the gating (availability, opt-in, in-flight guard, silent
    /// re-auth) lives inside `HealthKitService` so this call site and the
    /// Bars pull-to-refresh + Settings button all follow the same rules.
    private func autoImportFromHealth(minInterval: TimeInterval?) async {
        let start = preferences.first?.startDate
            ?? Calendar.current.date(byAdding: .day, value: -90, to: Date())
            ?? Date.distantPast
        await healthKit.importSinceChallengeStart(
            from: start,
            into: modelContext,
            minInterval: minInterval
        )
    }

    /// First-run setup: create a default preferences row and a default
    /// workout type if the database is empty. Also runs a one-shot dedupe
    /// pass so duplicate workout types (e.g. the four "Exercise" rows seeded
    /// by successive pre-CloudKit-sync launches) are collapsed into one —
    /// see `dedupeWorkoutTypes()`.
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

        dedupeWorkoutTypes()
        dedupeWorkouts()

        let typeFetch = FetchDescriptor<WorkoutTypeModel>()
        if let existing = try? modelContext.fetch(typeFetch), existing.isEmpty {
            let defaultType = WorkoutTypeModel(name: "Exercise", colorHex: "#4CAF50")
            modelContext.insert(defaultType)
        }

        // Phase 2 migration: seed a ChallengeModel from existing prefs on
        // first launch. Safe to call every launch — no-ops when any row
        // already exists.
        ChallengeService.migrateFromPrefsIfNeeded(
            context: modelContext,
            prefs: preferences.first,
            challenges: challenges
        )
    }

    /// Collapse workout types that share a (case-insensitive, whitespace-
    /// trimmed) name into a single canonical record. The oldest row wins so
    /// its identity survives — any workouts tagged with the losers are
    /// re-pointed at the winner, then the loser rows are deleted.
    ///
    /// This runs on every cold launch but no-ops when nothing is duplicated,
    /// so it's cheap. It exists because the prior seed logic could insert
    /// multiple "Exercise" rows when several pre-CloudKit-sync launches each
    /// observed an empty fetch result; CloudKit then faithfully replicated
    /// the duplicates across devices.
    private func dedupeWorkoutTypes() {
        let fetch = FetchDescriptor<WorkoutTypeModel>()
        guard let all = try? modelContext.fetch(fetch), all.count > 1 else { return }

        // Group by canonical name (trimmed + case-insensitive).
        var groups: [String: [WorkoutTypeModel]] = [:]
        for t in all {
            let key = t.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            groups[key, default: []].append(t)
        }

        // Fetch once — we may need to re-point workouts across several groups.
        let workoutFetch = FetchDescriptor<WorkoutModel>()
        let allWorkouts = (try? modelContext.fetch(workoutFetch)) ?? []

        var didChange = false

        for (_, members) in groups where members.count > 1 {
            // Oldest wins — matches "this is the original, everything else
            // is a duplicate" intuition and keeps any relationships intact.
            let sorted = members.sorted { $0.createdAt < $1.createdAt }
            guard let keeper = sorted.first else { continue }
            let losers = Array(sorted.dropFirst())
            let loserIDs = Set(losers.map(\.id))

            for w in allWorkouts {
                if let t = w.workoutType, loserIDs.contains(t.id) {
                    w.workoutType = keeper
                }
            }

            for loser in losers {
                modelContext.delete(loser)
            }
            didChange = true
        }

        // SwiftData autosaves on context teardown, but an explicit save here
        // makes the dedupe immediately visible to the @Query that drives the
        // chips in LogWorkoutSheet on this run.
        if didChange {
            try? modelContext.save()
        }
    }

    /// Collapse workout rows that represent the same underlying session.
    /// Two rows are treated as the same workout when their `(startOfMinute,
    /// duration)` tuples match — the same test the import path now uses
    /// to prevent new duplicates from being created.
    ///
    /// This is a one-shot cleanup for stores that accumulated duplicates
    /// before the stronger import dedupe landed (e.g. Kurt's "I tagged a
    /// workout Rollerblade and the un-typed version came back on next
    /// import" report). No-op on stores that don't have duplicates, so
    /// it's safe to run every launch alongside `dedupeWorkoutTypes()`.
    ///
    /// Keeper-selection policy (stable, deterministic):
    ///   1. Prefer a row with an assigned `workoutType` — the user's
    ///      tag is the valuable human edit we must not lose.
    ///   2. Then prefer a row that has a `healthKitUUID` — so the
    ///      kept row stays wired to Apple Health for round-trips.
    ///   3. Then earliest `createdAt` — matches the same "original
    ///      wins" intuition used by `dedupeWorkoutTypes()`.
    ///
    /// Surviving row inherits any useful fields missing on the keeper
    /// (HK uuid, snapshot) from a loser — so we never drop the HK link
    /// while merging.
    private func dedupeWorkouts() {
        let fetch = FetchDescriptor<WorkoutModel>()
        guard let all = try? modelContext.fetch(fetch), all.count > 1 else { return }

        struct Key: Hashable { let minute: Date; let minutes: Int }
        var groups: [Key: [WorkoutModel]] = [:]
        for w in all {
            let key = Key(minute: w.date.truncatedToMinute, minutes: w.duration)
            groups[key, default: []].append(w)
        }

        var didChange = false

        for (_, members) in groups where members.count > 1 {
            // Sort by keeper-desirability — best candidate first.
            let sorted = members.sorted { a, b in
                let aTyped = a.workoutType != nil
                let bTyped = b.workoutType != nil
                if aTyped != bTyped { return aTyped && !bTyped }
                let aHK = a.healthKitUUID != nil
                let bHK = b.healthKitUUID != nil
                if aHK != bHK { return aHK && !bHK }
                return a.createdAt < b.createdAt
            }
            guard let keeper = sorted.first else { continue }
            let losers = Array(sorted.dropFirst())

            // Inherit HK linkage from a loser when the keeper doesn't
            // have one yet — don't sever the round-trip by accident.
            if keeper.healthKitUUID == nil,
               let donor = losers.first(where: { $0.healthKitUUID != nil }) {
                keeper.healthKitUUID = donor.healthKitUUID
                if keeper.hkImportedDate == nil {
                    keeper.hkImportedDate = donor.hkImportedDate ?? donor.date
                    keeper.hkImportedDuration = donor.hkImportedDuration ?? donor.duration
                }
            }

            for loser in losers {
                modelContext.delete(loser)
            }
            didChange = true
        }

        if didChange {
            try? modelContext.save()
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

        // Selected state uses `accentInk` (not raw `accentVolt`) because
        // Volt at ~1.07:1 on the light Surface fails WCAG as a foreground.
        // accentInk is the dark-on-light sibling and collapses back to full
        // Volt in dark mode, so the tab bar reads crisply in both themes.
        for item in [tab.stackedLayoutAppearance,
                     tab.inlineLayoutAppearance,
                     tab.compactInlineLayoutAppearance] {
            item.selected.iconColor = UIColor(Color.accentInk)
            item.selected.titleTextAttributes = [
                .foregroundColor: UIColor(Color.accentInk),
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

        // Slider unfilled track bumped to Surface3 (vs. the system default
        // ~Surface2) so the Volt filled portion has real contrast against
        // the remaining track on light mode. Dark mode: Surface3 resolves
        // to a near-black surface, which reads fine against Volt.
        UISlider.appearance().maximumTrackTintColor = UIColor(Color.appSurface3)

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
