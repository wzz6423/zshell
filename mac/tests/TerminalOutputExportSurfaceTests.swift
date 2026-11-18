import AppKit
import Foundation
import ObjectiveC.runtime
@testable import zshell

private enum OutputExportFailure: Error { case check(String) }

@MainActor
private enum OutputExportTemporaryDirectory {
    nonisolated(unsafe) static var url: URL!

    static func install(in home: URL) throws {
        guard home.path.hasPrefix("/tmp/zshell-output-export-tests-"),
              ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"].map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) == home,
              let configured = ProcessInfo.processInfo.environment["TMPDIR"],
              URL(fileURLWithPath: configured).resolvingSymlinksInPath() == home.appendingPathComponent("tmp", isDirectory: true),
              FileManager.default.fileExists(atPath: configured),
              let original = class_getInstanceMethod(FileManager.self, #selector(getter: FileManager.temporaryDirectory)),
              let replacement = class_getInstanceMethod(FileManager.self, NSSelectorFromString("outputExportTestTemporaryDirectory")) else {
            throw OutputExportFailure.check("the fixture's HOME and configured temporary directory must be disposable")
        }
        url = URL(fileURLWithPath: configured, isDirectory: true).resolvingSymlinksInPath()
        // Foundation ignores TMPDIR on this macOS; keep its capture validation
        // and the native backend's TMPDIR inside the same disposable directory.
        method_exchangeImplementations(original, replacement)
    }
}

extension FileManager {
    @objc(outputExportTestTemporaryDirectory)
    nonisolated fileprivate func outputExportTestTemporaryDirectory() -> URL { OutputExportTemporaryDirectory.url }
}

@MainActor
private final class OutputExportApplication: NSApplication {
    weak var fixtureWindow: NSWindow?
    override var keyWindow: NSWindow? { fixtureWindow ?? super.keyWindow }
}

@MainActor
private final class OutputExportSavePanel: NSSavePanel {
    var destination: URL?
    private var responseHandler: ((NSApplication.ModalResponse) -> Void)?
    private weak var host: NSWindow?
    var responseIsPending: Bool { responseHandler != nil }
    override var url: URL? { destination }

    override func beginSheetModal(for window: NSWindow,
                                 completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        host = window
        responseHandler = handler
        QuickTerminalOffscreen.prepare(self)
        window.beginSheet(self)
    }

    func resolve(_ response: NSApplication.ModalResponse) {
        let handler = responseHandler
        responseHandler = nil
        host?.endSheet(self, returnCode: response)
        orderOut(nil)
        handler?(response)
    }

    override func cancel(_ sender: Any?) { resolve(.cancel) }
}

@main
@MainActor
struct TerminalOutputExportSurfaceTests {
    private static var checks = 0
    private static let files = FileManager.default

    static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        setbuf(stdout, nil)
        do { try run(); print("Terminal output export: \(checks) checks passed") }
        catch { fputs("Terminal output export failed after \(checks) checks: \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        let app = OutputExportApplication.shared as! OutputExportApplication
        NSApp.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        let backend = CommandLine.arguments[1]
        let home = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        try OutputExportTemporaryDirectory.install(in: home)
        let temporary = files.temporaryDirectory.resolvingSymlinksInPath()
        print("Fixture \(backend): HOME=\(home.path); capture directory=\(temporary.path)")
        try check(home.path.hasPrefix("/tmp/zshell-output-export-tests-")
                  && temporary.path.hasPrefix(home.path + "/"), "HOME and capture directory are disposable")
        let draft = home.appendingPathComponent("draft.txt")
        try """
        HISTFILE=/dev/null
        unsetopt SHARE_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME APPEND_HISTORY
        bindkey -e
        PROMPT='EXPORT_READY> '
        RPROMPT=''
        PS2=''
        _export_dump_draft() { builtin print -rn -- "$BUFFER" >| \(quote(draft.path)); }
        zle -N _export_dump_draft
        bindkey '^T' _export_dump_draft
        """.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let output = home.appendingPathComponent("output.py")
        try """
        import sys
        print('EXPORT_OLD_你好 café e\\u0301 👩🏽‍💻 🇨🇳')
        print('\\x1b[31mEXPORT_STYLED\\x1b[0m')
        print('\\x1b]8;;https://example.com\\x1b\\\\EXPORT_LINK_LABEL\\x1b]8;;\\x1b\\\\')
        print('EXPORT_FIRST\\r\\n\\r\\nEXPORT_THIRD')
        print('EXPORT_WRAP_' + '你好' * 120 + '_WRAP_END')
        for index in range(800):
            print(f'EXPORT_LINE_{index:04d} ' + 'x' * 160)
        print('EXPORT_NEW_終わり', flush=True)
        """.write(to: output, atomically: true, encoding: .utf8)
        AppSettings.shared.language = .english
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.restoreTerminalHistory = false
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.resumeAgentConversations = false
        AppSettings.shared.notifyOnError = false
        AppSettings.shared.copyOnSelect = false
        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let first = Project(fallbackName: "Export source", manager: manager, createInitialSession: false)
        let second = Project(fallbackName: "Other project", manager: manager, createInitialSession: false)
        first.customDirectory = home.path; second.customDirectory = home.path
        manager.projects = [first, second]
        manager.selectedProjectID = first.id
        guard let source = first.newSession(directory: home.path), let other = second.newSession(directory: home.path) else {
            throw OutputExportFailure.check("fixture shells could not start")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.identifier = .init("main-output-export-fixture")
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        window.contentView = content
        manager.attach(to: window)
        for session in [source, other] {
            session.surface.frame = NSRect(x: 0, y: 0, width: 880, height: 450)
            content.addSubview(session.surface)
            session.surface.setSurfaceVisible(true)
        }
        window.orderFront(nil)
        app.fixtureWindow = window
        window.makeFirstResponder(source.surface)
        var panel: OutputExportSavePanel?
        let controller = TerminalOutputExportController(makeSavePanel: {
            let created = OutputExportSavePanel()
            panel = created
            return created
        })
        AppMenuController.shared.install()
        guard let terminalMenu = NSApp.mainMenu.flatMap({ AppMenuController.submenu(.terminal, in: $0) }),
              let mainExport = terminalMenu.items.first(where: { $0.title == String(localized: "Save Terminal Output…") }),
              let mainValidation = mainExport.target as? NSMenuItemValidation else {
            throw OutputExportFailure.check("the Terminal menu export command is missing")
        }
        try check(mainValidation.validateMenuItem(mainExport), "the main menu enables export for the focused terminal")
        let sourceTabID = first.selectedTabID
        let file = FileTab(path: output.path)
        let fileTab = PaneTab(content: .file(file))
        first.tabs.append(fileTab)
        first.selectedTabID = fileTab.id
        try check(!controller.canSave(in: manager) && !mainValidation.validateMenuItem(mainExport),
                  "a focused file pane disables export even if an old terminal responder remains")
        first.tabs.removeAll { $0.id == fileTab.id }
        first.selectedTabID = sourceTabID
        defer {
            panel?.cancel(nil)
            manager.windowClosed()
            pump(0.3)
            window.contentView = nil
            window.close()
            app.fixtureWindow = nil
        }
        try wait("both real PTYs reach their shell prompt") { [source, other].allSatisfy(\.terminalPromptQueueIsReady) }
        try run("/usr/bin/python3 " + quote(output.path), in: source)
        try run("printf 'OTHER_PROJECT_ONLY\\n'", in: other)
        window.makeFirstResponder(source.surface)
        let original = try capture(source)
        try check(original.contains("EXPORT_OLD_你好 café e\u{301} 👩🏽‍💻 🇨🇳") && original.contains("EXPORT_NEW_終わり"),
                  "\(backend) retains Unicode and both old scrollback and the current screen")
        try check(original.contains("EXPORT_STYLED") && original.contains("EXPORT_LINK_LABEL")
                  && !original.contains("\u{1b}") && !original.contains("\r"), "styled and hyperlink output becomes plain LF text")
        try check(original.contains("EXPORT_FIRST\n\nEXPORT_THIRD")
                  && original.contains("EXPORT_WRAP_" + String(repeating: "你好", count: 120) + "_WRAP_END"),
                  "blank lines and soft-wrapped Unicode retain their logical text")
        try check(original.contains("EXPORT_LINE_0000") && original.contains("EXPORT_LINE_0799") && original.utf8.count > 100_000,
                  "a long capture includes the retained rows above the viewport")

        let independent = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        independent.isReleasedWhenClosed = false
        let independentContent = NSView(frame: content.bounds)
        independent.contentView = independentContent
        independentContent.addSubview(other.surface)
        independent.orderFront(nil)
        independent.makeFirstResponder(other.surface)
        app.fixtureWindow = independent
        try check(controller.canSave(in: nil) && controller.canSave(in: manager),
                  "an independent quick surface needs no manager and cannot target another main window")
        try check(mainValidation.validateMenuItem(mainExport), "the main menu also enables an independent key terminal")
        let independentSnapshot = try capture(other)
        let independentDestination = home.appendingPathComponent("independent.txt")
        controller.save(in: nil)
        panel?.destination = independentDestination
        panel?.resolve(.OK)
        try wait("an independent surface saves its own captured text") {
            (try? String(contentsOf: independentDestination, encoding: .utf8)) == independentSnapshot
                && controller.canSave(in: nil)
        }
        let container = TerminalContainerView(frame: independentContent.bounds)
        container.focusOnAppear = false
        independentContent.addSubview(container)
        container.mount(other.surface, scrollbar: other.overlayScrollbar, queueBar: other.promptQueueBar)
        other.promptQueue.present()
        independentContent.layoutSubtreeIfNeeded()
        func queueField(_ view: NSView) -> NSTextField? {
            if view.identifier?.rawValue == "prompt-queue-input" { return view as? NSTextField }
            return view.subviews.lazy.compactMap(queueField).first
        }
        guard let input = queueField(other.promptQueueBar) else { throw OutputExportFailure.check("queue field missing") }
        independent.makeFirstResponder(input)
        try check(controller.canSave(in: nil), "a quick terminal's prompt-queue field resolves its owning container")
        let overlay = NSTextView(frame: other.surface.bounds)
        other.surface.addSubview(overlay)
        independent.makeFirstResponder(overlay)
        try check(controller.canSave(in: nil), "a terminal overlay resolves its ancestor surface")
        overlay.removeFromSuperview()
        other.promptQueue.dismiss()
        let editor = NSTextView(frame: independentContent.bounds)
        independentContent.addSubview(editor)
        independent.makeFirstResponder(editor)
        try check(!controller.canSave(in: nil) && !controller.canSave(in: manager),
                  "an editor in the key independent window cannot fall back to another terminal")
        try check(!mainValidation.validateMenuItem(mainExport), "the main menu disables export for the independent editor")
        container.releaseTerminal(other.surface)
        other.promptQueueBar.setPaneVisible(false)
        other.surface.translatesAutoresizingMaskIntoConstraints = true
        content.addSubview(other.surface)
        app.fixtureWindow = window
        window.makeFirstResponder(source.surface)
        independent.contentView = nil
        independent.close()

        let beforeRelease = try captureDirectories()
        var localPanel: OutputExportSavePanel?
        var localController: TerminalOutputExportController? = TerminalOutputExportController(makeSavePanel: {
            let created = OutputExportSavePanel()
            localPanel = created
            return created
        })
        weak let releasedController = localController
        localController?.save(from: source.surface)
        try check(localPanel?.responseIsPending == true, "a local controller owns a pending capture and save panel")
        localController = nil
        try wait("releasing the controller cancels its panel and cleans the owned capture") {
            releasedController == nil && localPanel?.responseIsPending == false
                && (try? captureDirectories()) == beforeRelease && window.attachedSheet == nil
        }
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        try check(controller.canSave(from: source.surface), "released-controller notifications leave live exports usable")

        let cancelled = home.appendingPathComponent("cancelled.txt")
        let beforeCancel = try captureDirectories()
        source.surface.selectAll(nil)
        try check(source.surface.hasSelection, "selection exists before exporting")
        let context = controller.menuItem(for: source.surface)
        let actualContext = TerminalContextMenu.make(for: source.surface, linkTarget: nil)
        try check(actualContext.items.contains { $0.identifier?.rawValue == "zshell-save-terminal-output" },
                  "the real terminal context menu includes export beside existing actions")
        try check(controller.validateMenuItem(context) && (context.representedObject as? NSView) === source.surface,
                  "context action is available and bound to its clicked surface")
        try invoke(context)
        guard let cancelledPanel = panel else { throw OutputExportFailure.check("save panel missing") }
        cancelledPanel.destination = cancelled
        try check(cancelledPanel.allowedContentTypes == [.plainText] && cancelledPanel.nameFieldStringValue == "terminal-output.txt",
                  "the AppKit save panel offers a plain-text file")
        try check((try captureDirectories().subtracting(beforeCancel)).count == 1, "each pending export owns one capture directory")
        cancelledPanel.cancel(nil)
        try wait("cancel removes the capture without creating a destination") {
            (try? captureDirectories()) == beforeCancel && controller.canSave(from: source.surface)
        }
        try check(!files.fileExists(atPath: cancelled.path) && source.surface.hasSelection
                  && window.firstResponder === source.surface, "cancel keeps the terminal selection and responder")

        let switched = home.appendingPathComponent("switched.txt")
        let beforeSwitch = try captureDirectories()
        controller.save(in: manager)
        try check(!controller.canSave(from: source.surface), "a pending save panel rejects a second export in the same window")
        manager.selectedProjectID = second.id
        window.makeFirstResponder(other.surface)
        panel?.destination = switched
        panel?.resolve(.OK)
        try wait("project switching saves the original snapshot and releases its capture") {
            (try? String(contentsOf: switched, encoding: .utf8)) == original
                && (try? captureDirectories()) == beforeSwitch && controller.canSave(from: source.surface)
        }
        try check(window.firstResponder === other.surface && source.surface.hasSelection,
                  "completion preserves the newly focused pane and original selection")
        manager.selectedProjectID = first.id
        window.makeFirstResponder(source.surface)
        let typedDraft = "printf 'UNSENT_DRAFT_你好 👩🏽‍💻'"
        source.sendCommand(typedDraft, asPaste: true)
        control("\u{14}", in: source)
        try wait("the PTY holds an unsent Unicode draft") { (try? String(contentsOf: draft, encoding: .utf8)) == typedDraft }
        source.surface.isReadOnly = true
        let blocking = source.surface.commandRouting.contextMenuItem()
        try invoke(blocking)
        let lockedContext = TerminalContextMenu.make(for: source.surface, linkTarget: nil)
        guard let lockedExport = lockedContext.items.first(where: { $0.identifier?.rawValue == "zshell-save-terminal-output" }),
              let contextValidation = lockedExport.target as? NSMenuItemValidation else {
            throw OutputExportFailure.check("the locked terminal's context export is missing")
        }
        try check(source.isReadOnly && source.surface.commandRouting.blocksCommands
                  && mainValidation.validateMenuItem(mainExport) && contextValidation.validateMenuItem(lockedExport),
                  "main and context export remain enabled with Read Only and Block Zshell Commands together")
        let draftSequence = source.commandLifecycle.completionSequence
        func preservedLockedDraft(_ operation: String) throws {
            try check(source.isReadOnly && source.surface.commandRouting.blocksCommands
                      && source.commandLifecycle.completionSequence == draftSequence && window.firstResponder === source.surface,
                      "\(operation) preserves both locks, the command lifecycle and terminal focus")
            source.surface.isReadOnly = false
            defer { source.surface.isReadOnly = true }
            try files.removeItem(at: draft)
            control("\u{14}", in: source)
            try wait("\(operation) leaves the real PTY's unsent Unicode draft unchanged") {
                (try? String(contentsOf: draft, encoding: .utf8)) == typedDraft
            }
        }
        let lockedSnapshot = try capture(source)
        let beforeDraftExport = try captureDirectories()
        let draftExport = home.appendingPathComponent("draft.txt.export")
        try invoke(context)
        panel?.destination = draftExport
        panel?.resolve(.OK)
        try wait("locked export saves its original snapshot and removes its capture") {
            (try? String(contentsOf: draftExport, encoding: .utf8)) == lockedSnapshot
                && (try? captureDirectories()) == beforeDraftExport && controller.canSave(from: source.surface)
        }
        try preservedLockedDraft("saving while locked")
        let beforeLockedCancel = try captureDirectories()
        controller.save(in: manager)
        panel?.destination = cancelled
        panel?.cancel(nil)
        try wait("locked cancellation removes its capture without creating a file") {
            (try? captureDirectories()) == beforeLockedCancel && !files.fileExists(atPath: cancelled.path)
                && controller.canSave(from: source.surface)
        }
        try preservedLockedDraft("cancelling while locked")

        let locked = home.appendingPathComponent("locked", isDirectory: true)
        try files.createDirectory(at: locked, withIntermediateDirectories: false)
        let target = locked.appendingPathComponent("output.txt")
        let sentinel = Data("ORIGINAL_FILE_KEEP_ME\n".utf8)
        try sentinel.write(to: target)
        let beforeFailure = try captureDirectories()
        controller.save(from: source.surface)
        panel?.destination = target
        try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        panel?.resolve(.OK)
        try wait("atomic write failure shows an AppKit error and cleans the capture") {
            window.attachedSheet?.identifier?.rawValue == "terminal-output-export-error"
                && (try? captureDirectories()) == beforeFailure
        }
        try check(try Data(contentsOf: target) == sentinel, "atomic failure preserves the previous file contents")
        try check(alertText(in: window).contains(target.path), "the write error identifies the chosen local file")
        dismissError(in: window)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        try preservedLockedDraft("a write error while locked")

        let beforeReadFailure = try captureDirectories()
        controller.save(from: source.surface)
        guard let brokenDirectory = try captureDirectories().subtracting(beforeReadFailure).first,
              let brokenCapture = try files.contentsOfDirectory(at: brokenDirectory, includingPropertiesForKeys: nil).first else {
            throw OutputExportFailure.check("no owned capture to corrupt")
        }
        try Data([0xff, 0xfe]).write(to: brokenCapture)
        let unreadable = home.appendingPathComponent("unreadable.txt")
        panel?.destination = unreadable
        panel?.resolve(.OK)
        try wait("invalid UTF-8 capture reports a read error and removes its directory") {
            window.attachedSheet?.identifier?.rawValue == "terminal-output-export-error"
                && (try? captureDirectories()) == beforeReadFailure
        }
        try check(!files.fileExists(atPath: unreadable.path) && alertText(in: window).contains("The terminal output could not be read."),
                  "a capture read failure does not report success or create a file")
        dismissError(in: window)
        try preservedLockedDraft("a read error while locked")
        source.surface.isReadOnly = false
        try invoke(blocking)
        control("\u{15}", in: source)

        let release = home.appendingPathComponent("release-buffer")
        let bufferFixture = home.appendingPathComponent("buffer.py")
        try """
        import sys, time
        from pathlib import Path
        alternate = sys.argv[1] == 'alternate'
        print('\\x1b[?1049h' if alternate else '', end='')
        print('\\x1b[2J\\x1b[3J\\x1b[H', end='')
        if alternate:
            print('EXPORT_TUI_你好 👩🏽‍💻')
        sys.stdout.flush()
        while not Path(sys.argv[2]).exists():
            time.sleep(0.02)
        if alternate:
            print('\\x1b[?1049l', end='', flush=True)
        """.write(to: bufferFixture, atomically: true, encoding: .utf8)
        for mode in ["empty", "alternate"] {
            let sequence = other.commandLifecycle.completionSequence
            other.sendCommand("/usr/bin/python3 " + quote(bufferFixture.path) + " " + mode + " " + quote(release.path), asPaste: true)
            other.sendEnter()
            try wait("the \(mode) screen is active on the real backend") {
                guard let visible = other.surface.readVisibleText(maxLines: 250, maxColumns: 1_000) else { return false }
                return mode == "empty" ? visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : visible.contains("EXPORT_TUI_")
            }
            let snapshot = try capture(other)
            let destination = home.appendingPathComponent(mode + ".txt")
            controller.save(from: other.surface)
            panel?.destination = destination
            panel?.resolve(.OK)
            try wait("\(mode) buffer exports as UTF-8 text") {
                (try? String(contentsOf: destination, encoding: .utf8)) == snapshot && controller.canSave(from: other.surface)
            }
            if mode == "empty" {
                try check(snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          "an empty retained buffer exports only its blank screen rows")
            } else {
                try check(snapshot.contains("EXPORT_TUI_你好 👩🏽‍💻") && !snapshot.contains("OTHER_PROJECT_ONLY"),
                          "alternate-screen export contains the active TUI buffer")
            }
            try Data().write(to: release)
            try wait("the fixture returns to its root shell") {
                other.commandLifecycle.completionSequence > sequence && other.terminalPromptQueueIsReady
            }
            try files.removeItem(at: release)
        }

        let closed = home.appendingPathComponent("closed-pane.txt")
        let closedSnapshot = try capture(source)
        controller.save(from: source.surface)
        source.terminate()
        try wait("original pane can close while the save panel is open") { source.hasExited }
        source.surface.removeFromSuperview()
        manager.selectedProjectID = second.id
        window.makeFirstResponder(other.surface)
        panel?.destination = closed
        panel?.resolve(.OK)
        try wait("closing the original terminal still saves its captured snapshot") {
            (try? String(contentsOf: closed, encoding: .utf8)) == closedSnapshot && controller.canSave(from: other.surface)
        }
        content.addSubview(source.surface)
        controller.save(from: source.surface)
        try wait("a detached backend reports capture failure through AppKit") {
            window.attachedSheet?.identifier?.rawValue == "terminal-output-export-error"
        }
        dismissError(in: window)
        source.surface.removeFromSuperview()

        let closingHost = home.appendingPathComponent("closed-window.txt")
        let beforeClose = try captureDirectories()
        controller.save(from: other.surface)
        let closingPanel = panel
        closingPanel?.destination = closingHost
        window.close()
        app.fixtureWindow = nil
        closingPanel?.resolve(.OK)
        try wait("closing the host cancels the panel and removes its capture") {
            (try? captureDirectories()) == beforeClose && window.attachedSheet == nil
        }
        try check(!files.fileExists(atPath: closingHost.path), "a late save response after host closure cannot write")
        try check(QuickTerminalOffscreen.isSafe(), "acceptance windows stay offscreen and never activate the app")
    }

    private static func captureDirectories() throws -> Set<URL> {
        Set(try files.contentsOfDirectory(at: files.temporaryDirectory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
    }

    private static func capture(_ session: TerminalSession) throws -> String {
        guard let text = TerminalHistorySerializer.takeLogCapture(from: session.surface)?.read() else {
            throw OutputExportFailure.check("the real backend could not capture its output")
        }
        return text
    }

    private static func run(_ command: String, in session: TerminalSession) throws {
        let sequence = session.commandLifecycle.completionSequence
        session.sendCommand(command, asPaste: true)
        session.sendEnter()
        try wait("the fixture command finishes on the real PTY") {
            session.commandLifecycle.completionSequence > sequence && session.terminalPromptQueueIsReady
        }
    }

    private static func control(_ text: String, in session: TerminalSession) {
        if let surface = session.surface as? ZshellTerminalView {
            surface.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
        } else { session.surface.sendText(text) }
    }

    private static func invoke(_ item: NSMenuItem) throws {
        guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else {
            throw OutputExportFailure.check("AppKit could not invoke the export menu item")
        }
    }

    private static func alertText(in window: NSWindow) -> String {
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        return window.attachedSheet?.contentView.map { fields($0).map(\.stringValue).joined(separator: "\n") } ?? ""
    }

    private static func dismissError(in window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
        pump(0.02)
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw OutputExportFailure.check(message) }
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
