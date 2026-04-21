//
//  CreateChallengeView.swift
//  WorkoutChallenge
//
//  Three-step flow for starting a new challenge:
//    1) Activities — pick (or confirm) the workout types you'll use
//    2) Goals     — start date + days per week
//    3) Commit    — read the contract, sign the pledge, begin
//
//  Design intent (per the Lifecycle doc): step 3 is the "commitment
//  moment" — a contract-like card listing the deal, followed by an
//  italic pledge. Signing is done by typing any name — it's symbolic.
//

import SwiftUI
import SwiftData

struct CreateChallengeView: View {
    let nextNumber: Int
    let defaultSigmoid: SigmoidParams
    let onCreate: (_ startDate: Date, _ daysPerWeek: Int,
                   _ sigmoid: SigmoidParams, _ pledge: String) -> Void
    let onCancel: () -> Void

    @Query private var workoutTypes: [WorkoutTypeModel]

    @State private var step: Step = .activities
    @State private var selectedTypeIds: Set<UUID> = []
    @State private var startDate: Date = Date()
    @State private var daysPerWeek: Int = 4
    @State private var pledge: String = ""

    enum Step: Int, CaseIterable { case activities = 1, goals = 2, commit = 3 }

    var body: some View {
        ScreenShell(
            eyebrow: String.localizedStringWithFormat(
                NSLocalizedString("CHALLENGE %02lld", comment: "Create flow eyebrow"),
                nextNumber),
            title: headline
        ) {
            stepIndicator
            Group {
                switch step {
                case .activities: activitiesStep
                case .goals:      goalsStep
                case .commit:     commitStep
                }
            }
            footer
        }
        .onAppear {
            // Preselect all existing types so the default is "whatever the
            // user has been using" — consistent with prefs.
            selectedTypeIds = Set(workoutTypes.map(\.id))
        }
    }

    private var headline: String {
        switch step {
        case .activities: return String(localized: "Pick your activities.", comment: "Create flow step 1 headline")
        case .goals:      return String(localized: "Set your goals.", comment: "Create flow step 2 headline")
        case .commit:     return String(localized: "This is the deal.", comment: "Create flow step 3 headline")
        }
    }

    // MARK: - Progress bar header

    private var stepIndicator: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                Text("STEP \(step.rawValue) OF 3")
                    .font(AppFont.mono(10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.textTertiary)
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(AppFont.ui(13, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 4) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Rectangle()
                        .fill(s.rawValue <= step.rawValue
                              ? Color.accentVolt : Color.appSurface2)
                        .frame(height: 3)
                }
            }
        }
    }

    // MARK: - Step 1: Activities

    private var activitiesStep: some View {
        LazyVGrid(
            columns: [.init(.flexible()), .init(.flexible())],
            spacing: Space.x2
        ) {
            ForEach(workoutTypes) { type in
                activityTile(for: type)
            }
        }
    }

    @ViewBuilder
    private func activityTile(for type: WorkoutTypeModel) -> some View {
        let selected = selectedTypeIds.contains(type.id)
        let color = Color(hex: type.colorHex) ?? .accentVolt
        Button {
            if selected { selectedTypeIds.remove(type.id) }
            else { selectedTypeIds.insert(type.id) }
        } label: {
            HStack(spacing: Space.x2) {
                Circle()
                    .fill(color)
                    .overlay(
                        Circle().stroke(
                            selected ? Color.accentVolt : Color.appBorder,
                            lineWidth: selected ? 1.5 : 1)
                    )
                    .frame(width: 10, height: 10)
                Text(type.name)
                    .font(AppFont.ui(13, weight: selected ? .bold : .semibold))
                    .foregroundStyle(selected ? Color.textPrimary : Color.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.x3)
            .padding(.vertical, Space.x3)
            .background(
                selected ? Color.accentVolt.opacity(0.08) : Color.appSurface,
                in: .rect(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.accentVolt : Color.appBorder,
                            lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: Goals

    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            VStack(alignment: .leading, spacing: Space.x2) {
                Text("START DATE")
                    .font(AppFont.mono(10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.textTertiary)
                DatePicker("", selection: $startDate, displayedComponents: .date)
                    .labelsHidden()
                    .tint(.accentVolt)
            }
            VStack(alignment: .leading, spacing: Space.x2) {
                Text("DAYS PER WEEK")
                    .font(AppFont.mono(10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.textTertiary)
                HStack(spacing: Space.x3) {
                    ForEach(1...7, id: \.self) { n in
                        Button { daysPerWeek = n } label: {
                            Text("\(n)")
                                .font(AppFont.ui(14, weight: daysPerWeek == n ? .bold : .semibold))
                                .foregroundStyle(daysPerWeek == n
                                                 ? Color(red: 0.04, green: 0.04, blue: 0.04)
                                                 : Color.textSecondary)
                                .frame(width: 36, height: 36)
                                .background(daysPerWeek == n
                                            ? Color.accentVolt : Color.appSurface,
                                            in: .rect(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(daysPerWeek == n
                                                ? Color.textPrimary : Color.appBorder,
                                                lineWidth: daysPerWeek == n ? 1.5 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .appCard()
    }

    // MARK: - Step 3: Commit

    private var commitStep: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            // Contract card
            VStack(alignment: .leading, spacing: Space.x3) {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("CHALLENGE %02lld", comment: "Contract card header"),
                    nextNumber))
                    .font(AppFont.mono(10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.accentInk)

                contractRow("Starts", formatted(startDate))
                contractRow("Ends",   formatted(startDate.addingDays(89)))
                contractRow("Days/week", "\(daysPerWeek)")
                contractRow("Activities", activitiesSummary)
            }
            .appCard()
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(Color.accentVolt, lineWidth: 1.5)
            )

            // Pledge
            HStack(alignment: .top, spacing: Space.x2) {
                Rectangle().fill(Color.accentVolt).frame(width: 2)
                Text("“I show up, even when it's boring. Ninety days, no renegotiation.”")
                    .font(AppFont.ui(13, weight: .medium))
                    .italic()
                    .foregroundStyle(Color.textPrimary)
                    .padding(.vertical, 4)
            }

            // Signature
            VStack(alignment: .leading, spacing: Space.x2) {
                Text("SIGN TO COMMIT")
                    .font(AppFont.mono(9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.textTertiary)
                TextField("Your name", text: $pledge)
                    .font(AppFont.display(18))
                    .foregroundStyle(Color.accentInk)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.accentVoltInk)
                            .frame(height: 1.5)
                    }
            }
        }
    }

    @ViewBuilder
    private func contractRow(_ label: String, _ value: String) -> some View {
        // `label` is a static English key (e.g. "Starts") routed through the
        // catalog via LocalizedStringKey. `value` is a pre-formatted dynamic
        // string (date, number) and rendered verbatim.
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label))
                .font(AppFont.ui(13, weight: .medium))
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(AppFont.ui(13, weight: .bold))
                .foregroundStyle(Color.textPrimary)
        }
    }

    private func formatted(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private var activitiesSummary: String {
        let names = workoutTypes
            .filter { selectedTypeIds.contains($0.id) }
            .map(\.name)
        if names.isEmpty { return "—" }
        if names.count <= 2 { return names.joined(separator: " + ") }
        return "\(names.prefix(2).joined(separator: " + ")) +\(names.count - 2)"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Space.x3) {
            if step != .activities {
                SecondaryButton(title: "Back") { step = Step(rawValue: step.rawValue - 1) ?? .activities }
            }
            PrimaryButton(title: step == .commit ? "Begin" : "Continue") {
                switch step {
                case .activities: step = .goals
                case .goals:      step = .commit
                case .commit:
                    onCreate(startDate.startOfDay, daysPerWeek,
                             defaultSigmoid, pledge)
                }
            }
        }
    }
}

#Preview {
    CreateChallengeView(
        nextNumber: 2,
        defaultSigmoid: .default,
        onCreate: { _, _, _, _ in },
        onCancel: {}
    )
    .modelContainer(try! Persistence.makePreviewContainer())
}
