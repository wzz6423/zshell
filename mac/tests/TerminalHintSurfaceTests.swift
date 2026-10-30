import AppKit
import GhosttyTerminal
@testable import zshell

@MainActor
private final class HintTestApplication: NSApplication {
    var textInputEvent: NSEvent?
    var testWindow: NSWindow?
    override var currentEvent: NSEvent? { textInputEvent ?? super.currentEvent }
    override var keyWindow: NSWindow? { testWindow ?? super.keyWindow }
}

@MainActor
private final class HintTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class HintEvents: TerminalBackendEvents {
    var opened: [String] = []
    var lastScroll: TerminalScrollPosition?
    let terminalPromptSelectionIsReady = false
    let terminalPromptQueueIsReady = false
    func terminalDidChangeTitle(_ title: String) {}
    func terminalDidChangeWorkingDirectory(_ path: String) {}
    func terminalDidChangeCellSize(_ size: CGSize) {}
    func terminalDidRingBell() {}
    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent) {}
    func terminalDidClose(processAlive: Bool) {}
    func terminalDidRequestDesktopNotification(title: String, body: String) {}
    func terminalDidRequestOpenURL(_ url: String) { opened.append(url) }
    func terminalLinkTarget(for value: String) -> TerminalLinkTarget? {
        value.hasPrefix("https://") ? URL(string: value).map(TerminalLinkTarget.url) : nil
    }
    func terminalDidScroll(_ position: TerminalScrollPosition) { lastScroll = position }
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest) { request.deny() }
    func terminalDidBeginFind(needle: String) {}
    func terminalDidEndFind() {}
    func terminalDidUpdateFindTotal(_ total: Int?) {}
    func terminalDidUpdateFindSelected(_ selected: Int?) {}
}

@MainActor
private func pump(_ duration: TimeInterval = 0.02) {
    let until = Date().addingTimeInterval(duration)
    while Date() < until { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

@main
struct TerminalHintSurfaceTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        let app = HintTestApplication.shared as! HintTestApplication
        app.setActivationPolicy(.prohibited)
        let backend = CommandLine.arguments[1]
        let fixture = CommandLine.arguments[2]
        let record = URL(fileURLWithPath: CommandLine.arguments[3])
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let launch = TerminalLaunch(program: "/usr/bin/python3", arguments: [fixture, record.path],
                                    commandLine: "/usr/bin/python3 \(quoted(fixture)) \(quoted(record.path))",
                                    interactiveShell: nil, workingDirectory: record.deletingLastPathComponent().path,
                                    environment: ["TERM": "xterm-256color", "LC_ALL": "en_US.UTF-8"])
        let view: any TerminalBackendSurface = backend == "ghostty"
            ? ZshellTerminalView(launch: launch) : AlacrittyTerminalView(launch: launch)
        let events = HintEvents()
        view.events = events
        let window = HintTestWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        app.testWindow = window
        window.makeFirstResponder(view)
        view.setSurfaceVisible(true)
        let pasteboard = NSPasteboard.withUniqueName()
        let mode = TerminalHintMode(surface: view, pasteboard: pasteboard)
        if let ghostty = view as? ZshellTerminalView { ghostty.hintMode = mode }
        if let alacritty = view as? AlacrittyTerminalView { alacritty.hintMode = mode }
        func control(_ text: String) {
            if let ghostty = view as? ZshellTerminalView {
                ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
            } else { view.sendText(text) }
        }
        defer {
            mode.dismiss(restoringFocus: false)
            control("\u{4}")
            pump(0.15)
            view.setSurfaceVisible(false)
            view.detach()
            window.contentView = nil
            window.close()
            app.testWindow = nil
            pasteboard.releaseGlobally()
        }
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw NSError(domain: name, code: 1) }
            checks += 1
            print("PASS \(backend): \(name)")
        }
        func wait(_ name: String, until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { pump() }
            try check(condition(), name)
        }
        func snapshot() throws -> TerminalViewportSnapshot {
            guard let snapshot = view.readVisibleSnapshot() else { throw NSError(domain: "missing viewport", code: 1) }
            return snapshot
        }
        func bytes() -> Data { (try? Data(contentsOf: record)) ?? Data() }
        func event(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown, repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: text, charactersIgnoringModifiers: text,
                             isARepeat: repeated, keyCode: code)!
        }
        func key(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
            window.sendEvent(event(text, code: code, flags: flags))
            window.sendEvent(event(text, code: code, flags: flags, type: .keyUp))
            pump()
        }
        func present(_ action: TerminalHintMode.Action = .copy) throws {
            window.makeFirstResponder(view)
            mode.present(action: action)
            try wait("letters appear on the real surface") { !mode.hints.isEmpty }
        }
        func choose(_ value: String) throws {
            guard let hint = mode.hints.first(where: { $0.value == value }) else {
                throw NSError(domain: "missing hint \(value), got \(mode.hints.map(\.value))", code: 1)
            }
            for letter in hint.label { key(String(letter)) }
        }
        let previousMenu = app.mainMenu
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let terminalItem = NSMenuItem()
        let terminalMenu = NSMenu()
        terminalMenu.addItem(NSMenuItem(title: "Quick Terminal", action: NSSelectorFromString("toggleQuickTerminal"), keyEquivalent: ""))
        terminalItem.submenu = terminalMenu
        mainMenu.addItem(terminalItem)
        app.mainMenu = mainMenu
        TerminalHintMenu.shared.install(in: mainMenu)
        defer { app.mainMenu = previousMenu }
        AppSettings.shared.terminalTextHints = false
        TerminalHintMenu.shared.install(in: mainMenu)
        try check(TerminalHintMenu.shared.items(for: view).isEmpty
                  && !terminalMenu.items.contains { $0.identifier?.rawValue == "zshell-copy-terminal-hint" },
                  "disabled hints remove context and main menu entries")
        mode.present(action: .copy)
        try check(!mode.isPresented, "disabled hints reject direct presentation")
        AppSettings.shared.terminalTextHints = true
        TerminalHintMenu.shared.install(in: mainMenu)
        try check(TerminalHintMenu.shared.items(for: view).count == 2,
                  "enabling hints restores both menu actions")
        try wait("PTY fixture reaches visible grid") {
            view.readVisibleSnapshot()?.rows.contains(where: { $0.text.contains("READY_HINTS") }) == true
        }
        try present()
        AppSettings.shared.terminalTextHints = false
        mode.refreshSnapshot()
        try check(!mode.isPresented && window.firstResponder === view,
                  "disabling active hints restores the terminal responder")
        AppSettings.shared.terminalTextHints = true
        let initial = try snapshot()
        let all = TerminalHintMatcher.matches(in: initial)
        let unicode = all.first { $0.value == "https://example.com/unicode" }
        try check(unicode != nil, "Unicode-prefixed URL remains whole")
        let cursorReport = record.deletingPathExtension().appendingPathExtension("cursor")
        try wait("terminal reports its Unicode cursor position") { FileManager.default.fileExists(atPath: cursorReport.path) }
        let expectedColumn = Int(try String(contentsOf: cursorReport, encoding: .utf8).split(separator: ";")[1])! - 1
        try check(unicode?.fragments.first?.columns.lowerBound == expectedColumn,
                  "CJK, repeated narrow Unicode, combining and ZWJ agree with the engine's cursor report at column \(expectedColumn)")
        if let ghostty = view as? ZshellTerminalView, let reference = ghostty.readViewportTextSnapshot() {
            try check(abs(initial.origin.x - reference.origin.x) < 0.5 && abs(initial.origin.y - reference.origin.y) < 1,
                      "Ghostty grid origin agrees with its cursor-derived geometry")
        }
        let longURL = "https://example.com/" + String(repeating: "segment/", count: 16) + "end"
        try check(all.first(where: { $0.value == longURL })?.fragments.count ?? 0 >= 2, "soft-wrapped URL stays one hint with multiple cell fragments")
        try check(all.contains { $0.value == "./Sources/main.swift:42:7" }, "diagnostic retains line and column")
        try check(all.contains { $0.value == "2001:db8::1" } && all.contains { $0.value == "192.168.1.2" }, "IPv4 and IPv6 have labels")
        app.sendEvent(event("h", code: 4, flags: [.command, .option]))
        app.sendEvent(event("h", code: 4, flags: [.command, .option], type: .keyUp))
        try wait("Cmd-Option-H takes priority over Hide Others") { mode.isPresented && mode.action == .open && !mode.hints.isEmpty }
        key("\u{1b}", code: 53)
        app.sendEvent(event("h", code: 4, flags: [.command, .shift]))
        app.sendEvent(event("h", code: 4, flags: [.command, .shift], type: .keyUp))
        try wait("Cmd-Shift-H opens copying through AppKit events") { mode.isPresented && mode.action == .copy && !mode.hints.isEmpty }
        key("\u{1b}", code: 53)
        try present()
        let baseline = bytes()
        let twoLetters = mode.hints.first { $0.label.count == 2 }!
        key(String(twoLetters.label.first!))
        try check(mode.isPresented && mode.matchingHints.count < mode.hints.count && !mode.prefix.isEmpty, "prefix narrows letter labels")
        key("\u{7f}", code: 51)
        try check(mode.prefix.isEmpty, "Backspace restores all labels")
        key("\u{1b}", code: 53)
        try check(!mode.isPresented && window.firstResponder === view, "Esc restores exact terminal responder")
        try check(bytes() == baseline, "filter, Backspace and Esc send no PTY bytes")
        try present()
        try choose("./Sources/main.swift:42:7")
        try check(pasteboard.string(forType: .string) == "./Sources/main.swift:42:7", "copy preserves diagnostic text")
        try check(bytes() == baseline, "letter selection sends no PTY bytes")
        try present(.open)
        try choose("https://example.com/second")
        try check(events.opened == ["https://example.com/second"] && !mode.isPresented, "open dispatches the selected value through existing backend events")
        try present(.open)
        try choose("deadbee")
        try check(mode.isPresented && events.opened.count == 1, "unopenable hash remains available for copying")
        key("\t", code: 48)
        try choose("deadbee")
        try check(pasteboard.string(forType: .string) == "deadbee", "Tab switches to copying")
        try present()
        let chosen = mode.hints[0]
        for letter in chosen.label { window.sendEvent(event(String(letter), code: 7)) }
        try check(mode.consumesKeyDown(event("x", code: 7, repeated: true)), "final hint key repeats remain suppressed")
        try check(mode.handleKeyUp(event("x", code: 7, type: .keyUp)), "final hint key-up remains suppressed")
        try check(!mode.consumesKeyDown(event("x", code: 7)), "new key-down is returned to normal input")
        try present()
        view.setFrameSize(NSSize(width: 610, height: 440))
        window.setContentSize(view.frame.size)
        try wait("resize refreshes labels and geometry") { mode.snapshot?.columns != initial.columns && !mode.hints.isEmpty }
        try wait("wrapped URL survives resize") { mode.hints.contains { $0.value == longURL } }
        key("\u{1b}", code: 53)
        let resized = try snapshot()
        try check(resized.origin.x + CGFloat(resized.columns) * resized.cellSize.width <= view.bounds.width + 1, "labels stay within resized grid")
        try present()
        control("\u{15}")
        try wait("changed output replaces stale labels") { mode.hints.contains { $0.value == "https://changed.example/new" } }
        key("\u{1b}", code: 53)
        control("\u{13}")
        try wait("scrollback fixture finishes writing") { view.readVisibleSnapshot()?.rows.contains { $0.text.contains("READY_HISTORY") } == true }
        try wait("scrollback generated") { events.lastScroll?.isScrollable == true }
        view.scroll(toFraction: 0)
        try wait("scrollback viewport reaches old URL") { view.readVisibleSnapshot()?.rows.contains { $0.text.contains("https://history.example/old") } == true }
        try present()
        try choose("https://history.example/old")
        try check(pasteboard.string(forType: .string) == "https://history.example/old", "only currently visible scrollback is labelled and copied")
        view.scroll(toFraction: 1)
        control("\u{14}")
        try wait("alternate screen fixture ready") { view.readVisibleSnapshot()?.rows.contains { $0.text.contains("READY_HINTS") } == true }
        try present()
        try choose("deadbee")
        try check(pasteboard.string(forType: .string) == "deadbee", "alternate screen also supports hint copying")
        let beforeTyping = bytes()
        let client = view as! any NSTextInputClient
        app.textInputEvent = event("x", code: 7)
        client.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        app.textInputEvent = nil
        app.textInputEvent = event("中文", code: 0)
        client.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(client.hasMarkedText(), "IME composition remains usable after hints")
        client.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        app.textInputEvent = nil
        try wait("normal text and IME commit reach PTY after exit") { bytes().count >= beforeTyping.count + "x中文".utf8.count }
        try check(bytes().dropFirst(beforeTyping.count) == Data("x中文".utf8), "normal and IME input resume without hint bytes")
        print("PASS \(checks) real \(backend) terminal hint checks")
    }
}
