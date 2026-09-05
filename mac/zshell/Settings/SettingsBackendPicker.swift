//
//  SettingsBackendPicker.swift
//  zshell
//

import AppKit

/// Keeps every available engine visible, following the same selection model as
/// the Appearance cards while leaving room for capability differences.
final class SettingsBackendPicker: NSView {
    private var options: [BackendOptionCard] = []

    init(onChange: @escaping (TerminalBackend) -> Void) {
        super.init(frame: .zero)

        options = TerminalBackend.selectable.map { backend in
            BackendOptionCard(backend: backend) { onChange(backend) }
        }

        let stack = NSStackView(views: options)
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 310),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func select(_ backend: TerminalBackend) {
        for option in options {
            option.isSelectedCard = option.backend == backend
        }
    }
}

private final class BackendOptionCard: SettingsCardButton {
    let backend: TerminalBackend

    init(backend: TerminalBackend, action: @escaping () -> Void) {
        self.backend = backend

        let icon = NSImageView(image: NSImage(named: backend.settingsIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])

        let name = NSTextField(labelWithString: backend.displayName)
        name.font = .systemFont(ofSize: NSFont.systemFontSize)

        let header = NSStackView(views: [icon, name])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let highlights = NSStackView(views: backend.settingsHighlights.map { BackendHighlightView(highlight: $0) })
        highlights.orientation = .vertical
        highlights.alignment = .leading
        highlights.spacing = 3
        highlights.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0)

        let content = NSStackView(views: [header, highlights])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4

        super.init(
            content: content,
            insets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8),
            unselectedBorder: NSColor.labelColor.withAlphaComponent(0.12),
            accessibilityLabel: backend.displayName,
            action: action
        )
    }
}

/// One capability line: a status glyph and what it describes.
private final class BackendHighlightView: NSView {
    init(highlight: TerminalBackendHighlight) {
        super.init(frame: .zero)

        let configuration = NSImage.SymbolConfiguration(
            pointSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        let symbol = highlight.isPositive ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        let icon = NSImageView(image: NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration) ?? NSImage())
        icon.contentTintColor = highlight.isPositive ? .systemGreen : .systemOrange

        let label = NSTextField(labelWithString: highlight.title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let availability = highlight.isPositive
            ? String(localized: "Available", comment: "Accessibility description for a supported terminal feature.")
            : String(localized: "Unavailable", comment: "Accessibility description for an unsupported terminal feature.")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(
            localized: "\(availability): \(highlight.title)",
            comment: "Accessibility label for a terminal feature and whether it is available."
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
