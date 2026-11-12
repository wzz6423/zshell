import Foundation

nonisolated enum TerminalScrollSettings {
    static let defaultMultiplier: Double = 1
    static let multiplierRange: ClosedRange<Double> = 0.1...10
    static let maximumApplicationLines = 50
    static let maximumScrollbackLines = 10_000
    static let ghosttyWheelMultiplier: Double = 3

    static func validMultiplier(_ value: Double?) -> Double {
        guard let value, value.isFinite, multiplierRange.contains(value) else { return defaultMultiplier }
        return value
    }

    static func boundedDelta(_ value: Double, limit: Double) -> Double {
        guard value.isFinite, limit.isFinite, limit > 0 else { return 0 }
        return min(max(value, -limit), limit)
    }

    // AppKit precise deltas are points. Ghostty consumes pixels and divides by
    // the pixel cell size, so the backing scale turns one point-cell into one
    // pixel-cell. Non-finite or non-positive scales fall back to 1. Wheel ticks
    // are not points and must not use this conversion.
    static func ghosttyPrecisePixels(_ points: Double, backingScale: Double) -> Double {
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        return points * scale
    }
}

nonisolated struct TerminalScrollAccumulator {
    private var remainder: Double = 0
    private var multiplier: Double = TerminalScrollSettings.defaultMultiplier

    mutating func consume(_ delta: Double, multiplier: Double, limit: Int) -> Int {
        let multiplier = TerminalScrollSettings.validMultiplier(multiplier)
        if self.multiplier != multiplier {
            remainder = 0
            self.multiplier = multiplier
        }
        guard delta.isFinite, limit > 0 else {
            remainder = 0
            return 0
        }
        guard delta != 0 else { return 0 }
        let maximum = Double(min(limit, TerminalScrollSettings.maximumScrollbackLines))
        let bounded = TerminalScrollSettings.boundedDelta(delta, limit: maximum / multiplier) * multiplier
        var total = bounded + remainder
        let nearest = total.rounded()
        // Repeated decimal wheel fractions must reach their intended whole row.
        if abs(total - nearest) <= 8 * Double.ulpOfOne * max(1, abs(total)) { total = nearest }
        let whole = total.rounded(.towardZero)
        remainder = total - whole
        // Drop excess whole rows instead of creating a backlog after a burst.
        return Int(min(max(whole, -maximum), maximum))
    }
}
