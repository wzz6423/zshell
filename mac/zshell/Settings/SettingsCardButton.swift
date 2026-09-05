//
//  SettingsCardButton.swift
//  zshell
//

import AppKit

/// A card the user picks by clicking — the selection model the Appearance and
/// Backend rows share.
///
/// The selection chrome is drawn here rather than delegated to a cell, because
/// what sits inside a card is arbitrary (a window preview; an icon over a
/// feature list) while the control still has to read and behave as a radio
/// button.
class SettingsCardButton: NSButton {
    private static let corner: CGFloat = 10

    private let unselectedBorderColor: NSColor?
    private let handler: () -> Void

    /// Whether this card is the chosen one. Named apart from `NSButton.state`,
    /// which stays untouched: the cell never draws.
    var isSelectedCard = false {
        didSet {
            guard isSelectedCard != oldValue else { return }
            needsDisplay = true
            didChangeSelection()
            setAccessibilityValue(isSelectedCard)
        }
    }

    /// - Parameters:
    ///   - content: The card's interior, pinned inside `insets`.
    ///   - unselectedBorder: Hairline drawn while unselected, or nil for none.
    init(
        content: NSView,
        insets: NSEdgeInsets,
        unselectedBorder: NSColor?,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        unselectedBorderColor = unselectedBorder
        handler = action
        super.init(frame: .zero)

        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(invoke)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(false)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Hook for cards whose content restyles itself with the selection.
    func didChangeSelection() {}

    override func draw(_ dirtyRect: NSRect) {
        // No super call: NSButtonCell would paint a bezel over the card.
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: Self.corner,
            yRadius: Self.corner
        )
        if isSelectedCard {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        } else if let unselectedBorderColor {
            unselectedBorderColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds,
            xRadius: Self.corner,
            yRadius: Self.corner
        ).fill()
    }

    @objc private func invoke() {
        handler()
    }
}
