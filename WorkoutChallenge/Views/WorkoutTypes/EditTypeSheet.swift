//
//  EditTypeSheet.swift
//  WorkoutChallenge
//
//  Shared create/edit sheet for WorkoutTypeModel. Used by both
//  WorkoutTypeManagerView (Settings → Workout types) and by the inline
//  "+ New type" affordance inside LogWorkoutSheet's chip row so users can
//  add a custom category without leaving the log flow.
//
//  Originally lived as a `private` type inside WorkoutTypeManagerView.swift;
//  extracted 2026-04-20 so LogWorkoutSheet can reuse it verbatim.
//

import SwiftUI

/// Create-or-edit sheet for a WorkoutTypeModel. The caller owns the model
/// lifecycle: this sheet only gathers name + color and hands them back via
/// `onSave`. Delete is handled by the manager view separately.
struct EditTypeSheet: View {
    enum Mode {
        case create
        case edit(WorkoutTypeModel)
    }

    let mode: Mode
    let onSave: (String, Color) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var color: Color = .green
    @FocusState private var nameFocused: Bool

    private var title: String {
        switch mode {
        case .create: return "New type"
        case .edit:   return "Edit type"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(
                    title: title,
                    onCancel: onCancel,
                    confirmLabel: "Save",
                    confirmDisabled: !canSave,
                    onConfirm: {
                        onSave(name.trimmingCharacters(in: .whitespaces), color)
                    }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.x5) {
                        AppSection(title: "Name") {
                            TextField("e.g. Rollerblading", text: $name)
                                .focused($nameFocused)
                                .font(AppFont.ui(16, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                                .padding(.vertical, Space.x2)
                        }

                        AppSection(title: "Color") {
                            HStack(spacing: Space.x3) {
                                Circle()
                                    .fill(color)
                                    .frame(width: 32, height: 32)
                                    .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
                                ColorPicker("", selection: $color, supportsOpacity: false)
                                    .labelsHidden()
                                Text("Pick a color")
                                    .font(AppFont.ui(14, weight: .medium))
                                    .foregroundStyle(Color.textSecondary)
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, Space.x5)
                    .padding(.top, Space.x3)
                    .padding(.bottom, Space.x10)
                }
            }
        }
        .task {
            if case .edit(let t) = mode {
                name = t.name
                color = t.color
            }
            nameFocused = true
        }
    }
}
