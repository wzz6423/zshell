import AppKit
import GhosttyTerminal
@testable import zshell

@MainActor private final class ReadOnlyApplication: NSApplication {
    var inputEvent: NSEvent?
    var fixtureWindow: NSWindow?
    override var currentEvent: NSEvent? { inputEvent ?? super.currentEvent }
    override var keyWindow: NSWindow? { fixtureWindow ?? super.keyWindow }
}

@MainActor private final class ReadOnlyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor private final class ReadOnlyEvents: TerminalBackendEvents {
    let terminalPromptSelectionIsReady = false
    let terminalPromptQueueIsReady = false
    var confirmations: [TerminalClipboardRequest] = []
    var lastScroll: TerminalScrollPosition?
    var totalMatches: Int?
    func terminalDidChangeTitle(_ title: String) {}
    func terminalDidChangeWorkingDirectory(_ path: String) {}
    func terminalDidChangeCellSize(_ size: CGSize) {}
    func terminalDidRingBell() {}
    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent) {}
    func terminalDidClose(processAlive: Bool) {}
    func terminalDidRequestDesktopNotification(title: String, body: String) {}
    func terminalDidRequestOpenURL(_ url: String) {}
    func terminalLinkTarget(for value: String) -> TerminalLinkTarget? { URL(string: value).map(TerminalLinkTarget.url) }
    func terminalDidScroll(_ position: TerminalScrollPosition) { lastScroll = position }
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest) { confirmations.append(request) }
    func terminalDidBeginFind(needle: String) {}
    func terminalDidEndFind() {}
    func terminalDidUpdateFindTotal(_ total: Int?) { totalMatches = total }
    func terminalDidUpdateFindSelected(_ selected: Int?) {}
}

@MainActor private final class ReadOnlyDrop: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggingLocation = NSPoint.zero
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none
    init(pasteboard: NSPasteboard, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination destination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@main @MainActor struct TerminalReadOnlySurfaceTests {
    private static var checks = 0
    private static var sequence = 0
    private static var backend = ""

    static func main() {
        do { try run() }
        catch { fputs("Read-only checks failed: \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        setbuf(stdout, nil)
        backend = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let fixture = CommandLine.arguments[3]
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard ["/tmp/zshell-read-only-tests-", "/private/tmp/zshell-read-only-tests-"]
            .contains(where: home.path.hasPrefix) else { throw failure("disposable HOME required") }
        let app = ReadOnlyApplication.shared as! ReadOnlyApplication
        app.setActivationPolicy(.prohibited)
        AppLocalization.apply(.english)
        let settings = AppSettings.shared
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.terminalStartupProgram = ""
        settings.preserveTerminalSessions = false
        settings.restoreTerminalHistory = false
        settings.resumeAgentConversations = false
        settings.notifyOnError = false
        settings.copyOnSelect = false
        let launch = TerminalLaunch(
            program: "/usr/bin/python3", arguments: [fixture, root.path],
            commandLine: "/usr/bin/python3 " + quote(fixture) + " " + quote(root.path),
            interactiveShell: nil, workingDirectory: root.path,
            environment: ["TERM": "xterm-256color", "LC_ALL": "en_US.UTF-8"]
        )
        guard let surface = settings.terminalBackend.makeSurface(launch: launch) else { throw failure("surface missing") }
        surface.frame = NSRect(x: 0, y: 0, width: 840, height: 480)
        let window = ReadOnlyWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        app.fixtureWindow = window
        window.makeFirstResponder(surface)
        surface.setSurfaceVisible(true)
        let events = ReadOnlyEvents()
        surface.events = events
        let clipboard = NSPasteboard.general
        let savedClipboard = (clipboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        var ownedClipboardCount = clipboard.changeCount
        defer {
            try? command("exit", root: root)
            for request in events.confirmations { request.deny() }
            surface.setSurfaceVisible(false)
            surface.detach()
            window.contentView = nil
            window.close()
            app.fixtureWindow = nil
            if clipboard.changeCount == ownedClipboardCount {
                clipboard.clearContents()
                clipboard.writeObjects(savedClipboard.map { entries in
                    let item = NSPasteboardItem()
                    for (type, bytes) in entries { item.setData(bytes, forType: type) }
                    return item
                })
            }
        }
        func bytes() -> Data { (try? Data(contentsOf: root.appendingPathComponent("input.bin"))) ?? Data() }
        func visible() -> String { surface.readVisibleText(maxLines: 200, maxColumns: 500) ?? "" }
        func clipboardText(_ value: String) {
            clipboard.clearContents()
            clipboard.setString(value, forType: .string)
            ownedClipboardCount = clipboard.changeCount
        }
        func key(_ type: NSEvent.EventType = .keyDown, text: String = "x", code: UInt16 = 7,
                 flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        func mouse(_ type: NSEvent.EventType, column: Int = 2, row: Int = 0,
                   flags: NSEvent.ModifierFlags = []) -> NSEvent {
            let snapshot = surface.readVisibleSnapshot()!
            let top = snapshot.origin.y + (CGFloat(row) + 0.5) * snapshot.cellSize.height
            let point = NSPoint(x: snapshot.origin.x + (CGFloat(column) + 0.25) * snapshot.cellSize.width,
                y: surface.isFlipped ? top : surface.bounds.height - top)
            return NSEvent.mouseEvent(with: type, location: surface.convert(point, to: nil), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func wheel(_ lines: Int) -> NSEvent {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                wheel1: Int32(lines), wheel2: 0, wheel3: 0)!
            event.location = NSPoint(x: 50, y: 50)
            return NSEvent(cgEvent: event)!
        }
        func blocked(_ name: String, _ action: () throws -> Void) throws {
            pump(0.06)
            let previous = bytes()
            try action()
            app.inputEvent = nil
            pump(0.15)
            try check(bytes() == previous, name)
        }

        try wait("real PTY output is visible") { visible().contains("READ_ONLY_READY_plain") }
        try check(!surface.isReadOnly, "fresh surface starts editable")
        _ = surface.sendText("editable")
        try wait("editable surface writes real PTY input") { String(decoding: bytes(), as: UTF8.self).contains("editable") }
        clipboardText("late-approval\n")
        NSApp.sendAction(#selector(NSText.paste(_:)), to: surface, from: nil)
        try wait("real unsafe paste requests approval before writing") { !events.confirmations.isEmpty }
        let pendingPaste = events.confirmations.removeFirst()
        surface.isReadOnly = true
        surface.isReadOnly = false
        try blocked("unlock cannot revive an earlier unsafe-paste approval") { pendingPaste.approve() }
        surface.isReadOnly = true
        try blocked("raw text, paste, Return and queued submit are rejected") {
            try check(!surface.sendText("blocked"), "sendText reports rejection")
            try check(!surface.sendPaste("blocked"), "sendPaste reports rejection")
            try check(!surface.sendEnter(), "sendEnter reports rejection")
            try check(!surface.sendPromptQueueEnter(), "queue submit reports rejection")
        }
        try blocked("keyboard, key release, flags and IME commit write no bytes") {
            let down = key()
            app.inputEvent = down
            surface.keyDown(with: down)
            surface.keyUp(with: key(.keyUp))
            surface.flagsChanged(with: key(.flagsChanged, text: "", code: 56, flags: .shift))
            let input = surface as! any NSTextInputClient
            input.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            input.insertText("拼音", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        try blocked("accessibility text edits are rejected") { surface.setAccessibilitySelectedText("dictation") }
        try check(!surface.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilitySelectedText:")),
                  "locked terminal does not advertise writable accessibility text")
        clipboardText("READ_ONLY_PASTE")
        try blocked("Cmd-V and right-click paste are rejected") {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: surface, from: nil)
            settings.terminalRightClickAction = .paste
            surface.rightMouseDown(with: mouse(.rightMouseDown))
            surface.rightMouseUp(with: mouse(.rightMouseUp))
        }
        try blocked("middle button cannot paste") {
            surface.otherMouseDown(with: mouse(.otherMouseDown))
            surface.otherMouseUp(with: mouse(.otherMouseUp))
        }
        let dropBoard = NSPasteboard.withUniqueName()
        defer { dropBoard.releaseGlobally() }
        dropBoard.writeObjects([root.appendingPathComponent("input.bin") as NSURL])
        let drop = ReadOnlyDrop(pasteboard: dropBoard, window: window)
        try check(surface.draggingEntered(drop) == [], "locked terminal refuses file drag acceptance")
        try blocked("direct file-drop dispatch cannot bypass the lock") { _ = surface.performDragOperation(drop) }
        if let ghostty = surface as? ZshellTerminalView {
            try check(!ghostty.performBindingAction("text:\\x62"), "Ghostty input binding reports rejection")
            try check(!ghostty.performBindingAction("paste_from_clipboard"), "Ghostty paste binding reports rejection")
        }
        try command("query", root: root)
        try wait("locked PTY still receives cursor-position query reply") {
            String(decoding: bytes(), as: UTF8.self).range(of: #"\x1b\[\d+;\d+R"#, options: .regularExpression) != nil
        }
        try wait("locked terminal still answers color queries") { String(decoding: bytes(), as: UTF8.self).contains("rgb:") }
        try command("stream", root: root)
        try wait("running output continues while locked") { visible().contains("READ_ONLY_STREAM_15") }
        try command("capture", root: root)
        try wait("real TUI enables mouse reporting") { visible().contains("READ_ONLY_READY_capture") }
        surface.isReadOnly = false
        pump(0.08)
        let immediateStart = bytes()
        surface.isReadOnly = true
        surface.mouseMoved(with: mouse(.mouseMoved, column: 3))
        if let ghostty = surface as? ZshellTerminalView { _ = ghostty.contextText(for: mouse(.mouseMoved, column: 4)) }
        surface.mouseDown(with: mouse(.leftMouseDown, column: 0))
        surface.mouseUp(with: mouse(.leftMouseUp, column: 0))
        surface.scrollWheel(with: wheel(2))
        pump(0.12)
        try check(bytes() == immediateStart, "locking immediately blocks TUI motion, hit testing, clicks and wheel without a run-loop delay")
        try blocked("TUI clicks, motion, drag and wheel stay in the host") {
            surface.mouseMoved(with: mouse(.mouseMoved, column: 3))
            surface.mouseDown(with: mouse(.leftMouseDown, column: 0))
            surface.mouseDragged(with: mouse(.leftMouseDragged, column: 12))
            surface.mouseUp(with: mouse(.leftMouseUp, column: 12))
            surface.otherMouseDown(with: mouse(.otherMouseDown))
            surface.otherMouseDragged(with: mouse(.otherMouseDragged, column: 4))
            surface.otherMouseUp(with: mouse(.otherMouseUp, column: 4))
            surface.scrollWheel(with: wheel(2))
            _ = surface.sendApplicationScroll(lines: 3)
        }
        try check(surface.hasSelection, "locked captured TUI still permits native text selection")
        NSApp.sendAction(#selector(NSText.copy(_:)), to: surface, from: nil)
        ownedClipboardCount = clipboard.changeCount
        try check(clipboard.string(forType: .string)?.contains("SELECT_READ") == true, "locked native selection remains copyable")
        let focusStart = bytes().count
        window.makeFirstResponder(nil)
        pump(0.08)
        window.makeFirstResponder(surface)
        try wait("focus protocol remains available while locked") {
            String(decoding: bytes().dropFirst(focusStart), as: UTF8.self).contains("\u{1b}[I")
        }
        try command("plain", root: root)
        try wait("fixture returns to shell scrollback") { visible().contains("READ_ONLY_READY_plain") }
        try command("lines", root: root)
        try wait("locked output expands real scrollback") { (events.lastScroll?.totalRows ?? 0) > (events.lastScroll?.viewportRows ?? .max) }
        let previousTop = events.lastScroll?.topRow ?? 0
        surface.scrollWheel(with: wheel(3))
        try wait("locked mouse wheel scrolls host history") { (events.lastScroll?.topRow ?? previousTop) < previousTop }
        surface.beginFind("READ_ONLY_SCROLL_000")
        try wait("locked terminal search still finds output") { (events.totalMatches ?? 0) > 0 }
        surface.endFind()
        surface.scroll(toFraction: 1)
        surface.setSurfaceVisible(false)
        surface.removeFromSuperview()
        let remount = NSView(frame: window.contentView?.bounds ?? surface.frame)
        window.contentView = remount
        remount.addSubview(surface)
        surface.setSurfaceVisible(true)
        window.makeFirstResponder(surface)
        try check(surface.isReadOnly, "same surface remains locked after parking and remounting")
        try blocked("remounting does not replay rejected input") {}
        surface.isReadOnly = false
        pump(0.12)
        let unlockedStart = bytes().count
        _ = surface.sendText("fresh-unlocked")
        try wait("unlock permits only newly requested input") { bytes().dropFirst(unlockedStart) == Data("fresh-unlocked".utf8) }
        try command("keys", root: root)
        try wait("fixture requests extended keyboard protocol") { visible().contains("READ_ONLY_READY_keys") }
        if backend == "ghostty" {
            let keyStart = bytes().count
            app.inputEvent = key()
            surface.keyDown(with: app.inputEvent!)
            surface.keyUp(with: key(.keyUp))
            app.inputEvent = nil
            try wait("editable Ghostty delivers extended key release") {
                String(decoding: bytes().dropFirst(keyStart), as: UTF8.self).contains(":3u")
            }
        }
        surface.isReadOnly = true
        try blocked("extended key-release protocol is blocked") {
            app.inputEvent = key()
            surface.keyDown(with: app.inputEvent!)
            surface.keyUp(with: key(.keyUp))
        }
        let blocking = surface.commandRouting.contextMenuItem()
        try check(NSApp.sendAction(blocking.action!, to: blocking.target, from: blocking), "Block Zshell Commands action dispatches")
        try blocked("read-only and command blocking together reject routed command chords") {
            app.inputEvent = key(text: "n", code: 45, flags: .command)
            surface.keyDown(with: app.inputEvent!)
            surface.keyUp(with: key(.keyUp, text: "n", code: 45, flags: .command))
            NSApp.sendAction(#selector(NSText.paste(_:)), to: surface, from: nil)
        }
        let explicitToggle = TerminalReadOnlyController.shared.menuItem(for: surface)
        try check(NSApp.sendAction(explicitToggle.action!, to: explicitToggle.target, from: explicitToggle)
                  && !surface.isReadOnly && surface.commandRouting.blocksCommands,
                  "context-menu unlock remains reachable while Zshell command chords are blocked")
        _ = NSApp.sendAction(blocking.action!, to: blocking.target, from: blocking)
        try sessionChecks(app: app, root: root)
        print("Read-only \(backend): \(checks) native view and real PTY checks passed")
    }

    private static func sessionChecks(app: ReadOnlyApplication, root: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let draft = root.appendingPathComponent("draft.txt")
        try """
        HISTFILE=/dev/null
        unsetopt SHARE_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME APPEND_HISTORY
        bindkey -e
        PROMPT='READ_ONLY_SHELL> '
        RPROMPT=''
        _read_only_draft() { builtin print -rn -- "$BUFFER" >| \(quote(draft.path)); }
        _read_only_clear() { BUFFER=''; CURSOR=0; }
        zle -N _read_only_draft
        zle -N _read_only_clear
        bindkey '^T' _read_only_draft
        bindkey '^R' _read_only_clear
        """.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let project = Project(fallbackName: "Read-only fixture", manager: manager, createInitialSession: false)
        project.customDirectory = root.path
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        guard let session = project.newSession(directory: root.path) else { throw failure("session missing") }
        let window = ReadOnlyWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        let container = TerminalContainerView()
        container.frame = window.contentView!.bounds
        container.mount(session.surface, scrollbar: session.overlayScrollbar, queueBar: session.promptQueueBar)
        window.contentView = container
        app.fixtureWindow = window
        window.makeFirstResponder(session.surface)
        container.layoutSubtreeIfNeeded()
        session.surface.setSurfaceVisible(true)
        defer {
            manager.windowClosed()
            pump(0.4)
            window.contentView = nil
            window.close()
            app.fixtureWindow = nil
        }
        try wait("original zsh reaches an empty prompt") { session.canSendQueuedPrompt }
        var unsafeResolutions: [Bool] = []
        let unsafe = TerminalClipboardRequest(kind: .unsafePaste, contents: "pending\n") { unsafeResolutions.append($0) }
        session.terminalDidRequestClipboardConfirmation(unsafe)
        session.surface.isReadOnly = true
        session.surface.isReadOnly = false
        pump(0.08)
        unsafe.approve()
        try check(window.attachedSheet == nil && unsafeResolutions == [false],
                  "locking before unsafe-paste sheet presentation denies once and leaves no stale sheet")
        func control(_ text: String) throws {
            if let ghostty = session.surface as? ZshellTerminalView {
                let escaped = text.utf8.map { String(format: "\\x%02x", $0) }.joined()
                try check(ghostty.performBindingAction("text:" + escaped), "shell control binding is accepted")
            } else {
                try check(session.sendCommand(text), "shell control bytes are accepted")
            }
        }
        session.promptQueue.present()
        guard let composer = find("prompt-queue-input", in: session.promptQueueBar) as? NSTextField else {
            throw failure("queue composer missing")
        }
        composer.stringValue = "unsent composer 你好"
        let marker = root.appendingPathComponent("queue-leak.txt")
        session.promptQueue.enqueue("printf leak > " + quote(marker.path))
        try check(session.sendCommand("existing draft", asPaste: true), "shell draft paste is accepted")
        try control("\u{14}")
        try wait("zsh BUFFER contains the draft before locking") {
            (try? String(contentsOf: draft, encoding: .utf8)) == "existing draft"
        }
        let previousDraft = try String(contentsOf: draft, encoding: .utf8)
        try FileManager.default.removeItem(at: draft)
        session.surface.isReadOnly = true
        try check(session.isReadOnly, "session reflects its surface lock")
        try check(session.browserInputGate.isReadOnly, "surface lock synchronously closes the same session's browser input gate")
        try check(!session.sendCommand("blocked") && !session.sendEnter(), "session write methods report rejection")
        try check(!session.sendQueuedPrompt(at: 0), "locked pane cannot manually dispatch queue")
        AppSettings.shared.promptQueueAutoDispatch = true
        session.schedulePromptQueueDispatch()
        session.terminalDidReportShellIntegration(.promptStart)
        pump(0.4)
        try check(session.promptQueueDispatchTask == nil && session.promptQueue.commands.count == 1,
                  "locked pane neither schedules nor removes queued work")
        try check(composer.stringValue == "unsent composer 你好", "locking preserves queue composer draft")
        session.surface.isReadOnly = false
        try check(!session.browserInputGate.isReadOnly, "surface unlock synchronously opens only the current browser input generation")
        pump(0.3)
        try check(!FileManager.default.fileExists(atPath: marker.path), "unlock does not replay blocked queue dispatch")
        try control("\u{14}")
        try wait("pre-lock shell draft survives") { (try? String(contentsOf: draft, encoding: .utf8)) == previousDraft }
        try control("\u{12}")
        session.promptQueue.remove(at: 0)
        AppSettings.shared.promptQueueAutoDispatch = false
        try wait("cleared shell is ready again") { session.canSendQueuedPrompt }
        guard let tab = project.tabs.first(where: { $0.sessions.contains(where: { $0 === session }) }),
              let pane = tab.allPanes.first(where: { $0.content.id == session.id }) else { throw failure("session pane missing") }
        let store = TerminalCommandTaskStore.shared
        let pendingMarker = root.appendingPathComponent("pending-task-leak.txt")
        let pending = store.submit(argv: ["/bin/sh", "-c", "printf leak > " + quote(pendingMarker.path)],
                                   projectID: project.id, paneID: pane.id, session: session)
        try check(pending.state == .pending, "command task is pending before its main-actor dispatch")
        session.surface.isReadOnly = true
        try check(store.task(id: pending.id, projectID: project.id)?.errorCode == "terminal_read_only"
                  && !store.hasActiveTask(terminalID: session.id), "locking immediately terminates a pending task with terminal_read_only")
        session.surface.isReadOnly = false
        pump(0.15)
        try check(!FileManager.default.fileExists(atPath: pendingMarker.path)
                  && store.task(id: pending.id, projectID: project.id)?.state == .unavailable,
                  "unlock does not revive a pending command task")
        try wait("original shell is ready for an observed command task") { session.isCommandTaskShellReady }
        let runningMarker = root.appendingPathComponent("running-task.txt")
        let running = store.submit(argv: ["/bin/sh", "-c", "printf started > " + quote(runningMarker.path)
                                        + "; sleep 0.3; printf READ_ONLY_TASK_FINISHED"],
                                   projectID: project.id, paneID: pane.id, session: session)
        try wait("real command task has started before locking") {
            store.task(id: running.id, projectID: project.id)?.state == .running
                && FileManager.default.fileExists(atPath: runningMarker.path)
        }
        session.surface.isReadOnly = true
        try wait("a task already running continues to completion while locked") {
            store.task(id: running.id, projectID: project.id)?.state == .completed
        }
        let result = store.task(id: running.id, projectID: project.id)
        try check(result?.exitCode == 0 && result?.output?.contains("READ_ONLY_TASK_FINISHED") == true,
                  "running task retains its actual exit status and terminal output")
        session.surface.isReadOnly = false
        try wait("shell is ready after the locked running task") { session.canSendQueuedPrompt }
        try delayedImageChecks(session: session)

        let historyCommand = "printf READ_ONLY_HISTORY"
        session.sendCommand(historyCommand, asPaste: true)
        session.sendEnter()
        try wait("real command produces history metadata") {
            session.commandRecords.contains { $0.command == historyCommand && $0.finishedAt != nil } && session.canSendQueuedPrompt
        }
        guard let record = session.commandRecords.first(where: { $0.command == historyCommand && $0.finishedAt != nil }) else {
            throw failure("history record missing")
        }
        let entry = TerminalCommandHistoryEntry(record: record, terminalID: session.id)
        session.surface.isReadOnly = true
        try check(!TerminalCommandHistoryActions.canInsert(entry) && !TerminalCommandHistoryActions.insert(entry),
                  "history insertion rejects locked origin")
        try check(TerminalCommandHistoryActions.canReveal(entry), "history output navigation remains available")
        try request("pane.send", params: ["text": .string("blocked"), "enter": .bool(true)], session: session)
        try request("pane.run", params: ["argv": .array([.string("/usr/bin/true")])], session: session)
        try request("agent.start", params: ["kind": .string("claude"), "alias": .string("locked")], session: session)
        session.declareAutomationAgent(alias: "locked", kind: .claude)
        try request("agent.prompt", params: ["alias": .string("locked"), "text": .string("blocked")], session: session)
        try cliChecks(session: session)
        let uploadBoard = NSPasteboard.withUniqueName()
        defer { uploadBoard.releaseGlobally() }
        uploadBoard.setString("blocked", forType: .string)
        var pasted = false
        try check(session.terminalHandleUserPaste(uploadBoard, paste: { _ in pasted = true }), "session consumes locked paste")
        _ = session.terminalHandleFileDrop([root.appendingPathComponent("input.bin")], paste: { _ in pasted = true })
        _ = session.uploadSelectedFiles([root.appendingPathComponent("input.bin")], paste: { _ in pasted = true })
        pump(0.15)
        try check(!pasted, "locked paste and upload APIs never invoke insertion callback")

        AppMenuController.shared.install()
        guard let terminalMenu = AppMenuController.submenu(.terminal, in: NSApp.mainMenu!),
              let toggle = terminalMenu.items.first(where: { $0.identifier?.rawValue == "terminal-read-only" }) else {
            throw failure("terminal menu toggle missing")
        }
        try check(TerminalReadOnlyController.shared.validateMenuItem(toggle) && toggle.state == .on,
                  "native menu reflects focused lock")
        composer.selectText(nil)
        try check((window.firstResponder as? NSTextView)?.isFieldEditor == true
                  && TerminalReadOnlyController.shared.validateMenuItem(toggle) && toggle.state == .on,
                  "main menu resolves the real queue field editor to its terminal")
        try check(NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle) && !session.isReadOnly,
                  "main menu toggles the queue composer's own terminal")
        _ = NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        window.makeFirstResponder(session.surface)
        let workspaceHost = NSView(frame: container.frame)
        window.contentView = workspaceHost
        workspaceHost.addSubview(container)
        session.find.present()
        let findField = NSTextField(frame: NSRect(x: 10, y: 10, width: 160, height: 22))
        workspaceHost.addSubview(findField)
        findField.selectText(nil)
        try check(TerminalReadOnlyController.shared.validateMenuItem(toggle) && toggle.state == .on,
                  "main menu resolves a find field to its focused terminal")
        findField.removeFromSuperview()
        let filePath = root.appendingPathComponent("editor.txt")
        try "editable file".write(to: filePath, atomically: true, encoding: .utf8)
        let file = FileTab(path: filePath.path)
        defer { file.close() }
        let fileTab = PaneTab(content: .file(file))
        project.tabs.append(fileTab)
        project.selectedTabID = fileTab.id
        let fileEditor = NSTextView(frame: NSRect(x: 10, y: 10, width: 160, height: 60))
        window.contentView!.addSubview(fileEditor)
        window.makeFirstResponder(fileEditor)
        try check(!TerminalReadOnlyController.shared.validateMenuItem(toggle), "main menu is disabled for an editor with a terminal find bar open")
        _ = NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        try check(session.isReadOnly, "editor focus cannot toggle the background terminal")
        fileEditor.removeFromSuperview()
        let browser = BrowserTab(initialFocus: .none)
        defer { browser.close() }
        let browserTab = PaneTab(content: .browser(browser))
        project.tabs.append(browserTab)
        project.selectedTabID = browserTab.id
        browser.webView.frame = NSRect(x: 10, y: 10, width: 160, height: 100)
        window.contentView!.addSubview(browser.webView)
        window.makeFirstResponder(browser.webView)
        try check(!TerminalReadOnlyController.shared.validateMenuItem(toggle), "main menu is disabled for browser web content")
        _ = NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        try check(session.isReadOnly, "browser focus cannot toggle the background terminal")
        browser.webView.removeFromSuperview()
        project.selectedTabID = tab.id
        session.find.dismiss()
        window.makeFirstResponder(session.surface)
        let translations = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("translations.json")))
            as! [String: [String: String]]
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            container.layoutSubtreeIfNeeded()
            pump(0.01)
            AppMenuController.shared.menuNeedsUpdate(terminalMenu)
            guard let unlock = find("terminal-read-only-unlock", in: container) as? NSButton else {
                throw failure("unlock control missing")
            }
            try check(!unlock.isHidden && unlock.toolTip?.isEmpty == false && unlock.accessibilityLabel()?.isEmpty == false,
                      "\(language.rawValue) single-pane unlock has visible state and accessible name")
            let expected = translations[language.rawValue]!
            do {
                try wait("\(language.rawValue) menu, unlock and input rejection display the compiled translations") {
                    unlock.title == expected["Read Only"] && toggle.title == expected["Read Only"]
                        && unlock.toolTip == expected["Unlock Terminal"] && unlock.accessibilityLabel() == expected["Unlock Terminal"]
                        && TerminalReadOnlyController.rejectionMessage == expected["This terminal is read only. Unlock it before sending input."]
                }
            } catch {
                throw failure("\(language.rawValue) localization: button=\(unlock.title), menu=\(toggle.title), tooltip=\(unlock.toolTip ?? ""), accessibility=\(unlock.accessibilityLabel() ?? ""), rejection=\(TerminalReadOnlyController.rejectionMessage); expected=\(expected)")
            }
            window.setContentSize(NSSize(width: 180, height: 360))
            container.frame = workspaceHost.bounds
            container.layoutSubtreeIfNeeded()
            let rect = unlock.convert(unlock.bounds, to: container)
            try check(rect.minX >= 0 && rect.maxX <= container.bounds.maxX && rect.minY >= 0 && rect.maxY <= container.bounds.maxY,
                      "\(language.rawValue) unlock fits a narrow pane")
        }
        AppLocalization.apply(.english)
        AppSettings.shared.terminalTextHints = true
        session.surface.hintMode.present(action: .copy)
        try check(TerminalHintMode.isPresented(in: window) && TerminalReadOnlyController.shared.validateMenuItem(toggle),
                  "menu resolves the actual hint overlay to its locked terminal")
        session.surface.hintMode.dismiss()
        guard let unlock = find("terminal-read-only-unlock", in: container) as? NSButton else { throw failure("unlock missing") }
        unlock.performClick(nil)
        try check(!session.surface.isReadOnly && unlock.isHidden, "native unlock action restores editable mode")
        guard let split = project.newSession(directory: root.path) else { throw failure("new pane missing") }
        try check(!split.surface.isReadOnly, "newly created pane does not inherit another surface lock")
        session.surface.isReadOnly = true
        try quickTerminalChecks(app: app, mainWindow: window, mainSession: session, toggle: toggle)
    }

    private static func delayedImageChecks(session: TerminalSession) throws {
        session.surface.window?.makeFirstResponder(session.surface)
        try check(session.surface.hasEffectiveTerminalFocus, "image cancellation fixture has effective terminal focus")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let width = 1024, height = 1024
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: width * 4, bitsPerPixel: 32)!
        var random: UInt32 = 1
        for offset in 0..<(width * height * 4) {
            random = random &* 1_664_525 &+ 1_013_904_223
            bitmap.bitmapData![offset] = UInt8(truncatingIfNeeded: random >> 24)
        }
        let png = bitmap.representation(using: .png, properties: [:])!
        board.setData(png, forType: .png)
        let temporary = FileManager.default.temporaryDirectory
        func batches() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: temporary.path))?.filter { $0.hasPrefix("zshell-clipboard-") } ?? [])
        }
        let previous = batches()
        var inserted = false
        var barrierFinished = false
        var barrierError: Error?
        Task { @MainActor in
            do {
                try check(session.terminalHandleUserPaste(board, paste: { _ in inserted = true }), "local image paste starts in the editable terminal")
                let deadline = Date().addingTimeInterval(3)
                while batches() == previous, !inserted, Date() < deadline { await Task.yield() }
                var image: URL?
                while image == nil, Date() < deadline {
                    for batch in batches().subtracting(previous) {
                        let folder = temporary.appendingPathComponent(batch)
                        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                            image = files.first(where: { (try? Data(contentsOf: $0)) == png })
                        }
                    }
                    if image == nil { Thread.sleep(forTimeInterval: 0.002) }
                }
                try check(image != nil && !inserted, "image worker saves its real PNG while the main-actor insertion remains queued")
                Thread.sleep(forTimeInterval: 0.05)
                session.surface.isReadOnly = true
                session.surface.isReadOnly = false
            } catch { barrierError = error }
            barrierFinished = true
        }
        try wait("image cancellation barrier finishes") { barrierFinished }
        if let barrierError { throw barrierError }
        pump(0.15)
        try check(!inserted, "lock and unlock cannot revive a finished local-image paste")
        try wait("cancelled local-image paste removes its saved temporary PNG") { batches() == previous }
    }

    private static func quickTerminalChecks(app: ReadOnlyApplication, mainWindow: NSWindow,
                                           mainSession: TerminalSession, toggle: NSMenuItem) throws {
        let overlay = GlobalTerminalOverlay.shared
        AppSettings.shared.quickTerminalEnabled = true
        AppSettings.shared.quickTerminalMode = .reuse
        defer {
            overlay.stop()
            AppSettings.shared.quickTerminalEnabled = false
            app.fixtureWindow = mainWindow
        }
        overlay.toggle()
        try wait("independent Quick Terminal creates its own surface and panel") { overlay.workspace?.sessions.first?.surface.window != nil }
        guard let quick = overlay.workspace?.sessions.first, let panel = quick.surface.window, let host = panel.contentView else {
            throw failure("Quick Terminal panel missing")
        }
        app.fixtureWindow = panel
        panel.makeFirstResponder(quick.surface)
        try check(panel !== mainWindow && !quick.isReadOnly && TerminalReadOnlyController.shared.validateMenuItem(toggle) && toggle.state == .off,
                  "Quick Terminal main-menu state comes from its own editable surface")
        _ = NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        try check(quick.isReadOnly && mainSession.isReadOnly, "Quick Terminal menu locks its own surface without changing the main terminal")
        host.layoutSubtreeIfNeeded()
        try wait("Quick Terminal uses the shared visible unlock control") { find("terminal-read-only-unlock", in: host)?.isHidden == false }
        quick.promptQueue.present()
        host.layoutSubtreeIfNeeded()
        try wait("Quick Terminal mounts its queue composer") { find("prompt-queue-input", in: host) is NSTextField }
        let composer = find("prompt-queue-input", in: host) as! NSTextField
        composer.selectText(nil)
        try check((panel.firstResponder as? NSTextView)?.isFieldEditor == true
                  && TerminalReadOnlyController.shared.validateMenuItem(toggle) && toggle.state == .on,
                  "Quick Terminal queue field editor resolves only its own terminal")
        _ = NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        try check(!quick.isReadOnly && mainSession.isReadOnly, "Quick Terminal composer menu unlocks only the Quick Terminal surface")
        _ = NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        panel.makeFirstResponder(quick.surface)
        overlay.toggle()
        try check(!panel.isVisible && quick.isReadOnly, "reusable Quick Terminal keeps its lock while hidden")
        app.fixtureWindow = mainWindow
        mainWindow.makeFirstResponder(mainSession.surface)
        try check(TerminalReadOnlyController.shared.validateMenuItem(toggle) && toggle.state == .on,
                  "main menu resolves the main terminal while Quick Terminal is hidden")
        overlay.toggle()
        try check(overlay.workspace?.sessions.first === quick && quick.isReadOnly, "showing reusable Quick Terminal preserves the same surface lock")
        app.fixtureWindow = panel
        panel.makeFirstResponder(quick.surface)
        guard let unlock = find("terminal-read-only-unlock", in: host) as? NSButton else { throw failure("Quick Terminal unlock missing") }
        unlock.performClick(nil)
        try check(!quick.isReadOnly && mainSession.isReadOnly, "Quick Terminal's visible unlock button does not unlock the main terminal")
    }

    private static func cliChecks(session: TerminalSession) throws {
        guard let executable = ProcessInfo.processInfo.environment["ZSHELL_TEST_EXECUTABLE"] else {
            throw failure("built CLI executable missing")
        }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(ZshellCLIService.shared.terminalEnvironment(for: session.id)) { _, capability in capability }
        func run(_ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = output
            process.standardError = error
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            try wait("real CLI \(arguments.prefix(2).joined(separator: " ")) exits") { !process.isRunning }
            return (process.terminationStatus,
                    String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let current = try run(["+pane", "current"])
        let snapshot = try JSONSerialization.jsonObject(with: Data(current.output.utf8)) as? [String: Any]
        try check(current.status == 0 && current.error.isEmpty && snapshot?["read_only"] as? Bool == true,
                  "real CLI socket reports the current surface as read only")
        let read = try run(["+pane", "read", "--lines", "10"])
        let transcript = try JSONSerialization.jsonObject(with: Data(read.output.utf8)) as? [String: Any]
        try check(read.status == 0 && read.error.isEmpty && transcript?["text"] is String,
                  "real CLI socket retains transcript reads while locked")
        for arguments in [
            ["+pane", "send", "--text", "blocked", "--enter"],
            ["+pane", "run", "--", "/usr/bin/true"],
            ["+agent", "start", "locked-start", "--kind", "claude"],
            ["+agent", "prompt", "locked", "--text", "blocked"],
        ] {
            let result = try run(arguments)
            try check(result.status == 1 && result.output.isEmpty && result.error.contains("terminal_read_only:"),
                      "real CLI \(arguments.prefix(2).joined(separator: " ")) exits 1 with terminal_read_only and no success JSON")
        }
    }

    private static func request(_ method: String, params: [String: ZshellJSONValue], session: TerminalSession) throws {
        var response: ZshellAutomationResponse?
        Task { @MainActor in
            response = await ZshellAutomationRouter.route(
                ZshellAutomationRequest(version: 1, id: UUID().uuidString, method: method,
                                        token: "test", terminalID: session.id.uuidString, params: params),
                callerTerminalID: session.id
            )
        }
        try wait("\(method) returns a response") { response != nil }
        try check(response?.ok == false && response?.error?.code == "terminal_read_only",
                  "\(method) returns terminal_read_only instead of sent")
    }

    private static func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews { if let result = find(identifier, in: child) { return result } }
        return nil
    }

    private static func command(_ action: String, root: URL) throws {
        sequence += 1
        let data = try JSONSerialization.data(withJSONObject: ["sequence": sequence, "action": action])
        try data.write(to: root.appendingPathComponent("control.json"), options: .atomic)
        try wait("fixture processes \(action)") {
            guard let bytes = try? Data(contentsOf: root.appendingPathComponent("state.json")),
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
            return object["sequence"] as? Int == sequence
        }
    }

    private static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw failure(label) }
        checks += 1
        print("PASS \(backend) read-only: \(label)")
    }

    private static func wait(_ label: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { pump(0.02) }
        try check(condition(), label)
    }

    private static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func failure(_ text: String) -> NSError { NSError(domain: "ReadOnlySurface", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
