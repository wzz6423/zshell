import AppKit
import Foundation
@testable import zshell

private enum PromptQueueFailure: Error { case failed(String) }

@main
@MainActor
struct TerminalPromptQueueSurfaceTests {
    private static var checks = 0

    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let backend = CommandLine.arguments[2]
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard ["/tmp/zshell-prompt-queue-tests-", "/private/tmp/zshell-prompt-queue-tests-"]
            .contains(where: home.path.hasPrefix) else {
            throw PromptQueueFailure.failed("acceptance requires a disposable HOME")
        }
        let draft = root.appendingPathComponent("shell-draft.txt")
        try """
        HISTFILE=/dev/null
        unsetopt SHARE_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME APPEND_HISTORY
        bindkey -e
        PROMPT='QUEUE_READY> '
        RPROMPT=''
        _queue_dump_draft() { builtin print -rn -- "$BUFFER" >| \(quote(draft.path)); }
        zle -N _queue_dump_draft
        bindkey '^T' _queue_dump_draft
        """.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let settings = AppSettings.shared
        settings.language = .english
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.terminalStartupProgram = ""
        settings.restoreTerminalHistory = false
        settings.preserveTerminalSessions = false
        settings.resumeAgentConversations = false
        settings.notifyOnError = false
        settings.copyOnSelect = false
        settings.shellCompletions = true
        try check(settings.promptQueueEnabled && !settings.promptQueueAutoDispatch,
                  "default queue mode uses explicit sending")

        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let project = Project(fallbackName: "Queue fixture", manager: manager, createInitialSession: false)
        project.customDirectory = root.path
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        let window = makeWindow("main-prompt-queue-fixture")
        manager.attach(to: window)
        guard let session = project.newSession(directory: root.path),
              let pane = project.tabs.first?.focusedPane else {
            throw PromptQueueFailure.failed("fixture shell could not start")
        }
        mount(session, in: window)
        defer {
            SettingsWindowController.shared.window?.close()
            manager.windowClosed()
            pump(0.6)
            window.contentView = nil
            window.close()
        }
        try wait("original shell reaches a fresh prompt") { session.canSendQueuedPrompt }

        session.promptQueue.present()
        let field = try input(in: session)
        field.stringValue = "typed\r\nqueued"
        try check(session.promptQueueBar.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))),
                  "Return explicitly adds the composer entry")
        try check(session.promptQueue.commands == ["typed queued"] && field.stringValue.isEmpty,
                  "Return queues one flattened line without submitting it to the terminal")
        session.promptQueue.remove(at: 0)
        field.stringValue = "unsent composer draft 你好"
        let manualMarker = root.appendingPathComponent("manual.txt")
        session.promptQueue.enqueue("printf manual > " + quote(manualMarker.path))
        session.schedulePromptQueueDispatch()
        session.terminalDidReportShellIntegration(.promptStart)
        session.terminalDidReportShellIntegration(.commandFinished(exitCode: 0, durationNanos: nil))
        pump(0.45)
        try check(!exists(manualMarker) && session.promptQueue.commands.count == 1
                  && session.promptQueueDispatchTask == nil,
                  "manual mode rejects every automatic scheduling entry point")
        let sendButton = try button("prompt-queue-send-0", in: session.promptQueueBar)
        try check(sendButton.isEnabled, "fresh prompt enables the native send control")
        sendButton.performClick(nil)
        try wait("explicit native click sends the queued entry") { exists(manualMarker) && session.canSendQueuedPrompt }
        try check(session.promptQueue.commands.isEmpty && field.stringValue == "unsent composer draft 你好",
                  "sending does not submit or erase the queue composer draft")

        let duplicate = root.appendingPathComponent("duplicate.txt")
        session.promptQueue.enqueue("/bin/sleep 0.3; printf first >> " + quote(duplicate.path))
        session.promptQueue.enqueue("printf second >> " + quote(duplicate.path))
        try check(session.sendQueuedPrompt(at: 0), "first explicit send succeeds")
        try check(!session.sendQueuedPrompt(at: 0) && session.promptQueue.commands.count == 1,
                  "a second synchronous click cannot reuse the same prompt acknowledgement")
        try wait("first duplicate command finishes") { session.canSendQueuedPrompt && exists(duplicate) }
        try check(read(duplicate) == "first", "repeated click does not leak the next command into the PTY")
        session.promptQueue.remove(at: 0)

        let competitive = root.appendingPathComponent("competitive.txt")
        settings.promptQueueAutoDispatch = true
        session.promptQueue.enqueue("/bin/sleep 0.3; printf manual >> " + quote(competitive.path))
        session.promptQueue.enqueue("printf automatic >> " + quote(competitive.path))
        session.schedulePromptQueueDispatch()
        try check(session.sendQueuedPrompt(at: 0) && !session.sendQueuedPrompt(at: 0),
                  "explicit send cancels the settle window and reserves the prompt")
        pump(0.2)
        try check(!exists(competitive) && session.promptQueue.commands.count == 1,
                  "pending automatic window cannot race the manual PTY command")
        try wait("next acknowledged completion runs the remaining automatic entry") {
            read(competitive) == "manualautomatic" && session.canSendQueuedPrompt
        }
        settings.promptQueueAutoDispatch = false
        try bufferedReservation(session: session, root: root, window: window)

        let draftMarker = root.appendingPathComponent("draft-send.txt")
        session.promptQueue.enqueue("printf leaked > " + quote(draftMarker.path))
        session.sendCommand("SHELL_DRAFT_你好", asPaste: true)
        try wait("shell draft closes readiness") { !session.terminalPromptQueueIsReady }
        try check(!session.sendQueuedPrompt(at: 0), "manual send refuses to append to shell draft")
        settings.promptQueueAutoDispatch = true
        session.schedulePromptQueueDispatch()
        pump(2.1)
        try check(!exists(draftMarker) && session.promptQueue.commands.count == 1,
                  "automatic retry window cannot execute shell drafts")
        control("\u{14}", in: session)
        try wait("shell exposes preserved draft") { read(draft) == "SHELL_DRAFT_你好" }
        try check(!(try button("prompt-queue-send-0", in: session.promptQueueBar)).isEnabled,
                  "native send control is disabled while the shell has a draft")
        settings.promptQueueAutoDispatch = false
        control("\u{15}", in: session)
        control("\u{14}", in: session)
        pump(0.3)
        try wait("draft reset restores ready prompt") { session.canSendQueuedPrompt }
        session.promptQueue.remove(at: 0)

        let busyMarker = root.appendingPathComponent("busy-send.txt")
        session.sendCommand("/bin/sleep 0.7", asPaste: true)
        session.sendEnter()
        try wait("real foreground job owns PTY") { session.surface.foregroundPid != session.shellPid }
        session.promptQueue.enqueue("printf leaked > " + quote(busyMarker.path))
        try check(!session.sendQueuedPrompt(at: 0), "manual send cannot inject into a foreground program")
        pump(0.3)
        try check(!(try button("prompt-queue-send-0", in: session.promptQueueBar)).isEnabled,
                  "foreground task disables the native send control")
        try wait("foreground job finishes without queue sending") { session.canSendQueuedPrompt }
        try check(!exists(busyMarker) && session.promptQueue.commands.count == 1,
                  "manual mode keeps queue after a real command completion")
        session.promptQueue.remove(at: 0)

        let taskMarker = root.appendingPathComponent("task-send.txt")
        session.promptQueue.enqueue("printf leaked > " + quote(taskMarker.path))
        let task = TerminalCommandTaskStore.shared.submit(
            argv: ["/bin/sleep", "0.6"], projectID: project.id, paneID: pane.id, session: session
        )
        try check(TerminalCommandTaskStore.shared.hasActiveTask(terminalID: session.id),
                  "pending command task owns its PTY before execution")
        try check(!session.sendQueuedPrompt(at: 0), "queue cannot bypass the pending task owner")
        settings.promptQueueAutoDispatch = true
        session.schedulePromptQueueDispatch()
        settings.promptQueueEnabled = false
        try check(session.promptQueueDispatchTask == nil && !session.promptQueue.isPresented,
                  "master disable synchronously cancels pending dispatch and hides the bar")
        try wait("owned command task completes") {
            TerminalCommandTaskStore.shared.task(id: task.id, projectID: project.id)?.state.isTerminal == true
        }
        pump(0.25)
        try check(!exists(taskMarker) && session.promptQueue.commands.count == 1
                  && field.stringValue == "unsent composer draft 你好",
                  "task completion cannot replay a disabled queue and preserves composer input")
        settings.promptQueueEnabled = true
        pump(0.25)
        try check(!exists(taskMarker), "re-enabling does not replay saved entries")
        settings.promptQueueAutoDispatch = false
        session.promptQueue.present()
        session.promptQueue.remove(at: 0)
        try wait("shell reaches empty prompt after owned task") { session.canSendQueuedPrompt }

        let cancelled = root.appendingPathComponent("cancelled.txt")
        session.promptQueue.enqueue("printf leaked > " + quote(cancelled.path))
        settings.promptQueueAutoDispatch = true
        session.schedulePromptQueueDispatch()
        let previousGeneration = session.promptQueueDispatchGeneration
        settings.promptQueueAutoDispatch = false
        try check(session.promptQueueDispatchTask == nil && session.promptQueueDispatchGeneration > previousGeneration,
                  "automatic mode toggle invalidates the scheduled generation immediately")
        pump(0.25)
        try check(!exists(cancelled), "cancelled settle delay cannot leak a command")
        settings.promptQueueAutoDispatch = true
        pump(0.25)
        try check(!exists(cancelled), "automatic opt-in does not itself send existing queue content")
        session.promptQueue.remove(at: 0)

        let order = root.appendingPathComponent("order.txt")
        session.promptQueue.enqueue("printf first >> " + quote(order.path))
        session.promptQueue.enqueue("printf second >> " + quote(order.path))
        session.sendCommand(":", asPaste: true)
        session.sendEnter()
        try wait("real completion drains opted-in queue in order") {
            read(order) == "firstsecond" && session.promptQueue.commands.isEmpty && session.canSendQueuedPrompt
        }
        try check(field.stringValue == "unsent composer draft 你好",
                  "automatic dispatch never submits the composer draft")
        settings.promptQueueAutoDispatch = false

        let otherManager = TerminalManager()
        otherManager.projects.forEach { otherManager.close($0) }
        let otherProject = Project(fallbackName: "Other queue fixture", manager: otherManager, createInitialSession: false)
        otherProject.customDirectory = root.path
        otherManager.projects.append(otherProject)
        otherManager.selectedProjectID = otherProject.id
        let otherWindow = makeWindow("main-other-queue-fixture")
        otherManager.attach(to: otherWindow)
        guard let other = otherProject.newSession(directory: root.path) else { throw PromptQueueFailure.failed("other shell missing") }
        mount(other, in: otherWindow)
        defer { otherManager.windowClosed(); pump(0.4); otherWindow.contentView = nil; otherWindow.close() }
        let quick = TerminalSession(initialDirectory: root.path, allowsPersistence: false)
        let quickTab = PaneTab(content: .session(quick))
        let quickHost = QuickTerminalWorkspaceView(tab: quickTab, split: { _ in }, close: {})
        let quickWindow = makeWindow("quick-queue-fixture")
        quickWindow.contentView = quickHost
        quickWindow.makeKeyAndOrderFront(nil)
        quickHost.reveal()
        defer { quick.terminate(); pump(0.4); quickWindow.contentView = nil; quickWindow.close() }
        try wait("additional window and Quick Terminal shells reach ready prompts") { other.canSendQueuedPrompt && quick.canSendQueuedPrompt }
        let isolatedMarker = root.appendingPathComponent("isolated.txt")
        for item in [session, other, quick] {
            item.promptQueue.present()
            item.promptQueue.enqueue("printf leaked > " + quote(isolatedMarker.path))
            try input(in: item).stringValue = "unsent \(item.id)"
        }
        settings.promptQueueEnabled = false
        for item in [session, other, quick] {
            try check(!item.promptQueue.isPresented && item.promptQueueBar.isHidden && item.promptQueueBar.frame.height < 1,
                      "master switch hides queue in each native window and Quick Terminal")
            try check(!item.sendQueuedPrompt(at: 0) && item.promptQueue.commands.count == 1,
                      "disabled master blocks direct queue send paths without discarding content")
            try check(!item.promptQueueBar.isPollingReadiness,
                      "disabled master cancels each pane's readiness timer")
        }
        session.promptQueue.present()
        session.promptQueue.enqueue("blocked insertion")
        try check(!session.promptQueue.isPresented && session.promptQueue.commands.count == 1,
                  "disabled queue model rejects presentation and addition")
        let freshDisabled = TerminalSession(initialDirectory: root.path, allowsPersistence: false)
        freshDisabled.promptQueue.present()
        try check(!freshDisabled.promptQueue.isPresented, "new panes inherit disabled settings")
        freshDisabled.terminate()
        settings.promptQueueEnabled = true
        pump(0.2)
        try check(!exists(isolatedMarker), "no window or Quick Terminal automatically replays on re-enable")
        for item in [session, other, quick] {
            item.promptQueue.present()
            try check(try input(in: item).stringValue == "unsent \(item.id)",
                      "all composer drafts survive disable and re-enable")
            item.promptQueue.remove(at: 0)
        }
        let toggle = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                      timestamp: 0, windowNumber: quickWindow.windowNumber, context: nil,
                                      characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46)!
        try check(quickHost.handleKeyEquivalent(toggle) && !quick.promptQueue.isPresented && session.promptQueue.isPresented,
                  "Quick Terminal shortcut targets its own focused pane")
        _ = quickHost.handleKeyEquivalent(toggle)
        quick.promptQueue.enqueue("timer fixture")
        quick.promptQueueBar.setPaneVisible(true)
        try check(quick.promptQueueBar.isPollingReadiness, "visible mounted queue polls shell readiness")
        quick.promptQueueBar.setPaneVisible(false)
        try check(!quick.promptQueueBar.isPollingReadiness, "parked panes cancel readiness polling")
        quick.promptQueueBar.setPaneVisible(true)
        quickWindow.orderOut(nil)
        pump(0.08)
        try check(!quick.promptQueueBar.isPollingReadiness, "hidden Quick Terminal cancels its timer")
        quickWindow.makeKeyAndOrderFront(nil)
        quickHost.reveal()
        quick.promptQueue.remove(at: 0)
        try check(!quick.promptQueueBar.isPollingReadiness, "empty queue stops readiness polling")
        session.promptQueue.enqueue("not executed")
        session.transferHost(to: otherManager)
        try check(!session.sendQueuedPrompt(at: 0) && session.promptQueue.commands.count == 1,
                  "stale project host scope cannot dispatch queued work")
        session.transferHost(to: manager)
        session.promptQueue.remove(at: 0)

        let nested = root.appendingPathComponent("nested.txt")
        session.sendCommand("/bin/zsh -f", asPaste: true)
        session.sendEnter()
        try wait("nested shell owns foreground") { session.surface.foregroundPid != session.shellPid }
        session.promptQueue.enqueue("printf leaked > " + quote(nested.path))
        try check(!session.sendQueuedPrompt(at: 0), "nested shell cannot receive a queued prompt")
        session.sendCommand("exit", asPaste: true)
        session.sendEnter()
        try wait("nested shell returns to original") { session.canSendQueuedPrompt }
        try check(!exists(nested), "nested-shell guard retains entry without PTY injection")
        session.promptQueue.remove(at: 0)

        try layoutAndSettings(session, window: window)
        settings.promptQueueAutoDispatch = true
        session.promptQueue.enqueue("never run after close")
        session.schedulePromptQueueDispatch()
        session.terminate()
        try check(session.promptQueueDispatchTask == nil, "teardown cancels the pending settle window")
        print("Prompt queue \(backend): \(checks) native settings, queue and real PTY checks passed")
    }

    private static func layoutAndSettings(_ session: TerminalSession, window: NSWindow) throws {
        let pane = SettingsTerminalPane()
        pane.setCategory(.terminal)
        let settingsWindow = makeWindow("queue-settings-layout-fixture")
        settingsWindow.contentViewController = pane
        settingsWindow.makeKeyAndOrderFront(nil)
        defer { settingsWindow.contentViewController = nil; settingsWindow.close() }
        session.promptQueue.present()
        session.promptQueue.enqueue("Unicode preview 你好 العربية 👩🏽‍💻 café — " + String(repeating: "queue ", count: 30))
        for language in AppLanguage.allCases where language != .system {
            AppSettings.shared.language = language
            let localizedPane = SettingsTerminalPane()
            localizedPane.setCategory(.terminal)
            settingsWindow.contentViewController = localizedPane
            for width in [320.0, 480, 900, 320] {
                window.setContentSize(NSSize(width: width, height: 520))
                window.contentView?.layoutSubtreeIfNeeded()
                session.promptQueueBar.layoutSubtreeIfNeeded()
                pump(0.015)
                for id in ["prompt-queue-add", "prompt-queue-send-0", "prompt-queue-remove-0"] {
                    let control = try button(id, in: session.promptQueueBar)
                    let rect = control.convert(control.bounds, to: session.promptQueueBar)
                    try check(rect.minX >= -1 && rect.maxX <= session.promptQueueBar.bounds.maxX + 1,
                              "\(language.rawValue) queue action fits at \(width) points")
                    try check(control.accessibilityLabel()?.isEmpty == false && control.toolTip?.isEmpty == false,
                              "\(language.rawValue) compact queue action has a name and tooltip")
                }
            }
            for width in [480.0, 660] {
                settingsWindow.setContentSize(NSSize(width: width, height: 560))
                localizedPane.view.layoutSubtreeIfNeeded()
                let title = String(localized: "Enable Prompt Queue")
                guard let toggle = descendants(localizedPane.view).compactMap({ $0 as? NSSwitch })
                    .first(where: { $0.accessibilityLabel() == title }) else { throw PromptQueueFailure.failed("queue settings toggle missing") }
                try check(toggle.isEnabled && localizedPane.revealSearchResult(title, in: String(localized: "Prompt Queue")),
                          "\(language.rawValue) queue settings are searchable and actionable")
                let labels = descendants(localizedPane.view).compactMap { $0 as? NSTextField }.filter {
                    !$0.isEditable && !$0.isHidden && $0.maximumNumberOfLines == 0
                }
                try check(labels.allSatisfy { $0.frame.height + 1 >= $0.cell!.cellSize(forBounds:
                    NSRect(x: 0, y: 0, width: $0.frame.width, height: 10_000)).height },
                    "\(language.rawValue) settings labels wrap without clipping at \(width) points")
            }
        }
        AppSettings.shared.language = .english
        session.promptQueue.remove(at: 0)
        AppSettings.shared.promptQueueEnabled = false
        pane.syncFromSettings()
        let automatic = descendants(pane.view).compactMap { $0 as? NSSwitch }
            .first { $0.accessibilityLabel() == String(localized: "Send queued prompts automatically") }
        try check(automatic?.isEnabled == false, "automatic settings control is disabled with the master switch")
        AppSettings.shared.promptQueueEnabled = true
    }

    private static func bufferedReservation(session: TerminalSession, root: URL, window: NSWindow) throws {
        let armed = root.appendingPathComponent("reservation-armed")
        let paused = root.appendingPathComponent("reservation-paused")
        let release = root.appendingPathComponent("reservation-release")
        let started = root.appendingPathComponent("reservation-started")
        let answer = root.appendingPathComponent("reservation-answer")
        let order = root.appendingPathComponent("reservation-order")
        let setup = """
        _queue_change_keymap() { zle -K viins; }; zle -N _queue_change_keymap; bindkey '^X' _queue_change_keymap;
        _queue_hold_redraw() { if [[ -f \(quote(armed.path)) ]]; then /bin/rm -f -- \(quote(armed.path));
        builtin print paused >| \(quote(paused.path)); while [[ ! -f \(quote(release.path)) ]]; do :; done; fi; };
        add-zle-hook-widget line-pre-redraw _queue_hold_redraw
        """.replacingOccurrences(of: "\n", with: " ")
        session.sendCommand(setup)
        session.sendEnter()
        try wait("reservation fixture installs real ZLE keymap and redraw hooks") { session.canSendQueuedPrompt }
        pump(0.1)
        try Data().write(to: armed)
        control("\u{18}", in: session)
        try wait("redraw is held before the shell consumes queued input") { exists(paused) }
        defer { try? Data().write(to: release) }
        session.promptQueue.enqueue("builtin print started >| " + quote(started.path)
            + "; read -r answer; builtin print -rn -- \"$answer\" >| " + quote(answer.path))
        session.promptQueue.enqueue("printf second >> " + quote(order.path))
        AppSettings.shared.promptQueueAutoDispatch = true
        session.schedulePromptQueueDispatch()
        try check(session.sendQueuedPrompt(at: 0), "manual send reserves an input while redraw delays consumption")
        try check(!session.canSendQueuedPrompt && !session.sendQueuedPrompt(at: 0),
                  "redraw cannot release the command reservation before PTY input is consumed")
        session.terminalDidReportShellIntegration(.promptStart)
        session.schedulePromptQueueDispatch()
        pump(0.35)
        try check(!exists(started) && !exists(order) && session.promptQueue.commands.count == 1,
                  "automatic retries retain the second entry while the first command is still buffered")
        try Data().write(to: release)
        try wait("first buffered command owns shell input through builtin read") { exists(started) }
        try check(!session.canSendQueuedPrompt && !session.sendQueuedPrompt(at: 0),
                  "matching submission does not complete the reservation before its command finishes")
        session.promptQueueBar.setPaneVisible(false)
        session.surface.setSurfaceVisible(false)
        control("deliberate answer\r", in: session)
        try wait("hidden pane publishes the completed acknowledgement without renderer callbacks") {
            read(answer) == "deliberate answer" && session.canSendQueuedPrompt
        }
        try check(!exists(order) && session.promptQueue.commands.count == 1,
                  "the foreground read receives deliberate input and preserves the next queued command")
        session.surface.setSurfaceVisible(true)
        session.promptQueueBar.setPaneVisible(true)
        window.makeFirstResponder(session.surface)
        try check(session.sendQueuedPrompt(at: 0), "Send Now works with automatic sending enabled after completion")
        try wait("next command runs exactly once after remount") { read(order) == "second" && session.canSendQueuedPrompt }
        AppSettings.shared.promptQueueAutoDispatch = false
        for command in [":", "false", "true"] {
            session.promptQueue.enqueue(command)
            try check(session.sendQueuedPrompt(at: 0), "fast command reserves its own submission")
            try wait("fast command returns its own completed empty-prompt acknowledgement") { session.canSendQueuedPrompt }
        }
    }

    private static func makeWindow(_ identifier: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        return window
    }

    private static func mount(_ session: TerminalSession, in window: NSWindow) {
        let container = TerminalContainerView()
        container.mount(session.surface, scrollbar: session.overlayScrollbar, queueBar: session.promptQueueBar)
        session.promptQueueBar.onLayoutChange = { [weak container] in container?.layoutSubtreeIfNeeded() }
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(session.surface)
        session.surface.setSurfaceVisible(true)
        container.layoutSubtreeIfNeeded()
    }

    private static func input(in session: TerminalSession) throws -> NSTextField {
        guard let field = descendants(session.promptQueueBar).first(where: {
            $0.identifier?.rawValue == "prompt-queue-input"
        }) as? NSTextField else { throw PromptQueueFailure.failed("queue composer missing") }
        return field
    }

    private static func button(_ id: String, in root: NSView) throws -> NSButton {
        guard let control = descendants(root).first(where: { $0.identifier?.rawValue == id }) as? NSButton else {
            throw PromptQueueFailure.failed("queue action missing: \(id)")
        }
        return control
    }

    private static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func control(_ text: String, in session: TerminalSession) {
        if let ghostty = session.surface as? ZshellTerminalView {
            ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
        } else { session.surface.sendText(text) }
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw PromptQueueFailure.failed(message) }
    }
    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
    private static func wait(_ message: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { pump(0.015) }
        try check(condition(), message)
    }
}
