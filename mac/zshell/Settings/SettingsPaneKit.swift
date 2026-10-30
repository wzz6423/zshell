//
//  SettingsPaneKit.swift
//  zshell
//

import AppKit
import Combine

/// Shared geometry for the settings panes.
enum SettingsMetrics {
    static let paneInset: CGFloat = 28
    static let groupSpacing: CGFloat = 24
    static let groupInset: CGFloat = 18
    static let groupCornerRadius: CGFloat = 16
    static let headerSpacing: CGFloat = 16
    static let rowVerticalInset: CGFloat = 12
    /// Smallest gap between a row's label column and its control.
    static let labelControlGap: CGFloat = 16
    /// Numeric readout beside a slider, wide enough for "100%".
    static let sliderValueWidth: CGFloat = 44
    /// Sidebar row height and the width reserved for its symbol, so titles line
    /// up whatever glyph precedes them.
    static let sidebarRowHeight: CGFloat = 36
    static let sidebarSymbolWidth: CGFloat = 22
}

// MARK: - Chrome

/// A hairline. Drawn rather than layer-filled so it re-resolves whenever the
/// effective appearance changes.
final class SettingsSeparatorView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One row inside a group: its vertical padding, and the hairline that separates
/// it from the row above. Both live here so hiding a conditional row takes its
/// separator with it.
private final class SettingsRowWrapper: NSView {
    private let row: NSView
    private let separator = SettingsSeparatorView()
    private lazy var separatorHeight = separator.heightAnchor.constraint(equalToConstant: 1)
    private lazy var rowTop = row.topAnchor.constraint(equalTo: separator.bottomAnchor)
    private lazy var rowBottom = row.bottomAnchor.constraint(equalTo: bottomAnchor)

    init(row: NSView) {
        self.row = row
        super.init(frame: .zero)

        separator.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(row)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorHeight,
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowTop,
            rowBottom,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setVisiblePosition(isFirst: Bool, isLast: Bool) {
        separator.isHidden = isFirst
        separatorHeight.constant = isFirst ? 0 : 1
        rowTop.constant = isFirst ? 0 : SettingsMetrics.rowVerticalInset
        rowBottom.constant = isLast ? 0 : -SettingsMetrics.rowVerticalInset
    }
}

/// Every child is pinned to the card's content width: a vertical stack's
/// `alignment = .width` otherwise leaves narrow groups hugging their content.
final class SettingsGroup: NSView {
    let headerTitle: String?
    private let rowStack = NSStackView()
    private var wrappers: [SettingsRowWrapper] = []

    init(header: String? = nil, rows: [NSView]) {
        headerTitle = header
        super.init(frame: .zero)

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.detachesHiddenViews = true
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            let wrapper = SettingsRowWrapper(row: row)
            wrappers.append(wrapper)
            rowStack.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }

        addSubview(rowStack)
        var constraints: [NSLayoutConstraint] = [
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.groupInset),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.groupInset),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsMetrics.groupInset),
        ]

        if let header {
            let label = NSTextField(wrappingLabelWithString: header)
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            constraints += [
                label.leadingAnchor.constraint(equalTo: rowStack.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: rowStack.trailingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor, constant: SettingsMetrics.groupInset),
                rowStack.topAnchor.constraint(
                    equalTo: label.bottomAnchor,
                    constant: SettingsMetrics.headerSpacing
                ),
            ]
        } else {
            constraints.append(rowStack.topAnchor.constraint(equalTo: topAnchor, constant: SettingsMetrics.groupInset))
        }

        NSLayoutConstraint.activate(constraints)
        updateVisibleRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: SettingsMetrics.groupCornerRadius,
            yRadius: SettingsMetrics.groupCornerRadius
        ).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Shows or hides one row along with the separator above it.
    func setRowHidden(_ hidden: Bool, at index: Int) {
        guard wrappers.indices.contains(index) else { return }
        wrappers[index].isHidden = hidden
        updateVisibleRows()
    }

    private func updateVisibleRows() {
        let visible = wrappers.filter { !$0.isHidden }
        isHidden = visible.isEmpty
        for (index, wrapper) in visible.enumerated() {
            wrapper.setVisiblePosition(isFirst: index == 0, isLast: index == visible.count - 1)
        }
    }
}
