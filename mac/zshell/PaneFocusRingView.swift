//
//  PaneFocusRingView.swift
//  zshell
//

import AppKit
import Combine
import SwiftUI

/// Native pane chrome kept outside either terminal backend's render path.
private final class PaneFocusRingView: NSView {
    private var isFocused: Bool
    private var showsFocusedRing: Bool
    private var focusedOpacity: Double
    private var observations: Set<AnyCancellable> = []

    override var isOpaque: Bool { false }

    init(isFocused: Bool) {
        self.isFocused = isFocused
        showsFocusedRing = AppSettings.shared.showPaneFocusRing
        focusedOpacity = AppSettings.shared.paneFocusRingOpacity
        super.init(frame: .zero)
        setAccessibilityElement(false)
        observeAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setFocused(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
        needsDisplay = true
    }

    private func observeAppearance() {
        AppSettings.shared.$showPaneFocusRing
            .combineLatest(AppSettings.shared.$paneFocusRingOpacity)
            .dropFirst()
            .sink { [weak self] showsFocusedRing, focusedOpacity in
                self?.showsFocusedRing = showsFocusedRing
                self?.focusedOpacity = focusedOpacity
                self?.needsDisplay = true
            }
            .store(in: &observations)
        Theme.changes.objectWillChange
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &observations)
    }

    override func draw(_ dirtyRect: NSRect) {
        let drawsAccent = isFocused && showsFocusedRing
        let lineWidth: CGFloat = drawsAccent ? 1.5 : 1
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            xRadius: 6,
            yRadius: 6
        )
        path.lineWidth = lineWidth
        (drawsAccent
            ? Theme.accent.withAlphaComponent(focusedOpacity)
            : NSColor.labelColor.withAlphaComponent(0.06)
        ).setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

struct PaneFocusRing: NSViewRepresentable {
    let isFocused: Bool

    func makeNSView(context: Context) -> NSView {
        PaneFocusRingView(isFocused: isFocused)
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? PaneFocusRingView)?.setFocused(isFocused)
    }
}
