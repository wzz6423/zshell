import AppKit
import CoreGraphics

@MainActor
final class SettingsPermissionDragHelper {
    private let appURL: URL
    private let frameProvider: () -> NSRect?
    private var panel: NSPanel?
    private var positionTask: Task<Void, Never>?

    init(appURL: URL = Bundle.main.bundleURL, frameProvider: (() -> NSRect?)? = nil) {
        self.appURL = appURL
        self.frameProvider = frameProvider ?? Self.systemSettingsFrame
    }

    func show(relativeTo host: NSWindow?) {
        guard appURL.isFileURL, appURL.pathExtension == "app" else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, relativeTo: host)
        panel.orderFrontRegardless()
        positionTask?.cancel()
        // Settings can create its window after launch or move between displays during authorization.
        positionTask = Task { [weak self, weak host] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.position(panel, relativeTo: host)
            }
        }
    }

    func hide() {
        positionTask?.cancel()
        positionTask = nil
        panel?.orderOut(nil)
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

        let icon = SettingsPermissionAppIcon(appURL: appURL)
        let name = NSTextField(wrappingLabelWithString: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
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

    private func position(_ panel: NSPanel, relativeTo host: NSWindow?) {
        let settingsFrame = frameProvider()
        let reference = settingsFrame ?? host?.frame
        guard let screen = reference.flatMap({ frame in
            Self.screenIndex(for: frame, frames: NSScreen.screens.map(\.frame)).map { NSScreen.screens[$0] }
        }) ?? host?.screen ?? NSScreen.main else { return }
        let frame = Self.frame(size: panel.frame.size, nextTo: reference ?? screen.visibleFrame,
                               visibleFrame: screen.visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    static func frame(size: NSSize, nextTo reference: NSRect, visibleFrame: NSRect) -> NSRect {
        let inset: CGFloat = 12
        let right = reference.maxX + inset
        let left = reference.minX - inset - size.width
        let desiredX = right + size.width <= visibleFrame.maxX - inset ? right : left
        return NSRect(
            x: min(max(desiredX, visibleFrame.minX + inset), max(visibleFrame.minX + inset, visibleFrame.maxX - size.width - inset)),
            y: min(max(reference.maxY - size.height - 40, visibleFrame.minY + inset),
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
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return windowFrame(in: windows, ownerPIDs: pids, primaryScreenTop: CGDisplayBounds(CGMainDisplayID()).height)
    }

    static func windowFrame(in windows: [[String: Any]], ownerPIDs: Set<pid_t>, primaryScreenTop: CGFloat) -> NSRect? {
        var candidate: (rect: CGRect, isOnscreen: Bool)?
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, ownerPIDs.contains(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 300,
                  rect.height > 200 else { continue }
            // Hidden Settings windows still supply bounds while launch restores their visibility.
            let isOnscreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
            if let previous = candidate {
                if previous.isOnscreen && !isOnscreen { continue }
                if previous.isOnscreen == isOnscreen,
                   previous.rect.width * previous.rect.height >= rect.width * rect.height { continue }
            }
            candidate = (rect, isOnscreen)
        }
        guard let rect = candidate?.rect else { return nil }
        // Window metadata uses a top-left origin on the primary display; AppKit uses bottom-left.
        return NSRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }
}

final class SettingsPermissionAppIcon: NSImageView, NSDraggingSource {
    let appURL: URL

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

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
