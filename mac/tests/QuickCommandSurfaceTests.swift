import AppKit
import Foundation
import GhosttyTerminal
@testable import zshell

@MainActor private final class QuickCommandTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

private enum QuickCommandTestFailure: Error { case failed(String) }

@main @MainActor
struct QuickCommandSurfaceTests {
    private static var checks = 0

    static func main() {
        do { try run() } catch { fputs("Quick command surfaces failed: \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let gui = ProcessInfo.processInfo.environment["ZSHELL_TEST_QUICK_COMMAND_GUI"] == "1"
        NSApp.setActivationPolicy(gui ? .accessory : .prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let backend = CommandLine.arguments[2]
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard home.path.contains("zshell-quick-command-tests-") else { throw QuickCommandTestFailure.failed("disposable HOME required") }
        let draft = root.appendingPathComponent("draft.txt")
        let log = root.appendingPathComponent("argv.txt")
        let accepted = root.appendingPathComponent("accepted.txt")
        try """
        HISTFILE=/dev/null
        unsetopt SHARE_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME APPEND_HISTORY
        bindkey -e
        PROMPT='QUICK_READY> '
        RPROMPT=''
        _quick_dump() { builtin print -rn -- "$BUFFER" >| \(quote(draft.path)); }
        zle -N _quick_dump
        bindkey '^T' _quick_dump
        _quick_capture() { /usr/bin/printf '%s\\0' "$@" >> \(quote(log.path)); }
        _quick_line_finish() { builtin print -r -- "$BUFFER" >> \(quote(accepted.path)); }
        autoload -Uz add-zle-hook-widget
        add-zle-hook-widget line-finish _quick_line_finish
        """.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        AppLocalization.apply(.english)
        TerminalFont.registerBundledFonts()
        let settings = AppSettings.shared
        settings.language = .english
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.terminalStartupProgram = ""
        settings.preserveTerminalSessions = false
        settings.restoreTerminalHistory = false
        settings.resumeAgentConversations = false
        settings.notifyOnError = false
        settings.promptQueueAutoDispatch = false
        settings.promptQueueEnabled = true
        let manager = TerminalManager()
        for project in manager.projects { manager.close(project) }
        let project = Project(fallbackName: "Quick command fixture", manager: manager, createInitialSession: false)
        project.customDirectory = root.path
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        let window = makeWindow()
        manager.attach(to: window)
        guard let session = project.newSession(directory: root.path), let pane = project.tabs.first?.focusedPane else {
            throw QuickCommandTestFailure.failed("fixture shell missing")
        }
        mount(session, in: window)
        if gui { window.makeKeyAndOrderFront(nil) }
        defer { manager.windowClosed(); pump(0.25); window.contentView = nil; window.close() }
        do {
            try wait("fresh root zsh") { session.terminalPromptQueueIsReady && session.isShellAvailableForAutomation }
        } catch {
            print(
                "STARTUP exited=\(session.hasExited) terminating=\(session.isTerminating) shell=\(String(describing: session.shellPid)) foreground=\(String(describing: session.surface.foregroundPid)) phase=\(session.commandLifecycle.phase)"
            )
            print(
                "STARTUP window=\(String(describing: session.surface.window)) bounds=\(session.surface.bounds) viewport=\(String(reflecting: session.surface.readVisibleText(maxLines: 12, maxColumns: 120) ?? ""))"
            )
            throw error
        }
        let value = QuickCommandParameter(name: "branch", defaultValue: "main")
        let environment = QuickCommandParameter(
            name: "environment", kind: .dropdown, defaultValue: "staging", choices: ["staging", "production"])
        let preset = QuickCommandPreset(
            name: "Deploy", command: "_quick_capture {{environment}} {{branch}} {{branch}}", parameters: [environment, value])
        QuickCommandStore.shared.replace(with: [preset])

        let controller = QuickCommandInvocationWindowController(preset: preset, session: session, run: true)
        guard let content = controller.window?.contentView else { throw QuickCommandTestFailure.failed("preview content missing") }
        let preview = try view("quick-command-preview-text", in: content, type: NSTextView.self)
        let field = try view("quick-command-value-branch", in: content, type: NSTextField.self)
        let picker = try view("quick-command-value-environment", in: content, type: NSPopUpButton.self)
        let send = try view("quick-command-preview-send", in: content, type: NSButton.self)
        try check(preview.string == "_quick_capture 'staging' 'main' 'main'", "default preview matches exact command")
        try check(send.keyEquivalent.isEmpty, "Run has no Return shortcut")
        try check(
            controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))),
            "Return is consumed by field editing")
        pump(0.04)
        try check(!exists(log), "field Return does not run terminal command")
        field.stringValue = "bad\nvalue"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try check(!send.isEnabled && preview.string.isEmpty, "invalid multiline value clears preview and disables send")
        let malicious = "release \"quote\" 你好 👩🏽‍💻; $(touch " + root.appendingPathComponent("injected").path + ")"
        field.stringValue = malicious
        picker.selectItem(at: 1)
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        let expected = try preset.resolvedCommand(values: ["branch": malicious, "environment": "production"])
        try check(preview.string == expected && send.isEnabled, "updated native inputs render exact preview")
        let before = read(accepted)
        send.performClick(nil)
        send.performClick(nil)
        try wait("one explicit run completes") { exists(log) && session.terminalPromptQueueIsReady }
        try check(
            try Data(contentsOf: log) == Data(("production\0" + malicious + "\0" + malicious + "\0").utf8),
            "real PTY receives literal choice and repeated value")
        try check(!exists(root.appendingPathComponent("injected")), "parameter cannot execute shell syntax")
        try check(read(accepted).dropFirst(before.count).split(separator: "\n").count == 1, "repeated Run emits one Enter")
        try check(QuickCommandStore.shared.presets == [preset], "invocation values never update saved defaults")

        let cancelled = QuickCommandInvocationWindowController(preset: preset, session: session, run: true)
        let cancelContent = cancelled.window!.contentView!
        let cancelField = try view("quick-command-value-branch", in: cancelContent, type: NSTextField.self)
        cancelField.stringValue = "unsaved transient value"
        cancelled.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: cancelField))
        let logBefore = try Data(contentsOf: log)
        let cancel = try view("quick-command-preview-cancel", in: cancelContent, type: NSButton.self)
        cancel.performClick(nil)
        pump(0.05)
        try check(
            try Data(contentsOf: log) == logBefore && QuickCommandStore.shared.presets == [preset],
            "Cancel sends nothing and saves no parameter values")

        let inserted = QuickCommandInvocationWindowController(preset: preset, session: session, run: false)
        let insertedContent = inserted.window!.contentView!
        let insertedPreview = try view("quick-command-preview-text", in: insertedContent, type: NSTextView.self).string
        let insert = try view("quick-command-preview-send", in: insertedContent, type: NSButton.self)
        insert.performClick(nil)
        try wait("insertion creates an edit buffer") { !session.terminalPromptQueueIsReady }
        try check(try dumpDraft(session, at: draft) == insertedPreview, "Insert sends exactly the preview and no Enter")
        try check(try Data(contentsOf: log) == logBefore, "insertion cannot execute the command")
        let draftInvocation = QuickCommandInvocation(session: session)
        try check(!draftInvocation.send("_quick_capture 'blocked'", run: true), "existing shell draft rejects invocation")
        try check(try dumpDraft(session, at: draft) == insertedPreview, "rejected invocation preserves shell draft")
        clearDraft(session)
        try wait("cleared prompt") { session.terminalPromptQueueIsReady }

        let locked = QuickCommandInvocation(session: session)
        session.surface.isReadOnly = true
        try check(!locked.send("_quick_capture 'locked'", run: true), "read-only session rejects send")
        session.surface.isReadOnly = false
        try check(!locked.send("_quick_capture 'stale lock'", run: true), "changed lock generation rejects old preview")
        let queued = QuickCommandInvocation(session: session)
        session.promptQueue.enqueue("retained queue entry")
        try check(!queued.send("_quick_capture 'queued'", run: true), "queued prompt owns input")
        session.promptQueue.remove(at: 0)
        settings.promptQueueEnabled = false
        let queueDisabled = QuickCommandInvocation(session: session)
        try check(queueDisabled.unavailableReason == nil, "parameter commands do not require enabled prompt queue")
        settings.promptQueueEnabled = true

        let moved = QuickCommandInvocation(session: session)
        let other = Project(fallbackName: "Other project", manager: manager, createInitialSession: false)
        manager.projects.append(other)
        manager.selectedProjectID = other.id
        try check(!moved.send("_quick_capture 'other project'", run: true), "project switch rejects old preview")
        manager.selectedProjectID = project.id
        let otherManager = TerminalManager()
        let transferred = QuickCommandInvocation(session: session)
        session.transferHost(to: otherManager)
        try check(!transferred.send("_quick_capture 'other host'", run: true), "host transfer rejects old preview")
        session.transferHost(to: manager)
        otherManager.windowClosed()
        let oldWindow = QuickCommandInvocation(session: session)
        let replacement = makeWindow()
        mount(session, in: replacement)
        try check(!oldWindow.send("_quick_capture 'other window'", run: true), "reparented surface rejects old preview")
        mount(session, in: window)
        replacement.contentView = nil
        replacement.close()

        let busy = QuickCommandInvocation(session: session)
        try check(session.sendCommand("builtin read -r ANSWER", asPaste: true) && session.sendEnter(), "builtin read starts")
        try wait("busy builtin clears prompt readiness") { !session.terminalPromptQueueIsReady }
        try check(
            session.surface.foregroundPid == session.shellPid && !busy.send("_quick_capture 'busy root'", run: true),
            "busy root shell rejects send")
        session.sendCommand("deliberate answer")
        session.sendEnter()
        try wait("builtin returns") { session.terminalPromptQueueIsReady && session.isShellAvailableForAutomation }

        let nested = QuickCommandInvocation(session: session)
        session.sendCommand("/bin/zsh -f", asPaste: true)
        session.sendEnter()
        try wait("nested shell owns PTY") { session.surface.foregroundPid != session.shellPid }
        try check(!nested.send("_quick_capture 'nested'", run: true), "nested shell rejects parameter commands")
        session.sendCommand("exit")
        session.sendEnter()
        try wait("original shell returns") { session.terminalPromptQueueIsReady && session.isShellAvailableForAutomation }

        let taskInvocation = QuickCommandInvocation(session: session)
        let task = TerminalCommandTaskStore.shared.submit(
            argv: ["/bin/sleep", "0.1"], projectID: project.id, paneID: pane.id, session: session)
        try check(!taskInvocation.send("_quick_capture 'task'", run: true), "pending task owns input before shell starts it")
        try wait("task completes") {
            TerminalCommandTaskStore.shared.task(id: task.id, projectID: project.id)?.state.isTerminal == true
                && session.terminalPromptQueueIsReady
        }

        try editor(preset: preset)
        if gui { try sheets(preset: preset, session: session, window: window) }
        let menu = session.surface.splitTarget.quickCommandMenuItem().submenu!.items
        try check(menu.first?.submenu?.items.count == 2, "existing preset menu retains Insert and Run actions")
        let fixed = QuickCommandPreset(name: "Fixed", command: "_quick_capture fixed")
        QuickCommandStore.shared.replace(with: [fixed])
        let fixedMenu = session.surface.splitTarget.quickCommandMenuItem().submenu!.items
        let fixedInsert = fixedMenu[0].submenu!.items[0]
        NSApp.sendAction(fixedInsert.action!, to: fixedInsert.target, from: fixedInsert)
        try wait("fixed command insert reaches prompt") { !session.terminalPromptQueueIsReady }
        try check(try dumpDraft(session, at: draft) == fixed.command, "legacy fixed command insertion remains exact")
        clearDraft(session)
        try wait("fixed command cleared") { session.terminalPromptQueueIsReady }

        let closing = QuickCommandInvocation(session: session)
        session.terminate()
        try check(!closing.send("_quick_capture 'closed'", run: true), "terminated session rejects send without Enter")
        print("Quick command \(backend): \(checks) native UI and real PTY checks passed")
    }

    private static func editor(preset: QuickCommandPreset) throws {
        QuickCommandStore.shared.replace(with: [preset])
        let controller = QuickCommandEditorWindowController()
        let content = controller.window!.contentView!
        let name = try view("quick-command-name", in: content, type: NSTextField.self)
        let command = try view("quick-command-command", in: content, type: NSTextField.self)
        let parameterName = try view("quick-command-parameter-name", in: content, type: NSTextField.self)
        let type = try view("quick-command-parameter-kind", in: content, type: NSPopUpButton.self)
        let defaultField = try view("quick-command-parameter-default", in: content, type: NSTextField.self)
        let choices = try view("quick-command-parameter-choices", in: content, type: NSTextView.self)
        let save = try view("quick-command-save", in: content, type: NSButton.self)
        try check(name.stringValue == preset.name && command.stringValue == preset.command, "editor opens existing preset")
        try check(
            parameterName.stringValue == "environment" && type.indexOfSelectedItem == 1 && defaultField.stringValue == "staging",
            "editor restores parameter type and default")
        defaultField.stringValue = "invalid"
        defaultField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: defaultField))
        try check(!save.isEnabled, "invalid dropdown default disables saving")
        defaultField.stringValue = "production"
        defaultField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: defaultField))
        try check(save.isEnabled, "listed dropdown default enables saving")
        choices.string = "staging\nproduction\nproduction"
        choices.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: choices))
        try check(!save.isEnabled, "duplicate dropdown choices disable saving")
        choices.string = "staging\nproduction"
        choices.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: choices))
        save.performClick(nil)
        try check(
            QuickCommandStore.shared.presets[0].parameters[0].defaultValue == "production", "native Save persists valid parameter edits")
        let cancelled = QuickCommandEditorWindowController()
        let cancelledContent = cancelled.window!.contentView!
        let edited = try view("quick-command-name", in: cancelledContent, type: NSTextField.self)
        edited.stringValue = "unsaved preset name"
        try view("quick-command-cancel", in: cancelledContent, type: NSButton.self).performClick(nil)
        try check(QuickCommandStore.shared.presets[0].name == preset.name, "editor Cancel keeps stored presets")
    }

    private static func sheets(preset: QuickCommandPreset, session: TerminalSession, window: NSWindow) throws {
        window.makeKeyAndOrderFront(nil)
        var closed = false
        weak var weakController: QuickCommandInvocationWindowController?
        try autoreleasepool {
            let controller = QuickCommandInvocationWindowController(preset: preset, session: session, run: true)
            weakController = controller
            controller.onClose = { closed = true }
            controller.present(relativeTo: window)
            try wait("parameter preview attaches to origin window") { window.attachedSheet === controller.window }
            try escapeSheet(controller)
            try wait("Escape releases native sheet ownership") { window.attachedSheet == nil && closed }
        }
        try wait("dismissed preview releases controller and timer") { weakController == nil }
        let previewMenu = session.surface.splitTarget.quickCommandMenuItem().submenu!.items
        let run = previewMenu[0].submenu!.items[1]
        NSApp.sendAction(run.action!, to: run.target, from: run)
        try wait("existing Run menu opens a parameter sheet") { window.attachedSheet?.identifier?.rawValue == "quick-command-preview" }
        let previewContent = window.attachedSheet!.contentView!
        let cancel = try view("quick-command-preview-cancel", in: previewContent, type: NSButton.self)
        cancel.performClick(nil)
        try wait("menu preview Cancel closes its sheet") { window.attachedSheet == nil }
        let closingWindow = makeWindow()
        mount(session, in: closingWindow)
        closingWindow.makeKeyAndOrderFront(nil)
        var hostClosed = false
        let hostController = QuickCommandInvocationWindowController(preset: preset, session: session, run: true)
        hostController.onClose = { hostClosed = true }
        hostController.present(relativeTo: closingWindow)
        try wait("host-close fixture attaches sheet") { closingWindow.attachedSheet != nil }
        closingWindow.close()
        try wait("closing parent dismisses preview and timer") { hostClosed && hostController.window?.sheetParent == nil }
        mount(session, in: window)
        closingWindow.contentView = nil
    }

    private static func escapeSheet(_ controller: QuickCommandInvocationWindowController) throws {
        let field = try view("quick-command-value-branch", in: controller.window!.contentView!, type: NSTextField.self)
        try check(
            controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))),
            "Escape dismisses the active sheet")
    }

    private static func makeWindow() -> NSWindow {
        let window = QuickCommandTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("main-quick-command-fixture")
        return window
    }
    private static func mount(_ session: TerminalSession, in window: NSWindow) {
        let container = TerminalContainerView(frame: window.contentLayoutRect)
        // Ghostty creates its PTY on attachment, so give the offscreen host
        // real geometry before viewDidMoveToWindow rather than waiting for layout.
        session.surface.frame = container.bounds
        container.mount(session.surface, scrollbar: session.overlayScrollbar, queueBar: session.promptQueueBar)
        window.contentView = container
        window.makeFirstResponder(session.surface)
        session.surface.setSurfaceVisible(true)
        container.layoutSubtreeIfNeeded()
    }
    private static func view<T: NSView>(_ identifier: String, in root: NSView, type: T.Type) throws -> T {
        guard let found = descendants(root).first(where: { $0.identifier?.rawValue == identifier }) as? T else {
            throw QuickCommandTestFailure.failed("missing native control: " + identifier)
        }
        return found
    }
    private static func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    private static func quote(_ value: String) -> String { TerminalSession.shellQuote(value) }
    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private static func dumpDraft(_ session: TerminalSession, at path: URL) throws -> String {
        try? FileManager.default.removeItem(at: path)
        control("\u{14}", in: session)
        try wait("zsh dumps exact buffer") { exists(path) }
        return read(path)
    }
    private static func clearDraft(_ session: TerminalSession) { control("\u{15}", in: session) }
    private static func control(_ text: String, in session: TerminalSession) {
        if let ghostty = session.surface as? AppTerminalView {
            let escaped = text.utf8.map { String(format: "\\x%02x", $0) }.joined()
            ghostty.performBindingAction("text:" + escaped)
        } else {
            session.surface.sendText(text)
        }
    }
    private static func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    private static func wait(_ message: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { pump(0.02) }
        try check(condition(), message)
    }
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw QuickCommandTestFailure.failed(message) }
    }
}
