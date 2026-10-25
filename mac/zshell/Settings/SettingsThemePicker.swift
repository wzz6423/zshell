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
        stack.distribution = .fillEqually
        stack.spacing = 14
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
        label.alignment = .center
        // Long translations must not stretch one option past its neighbours.
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [preview, label])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 8

        let previewWidth = preview.widthAnchor.constraint(equalTo: content.widthAnchor)
        previewWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            previewWidth,
            label.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])

        super.init(
            content: content,
            insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10),
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
        label.textColor = isSelectedCard ? .controlAccentColor : .secondaryLabelColor
    }

    func refreshPreview() {
        preview.needsDisplay = true
    }
}

/// A miniature zshell window painted in one appearance's real colors.
/// `system` shows both palettes so it stays distinct from either fixed appearance.
private final class ThemePreviewView: NSView {
    private static let size = NSSize(width: 160, height: 76)
    private static let corner: CGFloat = 7
    private static let sidebarWidth: CGFloat = 40
    private static let titlebarHeight: CGFloat = 17
    private static let padding: CGFloat = 8
    private static let barHeight: CGFloat = 3

    private let theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.size.width),
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
            let darkHalf = NSBezierPath()
            darkHalf.move(to: NSPoint(x: bounds.maxX, y: bounds.minY))
            darkHalf.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
            darkHalf.line(to: NSPoint(x: bounds.minX, y: bounds.maxY))
            darkHalf.close()
            darkHalf.addClip()
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

        Theme.application(dark: dark).surfaceNSColor(elevation: 0.08).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.titlebarHeight).fill()

        let dots = [0xFF5F57, 0xFEBC2E, 0x28C840]
        for (index, hex) in dots.enumerated() {
            let x = Self.padding + CGFloat(index) * 7
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                    green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255,
                    alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 6, width: 4.5, height: 4.5)).fill()
        }
        let sidebarFaint = text.withAlphaComponent(0.35)
        for (index, width) in [CGFloat(22), 16, 22].enumerated() {
            bar(
                x: Self.padding,
                y: 26 + CGFloat(index) * (Self.barHeight + 5),
                width: width,
                color: sidebarFaint
            )
        }

        let contentX = Self.sidebarWidth + Self.padding
        let contentWidth = max(0, bounds.width - contentX - Self.padding)
        text.withAlphaComponent(0.12).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: contentX, y: 5, width: contentWidth * 0.35, height: 7),
            xRadius: 1.5,
            yRadius: 1.5
        ).fill()

        bar(x: contentX, y: 26, width: 4, color: cursor)
        bar(x: contentX + 7, y: 26, width: contentWidth * 0.45, color: text.withAlphaComponent(0.8))
        bar(x: contentX, y: 35, width: contentWidth * 0.65, color: text.withAlphaComponent(0.45))
        bar(x: contentX, y: 44, width: contentWidth * 0.4, color: text.withAlphaComponent(0.45))
        bar(x: contentX, y: 53, width: 4, color: cursor)
        bar(x: contentX + 7, y: 53, width: contentWidth * 0.2, color: text.withAlphaComponent(0.8))
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
