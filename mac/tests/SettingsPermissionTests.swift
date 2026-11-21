import AppKit
import Foundation

@MainActor
private final class PermissionFixture {
    var statuses: [SettingsPermission: SettingsPermissionStatus] = [:]
    var reads: [(SettingsPermission, SettingsPermissionCoordinator.Completion)] = []
    var requests: [(SettingsPermission, SettingsPermissionCoordinator.RequestCompletion)] = []
    var opened: [URL] = []
    var deferReads = false
    var canOpen = true

    func makeCoordinator() -> SettingsPermissionCoordinator {
        SettingsPermissionCoordinator(
            dependencies: .init(
                read: { [self] permission, completion in
                    if deferReads {
                        reads.append((permission, completion))
                    } else {
                        completion(statuses[permission] ?? (permission.requiresSystemSettings ? .manual : .notDetermined))
                    }
                },
                request: { [self] in requests.append(($0, $1)) },
                openSettings: { [self] in
                    opened.append($0); return canOpen
                }
            ))
    }
}

@main
struct SettingsPermissionTests {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        testActions()
        testStaleReads()
        await testDragHelper()
        testSettingsWindowPosition()
        testPane()
        print("PASS permission actions, stale callbacks, native pane, and running-app drag payload")
    }

    @MainActor private static func testActions() {
        let fixture = PermissionFixture()
        let coordinator = fixture.makeCoordinator()
        var helpers: [SettingsPermission] = []
        coordinator.onOpenSettings = { helpers.append($0) }
        coordinator.activate()
        precondition(fixture.requests.isEmpty && fixture.opened.isEmpty, "Viewing permissions must never request them")
        precondition(coordinator.statuses[.fullDiskAccess] == .manual, "Manual permissions must not invent authorization state")

        coordinator.performAction(for: .camera)
        coordinator.performAction(for: .camera)
        coordinator.performAction(for: .microphone)
        precondition(fixture.requests.count == 1 && coordinator.requesting == .camera, "One system prompt must be serialized")
        fixture.statuses[.camera] = .granted
        fixture.requests.removeFirst().1(.success(.granted))
        precondition(coordinator.statuses[.camera] == .granted && coordinator.requesting == nil)

        coordinator.performAction(for: .microphone)
        fixture.statuses[.microphone] = .denied
        fixture.requests.removeFirst().1(.success(.denied))
        coordinator.performAction(for: .microphone)
        precondition(fixture.opened.last == SettingsPermission.microphone.settingsURL)
        precondition(fixture.requests.isEmpty, "A denied permission must open Settings rather than request again")

        coordinator.performAction(for: .accessibility)
        fixture.requests.removeFirst().1(.success(.denied))
        precondition(helpers.last == .accessibility, "Boolean privacy prompts must lead to the app drag helper")
        coordinator.refresh()
        precondition(coordinator.statuses[.accessibility] == .denied, "Boolean preflight must preserve a known denial")
        fixture.statuses[.accessibility] = .granted
        coordinator.refresh()
        precondition(coordinator.statuses[.accessibility] == .granted, "Returning from Settings must reflect a new grant")

        fixture.canOpen = false
        let count = helpers.count
        coordinator.performAction(for: .fullDiskAccess)
        precondition(
            coordinator.failures[.fullDiskAccess] != nil && helpers.count == count,
            "A failed Settings launch must show an error and keep the helper hidden")
        fixture.canOpen = true
        coordinator.performAction(for: .fullDiskAccess)
        precondition(coordinator.failures[.fullDiskAccess] == nil && helpers.last == .fullDiskAccess)

        coordinator.performAction(for: .screenRecording)
        coordinator.deactivate()
        fixture.requests.removeFirst().1(.success(.denied))
        precondition(helpers.last == .fullDiskAccess, "A hidden pane must not launch Settings after a delayed answer")
        coordinator.activate()
        coordinator.performAction(for: .inputMonitoring)
        fixture.requests.removeFirst().1(.failure(CocoaError(.userCancelled)))
        precondition(coordinator.failures[.inputMonitoring] != nil && coordinator.requesting == nil)
    }

    @MainActor private static func testStaleReads() {
        let fixture = PermissionFixture()
        fixture.deferReads = true
        let coordinator = fixture.makeCoordinator()
        coordinator.activate()
        let obsolete = fixture.reads
        fixture.reads.removeAll()
        coordinator.refresh()
        fixture.reads.forEach { $0.1(.granted) }
        obsolete.forEach { $0.1(.denied) }
        precondition(coordinator.statuses[.camera] == .granted, "Old refresh answers must not replace current grants")
        fixture.reads.removeAll()
        coordinator.refresh()
        coordinator.deactivate()
        fixture.reads.forEach { $0.1(.denied) }
        precondition(coordinator.statuses[.camera] == .granted, "Hidden panes must ignore refresh callbacks")

        coordinator.deactivate()
        let opened = fixture.opened.count
        coordinator.performAction(for: .microphone)
        precondition(fixture.opened.count == opened, "Inactive views must not navigate")
    }

    @MainActor private static func testDragHelper() async {
        let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let host = NSWindow(
            contentRect: NSRect(x: 180, y: 160, width: 700, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        var settingsFrame: NSRect?
        var isSettingsDrop = false
        let helper = SettingsPermissionDragHelper(
            appURL: appURL, frameProvider: { settingsFrame },
            dropTargetProvider: { _ in isSettingsDrop })
        helper.show()
        guard let panel = NSApp.windows.first(where: { $0.identifier?.rawValue == "permission-drag-helper" }) as? NSPanel,
            let icon = descendants(panel.contentView!).compactMap({ $0 as? SettingsPermissionAppIcon }).first
        else {
            preconditionFailure("The helper must present a real app icon")
        }
        precondition(
            !panel.isVisible && !panel.hidesOnDeactivate && panel.styleMask.contains(.nonactivatingPanel),
            "The helper must wait for the visible Settings window without activating Zshell")
        try? await Task.sleep(for: .milliseconds(350))
        precondition(!panel.isVisible, "An absent Settings window must not show a helper at a fallback position")
        precondition(icon.appURL == appURL && icon.image != nil)
        let content = panel.contentView!
        content.layoutSubtreeIfNeeded()
        let stack = content.subviews.compactMap { $0 as? NSStackView }.first!
        precondition(
            abs(stack.frame.midX - content.bounds.midX) < 0.5
                && abs(stack.frame.midY - content.bounds.midY) < 0.5,
            "The complete icon, name, and instruction group must be centered")
        let item = icon.draggingItem()
        precondition((item.item as? NSURL) as URL? == appURL, "Dragging must transfer the running .app, not its image or executable")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("zshell-permission-test-" + UUID().uuidString))
        pasteboard.writeObjects([item.item as! NSPasteboardWriting])
        precondition(pasteboard.types?.contains(.fileURL) == true)
        precondition(URL(string: pasteboard.string(forType: .fileURL) ?? "") == appURL)
        pasteboard.releaseGlobally()
        let initial = panel.frame
        guard let visible = host.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            preconditionFailure("The native test requires a display")
        }
        settingsFrame = visible.insetBy(dx: 200, dy: 150)
        try? await Task.sleep(for: .milliseconds(650))
        let appeared = SettingsPermissionDragHelper.frame(size: panel.frame.size, nextTo: settingsFrame!, visibleFrame: visible)
        precondition(
            panel.isVisible && panel.frame == appeared && panel.frame != initial,
            "The helper must wait for Settings to appear instead of keeping its launch fallback")
        helper.show()
        precondition(panel.isVisible && panel.frame == appeared, "Repeated requests must reuse the visible helper without flashing")
        settingsFrame = settingsFrame!.offsetBy(dx: -80, dy: 30)
        let dragSession = NSDraggingSession()
        icon.draggingSession(dragSession, willBeginAt: .zero)
        try? await Task.sleep(for: .milliseconds(650))
        precondition(panel.frame == appeared, "An active drag must keep its source panel still when Settings moves")
        icon.draggingSession(dragSession, endedAt: .zero, operation: [])
        try? await Task.sleep(for: .milliseconds(650))
        precondition(
            panel.frame == SettingsPermissionDragHelper.frame(size: panel.frame.size, nextTo: settingsFrame!, visibleFrame: visible)
                && panel.frame != appeared, "The visible helper must follow a moved Settings window")

        let lastVisibleFrame = panel.frame
        settingsFrame = nil
        try? await Task.sleep(for: .milliseconds(650))
        precondition(
            panel.isVisible && panel.frame == lastVisibleFrame,
            "Minimizing or hiding Settings must preserve the helper's last position")
        icon.draggingSession(dragSession, willBeginAt: .zero)
        precondition(panel.isVisible, "Starting a drag must leave the helper visible")
        icon.draggingSession(dragSession, endedAt: .zero, operation: [])
        precondition(panel.isVisible, "Cancelling or rejecting a drop must preserve the helper")
        icon.draggingSession(dragSession, endedAt: .zero, operation: .copy)
        precondition(panel.isVisible, "A successful copy to Finder must preserve the permission helper")
        isSettingsDrop = true
        icon.draggingSession(dragSession, endedAt: .zero, operation: [])
        precondition(panel.isVisible, "A cancelled Settings drop must not dismiss the helper")
        icon.draggingSession(dragSession, willBeginAt: .zero)
        icon.draggingSession(dragSession, movedTo: .zero)
        isSettingsDrop = false
        let finderPoint = NSPoint(x: 40, y: 40)
        icon.draggingSession(dragSession, movedTo: finderPoint)
        icon.draggingSession(dragSession, endedAt: finderPoint, operation: .copy)
        precondition(panel.isVisible, "Moving from Settings to Finder must clear the remembered drop target")
        isSettingsDrop = true
        icon.draggingSession(dragSession, willBeginAt: .zero)
        icon.draggingSession(dragSession, movedTo: .zero)
        isSettingsDrop = false
        icon.draggingSession(dragSession, endedAt: .zero, operation: .copy)
        precondition(!panel.isVisible, "Only an accepted drop into System Settings should hide the helper")
        settingsFrame = visible.insetBy(dx: 250, dy: 100)
        try? await Task.sleep(for: .milliseconds(650))
        precondition(!panel.isVisible, "A completed drop must cancel tracking so the helper cannot reappear")

        helper.show()
        try? await Task.sleep(for: .milliseconds(650))
        precondition(panel.isVisible, "A new permission action may show the helper again")
        helper.hide()
        precondition(!panel.isVisible)
        let hiddenFrame = panel.frame
        settingsFrame = settingsFrame!.offsetBy(dx: 120, dy: -30)
        try? await Task.sleep(for: .milliseconds(350))
        precondition(panel.frame == hiddenFrame, "Hidden helpers must stop tracking external windows")
        settingsFrame = nil
        helper.show()
        helper.hide()
        settingsFrame = visible.insetBy(dx: 200, dy: 150)
        try? await Task.sleep(for: .milliseconds(650))
        precondition(!panel.isVisible, "Hiding a waiting helper must cancel its pending appearance")
        settingsFrame = nil
        helper.show()
        panel.close()
        settingsFrame = visible.insetBy(dx: 200, dy: 150)
        try? await Task.sleep(for: .milliseconds(650))
        precondition(!panel.isVisible, "Closing the helper must cancel an outstanding wait for Settings")
        host.close()

        for visible in [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: -1440, y: 0, width: 1440, height: 900),
        ] {
            for reference in [visible.insetBy(dx: 100, dy: 100), visible.offsetBy(dx: 1000, dy: 0)] {
                let frame = SettingsPermissionDragHelper.frame(
                    size: NSSize(width: 184, height: 192),
                    nextTo: reference, visibleFrame: visible)
                precondition(visible.contains(frame), "The helper must stay on its display even when Settings is near an edge")
            }
        }
        precondition(SettingsPermission.allCases.filter(\.supportsAppDrop).count == 4)
    }

    @MainActor private static func testSettingsWindowPosition() {
        func window(pid: Int32 = 31446, rect: NSRect, onscreen: Bool? = nil, layer: Int = 0) -> [String: Any] {
            var metadata: [String: Any] = [
                kCGWindowOwnerPID as String: NSNumber(value: pid),
                kCGWindowLayer as String: layer,
                kCGWindowBounds as String: rect.dictionaryRepresentation,
            ]
            if let onscreen { metadata[kCGWindowIsOnscreen as String] = onscreen }
            return metadata
        }
        let settingsRect = NSRect(x: 750, y: 170, width: 754, height: 747)
        let hiddenSettings = window(rect: settingsRect)
        let menu = window(rect: NSRect(x: 0, y: 0, width: 1512, height: 33))
        let unrelated = window(pid: 123, rect: NSRect(x: 0, y: 0, width: 1500, height: 900), onscreen: true)
        let expected = NSRect(x: 750, y: 65, width: 754, height: 747)
        precondition(
            SettingsPermissionDragHelper.windowFrame(
                in: [menu, unrelated, hiddenSettings],
                ownerPIDs: [31446], primaryScreenTop: 982) == nil,
            "Hidden Settings windows and menu bars must not position the helper")
        let visibleSettings = window(rect: settingsRect, onscreen: true)
        precondition(
            SettingsPermissionDragHelper.windowFrame(
                in: [menu, unrelated, hiddenSettings, visibleSettings],
                ownerPIDs: [31446], primaryScreenTop: 982) == expected,
            "Only a visible Settings window supplies the helper position")

        let movedRect = NSRect(x: -1300, y: -400, width: 754, height: 747)
        precondition(
            SettingsPermissionDragHelper.windowFrame(
                in: [hiddenSettings, window(rect: movedRect, onscreen: true)],
                ownerPIDs: [31446], primaryScreenTop: 982)?.origin == NSPoint(x: -1300, y: 635),
            "A visible Settings window must win over a hidden window and track moves above the primary display")
        precondition(SettingsPermissionDragHelper.windowFrame(in: [], ownerPIDs: [31446], primaryScreenTop: 982) == nil)

        let dropPoint = NSPoint(x: expected.midX, y: expected.midY)
        precondition(
            SettingsPermissionDragHelper.isSystemSettingsDrop(
                at: dropPoint, in: [visibleSettings],
                ownerPIDs: [31446], primaryScreenTop: 982), "A successful drop must target the Settings window")
        precondition(
            !SettingsPermissionDragHelper.isSystemSettingsDrop(
                at: dropPoint, in: [unrelated, visibleSettings],
                ownerPIDs: [31446], primaryScreenTop: 982), "An unrelated window covering Settings must not count as its drop target")
        precondition(
            !SettingsPermissionDragHelper.isSystemSettingsDrop(
                at: dropPoint, in: [hiddenSettings],
                ownerPIDs: [31446], primaryScreenTop: 982), "Hidden Settings bounds must not count as a drop target")

        let displays = [
            NSRect(x: 0, y: 0, width: 1512, height: 982),
            NSRect(x: -1440, y: 0, width: 1440, height: 900),
        ]
        precondition(
            SettingsPermissionDragHelper.screenIndex(
                for: NSRect(x: -600, y: 100, width: 754, height: 747),
                frames: displays) == 1, "A window spanning displays must use the display containing most of it")
        let helperSize = NSSize(width: 184, height: 194)
        let first = SettingsPermissionDragHelper.frame(size: helperSize, nextTo: expected, visibleFrame: displays[0])
        let moved = SettingsPermissionDragHelper.frame(
            size: helperSize,
            nextTo: NSRect(x: -1300, y: 100, width: 754, height: 747), visibleFrame: displays[1])
        precondition(
            first.origin != moved.origin && displays[1].contains(moved),
            "The helper position must follow Settings to its new display")
    }

    @MainActor private static func testPane() {
        let fixture = PermissionFixture()
        let pane = SettingsPermissionsPane(coordinator: fixture.makeCoordinator())
        pane.setCategory(.permissions)
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentViewController = pane
        host.contentView?.layoutSubtreeIfNeeded()
        let rows = descendants(pane.view).compactMap { $0 as? SettingsRow }
        let buttons = descendants(pane.view).compactMap { $0 as? NSButton }
        precondition(rows.count == 9)
        precondition(buttons.filter { $0.accessibilityIdentifier().hasPrefix("permission-") }.count == 9)
        precondition(fixture.requests.isEmpty && fixture.opened.isEmpty)
        for permission in SettingsPermission.allCases {
            precondition(pane.revealSearchResult(permission.title), "Every permission search destination must reveal a real row")
        }
        host.close()
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
