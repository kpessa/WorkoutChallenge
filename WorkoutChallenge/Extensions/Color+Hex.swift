//
//  Color+Hex.swift
//  WorkoutChallenge
//
//  Small helper to build SwiftUI Colors from hex strings ("#RRGGBB" or
//  "RRGGBB"), and to serialize a Color back to a hex string.
//

import SwiftUI

extension Color {
    /// Initialize from a hex string. Returns nil on malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else {
            return nil
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    /// Serialize to a "#RRGGBB" hex string. Returns nil if the color's RGB
    /// components can't be resolved (e.g. certain dynamic/catalog colors
    /// without a concrete value in the current trait collection).
    ///
    /// Implementation note: SwiftUI's `Color` doesn't expose RGB directly,
    /// so we bridge through `UIColor`. `getRed(_:green:blue:alpha:)` works
    /// for RGB-space colors; for pattern/catalog colors it returns false and
    /// we fall back to `nil` so the caller can substitute a default.
    func toHex() -> String? {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        let R = Int((max(0, min(1, r)) * 255).rounded())
        let G = Int((max(0, min(1, g)) * 255).rounded())
        let B = Int((max(0, min(1, b)) * 255).rounded())
        return String(format: "#%02X%02X%02X", R, G, B)
    }
}
