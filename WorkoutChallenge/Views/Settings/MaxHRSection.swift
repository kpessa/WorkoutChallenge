//
//  MaxHRSection.swift
//  WorkoutChallenge
//
//  Settings section that lets the user pick how their Max HR is derived.
//  This is what drives the 5-zone split on the workout detail view.
//
//  Compositionally: read-only rows at the top (resolved MHR, Health-kit
//  inferred age / sex) → age override → method picker → manual BPM input
//  (only when Manual is selected) → refresh-observed-max action.
//
//  Kept in its own view rather than inlined into `SettingsView` because the
//  method picker alone is a dozen+ lines and SettingsView is already the
//  app's longest file.
//

import SwiftUI
import Combine
import SwiftData
import HealthKit

struct MaxHRSection: View {
    @Bindable var prefs: UserPreferencesModel
    @EnvironmentObject private var healthKit: HealthKitService

    @State private var hkBirthdate: DateComponents?
    @State private var hkSex: HKBiologicalSex?
    @State private var refreshingObserved = false
    @State private var refreshingResting = false

    /// Age we derive for formula-based methods. Override wins, else we
    /// compute from the HealthKit birthdate (when access is granted).
    private var resolvedAge: Double? {
        MaxHRService.age(from: hkBirthdate, override: prefs.maxHRAgeOverride)
    }

    private var resolvedMaxHR: Double {
        MaxHRService.resolve(preferences: prefs, birthdate: hkBirthdate)
    }

    var body: some View {
        AppSection(title: "Heart rate zones") {
            VStack(alignment: .leading, spacing: Space.x3) {
                resolvedReadoutRow
                RowDivider()
                restingRow
                RowDivider()
                ageRow
                RowDivider()
                methodPicker
                if prefs.maxHRMethod == .manual {
                    RowDivider()
                    manualRow
                }
                if prefs.maxHRMethod == .observed {
                    RowDivider()
                    observedRow
                }
            }
        }
        .task {
            // Pull HealthKit characteristics once the section appears. If
            // access hasn't been granted, these silently return nil — the
            // UI reads as "no birthdate on file" and the Manual / age
            // override flow still works.
            hkBirthdate = healthKit.fetchBirthdateComponents()
            hkSex = healthKit.fetchBiologicalSex()

            // On first run seed the method from the HealthKit sex hint
            // (Gulati for biologically female, Tanaka otherwise). We only
            // auto-apply when the user hasn't picked anything yet — i.e.
            // the default Tanaka is still in place and no other field is
            // customized.
            let isFirstRun = prefs.maxHRMethodRaw == MaxHRMethod.tanaka.rawValue
                && prefs.maxHRAgeOverride == 0
                && prefs.maxHRManualBPM == 0
            if isFirstRun {
                prefs.maxHRMethod = MaxHRService.suggestedDefault(sex: hkSex)
            }
        }
    }

    // MARK: - Readout

    private var resolvedReadoutRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("RESOLVED MAX HR").tsEyebrow().foregroundStyle(Color.textTertiary)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("\(Int(resolvedMaxHR.rounded()))")
                        .font(AppFont.display(36))
                        .foregroundStyle(Color.accentInk)
                    Text("BPM")
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                }
                Text(prefs.maxHRMethod.detail)
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: - Age

    private var ageRow: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                Text("Age").font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if let age = resolvedAge {
                    Text("\(Int(age))")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundStyle(Color.accentInk)
                } else {
                    Text("—")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                }
                Stepper(
                    "",
                    value: Binding(
                        get: { prefs.maxHRAgeOverride },
                        set: { prefs.maxHRAgeOverride = max(0, min(120, $0)) }
                    ),
                    in: 0...120
                )
                .labelsHidden()
                .tint(.accentVolt)
            }
            if let hkAge = MaxHRService.age(from: hkBirthdate, override: 0) {
                // Only show the HealthKit hint when it's actually providing
                // data — if override is 0 we're already using this age, so
                // the hint is informational; if override > 0 it's a cue
                // that Health says otherwise.
                Text(prefs.maxHRAgeOverride == 0
                     ? "Using your Apple Health birthdate (\(Int(hkAge)) yrs)."
                     : "Apple Health reports \(Int(hkAge)). Set age to 0 to use that value.")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            } else {
                Text("Set a value above — Apple Health isn't sharing your birthdate.")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    // MARK: - Method picker

    /// Tap-selectable rows, one per MaxHRMethod. Using a list of buttons
    /// (not a `Picker`) so each row can show its formula detail without
    /// truncating and so the whole thing lays out predictably inside the
    /// card.
    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text("Method").font(AppFont.ui(15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            VStack(spacing: Space.x2) {
                ForEach(MaxHRMethod.allCases) { method in
                    methodRow(method)
                }
            }
        }
    }

    private func methodRow(_ method: MaxHRMethod) -> some View {
        let selected = prefs.maxHRMethod == method
        return Button {
            prefs.maxHRMethod = method
        } label: {
            HStack(alignment: .top, spacing: Space.x3) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentInk : Color.textTertiary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(method.label)
                            .font(AppFont.ui(14, weight: .bold))
                            .foregroundStyle(Color.textPrimary)
                        if let preview = preview(for: method) {
                            Text("· \(preview) BPM")
                                .font(AppFont.mono(12, weight: .semibold))
                                .foregroundStyle(Color.accentInk)
                        }
                    }
                    Text(method.detail)
                        .font(AppFont.ui(12, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(Space.x3)
            .background(selected ? Color.appSurface2 : Color.clear,
                        in: .rect(cornerRadius: Radius.input))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.input)
                    .stroke(selected ? Color.appBorder : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Pre-compute each method's current estimate so the picker rows tell
    /// you what they'd resolve to without forcing you to tap through each
    /// one. Nil for `observed`/`manual` when there's no input yet.
    private func preview(for method: MaxHRMethod) -> Int? {
        switch method {
        case .observed:
            return prefs.observedMaxHRBPM > 0 ? prefs.observedMaxHRBPM : nil
        case .manual:
            return prefs.maxHRManualBPM > 0 ? prefs.maxHRManualBPM : nil
        case .fox, .tanaka, .gulati, .nes:
            guard let age = resolvedAge,
                  let bpm = method.estimate(age: age) else { return nil }
            return Int(bpm.rounded())
        }
    }

    // MARK: - Manual entry

    private var manualRow: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                Text("Manual MHR").font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                TextField("190", value: Binding(
                    get: { prefs.maxHRManualBPM },
                    set: { prefs.maxHRManualBPM = max(0, min(260, $0)) }
                ), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(AppFont.mono(15, weight: .bold))
                .foregroundStyle(Color.accentInk)
                .frame(width: 64)
                Text("BPM").font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
            }
            Text("Set from a recent lab test or maximum-effort field test.")
                .font(AppFont.ui(11, weight: .medium))
                .foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: - Observed HR

    private var observedRow: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                Text("Observed max").font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text(prefs.observedMaxHRBPM > 0 ? "\(prefs.observedMaxHRBPM) BPM" : "—")
                    .font(AppFont.mono(14, weight: .semibold))
                    .foregroundStyle(Color.accentInk)
            }
            if let updated = prefs.observedMaxHRUpdatedAt {
                Text("Last refreshed \(updated, format: .relative(presentation: .named))")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            } else {
                Text("Refresh to scan Apple Health for your highest recent HR reading (last 180 days).")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
            SecondaryButton(
                title: refreshingObserved ? "Scanning…" : "Refresh from Apple Health",
                icon: "heart.circle"
            ) {
                Task { await refreshObservedMax() }
            }
        }
    }

    // MARK: - Resting HR

    /// Resting HR drives the HRR/Karvonen formula used to bucket workout
    /// HR samples into zones. When unset (0), zone math falls back to the
    /// older %-of-max convention so existing users see no change. Once
    /// set, zones align with the Apple Watch — the difference is large
    /// for users with elevated resting HRs (the lower zone bounds drift
    /// up by 20–30 BPM at typical resting values).
    private var restingRow: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                Text("Resting HR").font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                TextField("60", value: Binding(
                    get: { prefs.restingHRBPM },
                    set: {
                        prefs.restingHRBPM = max(0, min(120, $0))
                        // Manual edit clears the auto-fetch timestamp so
                        // the "refreshed N days ago" line doesn't lie.
                        prefs.restingHRUpdatedAt = nil
                    }
                ), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(AppFont.mono(15, weight: .bold))
                .foregroundStyle(Color.accentInk)
                .frame(width: 64)
                Text("BPM").font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
            }
            if prefs.restingHRBPM == 0 {
                Text("Set this to enable Karvonen / HRR zones (matches the Apple Watch). Without it, zones use the simpler %-of-max convention.")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            } else if let updated = prefs.restingHRUpdatedAt {
                Text("Auto-fetched from Apple Health \(updated, format: .relative(presentation: .named)).")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            } else {
                Text("Manually set. Karvonen / HRR zones active.")
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
            SecondaryButton(
                title: refreshingResting ? "Fetching…" : "Fetch from Apple Health",
                icon: "heart.text.square"
            ) {
                Task { await refreshRestingHR() }
            }
        }
    }

    @MainActor
    private func refreshRestingHR() async {
        guard !refreshingResting else { return }
        refreshingResting = true
        defer { refreshingResting = false }

        if !healthKit.isAuthorized {
            await healthKit.requestAuthorization()
        }
        if let result = await healthKit.fetchLatestRestingHR() {
            prefs.restingHRBPM = Int(result.bpm.rounded())
            prefs.restingHRUpdatedAt = result.date
        }
    }

    @MainActor
    private func refreshObservedMax() async {
        guard !refreshingObserved else { return }
        refreshingObserved = true
        defer { refreshingObserved = false }

        if !healthKit.isAuthorized {
            await healthKit.requestAuthorization()
        }
        if let max = await healthKit.fetchObservedMaxHR() {
            prefs.observedMaxHRBPM = Int(max.rounded())
            prefs.observedMaxHRUpdatedAt = Date()
        }
    }
}
