//
//  ProjectTabMarkerColor.swift
//  zshell
//

import AppKit
import Foundation

/// An opaque sRGB color used by project and tab markers. The normalized hex
/// value is the persistence boundary, keeping snapshots independent of AppKit
/// archive formats.
struct ProjectTabMarkerColor: Equatable, Sendable {
    static let defaultColor = ProjectTabMarkerColor(hex: "0A84FF")!

    let hex: String

    init?(hex rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard value.count == 6, UInt64(value, radix: 16) != nil else { return nil }
        hex = value.uppercased()
    }

    init?(nsColor: NSColor) {
        guard let color = nsColor.usingColorSpace(.sRGB) else { return nil }
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
            .map { Int((min(max($0, 0), 1) * 255).rounded()) }
        hex = components.map { String(format: "%02X", $0) }.joined()
    }

    var nsColor: NSColor {
        let value = UInt64(hex, radix: 16)!
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var displayValue: String { "#\(hex)" }
}

/// Owns the shared AppKit color panel without introducing another SwiftUI
/// representable. The active project or tab receives continuous color changes.
@MainActor
final class ProjectTabColorPanelController: NSObject {
    static let shared = ProjectTabColorPanelController()

    private var applyColor: ((ProjectTabMarkerColor) -> Void)?

    func present(project: Project) {
        present(markerColor: project.markerColor) { [weak project] color in
            project?.markerColor = color
        }
    }

    func present(tab: PaneTab) {
        present(markerColor: tab.markerColor) { [weak tab] color in
            tab?.markerColor = color
        }
    }

    private func present(
        markerColor: ProjectTabMarkerColor?,
        apply: @escaping (ProjectTabMarkerColor) -> Void
    ) {
        let initialColor = markerColor ?? .defaultColor
        applyColor = apply

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = initialColor.nsColor
        panel.setTarget(self)
        panel.setAction(#selector(colorDidChange(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorDidChange(_ sender: NSColorPanel) {
        guard let color = ProjectTabMarkerColor(nsColor: sender.color) else { return }
        applyColor?(color)
    }
}
