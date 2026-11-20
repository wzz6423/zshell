import AppKit
import GhosttyKit
@testable import GhosttyTerminal
@testable import zshell

private enum CommandBlockFailure: Error { case failed(String) }

@main
@MainActor
struct TerminalCommandBlockSurfaceTests {
    private static var checks = 0
    private static var backend = ""

    static func main() {
        do { try run() }
        catch { fputs("Command block surface failed: \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        backend = CommandLine.arguments[2]
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard ["/tmp/zshell-command-block-tests-", "/private/tmp/zshell-command-block-tests-"]
            .contains(where: home.path.hasPrefix) else {
            throw CommandBlockFailure.failed("surface tests require a disposable HOME")
        }
        let draft = root.appendingPathComponent("draft.txt")
        try """
        HISTFILE=/dev/null
        unsetopt SHARE_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME APPEND_HISTORY
        bindkey -e
        PROMPT='BLOCK_READY> '
        RPROMPT=''
        PS2=''
        _block_dump_draft() { builtin print -rn -- "$BUFFER" >| \(quote(draft.path)); }
        zle -N _block_dump_draft
        bindkey '^T' _block_dump_draft
        _block_reset_draft() { BUFFER=''; CURSOR=0; }
        zle -N _block_reset_draft
        bindkey '^R' _block_reset_draft
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
        if backend == "ghostty" { try verifyGhosttyCommandCallbacks(directory: root.path) }
        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let project = Project(fallbackName: "Command block fixture", manager: manager, createInitialSession: false)
        project.customDirectory = root.path
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        guard let session = project.newSession(directory: root.path) else {
            throw CommandBlockFailure.failed("could not create fixture shell")
        }
        let surface = session.surface
        window.contentView = surface
        surface.frame = window.contentView!.bounds
        surface.onBecomeFirstResponder = { [weak session] in session?.terminalDidBecomeFocused() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surface)
        surface.setSurfaceVisible(true)
        let clipboard = NSPasteboard.general
        let savedClipboard = (clipboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        var ownedClipboardCount = clipboard.changeCount
        defer {
            if clipboard.changeCount == ownedClipboardCount {
                clipboard.clearContents()
                clipboard.writeObjects(savedClipboard.map { entries in
                    let item = NSPasteboardItem()
                    for (type, data) in entries { item.setData(data, forType: type) }
                    return item
                })
            }
            manager.windowClosed()
            pump(0.3)
            window.contentView = nil
            window.close()
        }
        func visible() -> String { surface.readVisibleText(maxLines: 500, maxColumns: 2_000) ?? "" }
        func seedClipboard() {
            clipboard.clearContents()
            clipboard.setString("COMMAND_BLOCK_SENTINEL", forType: .string)
            ownedClipboardCount = clipboard.changeCount
        }
        func invoke(_ item: NSMenuItem) throws {
            guard let action = item.action else { throw CommandBlockFailure.failed("menu action missing") }
            try check(NSApp.sendAction(action, to: item.target, from: item), "native menu action dispatches")
            ownedClipboardCount = clipboard.changeCount
        }
        func run(_ command: String) throws -> TerminalCommandRecord {
            try wait("empty shell accepts fixture command") { session.terminalPromptQueueIsReady }
            let existing = Set(session.commandRecords.map(\.id))
            session.sendCommand(command, asPaste: true)
            session.sendEnter()
            try wait("command finishes with semantic metadata") {
                session.terminalPromptQueueIsReady && session.commandRecords.contains {
                    !existing.contains($0.id) && $0.finishedAt != nil
                }
            }
            guard let record = session.commandRecords.first(where: { !existing.contains($0.id) }) else {
                throw CommandBlockFailure.failed("command metadata missing")
            }
            try check(record.command == command, "command metadata preserves exact input")
            return record
        }
        func event(row: Int, column: Int = 2, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .rightMouseDown) throws -> NSEvent {
            guard let snapshot = surface.readVisibleSnapshot() else { throw CommandBlockFailure.failed("viewport missing") }
            let top = snapshot.origin.y + (CGFloat(row) + 0.5) * snapshot.cellSize.height
            let point = NSPoint(x: snapshot.origin.x + (CGFloat(column) + 0.25) * snapshot.cellSize.width,
                                y: surface.isFlipped ? top : surface.bounds.height - top)
            return NSEvent.mouseEvent(with: type, location: surface.convert(point, to: nil), modifierFlags: flags,
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func menu(for record: TerminalCommandRecord) throws -> NSMenu {
            guard let location = record.outputLocation, surface.revealCommand(at: location) else {
                throw CommandBlockFailure.failed("block cannot be revealed")
            }
            pump(0.08)
            guard let snapshot = surface.readVisibleSnapshot() else { throw CommandBlockFailure.failed("viewport missing") }
            for row in snapshot.rows.indices {
                let click = try event(row: row)
                if surface.commandLocation(for: click) == location, let menu = surface.menu(for: click) {
                    let line = snapshot.rows[row].text
                    try check(!line.trimmingCharacters(in: .whitespaces).isEmpty,
                              "clicked block token belongs to a populated visible row")
                    return menu
                }
            }
            print("DIAGNOSTIC missing click location=\(location) region=\(String(describing: surface.commandRegion(at: location)))")
            print("DIAGNOSTIC viewport=\(String(reflecting: visible()))")
            print("DIAGNOSTIC row IDs=\(try snapshot.rows.indices.map { surface.commandLocation(for: try event(row: $0))?.blockID ?? 0 })")
            throw CommandBlockFailure.failed("revealed block has no clickable row")
        }
        func hit(_ needle: String, in record: TerminalCommandRecord) throws {
            guard let snapshot = surface.readVisibleSnapshot(), let location = record.outputLocation else {
                throw CommandBlockFailure.failed("hit-test viewport or token missing")
            }
            let matches = snapshot.rows.indices.filter { snapshot.rows[$0].text.contains(needle) }
            try check(!matches.isEmpty, "expected command text is visible for hit testing")
            for row in matches {
                let line = snapshot.rows[row]
                let range = (line.text as NSString).range(of: needle)
                guard let columns = line.columns(for: range) else { throw CommandBlockFailure.failed("text cells missing") }
                let click = try event(row: row, column: columns.lowerBound)
                try check(surface.commandLocation(for: click) == location,
                          "visible \(needle) row hits its exact block on \(window.backingScaleFactor)x display")
            }
        }
        func item(_ identifier: String, in menu: NSMenu) throws -> NSMenuItem {
            guard let item = menu.items.first(where: { $0.identifier?.rawValue == identifier }) else {
                throw CommandBlockFailure.failed("missing menu item: " + identifier)
            }
            return item
        }
        func validate(_ item: NSMenuItem) -> Bool {
            (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? false
        }
        func dumpDraft() throws -> String {
            try? FileManager.default.removeItem(at: draft)
            control("\u{14}", in: session)
            try wait("zsh reports its actual edit buffer") { FileManager.default.fileExists(atPath: draft.path) }
            return try String(contentsOf: draft, encoding: .utf8)
        }

        try wait("native zsh reaches ready empty prompt") { session.isShellAvailableForAutomation && session.terminalPromptQueueIsReady }
        let keyboard = TerminalContextMenu.make(for: surface, linkTarget: nil)
        try check(keyboard.items.prefix(3).map(\.title) == ["Copy", "Paste", "Select All"]
                  && !keyboard.items.contains { $0.identifier?.rawValue == "zshell-copy-command" },
                  "keyboard menu retains general actions without guessing the last block")
        let initial = try event(row: 0)
        try check(surface.commandLocation(for: initial) == nil && surface.menu(for: initial)?.items.contains {
            $0.identifier?.rawValue == "zshell-copy-command"
        } == false, "unknown prompt does not expose block actions")

        let first = try run("printf 'FIRST_你好 👩🏽‍💻\\nSECOND_終わり\\n'")
        let second = try run("printf 'ADJACENT_BLOCK\\n'")
        let firstMenu = try menu(for: first)
        try hit("FIRST_你好", in: first)
        try hit("SECOND_終わり", in: first)
        try hit("ADJACENT_BLOCK", in: second)
        let firstCommand = try item("zshell-copy-command", in: firstMenu)
        try invoke(firstCommand)
        try check(clipboard.string(forType: .string) == first.command, "adjacent block copy uses the clicked command")
        let firstOutput = try item("zshell-copy-command-output", in: firstMenu)
        try invoke(firstOutput)
        let output = clipboard.string(forType: .string) ?? ""
        try check(output.contains("FIRST_你好 👩🏽‍💻\nSECOND_終わり") && !output.contains("ADJACENT_BLOCK")
                  && !output.contains("BLOCK_READY>"), "output preserves Unicode and excludes the prompt and adjacent block")
        try invoke(try item("zshell-copy-command-block", in: firstMenu))
        let block = clipboard.string(forType: .string) ?? ""
        // Whole-block copy reads the visible grid; ZLE may escape non-printing
        // input characters while command-only copy preserves the shell source.
        if !block.contains("BLOCK_READY> printf 'FIRST_你好") || !block.contains(output) {
            print("DIAGNOSTIC block=\(String(reflecting: block)) output=\(String(reflecting: output))")
        }
        try check(block.contains("BLOCK_READY> printf 'FIRST_你好") && block.contains("\\nSECOND_終わり\\n'")
                  && block.contains(output) && !block.contains("ADJACENT_BLOCK"),
                  "whole-block copy includes prompt, visible input and only its full output")
        try invoke(try item("zshell-select-command-output", in: firstMenu))
        try check(surface.hasSelection, "Select Command Output creates a real terminal selection")
        let genericCopy = firstMenu.items[0]
        try invoke(genericCopy)
        try check(clipboard.string(forType: .string)?.contains("FIRST_你好") == true
                  && clipboard.string(forType: .string)?.contains("BLOCK_READY>") == false,
                  "selected text is exactly the command output")
        try invoke(try item("zshell-copy-command", in: menu(for: second)))
        try check(clipboard.string(forType: .string) == second.command, "the next block has its own command target")

        let empty = try run(":")
        let emptyMenu = try menu(for: empty)
        try check(!(try item("zshell-copy-command-output", in: emptyMenu)).isEnabled
                  && !(try item("zshell-select-command-output", in: emptyMenu)).isEnabled,
                  "empty output disables copy and selection without inventing content")
        seedClipboard()
        try invoke(try item("zshell-copy-command-output", in: emptyMenu))
        try check(clipboard.string(forType: .string) == "COMMAND_BLOCK_SENTINEL", "empty-output action preserves the clipboard")

        let multilineText = "printf 'MULTILINE_你好\\n'\nprintf 'CONTINUATION_👩🏽‍💻\\n'"
        let multiline = try run(multilineText)
        let multilineMenu = try menu(for: multiline)
        try invoke(try item("zshell-copy-command", in: multilineMenu))
        try check(clipboard.string(forType: .string) == multilineText, "multiline command copy preserves the original newlines")
        let longText = String(repeating: "長é", count: 170)
        let long = try run("printf '%s\\n' '" + longText + "'")
        let longMenu = try menu(for: long)
        try invoke(try item("zshell-copy-command-output", in: longMenu))
        try check((clipboard.string(forType: .string) ?? "").contains(longText), "soft-wrapped long Unicode output copies as one logical line")
        window.setContentSize(NSSize(width: 520, height: 440))
        pump(0.2)
        try invoke(try item("zshell-copy-command", in: longMenu))
        try check(clipboard.string(forType: .string) == long.command, "an open menu token survives resize and reflow")
        window.setContentSize(NSSize(width: 900, height: 520))
        pump(0.1)

        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            let localized = try menu(for: multiline)
            try check(try item("zshell-copy-command", in: localized).title == String(localized: "Copy Command")
                      && item("zshell-copy-command-output", in: localized).title == String(localized: "Copy Output")
                      && item("zshell-copy-command-block", in: localized).title == String(localized: "Copy Command Block")
                      && item("zshell-select-command-output", in: localized).title == String(localized: "Select Command Output")
                      && item("zshell-insert-command", in: localized).title == String(localized: "Insert at Prompt"),
                      "\(language.rawValue) command-block menu uses the compiled translations")
        }
        AppLocalization.apply(.english)
        let insertMenu = try menu(for: multiline)
        let insert = try item("zshell-insert-command", in: insertMenu)
        try check(validate(insert), "ready empty zsh permits insertion while saved history is disabled")
        try invoke(insert)
        try check(try dumpDraft() == multilineText && session.commandLifecycle.phase != .executing,
                  "insertion preserves multiline input without submitting Enter")
        try check(!validate(insert), "an existing draft disables a retained insertion item")
        try invoke(insert)
        try check(try dumpDraft() == multilineText, "stale insertion cannot overwrite or append to a draft")
        control("\u{12}", in: session)
        try wait("reset buffer restores prompt readiness") { session.terminalPromptQueueIsReady }
        session.promptQueue.enqueue("echo queued")
        try check(!validate(insert), "queued input disables insertion")
        try invoke(insert)
        try check(try dumpDraft().isEmpty, "insertion sends no input while a queue owns the prompt")
        session.promptQueue.remove(at: 0)

        let existing = Set(session.commandRecords.map(\.id))
        session.sendCommand("printf 'STREAM_BEFORE\\n'; /bin/sleep 1.5; printf 'STREAM_AFTER\\n'", asPaste: true)
        session.sendEnter()
        try wait("streaming output starts") {
            visible().contains("\nSTREAM_BEFORE") && session.commandRecords.contains { !existing.contains($0.id) }
        }
        let streaming = session.commandRecords.first { !existing.contains($0.id) }!
        let streamMenu = try menu(for: streaming)
        let streamOutput = try item("zshell-copy-command-output", in: streamMenu)
        try check(!validate(insert), "a foreground command disables retained insertion")
        try check(streamMenu.items.contains { $0.identifier?.rawValue == "zshell-insert-command" } == false,
                  "a running command does not offer prompt insertion")
        try wait("streaming output finishes") { session.terminalPromptQueueIsReady }
        try invoke(streamOutput)
        try check(clipboard.string(forType: .string)?.contains("STREAM_AFTER") == true,
                  "a retained menu reads current output from its original block")
        try invoke(firstCommand)
        try check(clipboard.string(forType: .string) == first.command, "later output does not retarget an earlier menu")

        session.sendCommand("printf '\\033[?1049hALTERNATE_READY'; /bin/sleep 0.6; printf '\\033[?1049l'", asPaste: true)
        session.sendEnter()
        try wait("fixture enters alternate screen") { visible().contains("ALTERNATE_READY") }
        seedClipboard()
        try check(!validate(firstCommand), "alternate screen invalidates retained block actions")
        try invoke(firstCommand)
        try check(clipboard.string(forType: .string) == "COMMAND_BLOCK_SENTINEL", "alternate screen never copies an old shell block")
        let alternateMenu = surface.menu(for: try event(row: 0))
        try check(alternateMenu?.items.contains { $0.identifier?.rawValue == "zshell-copy-command" } == false,
                  "alternate-screen right-click has no shell block actions")
        try wait("fixture returns from alternate screen") { session.terminalPromptQueueIsReady }

        _ = try run("for item in {1..11000}; do printf 'CLIP_%s\\n' \"$item\"; done")
        try check(!validate(firstCommand), "scrollback clipping invalidates the original opaque token")
        seedClipboard()
        try invoke(firstCommand)
        try check(clipboard.string(forType: .string) == "COMMAND_BLOCK_SENTINEL", "a clipped menu never copies a replacement block")
        surface.scroll(toFraction: 1)
        pump(0.05)

        let compilerOutput = root.appendingPathComponent("compiler-output.py")
        try """
        import pathlib
        import sys
        import time
        proceed = pathlib.Path(sys.argv[1]) / 'compiler-continue'
        for batch in range(32):
            for line in range(128):
                print(f'SwiftCompile normal arm64 /tmp/Source{batch * 128 + line}.swift '
                      + '-I /tmp/Products/Debug/include ' * 6)
            print(f'COMPILER_OUTPUT_{batch}', flush=True)
            if batch == 0:
                while not proceed.exists():
                    time.sleep(0.005)
            time.sleep(0.02)
        print('COMPILER_FINISHED', flush=True)
        """.write(to: compilerOutput, atomically: true, encoding: .utf8)
        var lastPulse = ProcessInfo.processInfo.systemUptime
        var maximumGap: TimeInterval = 0
        let heartbeat = Timer(timeInterval: 0.01, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            maximumGap = max(maximumGap, now - lastPulse)
            lastPulse = now
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        defer { heartbeat.invalidate() }
        let sequence = session.commandLifecycle.completionSequence
        session.sendCommand("/usr/bin/python3 " + quote(compilerOutput.path) + " " + quote(root.path), asPaste: true)
        session.sendEnter()
        try wait("compiler output reaches the viewport while the command is running") {
            visible().contains("COMPILER_OUTPUT_0") && session.commandLifecycle.completionSequence == sequence
        }
        try Data().write(to: root.appendingPathComponent("compiler-continue"))
        try wait("compiler output finishes with the original shell responsive") {
            session.terminalPromptQueueIsReady && session.commandLifecycle.completionSequence > sequence
        }
        heartbeat.invalidate()
        print(String(format: "Compiler output %@: main-thread maximum gap %.1fms", backend, maximumGap * 1_000))
        try check(maximumGap < 0.5, "compiler output does not block the main thread")
        try check(visible().contains("COMPILER_FINISHED"), "compiler output remains visible after completion")

        let final = try run("printf 'FINAL_BLOCK\\n'")
        let finalMenu = try menu(for: final)
        let finalCopy = try item("zshell-copy-command", in: finalMenu)
        session.clear()
        pump(0.2)
        seedClipboard()
        try check(!validate(finalCopy), "clearing scrollback disables an open menu token")
        try invoke(finalCopy)
        try check(clipboard.string(forType: .string) == "COMMAND_BLOCK_SENTINEL", "cleared output cannot copy a different command")
        print("Command block \(backend) surfaces: \(checks) checks passed")
    }

    private static func verifyGhosttyCommandCallbacks(directory: String) throws {
        let launch = TerminalLaunch(program: "/bin/cat", arguments: [], commandLine: "/bin/cat",
                                    interactiveShell: nil, workingDirectory: directory,
                                    environment: ["TERM": "xterm-256color"])
        let view = ZshellTerminalView(launch: launch)
        let window = NSPanel(contentRect: NSRect(x: -100_000, y: -100_000, width: 800, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.setSurfaceVisible(false)
        let recorder = CommandCallbackRecorder(view: view)
        view.delegate = recorder
        defer { view.delegate = view; view.detach(); window.contentView = nil; window.close() }
        let bridge = view.core.bridge
        try check(bridge.rawSurface != nil, "callback fixture uses a live native surface")
        func render() {
            recorder.inNativeCallback = true
            _ = bridge.handleAction(ghostty_action_s(tag: GHOSTTY_ACTION_RENDER, action: ghostty_action_u()))
            recorder.inNativeCallback = false
        }
        func finish(_ exit: Int16, _ duration: UInt64) {
            var payload = ghostty_action_u()
            payload.command_finished = ghostty_action_command_finished_s(exit_code: exit, duration: duration)
            recorder.inNativeCallback = true
            _ = bridge.handleAction(ghostty_action_s(tag: GHOSTTY_ACTION_COMMAND_FINISHED, action: payload))
            recorder.inNativeCallback = false
        }
        render(); render(); render()
        finish(7, 101); finish(-1, 202); finish(255, 303)
        try check(recorder.finishExits.isEmpty && recorder.recordUpdates == 0,
                  "record readers do not run inside the native action callback")
        try wait("all native completion payloads are delivered") { recorder.finishExits.count == 3 }
        try check(recorder.finishExits == [7, nil, 255] && recorder.finishDurations == [101, 202, 303],
                  "command completions retain FIFO order, exit codes and durations")
        try check(recorder.recordUpdates == 1 && recorder.successfulReads == 4 && !recorder.reenteredCallback,
                  "render updates coalesce while completion observers can synchronously read native records")
        let updateCount = recorder.recordUpdates
        render(); finish(88, 404)
        view.detach()
        pump(0.05)
        try check(recorder.recordUpdates == updateCount && recorder.finishExits.count == 3,
                  "teardown cancels queued record and completion callbacks")
        view.start(launch: launch)
        view.delegate = recorder
        try check(view.core.bridge === bridge && bridge.rawSurface != nil,
                  "the callback bridge is reused by a new native surface")
        finish(99, 505)
        view.detach()
        view.start(launch: launch)
        view.delegate = recorder
        pump(0.05)
        try check(recorder.finishExits.count == 3,
                  "an old completion is never delivered to a replacement surface")
        finish(0, 606)
        try wait("replacement surface delivers fresh completion callbacks") { recorder.finishExits.count == 4 }
        try check(recorder.finishExits.last == 0 && recorder.finishDurations.last == 606,
                  "teardown cancellation does not suppress the new surface's completion")
    }

    private static func control(_ text: String, in session: TerminalSession) {
        if let ghostty = session.surface as? ZshellTerminalView {
            ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
        } else { session.surface.sendText(text) }
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CommandBlockFailure.failed(message) }
        checks += 1
        print("PASS \(backend) \(message)")
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

@MainActor
private final class CommandCallbackRecorder: TerminalSurfaceCommandFinishedDelegate, TerminalSurfaceCommandRecordsDelegate {
    weak var view: ZshellTerminalView?
    var inNativeCallback = false
    var reenteredCallback = false
    var recordUpdates = 0
    var successfulReads = 0
    var finishExits: [Int?] = []
    var finishDurations: [UInt64] = []

    init(view: ZshellTerminalView) { self.view = view }

    func terminalCommandRecordsDidChange() { recordUpdates += 1; readRecords() }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        readRecords()
        finishExits.append(exitCode)
        finishDurations.append(durationNanos)
    }

    private func readRecords() {
        reenteredCallback = reenteredCallback || inNativeCallback
        guard let view else { return }
        _ = view.semanticCommandRevision
        if view.semanticCommandRecords() != nil { successfulReads += 1 }
    }
}
