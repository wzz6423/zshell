import AppKit
import GhosttyTerminal
@testable import zshell

@MainActor private final class RightClickApplication: NSApplication {
    var inputEvent: NSEvent?
    var fixtureWindow: NSWindow?
    override var currentEvent: NSEvent? { inputEvent ?? super.currentEvent }
    override var keyWindow: NSWindow? { fixtureWindow ?? super.keyWindow }
}

@MainActor private final class RightClickWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor private final class RightClickEvents: TerminalBackendEvents {
    let terminalPromptSelectionIsReady = false
    let terminalPromptQueueIsReady = false
    var confirmations: [TerminalClipboardRequest] = []
    var pasteCalls = 0
    func terminalDidChangeTitle(_ title: String) {}
    func terminalDidChangeWorkingDirectory(_ path: String) {}
    func terminalDidChangeCellSize(_ size: CGSize) {}
    func terminalDidRingBell() {}
    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent) {}
    func terminalDidClose(processAlive: Bool) {}
    func terminalDidRequestDesktopNotification(title: String, body: String) {}
    func terminalDidRequestOpenURL(_ url: String) {}
    func terminalLinkTarget(for value: String) -> TerminalLinkTarget? { nil }
    func terminalDidScroll(_ position: TerminalScrollPosition) {}
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest) { confirmations.append(request) }
    func terminalHandleUserPaste(_ pasteboard: NSPasteboard, paste: @escaping (String) -> Void) -> Bool {
        pasteCalls += 1
        return false
    }
    func terminalDidBeginFind(needle: String) {}
    func terminalDidEndFind() {}
    func terminalDidUpdateFindTotal(_ total: Int?) {}
    func terminalDidUpdateFindSelected(_ selected: Int?) {}
}

@MainActor private func pumpRightClick(_ seconds: TimeInterval = 0.02) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

@main struct TerminalRightClickSurfaceTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("Right-click surface failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func run() throws {
        setbuf(stdout, nil)
        let app = RightClickApplication.shared as! RightClickApplication
        app.setActivationPolicy(.prohibited)
        AppLocalization.apply(.english)
        let backend = CommandLine.arguments[1]
        let fixture = CommandLine.arguments[2]
        let record = URL(fileURLWithPath: CommandLine.arguments[3])
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let launch = TerminalLaunch(
            program: "/usr/bin/python3", arguments: [fixture, record.path],
            commandLine: "/usr/bin/python3 \(quote(fixture)) \(quote(record.path))",
            interactiveShell: nil, workingDirectory: record.deletingLastPathComponent().path,
            environment: ["TERM": "xterm-256color", "LC_ALL": "en_US.UTF-8"]
        )
        let surface: any TerminalBackendSurface = backend == "ghostty"
            ? ZshellTerminalView(launch: launch) : AlacrittyTerminalView(launch: launch)
        surface.frame = NSRect(x: 0, y: 0, width: 900, height: 480)
        let window = RightClickWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        app.fixtureWindow = window
        window.makeFirstResponder(surface)
        surface.setSurfaceVisible(true)
        let events = RightClickEvents()
        surface.events = events
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        var ownedClipboardCount = clipboard.changeCount
        defer {
            if clipboard.changeCount == ownedClipboardCount {
                clipboard.clearContents()
                clipboard.writeObjects(saved.map { entries in
                    let item = NSPasteboardItem()
                    for (type, bytes) in entries { item.setData(bytes, forType: type) }
                    return item
                })
            }
            for confirmation in events.confirmations { confirmation.deny() }
            surface.setSurfaceVisible(false)
            surface.detach()
            window.contentView = nil
            window.close()
            app.fixtureWindow = nil
        }
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain: label, code: 1) }
            checks += 1
            print("PASS \(backend) right-click: \(label)")
        }
        func wait(_ label: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(6)
            while !condition(), Date() < deadline { pumpRightClick() }
            try check(condition(), label)
        }
        func bytes() -> Data { (try? Data(contentsOf: record)) ?? Data() }
        func control(_ text: String) {
            if let ghostty = surface as? ZshellTerminalView {
                ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
            } else { surface.sendText(text) }
        }
        func mouse(_ type: NSEvent.EventType, x: Int = 2, y: Int = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            let snapshot = surface.readVisibleSnapshot()!
            let point = NSPoint(x: snapshot.origin.x + (CGFloat(x) + 0.25) * snapshot.cellSize.width,
                                y: surface.bounds.height - snapshot.origin.y - (CGFloat(y) + 0.5) * snapshot.cellSize.height)
            return NSEvent.mouseEvent(
                with: type, location: surface.convert(point, to: nil), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        func rightClick(flags: NSEvent.ModifierFlags = []) {
            let down = mouse(.rightMouseDown, flags: flags)
            app.inputEvent = down
            surface.rightMouseDown(with: down)
            surface.rightMouseUp(with: mouse(.rightMouseUp, flags: flags))
            app.inputEvent = nil
            pumpRightClick(0.15)
        }
        func clipboardText(_ text: String?) {
            clipboard.clearContents()
            if let text { clipboard.setString(text, forType: .string) }
            ownedClipboardCount = clipboard.changeCount
        }
        func setMode(_ value: String, code: String) throws {
            control(code)
            try wait("real PTY enables \(value) mode") {
                surface.readVisibleSnapshot()?.rows.contains { $0.text.contains("RIGHT_CLICK_READY_" + value) } == true
            }
            pumpRightClick(0.1)
        }
        try wait("raw PTY fixture is visible") {
            surface.readVisibleSnapshot()?.rows.contains { $0.text.contains("RIGHT_CLICK_READY_plain") } == true
        }
        let settings = AppSettings.shared
        try check(settings.terminalRightClickAction == .contextMenu, "context menu remains the default")
        settings.copyOnSelect = false
        settings.terminalRightClickAction = .paste
        clipboardText("PASTED_RIGHT_CLICK")
        let pasteStart = bytes().count
        let callsBefore = events.pasteCalls
        rightClick()
        let expectedPaste = Data("\u{1b}[200~PASTED_RIGHT_CLICK\u{1b}[201~".utf8)
        try wait("right-click paste retains bracketed-paste framing exactly once") {
            bytes().dropFirst(pasteStart) == expectedPaste
        }
        try check(events.pasteCalls == callsBefore + 1, "right-click uses the session's user-paste entry point")
        clipboardText(nil)
        let emptyStart = bytes().count
        rightClick()
        try check(bytes().count == emptyStart, "an empty clipboard sends no terminal input")

        settings.terminalRightClickAction = .copyOrPaste
        surface.mouseDown(with: mouse(.leftMouseDown, x: 0))
        surface.mouseDragged(with: mouse(.leftMouseDragged, x: 18))
        surface.mouseUp(with: mouse(.leftMouseUp, x: 18))
        try wait("native pointer drag creates a real terminal selection") { surface.hasSelection }
        clipboardText("SELECTION_MUST_COPY")
        let copiedStart = bytes().count
        rightClick()
        ownedClipboardCount = clipboard.changeCount
        try check(clipboard.string(forType: .string)?.contains("SELECT_RIGHT_CLICK") == true,
                  "copy-or-paste copies the selected grid text")
        try check(bytes().count == copiedStart, "copying a selection never pastes or sends mouse bytes")
        surface.mouseDown(with: mouse(.leftMouseDown, x: 24, y: 2))
        surface.mouseUp(with: mouse(.leftMouseUp, x: 24, y: 2))
        try wait("plain click clears the native selection") { !surface.hasSelection }
        clipboardText("NO_SELECTION_PASTE")
        let unselectedStart = bytes().count
        rightClick()
        try wait("copy-or-paste without a selection pastes") {
            bytes().dropFirst(unselectedStart) == Data("\u{1b}[200~NO_SELECTION_PASTE\u{1b}[201~".utf8)
        }

        settings.terminalRightClickAction = .paste
        if backend == "ghostty" { try setMode("unsafe", code: "\u{15}") }
        clipboardText("unsafe\nsecond line")
        let unsafeStart = bytes().count
        rightClick()
        try wait("multi-line right-click paste requests the production confirmation") { !events.confirmations.isEmpty }
        try check(bytes().count == unsafeStart, "pending confirmation sends no bytes")
        events.confirmations.removeFirst().deny()
        pumpRightClick(0.1)
        try check(bytes().count == unsafeStart, "cancelled right-click paste sends no bytes")
        rightClick()
        try wait("multi-line paste can be approved after a second right-click") { !events.confirmations.isEmpty }
        events.confirmations.removeFirst().approve()
        try wait("approved right-click paste preserves the backend's existing encoding") {
            bytes().dropFirst(unsafeStart) == Data((backend == "ghostty"
                ? "unsafe\rsecond line" : "\u{1b}[200~unsafe\rsecond line\u{1b}[201~").utf8)
        }

        for (mode, code) in [("sgr", "\u{12}"), ("legacy", "\u{13}")] {
            try setMode(mode, code: code)
            clipboardText("MOUSE_MUST_NOT_PASTE")
            for action in TerminalRightClickAction.allCases {
                settings.terminalRightClickAction = action
                let mouseStart = bytes().count
                let calls = events.pasteCalls
                let down = mouse(.rightMouseDown)
                surface.rightMouseDown(with: down)
                surface.rightMouseDragged(with: mouse(.rightMouseDragged, x: 3))
                surface.rightMouseUp(with: mouse(.rightMouseUp, x: 3))
                let expected = mode == "sgr"
                    ? Data("\u{1b}[<2;3;1M\u{1b}[<34;4;1M\u{1b}[<2;4;1m".utf8)
                    : Data([0x1b, 0x5b, 0x4d, 34, 35, 33, 0x1b, 0x5b, 0x4d, 66, 36, 33, 0x1b, 0x5b, 0x4d, 35, 36, 33])
                try wait("\(mode) mouse press/drag/release remains exact with \(action.rawValue)") {
                    bytes().dropFirst(mouseStart) == expected
                }
                try check(events.pasteCalls == calls, "mouse-reporting right-click never reads the clipboard")
                try check(surface.menu(for: down) == nil, "mouse-reporting ordinary right-click does not expose a host menu")
            }
            for flags: NSEvent.ModifierFlags in [.shift, .command] {
                let menu = surface.menu(for: mouse(.rightMouseDown, flags: flags))
                try check(menu?.items.contains { $0.action == #selector(NSText.paste(_:)) } == true,
                          "explicit modifier keeps the complete menu available in \(mode)")
            }
            let controlMenu = surface.menu(for: mouse(.leftMouseDown, flags: .control))
            try check(controlMenu?.items.contains { $0.action == #selector(NSText.copy(_:)) } == true,
                      "Control-click can reach the standard menu while mouse reporting is active")
        }
        try setMode("plain", code: "\u{14}")
        AppMenuController.shared.install()
        let edit = app.mainMenu?.items.first { $0.title == "Edit" }?.submenu
        let contextCommand = edit?.items.first { $0.action == NSSelectorFromString("showTerminalContextMenu:") }
        try check(contextCommand != nil && contextCommand?.target == nil
                  && contextCommand?.keyEquivalent == "\u{f70d}" && contextCommand?.keyEquivalentModifierMask == .shift,
                  "Edit menu provides Shift-F10 through the responder chain")
        try check(surface.responds(to: NSSelectorFromString("showTerminalContextMenu:")), "the real backend implements the keyboard menu action")
        let pane = SettingsTerminalPane()
        let settingsView = pane.view
        func popups(_ view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups)
        }
        let popup = popups(settingsView).first { $0.accessibilityLabel() == "Right-click action" }
        try check(popup?.itemTitles == TerminalRightClickAction.allCases.map(\.title), "native settings exposes all three right-click choices")
        settings.terminalRightClickAction = .copyOrPaste
        pumpRightClick(0.1)
        try check(popup?.titleOfSelectedItem == TerminalRightClickAction.copyOrPaste.title, "the settings picker reflects live setting changes")
        print("Right-click surface \(backend): \(checks) checks passed")
    }
}
