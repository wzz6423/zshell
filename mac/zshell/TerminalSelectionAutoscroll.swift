//
//  TerminalSelectionAutoscroll.swift
//  zshell
//

import CoreGraphics

enum TerminalSelectionAutoscrollDirection: Equatable {
    case towardTop
    case towardBottom

    private static let edgeInset: CGFloat = 16

    init?(locationY: CGFloat, bounds: CGRect) {
        guard !bounds.isEmpty else { return nil }
        let inset = min(Self.edgeInset, bounds.height / 2)
        if locationY >= bounds.maxY - inset {
            self = .towardTop
        } else if locationY <= bounds.minY + inset {
            self = .towardBottom
        } else {
            return nil
        }
    }
}
