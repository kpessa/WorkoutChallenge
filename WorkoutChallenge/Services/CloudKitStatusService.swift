//
//  CloudKitStatusService.swift
//  WorkoutChallenge
//
//  Surfaces whether the device is signed into iCloud and whether the SwiftData
//  store is currently syncing with CloudKit. Drives the "iCloud Sync" section
//  in SettingsView so the user can tell at a glance whether their data is
//  backed up / syncing across devices.
//
//  How it works
//  ------------
//  1. iCloud account status: ask `CKContainer` for `accountStatus`. This tells
//     us whether the user is signed in, has iCloud disabled for the app,
//     account is restricted (parental controls), etc. Refreshed on init and
//     whenever `CKAccountChanged` fires.
//
//  2. Sync activity: SwiftData uses `NSPersistentCloudKitContainer` under the
//     hood, and that class posts `eventChangedNotification` when it starts /
//     finishes a setup, import, or export event. We listen for those to show
//     "Syncing…" / "Last sync: <time>" / error state.
//
//  The container identifier is read from `CKContainer.default()`, which picks
//  it up out of the app's iCloud entitlement at runtime — so the identifier
//  stays in sync with `WorkoutChallenge.entitlements` without us hard-coding it.
//

import Foundation
import Combine
import CloudKit
import CoreData

@MainActor
final class CloudKitStatusService: ObservableObject {

    // MARK: - Public model

    /// High-level status the UI renders. Kept intentionally small — if we
    /// want a developer-level diagnostics screen later, build a separate
    /// type rather than growing this one.
    enum AccountStatus: Equatable {
        case unknown                 // Haven't checked yet.
        case available               // Signed in, sync should work.
        case noAccount               // No iCloud account on the device.
        case restricted              // Parental controls / MDM.
        case temporarilyUnavailable  // Transient; Apple asks us to retry.
        case couldNotDetermine(String)

        var displayText: String {
            switch self {
            case .unknown:                 return "Checking…"
            case .available:               return "Connected"
            case .noAccount:               return "Not signed in"
            case .restricted:              return "Restricted"
            case .temporarilyUnavailable:  return "Unavailable"
            case .couldNotDetermine:       return "Unknown"
            }
        }

        /// User-facing hint shown under the main status row. Tells the user
        /// what (if anything) they should do.
        var detailText: String? {
            switch self {
            case .unknown:
                return nil
            case .available:
                return "Your workouts sync to iCloud automatically."
            case .noAccount:
                return "Sign into iCloud in Settings to back up and sync your workouts."
            case .restricted:
                return "iCloud is restricted on this device (parental controls or device management)."
            case .temporarilyUnavailable:
                return "iCloud is temporarily unavailable. Try again in a moment."
            case .couldNotDetermine(let message):
                return message
            }
        }
    }

    /// Whether a SwiftData → CloudKit sync event is currently running.
    enum SyncActivity: Equatable {
        case idle
        case syncing          // setup, import, or export in progress
        case failed(String)   // last event finished with an error
    }

    // MARK: - Published state

    @Published private(set) var accountStatus: AccountStatus = .unknown
    @Published private(set) var syncActivity: SyncActivity = .idle
    @Published private(set) var lastSyncDate: Date?

    /// The CloudKit container identifier, e.g. `iCloud.kpessa.WorkoutChallenge`.
    /// Sourced from `CKContainer.default()`, which reads it out of the app's
    /// iCloud entitlement at runtime — so we stay in sync with entitlements
    /// without parsing them ourselves.
    var containerIdentifier: String? { container.containerIdentifier }

    // MARK: - Internals

    private let container: CKContainer = .default()
    private var observers: [NSObjectProtocol] = []

    // MARK: - Init

    init() {
        observeAccountChanges()
        observeCloudKitEvents()
        Task { await refreshAccountStatus() }
    }

    deinit {
        // Notification observers must be removed off the main actor — ok to
        // do synchronously here since they were stored as opaque tokens.
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Public API

    /// Re-query iCloud for account status. Call from a "Refresh" button or
    /// when the Settings view appears.
    func refreshAccountStatus() async {
        do {
            let status = try await container.accountStatus()
            self.accountStatus = Self.map(status)
        } catch {
            self.accountStatus = .couldNotDetermine(error.localizedDescription)
        }
    }

    // MARK: - Account change observation

    private func observeAccountChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAccountStatus()
            }
        }
        observers.append(token)
    }

    // MARK: - CloudKit sync event observation

    /// Subscribe to `NSPersistentCloudKitContainer.eventChangedNotification`.
    /// SwiftData wraps Core Data's CloudKit container, so this notification
    /// fires on every setup / import / export start & end — exactly what we
    /// need to drive a "Syncing…" / "Last sync at …" indicator.
    private func observeCloudKitEvents() {
        let name = NSPersistentCloudKitContainer.eventChangedNotification
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let key = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            guard
                let event = note.userInfo?[key] as? NSPersistentCloudKitContainer.Event
            else { return }

            Task { @MainActor in
                self.apply(event: event)
            }
        }
        observers.append(token)
    }

    private func apply(event: NSPersistentCloudKitContainer.Event) {
        if event.endDate == nil {
            // Still running.
            syncActivity = .syncing
        } else if let error = event.error {
            syncActivity = .failed(error.localizedDescription)
        } else {
            syncActivity = .idle
            lastSyncDate = event.endDate
        }
    }

    // MARK: - Helpers

    private static func map(_ status: CKAccountStatus) -> AccountStatus {
        switch status {
        case .available:              return .available
        case .noAccount:              return .noAccount
        case .restricted:             return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .couldNotDetermine:      return .couldNotDetermine("iCloud status could not be determined.")
        @unknown default:             return .couldNotDetermine("Unknown iCloud status.")
        }
    }

}
