//
//  TerminalContrast.swift
//  zshell
//

/// Preserves ANSI colors unless their WCAG contrast is too low to read.
enum TerminalContrast {
    static let defaultMinimumRatio = 3.0
    static let minimumRatioRange: ClosedRange<Double> = 1...21

    static func validatedMinimumRatio(_ value: Double) -> Double {
        guard value.isFinite, minimumRatioRange.contains(value) else {
            return defaultMinimumRatio
        }
        // Both backends use the same precision as Ghostty's configuration.
        return (value * 100).rounded() / 100
    }
}
