//
//  SettingsApplicationIconPicker.swift
//  zshell
//

import AppKit

/// Chooses the icon shown for the running app in the Dock and app switcher.
final class SettingsApplicationIconPicker: NSView {
    private var options: [ApplicationIconOptionCard] = []

    init(onChange: @escaping (ApplicationIcon) -> Void) {
        super.init(frame: .zero)

        options = ApplicationIcon.allCases.map { icon in
            ApplicationIconOptionCard(applicationIcon: icon) { onChange(icon) }
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

    func select(_ applicationIcon: ApplicationIcon) {
        for option in options {
            option.isSelectedCard = option.applicationIcon == applicationIcon
        }
    }
}

private final class ApplicationIconOptionCard: SettingsCardButton {
    let applicationIcon: ApplicationIcon

    private let label: NSTextField

    init(applicationIcon: ApplicationIcon, action: @escaping () -> Void) {
        self.applicationIcon = applicationIcon

        previewImage = NSImageView(image: Self.preview(for: applicationIcon))
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewImage.widthAnchor.constraint(equalToConstant: 56),
            previewImage.heightAnchor.constraint(equalToConstant: 56),
        ])

        label = NSTextField(labelWithString: applicationIcon.title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1

        let content = NSStackView(views: [previewImage, label])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 4

        super.init(
            content: content,
            insets: NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5),
            unselectedBorder: nil,
            accessibilityLabel: applicationIcon.title,
            action: action
        )
    }

    private let previewImage: NSImageView

    /// The card previews the art each choice actually shows. The default is
    /// the icon compiled into this bundle — the Debug build ships its own —
    /// and the variants are the alternate .icns resources in that bundle.
    private static func preview(for applicationIcon: ApplicationIcon) -> NSImage {
        let image: NSImage?
        switch applicationIcon {
        case .defaultIcon:
            // Use the system-rendered icon, including its Dock padding and
            // the separate identity compiled into Debug builds.
            image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        case .light, .dark:
            image = applicationIcon.bundledImage()
        }
        guard let image else {
            return NSApplication.shared.applicationIconImage
                ?? NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil)!
        }
        return image
    }

    override func didChangeSelection() {
        label.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: isSelectedCard ? .semibold : .regular
        )
        label.textColor = isSelectedCard ? .labelColor : .secondaryLabelColor
    }
}
