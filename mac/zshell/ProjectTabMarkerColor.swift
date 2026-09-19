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
    static let chromePresetColors = [
        ProjectTabMarkerColor(hex: "5F6369")!,
        ProjectTabMarkerColor(hex: "1A74E8")!,
        ProjectTabMarkerColor(hex: "D93025")!,
        ProjectTabMarkerColor(hex: "F9AC02")!,
        ProjectTabMarkerColor(hex: "1A8039")!,
        ProjectTabMarkerColor(hex: "D01784")!,
        ProjectTabMarkerColor(hex: "A142F5")!,
        ProjectTabMarkerColor(hex: "027B84")!,
        ProjectTabMarkerColor(hex: "FA903E")!,
    ]

    let hex: String

    nonisolated init?(hex rawValue: String) {
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
/// representable. The active project, tab, or group receives color changes.
@MainActor
final class ProjectTabColorPanelController: NSObject {
    static let shared = ProjectTabColorPanelController()

    private var applyColor: ((ProjectTabMarkerColor) -> Void)?
    private lazy var chromePalette = ChromeColorPaletteView { [weak self] color in
        self?.selectChromeColor(color)
    }

    func present(project: Project, hostWindow: NSWindow? = nil) {
        present(
            markerColor: project.markerColor,
            apply: { [weak project] color in
                project?.markerColor = color
            },
            hostWindow: hostWindow,
            showsChromePresets: false
        )
    }

    func present(tab: PaneTab, hostWindow: NSWindow? = nil) {
        present(
            markerColor: tab.markerColor,
            apply: { [weak tab] color in
                tab?.markerColor = color
            },
            hostWindow: hostWindow,
            showsChromePresets: false
        )
    }

    func present(
        group: ProjectGroup,
        apply: @escaping (ProjectTabMarkerColor) -> Void,
        hostWindow: NSWindow? = nil
    ) {
        present(
            markerColor: group.markerColor,
            apply: apply,
            hostWindow: hostWindow,
            showsChromePresets: true
        )
    }

    func present(
        tabGroup: SessionTabGroup,
        apply: @escaping (ProjectTabMarkerColor) -> Void,
        hostWindow: NSWindow? = nil
    ) {
        present(
            markerColor: tabGroup.markerColor,
            apply: apply,
            hostWindow: hostWindow,
            showsChromePresets: true
        )
    }

    private func present(
        markerColor: ProjectTabMarkerColor?,
        apply: @escaping (ProjectTabMarkerColor) -> Void,
        hostWindow: NSWindow?,
        showsChromePresets: Bool
    ) {
        let initialColor = markerColor ?? .defaultColor
        guard let host = AppWindowPresentation.hostWindow(relativeTo: hostWindow) else { return }
        applyColor = apply

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = initialColor.nsColor
        if showsChromePresets {
            chromePalette.select(initialColor)
            panel.accessoryView = chromePalette
            let contentSize = panel.contentView?.bounds.size ?? .zero
            if contentSize.width < chromePalette.intrinsicContentSize.width {
                panel.setContentSize(NSSize(
                    width: chromePalette.intrinsicContentSize.width,
                    height: contentSize.height
                ))
            }
        } else {
            panel.accessoryView = nil
        }
        panel.setTarget(self)
        panel.setAction(#selector(colorDidChange(_:)))
        AppWindowPresentation.attach(panel, to: host, placement: .centered)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorDidChange(_ sender: NSColorPanel) {
        guard let color = ProjectTabMarkerColor(nsColor: sender.color) else { return }
        chromePalette.select(color)
        applyColor?(color)
    }

    private func selectChromeColor(_ color: ProjectTabMarkerColor) {
        let panel = NSColorPanel.shared
        panel.color = color.nsColor
        chromePalette.select(color)
        applyColor?(color)
    }
}

private final class ChromeColorPaletteView: NSView {
    private static let buttonSize: CGFloat = 40
    private static let spacing: CGFloat = 8
    private static let horizontalInset: CGFloat = 12

    private let buttons: [ChromeColorSwatchButton]

    init(onSelect: @escaping (ProjectTabMarkerColor) -> Void) {
        buttons = ProjectTabMarkerColor.chromePresetColors.map { color in
            ChromeColorSwatchButton(color: color, action: onSelect)
        }
        super.init(frame: .zero)
        frame.size = intrinsicContentSize
        for button in buttons { addSubview(button) }
        layout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.horizontalInset * 2
                + CGFloat(buttons.count) * Self.buttonSize
                + CGFloat(max(0, buttons.count - 1)) * Self.spacing,
            height: Self.buttonSize
        )
    }

    override func layout() {
        super.layout()
        var x = Self.horizontalInset
        for button in buttons {
            button.frame = NSRect(x: x, y: 0, width: Self.buttonSize, height: Self.buttonSize)
            x += Self.buttonSize + Self.spacing
        }
    }

    func select(_ color: ProjectTabMarkerColor) {
        for button in buttons {
            button.isSelectedSwatch = button.color == color
        }
    }
}

private final class ChromeColorSwatchButton: NSButton {
    let color: ProjectTabMarkerColor
    var isSelectedSwatch = false {
        didSet {
            guard oldValue != isSelectedSwatch else { return }
            needsDisplay = true
            setAccessibilityValue(isSelectedSwatch ? String(localized: "Selected") : "")
        }
    }

    init(color: ProjectTabMarkerColor, action: @escaping (ProjectTabMarkerColor) -> Void) {
        self.color = color
        onSelect = action
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(invokeAction)
        toolTip = color.displayValue
        setAccessibilityLabel(color.displayValue)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var onSelect: (ProjectTabMarkerColor) -> Void

    @objc private func invokeAction() {
        onSelect(color)
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = bounds.midX
        let diameter = min(bounds.width, bounds.height)
        if isSelectedSwatch {
            let outer = NSRect(
                x: center - diameter / 2 + 2,
                y: bounds.midY - diameter / 2 + 2,
                width: diameter - 4,
                height: diameter - 4
            )
            color.nsColor.setStroke()
            let outerRing = NSBezierPath(ovalIn: outer)
            outerRing.lineWidth = 2
            outerRing.stroke()

            let halo = outer.insetBy(dx: 3, dy: 3)
            NSColor.white.setStroke()
            let haloRing = NSBezierPath(ovalIn: halo)
            haloRing.lineWidth = 2
            haloRing.stroke()

            color.nsColor.setFill()
            NSBezierPath(ovalIn: halo.insetBy(dx: 2, dy: 2)).fill()
        } else {
            color.nsColor.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5)).fill()
        }
    }
}
