//
//  PhysiologicalAdaptation.swift
//  WorkoutChallenge
//
//  Static-facts catalog of training adaptations the app surfaces in the
//  Progress tab. The Watch can't measure mitochondrial density or motor-
//  unit recruitment directly — these are *modeled* from time + stimulus,
//  with the closest measurable proxy noted where one exists. The card
//  copy leans into that explicitly so the educational read ("here's
//  what's happening inside your body during a challenge") stays honest.
//
//  Each adaptation declares:
//    • mechanism — the one-paragraph teaching moment
//    • timeline — onset / active / plateau weeks
//    • stimulus — what kind of training drives it (strength vs aerobic)
//    • doseTarget — total minutes/sessions that mark "substantial dose"
//    • measurableProxy — name of the HK signal that tracks it (or nil)
//
//  Progress per-user is computed in `AdaptationProgressService` from
//  these facts plus their workout history.
//

import Foundation

/// One of the named adaptations the card surfaces. Cases (not strings)
/// so callers get exhaustiveness checks; the static `catalog` returns
/// the first three the user picked to ship — Neural / Mitochondrial /
/// Stroke volume — covering fast / medium / slow timescales.
enum PhysiologicalAdaptation: String, CaseIterable, Identifiable {
    case neural
    case mitochondrial
    case strokeVolume

    var id: String { rawValue }

    /// Short title for the row header.
    var title: String {
        switch self {
        case .neural:        return "Neural recruitment"
        case .mitochondrial: return "Mitochondrial density"
        case .strokeVolume:  return "Stroke volume"
        }
    }

    /// Compact tagline for the collapsed row state. One sentence.
    var tagline: String {
        switch self {
        case .neural:
            return "Your nervous system learning to fire muscle fibers harder, faster, in better sync."
        case .mitochondrial:
            return "More mitochondria per muscle fiber → more aerobic ATP at the same effort."
        case .strokeVolume:
            return "Heart's left ventricle expands so each beat pumps more blood — why resting HR drops."
        }
    }

    /// The teaching paragraph — shown when the row is expanded.
    /// Calibrated to "I learned this in a muscle/exercise physiology
    /// class" register: technical-but-not-jargon-heavy, names the
    /// mechanism, says what it feels like.
    var mechanism: String {
        switch self {
        case .neural:
            return "For roughly the first three to five weeks, most of your strength gain is neural, not muscular — the classic Moritani & deVries finding. Motor-unit recruitment improves (you fire more fibers per contraction), rate coding rises (each motor neuron fires faster), and intermuscular coordination tightens. With a novel, skill-heavy activity, plain motor learning adds to it. Measurable muscle growth comes later — and some of the earliest size change is fluid, not fiber. It's why beginners get stronger fast on the same body, and why a week off barely touches strength."
        case .mitochondrial:
            return "Sustained aerobic work — especially Z2 — triggers mitochondrial biogenesis via the PGC-1α pathway. Existing mitochondria divide; new ones get assembled. More mitochondria means more capacity to oxidize fat and pyruvate, raising the workload your body can sustain aerobically. This is the slow, steady adaptation that builds genuine endurance, and it's largely invisible in the first month — but compounds for years."
        case .strokeVolume:
            return "Endurance training causes eccentric cardiac hypertrophy: the left ventricle's chamber enlarges so each beat ejects more blood. Output goes up at the same heart rate, so resting HR drops and submaximal HR drops at the same pace. Unlike concentric (pressure-overload) hypertrophy from heavy lifting, endurance enlarges the chamber rather than thickening the wall. The resting-HR signal is the cleanest at-home measurement of this."
        }
    }

    /// Driver class — used by the progress service to count the right
    /// kind of workout against this adaptation's dose meter.
    var driver: AdaptationDriver {
        switch self {
        case .neural:        return .strength
        case .mitochondrial: return .aerobic
        case .strokeVolume:  return .aerobic
        }
    }

    /// Onset / active / plateau windows in *days since first qualifying
    /// stimulus*. Used to pick the stage label and color the row.
    /// Numbers come from textbook ranges in standard exercise-physiology
    /// references — Wilmore & Costill, Powers & Howley — rounded for
    /// legibility. They're approximate by design.
    var timeline: AdaptationTimeline {
        switch self {
        case .neural:
            // Fast: most gains in weeks 1–4, then hypertrophy takes over.
            return AdaptationTimeline(onsetDays: 7, peakDays: 14, plateauDays: 28)
        case .mitochondrial:
            // Medium: detectable by week 2, substantial by week 8–12.
            return AdaptationTimeline(onsetDays: 14, peakDays: 56, plateauDays: 84)
        case .strokeVolume:
            // Medium-fast: resting-HR drop typically visible by week 4.
            return AdaptationTimeline(onsetDays: 14, peakDays: 28, plateauDays: 56)
        }
    }

    /// Total dose of qualifying stimulus that marks "substantial." Used
    /// to scale the dose meter 0–1. Hours for aerobic adaptations,
    /// session count for neural (strength).
    var doseTarget: AdaptationDose {
        switch self {
        case .neural:        return .sessions(target: 8)
        case .mitochondrial: return .hours(target: 25)
        case .strokeVolume:  return .hours(target: 20)
        }
    }

    /// Measurable HK proxy for this adaptation, when one exists. Nil
    /// for neural — there's no consumer signal that tracks motor-unit
    /// recruitment. The card copy says so explicitly when nil.
    var measurableProxy: String? {
        switch self {
        case .neural:        return nil
        case .mitochondrial: return "VO₂Max trend"
        case .strokeVolume:  return "Resting HR trend"
        }
    }
}

/// What kind of stimulus drives the adaptation. Maps to a heuristic
/// classifier over `WorkoutTypeModel.name` (we don't store HK activity
/// type on local workouts, so we keyword-match the user-set name).
enum AdaptationDriver {
    case strength
    case aerobic

    /// True when the workout type's name contains a keyword matching
    /// this driver class. Kept loose intentionally — users name types
    /// freely, and a forgiving match is better than a brittle exact one.
    func matches(typeName: String?) -> Bool {
        guard let name = typeName?.lowercased() else { return false }
        switch self {
        case .strength:
            return AdaptationDriver.isStrengthName(name)
        case .aerobic:
            // Aerobic is the DEFAULT bucket for any movement that isn't
            // clearly strength or clearly non-cardio. Keyword lists are
            // brittle — users name types freely ("Rollerblading", "Zone
            // 2", "Peloton", "Outdoor Skate") and a fixed list will
            // always miss something, silently dropping real training
            // from the adaptation cards. So: a name that explicitly
            // reads as cardio counts; otherwise anything that isn't
            // strength or an explicit non-cardio activity (yoga, mobility,
            // rest) also counts.
            if Self.aerobicKeywords.contains(where: { name.contains($0) }) {
                return true
            }
            if Self.isStrengthName(name) { return false }
            if Self.nonCardioKeywords.contains(where: { name.contains($0) }) {
                return false
            }
            return true
        }
    }

    /// Explicit cardio names — fast path, also documents intent.
    private static let aerobicKeywords = [
        "run", "jog", "walk", "hike", "bike", "cycl", "swim", "row",
        "elliptical", "cardio", "treadmill", "climb", "stair", "spin",
        "skate", "skating", "blade", "rollerblad", "inline", "ski",
        "dance", "boxing", "kickbox", "jump rope", "jumprope", "hiit",
        "interval", "soccer", "basketball", "tennis", "pickleball",
        "paddle", "kayak", "sport"
    ]

    /// Names that should NOT count as aerobic stimulus even though they
    /// aren't strength — low cardiovascular demand.
    private static let nonCardioKeywords = [
        "yoga", "stretch", "flexibility", "mobility", "pilates",
        "meditat", "breath", "rest", "recovery", "cooldown", "warmup",
        "warm up", "cool down"
    ]

    private static func isStrengthName(_ name: String) -> Bool {
        let kw = ["strength", "weight", "lift", "resistance",
                  "barbell", "dumbbell", "bodyweight", "calisthenics",
                  "powerlifting", "crossfit"]
        return kw.contains(where: { name.contains($0) })
    }
}

/// The phase windows for an adaptation, expressed in days since the
/// user's first qualifying workout.
struct AdaptationTimeline: Equatable {
    let onsetDays: Int      // before this: "stimulus accumulating"
    let peakDays: Int       // before this: "adaptation actively happening"
    let plateauDays: Int    // after peakDays, before plateauDays: "matured"
                            // after plateauDays: "plateau / maintenance"
}

/// "How much stimulus is enough?" — used to render a 0–1 dose meter.
/// Sessions for neural (where each rep-heavy session has a discrete
/// effect), hours for aerobic (where total time-under-tension is the
/// driver).
enum AdaptationDose: Equatable {
    case sessions(target: Int)
    case hours(target: Double)

    /// Normalize an actual dose against the target → 0…1+. Uncapped at
    /// the upper end so callers can tell "well past the target" from
    /// "just hit it" if they want.
    func fraction(actualSessions: Int, actualMinutes: Int) -> Double {
        switch self {
        case .sessions(let target):
            guard target > 0 else { return 0 }
            return Double(actualSessions) / Double(target)
        case .hours(let target):
            guard target > 0 else { return 0 }
            return (Double(actualMinutes) / 60.0) / target
        }
    }

    /// Human-readable rendering of "actual / target", used in the dose
    /// meter sublabel. Sessions and hours render differently.
    func format(actualSessions: Int, actualMinutes: Int) -> String {
        switch self {
        case .sessions(let target):
            return "\(actualSessions) / \(target) sessions"
        case .hours(let target):
            let actualHours = Double(actualMinutes) / 60.0
            return String(format: "%.1f / %.0f hours", actualHours, target)
        }
    }
}
