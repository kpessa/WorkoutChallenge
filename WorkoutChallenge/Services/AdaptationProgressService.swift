//
//  AdaptationProgressService.swift
//  WorkoutChallenge
//
//  Pure-function bridge between the user's training history and the
//  static facts in `PhysiologicalAdaptation`. Produces an
//  `AdaptationProgress` per adaptation: where on the timeline they are,
//  how much stimulus they've banked toward the dose target, and the
//  proxy delta when one is measurable. The card just renders these.
//
//  Deliberately stateless and side-effect-free so it's trivially
//  testable and safe to call on every body evaluation. The classifier
//  is keyword-based on `WorkoutTypeModel.name` (loose match — see
//  `AdaptationDriver.matches(typeName:)`).
//

import Foundation

enum AdaptationProgressService {

    /// Compute progress for every adaptation in the catalog. Pass the
    /// caller's workouts (already-loaded SwiftData rows), the
    /// challenge's startDate (or earliest training date), and any
    /// resting-HR series available for proxy computation.
    static func compute(
        adaptations: [PhysiologicalAdaptation] = PhysiologicalAdaptation.allCases,
        workouts: [WorkoutModel],
        startDate: Date,
        now: Date = Date(),
        restingHRSeries: [HealthKitService.RestingHRSample] = [],
        vo2Series: [HealthKitService.VO2MaxSample] = []
    ) -> [AdaptationProgress] {
        adaptations.map { adaptation in
            compute(
                adaptation: adaptation,
                workouts: workouts,
                startDate: startDate,
                now: now,
                restingHRSeries: restingHRSeries,
                vo2Series: vo2Series
            )
        }
    }

    /// Single-adaptation compute. Public for unit tests / spot calls.
    static func compute(
        adaptation: PhysiologicalAdaptation,
        workouts: [WorkoutModel],
        startDate: Date,
        now: Date = Date(),
        restingHRSeries: [HealthKitService.RestingHRSample] = [],
        vo2Series: [HealthKitService.VO2MaxSample] = []
    ) -> AdaptationProgress {
        // Filter workouts to those that match the driver class. The
        // first qualifying workout's date anchors the timeline — if the
        // user hasn't done any matching work yet, we use `startDate` so
        // the row still renders an "accumulating" state instead of NaN.
        let qualifying = workouts.filter {
            adaptation.driver.matches(typeName: $0.workoutType?.name)
        }
        let firstStimulusDate = qualifying.map(\.date).min() ?? startDate
        let daysSinceFirst = max(0, firstStimulusDate.daysUntil(now))
        let stage = stage(daysSinceFirst: daysSinceFirst,
                          timeline: adaptation.timeline)

        let sessionCount = qualifying.count
        let totalMinutes = qualifying.reduce(0) { $0 + $1.duration }
        let doseFraction = adaptation.doseTarget.fraction(
            actualSessions: sessionCount,
            actualMinutes: totalMinutes
        )
        let doseLabel = adaptation.doseTarget.format(
            actualSessions: sessionCount,
            actualMinutes: totalMinutes
        )

        let proxy = proxyReading(
            adaptation: adaptation,
            restingHRSeries: restingHRSeries,
            vo2Series: vo2Series
        )

        let caption = caption(
            adaptation: adaptation,
            stage: stage,
            doseFraction: doseFraction,
            sessionCount: sessionCount,
            totalMinutes: totalMinutes,
            proxy: proxy
        )

        return AdaptationProgress(
            adaptation: adaptation,
            stage: stage,
            daysSinceFirstStimulus: daysSinceFirst,
            sessionCount: sessionCount,
            totalMinutes: totalMinutes,
            doseFraction: doseFraction,
            doseLabel: doseLabel,
            proxy: proxy,
            caption: caption
        )
    }

    // MARK: - Stage

    private static func stage(
        daysSinceFirst: Int,
        timeline: AdaptationTimeline
    ) -> AdaptationStage {
        if daysSinceFirst < timeline.onsetDays {
            return .accumulating
        } else if daysSinceFirst < timeline.peakDays {
            return .active
        } else if daysSinceFirst < timeline.plateauDays {
            return .matured
        } else {
            return .maintenance
        }
    }

    // MARK: - Proxy

    private static func proxyReading(
        adaptation: PhysiologicalAdaptation,
        restingHRSeries: [HealthKitService.RestingHRSample],
        vo2Series: [HealthKitService.VO2MaxSample]
    ) -> AdaptationProxyReading? {
        switch adaptation {
        case .neural:
            // No consumer signal tracks motor-unit recruitment.
            return nil
        case .mitochondrial:
            return windowDelta(values: vo2Series.map(\.value),
                               name: "VO₂Max",
                               unit: "ml/kg·min",
                               favorableDirection: .up)
        case .strokeVolume:
            return windowDelta(values: restingHRSeries.map(\.value),
                               name: "Resting HR",
                               unit: "BPM",
                               favorableDirection: .down)
        }
    }

    private static func windowDelta(
        values: [Double],
        name: String,
        unit: String,
        favorableDirection: ProxyFavorableDirection
    ) -> AdaptationProxyReading? {
        guard let first = values.first, let last = values.last else { return nil }
        let delta = last - first
        let isFavorable: Bool
        switch favorableDirection {
        case .up:   isFavorable = delta > 0.5
        case .down: isFavorable = delta < -0.5
        }
        return AdaptationProxyReading(
            name: name,
            latestValue: last,
            delta: delta,
            unit: unit,
            isFavorable: isFavorable
        )
    }

    private enum ProxyFavorableDirection { case up, down }

    // MARK: - Caption

    /// Plain-language interpretation, computed from the same inputs the
    /// row's tiles render. By construction the caption can never
    /// disagree with the visuals because they're both derived from the
    /// same fields on `AdaptationProgress`.
    private static func caption(
        adaptation: PhysiologicalAdaptation,
        stage: AdaptationStage,
        doseFraction: Double,
        sessionCount: Int,
        totalMinutes: Int,
        proxy: AdaptationProxyReading?
    ) -> String {
        // No qualifying stimulus yet — same copy across adaptations.
        if sessionCount == 0 {
            switch adaptation.driver {
            case .strength:
                return "No strength sessions logged yet. Add one and the curve starts."
            case .aerobic:
                return "No aerobic sessions logged yet. Z2 walks, runs, or rides drive this."
            }
        }

        let stagePhrase: String
        switch (adaptation, stage) {
        case (.neural, .accumulating):
            stagePhrase = "First strength sessions in — recruitment patterns starting to form."
        case (.neural, .active):
            stagePhrase = "Active phase. Most strength gains right now are neural, not muscular."
        case (.neural, .matured):
            stagePhrase = "Neural plateau approaching — further gains shift to hypertrophy."
        case (.neural, .maintenance):
            stagePhrase = "Past peak neural adaptation. Strength gains from here are sarcomere remodeling."

        case (.mitochondrial, .accumulating):
            stagePhrase = "Stimulus accumulating. Mitochondrial biogenesis kicks in around week 2."
        case (.mitochondrial, .active):
            stagePhrase = "Active phase. New mitochondria assembling, existing ones dividing."
        case (.mitochondrial, .matured):
            stagePhrase = "Substantial adaptation likely — your aerobic engine is meaningfully bigger."
        case (.mitochondrial, .maintenance):
            stagePhrase = "Mature aerobic base. Further gains come from intensity work, not more volume."

        case (.strokeVolume, .accumulating):
            stagePhrase = "Stimulus building. Resting-HR drop typically shows up by week 4."
        case (.strokeVolume, .active):
            stagePhrase = "Active phase. Left ventricle is remodeling — each beat ejecting more blood."
        case (.strokeVolume, .matured):
            stagePhrase = "Stroke volume meaningfully up — resting HR should reflect it."
        case (.strokeVolume, .maintenance):
            stagePhrase = "Mature cardiac adaptation. Maintained as long as aerobic volume continues."
        }

        // Tack on the proxy reading when we have one and it's directional.
        if let p = proxy, abs(p.delta) >= 0.5 {
            let arrow = p.isFavorable ? "in line with" : "against"
            let sign = p.delta >= 0 ? "+" : ""
            let formatted = String(format: "%.1f", p.delta)
            return "\(stagePhrase) \(p.name) is \(sign)\(formatted) \(p.unit) over the window — \(arrow) the modeled direction."
        }
        return stagePhrase
    }
}

// MARK: - Output types

/// Per-adaptation snapshot the card renders.
struct AdaptationProgress: Identifiable {
    let adaptation: PhysiologicalAdaptation
    let stage: AdaptationStage
    let daysSinceFirstStimulus: Int
    let sessionCount: Int
    let totalMinutes: Int
    /// 0 = no dose; 1.0 = hit the target; >1 = exceeded.
    let doseFraction: Double
    let doseLabel: String
    let proxy: AdaptationProxyReading?
    let caption: String

    var id: String { adaptation.id }
}

/// Where the user is on the modeled adaptation curve. Drives the row's
/// stage chip and the caption.
enum AdaptationStage: String {
    case accumulating   // pre-onset
    case active         // peak adaptation phase
    case matured        // most of the gains banked
    case maintenance    // past plateau

    var label: String {
        switch self {
        case .accumulating: return "Accumulating"
        case .active:       return "Active"
        case .matured:      return "Matured"
        case .maintenance:  return "Maintenance"
        }
    }
}

/// A measurable signal that tracks an adaptation, when one exists. Nil
/// proxies are valid (e.g. neural recruitment has no consumer-grade
/// tracker), and the card surfaces "no measurable proxy" copy.
struct AdaptationProxyReading {
    let name: String
    let latestValue: Double
    let delta: Double
    let unit: String
    /// Computed against the favorable direction for *that* signal —
    /// resting HR ↓ is favorable, VO₂Max ↑ is favorable. The card uses
    /// this to color the proxy chip.
    let isFavorable: Bool
}
