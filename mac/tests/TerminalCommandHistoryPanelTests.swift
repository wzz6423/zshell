import AppKit
import Foundation
@testable import zshell

private enum HistoryPanelFailure: Error { case failed(String) }

@main
@MainActor
struct TerminalCommandHistoryPanelTests {
    private static var checks = 0

    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        AppSettings.shared.language = .english
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.restoreTerminalHistory = false
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.resumeAgentConversations = false
        AppSettings.shared.notifyOnError = false
        let store = TerminalCommandHistoryStore(url: root.appendingPathComponent("panel/records.json"))
        try wait("panel history loads") { !store.isLoading }
        let manager = TerminalManager()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.identifier = NSUserInterfaceItemIdentifier("main-command-history-fixture")
        host.orderFront(nil)
        manager.attach(to: host)
        let originalResponder = NSTextField(frame: NSRect(x: 20, y: 20, width: 220, height: 24))
        host.contentView?.addSubview(originalResponder)
        host.makeFirstResponder(originalResponder)
        let previousResponder = host.firstResponder
        let controller = TerminalCommandHistoryController(store: store)
        defer {
            controller.close()
            manager.windowClosed()
            pump(0.5)
            host.contentView = nil
            host.close()
        }
        var revealed: UUID?
        var inserted: UUID?
        var available = true
        controller.canReveal = { _ in available }
        controller.reveal = { entry in revealed = entry.id; return false }
        controller.canInsert = { _ in available }
        controller.insert = { entry in inserted = entry.id; return false }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = TerminalCommandHistoryEntry(id: UUID(), terminalID: UUID(),
            command: "printf '命令 👩🏽‍💻'\nprintf 'second line'", workingDirectory: "/tmp/项目/café",
            startedAt: date, finishedAt: date.addingTimeInterval(0.375), durationNanos: 375_000_000, exitCode: 7)
        let second = TerminalCommandHistoryEntry(id: UUID(), terminalID: UUID(),
            command: "echo other", workingDirectory: "/tmp/other", startedAt: date.addingTimeInterval(1),
            finishedAt: date.addingTimeInterval(1.01), durationNanos: 10_000_000, exitCode: 0)
        store.note(first)
        store.note(second)
        let mainMenu = NSMenu(title: "Zshell")
        let applicationItem = NSMenuItem(title: "Zshell", action: nil, keyEquivalent: "")
        applicationItem.submenu = NSMenu(title: "Zshell")
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
        let applicationDelegate = ZshellApplicationDelegate()
        applicationDelegate.restoreTerminalMenus()
        controller.installMenu(in: mainMenu)
        controller.installMenu(in: mainMenu)
        let historyItems = mainMenu.items.flatMap { $0.submenu?.items ?? [] }
            .filter { $0.identifier?.rawValue == "terminal-command-history" }
        try check(historyItems.count == 1, "refreshing the Terminal menu keeps one history command")
        guard let historyItem = historyItems.first, let action = historyItem.action else {
            throw HistoryPanelFailure.failed("history menu action missing")
        }
        host.makeKeyAndOrderFront(nil)
        try check(controller.validateMenuItem(historyItem), "history menu is available for the active workspace")
        try check(NSApp.sendAction(action, to: historyItem.target, from: historyItem),
                  "the installed menu action opens command history")
        guard let panel = host.childWindows?.first(where: { $0.identifier?.rawValue == "terminal-command-history" }),
              let content = panel.contentView,
              let search = view("command-history-search", in: content) as? NSSearchField,
              let table = view("command-history-list", in: content) as? NSTableView else {
            throw HistoryPanelFailure.failed("history panel views missing")
        }
        try check(panel is NSPanel && table.numberOfRows == 2, "native history panel lists executed commands")
        try check(panel.parent === host && panel.level == .normal, "history remains attached to its workspace window")
        try check(search.currentEditor() != nil, "opening history focuses its search field")

        search.stringValue = "SECOND cafe"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try check(table.numberOfRows == 1, "typing filters multiline text and the execution directory")
        guard let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) else {
            throw HistoryPanelFailure.failed("history cell missing")
        }
        let labels = descendants(cell).compactMap { $0 as? NSTextField }.map(\.stringValue)
        try check(labels.contains(where: { $0.contains("👩🏽‍💻") && $0.contains("↵") }), "row preserves Unicode and shows multiline commands")
        try check(labels.contains(first.workingDirectory), "row displays the original directory")
        try check(labels.contains(where: { $0.contains("0.375") && $0.contains("7") }), "row displays duration and exit status")
        try check(cell.accessibilityLabel()?.contains(first.workingDirectory) == true,
                  "VoiceOver receives command and metadata")

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(previous.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        try click("command-history-copy", in: content)
        try check(pasteboard.string(forType: .string) == first.command, "Copy Command preserves exact multiline Unicode input")
        try click("command-history-show", in: content)
        try check(revealed == first.id, "Show Output routes the selected stable command identity")
        try click("command-history-insert", in: content)
        try check(inserted == first.id, "Insert into Terminal is an independent action")
        available = false
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        try check((view("command-history-show", in: content) as? NSButton)?.isEnabled == false
                  && (view("command-history-insert", in: content) as? NSButton)?.isEnabled == false,
                  "unavailable origin disables navigation and insertion")
        try check((view("command-history-copy", in: content) as? NSButton)?.isEnabled == true,
                  "copy stays available when the original pane is gone")

        let originalLanguage = AppSettings.shared.language
        defer { AppSettings.shared.language = originalLanguage }
        for language in AppLanguage.allCases where language != .system {
            AppSettings.shared.language = language
            pump(0.03)
            panel.setContentSize(NSSize(width: 620, height: 380))
            content.layoutSubtreeIfNeeded()
            for id in ["command-history-show", "command-history-insert", "command-history-copy", "command-history-delete", "command-history-clear"] {
                guard let button = view(id, in: content) as? NSButton else { throw HistoryPanelFailure.failed(id) }
                let frame = button.convert(button.bounds, to: content)
                try check(frame.minX >= 0 && frame.maxX <= content.bounds.width && button.frame.width > 0,
                          "\(language.rawValue) action \(id) fits minimum panel width")
                try check(button.frame.width >= button.intrinsicContentSize.width - 1,
                          "\(language.rawValue) action label remains untruncated")
                try check(!button.title.isEmpty && button.accessibilityLabel() != "",
                          "\(language.rawValue) action has a localized accessible name")
            }
        }
        AppSettings.shared.language = .english
        pump(0.03)

        search.stringValue = "no matching entry"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try check(table.numberOfRows == 0, "empty query results leave no stale selection")
        search.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try check(table.numberOfRows == 2, "clearing search restores the full bounded list")
        let editor = NSTextView()
        _ = controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        try check(table.selectedRow == 1, "Down moves selection from the search field")
        _ = controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
        try check(table.selectedRow == 0, "Up moves selection without activating a command")
        try click("command-history-delete", in: content)
        try wait("deleting a row updates the list") { table.numberOfRows == 1 }
        store.flush()
        let reloaded = TerminalCommandHistoryStore(url: root.appendingPathComponent("panel/records.json"))
        try wait("panel deletion reloads") { !reloaded.isLoading }
        try check(reloaded.entries.map(\.id) == [first.id], "deleting a row removes only that saved command")
        _ = controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try check(!panel.isVisible && panel.parent == nil, "Escape closes and detaches the history panel")
        try check(host.firstResponder === previousResponder, "Escape restores the original responder")
        controller.show(for: manager)
        panel.performClose(nil)
        try check(!panel.isVisible && panel.parent == nil && host.firstResponder === previousResponder,
                  "the window close button also restores the original responder")
        controller.show(for: manager)
        panel.makeFirstResponder(table)
        panel.cancelOperation(nil)
        try check(!panel.isVisible && host.firstResponder === previousResponder,
                  "Escape closes history from a table or button responder")
        controller.show(for: manager)
        controller.close(restoreFocus: false)
        try check(!panel.isVisible && panel.parent == nil, "successful actions can close without restoring the old pane")
        controller.show(for: manager)
        try click("command-history-clear", in: content)
        guard let cancelSheet = panel.attachedSheet else { throw HistoryPanelFailure.failed("clear confirmation missing") }
        panel.endSheet(cancelSheet, returnCode: .alertSecondButtonReturn)
        pump(0.05)
        try check(store.entries.map(\.id) == [first.id], "cancelling clear retains saved history")
        try click("command-history-clear", in: content)
        guard let clearSheet = panel.attachedSheet else { throw HistoryPanelFailure.failed("clear confirmation missing") }
        panel.endSheet(clearSheet, returnCode: .alertFirstButtonReturn)
        try wait("confirmed clear updates the list") { store.entries.isEmpty && table.numberOfRows == 0 }
        store.flush()
        let cleared = TerminalCommandHistoryStore(url: root.appendingPathComponent("panel/records.json"))
        try wait("confirmed clear reloads") { !cleared.isLoading }
        try check(cleared.entries.isEmpty, "the clear confirmation durably removes saved history")
        controller.close()

        let brokenURL = root.appendingPathComponent("broken-panel/records.json")
        try FileManager.default.createDirectory(at: brokenURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try PersistentCLIConnection.writePrivate(Data("broken".utf8), to: brokenURL)
        let broken = TerminalCommandHistoryStore(url: brokenURL)
        try wait("damaged panel history load settles") { !broken.isLoading }
        let brokenController = TerminalCommandHistoryController(store: broken)
        brokenController.show(for: manager)
        guard let brokenPanel = host.childWindows?.first(where: { $0.identifier?.rawValue == "terminal-command-history" }),
              let brokenContent = brokenPanel.contentView else { throw HistoryPanelFailure.failed("damaged history panel missing") }
        defer { brokenController.close() }
        try check((view("command-history-clear", in: brokenContent) as? NSButton)?.isEnabled == true,
                  "an empty damaged history can be repaired through Clear History")
        print("Command history AppKit panel: \(checks) checks passed")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func view(_ id: String, in root: NSView) -> NSView? {
        descendants(root).first { $0.accessibilityIdentifier() == id }
    }

    private static func click(_ id: String, in root: NSView) throws {
        guard let button = view(id, in: root) as? NSButton else { throw HistoryPanelFailure.failed(id) }
        button.performClick(nil)
        pump(0.03)
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw HistoryPanelFailure.failed(message) }
        checks += 1
        print("PASS \(message)")
    }

    private static func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    private static func wait(_ message: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { pump(0.01) }
        try check(condition(), message)
    }
}
