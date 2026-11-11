import AppKit
import Combine
import SwiftUI

struct PaneHeaderRepresentable: NSViewRepresentable {
    let content: PaneContent
    let isFocused: Bool
    let allowsMove: Bool
    let focus: () -> Void
    let onMove: (CGPoint) -> Void
    let onMoveEnded: () -> Void
    let onSplit: (PaneDropEdge) -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> PaneHeaderNSView { PaneHeaderNSView(frame: .zero) }

    func updateNSView(_ view: PaneHeaderNSView, context: Context) {
        view.configure(content: content, isFocused: isFocused, allowsMove: allowsMove,
            focus: focus, onMove: onMove, onMoveEnded: onMoveEnded, onSplit: onSplit, onClose: onClose)
    }
}

/// Uses the existing pane header space so closing a split never adds another toolbar.
final class PaneHeaderNSView: NSView {
    private let titleView = PaneHeaderTitleNSView(frame: .zero)
    private let splitRightButton = WorkspaceChromeButton(symbol: "rectangle.split.2x1", label: "")
    private let splitDownButton = WorkspaceChromeButton(symbol: "rectangle.split.1x2", label: "")
    let closeButton = WorkspaceChromeButton(symbol: "xmark", label: AppCommand.closePane.title)
    private var content: PaneContent?
    private var contentObservation: AnyCancellable?
    private var observations: [AnyCancellable] = []
    private var isFocused = false
    private var refreshScheduled = false
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [titleView, splitRightButton, splitDownButton, closeButton] { addSubview(view) }
        for publisher in [Theme.changes.objectWillChange.eraseToAnyPublisher(),
                          AppSettings.shared.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &observations)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        content: PaneContent, isFocused: Bool, allowsMove: Bool,
        focus: @escaping () -> Void, onMove: @escaping (CGPoint) -> Void,
        onMoveEnded: @escaping () -> Void, onSplit: @escaping (PaneDropEdge) -> Void,
        onClose: @escaping () -> Void
    ) {
        if self.content?.id != content.id {
            self.content = content
            let publisher: ObservableObjectPublisher
            switch content {
            case .session(let session): publisher = session.objectWillChange
            case .file(let file): publisher = file.objectWillChange
            case .browser(let browser): publisher = browser.objectWillChange
            case .diff(let diff): publisher = diff.objectWillChange
            }
            contentObservation = publisher.receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleRefresh() }
        }
        self.isFocused = isFocused
        titleView.allowsMove = allowsMove
        titleView.onFocus = focus
        titleView.onMove = onMove
        titleView.onMoveEnded = onMoveEnded
        splitRightButton.onAction = { focus(); onSplit(.right) }
        splitDownButton.onAction = { focus(); onSplit(.bottom) }
        closeButton.onAction = onClose
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        guard let content else { return }
        titleView.apply(content: content, isFocused: isFocused, appearance: effectiveAppearance)
        splitRightButton.configure(symbol: "rectangle.split.2x1", label: String(localized: "Split Right"), pointSize: 11)
        splitRightButton.toolTip = String(localized: "Split Right (⌘D)")
        splitDownButton.configure(symbol: "rectangle.split.1x2", label: String(localized: "Split Down"), pointSize: 11)
        splitDownButton.toolTip = String(localized: "Split Down (⇧⌘D)")
        closeButton.configure(symbol: "xmark", label: AppCommand.closePane.title, pointSize: 11)
        closeButton.toolTip = "\(AppCommand.closePane.title) (\(AppSettings.shared.commandShortcut(for: .closePane).displayString))"
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var right = max(0, bounds.width - 5)
        for button in [closeButton, splitDownButton, splitRightButton] {
            // Closing remains reachable even when a split is narrower than its full header.
            button.frame = NSRect(x: max(0, right - 24), y: (bounds.height - 24) / 2, width: 24, height: 24)
            right -= 28
        }
        splitDownButton.isHidden = bounds.width < 57
        splitRightButton.isHidden = bounds.width < 85
        titleView.frame = NSRect(x: 9, y: 0, width: max(0, right - 9), height: bounds.height)
        titleView.isHidden = titleView.frame.width == 0
    }

    override func draw(_ dirtyRect: NSRect) { Theme.background.setFill(); bounds.fill() }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
}

private final class PaneHeaderTitleNSView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badge = AgentStatusBadgeView(frame: .zero)
    private var isDirty = false
    private var badgeWidth: CGFloat = 0
    private var isHovered = false
    private var mouseOrigin: NSPoint?
    private var isDragging = false
    var allowsMove = false { didSet { if oldValue != allowsMove { window?.invalidateCursorRects(for: self) } } }
    var onFocus: (() -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isSelectable = false
        alphaValue = 0.9
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        badge.translatesAutoresizingMaskIntoConstraints = true
        for view in [iconView, titleLabel, badge] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(content: PaneContent, isFocused: Bool, appearance: NSAppearance) {
        titleLabel.stringValue = content.title
        titleLabel.textColor = isFocused ? .labelColor : .secondaryLabelColor
        let image: NSImage?
        if let path = content.fileIconPath {
            image = MaterialFileIcon.image(forPath: path, appearance: appearance)
        } else if case .browser(let browser) = content, let favicon = browser.favicon {
            image = favicon
        } else {
            image = NSImage(systemSymbolName: content.systemImage, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        }
        iconView.image = image
        iconView.contentTintColor = image?.isTemplate == true ? (isFocused ? Theme.accent : .tertiaryLabelColor) : nil
        iconView.alphaValue = isFocused ? 1 : 0.8
        let rollup: ZshellAgentRollup?
        if case .session(let session) = content { rollup = session.agentRollup } else { rollup = nil }
        if let rollup {
            badge.apply(phase: rollup.phase, count: rollup.count, detail: rollup.detail, progress: rollup.progress)
            badgeWidth = badge.intrinsicContentSize.width
        } else { badgeWidth = 0 }
        badge.isHidden = rollup == nil
        isDirty = content.isDirty
        toolTip = content.fileIconPath
        if case .browser(let browser) = content { toolTip = browser.urlString }
        setAccessibilityLabel(content.title)
        setAccessibilityValue([
            isFocused ? String(localized: "Selected") : nil,
            isDirty ? String(localized: "Modified") : nil,
            rollup.map { $0.phase.statusDescription + "\n" + $0.detail },
        ].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 0, y: (bounds.height - 13) / 2, width: 13, height: 13)
        let available = max(0, bounds.width - 19)
        let visibleBadgeWidth = min(badgeWidth, max(0, available - (isDirty ? 11 : 0)))
        badge.isHidden = visibleBadgeWidth == 0
        let titleWidth = min(ceil(titleLabel.attributedStringValue.size().width),
            max(0, available - (visibleBadgeWidth > 0 ? visibleBadgeWidth + 6 : 0) - (isDirty ? 11 : 0)))
        let height = ceil((titleLabel.font?.ascender ?? 12) - (titleLabel.font?.descender ?? -3)) + 2
        titleLabel.frame = NSRect(x: 19, y: (bounds.height - height) / 2, width: titleWidth, height: height)
        badge.frame = NSRect(x: titleLabel.frame.maxX + 6, y: (bounds.height - 15) / 2,
                            width: visibleBadgeWidth, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDirty {
            NSColor.secondaryLabelColor.setFill()
            let x = badge.isHidden ? titleLabel.frame.maxX + 6 : badge.frame.maxX + 6
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func resetCursorRects() { if allowsMove { addCursorRect(bounds, cursor: .openHand) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: NSIntersectionRect(bounds, visibleRect),
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        alphaValue = 1
        if allowsMove && !isDragging { NSCursor.openHand.set() }
    }

    override func mouseMoved(with event: NSEvent) { if allowsMove && !isDragging { NSCursor.openHand.set() } }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        alphaValue = 0.9
        if !isDragging { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) { mouseOrigin = event.locationInWindow; isDragging = false }

    override func mouseDragged(with event: NSEvent) {
        guard allowsMove, let mouseOrigin else { return }
        if !isDragging {
            guard hypot(event.locationInWindow.x - mouseOrigin.x, event.locationInWindow.y - mouseOrigin.y) >= 4 else { return }
            isDragging = true
        }
        NSCursor.closedHand.set()
        onMove?(workspaceGlobalPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseOrigin != nil else { return }
        mouseOrigin = nil
        if isDragging { onMoveEnded?() }
        else if bounds.contains(convert(event.locationInWindow, from: nil)) { onFocus?() }
        isDragging = false
        (isHovered && allowsMove ? NSCursor.openHand : NSCursor.arrow).set()
    }

    override func accessibilityPerformPress() -> Bool { onFocus?(); return onFocus != nil }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onFocus?() } else { super.keyDown(with: event) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { mouseOrigin = nil; isDragging = false }
    }
}
