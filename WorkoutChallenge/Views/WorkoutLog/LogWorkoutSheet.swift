//
//  LogWorkoutSheet.swift
//  WorkoutChallenge
//
//  Modal sheet for logging a new workout OR editing/deleting an existing
//  one. Optionally writes to Apple Health when the toggle is on. For
//  workouts that originated from (or were previously synced to) Health,
//  edits and deletes propagate back to HealthKit — since HealthKit has no
//  "update" primitive, an edit is modeled as delete-old-sample-then-save-new.
//
//  Redesigned to use the ScreenShell + SheetHeader + appCard pattern
//  (no stock Form/NavigationBar).
//

import SwiftUI
import SwiftData

struct LogWorkoutSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var healthKit: HealthKitService

    @Query(sort: \WorkoutTypeModel.name) private var types: [WorkoutTypeModel]

    /// Distinguishes a brand-new entry from an existing one being edited.
    /// The two public inits map onto these cases.
    private enum Mode {
        case create(date: Date, proposedDuration: Int?)
        case edit(workout: WorkoutModel)
    }

    private let mode: Mode

    @State private var duration: Int
    @State private var selectedType: WorkoutTypeModel?
    @State private var syncToHealth: Bool
    @State private var showDeleteConfirm: Bool = false
    @FocusState private var durationFieldFocused: Bool

    init(date: Date, proposedDuration: Int? = nil) {
        self.mode = .create(date: date, proposedDuration: proposedDuration)
        _duration = State(initialValue: proposedDuration ?? 30)
        _selectedType = State(initialValue: nil)
        _syncToHealth = State(initialValue: true)
    }

    init(workout: WorkoutModel) {
        self.mode = .edit(workout: workout)
        _duration = State(initialValue: workout.duration)
        _selectedType = State(initialValue: workout.workoutType)
        // Default the HK toggle based on whether this entry already lives in
        // HealthKit. For HK-sourced entries we default ON so edits round-trip;
        // for local-only entries we also default ON so the user can opt to
        // start syncing. Either way the user can flip it.
        _syncToHealth = State(initialValue: true)
    }

    // MARK: - Derived

    private var isEditing: Bool {
        if case .edit = mode { return true } else { return false }
    }

    private var entryDate: Date {
        switch mode {
        case .create(let date, _): return date
        case .edit(let w): return w.date
        }
    }

    private var existingWorkout: WorkoutModel? {
        if case .edit(let w) = mode { return w } else { return nil }
    }

    private var proposedDuration: Int? {
        if case .create(_, let p) = mode { return p }
        return nil
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(
                    title: isEditing ? "Edit workout" : "Log workout",
                    onCancel: { dismiss() },
                    confirmLabel: isEditing ? "Save" : "Log",
                    onConfirm: { save() }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.x5) {
                        dateCard
                        durationCard
                        if !types.isEmpty {
                            typeCard
                        }
                        if healthKit.isAvailable {
                            healthKitCard
                        }
                        if isEditing {
                            deleteCard
                        }
                    }
                    .padding(.horizontal, Space.x5)
                    .padding(.top, Space.x3)
                    .padding(.bottom, Space.x10)
                }
            }
        }
        .task {
            if selectedType == nil { selectedType = existingWorkout?.workoutType ?? types.first }
            if !healthKit.isAuthorized && healthKit.isAvailable {
                await healthKit.requestAuthorization()
            }
        }
        .confirmationDialog(
            "Delete this workout?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteWorkout)
            Button("Cancel", role: .cancel) { }
        } message: {
            if existingWorkout?.healthKitUUID != nil && syncToHealth {
                Text("This will also remove the matching sample from Apple Health.")
            }
        }
    }

    // MARK: - Cards

    private var dateCard: some View {
        AppSection(title: "Date") {
            HStack(alignment: .lastTextBaseline, spacing: Space.x2) {
                Text(entryDate, format: .dateTime.weekday(.wide))
                    .font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                Text(entryDate, format: .dateTime.month(.abbreviated).day().year())
                    .tsH3()
                    .foregroundStyle(Color.textPrimary)
            }
        }
    }

    private var durationCard: some View {
        AppSection(
            title: "Duration",
            trailing: proposedDuration.map { value in
                AnyView(
                    Chip(title: "Target \(value) min",
                         isOn: duration == value,
                         action: { duration = value })
                )
            }
        ) {
            VStack(alignment: .leading, spacing: Space.x3) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    TextField("30", value: $duration, format: .number)
                        .keyboardType(.numberPad)
                        .focused($durationFieldFocused)
                        .font(AppFont.display(48))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentInk)
                        .fixedSize()
                    Text("min")
                        .font(AppFont.ui(16, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    Stepper("", value: $duration, in: 1...240, step: 5)
                        .labelsHidden()
                        .tint(.accentVolt)
                }
                .contentShape(Rectangle())
                .onTapGesture { durationFieldFocused = true }
                .onChange(of: duration) { _, new in
                    if new < 1 { duration = 1 }
                    if new > 240 { duration = 240 }
                }
            }
        }
    }

    private var typeCard: some View {
        AppSection(title: "Workout type") {
            FlowLayout(spacing: Space.x2, rowSpacing: Space.x2) {
                ForEach(types) { type in
                    Chip(
                        title: type.name,
                        dotColor: type.color,
                        isOn: selectedType?.id == type.id,
                        action: { selectedType = type }
                    )
                }
            }
        }
    }

    private var healthKitCard: some View {
        AppSection(title: "Apple Health") {
            AppToggleRow(
                title: "Save to Apple Health",
                detail: existingWorkout?.healthKitUUID != nil
                    ? "This workout is already synced. Changes update the Health sample."
                    : "Writes a workout sample with the duration above.",
                isOn: $syncToHealth
            )
        }
    }

    private var deleteCard: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                Text("Delete workout")
            }
            .font(AppFont.ui(14.5, weight: .bold))
            .foregroundStyle(Color.danger)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Color.appSurface, in: .rect(cornerRadius: Radius.button))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.button)
                    .stroke(Color.danger.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save

    private func save() {
        switch mode {
        case .create(let date, _):
            saveNew(date: date)
        case .edit(let workout):
            saveEdit(workout: workout)
        }
        dismiss()
    }

    private func saveNew(date: Date) {
        let model = WorkoutModel(
            date: date,
            duration: duration,
            workoutType: selectedType,
            healthKitUUID: nil
        )
        modelContext.insert(model)

        if syncToHealth && healthKit.isAvailable {
            Task {
                let id = await healthKit.saveWorkout(
                    start: date,
                    durationMinutes: duration
                )
                if let id {
                    model.healthKitUUID = id
                    try? modelContext.save()
                }
            }
        }
    }

    private func saveEdit(workout: WorkoutModel) {
        workout.duration = duration
        workout.workoutType = selectedType

        // If this workout is tied to Apple Health and sync is on, replace the
        // HK sample so its duration matches. Delete-then-save because HK has
        // no in-place update.
        if syncToHealth && healthKit.isAvailable {
            let oldUUID = workout.healthKitUUID
            let newDate = workout.date
            let newDuration = duration
            Task {
                if let oldUUID {
                    await healthKit.deleteWorkout(uuid: oldUUID)
                }
                let newID = await healthKit.saveWorkout(
                    start: newDate,
                    durationMinutes: newDuration
                )
                if let newID {
                    workout.healthKitUUID = newID
                    try? modelContext.save()
                }
            }
        }
    }

    // MARK: - Delete

    private func deleteWorkout() {
        guard case .edit(let workout) = mode else { return }

        let hkUUID = workout.healthKitUUID
        let shouldDeleteHK = syncToHealth && healthKit.isAvailable && hkUUID != nil

        modelContext.delete(workout)

        if shouldDeleteHK, let hkUUID {
            Task {
                await healthKit.deleteWorkout(uuid: hkUUID)
            }
        }

        dismiss()
    }
}

// MARK: - FlowLayout

/// Simple wrapping layout for the workout-type Chips. iOS 16+ `Layout` API.
/// Left-aligned rows; items flow to the next row when they'd overflow.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * rowSpacing
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, width: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let currentIndex = rows.count - 1
            let projected = rows[currentIndex].width
                + size.width
                + (rows[currentIndex].items.isEmpty ? 0 : spacing)
            if projected <= maxWidth || rows[currentIndex].items.isEmpty {
                if !rows[currentIndex].items.isEmpty {
                    rows[currentIndex].width += spacing
                }
                rows[currentIndex].items.append((index, size.width))
                rows[currentIndex].width += size.width
                rows[currentIndex].height = max(rows[currentIndex].height, size.height)
            } else {
                var newRow = Row()
                newRow.items.append((index, size.width))
                newRow.width = size.width
                newRow.height = size.height
                rows.append(newRow)
            }
        }
        return rows
    }
}
