//
//  DataExportSection.swift
//  WorkoutChallenge
//
//  "Data" block on the Settings screen — currently just an "Export data
//  as JSON" action that gathers everything the app has stored for the
//  user (challenges, workouts, types, preferences, coach feedback,
//  Reclaim mappings, plus per-workout HealthKit details where available)
//  and hands a `.json` file off to the iOS share sheet.
//
//  The actual export work lives in `DataExportService`. This file is just
//  the UI surface and the UIKit bridge for the share sheet.
//

import SwiftUI
import Combine
import SwiftData
import UIKit

struct DataExportSection: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var healthKit: HealthKitService

    /// Status sub-text rendered under the export button. Reflects the
    /// in-flight, success, and error states so the user knows what's
    /// happening — HealthKit fan-out can take a couple seconds on a real
    /// device with hundreds of imported workouts.
    @State private var status: ExportStatus = .idle

    /// File URL of the export currently being shared. Setting this drives
    /// the `.sheet` presentation; we clear it when the share sheet
    /// dismisses so the next export presents cleanly.
    @State private var shareURL: URL?

    var body: some View {
        AppSection(title: "Data") {
            VStack(spacing: Space.x2) {
                SecondaryButton(
                    title: status.isWorking ? "Preparing export…" : "Export data as JSON",
                    icon: "square.and.arrow.up"
                ) {
                    Task { await runExport() }
                }
                .disabled(status.isWorking)
            }

            if let message = status.message {
                Text(message)
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(status.isError ? Color.danger : Color.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Includes your challenges, workouts, types, preferences, coach feedback, and \u{2014} where Apple Health is connected \u{2014} per\u{2011}workout heart rate, zone breakdown, and route data.")
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: Binding(
            get: { shareURL.map(IdentifiableURL.init) },
            set: { shareURL = $0?.url }
        )) { wrapped in
            ShareSheet(activityItems: [wrapped.url])
        }
    }

    // MARK: - Action

    private func runExport() async {
        status = .working
        do {
            let url = try await DataExportService.writeToTempFile(
                modelContext: modelContext,
                healthKit: healthKit
            )
            // Tag with size so the user sees the export went out the
            // door — useful as a sanity check on a 0-byte HK fanout bug.
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            status = .ready(byteCount: bytes)
            shareURL = url
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Status enum

private enum ExportStatus {
    case idle
    case working
    case ready(byteCount: Int)
    case failed(String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Human-readable status line, or nil when there's nothing to show.
    var message: String? {
        switch self {
        case .idle:
            return nil
        case .working:
            return String(
                localized: "Gathering your data\u{2026}",
                comment: "DataExportSection — in-flight status"
            )
        case .ready(let bytes):
            let formatted = ByteCountFormatter.string(
                fromByteCount: Int64(bytes),
                countStyle: .file
            )
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "Export ready (%@). Tap a destination to save or send.",
                    comment: "DataExportSection — success status with byte count"
                ),
                formatted
            )
        case .failed(let reason):
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "Export failed: %@",
                    comment: "DataExportSection — failure status"
                ),
                reason
            )
        }
    }
}

// MARK: - Share sheet bridge
//
// SwiftUI gained `ShareLink` in iOS 16, but we want both the textual
// status above AND a programmatically-triggered presentation (after the
// async export completes), so we wrap UIActivityViewController directly.
//

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        // No-op: activity items are static for the life of the sheet.
    }
}

/// Lightweight `Identifiable` wrapper so a `URL?` can drive a
/// `.sheet(item:)` modifier — `URL` itself isn't Identifiable.
private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: URL { url }
}
