//
//  SigmoidParams.swift
//  WorkoutChallenge
//
//  A small value type describing the shape of the 90-day progression curve.
//  Stored as an embedded struct on UserPreferencesModel.
//

import Foundation

// `nonisolated` overrides the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
// default. Without it, the synthesized Codable conformance is inferred as
// main-actor-isolated, which Swift then refuses to use from the nonisolated
// contexts SwiftData (and JSONEncoder in general) call encoding from.
nonisolated struct SigmoidParams: Codable, Hashable, Sendable {
    /// How sharply the curve rises. Larger values = steeper transition.
    /// Web default: 0.1
    var steepness: Double

    /// The day number at which the curve is at the midpoint of min/max.
    /// Web default: 30
    var midpoint: Double

    /// Lower bound of the workout duration, in minutes.
    /// Web default: 30
    var minDuration: Double

    /// Upper bound of the workout duration, in minutes.
    /// Web default: 60
    var maxDuration: Double

    static let `default` = SigmoidParams(
        steepness: 0.1,
        midpoint: 30,
        minDuration: 30,
        maxDuration: 60
    )
}
