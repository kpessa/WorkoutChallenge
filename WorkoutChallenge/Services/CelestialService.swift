//
//  CelestialService.swift
//  WorkoutChallenge
//
//  The astronomical math that powers the "Celestial" layer: moon phase,
//  sunrise / sunset, and the next equinox or solstice. All calculations are
//  pure functions of a `Date` (+ a coordinate for sun times), so the
//  service is trivially testable and side-effect free.
//
//  Sunrise/sunset uses a compact form of the NOAA sunrise-equation (same
//  algorithm the US Naval Observatory publishes). Accurate to within ~1min
//  for most latitudes, which is well inside "ambient header strip"
//  tolerance. For high-latitude polar day / polar night the service returns
//  `nil` for both rise and set.
//
//  Location: Phase 1 uses a hard-coded Austin, TX fallback matching the
//  design spec. A CoreLocation opt-in is a valid Phase 2 follow-up.
//

import Foundation

enum CelestialService {

    // MARK: - Defaults

    /// Austin, TX — the design-spec fallback when the app has no location.
    /// 30.2672°N, 97.7431°W.
    static let defaultCoordinate = Coordinate(latitude: 30.2672, longitude: -97.7431)

    struct Coordinate: Equatable, Hashable {
        let latitude: Double
        let longitude: Double
    }

    // MARK: - Moon phase

    /// Eight named states per the Design Meld tokens (Section 09 · Celestial).
    /// The render logic decides how to draw each from a single fraction.
    enum MoonPhase: String, CaseIterable {
        case new
        case waxingCrescent
        case firstQuarter
        case waxingGibbous
        case full
        case waningGibbous
        case lastQuarter
        case waningCrescent

        /// Human-readable label (for "Waxing gibbous · 89%" etc.)
        var label: String {
            switch self {
            case .new:             return String(localized: "New moon", comment: "MoonPhase label")
            case .waxingCrescent:  return String(localized: "Waxing crescent", comment: "MoonPhase label")
            case .firstQuarter:    return String(localized: "First quarter", comment: "MoonPhase label")
            case .waxingGibbous:   return String(localized: "Waxing gibbous", comment: "MoonPhase label")
            case .full:            return String(localized: "Full moon", comment: "MoonPhase label")
            case .waningGibbous:   return String(localized: "Waning gibbous", comment: "MoonPhase label")
            case .lastQuarter:     return String(localized: "Last quarter", comment: "MoonPhase label")
            case .waningCrescent:  return String(localized: "Waning crescent", comment: "MoonPhase label")
            }
        }
    }

    /// Lunar cycle length (synodic month, days).
    private static let synodicMonth = 29.530588853

    /// Julian date of the reference new moon: 2000-01-06 18:14 UTC.
    private static let referenceNewMoonJD = 2_451_550.1

    /// Fraction (0..<1) of the current synodic cycle. 0 = new, 0.5 = full.
    static func moonPhaseFraction(on date: Date) -> Double {
        let jd = julianDate(from: date)
        let days = jd - referenceNewMoonJD
        let f = days.truncatingRemainder(dividingBy: synodicMonth) / synodicMonth
        return f < 0 ? f + 1 : f
    }

    /// Illuminated fraction (0..1) — 0 at new, 1 at full.
    /// Uses a cosine approximation which is what eyes perceive anyway.
    static func moonIllumination(on date: Date) -> Double {
        let f = moonPhaseFraction(on: date)
        return (1 - cos(2 * .pi * f)) / 2
    }

    /// Classify the phase fraction into one of the eight named states.
    /// Bucket boundaries are ±1/16 around each of the four cardinal points
    /// (new/first-q/full/last-q), giving crescent/gibbous the remaining
    /// bands. This matches the glyph set in Design Meld § Section 09.
    static func moonPhase(on date: Date) -> MoonPhase {
        let f = moonPhaseFraction(on: date)
        switch f {
        case ..<0.0625:  return .new
        case ..<0.1875:  return .waxingCrescent
        case ..<0.3125:  return .firstQuarter
        case ..<0.4375:  return .waxingGibbous
        case ..<0.5625:  return .full
        case ..<0.6875:  return .waningGibbous
        case ..<0.8125:  return .lastQuarter
        case ..<0.9375:  return .waningCrescent
        default:         return .new
        }
    }

    // MARK: - Sunrise / sunset

    /// Local sunrise and sunset for a given date & coordinate, or `nil` at
    /// the poles during polar day / polar night. Returns `Date` in the
    /// system's current time zone so callers can format with
    /// `.formatted(date:time:)` directly.
    static func sunriseSunset(
        on date: Date,
        at coordinate: Coordinate = defaultCoordinate
    ) -> (sunrise: Date, sunset: Date)? {
        // NOAA sunrise equation — see https://en.wikipedia.org/wiki/Sunrise_equation.
        let lat = coordinate.latitude
        let lon = coordinate.longitude

        // Step 1: Julian day at local noon (integer).
        let jd = julianDayNumber(from: date)
        let n = Double(jd) - 2_451_545.0 + 0.0008

        // Step 2: mean solar noon at longitude.
        let jStar = n - (lon / 360.0)

        // Step 3: solar mean anomaly (degrees).
        let m = (357.5291 + 0.98560028 * jStar).truncatingRemainder(dividingBy: 360.0)
        let mRad = m * .pi / 180.0

        // Step 4: equation of center.
        let c = 1.9148 * sin(mRad) + 0.0200 * sin(2 * mRad) + 0.0003 * sin(3 * mRad)

        // Step 5: ecliptic longitude.
        let lambda = (m + c + 180.0 + 102.9372).truncatingRemainder(dividingBy: 360.0)
        let lambdaRad = lambda * .pi / 180.0

        // Step 6: solar transit (Julian Date of local noon).
        let jTransit = 2_451_545.0 + jStar + 0.0053 * sin(mRad) - 0.0069 * sin(2 * lambdaRad)

        // Step 7: declination of the sun.
        let sinDelta = sin(lambdaRad) * sin(23.4397 * .pi / 180.0)
        let cosDelta = cos(asin(sinDelta))

        // Step 8: hour angle (with -0.83° for atmospheric refraction + disk).
        let latRad = lat * .pi / 180.0
        let numerator = sin(-0.83 * .pi / 180.0) - sin(latRad) * sinDelta
        let denominator = cos(latRad) * cosDelta
        let cosOmega = numerator / denominator

        // Polar day / polar night — sun never rises or never sets.
        guard cosOmega >= -1, cosOmega <= 1 else { return nil }
        let omega = acos(cosOmega) * 180.0 / .pi

        let jRise = jTransit - omega / 360.0
        let jSet = jTransit + omega / 360.0

        return (dateFromJulianDate(jRise), dateFromJulianDate(jSet))
    }

    // MARK: - Equinox / solstice

    enum SolarEvent: String, CaseIterable {
        case springEquinox
        case summerSolstice
        case autumnEquinox
        case winterSolstice

        /// Short label used in the celestial strip, e.g. "Summer".
        var shortLabel: String {
            switch self {
            case .springEquinox:  return String(localized: "Spring", comment: "SolarEvent shortLabel")
            case .summerSolstice: return String(localized: "Summer", comment: "SolarEvent shortLabel")
            case .autumnEquinox:  return String(localized: "Fall", comment: "SolarEvent shortLabel")
            case .winterSolstice: return String(localized: "Winter", comment: "SolarEvent shortLabel")
            }
        }
    }

    /// The next equinox or solstice on or after `date`. Uses approximate
    /// UTC dates (March 20 / June 21 / Sept 22 / Dec 21) — fine for
    /// "N days until Summer"-style display. Within ±1 day of the real
    /// event in any given year through 2050.
    static func nextSolarEvent(from date: Date) -> (date: Date, kind: SolarEvent) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let year = cal.component(.year, from: date)

        let candidates: [(SolarEvent, DateComponents)] = [
            (.springEquinox,  DateComponents(year: year, month: 3, day: 20)),
            (.summerSolstice, DateComponents(year: year, month: 6, day: 21)),
            (.autumnEquinox,  DateComponents(year: year, month: 9, day: 22)),
            (.winterSolstice, DateComponents(year: year, month: 12, day: 21)),
            // Roll over to next year so we always have an answer.
            (.springEquinox,  DateComponents(year: year + 1, month: 3, day: 20))
        ]

        let today = Calendar.current.startOfDay(for: date)
        for (kind, comps) in candidates {
            if let d = cal.date(from: comps),
               Calendar.current.startOfDay(for: d) >= today {
                return (d, kind)
            }
        }
        // Theoretically unreachable — the list spans into next year.
        return (date, .springEquinox)
    }

    // MARK: - Julian date helpers

    /// Julian Date (continuous) for an arbitrary instant. Used for moon
    /// phase, which needs time-of-day precision.
    private static func julianDate(from date: Date) -> Double {
        // Unix epoch (1970-01-01 00:00 UTC) = JD 2440587.5.
        return date.timeIntervalSince1970 / 86_400.0 + 2_440_587.5
    }

    /// Julian Day Number (integer) at noon UTC of the given date —
    /// what the NOAA sunrise equation consumes in step 1.
    private static func julianDayNumber(from date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return 0 }

        // Standard Gregorian calendar → JDN conversion.
        let a = (14 - m) / 12
        let yy = y + 4800 - a
        let mm = m + 12 * a - 3
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32_045
    }

    /// Inverse of `julianDate(from:)` — `Date` for a continuous JD.
    private static func dateFromJulianDate(_ jd: Double) -> Date {
        Date(timeIntervalSince1970: (jd - 2_440_587.5) * 86_400.0)
    }
}
