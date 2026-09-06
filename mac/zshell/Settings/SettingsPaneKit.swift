//
//  SettingsPaneKit.swift
//  zshell
//

import AppKit
import Combine

/// Shared geometry for the settings panes.
enum SettingsMetrics {
    static let paneInset: CGFloat = 20
    static let groupSpacing: CGFloat = 22
    static let headerSpacing: CGFloat = 7
    static let rowVerticalInset: CGFloat = 10
    /// Smallest gap between a row's label column and its control.
    static let labelControlGap: CGFloat = 16
    /// Numeric readout beside a slider, wide enough for "100%".
    static let sliderValueWidth: CGFloat = 44
    /// Sidebar row height and the width reserved for its symbol, so titles line
    /// up whatever glyph precedes them.
    static let sidebarRowHeight: CGFloat = 30
    static let sidebarSymbolWidth: CGFloat = 20
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
    init(row: NSView, showsSeparator: Bool) {
        super.init(frame: .zero)

        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        var constraints: [NSLayoutConstraint] = [
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -SettingsMetrics.rowVerticalInset
            ),
        ]

        if showsSeparator {
            let separator = SettingsSeparatorView()
            separator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(separator)
            constraints += [
                separator.topAnchor.constraint(equalTo: topAnchor),
                separator.leadingAnchor.constraint(equalTo: leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor),
                separator.heightAnchor.constraint(equalToConstant: 1),
                row.topAnchor.constraint(
                    equalTo: separator.bottomAnchor,
                    constant: SettingsMetrics.rowVerticalInset
                ),
            ]
        } else {
            constraints.append(row.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsMetrics.rowVerticalInset
            ))
        }

        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A titled group of settings rows: a small header, then the rows bracketed by
/// hairlines. Every child is pinned to the group's own leading and trailing
/// edges rather than aligned by the stack: `alignment = .width` on a vertical
/// `NSStackView` leaves subviews hugging their content and lines them up on
/// their *trailing* edges, which is what pushed narrow groups off the pane's
/// left margin.
final class SettingsGroup: NSView {
    private let rowStack = NSStackView()
    private var wrappers: [SettingsRowWrapper] = []

    init(header: String? = nil, rows: [NSView]) {
        super.init(frame: .zero)

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.detachesHiddenViews = true
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            let wrapper = SettingsRowWrapper(row: row, showsSeparator: index > 0)
            wrappers.append(wrapper)
            rowStack.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }

        let top = SettingsSeparatorView()
        let bottom = SettingsSeparatorView()
        var constraints: [NSLayoutConstraint] = []
        for view in [top, rowStack, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            constraints += [
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        }
        constraints += [
            top.heightAnchor.constraint(equalToConstant: 1),
            bottom.heightAnchor.constraint(equalToConstant: 1),
            rowStack.topAnchor.constraint(equalTo: top.bottomAnchor),
            bottom.topAnchor.constraint(equalTo: rowStack.bottomAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]

        if let header {
            let label = NSTextField(labelWithString: header)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            constraints += [
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor),
                top.topAnchor.constraint(
                    equalTo: label.bottomAnchor,
                    constant: SettingsMetrics.headerSpacing
                ),
            ]
        } else {
            constraints.append(top.topAnchor.constraint(equalTo: topAnchor))
        }

        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows or hides one row along with the separator above it.
    func setRowHidden(_ hidden: Bool, at index: Int) {
        guard wrappers.indices.contains(index) else { return }
        wrappers[index].isHidden = hidden
    }
}
