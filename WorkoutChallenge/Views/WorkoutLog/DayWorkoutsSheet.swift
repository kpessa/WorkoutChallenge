//
//  DayWorkoutsSheet.swift
//  WorkoutChallenge
//
//  Sheet shown when the user taps a day that already has one or more
//  logged workouts. Lists each entry (tap to edit) and offers an
//  "Add another workout" action at the bottom. Deletes propagate to
//  Apple Health when the entry has a healthKitUUID.
//
//  Redesigned around the SheetHeader + appCard pattern.
//

import SwiftUI
import SwiftData

struct DayWorkoutsSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var healthKit: HealthKitService
    @EnvironmentObject private var vaultSync: HealthKitSyncService

    @Query(sort: \WorkoutModel.date) private var allWorkouts: [WorkoutModel]

    let date: Date
    let proposedDuration: Int?

    @State private var editing: WorkoutModel?
    @State private var addingNew: Bool = false
    @State private var pendingDelete: WorkoutModel?
    @State private var pushingUUID: UUID?
    @State private var pushStatus: [UUID: PushStatus] = [:]

    private enum PushStatus: Equatable {
        case ok(String)
        case failed(String)
    }

    init(date: Date, proposedDuration: Int? = nil) {
        self.date = date
        self.proposedDuration = proposedDuration
    }

    private var dayWorkouts: [WorkoutModel] {
        allWorkouts.filter {
            Calendar.current.isDate($0.date, inSameDayAs: date)
        }
    }

    private var totalMinutes: Int {
        dayWorkouts.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(
                    title: date.formatted(.dateTime.weekday().month().day()),
                    confirmLabel: "Done",
                    onConfirm: { dismiss() }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.x5) {
                        summaryCard

                        AppSection(title: "Logged") {
                            VStack(spacing: Space.x2) {
                                ForEach(Array(dayWorkouts.enumerated()), id: \.element.id) { idx, w in
                                    row(for: w)
                                        .contentShape(Rectangle())
                                        .onTapGesture { editing = w }
                                    if idx < dayWorkouts.count - 1 {
                                        RowDivider()
                                    }
                                }
                            }
                        }

                        PrimaryButton(title: "Add another workout", icon: "plus") {
                            addingNew = true
                        }
                    }
                    .padding(.horizontal, Space.x5)
                    .padding(.top, Space.x3)
                    .padding(.bottom, Space.x10)
                }
            }
        }
        .sheet(item: $editing) { workout in
            LogWorkoutSheet(workout: workout)
        }
        .sheet(isPresented: $addingNew) {
            LogWorkoutSheet(date: date, proposedDuration: proposedDuration)
        }
        .confirmationDialog(
            "Delete this workout?",
            isPresented: deleteBinding,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { workout in
            Button("Delete", role: .destructive) { performDelete(workout) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { workout in
            if workout.healthKitUUID != nil && healthKit.isAvailable {
                Text("This will also remove the matching sample from Apple Health.")
            } else {
                Text("This can't be undone.")
            }
        }
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        HStack(spacing: Space.x2) {
            StatTile(
                label: "Logged today",
                value: "\(totalMinutes)",
                unit: "min",
                accent: true
            )
            StatTile(
                label: "Entries",
                value: "\(dayWorkouts.count)"
            )
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for workout: WorkoutModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Space.x3) {
                // Type dot
                Circle()
                    .fill(workout.workoutType?.color ?? Color.accentVolt)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(workout.duration) min")
                            .font(AppFont.ui(15, weight: .bold))
                            .foregroundStyle(Color.textPrimary)
                        if workout.healthKitUUID != nil {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.danger)
                        }
                    }
                    Text(workout.workoutType?.name ?? "Unassigned")
                        .font(AppFont.mono(11, weight: .medium))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.textTertiary)
                }

                Spacer()

                if let hkUUID = workout.healthKitUUID {
                    pushButton(for: workout, hkUUID: hkUUID)
                }

                Button(role: .destructive) {
                    pendingDelete = workout
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.danger)
                        .frame(width: 32, height: 32)
                        .background(Color.appSurface2, in: Circle())
                        .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
            }

            if let status = pushStatus[workout.id] {
                pushStatusLabel(status)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func pushButton(for workout: WorkoutModel, hkUUID: UUID) -> some View {
        let isPushing = pushingUUID == workout.id
        Button {
            Task { await runPush(workout: workout, hkUUID: hkUUID) }
        } label: {
            Group {
                if isPushing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentVolt)
                }
            }
            .frame(width: 32, height: 32)
            .background(Color.appSurface2, in: Circle())
            .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(vaultSync.isWorking)
    }

    @ViewBuilder
    private func pushStatusLabel(_ status: PushStatus) -> some View {
        switch status {
        case .ok(let body):
            Text("✓ \(body)")
                .font(.caption2)
                .foregroundStyle(.green)
                .lineLimit(2)
                .textSelection(.enabled)
        case .failed(let message):
            Text("✗ \(message)")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    // MARK: - Actions

    @MainActor
    private func runPush(workout: WorkoutModel, hkUUID: UUID) async {
        pushingUUID = workout.id
        defer { pushingUUID = nil }
        do {
            let response = try await vaultSync.pushWorkout(uuid: hkUUID)
            pushStatus[workout.id] = .ok(response.isEmpty ? "pushed" : response)
        } catch {
            pushStatus[workout.id] = .failed(error.localizedDescription)
        }
    }

    private func performDelete(_ workout: WorkoutModel) {
        let hkUUID = workout.healthKitUUID
        modelContext.delete(workout)
        if let hkUUID, healthKit.isAvailable {
            Task {
                await healthKit.deleteWorkout(uuid: hkUUID)
            }
        }
        pendingDelete = nil
    }
}
