import AppKit
import ObjectiveC.runtime
#if ZSHELL_POINTER_FOCUS_APP
@testable import zshell
#else
struct AppSettings {
    static var shared = AppSettings()
    var focusFollowsMouse = false
    var isTerminalBackgroundBlurActive = false
}
struct OverlayScrollbarView { static let stripWidth: CGFloat = 12 }
protocol TerminalBackendSurface: NSView { func setSurfaceVisible(_ visible: Bool) }
struct TerminalCommandRouting {
    static var blocks = false
    static func isBlockingCommands(in window: NSWindow?) -> Bool { blocks }
}
final class FocusSurface: NSView, TerminalBackendSurface {
    var onFocus: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { onFocus?(); return true }
    func setSurfaceVisible(_ visible: Bool) {}
}
#endif

@MainActor
private enum PointerFocusInputFixture {
    static var pressedButtons = 0

    static func exchangeButtonGetter() {
        let original = class_getClassMethod(NSEvent.self, NSSelectorFromString("pressedMouseButtons"))!
        let fixture = class_getClassMethod(NSEvent.self, NSSelectorFromString("pointerFocus_pressedMouseButtons"))!
        method_exchangeImplementations(original, fixture)
    }
}

extension NSEvent {
    @objc(pointerFocus_pressedMouseButtons) class func pointerFocus_pressedMouseButtons() -> Int {
        MainActor.assumeIsolated { PointerFocusInputFixture.pressedButtons }
    }
}

@MainActor
final class FocusWindow: NSPanel {
    var fixtureKey = true
    var fixtureVisible = true
    var fixtureMiniaturized = false
    var fixtureSheet: NSWindow?
    var pointer = NSPoint(x: -50, y: -50)
    override var isKeyWindow: Bool { fixtureKey }
    override var isVisible: Bool { fixtureVisible }
    override var isMiniaturized: Bool { fixtureMiniaturized }
    override var attachedSheet: NSWindow? { fixtureSheet }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}
final class PassthroughScrollbar: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@main
struct FocusProbe {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        PointerFocusInputFixture.exchangeButtonGetter()
        defer { PointerFocusInputFixture.exchangeButtonGetter() }
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            guard value else { fatalError(message) }
        }
        let window = FocusWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 500, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = root
        let left = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
        let right = TerminalContainerView(frame: NSRect(x: 260, y: 0, width: 240, height: 300))
        left.focusOnAppear = false
        right.focusOnAppear = false
#if ZSHELL_POINTER_FOCUS_APP
        let backend = CommandLine.arguments[1] == "ghostty" ? TerminalBackend.libghostty : .alacritty
        let launch = TerminalLaunch(program: "/bin/cat", arguments: [], commandLine: "/bin/cat",
                                    interactiveShell: nil, workingDirectory: NSTemporaryDirectory(),
                                    environment: ["TERM": "xterm-256color", "LC_ALL": "en_US.UTF-8"])
        let a = backend.makeSurface(launch: launch)!
        let b = backend.makeSurface(launch: launch)!
        defer {
            for surface in [a, b] {
                surface.onBecomeFirstResponder = nil
                surface.setSurfaceVisible(false)
                surface.detach()
                surface.removeFromSuperview()
            }
            window.contentView = nil
        }
#else
        let a = FocusSurface()
        let b = FocusSurface()
#endif
        var focused = ""
        var callbacks = 0
#if ZSHELL_POINTER_FOCUS_APP
        a.onBecomeFirstResponder = { focused = "left"; callbacks += 1 }
        b.onBecomeFirstResponder = { focused = "right"; callbacks += 1 }
#else
        a.onFocus = { focused = "left"; callbacks += 1 }
        b.onFocus = { focused = "right"; callbacks += 1 }
#endif
        root.addSubview(left)
        root.addSubview(right)
        left.mount(a, scrollbar: PassthroughScrollbar())
        right.mount(b, scrollbar: PassthroughScrollbar())
        root.layoutSubtreeIfNeeded()
        left.updateTrackingAreas()
        right.updateTrackingAreas()
        check(window.makeFirstResponder(a), "fixture can focus first terminal")
        func move(_ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) {
            window.pointer = point
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            left.mouseMoved(with: event)
            right.mouseMoved(with: event)
        }
        func enterRight(_ flags: NSEvent.ModifierFlags = []) { move(NSPoint(x: 250, y: 100)); move(NSPoint(x: 300, y: 100), flags) }
        func enterLeft(_ flags: NSEvent.ModifierFlags = []) { move(NSPoint(x: 250, y: 100)); move(NSPoint(x: 100, y: 100), flags) }
        enterRight()
        check(window.firstResponder === a && focused == "left", "default leaves focus unchanged")
        AppSettings.shared.focusFollowsMouse = true
        move(NSPoint(x: 320, y: 110))
        check(window.firstResponder === a, "enabling while pointer is inside does not switch focus")
        enterRight()
        check(window.firstResponder === b && focused == "right", "real entry focuses right and invokes model callback")
        let lastCallbacks = callbacks
        move(NSPoint(x: 330, y: 120))
        check(callbacks == lastCallbacks, "movement inside the pane does not refocus")
        enterLeft()
        check(window.firstResponder === a && focused == "left", "real entry focuses left")
        AppSettings.shared.focusFollowsMouse = false
        enterRight()
        check(window.firstResponder === a, "live disable takes effect")
        AppSettings.shared.focusFollowsMouse = true
        for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            enterRight(flags)
            check(window.firstResponder === a, "modifier gesture does not switch focus")
            move(NSPoint(x: 310, y: 110))
            check(window.firstResponder === a, "modifier release inside does not switch focus")
        }
        PointerFocusInputFixture.pressedButtons = 1
        enterRight()
        check(window.firstResponder === a, "pressed mouse button keeps selection or drag focus")
        PointerFocusInputFixture.pressedButtons = 0
        move(NSPoint(x: 310, y: 110))
        check(window.firstResponder === a, "releasing a drag inside does not switch focus")
        move(NSPoint(x: 250, y: 100))
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 300, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 1)!
        right.mouseMoved(with: drag)
        check(window.firstResponder === a, "drag events never focus a different pane")
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        enterRight()
        check(window.firstResponder === a, "menu tracking blocks pointer focus")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        enterRight()
        check(window.firstResponder === b, "pointer focus resumes after menu closes")
        enterLeft()
        let popover = NSPopover()
        NotificationCenter.default.post(name: NSPopover.willShowNotification, object: popover)
        enterRight()
        check(window.firstResponder === a, "popover blocks pointer focus")
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: popover)
        enterRight()
        check(window.firstResponder === b, "pointer focus resumes after popover closes")
        enterLeft()
        let sheet = NSWindow()
        sheet.isReleasedWhenClosed = false
        window.fixtureSheet = sheet
        enterRight()
        check(window.firstResponder === a, "sheet blocks pointer focus")
        window.fixtureSheet = nil
        window.fixtureKey = false
        enterRight()
        check(window.firstResponder === a, "non-key window does not switch focus")
        window.fixtureKey = true
        window.fixtureVisible = false
        enterRight()
        check(window.firstResponder === a, "hidden window does not switch focus")
        window.fixtureVisible = true
        window.fixtureMiniaturized = true
        enterRight()
        check(window.firstResponder === a, "miniaturized window does not switch focus")
        window.fixtureMiniaturized = false
        window.styleMask = [.borderless]
        enterRight()
        check(!NSApp.isActive && window.firstResponder === a, "inactive ordinary window does not switch focus")
        window.styleMask = [.borderless, .nonactivatingPanel]
#if ZSHELL_POINTER_FOCUS_APP
        let blockItem = a.commandRouting.contextMenuItem()
        check(NSApp.sendAction(blockItem.action!, to: blockItem.target, from: blockItem), "enable terminal command blocking")
#else
        TerminalCommandRouting.blocks = true
#endif
        enterRight()
        check(window.firstResponder === a, "terminal command blocking preserves focus")
#if ZSHELL_POINTER_FOCUS_APP
        check(NSApp.sendAction(blockItem.action!, to: blockItem.target, from: blockItem), "disable terminal command blocking")
#else
        TerminalCommandRouting.blocks = false
#endif
        let field = NSTextView(frame: NSRect(x: 5, y: 5, width: 30, height: 20))
        root.addSubview(field)
        check(window.makeFirstResponder(field), "fixture can focus editor")
        enterRight()
        check(window.firstResponder === field, "text editing keeps keyboard focus")
        field.removeFromSuperview()
        check(window.makeFirstResponder(a), "return focus")
        let overlay = NSView(frame: root.bounds)
        root.addSubview(overlay, positioned: .above, relativeTo: right)
        enterRight()
        check(window.firstResponder === a, "covering overlay blocks focus")
        overlay.removeFromSuperview()
        right.isHidden = true
        enterRight()
        check(window.firstResponder === a, "hidden pane does not switch focus")
        right.isHidden = false
        move(NSPoint(x: 310, y: 110))
        check(window.firstResponder === a, "unhiding pane under pointer does not switch focus")
        right.updateTrackingAreas()
        let rebuiltExit = NSEvent.enterExitEvent(with: .mouseExited, location: window.pointer,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)!
        right.mouseExited(with: rebuiltExit)
        move(NSPoint(x: 320, y: 120))
        check(window.firstResponder === a, "tracking rebuild under pointer does not switch focus")
        enterRight()
        check(window.firstResponder === b, "entry resumes after tracking rebuild")
        enterLeft()
        move(NSPoint(x: 300, y: 100))
        check(window.makeFirstResponder(a), "restore keyboard-focused left pane")
        let syntheticEnter = NSEvent.enterExitEvent(with: .mouseEntered, location: window.pointer,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)!
        right.mouseEntered(with: syntheticEnter)
        check(window.firstResponder === a, "synthetic enter does not switch keyboard focus")
        right.releaseTerminal(b)
        enterRight()
        check(window.firstResponder === a, "released pane does not switch focus")
        right.removeFromSuperview()
        enterRight()
        check(window.firstResponder === a, "unmounted pane does not switch focus")
        check(!NSApp.isActive, "offscreen probe never activates the app")
#if ZSHELL_POINTER_FOCUS_APP
        verifySettings(check)
        verifyQuickTerminal(check)
        print("PointerFocus: \(checks) production AppKit, \(backend.displayName) surface, settings and Quick Terminal checks passed")
#else
        print("PointerFocus: \(checks) production-container AppKit checks passed")
#endif
    }
}

#if ZSHELL_POINTER_FOCUS_APP
extension FocusProbe {
    @MainActor private static func verifySettings(_ check: (Bool, String) -> Void) {
        let settings = AppSettings.shared
        let controller = SettingsTerminalPane()
        _ = controller.view
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let label = String(localized: "Focus follows mouse")
        let toggle = descendants(controller.view).compactMap { $0 as? NSSwitch }
            .first { $0.accessibilityLabel() == label }
        check(toggle != nil, "native settings switch has a VoiceOver label")
        settings.focusFollowsMouse = false
        controller.syncFromSettings()
        check(toggle?.state == .off, "settings switch reflects live disable")
        toggle?.state = .on
        check(NSApp.sendAction(toggle!.action!, to: toggle!.target, from: toggle!), "native switch sends its action")
        check(settings.focusFollowsMouse, "native switch enables pointer focus")
        settings.focusFollowsMouse = false
        controller.syncFromSettings()
        check(toggle?.state == .off, "settings reflects external disable")
        check(SettingsSearchIndex.results(for: "terminal.focus-follows-mouse").contains { $0.category == .terminal && $0.title == label },
              "settings search finds pointer focus by its config key")
        settings.focusFollowsMouse = true
    }

    @MainActor private static func verifyQuickTerminal(_ check: (Bool, String) -> Void) {
        let settings = AppSettings.shared
        settings.preserveTerminalSessions = false
        settings.restoreTerminalHistory = false
        settings.terminalBackend = CommandLine.arguments[1] == "ghostty" ? .libghostty : .alacritty
        let directory = FileManager.default.homeDirectoryForCurrentUser.path
        let first = TerminalSession(initialDirectory: directory, commandArguments: ["/bin/cat"], allowsPersistence: false)
        let second = TerminalSession(initialDirectory: directory, commandArguments: ["/bin/cat"], allowsPersistence: false)
        let left = Pane(content: .session(first))
        let right = Pane(content: .session(second))
        let tab = PaneTab(layout: .split(PaneSplit(axis: .horizontal, fraction: 0.5,
                                first: .pane(left), second: .pane(right))), focusedPaneID: left.id)
        let workspace = QuickTerminalWorkspaceView(tab: tab, split: { _ in }, close: {})
        workspace.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        let window = FocusWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 800, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = workspace
        defer {
            for session in [first, second] { session.terminate() }
            window.contentView = nil
        }
        workspace.layoutSubtreeIfNeeded()
        func containers(in view: NSView) -> [TerminalContainerView] {
            (view as? TerminalContainerView).map { [$0] } ?? view.subviews.flatMap(containers)
        }
        // The initial Combine delivery applies split fractions after AppKit
        // has assigned the window geometry.
        let layoutDeadline = Date().addingTimeInterval(3)
        while Date() < layoutDeadline,
              containers(in: workspace).contains(where: { $0.bounds.width < 100 }) {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            workspace.layoutSubtreeIfNeeded()
        }
        let hosts = containers(in: workspace)
        check(hosts.count == 2, "Quick Terminal reuses two production terminal containers")
        check(hosts.allSatisfy { $0.bounds.width > 100 }, "Quick Terminal finishes its production split layout")
        hosts.forEach { $0.updateTrackingAreas() }
        let firstHost = hosts.first { $0.terminal === first.surface }!
        let secondHost = hosts.first { $0.terminal === second.surface }!
        check(window.makeFirstResponder(first.surface), "Quick Terminal initially focuses first surface")
        func move(to host: TerminalContainerView) {
            let separator = NSPoint(x: 400, y: 100)
            for point in [separator, host.convert(NSPoint(x: 40, y: 100), to: nil)] {
                window.pointer = point
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                hosts.forEach { $0.mouseMoved(with: event) }
            }
        }
        move(to: secondHost)
        check(window.firstResponder === second.surface && tab.focusedPaneID == right.id,
              "Quick Terminal pointer focus updates surface and pane model")
        move(to: firstHost)
        check(window.firstResponder === first.surface && tab.focusedPaneID == left.id,
              "Quick Terminal switches back through the same callback")
        settings.focusFollowsMouse = false
        move(to: secondHost)
        check(window.firstResponder === first.surface && tab.focusedPaneID == left.id,
              "Quick Terminal honors live disable")
    }
}
#endif
