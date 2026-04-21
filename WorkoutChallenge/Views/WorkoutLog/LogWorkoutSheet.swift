//
//  LogWorkoutSheet.swift
//  WorkoutChallenge
//
//  Modal sheet for logging a new workout OR editing/deleting an existing
//  one. Two distinct save paths:
//
//    1. Local / never-imported workouts. The "Save to Apple Health" toggle
//       controls whether a new HKWorkout is written on first save. Edits
//       to a local workout that was later synced stay local unless the
//       toggle is flipped on again (but flipping does a write-new, not an
//       update — HealthKit has no update primitive).
//
//    2. Imported-from-HealthKit workouts. Edits default to non-destructive
//       local overrides: the SwiftData row diverges from the HKWorkout,
//       which stays untouched so the Watch's attached HR/route/calorie
//       samples remain associated with the original sample. The user
//       gets an explicit "Replace in Apple Health" action (with a clear
//       warning) to push edits back to HK, and a "Revert to Apple Health
//       values" action to snap back to the import snapshot.
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
    /// Preferences row drives the Max HR used for zone math when we're
    /// displaying per-workout details. Assumed to exist — `ensureDefaults`
    /// inserts the default row on first launch.
    @Query private var preferencesList: [UserPreferencesModel]

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

    /// Imported-from-HealthKit workouts start in a locked state so the
    /// duration field is read-only. Tapping "Edit anyway" sets this true
    /// and reveals the editable controls. Local-only workouts (no HK
    /// uuid) bypass the lock entirely.
    @State private var unlocked: Bool = false

    /// Shown before a destructive "Replace in Apple Health" action that
    /// deletes the current HK sample and writes a new one with the user's
    /// edited values. The HR/route/calorie samples the Watch attached to
    /// the original workout may no longer be associated with the new row.
    @State private var showReplaceInHealthConfirm: Bool = false

    /// Shown before "Revert to Apple Health values" restores the stored
    /// snapshot so duration/date match HK again.
    @State private var showRevertConfirm: Bool = false

    /// Inline "+ New type" affordance inside the type-chip row. When true,
    /// presents `EditTypeSheet` in create mode; on save we insert a new
    /// `WorkoutTypeModel`, select it, and (in edit mode) commit the chosen
    /// type to the workout immediately — same auto-save path as tapping an
    /// existing chip.
    @State private var showingNewType: Bool = false

    /// Pulls HR samples, calories, distance, elevation, and the GPS route
    /// from HealthKit for the edit-mode workout. `@State` (rather than
    /// `@StateObject`) because `WorkoutDetailsLoader` is an `@Observable`
    /// class — SwiftUI tracks its published `state` through the Observation
    /// framework directly.
    @State private var detailsLoader = WorkoutDetailsLoader()

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
        // For never-imported local workouts, edits write-through and
        // (optionally) save to HealthKit. For imported rows, edits are
        // non-destructive local overrides by default — the toggle only
        // controls whether *new* writes also push to HK. Default:
        //   - Imported rows: OFF (don't accidentally clobber HK on save).
        //   - Local rows:    ON  (matches previous behavior).
        _syncToHealth = State(initialValue: workout.healthKitUUID == nil)
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
                // Hide the confirm button entirely while an imported workout
                // is locked — nothing is editable yet, so a SAVE button up
                // top would contradict the "From Apple Health / Edit anyway"
                // state below. The "Edit anyway" action in the HK card is
                // the sole affordance until the user unlocks.
                SheetHeader(
                    title: isEditing ? "Edit workout" : "Log workout",
                    onCancel: { dismiss() },
                    confirmLabel: isLockedForImport ? nil : (isEditing ? "Save" : "Log"),
                    onConfirm: isLockedForImport ? nil : { save() }
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
                        // Per-workout enrichment — only shown when editing
                        // an existing HealthKit-synced entry.
                        if isEditing {
                            detailsSection
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
            // Kick off details load once authorization is done. We run this
            // after requestAuthorization so first-launch users see the
            // permission prompt before the loader silently returns empty.
            loadDetailsIfEditing()
        }
        .onDisappear { detailsLoader.cancel() }
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
        .confirmationDialog(
            "Replace in Apple Health?",
            isPresented: $showReplaceInHealthConfirm,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive, action: replaceInHealthKit)
            Button("Cancel", role: .cancel) { }
        } message: {
            // Key warning: HK has no "update" primitive, so we have to
            // delete+re-save. The HR/route/calorie samples the Watch
            // attached to the original HKWorkout may no longer be
            // associated with the new row — users need to know that
            // before committing.
            Text("The current Health entry will be deleted and a new one written with your edited values. Heart-rate, route, and calorie data recorded by your Watch may no longer be associated with this workout.")
        }
        .confirmationDialog(
            "Revert to Apple Health values?",
            isPresented: $showRevertConfirm,
            titleVisibility: .visible
        ) {
            Button("Revert", role: .destructive, action: revertToHealthValues)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your local edits to duration and date will be discarded.")
        }
        .sheet(isPresented: $showingNewType) {
            EditTypeSheet(mode: .create) { name, color in
                let hex = color.toHex() ?? "#4CAF50"
                let new = WorkoutTypeModel(name: name, colorHex: hex)
                modelContext.insert(new)
                // Persist the insertion before selecting so the @Query
                // driving the chip row picks it up on the next render.
                try? modelContext.save()
                commitTypeSelection(new)
                showingNewType = false
            } onCancel: {
                showingNewType = false
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

    /// True when editing a workout that came from HealthKit AND the user
    /// hasn't explicitly unlocked the fields. Duration/date render as
    /// read-only in this state.
    private var isLockedForImport: Bool {
        (existingWorkout?.isImported ?? false) && !unlocked
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
                if isLockedForImport {
                    // Read-only view: big display of the current value with
                    // a lock glyph; the HK card below offers the unlock
                    // affordance so it stays near the "Apple Health" copy.
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text("\(duration)")
                            .font(AppFont.display(48))
                            .monospacedDigit()
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("min")
                            .font(AppFont.ui(16, weight: .semibold))
                            .foregroundStyle(Color.textSecondary)
                        Spacer()
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.textTertiary)
                    }
                } else {
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
    }

    /// Workout type chips + inline "+ New type" affordance.
    ///
    /// Tapping a chip on an *imported* HealthKit workout is an intentional
    /// exception to the edit-lock: workout type is local-only metadata (a
    /// SwiftData relationship to `WorkoutTypeModel`) that has no HealthKit
    /// counterpart we round-trip to, so retagging a run as "Rollerblade" or
    /// "Speediance" can never orphan the Watch's attached HR/route/calorie
    /// samples. In edit mode the chosen type is committed immediately via
    /// `commitTypeSelection` — no Save button, no unlock — matching the
    /// "tag, don't edit" mental model.
    private var typeCard: some View {
        AppSection(title: "Workout type") {
            FlowLayout(spacing: Space.x2, rowSpacing: Space.x2) {
                ForEach(types) { type in
                    Chip(
                        title: type.name,
                        dotColor: type.color,
                        isOn: selectedType?.id == type.id,
                        action: { commitTypeSelection(type) }
                    )
                }
                NewTypeChip { showingNewType = true }
            }
        }
    }

    /// Select `type` locally and, when editing an existing workout, persist
    /// the change to the SwiftData row immediately. The save is intentionally
    /// fire-and-forget: a type change is a tag, not a content edit, and
    /// users get instant feedback (the chip's selection state) without a
    /// Save tap.
    private func commitTypeSelection(_ type: WorkoutTypeModel) {
        selectedType = type
        if case .edit(let workout) = mode,
           workout.workoutType?.id != type.id {
            workout.workoutType = type
            try? modelContext.save()
        }
    }

    @ViewBuilder
    private var healthKitCard: some View {
        if let workout = existingWorkout, workout.isImported {
            importedHealthKitCard(workout: workout)
        } else {
            AppSection(title: "Apple Health") {
                AppToggleRow(
                    title: "Save to Apple Health",
                    detail: "Writes a workout sample with the duration above.",
                    isOn: $syncToHealth
                )
            }
        }
    }

    /// Apple Health card for a workout that originated in HealthKit. The
    /// normal "Save to Apple Health" toggle is hidden — we don't want edits
    /// to silently delete+re-save the HK sample (that would orphan the
    /// Watch's attached HR/route/calorie data from the workout).
    ///
    /// States:
    ///   • Locked (default): "From Apple Health" badge + "Edit anyway"
    ///     button that sets `unlocked = true`.
    ///   • Unlocked, no edits yet: a "Locked" badge is removed; the user
    ///     can edit duration freely. Saving writes the override locally.
    ///   • Unlocked, has edits: additionally shows "Revert to Apple Health
    ///     values" and "Replace in Apple Health" actions.
    private func importedHealthKitCard(workout: WorkoutModel) -> some View {
        AppSection(title: "Apple Health") {
            VStack(alignment: .leading, spacing: Space.x3) {
                HStack(spacing: Space.x2) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentInk)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From Apple Health")
                            .font(AppFont.ui(14, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text(importedCopy(workout: workout))
                            .font(AppFont.ui(12, weight: .medium))
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                }

                if !unlocked {
                    SecondaryButton(title: "Edit anyway", icon: "lock.open") {
                        unlocked = true
                    }
                } else {
                    // Unlocked. Show override-related actions only when a
                    // divergence actually exists. The "pending" check
                    // catches the case where the user has just typed a
                    // new duration but hasn't saved yet — we want the
                    // revert/replace buttons to appear immediately.
                    //
                    // Guard on snapshot presence: for older imported rows
                    // that pre-date the snapshot feature there's nothing
                    // meaningful to compare against, so we only show the
                    // actions when we have a real HK anchor.
                    let snapDur = workout.hkImportedDuration
                    let pendingDiverges = snapDur != nil && snapDur != duration
                    if workout.hasLocalOverride || pendingDiverges {
                        RowDivider()
                        SecondaryButton(
                            title: "Revert to Apple Health values",
                            icon: "arrow.uturn.backward"
                        ) {
                            showRevertConfirm = true
                        }
                        SecondaryButton(
                            title: "Replace in Apple Health",
                            icon: "exclamationmark.arrow.triangle.2.circlepath"
                        ) {
                            showReplaceInHealthConfirm = true
                        }
                    }
                }
            }
        }
    }

    /// Helper copy for the imported-card subtitle. When the snapshot
    /// fields are present we can show a crisp "Edited locally" state; for
    /// older rows that pre-date the snapshot we fall back to generic copy.
    private func importedCopy(workout: WorkoutModel) -> String {
        if workout.hasLocalOverride || (unlocked && duration != workout.duration) {
            return "You've edited this locally. Apple Health still has the original values."
        }
        if workout.hkImportedDuration != nil {
            return "Edits stay local by default. Use \u{201C}Replace\u{201D} to push changes back to Health."
        }
        return "This workout was imported from Apple Health."
    }

    // MARK: - Per-workout details

    /// Shows a placeholder while details load, then the HR + stats + route
    /// cards once they arrive. Collapses silently when the workout has no
    /// HealthKit UUID (local-only entries have nothing to enrich with).
    @ViewBuilder
    private var detailsSection: some View {
        switch detailsLoader.state {
        case .notAvailable:
            EmptyView()
        case .idle, .loading:
            AppSection(title: "Workout details") {
                HStack(spacing: Space.x3) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.accentInk)
                    Text("Loading heart rate, calories, route…")
                        .font(AppFont.ui(13, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                }
            }
        case .failed(let message):
            AppSection(title: "Workout details") {
                HStack(spacing: Space.x3) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't load details")
                            .font(AppFont.ui(14, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text(message)
                            .font(AppFont.ui(12))
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                }
            }
        case .loaded(let details):
            HeartRateCard(details: details)
            ExtraStatsCard(details: details)
            WorkoutRouteMap(locations: details.routeLocations)
        }
    }

    /// Kick off the details loader. Called from `.task` after we've had a
    /// chance to prompt for HealthKit authorization.
    private func loadDetailsIfEditing() {
        guard case .edit(let workout) = mode else {
            detailsLoader.cancel()
            return
        }
        let prefs = preferencesList.first
        let birthdate = healthKit.fetchBirthdateComponents()
        let maxHR: Double = {
            if let prefs {
                return MaxHRService.resolve(preferences: prefs, birthdate: birthdate)
            }
            // No preferences row yet — use a sensible default so zone math
            // doesn't divide by zero. This path shouldn't really fire
            // outside of tests/previews.
            return 190
        }()
        detailsLoader.load(workout: workout, healthKit: healthKit, maxHR: maxHR)
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
                    // Seed the HK snapshot too so a subsequent edit flow
                    // starts with `hasLocalOverride == false` and has a
                    // valid anchor to revert to.
                    model.captureHealthKitSnapshot()
                    try? modelContext.save()
                }
            }
        }
    }

    private func saveEdit(workout: WorkoutModel) {
        // Backfill the HK snapshot on first edit of an older imported row
        // (rows imported before the snapshot feature existed). We assume
        // the pre-edit `duration` is still the HK value, which is true
        // because the old code only diverged by round-tripping through HK.
        if workout.isImported,
           workout.hkImportedDuration == nil,
           workout.hkImportedDate == nil {
            workout.captureHealthKitSnapshot()
        }

        workout.duration = duration
        workout.workoutType = selectedType

        // Imported rows: edits are non-destructive by default. We write to
        // the local SwiftData row only — HealthKit is not touched, so the
        // Watch's attached HR/route/calorie samples stay associated with
        // the original HKWorkout. To push changes back to Health the user
        // must use the explicit "Replace in Apple Health" action, which
        // routes through `replaceInHealthKit()` with a destructive warning.
        //
        // Local (never-imported) rows: same as before — if sync is on,
        // write a new HKWorkout and record its uuid on the row.
        if !workout.isImported, syncToHealth, healthKit.isAvailable {
            let newDate = workout.date
            let newDuration = duration
            Task {
                let newID = await healthKit.saveWorkout(
                    start: newDate,
                    durationMinutes: newDuration
                )
                if let newID {
                    workout.healthKitUUID = newID
                    // Seed the snapshot so future edits can use the
                    // override/revert flow.
                    workout.captureHealthKitSnapshot()
                    try? modelContext.save()
                }
            }
        }
    }

    // MARK: - Explicit Apple Health round-trip

    /// Destructive: delete the existing HK sample and write a new one with
    /// the currently-edited values. Used only when the user explicitly
    /// opts in via "Replace in Apple Health" (behind a confirmation).
    /// Updates the local row's snapshot to match the new HK values so
    /// `hasLocalOverride` returns false afterward.
    private func replaceInHealthKit() {
        guard case .edit(let workout) = mode else { return }
        guard workout.isImported, healthKit.isAvailable else { return }

        // Persist the current edits locally first so the in-memory state
        // and the HK write agree on what "new values" means.
        workout.duration = duration
        workout.workoutType = selectedType
        let newDate = workout.date
        let newDuration = duration
        let oldUUID = workout.healthKitUUID

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
                // The new HK sample's values ARE the edited values, so
                // after a successful replace the local row no longer
                // diverges from HK.
                workout.captureHealthKitSnapshot()
                try? modelContext.save()
            }
            dismiss()
        }
    }

    /// Non-destructive: restore `duration`/`date` to the HK snapshot.
    /// Available only when the snapshot is present (modern imported rows).
    private func revertToHealthValues() {
        guard case .edit(let workout) = mode else { return }
        guard let snapDuration = workout.hkImportedDuration,
              let snapDate = workout.hkImportedDate
        else { return }
        workout.duration = snapDuration
        workout.date = snapDate
        duration = snapDuration  // keep the sheet's @State in lockstep
        unlocked = false         // relock after revert — clean slate
        try? modelContext.save()
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

// MARK: - NewTypeChip

/// Inline "+ New type" chip shown at the end of the workout-type chip row
/// inside `LogWorkoutSheet`. Mirrors `Chip`'s capsule geometry and typography
/// so it reads as part of the same row, but uses a dashed tertiary border
/// to signal "create" rather than "select" — same visual language as the
/// onboarding custom-activity tile. Tapping invokes the supplied action;
/// the caller is responsible for presenting the create sheet.
private struct NewTypeChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text("New type")
                    .font(AppFont.mono(11, weight: .medium))
                    .tracking(0.8)
                    .textCase(.uppercase)
            }
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(
                Capsule()
                    .stroke(Color.appBorder,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add a new workout type"))
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
