//
//  WorkoutChallengeApp.swift
//  WorkoutChallenge
//
//  App entry point. Wires up the SwiftData model container (CloudKit-synced)
//  and injects shared environment objects.
//

import SwiftUI
import Combine
import SwiftData

@main
struct WorkoutChallengeApp: App {

    // Shared HealthKit service, injected via environment so any view can use it.
    @StateObject private var healthKit = HealthKitService()

    // Observes the user's iCloud account state + SwiftData CloudKit sync
    // events. Used by SettingsView to show an "iCloud Sync" status row.
    @StateObject private var cloudKitStatus = CloudKitStatusService()

    // Drives the confetti + success haptic that fires the first time a
    // given day's logged minutes cross the sigmoid target. Lives at the
    // app level so the overlay can paint over whichever tab is active
    // when the threshold is crossed — including a freshly-dismissed
    // LogWorkoutSheet. See `CelebrationService.swift`.
    @StateObject private var celebration = CelebrationService()

    // Appearance preference. Backed by UserDefaults so the choice survives
    // app restarts. Default is `.system` — follow whatever the device is set to.
    @AppStorage(ThemePreference.storageKey) private var themeRaw: String = ThemePreference.system.rawValue

    /// First-run gate. Onboarding writes this to `true` on its final screen
    /// and we flip back to `RootView`. Defaulting to `false` means existing
    /// installs (pre-onboarding-feature) will also run onboarding once on
    /// their next launch — acceptable because it seeds model state our
    /// science-backed flow assumes (activities, cadence, pledge).
    @AppStorage(OnboardingKey.completed) private var onboardingCompleted: Bool = false

    // Outbound HealthKit → LLM Vault sync. Initialized after healthKit so
    // it can take a reference. StateObject wrapper requires wrappedValue init.
    @StateObject private var vaultSync: HealthKitSyncService

    init() {
        // Manually init vaultSync since it depends on healthKit.
        // SwiftUI initializes @StateObject wrappers in declaration order,
        // but we need healthKit's instance first.
        let hk = HealthKitService()
        _healthKit = StateObject(wrappedValue: hk)
        _cloudKitStatus = StateObject(wrappedValue: CloudKitStatusService())
        _celebration = StateObject(wrappedValue: CelebrationService())
        _vaultSync = StateObject(wrappedValue: HealthKitSyncService(healthKit: hk))
    }

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
            .environmentObject(celebration)
            .environmentObject(vaultSync)
            .preferredColorScheme(theme.colorScheme)
        }
        .modelContainer(modelContainer)
    }
}
