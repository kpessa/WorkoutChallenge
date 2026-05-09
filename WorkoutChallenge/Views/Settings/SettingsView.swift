//
//  SettingsView.swift
//  WorkoutChallenge
//
//  Port of SettingsModal.svelte + ControlsPanel. Lets the user edit theme,
//  the challenge start date, days/week, and the sigmoid parameters; plus
//  manage workout types, Apple Health integration, and iCloud sync.
//
//  Redesigned to use the ScreenShell + appCard system. Each block is an
//  AppSection with its own eyebrow header. Native controls (DatePicker,
//  Stepper, Slider) are kept for their platform behavior but styled with
//  Volt tint so they match the system. The theme source-of-truth is the
//  SwiftData preferences row (so it syncs via CloudKit).
//

import SwiftUI
import Combine
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var healthKit: HealthKitService
    @EnvironmentObject private var cloudKitStatus: CloudKitStatusService
    @Query private var preferencesList: [UserPreferencesModel]
    @Query private var challenges: [ChallengeModel]

    // Debug-only seed feedback. A small status string the user sees under
    // the "Seed sample workout (debug)" button so it's clear the action ran
    // and a new HKWorkout landed in the Health store.
    #if DEBUG
    @State private var seedStatus: String?
    @State private var seedInFlight = false
    #endif

    private var prefs: UserPreferencesModel? { preferencesList.first }

    /// The active/paused challenge. Only used now by
    /// `importFromHealthKit()` so "Import from Apple Health" anchors its
    /// lookback at day 1 of the live run; the Schedule + Progression-curve
    /// sliders that used to live here moved to `ChallengeEditorView`, which
    /// is pushed from the ChallengeSection cards.
    private var activeChallenge: ChallengeModel? {
        ChallengeService.currentChallenge(in: challenges)
    }

    var body: some View {
        NavigationStack {
            ScreenShell(
                eyebrow: "SETTINGS · DIAL IT IN",
                title: "Your setup."
            ) {
                ChallengeSection()
                if let prefs {
                    appearanceSection(prefs: prefs)
                    MaxHRSection(prefs: prefs)
                }
                workoutTypesSection
                healthKitSection
                CoachSection()
                ReclaimSection()
                VaultSyncSection()
                iCloudSyncSection
                DataExportSection()
                aboutSection
            }
            .toolbar(.hidden, for: .navigationBar)
            .tint(.accentVolt)
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private func appearanceSection(prefs: UserPreferencesModel) -> some View {
        AppSection(title: "Appearance") {
            SegmentedControl(
                items: ThemePreference.allCases.map { (label: $0.label, value: $0) },
                selection: Binding(
                    get: { ThemePreference(rawValue: prefs.themeRaw) ?? .system },
                    set: { prefs.themeRaw = $0.rawValue }
                )
            )
            Text("“System” follows your device's light/dark setting. Syncs via iCloud.")
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: - Workout types

    private var workoutTypesSection: some View {
        AppSection(title: "Workout types") {
            NavigationLink {
                WorkoutTypeManagerView()
            } label: {
                LabeledRow(label: "Manage types") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - HealthKit

    private var healthKitSection: some View {
        AppSection(title: "Apple Health") {
            if healthKit.isAvailable {
                LabeledRow(
                    label: "Access",
                    detail: healthKit.isAuthorized ? "Granted" : "Not requested"
                ) {
                    Image(systemName: healthKit.isAuthorized ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(healthKit.isAuthorized ? Color.accentInk : Color.textTertiary)
                }

                RowDivider()

                VStack(spacing: Space.x2) {
                    SecondaryButton(title: "Request access", icon: "heart.text.square") {
                        Task { await healthKit.requestAuthorization() }
                    }
                    SecondaryButton(title: "Import from Apple Health", icon: "arrow.down.to.line") {
                        Task { await importFromHealthKit() }
                    }

                    #if DEBUG
                    // Debug-only: seeds a fake 30-minute workout with HR /
                    // calories / distance into the local HealthKit store so
                    // Simulator runs can exercise the workout-detail UI
                    // without a real Watch session. Release builds never
                    // compile this block.
                    RowDivider()
                    SecondaryButton(
                        title: seedInFlight ? "Seeding…" : "Seed sample workout (debug)",
                        icon: "testtube.2"
                    ) {
                        Task { await seedDebugWorkout() }
                    }
                    .disabled(seedInFlight)
                    if let seedStatus {
                        Text(seedStatus)
                            .font(AppFont.ui(12, weight: .medium))
                            .foregroundStyle(Color.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    #endif
                }
            } else {
                Text("HealthKit unavailable on this device.")
                    .font(AppFont.ui(13))
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    // MARK: - iCloud

    private var iCloudSyncSection: some View {
        AppSection(title: "iCloud sync") {
            LabeledRow(label: "Status") {
                HStack(spacing: 6) {
                    Image(systemName: statusIconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusIconColor)
                    Text(cloudKitStatus.accountStatus.displayText)
                        .font(AppFont.ui(13, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
            }

            RowDivider()

            LabeledRow(label: "Sync") {
                Text(syncActivityText)
                    .font(AppFont.ui(13, weight: .medium))
                    .foregroundStyle(syncActivityColor)
            }

            if let date = cloudKitStatus.lastSyncDate {
                RowDivider()
                LabeledRow(label: "Last sync") {
                    Text(date, format: .relative(presentation: .named))
                        .font(AppFont.ui(13, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
            }

            RowDivider()

            VStack(spacing: Space.x2) {
                // iOS has no API for apps to sign the user into iCloud
                // directly, so the best we can do is deep-link the Settings
                // app. `openSettingsURLString` is the App Store–safe deep
                // link — it lands on this app's settings page, from which
                // the user can back out and tap their Apple ID.
                if case .noAccount = cloudKitStatus.accountStatus {
                    SecondaryButton(title: "Open iOS Settings", icon: "arrow.up.forward.app") {
                        openIOSSettings()
                    }
                }
                SecondaryButton(title: "Check iCloud status", icon: "arrow.clockwise.icloud") {
                    Task { await cloudKitStatus.refreshAccountStatus() }
                }
            }

            Text(iCloudFooterText)
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(Color.textTertiary)
        }
    }

    /// Open the iOS Settings app. Used by the "Not signed in" action above.
    private func openIOSSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var statusIconName: String {
        switch cloudKitStatus.accountStatus {
        case .available:               return "checkmark.icloud.fill"
        case .noAccount:               return "xmark.icloud"
        case .restricted,
             .temporarilyUnavailable,
             .couldNotDetermine:       return "exclamationmark.icloud"
        case .unknown:                 return "icloud"
        }
    }

    private var statusIconColor: Color {
        switch cloudKitStatus.accountStatus {
        case .available:               return Color.accentInk
        case .noAccount:               return Color.danger
        case .restricted,
             .temporarilyUnavailable,
             .couldNotDetermine:       return Color.warn
        case .unknown:                 return Color.textTertiary
        }
    }

    private var syncActivityText: String {
        switch cloudKitStatus.syncActivity {
        case .idle:
            return cloudKitStatus.lastSyncDate == nil
                ? String(localized: "Waiting", comment: "Sync-activity label before first sync")
                : String(localized: "Up to date", comment: "Sync-activity label when idle")
        case .syncing:
            return String(localized: "Syncing…", comment: "Sync-activity label in progress")
        case .failed:
            return String(localized: "Failed", comment: "Sync-activity label failed")
        }
    }

    private var syncActivityColor: Color {
        switch cloudKitStatus.syncActivity {
        case .idle:        return Color.textSecondary
        case .syncing:     return Color.accentInk
        case .failed:      return Color.danger
        }
    }

    private var iCloudFooterText: String {
        if case .failed(let message) = cloudKitStatus.syncActivity {
            return String.localizedStringWithFormat(
                NSLocalizedString("Last sync failed: %@",
                                   comment: "iCloud footer when last sync errored"),
                message)
        }
        return cloudKitStatus.accountStatus.detailText
            ?? String(localized: "Your workouts sync to iCloud when you're signed in.",
                      comment: "Fallback iCloud footer")
    }

    // MARK: - About

    private var aboutSection: some View {
        AppSection(title: "About") {
            Text("A sigmoidal 90-day progression for steady workout growth.")
                .font(AppFont.ui(13))
                .foregroundStyle(Color.textSecondary)
        }
    }

    // MARK: - Actions

    private func importFromHealthKit() async {
        // Prefer the active challenge's start so "Import from Apple Health"
        // on an in-progress challenge pulls from day 1 of *this* run
        // rather than wherever prefs happens to sit. Falls back to prefs
        // between challenges.
        let start = activeChallenge?.startDate ?? prefs?.startDate
        guard let start else { return }
        // Explicit user tap — always re-auth if we haven't yet this run,
        // and pass `minInterval: nil` so the import is never short-
        // circuited by the foreground-sync cooldown. This keeps "I tapped
        // the button" semantically equivalent to "force a fresh pull."
        if !healthKit.isAuthorized {
            await healthKit.requestAuthorization()
        }
        await healthKit.importSinceChallengeStart(
            from: start,
            into: modelContext,
            minInterval: nil
        )
    }

    #if DEBUG
    /// Fire the debug seed, then re-import so the new HKWorkout lands as a
    /// `WorkoutModel` the user can tap on and see the enriched detail view.
    private func seedDebugWorkout() async {
        seedInFlight = true
        seedStatus = nil
        defer { seedInFlight = false }

        let uuid = await healthKit.seedDebugWorkout()
        guard uuid != nil else {
            seedStatus = healthKit.lastError ?? "Seed failed."
            return
        }

        // Import so it shows up in the app immediately. 7-day window is
        // fine — the seed ended minutes ago.
        let since = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        await healthKit.importWorkouts(from: since, into: modelContext)
        seedStatus = "Seeded 30-min sample workout with HR series."
    }
    #endif
}

#Preview {
    SettingsView()
        .modelContainer(try! Persistence.makePreviewContainer())
        .environmentObject(HealthKitService())
        .environmentObject(CloudKitStatusService())
}
