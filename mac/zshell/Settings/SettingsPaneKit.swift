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
    static let rowTitleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let rowIconSize = ceil((rowTitleFont.ascender - rowTitleFont.descender) * 1.25)
    static let rowSymbolSize = ceil((rowTitleFont.ascender - rowTitleFont.descender) * 0.85)
    static let iconLabelGap: CGFloat = 12
    /// Baseline constraints measure down from the first line's typographic center.
    static let rowIconBaselineOffset = -(rowTitleFont.ascender + rowTitleFont.descender) / 2
    /// Sidebar row height and the width reserved for its symbol, so titles line
    /// up whatever glyph precedes them.
    static let sidebarRowHeight: CGFloat = 36
    static let sidebarSymbolWidth = rowIconSize
}

enum SettingsRowSymbols {
    struct Icon {
        let name: String
        let category: SettingsCategory
    }

    private static var language: String?
    private static var localized: [String: Icon] = [:]

    static func icon(for title: String, control: NSView? = nil) -> Icon {
        let identifier = AppLocalization.current.identifier
        if language != identifier {
            localized = makeLocalizedSymbols()
            language = identifier
        }
        if let icon = localized[title] { return icon }
        let toolAction = String(localized: "Manage \(title)")
        if control?.accessibilityLabel() == toolAction
            || (control as? NSStackView)?.arrangedSubviews.contains(where: { $0.accessibilityLabel() == toolAction }) == true {
            return Icon(name: "shippingbox", category: .recommendations)
        }
        if control is NSProgressIndicator {
            return Icon(name: "shippingbox", category: .recommendations)
        }
        if control is NSSwitch { return Icon(name: "switch.2", category: .general) }
        if control is NSPopUpButton { return Icon(name: "list.bullet", category: .general) }
        if control is NSTextField { return Icon(name: "textformat", category: .general) }
        return Icon(name: "slider.horizontal.3", category: .general)
    }

    private static func makeLocalizedSymbols() -> [String: Icon] {
        let groups: [([String], String, SettingsCategory)] = [
            ([String(localized: "Language")], "globe", .general),
            ([String(localized: "Show Zshell in")], "menubar.rectangle", .general),
            ([String(localized: "Toolbar")], "macwindow", .general),
            ([String(localized: "Keep computer awake")], "moon.zzz", .general),
            ([String(localized: "Show pull request status")], "arrow.triangle.pull", .general),
            ([String(localized: "Use proxy for Git"), String(localized: "Proxy address")], "network", .general),
            ([String(localized: "Dock icon")], "app", .appearance),
            ([String(localized: "Dark theme")], "moon.fill", .appearance),
            ([String(localized: "Light theme")], "sun.max.fill", .appearance),
            ([String(localized: "Terminal theme only")], "terminal", .appearance),
            ([String(localized: "Minimum contrast")], "circle.lefthalf.filled", .appearance),
            ([String(localized: "Latin family"), String(localized: "Size"), String(localized: "Font size"),
              String(localized: "Sidebar font size")], "textformat.size", .appearance),
            ([String(localized: "CJK fallback")], "character.book.closed", .appearance),
            ([String(localized: "Font ligatures"), String(localized: "OpenType features")], "textformat", .appearance),
            ([String(localized: "Thicken font strokes"), String(localized: "Stroke strength")], "bold", .appearance),
            ([String(localized: "Line height")], "arrow.up.and.down", .appearance),
            ([String(localized: "Cell width")], "arrow.left.and.right", .appearance),
            ([String(localized: "Cursor shape")], "cursorarrow", .appearance),
            ([String(localized: "Blink cursor")], "cursorarrow.rays", .appearance),
            ([String(localized: "Opacity"), String(localized: "Terminal background opacity"),
              String(localized: "Pane focus ring opacity")], "circle.dotted", .appearance),
            ([String(localized: "Blur behind window")], "drop.halffull", .appearance),
            ([String(localized: "Padding color")], "rectangle.inset.filled", .appearance),
            ([String(localized: "Interface size")], "arrow.up.left.and.arrow.down.right", .appearance),
            ([String(localized: "Show focus ring on active pane")], "viewfinder", .appearance),
            ([String(localized: "Double-click empty space to create a session")], "plus.rectangle", .appearance),
            ([String(localized: "New session directory")], "folder.fill", .terminal),
            ([String(localized: "Startup"), String(localized: "Backend")], "terminal", .terminal),
            ([String(localized: "Keep sessions running after quitting"), String(localized: "Session behavior")],
             "arrow.clockwise", .terminal),
            ([String(localized: "Apply terminal profiles automatically")], "person.text.rectangle", .terminal),
            ([String(localized: "Enable Quick Terminal")], "terminal", .terminal),
            ([String(localized: "Shortcut")], "keyboard", .terminal),
            ([String(localized: "Quick Terminal default size")], "arrow.up.left.and.arrow.down.right", .terminal),
            ([String(localized: "Quick Terminal default opacity")], "circle.dotted", .terminal),
            ([String(localized: "Mouse wheel")], "computermouse", .terminal),
            ([String(localized: "Trackpad")], "hand.draw", .terminal),
            ([String(localized: "Shell completions"), String(localized: "Show terminal text hints"),
              String(localized: "Vim command hints")], "text.bubble", .terminal),
            ([String(localized: "Use Option as Alt/Meta"), String(localized: "Shift+Enter inserts a newline")],
             "keyboard", .terminal),
            ([String(localized: "Copy on select")], "doc.on.doc", .terminal),
            ([String(localized: "Right-click action")], "computermouse", .terminal),
            ([String(localized: "Focus follows mouse")], "cursorarrow", .terminal),
            ([String(localized: "Upload copied files and images"), String(localized: "Upload dropped files")],
             "square.and.arrow.up", .terminal),
            ([String(localized: "Record command history"), String(localized: "Restore session history on relaunch")],
             "clock.arrow.circlepath", .terminal),
            ([String(localized: "Enable Prompt Queue")], "text.badge.plus", .terminal),
            ([String(localized: "Send queued prompts automatically")], "paperplane", .terminal),
            ([String(localized: "Long-running commands")], "timer", .terminal),
            ([String(localized: "Failed commands")], "exclamationmark.triangle", .terminal),
            ([String(localized: "Terminal bell")], "bell", .terminal),
            ([String(localized: "External editor")], "square.and.pencil", .editor),
            ([String(localized: "Wrap lines to editor width"), String(localized: "Wrap lines to diff width")],
             "arrow.turn.down.left", .editor),
            ([String(localized: "Protect against save conflicts")], "checkmark.shield", .editor),
            ([String(localized: "Back up unsaved drafts")], "clock.arrow.circlepath", .editor),
            ([String(localized: "Allow remote file changes")], "network", .editor),
            ([String(localized: "Import by dragging into the file tree")], "square.and.arrow.down", .editor),
            (["EasyList", "EasyPrivacy", String(localized: "Block ads and trackers")], "hand.raised.fill", .browser),
            ([String(localized: "Enable browser access"), String(localized: "Listen on")], "network", .browserAccess),
            ([String(localized: "HTTPS port")], "lock.shield", .browserAccess),
            ([String(localized: "AI")], "point.3.connected.trianglepath.dotted", .automation),
            ([String(localized: "Use custom recognition rules")], "slider.horizontal.3", .automation),
            ([String(localized: "Infer agent state from the screen")], "text.viewfinder", .automation),
            ([String(localized: "Resume agent conversations")], "bubble.left.and.bubble.right", .automation),
            ([String(localized: "Notify when agents need attention"), String(localized: "Notify when agents finish")],
             "bell", .automation),
            ([String(localized: "Automatically check for updates")], "arrow.clockwise", .updates),
            ([String(localized: "Automatically download updates")], "arrow.down.circle", .updates),
            ([String(localized: "Automatically install updates")], "shippingbox", .updates),
            ([String(localized: "New Session"), String(localized: "New Project"), String(localized: "New Window"),
              String(localized: "New Session in Worktree…")], "plus.rectangle", .shortcuts),
            ([String(localized: "Close Pane")], "xmark.rectangle", .shortcuts),
            ([String(localized: "Command Palette…")], "command", .shortcuts),
            ([String(localized: "Toggle Left Sidebar"), String(localized: "Toggle Right Sidebar")], "sidebar.left", .shortcuts),
            ([String(localized: "Toggle Files Panel")], "folder", .shortcuts),
            ([String(localized: "Toggle Git Panel")], "arrow.triangle.branch", .shortcuts),
            ([String(localized: "Next Project"), String(localized: "Previous Project")], "arrow.left.arrow.right", .shortcuts),
            ([String(localized: "Clear Terminal")], "clear", .shortcuts),
            (["Homebrew"], "shippingbox", .recommendations),
        ]
        var result: [String: Icon] = [:]
        for (titles, symbol, category) in groups {
            for title in titles { result[title] = Icon(name: symbol, category: category) }
        }
        return result
    }
}

enum SettingsIconColors {
    static func color(for symbolName: String) -> NSColor {
        if let category = SettingsCategory.allCases.first(where: { $0.symbolName == symbolName }) {
            return category.iconColor
        }
        switch symbolName {
        case "app": return SettingsCategory.appearance.iconColor
        case "terminal": return SettingsCategory.terminal.iconColor
        case "macwindow": return SettingsCategory.general.iconColor
        case "menubar.rectangle", "hand.raised.fill": return SettingsCategory.general.iconColor
        case "link", "network": return SettingsCategory.browser.iconColor
        default: return SettingsCategory.general.iconColor
        }
    }
}

/// SF Symbols have optical alignment insets. A plain view keeps the colored
/// tile square instead of drawing around an image view's expanded frame.
final class SettingsIconView: NSView {
    private static var visibleSymbolBounds: [String: NSRect] = [:]
    private let color: NSColor
    private let symbol = NSImageView()
    private let visibleBounds: NSRect

    init(symbolName: String, color: NSColor, size: CGFloat) {
        self.color = color
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: SettingsMetrics.rowTitleFont.pointSize, weight: .medium))
        visibleBounds = image.map { Self.visibleBounds(of: $0, named: symbolName) } ?? .zero
        super.init(frame: .zero)
        // SF Symbols include asymmetric drawing padding beyond their alignment rect.
        image?.alignmentRect = NSRect(origin: .zero, size: image?.size ?? .zero)
        symbol.image = image
        symbol.contentTintColor = .white
        symbol.imageScaling = .scaleProportionallyUpOrDown
        symbol.setAccessibilityElement(false)
        addSubview(symbol)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalTo: widthAnchor),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let radius = bounds.width / 4
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func layout() {
        super.layout()
        guard let image = symbol.image, !visibleBounds.isEmpty else { return }
        let scale = SettingsMetrics.rowSymbolSize / max(visibleBounds.width, visibleBounds.height)
        symbol.frame = NSRect(
            x: bounds.midX - visibleBounds.midX * scale,
            y: bounds.midY - visibleBounds.midY * scale,
            width: image.size.width * scale, height: image.size.height * scale
        )
    }

    private static func visibleBounds(of image: NSImage, named name: String) -> NSRect {
        if let bounds = visibleSymbolBounds[name] { return bounds }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return NSRect(origin: .zero, size: image.size)
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        let scaleX = image.size.width / CGFloat(bitmap.pixelsWide)
        let scaleY = image.size.height / CGFloat(bitmap.pixelsHigh)
        let bounds = NSRect(x: CGFloat(minX) * scaleX,
                            y: CGFloat(bitmap.pixelsHigh - maxY - 1) * scaleY,
                            width: CGFloat(maxX - minX + 1) * scaleX,
                            height: CGFloat(maxY - minY + 1) * scaleY)
        visibleSymbolBounds[name] = bounds
        return bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
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
