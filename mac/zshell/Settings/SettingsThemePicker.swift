//
//  SettingsThemePicker.swift
//  zshell
//

import AppKit
import GhosttyTheme

/// Appearance chooser modelled on the one in System Settings: a tappable
/// preview per option instead of a row of words.
final class SettingsThemePicker: NSView {
    private var options: [ThemeOptionCard] = []

    init(onChange: @escaping (AppTheme) -> Void) {
        super.init(frame: .zero)

        options = AppTheme.allCases.map { theme in
            ThemeOptionCard(theme: theme) { onChange(theme) }
        }

        let stack = NSStackView(views: options)
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func select(_ theme: AppTheme) {
        for option in options {
            option.isSelectedCard = option.theme == theme
        }
    }

    /// Repaints the previews after the selected color themes change: they draw
    /// the real palette, which `Theme` resolves outside this view.
    func refreshPreviews() {
        for option in options {
            option.refreshPreview()
        }
    }
}

private final class ThemeOptionCard: SettingsCardButton {
    let theme: AppTheme

    private let preview: ThemePreviewView
    private let label: NSTextField

    init(theme: AppTheme, action: @escaping () -> Void) {
        self.theme = theme
        preview = ThemePreviewView(theme: theme)
        label = NSTextField(labelWithString: theme.title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        // Without this a narrow window can squeeze a label to zero width,
        // wrapping it into blank lines that stretch one option past its
        // neighbours.
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = NSStackView(views: [preview, label])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 4

        super.init(
            content: content,
            insets: NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5),
            unselectedBorder: nil,
            accessibilityLabel: theme.title,
            action: action
        )
    }

    override func didChangeSelection() {
        label.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: isSelectedCard ? .semibold : .regular
        )
        label.textColor = isSelectedCard ? .labelColor : .secondaryLabelColor
    }

    func refreshPreview() {
        preview.needsDisplay = true
    }
}

/// A miniature zshell window painted in one appearance's real colors.
/// `system` splits down the middle — light on the left, dark on the right —
/// the same way System Settings previews "Auto".
private final class ThemePreviewView: NSView {
    private static let size = NSSize(width: 76, height: 50)
    private static let corner: CGFloat = 7
    private static let sidebarWidth: CGFloat = 22
    private static let padding: CGFloat = 5
    private static let barHeight: CGFloat = 2.5

    private let theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let clip = NSBezierPath(
            roundedRect: bounds,
            xRadius: Self.corner,
            yRadius: Self.corner
        )

        context.saveGraphicsState()
        clip.addClip()
        switch theme {
        case .light:
            drawWindow(dark: false)
        case .dark:
            drawWindow(dark: true)
        case .system:
            drawWindow(dark: false)
            context.saveGraphicsState()
            NSBezierPath(rect: NSRect(
                x: bounds.midX,
                y: 0,
                width: bounds.width / 2,
                height: bounds.height
            )).addClip()
            drawWindow(dark: true)
            context.restoreGraphicsState()
        }
        context.restoreGraphicsState()

        NSColor.labelColor.withAlphaComponent(0.15).setStroke()
        clip.lineWidth = 0.5
        clip.stroke()
    }

    private func drawWindow(dark: Bool) {
        let palette = Theme.terminal(dark: dark)
        let text = palette.foregroundNSColor
        let cursor = palette.cursorNSColor

        Theme.sidebarFill(dark: dark).setFill()
        NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: bounds.height).fill()
        palette.backgroundNSColor.setFill()
        NSRect(
            x: Self.sidebarWidth,
            y: 0,
            width: bounds.width - Self.sidebarWidth,
            height: bounds.height
        ).fill()

        // Traffic lights, then three sidebar rows.
        let dots = [0xFF5F57, 0xFEBC2E, 0x28C840]
        for (index, hex) in dots.enumerated() {
            let x = Self.padding + CGFloat(index) * (3.5 + 2.5)
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                    green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255,
                    alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: Self.padding, width: 3.5, height: 3.5)).fill()
        }
        let sidebarFaint = text.withAlphaComponent(0.35)
        for (index, width) in [CGFloat(11), 8, 11].enumerated() {
            bar(
                x: Self.padding,
                y: 14.5 + CGFloat(index) * (Self.barHeight + 3),
                width: width,
                color: sidebarFaint
            )
        }

        // A tab, then output lines: two prompts with a cursor block, and two
        // wrapped result lines between them.
        let contentX = Self.sidebarWidth + Self.padding
        text.withAlphaComponent(0.12).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: contentX, y: Self.padding, width: 14, height: 5),
            xRadius: 1.5,
            yRadius: 1.5
        ).fill()

        bar(x: contentX, y: 14.5, width: 3, color: cursor)
        bar(x: contentX + 5, y: 14.5, width: 22, color: text.withAlphaComponent(0.8))
        bar(x: contentX, y: 20.5, width: 30, color: text.withAlphaComponent(0.45))
        bar(x: contentX, y: 26.5, width: 16, color: text.withAlphaComponent(0.45))
        bar(x: contentX, y: 32.5, width: 3, color: cursor)
        bar(x: contentX + 5, y: 32.5, width: 7, color: text.withAlphaComponent(0.8))
    }

    private func bar(x: CGFloat, y: CGFloat, width: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: width, height: Self.barHeight),
            xRadius: 1,
            yRadius: 1
        ).fill()
    }
}
