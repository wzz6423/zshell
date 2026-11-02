import AppKit
import Foundation
@testable import zshell

private enum HistorySurfaceFailure: Error { case failed(String) }

@main
@MainActor
struct TerminalCommandHistorySurfaceTests {
    private static var checks = 0

    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let backend = CommandLine.arguments[2]
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard ["/tmp/zshell-command-history-tests-", "/private/tmp/zshell-command-history-tests-"]
            .contains(where: home.path.hasPrefix) else {
            throw HistorySurfaceFailure.failed("surface acceptance requires a disposable HOME")
        }
        let draft = root.appendingPathComponent("draft.txt")
        try """
        HISTFILE=/dev/null
        unsetopt SHARE_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME APPEND_HISTORY
        bindkey -e
        PROMPT='HISTORY_READY> '
        RPROMPT=''
        PS2=''
        _history_dump_draft() { builtin print -rn -- "$BUFFER" >| \(quote(draft.path)); }
        zle -N _history_dump_draft
        bindkey '^T' _history_dump_draft
        _history_reset_draft() { BUFFER=''; CURSOR=0; }
        zle -N _history_reset_draft
        bindkey '^R' _history_reset_draft
        """.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        AppSettings.shared.language = .english
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.restoreTerminalHistory = false
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.resumeAgentConversations = false
        AppSettings.shared.notifyOnError = false
        AppSettings.shared.copyOnSelect = false
        let store = TerminalCommandHistoryStore.shared
        try wait("saved history is ready") { !store.isLoading }
        store.clear()
        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let project = Project(fallbackName: "Command history fixture", manager: manager, createInitialSession: false)
        project.customDirectory = root.path
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main-command-history-surface-fixture")
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        guard let session = project.newSession(directory: root.path) else {
            throw HistorySurfaceFailure.failed("could not create fixture shell")
        }
        mount(session, in: window)
        let controller = TerminalCommandHistoryController(store: store)
        defer {
            controller.close(restoreFocus: false)
            manager.windowClosed()
            pump(0.5)
            window.contentView = nil
            window.close()
            store.flush()
        }
        try wait("root zsh reaches an empty prompt") { session.isShellAvailableForAutomation && session.terminalPromptQueueIsReady }

        let previousHistory = store.entries
        let previousCommands = Set(session.commandRecords.map(\.id))
        AppSettings.shared.commandHistoryEnabled = false
        send("printf 'UNRECORDED_COMMAND\\n'", to: session)
        session.sendEnter()
        try wait("disabled history still reports command blocks") {
            session.commandRecords.contains { !previousCommands.contains($0.id) && $0.finishedAt != nil }
                && session.terminalPromptQueueIsReady
        }
        try check(store.entries == previousHistory, "disabled command history does not persist new records")
        AppSettings.shared.commandHistoryEnabled = true

        func text() -> String { session.surface.readVisibleText(maxLines: 250, maxColumns: 1_000) ?? "" }
        func run(_ command: String) throws -> TerminalCommandHistoryEntry {
            try wait("shell accepts \(command.prefix(50))") { session.terminalPromptQueueIsReady }
            let existing = Set(store.entries.map(\.id))
            let before = Date()
            send(command, to: session)
            session.sendEnter()
            do {
                try wait("executed command metadata arrives") {
                    store.entries.contains { $0.terminalID == session.id && !existing.contains($0.id) && $0.finishedAt != nil }
                        && session.terminalPromptQueueIsReady
                }
            } catch {
                print("DIAGNOSTIC lifecycle=\(session.commandLifecycle) ready=\(session.terminalPromptQueueIsReady) records=\(session.commandRecords) history=\(store.entries)")
                print("DIAGNOSTIC visible output:\n\(text())")
                throw error
            }
            guard let entry = store.entries.first(where: { $0.terminalID == session.id && !existing.contains($0.id) }) else {
                throw HistorySurfaceFailure.failed("command record missing")
            }
            if entry.command != command {
                print("DIAGNOSTIC expected=\(String(reflecting: command)) actual=\(String(reflecting: entry.command))")
            }
            try check(entry.command == command, "\(backend) preserves exact executed command text")
            try check(entry.startedAt >= before.addingTimeInterval(-1) && entry.startedAt <= Date(),
                      "\(backend) records the actual start time")
            try check(entry.finishedAt.map { $0 >= entry.startedAt } == true, "\(backend) records completion after start")
            try check(session.commandRecords.contains { $0.id == entry.id }, "\(backend) history reuses the command block's stable identity")
            return entry
        }

        let successCommand = "printf 'HISTORY_SUCCESS_你好 👩🏽‍💻\\n'"
        let success = try run(successCommand)
        try check(success.exitCode == 0 && success.durationNanos != nil, "\(backend) success records exit zero and duration")
        try check(sameDirectory(success.workingDirectory, root.path), "\(backend) captures the execution directory")
        let failure = try run("/bin/sh -c 'exit 7'")
        try check(failure.exitCode == 7, "\(backend) captures the actual failing exit status")
        let slow = try run("/bin/sleep 0.3")
        try check((slow.durationNanos ?? 0) >= 250_000_000 && (slow.durationNanos ?? .max) < 10_000_000_000,
                  "\(backend) elapsed duration includes the real foreground sleep")
        let changed = root.appendingPathComponent("目录 café", isDirectory: true)
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: false)
        let cd = try run("cd -- " + quote(changed.path))
        try check(sameDirectory(cd.workingDirectory, root.path), "\(backend) cd retains its starting directory")
        let afterCD = try run("printf 'AFTER_DIRECTORY_CHANGE\\n'")
        try check(sameDirectory(afterCD.workingDirectory, changed.path), "\(backend) the next command uses the new directory")
        let multilineCommand = "printf 'MULTILINE_你好 👩🏽‍💻\\n'\nprintf 'SECOND_LINE_終わり\\n'"
        let multiline = try run(multilineCommand)
        try check(multiline.command.contains("\n") && multiline.command.contains("👩🏽‍💻"),
                  "\(backend) multiline Unicode survives PTY capture")
        guard let multilineLocation = session.commandRecords.first(where: { $0.id == multiline.id })?.outputLocation else {
            throw HistorySurfaceFailure.failed("multiline output token missing")
        }
        let originalOutput = session.surface.commandText(at: multilineLocation, part: .output) ?? ""
        print("DIAGNOSTIC \(backend) multiline region=\(String(describing: session.surface.commandRegion(at: multilineLocation))) output=\(String(reflecting: originalOutput))")
        try check(originalOutput.contains("MULTILINE_你好 👩🏽‍💻") && originalOutput.contains("SECOND_LINE_終わり"),
                  "\(backend) the history ID resolves both lines of its actual command output")
        let repeated = try run(successCommand)
        try check(repeated.id != success.id, "\(backend) identical commands retain separate execution IDs")
        store.flush()
        let historyURL = home.appendingPathComponent("Library/Application Support/zshell-dev/command-history/records.json")
        let reloaded = TerminalCommandHistoryStore(url: historyURL)
        try wait("real PTY history reloads") { !reloaded.isLoading }
        try check(reloaded.entries.first(where: { $0.id == multiline.id }) == multiline,
                  "\(backend) real command metadata persists without output coordinates")

        _ = try run("for item in {1..100}; do printf 'HISTORY_FILL_%s\\n' \"$item\"; done")
        try check(TerminalCommandHistoryActions.canReveal(multiline), "\(backend) original output has a live navigation token")
        try check(TerminalCommandHistoryActions.reveal(multiline), "\(backend) history reveals the original command output")
        try wait("original output becomes visible") { text().contains("MULTILINE_你好") }
        for size in [NSSize(width: 520, height: 440), NSSize(width: 980, height: 620)] {
            window.setContentSize(size)
            session.surface.frame = window.contentView!.bounds
            pump(0.15)
            try check(TerminalCommandHistoryActions.reveal(multiline), "\(backend) output token survives resize and reflow")
            try wait("reflow still resolves the same output") { text().contains("MULTILINE_你好") }
        }

        guard let other = project.newSession(directory: root.path) else {
            throw HistorySurfaceFailure.failed("second pane creation failed")
        }
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        mount(other, in: otherWindow)
        defer { otherWindow.contentView = nil; otherWindow.close() }
        try check(project.selectedSession?.id == other.id, "\(backend) navigation starts from a different pane")
        try check(TerminalCommandHistoryActions.reveal(multiline), "\(backend) navigation selects the original pane")
        pump(0.1)
        try check(project.selectedSession?.id == session.id && window.firstResponder === session.surface,
                  "\(backend) original pane and terminal responder regain focus")
        session.surface.scroll(toFraction: 1)
        try wait("empty prompt can receive history input") { TerminalCommandHistoryActions.canInsert(multiline) }
        let count = store.entries.count
        try check(TerminalCommandHistoryActions.insert(multiline), "\(backend) history fills the original prompt")
        pump(0.25)
        control("\u{14}", in: session)
        try wait("zsh exposes the inserted draft") { (try? String(contentsOf: draft, encoding: .utf8)) == multilineCommand }
        try check(store.entries.count == count && session.commandLifecycle.phase != .executing,
                  "\(backend) insertion preserves multiple lines without executing")
        try check(!TerminalCommandHistoryActions.canInsert(multiline), "\(backend) an existing draft disables reinsertion")
        controller.show(for: manager)
        guard let panel = window.childWindows?.first(where: { $0.identifier?.rawValue == "terminal-command-history" }),
              let content = panel.contentView,
              let search = view("command-history-search", in: content) as? NSSearchField,
              let table = view("command-history-list", in: content) as? NSTableView else {
            throw HistorySurfaceFailure.failed("history panel missing")
        }
        search.stringValue = "MULTILINE_你好"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try check(table.numberOfRows == 1, "\(backend) the real command is searchable in AppKit")
        try check((view("command-history-insert", in: content) as? NSButton)?.isEnabled == false,
                  "\(backend) the panel refuses to overwrite a live draft")
        controller.close()
        pump(0.1)
        print("DIAGNOSTIC reset responder=\(String(describing: window.firstResponder)) phase=\(session.commandLifecycle.phase) ready=\(session.terminalPromptQueueIsReady)")
        control("\u{12}", in: session)
        control("\u{14}", in: session)
        pump(0.3)
        print("DIAGNOSTIC reset buffer=\(String(reflecting: (try? String(contentsOf: draft, encoding: .utf8)) ?? "<missing>")) phase=\(session.commandLifecycle.phase) ready=\(session.terminalPromptQueueIsReady) available=\(session.isShellAvailableForAutomation)")
        try wait("draft reset restores insertion eligibility") { TerminalCommandHistoryActions.canInsert(multiline) }
        session.promptQueue.enqueue("echo queued")
        try check(!TerminalCommandHistoryActions.canInsert(multiline), "\(backend) history does not race queued commands")
        session.promptQueue.remove(at: 0)

        let beforeRunning = Set(store.entries.map(\.id))
        send("/bin/sleep 0.6", to: session)
        session.sendEnter()
        try wait("a running command enters history") {
            store.entries.contains { $0.terminalID == session.id && !beforeRunning.contains($0.id) && $0.finishedAt == nil }
        }
        guard let running = store.entries.first(where: { !beforeRunning.contains($0.id) && $0.terminalID == session.id }) else {
            throw HistorySurfaceFailure.failed("running command missing")
        }
        try check(!TerminalCommandHistoryActions.canInsert(multiline), "\(backend) a foreground command disables history insertion")
        store.delete(id: running.id)
        try wait("deleted running command finishes") { session.terminalPromptQueueIsReady }
        try check(!store.entries.contains { $0.id == running.id }, "\(backend) completion cannot resurrect a deleted command")

        let beforeClear = Set(store.entries.map(\.id))
        send("/bin/sleep 0.6", to: session)
        session.sendEnter()
        try wait("another running command is recorded") {
            store.entries.contains { $0.terminalID == session.id && !beforeClear.contains($0.id) && $0.finishedAt == nil }
        }
        store.clear()
        try wait("cleared running command finishes") { session.terminalPromptQueueIsReady }
        try check(store.entries.isEmpty, "\(backend) completion after clear cannot recreate old history")
        let remaining = try run("printf 'HISTORY_AFTER_CLEAR\\n'")
        try check(store.entries.map(\.id) == [remaining.id], "\(backend) new executions appear after clear")
        session.clear()
        pump(0.2)
        try check(!TerminalCommandHistoryActions.canReveal(remaining) && !TerminalCommandHistoryActions.reveal(remaining),
                  "\(backend) cleared output cannot jump to another command")
        try check(store.entries.map(\.id) == [remaining.id], "\(backend) clearing output retains saved command text")

        guard let originTab = project.tabs.first(where: { $0.sessions.contains(where: { $0.id == session.id }) }) else {
            throw HistorySurfaceFailure.failed("original tab missing")
        }
        project.close(originTab)
        try wait("original pane closes") { session.hasExited }
        try check(!TerminalCommandHistoryActions.canReveal(remaining) && !TerminalCommandHistoryActions.canInsert(remaining)
                  && !TerminalCommandHistoryActions.isRunning(remaining), "\(backend) closed panes are unavailable and never reported running")
        controller.show(for: manager)
        search.stringValue = "HISTORY_AFTER_CLEAR"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try check(table.numberOfRows == 1 && (view("command-history-copy", in: content) as? NSButton)?.isEnabled == true,
                  "\(backend) closed-pane history remains searchable and copyable")
        store.flush()
        print("Command history \(backend) surfaces: \(checks) checks passed")
    }

    private static func mount(_ session: TerminalSession, in window: NSWindow) {
        window.contentView = session.surface
        session.surface.frame = NSRect(x: 0, y: 0, width: window.frame.width, height: window.frame.height - 28)
        session.surface.onBecomeFirstResponder = { [weak session] in session?.terminalDidBecomeFocused() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(session.surface)
        session.surface.setSurfaceVisible(true)
    }

    private static func send(_ command: String, to session: TerminalSession) {
        session.sendCommand(command, asPaste: true)
    }

    private static func control(_ text: String, in session: TerminalSession) {
        if let ghostty = session.surface as? ZshellTerminalView {
            ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
        } else { session.surface.sendText(text) }
    }

    private static func sameDirectory(_ left: String, _ right: String) -> Bool {
        guard left.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: left).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: right).resolvingSymlinksInPath().path
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func view(_ id: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == id { return root }
        return root.subviews.lazy.compactMap { view(id, in: $0) }.first
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw HistorySurfaceFailure.failed(message) }
        checks += 1
        print("PASS \(message)")
    }

    private static func wait(_ message: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { pump(0.02) }
        try check(condition(), message)
    }

    private static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }
}
