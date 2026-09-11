//
//  TerminalViewportMetrics.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation

struct TerminalViewportMetrics: Equatable {
    var surfaceSize: TerminalGridMetrics
    var scale: Double
}

struct TerminalRequestedGeometry: Equatable {
    var scale: Double
    var pixelWidth: UInt32
    var pixelHeight: UInt32
}

struct TerminalRequestedGeometryGate {
    private var lastGeometry: TerminalRequestedGeometry?

    mutating func shouldApply(_ geometry: TerminalRequestedGeometry) -> Bool {
        guard geometry != lastGeometry else { return false }
        lastGeometry = geometry
        return true
    }

    mutating func reset() {
        lastGeometry = nil
    }
}
