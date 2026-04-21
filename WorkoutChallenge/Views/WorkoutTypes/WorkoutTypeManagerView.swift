//
//  WorkoutTypeManagerView.swift
//  WorkoutChallenge
//
//  Port of WorkoutTypeManager.svelte — add, rename, recolor, and delete
//  workout categories. Disallows deleting the last remaining type (the web
//  version had the same rule).
//
//  Presented via NavigationLink push from SettingsView. Because the tab
//  hides the stock navigation bar, this view paints its own top bar with
//  a back chevron + trailing "+".
//

import SwiftUI
import SwiftData

struct WorkoutTypeManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WorkoutTypeModel.name) private var types: [WorkoutTypeModel]

    @State private var showingAdd = false
    @State private var editingType: WorkoutTypeModel?
    @State private var pendingDelete: WorkoutTypeModel?

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.x4) {
                        ScreenHeader(eyebrow: "CATEGORIES", title: "Workout types.")

                        if types.isEmpty {
                            Text("No types yet.")
                                .font(AppFont.ui(13))
                                .foregroundStyle(Color.textSecondary)
                        } else {
                            VStack(spacing: Space.x2) {
                                ForEach(types) { t in
                                    typeRow(t)
                                }
                            }
                        }

                        PrimaryButton(title: "Add new type", icon: "plus") {
                            showingAdd = true
                        }
                    }
                    .padding(.horizontal, Space.x5)
                    .padding(.top, Space.x4)
                    .padding(.bottom, Space.x10)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingAdd) { addSheet }
        .sheet(item: $editingType) { t in editSheet(t) }
        .confirmationDialog(
            "Delete this type?",
            isPresented: deleteBinding,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { t in
            Button("Delete", role: .destructive) { performDelete(t) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Workouts tagged with this type will become Unassigned.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(Color.appSurface2, in: Circle())
                    .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Back"))

            Spacer()

            Text("Workout Types")
                .font(AppFont.ui(15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)

            Spacer()

            Button {
                showingAdd = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.04))
                    .frame(width: 36, height: 36)
                    .background(Color.accentVolt, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Add type"))
        }
        .padding(.horizontal, Space.x4)
        .padding(.top, Space.x3)
        .padding(.bottom, Space.x2)
    }

    // MARK: - Row

    private func typeRow(_ t: WorkoutTypeModel) -> some View {
        Button {
            editingType = t
        } label: {
            HStack(spacing: Space.x3) {
                Circle()
                    .fill(t.color)
                    .frame(width: 16, height: 16)
                Text(t.name)
                    .font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if types.count > 1 {
                    Button(role: .destructive) {
                        pendingDelete = t
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.danger)
                            .frame(width: 32, height: 32)
                            .background(Color.appSurface2, in: Circle())
                            .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, Space.x4)
            .padding(.vertical, Space.x3)
            .background(Color.appSurface, in: .rect(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .stroke(Color.appBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sheets

    private var addSheet: some View {
        EditTypeSheet(mode: .create) { name, color in
            let t = WorkoutTypeModel(name: name, colorHex: color.toHex() ?? "#4CAF50")
            modelContext.insert(t)
            showingAdd = false
        } onCancel: {
            showingAdd = false
        }
    }

    private func editSheet(_ t: WorkoutTypeModel) -> some View {
        EditTypeSheet(mode: .edit(t)) { name, color in
            t.name = name
            t.colorHex = color.toHex() ?? t.colorHex
            editingType = nil
        } onCancel: {
            editingType = nil
        }
    }

    // MARK: - Delete

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func performDelete(_ t: WorkoutTypeModel) {
        // Don't allow deleting the last remaining type.
        guard types.count > 1 else {
            pendingDelete = nil
            return
        }
        modelContext.delete(t)
        pendingDelete = nil
    }
}

// MARK: - Edit sheet
//
// `EditTypeSheet` was extracted to its own file (Views/WorkoutTypes/EditTypeSheet.swift)
// on 2026-04-20 so LogWorkoutSheet's inline "+ New type" chip could reuse it
// without duplicating the create/edit form.
