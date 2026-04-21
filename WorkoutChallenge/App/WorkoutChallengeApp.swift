//
//  WorkoutChallengeApp.swift
//  WorkoutChallenge
//
//  App entry point. Wires up the SwiftData model container (CloudKit-synced)
//  and injects shared environment objects.
//

import SwiftUI
import SwiftData

@main
struct WorkoutChallengeApp: App {

    // Shared HealthKit service, injected via environment so any view can use it.
    @StateObject private var healthKit = HealthKitService()

    // Observes the user's iCloud account state + SwiftData CloudKit sync
    // events. Used by SettingsView to show an "iCloud Sync" status row.
    @StateObject private var cloudKitStatus = CloudKitStatusService()

    // Appearance preference. Backed by UserDefaults so the choice survives
    // app restarts. Default is `.system` — follow whatever the device is set to.
    @AppStorage(ThemePreference.storageKey) private var themeRaw: String = ThemePreference.system.rawValue

    /// First-run gate. Onboarding writes this to `true` on its final screen
    /// and we flip back to `RootView`. Defaulting to `false` means existing
    /// installs (pre-onboarding-feature) will also run onboarding once on
    /// their next launch — acceptable because it seeds model state our
    /// science-backed flow assumes (activities, cadence, pledge).
    @AppStorage(OnboardingKey.completed) private var onboardingCompleted: Bool = false

    private var theme: ThemePreference {
        ThemePreference(rawValue: themeRaw) ?? .system
    }

    // SwiftData container holding all @Model types. CloudKit sync is configured
    // per-schema; see Persistence.swift for the container setup.
    let modelContainer: ModelContainer = {
        do {
            return try Persistence.makeContainer()
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingCompleted {
                    RootView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(healthKit)
            .environmentObject(cloudKitStatus)
            .preferredColorScheme(theme.colorScheme)
        }
        .modelContainer(modelContainer)
    }
}
