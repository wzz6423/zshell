//
//  TerminalContrast.swift
//  zshell
//

/// Preserves ANSI colors unless their WCAG contrast is too low to read.
enum TerminalContrast {
    static let minimumRatio = 3.0
}
