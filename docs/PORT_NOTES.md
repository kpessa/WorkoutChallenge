# WorkoutChallenge — iOS port

A native SwiftUI rewrite of the Svelte webapp. The core 90-day sigmoidal
progression logic and data model are ported; the webapp's Supabase backend
is replaced with **SwiftData** (on-device storage, ready to sync to iCloud
via CloudKit once the capability is enabled) and **HealthKit** is wired in
so workouts logged in the app show up in Apple Health, and workouts from
Apple Health can be imported back in.

## Project layout

Everything is already in the `WorkoutChallenge` app target. The Xcode
project uses a `PBXFileSystemSynchronizedRootGroup`, so new files you drop
inside `WorkoutChallenge/` are picked up automatically on the next build —
no drag-and-drop into the Xcode sidebar required.

```
WorkoutChallenge/
  App/
    WorkoutChallengeApp.swift   @main entry point
    Persistence.swift           SwiftData ModelContainer factory
    RootView.swift              TabView host + first-run defaults
  Models/
    SigmoidParams.swift         Codable struct for curve parameters
    UserPreferencesModel.swift  @Model — start date, days/week, sigmoid
    WorkoutTypeModel.swift      @Model — category (name + color)
    WorkoutModel.swift          @Model — single logged workout
  Services/
    SigmoidalService.swift      Port of src/lib/utils/sigmoidal.ts
    AnalyticsService.swift      Summary, streaks, weekly buckets
    HealthKitService.swift      Auth / save / import HKWorkouts
  Views/
    Calendar/CalendarView.swift
    WorkoutLog/LogWorkoutSheet.swift
    Progress/ProgressChartView.swift     (Swift Charts)
    Analytics/AnalyticsView.swift
    Settings/SettingsView.swift
    WorkoutTypes/WorkoutTypeManagerView.swift
  Extensions/
    Color+Hex.swift
    Date+Helpers.swift
  Assets.xcassets/
  Info.plist
  WorkoutChallenge.entitlements

WorkoutChallengeTests/
  SigmoidalServiceTests.swift   needs a separate test target (see below)

docs/
  PORT_NOTES.md                 (this file)
  Info.plist.snippet.xml        reference copy of the keys Info.plist now has
  WorkoutChallenge.entitlements.reference  reference copy with full HealthKit + CloudKit keys

.trash/
  Item.swift, ContentView.swift, WorkoutChallengeApp.swift
      old Xcode starter templates; kept in case you want to diff.
```

## Current state of the port

- **Done.** Models, services, views, extensions, and the `@main` app entry
  are in place and cross-reference each other cleanly.
- **Done.** `Info.plist` contains the two HealthKit usage strings the
  runtime requires before `HKHealthStore.requestAuthorization` is called.
- **Done.** `WorkoutChallenge.entitlements` declares the HealthKit
  entitlement and stubs for CloudKit/APS.
- **Deferred.** CloudKit sync is intentionally turned off for the first
  build (`Persistence.swift` uses `cloudKitDatabase: .none`). Flip it to
  `.automatic` once you've created a CloudKit container in the Apple
  Developer portal and added its identifier to the entitlements file.

## Remaining Xcode / Apple Developer steps

These can't be scripted — they live in Xcode UI or Apple's web dashboards.

1. **Signing & Capabilities** (Xcode target → *Signing & Capabilities*):
   - Add **HealthKit** (entitlement file already declares the key; Xcode
     will pick it up).
   - Add **iCloud** when you want to turn on CloudKit sync. Create a
     container (e.g. `iCloud.kpessa.WorkoutChallenge`) and list it under
     `com.apple.developer.icloud-container-identifiers` in the entitlements
     file.
   - (Optional) **Background Modes → Remote notifications** if you want
     CloudKit push updates. The Info.plist already has the background mode
     entry wired up.
2. **Deployment target.** SwiftData + Swift Charts need iOS 17+. The
   project currently targets iOS 26.2 (Xcode 26.2 default), which is fine.
3. **Real-device test.** HealthKit works on-device and partially in the
   simulator. Run on a real iPhone to exercise auth, save, and import.

## Optional: unit tests

`WorkoutChallengeTests/SigmoidalServiceTests.swift` exists but doesn't
have a test target wired up in `project.pbxproj` yet. To run it:

1. In Xcode: *File → New → Target → iOS Unit Testing Bundle*, name
   `WorkoutChallengeTests`.
2. Xcode will create a folder of the same name — delete the auto-generated
   stub `.swift` file, then drag in the existing
   `WorkoutChallengeTests/SigmoidalServiceTests.swift` (check only the
   test-target box, not the app target).
3. ⌘U to run. The tests cover sigmoid endpoints, midpoint value, and
   schedule length.

## What changed from the Svelte webapp

| Web (Svelte)                    | iOS (SwiftUI)                            |
| ------------------------------- | ---------------------------------------- |
| Supabase (auth + Postgres)      | SwiftData (CloudKit-ready; off for now)  |
| localStorage fallback           | SwiftData (always local-first)           |
| Chart.js / unovis               | Swift Charts                             |
| Tailwind + shadcn-svelte        | System SwiftUI styles                    |
| stores/ (Svelte writables)      | `@Query` / `@Environment(\.modelContext)`|
| —                               | HealthKit read + write                   |

The sigmoid formula is identical:

```
duration = min + (max − min) / (1 + exp(−steepness × (day − midpoint)))
```

## Nice-to-haves not yet ported

- **WidgetKit** lock-screen / home-screen widgets (progress ring, next
  target minutes).
- **App Intents / Shortcuts** ("Hey Siri, log a 30-minute workout").
- **UNUserNotificationCenter** reminders for scheduled workout days.
- **watchOS companion** app — the SwiftData models are already
  CloudKit-ready, so once CloudKit is on a watch target gets data for free.
- **Webapp data import** — an onboarding flow that ingests CSV/JSON
  exported from Supabase.
