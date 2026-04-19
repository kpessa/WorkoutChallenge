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
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var healthKit: HealthKitService
    @EnvironmentObject private var cloudKitStatus: CloudKitStatusService
    @Query private var preferencesList: [UserPreferencesModel]

    @State private var showResetConfirm = false

    private var prefs: UserPreferencesModel? { preferencesList.first }

    var body: some View {
        NavigationStack {
            ScreenShell(
                eyebrow: "SETTINGS · DIAL IT IN",
                title: "Your setup."
            ) {
                if let prefs {
                    appearanceSection(prefs: prefs)
                    scheduleSection(prefs: prefs)
                    curveSection(prefs: prefs)
                }
                workoutTypesSection
                healthKitSection
                iCloudSyncSection
                aboutSection
            }
            .toolbar(.hidden, for: .navigationBar)
            .tint(.accentVolt)
            .confirmationDialog(
                "Reset to defaults?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive, action: resetDefaults)
                Button("Cancel", role: .cancel) { }
            }
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

    // MARK: - Schedule

    @ViewBuilder
    private func scheduleSection(prefs: UserPreferencesModel) -> some View {
        AppSection(title: "Schedule") {
            LabeledRow(label: "Start date") {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { prefs.startDate },
                        set: { prefs.startDate = $0 }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                .tint(.accentVolt)
            }

            RowDivider()

            LabeledRow(
                label: "Days per week",
                detail: "\(prefs.daysPerWeek) day\(prefs.daysPerWeek == 1 ? "" : "s")"
            ) {
                Stepper(
                    "",
                    value: Binding(
                        get: { prefs.daysPerWeek },
                        set: { prefs.daysPerWeek = max(1, min(7, $0)) }
                    ),
                    in: 1...7
                )
                .labelsHidden()
                .tint(.accentVolt)
            }

            RowDivider()

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("Week starts on")
                    .font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                SegmentedControl(
                    items: [(label: "Sunday", value: 1), (label: "Monday", value: 2)],
                    selection: Binding(
                        get: { prefs.firstWeekday },
                        set: { prefs.firstWeekday = $0 }
                    )
                )
            }
        }
    }

    // MARK: - Curve

    @ViewBuilder
    private func curveSection(prefs: UserPreferencesModel) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack {
                Text("Progression curve").tsEyebrow().foregroundStyle(Color.textTertiary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: Space.x4) {
                // Hero sigmoid preview — no milestones since these sliders
                // aren't tied to a specific "today".
                SigmoidCurve(progress: 0.6, showMilestones: false)
                    .frame(height: 80)

                SliderRow(
                    title: "Min duration",
                    value: Binding(
                        get: { prefs.sigmoid.minDuration },
                        set: { prefs.sigmoid.minDuration = $0 }
                    ),
                    range: 5...120, step: 5, unit: "min"
                )
                SliderRow(
                    title: "Max duration",
                    value: Binding(
                        get: { prefs.sigmoid.maxDuration },
                        set: { prefs.sigmoid.maxDuration = $0 }
                    ),
                    range: 10...240, step: 5, unit: "min"
                )
                SliderRow(
                    title: "Midpoint (day)",
                    value: Binding(
                        get: { prefs.sigmoid.midpoint },
                        set: { prefs.sigmoid.midpoint = $0 }
                    ),
                    range: 1...90, step: 1
                )
                SliderRow(
                    title: "Steepness",
                    value: Binding(
                        get: { prefs.sigmoid.steepness },
                        set: { prefs.sigmoid.steepness = $0 }
                    ),
                    range: 0.01...1.0, step: 0.01,
                    format: .number.precision(.fractionLength(2))
                )

                SecondaryButton(title: "Reset to defaults") {
                    showResetConfirm = true
                }

                Text("Sigmoid: min + (max − min) / (1 + exp(−steepness × (day − midpoint)))")
                    .font(AppFont.mono(10, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
            .appCard()
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
        case .idle:        return cloudKitStatus.lastSyncDate == nil ? "Waiting" : "Up to date"
        case .syncing:     return "Syncing…"
        case .failed:      return "Failed"
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
            return "Last sync failed: \(message)"
        }
        return cloudKitStatus.accountStatus.detailText
            ?? "Your workouts sync to iCloud when you're signed in."
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

    private func resetDefaults() {
        prefs?.sigmoid = .default
        prefs?.daysPerWeek = 3
        prefs?.startDate = Date()
    }

    private func importFromHealthKit() async {
        guard let start = prefs?.startDate else { return }
        if !healthKit.isAuthorized {
            await healthKit.requestAuthorization()
        }
        await healthKit.importWorkouts(from: start, into: modelContext)
    }
}

#Preview {
    SettingsView()
        .modelContainer(try! Persistence.makePreviewContainer())
        .environmentObject(HealthKitService())
        .environmentObject(CloudKitStatusService())
}
