import AppKit
import CoreGraphics

@MainActor
final class SettingsPermissionDragHelper: NSObject, NSWindowDelegate {
    private let appURL: URL
    private let frameProvider: () -> NSRect?
    private let dropTargetProvider: (NSPoint) -> Bool
    private var panel: NSPanel?
    private var positionTask: Task<Void, Never>?
    private var pendingFrame: NSRect?
    private var isDragging = false
    private var lastSettingsDropPoint: NSPoint?

    init(
        appURL: URL = Bundle.main.bundleURL, frameProvider: (() -> NSRect?)? = nil,
        dropTargetProvider: ((NSPoint) -> Bool)? = nil
    ) {
        self.appURL = appURL
        self.frameProvider = frameProvider ?? Self.systemSettingsFrame
        self.dropTargetProvider = dropTargetProvider ?? Self.isSystemSettingsDrop
        super.init()
    }

    func show() {
        guard appURL.isFileURL, appURL.pathExtension == "app", positionTask == nil else { return }
        if panel == nil { panel = makePanel() }
        updatePosition()
        // Wait through Settings' launch and minimize animations before presenting or moving the helper.
        positionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.updatePosition()
            }
        }
    }

    func hide() {
        positionTask?.cancel()
        positionTask = nil
        pendingFrame = nil
        isDragging = false
        lastSettingsDropPoint = nil
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        hide()
    }

    private func finishDrag(at point: NSPoint, operation: NSDragOperation) {
        let isSettingsDrop =
            !operation.isEmpty
            && (lastSettingsDropPoint == point || dropTargetProvider(point))
        isDragging = false
        pendingFrame = nil
        lastSettingsDropPoint = nil
        if isSettingsDrop { hide() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 184, height: 170),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.title = String(localized: "Permissions")
        panel.identifier = NSUserInterfaceItemIdentifier("permission-drag-helper")
        panel.delegate = self

        let icon = SettingsPermissionAppIcon(appURL: appURL)
        icon.onDragStarted = { [weak self] in
            self?.isDragging = true
            self?.lastSettingsDropPoint = nil
        }
        icon.onDragMoved = { [weak self] point in
            guard let self else { return }
            // A successful drop may immediately replace the destination with an authentication sheet.
            self.lastSettingsDropPoint = self.dropTargetProvider(point) ? point : nil
        }
        icon.onDragEnded = { [weak self] point, operation in self?.finishDrag(at: point, operation: operation) }
        let name = NSTextField(
            wrappingLabelWithString: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? appURL.deletingPathExtension().lastPathComponent)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        name.alignment = .center
        let instruction = NSTextField(wrappingLabelWithString: String(localized: "Drag this icon into the permission list."))
        instruction.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        instruction.textColor = .secondaryLabelColor
        instruction.alignment = .center
        let stack = NSStackView(views: [icon, name, instruction])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        let content = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            name.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instruction.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 184, height: max(170, stack.fittingSize.height + 32)))
        return panel
    }

    private func updatePosition() {
        guard !isDragging, let reference = frameProvider() else {
            pendingFrame = nil
            return
        }
        guard pendingFrame == reference else {
            pendingFrame = reference
            return
        }
        let screens = NSScreen.screens
        guard let panel, let screenIndex = Self.screenIndex(for: reference, frames: screens.map(\.frame)) else { return }
        let frame = Self.frame(size: panel.frame.size, nextTo: reference, visibleFrame: screens[screenIndex].visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    static func frame(size: NSSize, nextTo reference: NSRect, visibleFrame: NSRect) -> NSRect {
        let inset: CGFloat = 12
        let right = reference.maxX + inset
        let left = reference.minX - inset - size.width
        let desiredX = right + size.width <= visibleFrame.maxX - inset ? right : left
        return NSRect(
            x: min(max(desiredX, visibleFrame.minX + inset), max(visibleFrame.minX + inset, visibleFrame.maxX - size.width - inset)),
            y: min(
                max(reference.maxY - size.height - 40, visibleFrame.minY + inset),
                max(visibleFrame.minY + inset, visibleFrame.maxY - size.height - inset)),
            width: size.width, height: size.height
        )
    }

    static func screenIndex(for reference: NSRect, frames: [NSRect]) -> Int? {
        frames.indices.max { left, right in
            let leftIntersection = frames[left].intersection(reference)
            let rightIntersection = frames[right].intersection(reference)
            return leftIntersection.width * leftIntersection.height < rightIntersection.width * rightIntersection.height
        }
    }

    private static func systemSettingsFrame() -> NSRect? {
        let pids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .map(\.processIdentifier))
        guard !pids.isEmpty,
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        return windowFrame(in: windows, ownerPIDs: pids, primaryScreenTop: CGDisplayBounds(CGMainDisplayID()).height)
    }

    static func windowFrame(in windows: [[String: Any]], ownerPIDs: Set<pid_t>, primaryScreenTop: CGFloat) -> NSRect? {
        var candidate: CGRect?
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, ownerPIDs.contains(pid),
                window[kCGWindowLayer as String] as? Int == 0,
                window[kCGWindowIsOnscreen as String] as? Bool == true,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 300,
                rect.height > 200
            else { continue }
            if let previous = candidate,
                previous.width * previous.height >= rect.width * rect.height
            {
                continue
            }
            candidate = rect
        }
        guard let rect = candidate else { return nil }
        // Window metadata uses a top-left origin on the primary display; AppKit uses bottom-left.
        return NSRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func isSystemSettingsDrop(at point: NSPoint) -> Bool {
        let pids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .map(\.processIdentifier))
        guard !pids.isEmpty,
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        return isSystemSettingsDrop(
            at: point, in: windows, ownerPIDs: pids,
            primaryScreenTop: CGDisplayBounds(CGMainDisplayID()).height)
    }

    static func isSystemSettingsDrop(
        at point: NSPoint, in windows: [[String: Any]],
        ownerPIDs: Set<pid_t>, primaryScreenTop: CGFloat
    ) -> Bool {
        let location = CGPoint(x: point.x, y: primaryScreenTop - point.y)
        // Window metadata is front to back; a successful Finder copy must not dismiss this helper.
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                window[kCGWindowIsOnscreen as String] as? Bool == true,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(location)
            else { continue }
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return false }
            return ownerPIDs.contains(pid)
        }
        return false
    }
}

final class SettingsPermissionAppIcon: NSImageView, NSDraggingSource {
    let appURL: URL
    var onDragStarted: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint, NSDragOperation) -> Void)?

    init(appURL: URL) {
        self.appURL = appURL
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: appURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityLabel(String(localized: "Drag this app into System Settings"))
        setAccessibilityIdentifier("permission-app-icon")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let image else { return }
        let item = draggingItem()
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingItem() -> NSDraggingItem {
        // Drag the running bundle itself so Debug and Release grants cannot point at each other.
        NSDraggingItem(pasteboardWriter: appURL as NSURL)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragStarted?()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        onDragMoved?(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?(screenPoint, operation)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
