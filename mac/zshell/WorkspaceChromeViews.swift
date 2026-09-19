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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        // Unclipped views can report a visibleRect larger than their bounds.
        addTrackingArea(NSTrackingArea(
            rect: NSIntersectionRect(bounds, visibleRect),
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        ))
        synchronizeHoverWithMouse()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeHoverWithMouse()
    }

    override func viewDidHide() {
        super.viewDidHide()
        setHovered(false)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        synchronizeHoverWithMouse()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func synchronizeHoverWithMouse() {
        guard let window, !isHiddenOrHasHiddenAncestor else {
            setHovered(false)
            return
        }
        // Layout and visibility changes can move the button without a mouse exit.
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(NSIntersectionRect(bounds, visibleRect).contains(point))
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

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
    weak var dragWindow: NSWindow?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            (dragWindow ?? window)?.performTitlebarDoubleClickAction()
        } else {
            (dragWindow ?? window)?.performDrag(with: event)
        }
    }
}

extension NSView {
    /// Project drags can cross the header's child panel, so their source and
    /// destination use the screen coordinate system shared by both windows.
    func workspaceScreenRect(_ rect: NSRect) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// PaneLayoutView reports SwiftUI global coordinates with a top-left
    /// origin. Use that same content coordinate space for native drag targets.
    /// The header may live in a child panel, so convert through its host window.
    func workspaceGlobalRect(_ rect: NSRect) -> NSRect {
        guard let sourceWindow = window else { return .zero }
        var workspaceWindow = sourceWindow
        while let parent = workspaceWindow.parent { workspaceWindow = parent }
        guard let root = workspaceWindow.contentView else { return .zero }
        let windowRect = convert(rect, to: nil)
        let screenRect = sourceWindow.convertToScreen(windowRect)
        let workspaceRect = workspaceWindow.convertFromScreen(screenRect)
        var converted = root.convert(workspaceRect, from: nil)
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
    var onScrollWheel: ((NSEvent) -> Void)?
    var menuItems: (() -> [AppKitContextMenuItem])?
    private var renameCommit: ((String) -> Void)?
    private weak var renamePreviousResponder: NSResponder?
    private var renameRequestID: UUID?
    private var mouseOrigin: NSPoint?
    private var hasDragged = false
    private var dragCancelMonitor: Any?
    private var pendingGroupSelection: DispatchWorkItem?
    private var pendingGroupSelectionID: UUID?
    private var isHovered = false
    private var isSelected = false
    private var isGroup = false
    private var isCompactGroup = false
    private var fillsGroupRow = false
    private var showsCompactGroupTitle = false
    private var isGrouped = false
    private var isDirty = false
    private var isSidebar = false
    private var usesTabStripHoverTracking = false
    private var indent: CGFloat = 0
    private var scale: CGFloat = 1
    private var groupControlScale: CGFloat = 1
    private var badgeWidth: CGFloat = 0
    private var markerColor: NSColor?
    private var groupControlColor: NSColor?
    private var titleWidth: CGFloat = 0
    private var countWidth: CGFloat = 0
    private var hasAction = false
    var isDropTarget = false { didSet { if oldValue != isDropTarget { needsDisplay = true } } }
    var isRenaming: Bool { renameCommit != nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [titleLabel, subtitleLabel, countLabel, shortcutLabel] {
            label.translatesAutoresizingMaskIntoConstraints = true
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            label.isSelectable = false
        }
        for image in [iconView, disclosureView, pinView] {
            image.imageScaling = .scaleProportionallyDown
            image.setAccessibilityElement(false)
        }
        disclosureView.imageAlignment = .alignCenter
        badge.translatesAutoresizingMaskIntoConstraints = true
        renameField.delegate = self
        renameField.isHidden = true
        renameField.isBordered = false
        renameField.drawsBackground = false
        renameField.focusRingType = .exterior
        for view in [disclosureView, iconView, pinView, titleLabel, subtitleLabel,
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
        sidebar: Bool = false, compactGroup: Bool = false, fillsGroupRow: Bool = false,
        showsGroupTitle: Bool = false,
        indent: CGFloat = 0, scale: CGFloat = 1, groupControlScale: CGFloat? = nil,
        tabStrip: Bool = false,
        shortcut: String? = nil, actionSymbol: String = "xmark",
        actionLabel: String = String(localized: "Close"), action: (() -> Void)? = nil
    ) {
        self.isSelected = selected
        self.isGroup = group
        self.isCompactGroup = group && compactGroup
        self.fillsGroupRow = group && fillsGroupRow
        self.showsCompactGroupTitle = self.isCompactGroup && showsGroupTitle
        self.isGrouped = grouped
        self.isDirty = dirty
        self.isSidebar = sidebar
        if usesTabStripHoverTracking != tabStrip {
            usesTabStripHoverTracking = tabStrip
            updateTrackingAreas()
        }
        self.indent = indent
        self.scale = scale
        self.groupControlScale = groupControlScale ?? scale
        self.hasAction = action != nil
        groupControlColor = group ? (marker ?? .defaultColor).nsColor : nil
        let fontSize: CGFloat = (group ? 10.5 : 11.5) * scale
        titleLabel.font = .systemFont(ofSize: fontSize, weight: group ? .medium : .regular)
        titleLabel.lineBreakMode = fillsGroupRow ? .byTruncatingTail : .byTruncatingMiddle
        titleLabel.alignment = fillsGroupRow ? .left : .natural
        titleLabel.stringValue = title
        titleLabel.textColor = (isCompactGroup || fillsGroupRow)
            ? groupControlColor
            : (selected ? .labelColor : .secondaryLabelColor)
        titleWidth = ceil(titleLabel.attributedStringValue.size().width)
        titleLabel.isHidden = isRenaming || (isCompactGroup && !showsCompactGroupTitle)
        subtitleLabel.font = .systemFont(ofSize: 10 * scale)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        iconView.image = icon
        iconView.contentTintColor = icon?.isTemplate == true ? (selected ? Theme.accent : .secondaryLabelColor) : nil
        disclosureView.isHidden = !group
        disclosureView.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        disclosureView.contentTintColor = (isCompactGroup || fillsGroupRow)
            ? groupControlColor
            : (groupControlColor == nil ? .secondaryLabelColor : .white)
        pinView.isHidden = !pinned
        pinView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinView.contentTintColor = .secondaryLabelColor
        markerColor = group ? nil : marker?.nsColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 9 * scale, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.stringValue = (isCompactGroup || fillsGroupRow) ? "" : (count.map(String.init) ?? "")
        countLabel.isHidden = isCompactGroup || fillsGroupRow || count == nil
        countWidth = isCompactGroup || fillsGroupRow || count == nil
            ? 0
            : ceil(countLabel.attributedStringValue.size().width) + 6 * scale
        shortcutLabel.font = .systemFont(ofSize: 10 * scale)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.stringValue = shortcut ?? ""
        actionButton.configure(symbol: actionSymbol, label: actionLabel, pointSize: 9 * scale)
        actionButton.onAction = { action?() }
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
        if isCompactGroup {
            return groupControlSize.width
        }
        let leading = 9 * scale + indent + (isGroup ? 13 * scale : 0)
            + (iconView.image == nil ? 0 : 17 * scale)
            + (pinView.isHidden ? 0 : 13 * scale)
        let trailing = 6 * scale + actionSlotWidth + countWidth + badgeWidth
        return min(260 * scale, max(68 * scale, leading + min(titleWidth, 160 * scale) + trailing))
    }

    private var actionSlotWidth: CGFloat { hasAction || !shortcutLabel.stringValue.isEmpty ? 24 * max(1, scale) : 0 }
    private var compactGroupControlScale: CGFloat {
        min(1.1, max(0.9, groupControlScale))
    }

    private var groupControlSize: NSSize {
        if isCompactGroup {
            let controlScale = compactGroupControlScale
            let titlePointSize = titleLabel.font?.pointSize ?? 10.5
            let height = showsCompactGroupTitle
                ? min(28, max(24, ceil(titlePointSize + 8)))
                : min(26, max(22, 24 * controlScale))
            guard showsCompactGroupTitle else {
                return NSSize(width: 17 * controlScale, height: height)
            }
            let horizontalPadding = 8 * controlScale
            let title = min(titleWidth, 68 * controlScale)
            let width = horizontalPadding * 2 + 10 * controlScale + 5 * controlScale + title
            return NSSize(width: min(104 * controlScale, max(52 * controlScale, width)), height: height)
        }
        let side = max(20, 20 * scale)
        return NSSize(width: side, height: side)
    }

    private var groupControlFrame: NSRect {
        if fillsGroupRow {
            return bounds.insetBy(dx: 0.5, dy: 2)
        }
        let verticalInset: CGFloat = isCompactGroup ? 2 : 2 * groupControlScale
        let height = min(groupControlSize.height, max(0, bounds.height - verticalInset * 2))
        let width = min(groupControlSize.width, bounds.width)
        let x = isCompactGroup
            ? (bounds.width - width) / 2
            : 4 * scale + indent
        return NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
    }

    override func layout() {
        super.layout()
        if isCompactGroup || fillsGroupRow {
            let control = groupControlFrame
            let controlScale = compactGroupControlScale
            let horizontalInset = 8 * controlScale
            let indicator = max(0, min(11 * controlScale, control.height - 8 * controlScale))
            let showsTitle = fillsGroupRow || showsCompactGroupTitle
            let gap = 5 * controlScale
            let availableTitleWidth = max(0, control.width - horizontalInset * 2 - indicator - gap)
            let indicatorX: CGFloat
            if fillsGroupRow {
                indicatorX = control.minX + horizontalInset
            } else {
                let centeredTitleWidth = showsTitle
                    ? min(titleWidth + 8 * controlScale, availableTitleWidth)
                    : 0
                let contentWidth = showsTitle ? indicator + gap + centeredTitleWidth : indicator
                indicatorX = control.midX - contentWidth / 2
            }
            disclosureView.frame = NSRect(
                x: indicatorX,
                y: control.midY - indicator / 2,
                width: indicator,
                height: indicator
            )
            actionButton.frame = .zero
            shortcutLabel.frame = .zero
            countLabel.frame = .zero
            badge.frame = .zero
            subtitleLabel.frame = .zero
            iconView.frame = .zero
            pinView.frame = .zero
            if showsTitle {
                let titleX = disclosureView.frame.maxX + gap
                let titleHeight = min(
                    control.height - 4 * controlScale,
                    ceil((titleLabel.font?.ascender ?? 12) - (titleLabel.font?.descender ?? -3)) + 2
                )
                let titleWidth = max(0, control.maxX - horizontalInset - titleX)
                titleLabel.frame = NSRect(
                    x: titleX,
                    y: control.midY - titleHeight / 2,
                    width: titleWidth,
                    height: titleHeight
                )
            } else {
                titleLabel.frame = .zero
            }
            renameField.frame = titleLabel.frame
            return
        }
        var x = 8 * scale + indent
        let iconSize = min(14 * scale, bounds.height - 8)
        for view in [disclosureView, iconView, pinView] where !view.isHidden {
            guard view !== iconView || iconView.image != nil else { continue }
            let width = view === disclosureView ? 10 * scale : iconSize
            view.frame = NSRect(x: x, y: (bounds.height - iconSize) / 2, width: width, height: iconSize)
            x += width + 4 * scale
        }
        if isGroup {
            x = max(x, groupControlFrame.maxX + 4 * scale)
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
        if hit === actionButton || hit.isDescendant(of: actionButton) { return actionButton }
        if hit === renameField || hit.isDescendant(of: renameField) { return hit }
        return self
    }

    override func draw(_ dirtyRect: NSRect) {
        let usesGroupControlBackground = isCompactGroup || fillsGroupRow
        let drawsItemBackground = isDropTarget || isSelected || isHovered || isGroup
        let shapeBounds = usesGroupControlBackground
            ? groupControlFrame
            : bounds.insetBy(dx: 0.5, dy: usesTabStripHoverTracking ? 6 : 1)
        let cornerRadius = min(
            (isCompactGroup ? 6 * compactGroupControlScale
                : (usesTabStripHoverTracking ? 7 : (isSidebar ? 6 : 12) * scale)),
            min(shapeBounds.width, shapeBounds.height) / 2
        )
        let shape = NSBezierPath(roundedRect: shapeBounds, xRadius: cornerRadius, yRadius: cornerRadius)
        if usesGroupControlBackground, let groupControlColor {
            (groupControlColor.blended(withFraction: 0.85, of: .white) ?? groupControlColor).setFill()
            shape.fill()
        }
        if usesGroupControlBackground && (isDropTarget || isSelected || isHovered) {
            (isDropTarget ? Theme.accent.withAlphaComponent(0.15)
                : NSColor.white.withAlphaComponent(isSelected ? 0.16 : 0.08)).setFill()
            shape.fill()
        } else if !usesGroupControlBackground && drawsItemBackground {
            (isDropTarget ? Theme.accent.withAlphaComponent(0.15)
                : NSColor.labelColor.withAlphaComponent(isSelected ? 0.09 : (isHovered ? 0.05 : 0.025))).setFill()
            shape.fill()
        }
        if usesGroupControlBackground, let groupControlColor {
            (isDropTarget ? Theme.accent : groupControlColor).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else if isDropTarget {
            Theme.accent.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        if !usesGroupControlBackground, let groupControlColor {
            groupControlColor.setFill()
            let radius = min(7 * groupControlScale, groupControlFrame.height / 2)
            NSBezierPath(roundedRect: groupControlFrame, xRadius: radius, yRadius: radius).fill()
        }
        if isGrouped && !isSidebar && !isGroup {
            Theme.accent.withAlphaComponent(0.45).setFill()
            NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 1).fill()
        }
        if let markerColor {
            markerColor.setFill()
            let thickness = max(1, ceil(1.5 * scale))
            if isSidebar {
                NSRect(x: indent, y: 4 * scale, width: thickness, height: max(0, bounds.height - 8 * scale)).fill()
            } else {
                NSRect(x: 2 * scale, y: bounds.maxY - thickness, width: max(0, bounds.width - 4 * scale), height: thickness).fill()
            }
        }
        if isDirty && actionButton.isHidden {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: actionButton.frame.midX - 2.5, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
        }
        if window?.firstResponder === self, !usesTabStripHoverTracking {
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
        let activeOption: NSTrackingArea.Options = usesTabStripHoverTracking ? .activeAlways : .activeInKeyWindow
        addTrackingArea(NSTrackingArea(rect: NSIntersectionRect(bounds, visibleRect),
            options: [activeOption, .mouseEnteredAndExited], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; updateActionVisibility(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateActionVisibility(); needsDisplay = true }

    override func scrollWheel(with event: NSEvent) {
        if let onScrollWheel {
            onScrollWheel(event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func updateActionVisibility() {
        actionButton.isHidden = !hasAction || isRenaming
        shortcutLabel.isHidden = isRenaming || !actionButton.isHidden || isDirty
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        mouseOrigin = event.locationInWindow
        hasDragged = false
        if event.clickCount == 2 {
            cancelPendingGroupSelection()
            mouseOrigin = nil
            onRename?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isRenaming, let mouseOrigin else { return }
        if !hasDragged {
            guard hypot(event.locationInWindow.x - mouseOrigin.x, event.locationInWindow.y - mouseOrigin.y) >= 4 else { return }
            cancelPendingGroupSelection()
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
        else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            if isGroup && onRename != nil && event.clickCount == 1 {
                let selectionID = UUID()
                pendingGroupSelectionID = selectionID
                let selection = DispatchWorkItem { [weak self] in
                    guard let self,
                          self.pendingGroupSelectionID == selectionID,
                          self.window != nil,
                          !self.isRenaming else { return }
                    self.pendingGroupSelection = nil
                    self.pendingGroupSelectionID = nil
                    self.onSelect?()
                }
                pendingGroupSelection = selection
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + NSEvent.doubleClickInterval,
                    execute: selection
                )
            } else {
                onSelect?()
            }
        }
        hasDragged = false
        NSCursor.arrow.set()
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, !isGroup { actionButton.onAction?() }
        else { super.otherMouseUp(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelPendingGroupSelection()
        window?.makeFirstResponder(self)
        guard let items = menuItems?(), !items.isEmpty else { return }
        menuPresenter.popUp(items: items, at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        cancelPendingGroupSelection()
        window?.makeFirstResponder(self)
        guard let items = menuItems?(), !items.isEmpty else { return false }
        menuPresenter.popUp(items: items, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }

    override func keyDown(with event: NSEvent) {
        cancelPendingGroupSelection()
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

    override func accessibilityPerformPress() -> Bool {
        cancelPendingGroupSelection()
        window?.makeFirstResponder(self)
        onSelect?()
        return onSelect != nil
    }

    private func cancelPendingGroupSelection() {
        pendingGroupSelection?.cancel()
        pendingGroupSelection = nil
        pendingGroupSelectionID = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelPendingGroupSelection() }
    }

    private func cancelMouseDrag() {
        cancelPendingGroupSelection()
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
        pendingGroupSelection?.cancel()
        if let dragCancelMonitor { NSEvent.removeMonitor(dragCancelMonitor) }
    }

    func beginRename(value: String, commit: @escaping (String) -> Void) {
        cancelPendingGroupSelection()
        guard !isRenaming else { return }
        let requestID = UUID()
        renameRequestID = requestID
        // Menu actions run inside AppKit's tracking loop. Waiting one turn lets
        // the menu dismiss before it gives the field editor its first responder.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.renameRequestID == requestID,
                  self.window != nil,
                  !self.isRenaming
            else { return }
            self.renameRequestID = nil
            self.startRename(value: value, commit: commit)
        }
    }

    private func startRename(value: String, commit: @escaping (String) -> Void) {
        renamePreviousResponder = window?.firstResponder
        renameCommit = commit
        renameField.stringValue = value
        renameField.setAccessibilityLabel(String(localized: "Name"))
        renameField.isHidden = false
        titleLabel.isHidden = true
        updateActionVisibility()
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectAll(nil)
    }

    private func finishRename(apply: Bool, restoreFocus: Bool = false) {
        guard let commit = renameCommit else { return }
        renameRequestID = nil
        let name = renameField.stringValue
        renameCommit = nil
        let responder = renamePreviousResponder
        renamePreviousResponder = nil
        if restoreFocus { window?.makeFirstResponder(nil) }
        renameField.isHidden = true
        titleLabel.isHidden = isCompactGroup && !showsCompactGroupTitle
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
