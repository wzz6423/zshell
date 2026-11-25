import AppKit
import Foundation
import ObjectiveC.runtime
@testable import zshell

private enum RedactionFailure: Error { case check(String) }

@MainActor
private enum RedactionTemporaryDirectory {
    nonisolated(unsafe) static var url: URL!

    static func install(in home: URL) throws {
        guard home.path.hasPrefix("/tmp/zshell-redaction-tests-"),
            ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"].map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) == home,
            let configured = ProcessInfo.processInfo.environment["TMPDIR"],
            URL(fileURLWithPath: configured).resolvingSymlinksInPath() == home.appendingPathComponent("tmp", isDirectory: true),
            FileManager.default.fileExists(atPath: configured),
            let original = class_getInstanceMethod(FileManager.self, #selector(getter: FileManager.temporaryDirectory)),
            let replacement = class_getInstanceMethod(FileManager.self, NSSelectorFromString("redactionTestTemporaryDirectory"))
        else {
            throw RedactionFailure.check("the fixture's HOME and configured temporary directory must be disposable")
        }
        url = URL(fileURLWithPath: configured, isDirectory: true).resolvingSymlinksInPath()
        // Foundation ignores TMPDIR on this macOS; keep its capture validation
        // and the native backend's TMPDIR inside the same disposable directory.
        method_exchangeImplementations(original, replacement)
    }
}

extension FileManager {
    @objc(redactionTestTemporaryDirectory)
    nonisolated fileprivate func redactionTestTemporaryDirectory() -> URL { RedactionTemporaryDirectory.url }
}

@MainActor
private final class RedactionApplication: NSApplication {
    weak var fixtureWindow: NSWindow?
    override var keyWindow: NSWindow? { fixtureWindow ?? super.keyWindow }
}

@MainActor
private final class RedactionSavePanel: NSSavePanel {
    var destination: URL?
    private var responseHandler: ((NSApplication.ModalResponse) -> Void)?
    private weak var host: NSWindow?
    var responseIsPending: Bool { responseHandler != nil }
    override var url: URL? { destination }

    override func beginSheetModal(
        for window: NSWindow,
        completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void
    ) {
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
struct TerminalRedactionSurfaceTests {
    private static var checks = 0
    private static let files = FileManager.default

    static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        setbuf(stdout, nil)
        do { try run(); print("Terminal sharing preview: \(checks) checks passed") } catch {
            fputs("Terminal sharing preview failed after \(checks) checks: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let app = RedactionApplication.shared as! RedactionApplication
        NSApp.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        let backend = CommandLine.arguments[1]
        let home = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        try RedactionTemporaryDirectory.install(in: home)
        let clipboard = NSPasteboard.general
        let savedClipboard = (clipboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        var ownedClipboardCount = clipboard.changeCount
        try """
        HISTFILE=/dev/null
        unsetopt SHARE_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME APPEND_HISTORY
        bindkey -e
        PROMPT='SHARING_READY> '
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
        settings.copyOnSelect = false
        settings.notifyOnError = false
        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let project = Project(fallbackName: "Sharing source", manager: manager, createInitialSession: false)
        project.customDirectory = home.path
        manager.projects = [project]
        manager.selectedProjectID = project.id
        guard let source = project.newSession(directory: home.path), let other = project.newSession(directory: home.path) else {
            throw RedactionFailure.check("fixture terminals missing")
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.identifier = .init("main-redaction-fixture")
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
        var savePanel: RedactionSavePanel?
        let exporter = TerminalOutputExportController(makeSavePanel: {
            let panel = RedactionSavePanel()
            savePanel = panel
            return panel
        })
        let controller = TerminalSharingPreviewController(exporter: exporter)
        defer {
            controller.close(restoreFocus: false)
            TerminalSharingPreviewController.shared.close(restoreFocus: false)
            if clipboard.changeCount == ownedClipboardCount {
                clipboard.clearContents()
                clipboard.writeObjects(
                    savedClipboard.map { entries in
                        let item = NSPasteboardItem()
                        for (type, data) in entries { item.setData(data, forType: type) }
                        return item
                    })
            }
            app.fixtureWindow = nil
            manager.windowClosed()
            pump(0.2)
            window.close()
        }
        try wait("both shells are ready") { source.terminalPromptQueueIsReady && other.terminalPromptQueueIsReady }
        let token = "ghp_" + String(repeating: "a", count: 36)
        let expected = "SHARING_中文😀\napi_key=[REDACTED]\nTOKEN:[REDACTED]\nlast line"
        let raw = "SHARING_中文😀\napi_key=local-secret\nTOKEN:" + token + "\nlast line"
        let fixture = home.appendingPathComponent("output.py")
        try ("print(" + pythonString(raw) + ")\n").write(to: fixture, atomically: true, encoding: .utf8)
        let record = try run("/usr/bin/python3 " + quote(fixture.path), in: source)
        _ = try run("printf 'OTHER_PANE_ONLY\\n'", in: other)
        guard let location = record.outputLocation, let commandText = source.surface.commandText(at: location, part: .output) else {
            throw RedactionFailure.check("completed command output missing")
        }
        try check(commandText.contains(raw), "real command output contains the fixture")
        clipboard.clearContents()
        clipboard.setString("SHARING_CLIPBOARD_SENTINEL", forType: .string)
        ownedClipboardCount = clipboard.changeCount
        controller.copy(from: source.surface, location: location)
        try wait("command output preview loads") { controller.editor.isEditable }
        let commandPreview = TerminalSecretRedaction.redact(commandText)!.text
        try check(
            controller.editor.string == commandPreview && commandPreview.contains(expected), "command preview matches exact redacted output"
        )
        try check(clipboard.changeCount == ownedClipboardCount, "preview capture leaves the general clipboard untouched")
        try button("terminal-sharing-original", in: controller).performClick(nil)
        try check(controller.editor.string == commandText, "original mode requires an explicit switch")
        controller.editor.undoManager?.registerUndo(withTarget: controller.editor) { $0.string = "RAW_UNDO_VALUE" }
        try button("terminal-sharing-original", in: controller).performClick(nil)
        try check(
            controller.editor.string == commandPreview && controller.editor.undoManager?.canUndo != true,
            "returning to redaction clears original undo history")
        controller.editor.string += "\nMANUAL_REVIEW"
        try button("terminal-sharing-action", in: controller).performClick(nil)
        ownedClipboardCount = clipboard.changeCount
        try check(clipboard.string(forType: .string) == commandPreview + "\nMANUAL_REVIEW", "Copy Preview copies the edited text exactly")
        try check(controller.panel?.isVisible == false && controller.editor.string.isEmpty, "copy clears preview storage")
        try check(source.surface.selectCommand(at: location), "native output selection")
        let selection = source.surface.readSelectedText(maxBytes: TerminalSecretRedaction.maximumBytes)!
        controller.copy(from: source.surface)
        try wait("selection preview loads") { controller.editor.isEditable }
        try check(
            controller.editor.string == TerminalSecretRedaction.redact(selection)!.text, "selection preview preserves native text exactly")
        try button("terminal-sharing-cancel", in: controller).performClick(nil)
        try check(
            controller.editor.string.isEmpty && clipboard.changeCount == ownedClipboardCount, "Cancel clears selection and does not copy")
        let quickWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        quickWindow.isReleasedWhenClosed = false
        let quickContent = NSView(frame: content.bounds)
        quickWindow.contentView = quickContent
        quickContent.addSubview(other.surface)
        quickWindow.orderFront(nil)
        quickWindow.makeFirstResponder(other.surface)
        app.fixtureWindow = quickWindow
        let quickSnapshot = try capture(other)
        try check(controller.canSave(), "independent Quick Terminal export resolves its own surface")
        controller.save()
        try wait("Quick Terminal preview loads") { controller.editor.isEditable }
        try check(
            controller.editor.string == TerminalSecretRedaction.redact(quickSnapshot)!.text, "Quick Terminal preview uses its own snapshot")
        controller.editor.string = "ONLY_REVIEWED_TEXT"
        controller.close()
        content.addSubview(other.surface)
        quickWindow.close()
        app.fixtureWindow = window
        controller.copy(from: source.surface, location: location)
        try wait("manual review preview loads") { controller.editor.isEditable }
        controller.editor.string = "ONLY_REVIEWED_TEXT"
        try button("terminal-sharing-action", in: controller).performClick(nil)
        ownedClipboardCount = clipboard.changeCount
        try check(clipboard.string(forType: .string) == "ONLY_REVIEWED_TEXT", "manual editing removes additional sensitive text")
        controller.copy(from: source.surface, location: location)
        try wait("second command preview loads") { controller.editor.isEditable }
        controller.editor.string = String(repeating: "x", count: TerminalSecretRedaction.maximumBytes + 1)
        try button("terminal-sharing-action", in: controller).performClick(nil)
        try check(
            controller.panel?.isVisible == true && clipboard.changeCount == ownedClipboardCount,
            "action rejects a programmatically oversized edit")
        controller.close()
        source.surface.isReadOnly = true
        let sourceSnapshot = try capture(source)
        let baselineDirectories = try captureDirectories()
        controller.save(from: source.surface)
        window.makeFirstResponder(other.surface)
        try wait("locked-pane save preview loads and capture is removed") {
            controller.editor.isEditable && (try? captureDirectories()) == baselineDirectories
        }
        let redactedSnapshot = TerminalSecretRedaction.redact(sourceSnapshot)!.text
        try check(
            controller.editor.string == redactedSnapshot && !controller.editor.string.contains("OTHER_PANE_ONLY"),
            "save remains bound to the locked source pane")
        let destination = home.appendingPathComponent("shared.txt")
        try button("terminal-sharing-action", in: controller).performClick(nil)
        savePanel?.destination = destination
        savePanel?.resolve(.OK)
        try wait("redacted snapshot is saved exactly") {
            (try? String(contentsOf: destination, encoding: .utf8)) == redactedSnapshot && controller.panel?.isVisible == false
        }
        try check(clipboard.changeCount == ownedClipboardCount && source.surface.isReadOnly, "save does not copy or unlock the source")
        controller.save(from: source.surface)
        try wait("preview for cancelled picker loads") { controller.editor.isEditable }
        try button("terminal-sharing-action", in: controller).performClick(nil)
        savePanel?.resolve(.cancel)
        try check(
            controller.panel?.isVisible == true && controller.editor.string == redactedSnapshot, "picker Cancel retains reviewed preview")
        controller.close()
        controller.save(from: source.surface)
        try wait("raw export preview loads") { controller.editor.isEditable }
        try button("terminal-sharing-original", in: controller).performClick(nil)
        try button("terminal-sharing-action", in: controller).performClick(nil)
        let rawDestination = home.appendingPathComponent("raw.txt")
        savePanel?.destination = rawDestination
        savePanel?.resolve(.OK)
        try wait("explicit original export saves source exactly") {
            (try? String(contentsOf: rawDestination, encoding: .utf8)) == sourceSnapshot && controller.panel?.isVisible == false
        }
        controller.save(from: source.surface)
        try wait("failure preview loads") { controller.editor.isEditable }
        let unwritable = home.appendingPathComponent("missing-parent/shared.txt")
        try button("terminal-sharing-action", in: controller).performClick(nil)
        savePanel?.destination = unwritable
        savePanel?.resolve(.OK)
        try wait("write error retains preview") { controller.panel?.attachedSheet?.identifier?.rawValue == "terminal-output-export-error" }
        try check(
            controller.editor.string == redactedSnapshot && !files.fileExists(atPath: unwritable.path),
            "failure keeps review text without creating a file")
        if let panel = controller.panel, let alert = panel.attachedSheet { panel.endSheet(alert, returnCode: .OK); alert.orderOut(nil) }
        controller.close()
        let cancelDestination = home.appendingPathComponent("cancelled-write.txt")
        controller.save(from: source.surface)
        try wait("close during picker preview loads") { controller.editor.isEditable }
        try button("terminal-sharing-action", in: controller).performClick(nil)
        let latePanel = savePanel
        latePanel?.destination = cancelDestination
        controller.close()
        latePanel?.resolve(.OK)
        pump(0.3)
        try check(
            !files.fileExists(atPath: cancelDestination.path) && controller.editor.string.isEmpty,
            "late picker response after preview closure cannot write")
        let beforeEarlyCancel = try captureDirectories()
        controller.save(from: source.surface)
        controller.close()
        try wait("early cancel removes unread snapshot") { (try? captureDirectories()) == beforeEarlyCancel }
        try check(controller.editor.string.isEmpty, "late detector response cannot restore cancelled raw text")
        let menu = TerminalContextMenu.make(for: source.surface, linkTarget: nil)
        let selectionItem = try item("zshell-copy-redacted-selection", in: menu)
        try check(
            (selectionItem.target as? NSMenuItemValidation)?.validateMenuItem(selectionItem) == true,
            "read-only selection menu stays available")
        try invoke(selectionItem)
        try wait("actual context selection opens shared preview") { TerminalSharingPreviewController.shared.editor.isEditable }
        try check(
            TerminalSharingPreviewController.shared.editor.string == TerminalSecretRedaction.redact(selection)!.text,
            "actual selection context uses its originating surface")
        TerminalSharingPreviewController.shared.close()
        let blockMenu = try commandMenu(source, location: location, window: window)
        try invoke(try item("zshell-copy-redacted-output", in: blockMenu))
        try wait("actual command context preview loads") { TerminalSharingPreviewController.shared.editor.isEditable }
        try check(
            TerminalSharingPreviewController.shared.editor.string == commandPreview, "actual clicked command context preserves its block")
        TerminalSharingPreviewController.shared.close()
        AppMenuController.shared.install()
        guard let terminal = NSApp.mainMenu.flatMap({ AppMenuController.submenu(.terminal, in: $0) }) else {
            throw RedactionFailure.check("Terminal menu missing")
        }
        try check(
            terminal.items.contains(where: { $0.title == String(localized: "Save Redacted Output") }),
            "Terminal menu exposes redacted export")
        var callbacks: [Bool] = []
        let callbackFile = home.appendingPathComponent("callback.txt")
        exporter.save(text: "CALLBACK_CONTENT", on: window) { callbacks.append($0) }
        savePanel?.destination = callbackFile
        savePanel?.resolve(.OK)
        try wait("text export completion occurs once") { callbacks == [true] }
        exporter.cancel(on: window)
        pump(0.05)
        try check(callbacks == [true], "completed text export cannot complete again during cancellation")
        callbacks = []
        exporter.save(text: "CANCELLED_RAW_CONTENT", on: window) { callbacks.append($0) }
        let callbackPanel = savePanel
        callbackPanel?.destination = home.appendingPathComponent("callback-cancelled.txt")
        exporter.cancel(on: window)
        callbackPanel?.resolve(.OK)
        pump(0.1)
        try check(
            callbacks == [false] && !files.fileExists(atPath: callbackPanel!.destination!.path),
            "cancelled text export completes once and ignores late response")
        let textJob = TerminalOutputExportJob(text: "IN_MEMORY_ONLY")
        _ = textJob.cancel()
        try check(textJob.read() == nil && textJob.isCancelled(), "cancelling a text job clears original memory")
        let oversizedCapture = TerminalHistorySerializer.takeLogCapture(from: source.surface)!
        do {
            _ = try oversizedCapture.read(maxBytes: 1)
            throw RedactionFailure.check("capture must fail above byte cap")
        } catch TerminalHistorySerializer.LogCapture.ReadFailure.tooLarge {
            try check(try captureDirectories() == baselineDirectories, "bounded capture read refuses oversized data and removes temp files")
        }
        controller.save(from: source.surface)
        try wait("host closure preview loads") { controller.editor.isEditable }
        try button("terminal-sharing-original", in: controller).performClick(nil)
        window.close()
        try wait("host closure discards both preview modes") {
            controller.panel?.isVisible == false && controller.editor.string.isEmpty && (try? captureDirectories()) == baselineDirectories
        }
        try check(clipboard.changeCount == ownedClipboardCount, "host closure leaves clipboard unchanged")
        try check(QuickTerminalOffscreen.isSafe(), "all acceptance windows stay offscreen")
        print("Backend \(backend): preview, native text, writes and lifecycle verified")
    }

    private static func commandMenu(_ session: TerminalSession, location: TerminalCommandOutputLocation, window: NSWindow) throws -> NSMenu
    {
        guard session.surface.revealCommand(at: location) else { throw RedactionFailure.check("command reveal missing") }
        pump(0.05)
        guard let snapshot = session.surface.readVisibleSnapshot() else { throw RedactionFailure.check("viewport missing") }
        for row in snapshot.rows.indices {
            let point = NSPoint(
                x: snapshot.origin.x + snapshot.cellSize.width * 2.25,
                y: session.surface.bounds.height - snapshot.origin.y - snapshot.cellSize.height * (CGFloat(row) + 0.5))
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: session.surface.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
            if session.surface.commandLocation(for: event) == location {
                return TerminalContextMenu.make(for: session.surface, event: event, linkTarget: nil)
            }
        }
        throw RedactionFailure.check("clicked command missing")
    }

    private static func button(_ identifier: String, in controller: TerminalSharingPreviewController) throws -> NSButton {
        guard let button = descendants(controller.panel?.contentView).first(where: { $0.identifier?.rawValue == identifier }) as? NSButton
        else {
            throw RedactionFailure.check("preview button missing")
        }
        return button
    }

    private static func item(_ identifier: String, in menu: NSMenu) throws -> NSMenuItem {
        guard let item = menu.items.first(where: { $0.identifier?.rawValue == identifier }) else {
            throw RedactionFailure.check("menu item missing")
        }
        return item
    }

    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap(descendants)
    }

    private static func captureDirectories() throws -> Set<URL> {
        Set(
            try files.contentsOfDirectory(at: files.temporaryDirectory, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
    }

    private static func capture(_ session: TerminalSession) throws -> String {
        guard let text = TerminalHistorySerializer.takeLogCapture(from: session.surface)?.read() else {
            throw RedactionFailure.check("backend capture missing")
        }
        return text
    }

    private static func run(_ command: String, in session: TerminalSession) throws -> TerminalCommandRecord {
        let old = Set(session.commandRecords.map(\.id))
        try wait("shell prompt ready") { session.terminalPromptQueueIsReady }
        session.sendCommand(command, asPaste: true)
        session.sendEnter()
        try wait("command completes") {
            session.terminalPromptQueueIsReady && session.commandRecords.contains { !old.contains($0.id) && $0.finishedAt != nil }
        }
        return session.commandRecords.first { !old.contains($0.id) }!
    }

    private static func invoke(_ item: NSMenuItem) throws {
        guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else {
            throw RedactionFailure.check("AppKit menu dispatch failed")
        }
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func pythonString(_ text: String) -> String {
        "'"
            + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(
                of: "\n", with: "\\n") + "'"
    }

    private static func pump(_ duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static func wait(_ name: String, _ condition: () -> Bool) throws {
        let until = Date().addingTimeInterval(15)
        while !condition(), Date() < until { pump(0.02) }
        try check(condition(), name)
    }

    private static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw RedactionFailure.check(name) }
        checks += 1
    }
}
