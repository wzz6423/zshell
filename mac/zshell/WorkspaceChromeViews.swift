//
//  WorkspaceChromeViews.swift
//  zshell
//

import AppKit

/// Small native controls shared by the project sidebar and session strip.
/// Colors are resolved when drawn, including live appearance/theme changes.
final class WorkspaceChromeButton: NSButton {
    var onAction: (() -> Void)?
    private var isHovered = false

    init(symbol: String, label: String, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(invokeAction)
        onAction = action
        configure(symbol: symbol, label: label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String, label: String, pointSize: CGFloat = 12) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        contentTintColor = .secondaryLabelColor
        toolTip = label
        setAccessibilityLabel(label)
    }

    func configure(symbol: String, command: AppCommand, pointSize: CGFloat = 12) {
        let shortcut = AppSettings.shared.commandShortcut(for: command).displayString
        configure(symbol: symbol, label: "\(command.title) (\(shortcut))", pointSize: pointSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    @objc private func invokeAction() { onAction?() }
}

final class WorkspaceWindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performTitlebarDoubleClickAction()
        } else {
            window?.performDrag(with: event)
        }
    }
}

extension NSView {
    /// PaneLayoutView reports SwiftUI global coordinates with a top-left
    /// origin. Use that same content coordinate space for native drag targets.
    func workspaceGlobalRect(_ rect: NSRect) -> NSRect {
        guard let root = window?.contentView else { return .zero }
        var converted = convert(rect, to: root)
        if !root.isFlipped { converted.origin.y = root.bounds.height - converted.maxY }
        return converted
    }

    func workspaceGlobalPoint(_ event: NSEvent) -> NSPoint {
        workspaceGlobalRect(NSRect(origin: convert(event.locationInWindow, from: nil), size: .zero)).origin
    }
}

/// Stable row views avoid replacing live field editors when terminal titles
/// change. Terminal surfaces are never owned by this chrome.
final class WorkspaceItemView: NSView, NSTextFieldDelegate {
    let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let disclosureView = NSImageView()
    private let markerView = NSImageView()
    private let pinView = NSImageView()
    private let countLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let badge = AgentStatusBadgeView(frame: .zero)
    private let actionButton = WorkspaceChromeButton(symbol: "xmark", label: String(localized: "Close"))
    private let renameField = NSTextField()
    private let menuPresenter = AppKitContextMenuMonitorView()

    var onSelect: (() -> Void)?
    var onRename: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onDragEnded: ((NSEvent) -> Void)?
    var onDragCancelled: (() -> Void)?
    var onNavigate: ((UInt16) -> Void)?
    var menuItems: (() -> [AppKitContextMenuItem])?
    private var renameCommit: ((String) -> Void)?
    private weak var renamePreviousResponder: NSResponder?
    private var mouseOrigin: NSPoint?
    private var hasDragged = false
    private var dragCancelMonitor: Any?
    private var isHovered = false
    private var isSelected = false
    private var isGroup = false
    private var isGrouped = false
    private var isDirty = false
    private var isSidebar = false
    private var indent: CGFloat = 0
    private var scale: CGFloat = 1
    private var badgeWidth: CGFloat = 0
    private var titleWidth: CGFloat = 0
    private var countWidth: CGFloat = 0
    private var hasAction = false
    var isDropTarget = false { didSet { if oldValue != isDropTarget { needsDisplay = true } } }
    var isRenaming: Bool { renameCommit != nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [titleLabel, subtitleLabel, countLabel, shortcutLabel] {
            label.translatesAutoresizingMaskIntoConstraints = true
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            label.isSelectable = false
        }
        for image in [iconView, disclosureView, markerView, pinView] {
            image.imageScaling = .scaleProportionallyDown
            image.setAccessibilityElement(false)
        }
        badge.translatesAutoresizingMaskIntoConstraints = true
        renameField.delegate = self
        renameField.isHidden = true
        renameField.isBordered = false
        renameField.drawsBackground = false
        renameField.focusRingType = .exterior
        for view in [disclosureView, iconView, markerView, pinView, titleLabel, subtitleLabel,
                     countLabel, shortcutLabel, badge, actionButton, renameField] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(
        title: String, subtitle: String? = nil, icon: NSImage?,
        selected: Bool, group: Bool = false, collapsed: Bool = false,
        grouped: Bool = false, pinned: Bool = false, marker: ProjectTabMarkerColor? = nil,
        count: Int? = nil, rollup: ZshellAgentRollup? = nil, dirty: Bool = false,
        sidebar: Bool = false, indent: CGFloat = 0, scale: CGFloat = 1,
        shortcut: String? = nil, actionSymbol: String = "xmark",
        actionLabel: String = String(localized: "Close"), action: (() -> Void)? = nil
    ) {
        self.isSelected = selected
        self.isGroup = group
        self.isGrouped = grouped
        self.isDirty = dirty
        self.isSidebar = sidebar
        self.indent = indent
        self.scale = scale
        self.hasAction = action != nil
        let fontSize: CGFloat = (group ? 10.5 : 11.5) * scale
        titleLabel.font = .systemFont(ofSize: fontSize, weight: group ? .medium : .regular)
        titleLabel.stringValue = title
        titleLabel.textColor = selected ? .labelColor : .secondaryLabelColor
        titleWidth = ceil(titleLabel.attributedStringValue.size().width)
        titleLabel.isHidden = isRenaming
        subtitleLabel.font = .systemFont(ofSize: 10 * scale)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        iconView.image = icon
        iconView.contentTintColor = icon?.isTemplate == true ? (selected ? Theme.accent : .secondaryLabelColor) : nil
        disclosureView.isHidden = !group
        disclosureView.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        disclosureView.contentTintColor = .secondaryLabelColor
        pinView.isHidden = !pinned
        pinView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinView.contentTintColor = .secondaryLabelColor
        markerView.isHidden = marker == nil
        markerView.image = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil)
        markerView.contentTintColor = marker?.nsColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 9 * scale, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.stringValue = count.map(String.init) ?? ""
        countLabel.isHidden = count == nil
        countWidth = count == nil ? 0 : ceil(countLabel.attributedStringValue.size().width) + 6 * scale
        shortcutLabel.font = .systemFont(ofSize: 10 * scale)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.stringValue = shortcut ?? ""
        actionButton.configure(symbol: actionSymbol, label: actionLabel, pointSize: 9 * scale)
        actionButton.onAction = action
        if let rollup {
            badge.apply(phase: rollup.phase, count: rollup.count)
            badgeWidth = badge.intrinsicContentSize.width + 4 * scale
            badge.isHidden = false
        } else {
            badgeWidth = 0
            badge.isHidden = true
        }
        renameField.font = titleLabel.font
        renameField.textColor = .labelColor
        setAccessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        let state = group
            ? String(localized: collapsed ? "Collapsed" : "Expanded")
            : (selected ? String(localized: "Selected") : "")
        let markerDescription = marker.map { String(localized: "Color marker \($0.displayValue)") }
        setAccessibilityValue([state, markerDescription].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        updateActionVisibility()
        needsLayout = true
        needsDisplay = true
    }

    var preferredWidth: CGFloat {
        let leading = 9 * scale + indent + (isGroup ? 13 * scale : 0)
            + (iconView.image == nil ? 0 : 17 * scale)
            + (markerView.isHidden ? 0 : 13 * scale) + (pinView.isHidden ? 0 : 13 * scale)
        let trailing = 6 * scale + actionSlotWidth + countWidth + badgeWidth
        return min(260 * scale, max(68 * scale, leading + min(titleWidth, 160 * scale) + trailing))
    }

    private var actionSlotWidth: CGFloat { hasAction || !shortcutLabel.stringValue.isEmpty ? 24 * max(1, scale) : 0 }

    override func layout() {
        super.layout()
        var x = 8 * scale + indent
        let iconSize = min(14 * scale, bounds.height - 8)
        for view in [disclosureView, iconView, markerView, pinView] where !view.isHidden {
            guard view !== iconView || iconView.image != nil else { continue }
            let width = view === disclosureView ? 10 * scale : iconSize
            view.frame = NSRect(x: x, y: (bounds.height - iconSize) / 2, width: width, height: iconSize)
            x += width + 4 * scale
        }
        let right = max(x, bounds.width - 5 * scale - actionSlotWidth)
        actionButton.frame = NSRect(x: right, y: (bounds.height - 24 * max(1, scale)) / 2,
                                    width: actionSlotWidth, height: 24 * max(1, scale))
        shortcutLabel.frame = NSRect(x: right, y: (bounds.height - 16 * scale) / 2,
                                     width: actionSlotWidth, height: 16 * scale)
        let visibleBadgeWidth = bounds.width - x - actionSlotWidth > 80 * scale ? badgeWidth : 0
        badge.isHidden = visibleBadgeWidth == 0
        badge.frame = NSRect(x: right - visibleBadgeWidth, y: (bounds.height - 15) / 2,
                             width: max(0, visibleBadgeWidth - 4 * scale), height: 15)
        countLabel.frame = NSRect(x: right - visibleBadgeWidth - countWidth,
                                  y: (bounds.height - 14 * scale) / 2, width: countWidth, height: 14 * scale)
        let titleSpace = max(0, right - visibleBadgeWidth - countWidth - x - 3 * scale)
        let titleHeight = ceil((titleLabel.font?.ascender ?? 12) - (titleLabel.font?.descender ?? -3)) + 2
        let subtitleHeight = subtitleLabel.isHidden ? 0 : 13 * scale
        let titleY = (bounds.height - titleHeight - subtitleHeight) / 2
        titleLabel.frame = NSRect(x: x, y: titleY, width: titleSpace, height: titleHeight)
        subtitleLabel.frame = NSRect(x: x, y: titleY + titleHeight, width: titleSpace, height: subtitleHeight)
        renameField.frame = titleLabel.frame
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === actionButton || hit === renameField || hit.isDescendant(of: renameField) { return hit }
        return self
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 6, yRadius: 6)
        if isDropTarget || isSelected || isHovered || isGroup {
            (isDropTarget ? Theme.accent.withAlphaComponent(0.15)
                : NSColor.labelColor.withAlphaComponent(isSelected ? 0.09 : (isHovered ? 0.05 : 0.025))).setFill()
            shape.fill()
        }
        if isDropTarget {
            Theme.accent.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        if isGrouped && !isSidebar {
            Theme.accent.withAlphaComponent(0.45).setFill()
            NSRect(x: 2, y: bounds.maxY - 2, width: max(0, bounds.width - 4), height: 1).fill()
        }
        if isDirty && actionButton.isHidden {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: actionButton.frame.midX - 2.5, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            shape.lineWidth = 2
            shape.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; updateActionVisibility(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateActionVisibility(); needsDisplay = true }

    private func updateActionVisibility() {
        actionButton.isHidden = !hasAction || isRenaming || (!isHovered && !isGroup)
        shortcutLabel.isHidden = isRenaming || !actionButton.isHidden || isDirty
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        mouseOrigin = event.locationInWindow
        hasDragged = false
        if event.clickCount == 2 { mouseOrigin = nil; onRename?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isRenaming, let mouseOrigin else { return }
        if !hasDragged {
            guard hypot(event.locationInWindow.x - mouseOrigin.x, event.locationInWindow.y - mouseOrigin.y) >= 4 else { return }
            hasDragged = true
            dragCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let input = WorkspaceChromeEvent(event)
                let output = MainActor.assumeIsolated {
                    guard let self, let event = input.value, event.window === self.window, event.keyCode == 53 else { return input }
                    self.cancelMouseDrag()
                    return WorkspaceChromeEvent(nil)
                }
                return output.value
            }
        }
        NSCursor.closedHand.set()
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseOrigin != nil else { return }
        mouseOrigin = nil
        removeDragMonitor()
        if hasDragged { onDragEnded?(event) }
        else if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
        hasDragged = false
        NSCursor.arrow.set()
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, !isGroup { actionButton.onAction?() }
        else { super.otherMouseUp(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let items = menuItems?(), !items.isEmpty else { return }
        menuPresenter.popUp(items: items, at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let items = menuItems?(), !items.isEmpty else { return false }
        menuPresenter.popUp(items: items, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109, event.modifierFlags.contains(.shift) {
            _ = accessibilityPerformShowMenu()
            return
        }
        switch event.keyCode {
        case 36, 49: onSelect?()
        case 120: onRename?()
        case 53:
            cancelMouseDrag()
        case 123, 124, 125, 126: onNavigate?(event.keyCode)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool { onSelect?(); return onSelect != nil }

    private func cancelMouseDrag() {
        mouseOrigin = nil
        hasDragged = false
        removeDragMonitor()
        onDragCancelled?()
        NSCursor.arrow.set()
    }

    private func removeDragMonitor() {
        if let dragCancelMonitor { NSEvent.removeMonitor(dragCancelMonitor) }
        dragCancelMonitor = nil
    }

    deinit {
        if let dragCancelMonitor { NSEvent.removeMonitor(dragCancelMonitor) }
    }

    func beginRename(value: String, commit: @escaping (String) -> Void) {
        guard !isRenaming else { return }
        renamePreviousResponder = window?.firstResponder
        renameCommit = commit
        renameField.stringValue = value
        renameField.setAccessibilityLabel(String(localized: "Name"))
        renameField.isHidden = false
        titleLabel.isHidden = true
        updateActionVisibility()
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(renameField)
        renameField.selectText(nil)
    }

    private func finishRename(apply: Bool, restoreFocus: Bool = false) {
        guard let commit = renameCommit else { return }
        let name = renameField.stringValue
        renameCommit = nil
        let responder = renamePreviousResponder
        renamePreviousResponder = nil
        if restoreFocus { window?.makeFirstResponder(nil) }
        renameField.isHidden = true
        titleLabel.isHidden = false
        updateActionVisibility()
        if apply { commit(name) }
        if restoreFocus, let responder = responder as? NSView, responder.window === window {
            window?.makeFirstResponder(responder)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishRename(apply: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finishRename(apply: true, restoreFocus: true); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishRename(apply: false, restoreFocus: true); return true }
        return false
    }
}

private struct WorkspaceChromeEvent: @unchecked Sendable {
    let value: NSEvent?
    init(_ value: NSEvent?) { self.value = value }
}
