import AppKit
import GhosttyTerminal
import UserNotifications
@testable import zshell

private enum DraftFailure: Error { case failed(String) }

@MainActor
private final class DraftNotificationDelivery: TerminalNotificationDelivery {
    func configure(delegate: any UNUserNotificationCenterDelegate) {}
    func settings(_ completion: @escaping @Sendable (TerminalNotificationAuthorization) -> Void) {
        completion(.init(status: .denied))
    }
    func authorize(_ completion: @escaping @Sendable (Bool) -> Void) { preconditionFailure("system authorization forbidden") }
    func deliver(_ record: TerminalNotificationRecord) { preconditionFailure("system delivery forbidden") }
    func remove(ids: [UUID]) {}
}

@main
@MainActor
struct AgentContextDraftSurfaceTests {
    private static var checks = 0
    private static var backend = ""

    static func main() {
        do { try run() } catch { fputs("Agent draft tests failed: \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        TerminalNotificationService.shared = TerminalNotificationService(delivery: DraftNotificationDelivery())
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        backend = CommandLine.arguments[2]
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard home.path.contains("zshell-agent-draft-tests-") else { throw DraftFailure.failed("disposable HOME required") }
        try """
        HISTFILE=/dev/null
        unsetopt SHARE_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME APPEND_HISTORY
        bindkey -e
        PROMPT='DRAFT_READY> '
        RPROMPT=''
        PS2=''
        """.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let settings = AppSettings.shared
        settings.language = .english
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.terminalStartupProgram = ""
        settings.restoreTerminalHistory = false
        settings.preserveTerminalSessions = false
        settings.resumeAgentConversations = false
        settings.commandHistoryEnabled = false
        settings.promptQueueAutoDispatch = false
        settings.copyOnSelect = false
        settings.notifyOnError = false
        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let project = Project(fallbackName: "Draft A", manager: manager, createInitialSession: false)
        project.customName = "Draft A"
        project.customDirectory = root.path
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.identifier = .init("main-agent-draft-fixture")
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        guard let source = project.newSession(directory: root.path) else { throw DraftFailure.failed("source shell missing") }
        mount(source, window: window)
        let controller = AgentContextDraftController.shared
        let clipboard = NSPasteboard.general
        let savedClipboard = (clipboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        var ownedClipboardCount = clipboard.changeCount
        defer {
            controller.close(restoreFocus: false)
            if clipboard.changeCount == ownedClipboardCount {
                clipboard.clearContents()
                clipboard.writeObjects(
                    savedClipboard.map { entries in
                        let item = NSPasteboardItem()
                        for (type, data) in entries { item.setData(data, forType: type) }
                        return item
                    })
            }
            manager.windowClosed()
            pump(0.2)
            window.contentView = nil
            window.close()
        }
        func visible(_ session: TerminalSession) -> String { session.surface.readVisibleText(maxLines: 100, maxColumns: 1_000) ?? "" }
        func command(_ text: String) throws -> TerminalCommandRecord {
            try wait("source has empty native zsh prompt") { source.terminalPromptQueueIsReady }
            let old = Set(source.commandRecords.map(\.id))
            source.sendCommand(text, asPaste: true)
            source.sendEnter()
            try wait("source command finishes") {
                source.terminalPromptQueueIsReady && source.commandRecords.contains { !old.contains($0.id) && $0.finishedAt != nil }
            }
            return source.commandRecords.first { !old.contains($0.id) }!
        }
        func menu(_ record: TerminalCommandRecord) throws -> NSMenu {
            guard let location = record.outputLocation, source.surface.revealCommand(at: location) else {
                throw DraftFailure.failed("record location missing")
            }
            pump(0.05)
            guard let snapshot = source.surface.readVisibleSnapshot() else { throw DraftFailure.failed("source viewport missing") }
            for row in snapshot.rows.indices {
                let point = NSPoint(
                    x: snapshot.origin.x + snapshot.cellSize.width * 2.25,
                    y: source.surface.bounds.height - snapshot.origin.y - snapshot.cellSize.height * (CGFloat(row) + 0.5))
                let event = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: source.surface.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if source.surface.commandLocation(for: event) == location {
                    return TerminalContextMenu.make(for: source.surface, event: event, linkTarget: nil)
                }
            }
            throw DraftFailure.failed("clicked command not found")
        }
        func item(_ identifier: String, _ menu: NSMenu) throws -> NSMenuItem {
            guard let item = menu.items.first(where: { $0.identifier?.rawValue == identifier }) else {
                throw DraftFailure.failed("menu item missing: " + identifier)
            }
            return item
        }
        func invoke(_ item: NSMenuItem) throws {
            guard let action = item.action else { throw DraftFailure.failed("action missing") }
            try check(NSApp.sendAction(action, to: item.target, from: item), "native menu dispatch")
        }
        func button(_ identifier: String) throws -> NSButton {
            guard
                let button = descendants(controller.panel?.contentView).first(where: { $0.identifier?.rawValue == identifier }) as? NSButton
            else {
                throw DraftFailure.failed("button missing: " + identifier)
            }
            return button
        }
        try testDraftState()
        try wait("source ready") { source.terminalPromptQueueIsReady }
        clipboard.clearContents()
        clipboard.setString("DRAFT_CLIPBOARD_SENTINEL", forType: .string)
        ownedClipboardCount = clipboard.changeCount
        let record = try command("printf '中文😀 first\\nsecond line\\n'")
        let blockMenu = try menu(record)
        let outputItem = try item("zshell-draft-output", blockMenu)
        try invoke(outputItem)
        let output = project.agentContextDraft.text
        try check(output.contains("中文😀 first\nsecond line"), "clicked command output preserves Unicode and newlines")
        try check(project.agentContextDraft.sources.count == 1, "command source retained")
        try check(project.agentContextDraft.sources[0].command == record.command, "clicked command source label")
        try check(clipboard.string(forType: .string) == "DRAFT_CLIPBOARD_SENTINEL", "capturing output does not touch clipboard")
        try check(try button("draft-focus").isEnabled == false, "no agent disables focus")
        try check(try button("draft-copy").isEnabled, "copy works without a target")
        try check(
            !descendants(controller.panel?.contentView).contains { $0.identifier?.rawValue == "draft-insert" },
            "no unchecked terminal insert action")
        controller.close()
        try check(project.agentContextDraft.text == output, "closing retains draft")
        try check(source.surface.selectCommand(at: record.outputLocation!), "native command selection")
        let selection = source.surface.readSelectedText(maxBytes: 262_144)
        try check(selection?.contains("中文😀") == true, "native selection Unicode")
        try check(source.surface.readSelectedText(maxBytes: 1) == nil, "oversized selection fails without truncation")
        try check(
            source.surface.commandText(at: record.outputLocation!, part: .output, maxBytes: 1) == nil,
            "oversized block fails without truncation")
        let selectionItem = try item("zshell-draft-selection", TerminalContextMenu.make(for: source.surface, linkTarget: nil))
        try invoke(selectionItem)
        try check(project.agentContextDraft.text == output + "\n\n" + selection!, "selection appends instead of replacing")
        try check(project.agentContextDraft.sources.count == 2, "selection source retained")
        try check(clipboard.changeCount == ownedClipboardCount, "selection capture leaves clipboard untouched")
        let edited = "Review this 中文😀\n\n" + project.agentContextDraft.text
        controller.editor.string = edited
        controller.textDidChange(Notification(name: NSText.didChangeNotification))
        let cancelled = controller.textView(controller.editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try check(
            cancelled && controller.panel?.isVisible == false && project.agentContextDraft.text == edited,
            "Escape keeps edited multiline draft")
        controller.show(for: project, manager: manager)
        try check(controller.editor.string == edited, "reopening restores edited draft")
        controller.copyDraft(nil)
        ownedClipboardCount = clipboard.changeCount
        try check(clipboard.string(forType: .string) == edited, "Copy Draft exact multiline content")
        controller.close()

        let other = Project(fallbackName: "Draft B", manager: manager, createInitialSession: false)
        other.customName = "Draft B"
        other.customDirectory = root.path
        manager.projects.append(other)
        let otherSource = AgentContextDraft.Source(kind: .selection, terminalTitle: "B", command: nil)
        try check(other.agentContextDraft.append("OTHER_PROJECT_DRAFT", source: otherSource), "second project owns independent draft")
        controller.show(for: project, manager: manager)
        controller.editor.undoManager?.registerUndo(withTarget: controller.editor) { $0.string = "UNDO_FROM_A" }
        try check(controller.editor.undoManager?.canUndo == true, "editor undo stack active")
        controller.show(for: other, manager: manager)
        try check(
            controller.editor.undoManager?.canUndo != true && controller.editor.string == "OTHER_PROJECT_DRAFT",
            "switching projects clears undo history")
        controller.close()
        try check(project.agentContextDraft.text == edited, "other project's editor cannot overwrite original draft")

        guard let agent = project.newSession(directory: root.path) else { throw DraftFailure.failed("agent shell missing") }
        mount(agent, window: window)
        try wait("agent shell ready") { agent.terminalPromptQueueIsReady }
        let fixture = root.appendingPathComponent("claude.py")
        let capture = root.appendingPathComponent("agent-input.json")
        try agentFixture.write(to: fixture, atomically: true, encoding: .utf8)
        agent.sendCommand("/usr/bin/python3 " + quote(fixture.path) + " " + quote(capture.path), asPaste: true)
        agent.sendEnter()
        try wait("native foreground fixture recognized") {
            agent.isAutomationAgentRunning(kind: .claude) && FileManager.default.fileExists(atPath: capture.path)
        }
        func status(_ phase: ZshellAgentPhase) {
            agent.updateAutomationAgentStatus(
                alias: "fixture", kind: .claude, phase: phase, authority: .integration,
                reason: "Fixture", processID: agent.surface.foregroundPid, unseen: false)
        }
        status(.idle)
        guard let context = ZshellAutomationRouter.context(forSession: agent.id), let target = AgentContextDraftTarget(context: context)
        else {
            throw DraftFailure.failed("native target missing")
        }
        project.agentContextDraft.target = target
        try check(target.context(in: project)?.session === agent, "target binds native process incarnation")
        try check(target.context(in: other) == nil, "cross-project target rejected")
        let before = try Data(contentsOf: capture)
        controller.show(for: project, manager: manager)
        manager.selectedProjectID = other.id
        pump(0.05)
        controller.copyDraft(nil)
        ownedClipboardCount = clipboard.changeCount
        try check(clipboard.string(forType: .string) == edited, "project switch keeps source draft")
        status(.working)
        controller.reload()
        try check(try button("draft-focus").isEnabled, "working target can be navigated without input")
        status(.blocked)
        controller.reload()
        agent.surface.isReadOnly = true
        controller.reload()
        try check(
            try button("draft-copy").isEnabled && button("draft-focus").isEnabled,
            "read-only blocked target keeps manual copy and navigation")
        controller.focusAgent(nil)
        try wait("focus selects original agent project") { manager.selectedProjectID == project.id && project.selectedSession === agent }
        try check(try Data(contentsOf: capture) == before, "copy and focus send no PTY bytes and no Enter")
        agent.surface.isReadOnly = false
        status(.idle)
        agent.sendCommand("EXISTING_INPUT ", asPaste: true)
        try wait("fixture records existing terminal draft") { (try? Data(contentsOf: capture)) != before }
        let existing = try Data(contentsOf: capture)
        controller.show(for: project, manager: manager)
        controller.copyDraft(nil)
        ownedClipboardCount = clipboard.changeCount
        controller.focusAgent(nil)
        pump(0.1)
        try check(try Data(contentsOf: capture) == existing, "existing terminal input remains unchanged")
        let identity = AgentConversationIdentity(provider: .claude, sessionID: UUID().uuidString, workingDirectory: root.path)!
        agent.recordAgentConversation(identity, processID: agent.surface.foregroundPid)
        try check(target.context(in: project) == nil, "conversation identity change invalidates original target")
        controller.show(for: project, manager: manager)
        try check(try button("draft-focus").isEnabled == false, "stale identity disables focus without retargeting")
        try check(project.agentContextDraft.target == target, "identity change retains chosen target and draft")
        controller.close()

        let current = AgentContextDraftTarget(context: ZshellAutomationRouter.context(forSession: agent.id)!)!
        project.agentContextDraft.target = current
        let tab = ZshellAutomationRouter.context(forSession: agent.id)!.tab
        let moved = project.detachTabForTransfer(id: tab.id)!
        other.adoptTransferredTab(moved, manager: manager)
        try check(current.context(in: project) == nil, "moving target to another project invalidates it")
        let returned = other.detachTabForTransfer(id: moved.id)!
        project.adoptTransferredTab(returned, manager: manager)
        status(.idle)
        mount(agent, window: window)
        controller.show(for: project, manager: manager)
        if let ghostty = agent.surface as? ZshellTerminalView {
            ghostty.performBindingAction("text:\\x03")
        } else {
            agent.sendCommand("\u{03}")
        }
        try wait("agent process exits") { !current.process.isAlive }
        controller.reload()
        try check(try button("draft-focus").isEnabled == false, "exited target disables focus")
        try check(project.agentContextDraft.text == edited, "exit preserves draft")
        controller.close()

        mount(source, window: window)
        let staleMenu = try menu(record)
        let staleOutput = try item("zshell-draft-output", staleMenu)
        source.clear()
        pump(0.1)
        try check((staleOutput.target as? any NSMenuItemValidation)?.validateMenuItem(staleOutput) == false, "cleared block token disabled")
        try invoke(staleOutput)
        try check(project.agentContextDraft.text == edited, "stale block never falls back to latest output")
        controller.close()
        controller.show(for: project, manager: manager)
        window.close()
        pump(0.05)
        try check(controller.panel?.isVisible == false && controller.editor.string.isEmpty, "host window closure releases panel and editor")
        try check(project.agentContextDraft.text == edited, "host closure keeps in-memory project draft")
        print("Agent draft \(backend): \(checks) checks passed")
    }

    private static func testDraftState() throws {
        let draft = AgentContextDraft()
        let combined = "a" + String(repeating: "\u{0301}", count: 400)
        let source = AgentContextDraft.Source(kind: .selection, terminalTitle: combined, command: combined)
        try check(
            source.terminalTitle.utf8.count <= 320 && (source.command?.utf8.count ?? 0) <= 320,
            "source labels bounded by bytes with combining characters")
        try check(draft.append("中文😀\nsecond line", source: source), "multiline draft append")
        try check(draft.append("\ntrailing spaces  ", source: source), "whitespace source preserved")
        try check(draft.text == "中文😀\nsecond line\n\n\ntrailing spaces  ", "exact multiline append separators")
        let text = draft.text
        try check(
            !draft.append(String(repeating: "x", count: AgentContextDraft.maximumBytes), source: source) && draft.text == text,
            "oversized append retains old draft")
        try check(
            !draft.edit(String(repeating: "x", count: AgentContextDraft.maximumBytes + 1)) && draft.text == text,
            "oversized edit retains old draft")
        let limit = AgentContextDraft()
        for _ in 0 ..< 64 { _ = limit.append("x", source: source) }
        try check(!limit.append("y", source: source) && limit.sources.count == 64, "source count bounded")
        _ = draft.edit("")
        try check(draft.sources.isEmpty, "clearing draft clears source labels")
        let isolated = NSPasteboard.withUniqueName()
        defer { isolated.releaseGlobally() }
        isolated.setString("sentinel", forType: .string)
        try check(!draft.copy(to: isolated) && isolated.string(forType: .string) == "sentinel", "empty draft does not erase clipboard")
    }

    private static func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return root.subviews.flatMap { [$0] + descendants($0) }
    }
    private static func mount(_ session: TerminalSession, window: NSWindow) {
        window.contentView = session.surface
        session.surface.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(session.surface)
        session.surface.setSurfaceVisible(true)
        pump(0.05)
    }
    private static func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }
    private static func wait(_ label: String, until predicate: () -> Bool) throws {
        let until = Date().addingTimeInterval(8)
        while !predicate(), Date() < until { pump(0.01) }
        try check(predicate(), label)
    }
    private static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw DraftFailure.failed("\(backend): \(label)") }
        checks += 1
        print("PASS: \(backend) \(label)")
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static let agentFixture = """
        import codecs, json, os, select, signal, sys, tty
        from pathlib import Path
        signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        if os.getpid() != os.getpgrp(): os.setpgid(0, 0)
        os.tcsetpgrp(0, os.getpgrp())
        tty.setraw(0)
        output = Path(sys.argv[1])
        received = bytearray()
        def save(): output.write_text(json.dumps({'bytes': list(received)}))
        save()
        sys.stdout.write('CLAUDE_FIXTURE_READY\\r\\n'); sys.stdout.flush()
        while True:
            if not select.select([0], [], [], 0.05)[0]: continue
            data = os.read(0, 4096)
            if not data or b'\\x03' in data: break
            received.extend(data)
            save()
            sys.stdout.write('INPUT_RECEIVED\\r\\n'); sys.stdout.flush()
        """
}
