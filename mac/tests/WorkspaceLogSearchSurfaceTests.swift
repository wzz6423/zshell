import AppKit
import Foundation
@testable import zshell

private enum Failure: Error { case check(String) }

@MainActor
private final class LogTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isVisible: Bool { true }
}

@MainActor
private final class FindProbe: NSObject {
    var fired = false
    @objc func find(_ sender: Any?) { fired = true }
}

@main
struct WorkspaceLogSearchSurfaceTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("Workspace log test failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let backend = CommandLine.arguments[1]
        let fixture = CommandLine.arguments[2]
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false

        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        func wait(_ message: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(12)
            while !condition(), Date() < deadline { pump(0.03) }
            guard condition() else { throw Failure.check(message) }
            print("PASS \(backend): \(message)")
        }
        func session(_ name: String) -> TerminalSession {
            TerminalSession(initialDirectory: NSTemporaryDirectory(),
                            commandArguments: ["/usr/bin/python3", "-u", fixture, name],
                            allowsPersistence: false)
        }
        func capture(_ session: TerminalSession) -> String {
            TerminalHistorySerializer.takeLogCapture(from: session.surface)?.read() ?? ""
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }

        let mainMenu = NSMenu()
        let find = FindProbe()
        for (title, action, key) in [("Zshell", nil, ""), ("Edit", #selector(FindProbe.find(_:)), "f")] as [(String, Selector?, String)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            if let action {
                let findItem = NSMenuItem(title: "Find…", action: action, keyEquivalent: key)
                findItem.target = find
                item.submenu?.addItem(findItem)
            }
            mainMenu.addItem(item)
        }
        app.mainMenu = mainMenu
        let delegate = ZshellApplicationDelegate()
        delegate.restoreTerminalMenus()
        delegate.restoreTerminalMenus()
        let searchItems = mainMenu.items.compactMap(\.submenu).flatMap(\.items).filter {
            $0.action == NSSelectorFromString("searchTerminalLogs")
        }
        guard searchItems.count == 1, let searchItem = searchItems.first,
              searchItem.menu?.title == String(localized: "Terminal"),
              searchItem.title == String(localized: "Search Terminal Logs"),
              searchItem.keyEquivalent == "f", searchItem.keyEquivalentModifierMask == [.command, .shift] else {
            throw Failure.check("Terminal menu does not contain one Search Terminal Logs command with Command-Shift-F")
        }
        print("PASS \(backend): Terminal menu contains Search Terminal Logs with Command-Shift-F")

        let manager = TerminalManager()
        manager.projects.forEach { $0.terminateAll() }
        let project = Project(fallbackName: "Fixture Project", manager: manager, createInitialSession: false)
        let a = session("A"), b = session("B"), c = session("C")
        a.title = "Pane A"; b.title = "Pane B"; c.title = "Pane C"
        let paneA = Pane(content: .session(a)), paneB = Pane(content: .session(b))
        let split = PaneSplit(axis: .horizontal, fraction: 0.5, first: .pane(paneA), second: .pane(paneB))
        let tab1 = PaneTab(layout: .split(split), focusedPaneID: paneA.id)
        tab1.customName = "Split tab"
        let tab2 = PaneTab(content: .session(c))
        tab2.customName = "Other tab"
        project.tabs = [tab1, tab2]
        project.selectedTabID = tab1.id
        manager.projects = [project]
        manager.selectedProjectID = project.id

        let window = LogTestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main-log-fixture")
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content
        for (index, session) in [a, b, c].enumerated() {
            session.surface.frame = NSRect(x: CGFloat(index) * 300, y: 0, width: 300, height: 440)
            content.addSubview(session.surface)
            session.surface.setSurfaceVisible(true)
        }
        manager.attach(to: window)
        defer {
            WorkspaceLogSearchController.shared.close()
            [a, b, c].forEach { $0.terminate() }
            manager.windowClosed()
            window.contentView = nil
            window.close()
        }
        try wait("three real PTYs have produced output") {
            [a, b, c].allSatisfy { $0.surface.readVisibleText(maxLines: 100, maxColumns: 500)?.contains("NEW-") == true }
        }
        for (name, session) in [("A", a), ("B", b), ("C", c)] {
            let text = capture(session)
            guard text.contains("OLD-\(name)-needle"), text.contains("NEW-\(name)-needle") else {
                throw Failure.check("full scrollback missing for \(name)")
            }
            let result = WorkspaceLogSearchIndex.search(text: text, query: "needle", limit: 20)
            guard result.total == 3 else { throw Failure.check("unexpected match count \(result.total) for \(name)") }
        }
        print("PASS \(backend): searches complete scrollback in three panes")

        a.surface.selectAll(nil)
        try wait("terminal selection exists before scanning") { a.surface.hasSelection }
        let controller = WorkspaceLogSearchController.shared
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: true) else {
            throw Failure.check("could not create Command-Shift-F event")
        }
        cgEvent.flags = [.maskCommand, .maskShift]
        guard let shortcut = NSEvent(cgEvent: cgEvent), mainMenu.performKeyEquivalent(with: shortcut), !find.fired else {
            throw Failure.check("Command-Shift-F did not run Search Terminal Logs")
        }
        withExtendedLifetime(delegate) {}
        guard let panel = app.windows.first(where: { $0.identifier?.rawValue == "workspace-log-search-panel" }), panel.isVisible,
              let content = panel.contentView,
              let field = descendants(content).compactMap({ $0 as? NSSearchField }).first,
              let table = descendants(content).compactMap({ $0 as? NSTableView }).first else {
            throw Failure.check("search panel was not installed")
        }
        field.stringValue = "NEEDLE"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try wait("panel lists all matching panes") { table.numberOfRows == 9 }
        guard a.surface.hasSelection else { throw Failure.check("scanning changed the terminal selection") }
        field.stringValue = "filler"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        pump(0.3)
        field.stringValue = "NEEDLE"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try wait("new query replaces the previous scan") { table.numberOfRows == 9 }
        a.surface.sendText("input-check\n")
        try wait("terminal still receives input while search is open") { capture(a).contains("INPUT-A-input-check") }
        try wait("search results refresh after terminal output") { table.numberOfRows == 9 }

        var target: Int?
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            if descendants(cell).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("OLD-B-needle") }) {
                target = row
                break
            }
        }
        guard let target else { throw Failure.check("old match in pane B missing") }
        table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        a.surface.sendText("refresh-check\n")
        let rescanDeadline = Date().addingTimeInterval(6)
        while table.numberOfRows == 9, Date() < rescanDeadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard table.numberOfRows < 9 else { throw Failure.check("results did not rescan after terminal output") }
        try wait("rescanned results keep the selected match") {
            table.numberOfRows == 9 && table.selectedRow >= 0
                && table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true).map {
                    descendants($0).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("OLD-B-needle") }
                } == true
        }
        _ = controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try wait("clicking old result focuses its pane and scrollback") {
            tab1.focusedPaneID == paneB.id && b.surface.readVisibleText(maxLines: 100, maxColumns: 500)?.contains("OLD-B-needle") == true
        }
        controller.show(for: manager)
        field.stringValue = "e\u{301}"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try wait("combining-character results are listed") { table.numberOfRows == 3 }
        a.surface.setFrameSize(NSSize(width: 350, height: 440))
        var unicodeTarget: Int?
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            if descendants(cell).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("OLD-A-needle") }) {
                unicodeTarget = row
                break
            }
        }
        guard let unicodeTarget else { throw Failure.check("combining-character result missing") }
        table.selectRowIndexes(IndexSet(integer: unicodeTarget), byExtendingSelection: false)
        _ = controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try wait("combining-character result reveals its old terminal row") {
            tab1.focusedPaneID == paneA.id && a.surface.readVisibleText(maxLines: 100, maxColumns: 500)?.contains("OLD-A-needle") == true
        }
        controller.show(for: manager)
        field.stringValue = "7TAB-"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        pump(0.6)
        try wait("a tab is not indexed as adjacent text") { table.numberOfRows == 0 }
        field.stringValue = "7 TAB-"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try wait("a tab is indexed as the blank it draws") { table.numberOfRows == 3 }
        var tabTarget: Int?
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            if descendants(cell).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("TAB-B") }) {
                tabTarget = row
                break
            }
        }
        guard let tabTarget else { throw Failure.check("tab result in pane B missing") }
        table.selectRowIndexes(IndexSet(integer: tabTarget), byExtendingSelection: false)
        _ = controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try wait("tab result reveals its terminal row") { tab1.focusedPaneID == paneB.id && !panel.isVisible }
        controller.show(for: manager)
        field.stringValue = "NEEDLE"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try wait("all panes are searchable after reopening") { table.numberOfRows == 9 }
        project.tabs.removeAll { $0.id == tab2.id }
        c.terminate()
        try wait("closing a tab removes its matches") { table.numberOfRows == 6 }
        print("Workspace log surface \(backend) passed")
    }
}
