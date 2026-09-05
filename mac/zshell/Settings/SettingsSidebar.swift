//
//  SettingsSidebar.swift
//  zshell
//

import AppKit

/// Source list of setting categories. Six fixed rows, so they are plain
/// buttons in a stack rather than a table with a data source.
final class SettingsSidebarViewController: NSViewController {
    /// Margin between a row and the sidebar's edges, as the stack's inset and
    /// again as the amount rows are narrower than the stack.
    private static let rowInset: CGFloat = 9

    var onSelect: ((SettingsCategory) -> Void)?

    private let rows = SettingsCategory.allCases.map { SettingsSidebarRow(category: $0) }
    private var selected: SettingsCategory?

    override func loadView() {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(
            top: 8,
            left: Self.rowInset,
            bottom: 8,
            right: Self.rowInset
        )

        for row in rows {
            row.onSelect = { [weak self] category in
                self?.onSelect?(category)
            }
        }

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ]
        // Rows are stretched by constraint, not by the stack's own alignment:
        // `.width` lines a vertical stack's subviews up on their trailing edges
        // and leaves them hugging, so the selection fill covered only the text.
        for row in rows {
            constraints.append(row.widthAnchor.constraint(
                equalTo: stack.widthAnchor,
                constant: -Self.rowInset * 2
            ))
        }
        NSLayoutConstraint.activate(constraints)
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateEmphasis()
        // A selected row is only drawn with the accent color while the window
        // is key, matching every other macOS source list.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowKeyStateChanged(_:)),
                name: name,
                object: view.window
            )
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self)
    }

    func select(_ category: SettingsCategory) {
        guard selected != category else { return }
        selected = category
        for row in rows {
            row.isSelectedRow = row.category == category
        }
    }

    @objc private func windowKeyStateChanged(_ notification: Notification) {
        updateEmphasis()
    }

    private func updateEmphasis() {
        let emphasized = view.window?.isKeyWindow ?? false
        for row in rows {
            row.isEmphasized = emphasized
        }
    }
}

/// One category row: symbol, name, and the source-list selection fill across
/// the whole row.
private final class SettingsSidebarRow: NSButton {
    let category: SettingsCategory

    var onSelect: ((SettingsCategory) -> Void)?

    var isSelectedRow = false {
        didSet {
            guard isSelectedRow != oldValue else { return }
            selectionView.isHidden = !isSelectedRow
            updateTint()
            setAccessibilityValue(isSelectedRow)
        }
    }

    var isEmphasized = false {
        didSet {
            guard isEmphasized != oldValue else { return }
            selectionView.isEmphasized = isEmphasized
            updateTint()
        }
    }

    private let selectionView = NSVisualEffectView()
    private let symbolView = NSImageView()
    private let titleLabel: NSTextField

    init(category: SettingsCategory) {
        self.category = category
        titleLabel = NSTextField(labelWithString: category.title)
        super.init(frame: .zero)

        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(category.title)
        setAccessibilityValue(false)
        target = self
        action = #selector(invoke)

        selectionView.material = .selection
        selectionView.blendingMode = .withinWindow
        selectionView.state = .active
        selectionView.isHidden = true
        selectionView.wantsLayer = true
        selectionView.layer?.cornerRadius = 6
        selectionView.layer?.cornerCurve = .continuous

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail

        symbolView.image = NSImage(
            systemSymbolName: category.symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        symbolView.imageScaling = .scaleNone
        symbolView.setAccessibilityElement(false)

        for subview in [selectionView, symbolView, titleLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            selectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionView.topAnchor.constraint(equalTo: topAnchor),
            selectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: SettingsMetrics.sidebarRowHeight),
            // A fixed symbol column so the titles line up under each other
            // whatever glyph precedes them.
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            symbolView.widthAnchor.constraint(equalToConstant: SettingsMetrics.sidebarSymbolWidth),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 5),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        onSelect?(category)
    }

    /// The accent fill only appears while the window is key, so the row's
    /// contents only invert then.
    private func updateTint() {
        let onAccent = isSelectedRow && isEmphasized
        titleLabel.textColor = onAccent ? .white : .labelColor
        symbolView.contentTintColor = onAccent ? .white : .secondaryLabelColor
    }
}
