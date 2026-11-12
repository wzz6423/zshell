import AppKit
@testable import zshell

@MainActor
private final class FileTreeDragFixture: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(url: URL, window: NSWindow) {
        draggingDestinationWindow = window
        draggingPasteboard = NSPasteboard(name: .init("zshell-file-tree-test-" + UUID().uuidString))
        super.init()
        draggingPasteboard.writeObjects([url as NSURL])
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
private final class FileTreePanelProbe {
    private var manager: TerminalManager!
    private var panel: AppKitFileTreePanel!
    private var window: NSWindow!
    private var table: NSTableView!
    private var checks = 0
    private let fixture = URL(fileURLWithPath: CommandLine.arguments[2])

    func start() throws {
        setbuf(stdout, nil)
        check(TerminalManager.activeWindowManager != nil, "Initial workspace exists")
        manager = TerminalManager()
        let target = fixture.appendingPathComponent("target")
        let fm = FileManager.default
        try fm.createDirectory(at: target.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("child".utf8).write(to: target.appendingPathComponent("folder/child.txt"))
        let longName = "very-long-中文-file-name-" + String(repeating: "abc", count: 55) + ".txt"
        try Data("long".utf8).write(to: target.appendingPathComponent(longName))
        let ordinary = target.appendingPathComponent("ordinary.txt")
        try Data("original".utf8).write(to: ordinary)
        manager.selectedProject?.customDirectory = target.path
        manager.syncFileTree()
        wait("Initial local rows") { self.manager.fileTree.items.count == 3 }

        let git = GitStatusModel()
        panel = AppKitFileTreePanel(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
        panel.configure(manager: manager, git: git)
        panel.update(rootBadge: nil, currentFilePath: nil, fontScale: 1, openSearchResult: { _ in })
        window = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        manager.attach(to: window)
        window.orderFront(nil)
        settle()
        table = descendants(panel).compactMap { $0 as? NSTableView }.first
        check(table != nil && table.numberOfRows == 3, "NSTableView contains local rows")
        check(QuickTerminalOffscreen.isSafe(), "Offscreen and focus isolation")
        let importButton = descendants(panel).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "Import Files…"
        }
        check(importButton?.isEnabled == true && importButton?.isHidden == false, "Import toolbar enabled")
        check(AppSettings.shared.fileTreeDragImport == false, "Drag import defaults to disabled")
        for language in [AppLanguage.english, .german, .arabic, .simplifiedChinese] {
            AppLocalization.apply(language)
            panel.update(rootBadge: nil, currentFilePath: nil, fontScale: 1.5, openSearchResult: { _ in })
            settle()
            let buttons = descendants(panel).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
            check(buttons.allSatisfy { $0.frame.width > 0 && $0.frame.minX >= 0
                && $0.frame.maxX <= ($0.superview?.bounds.width ?? 0) }, "200px localized toolbar fits: \(language)")
            let row = self.row(longName)
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { fail("Long-name row") }
            cell.layoutSubtreeIfNeeded()
            let labels = descendants(cell).compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
            check(labels.contains { $0.stringValue == longName && $0.frame.width > 0 && $0.lineBreakMode == .byTruncatingTail },
                  "Long filename remains accessible and truncates: \(language)")
            check(cell.accessibilityLabel()?.contains(longName) == true, "Full filename in accessibility label")
        }
        AppLocalization.apply(.english)
        panel.update(rootBadge: nil, currentFilePath: nil, fontScale: 1, openSearchResult: { _ in })
        settle()

        let folderRow = row("folder")
        table.selectRowIndexes(IndexSet(integer: folderRow), byExtendingSelection: false)
        key(124)
        wait("Right arrow expands folder") { self.manager.fileTree.items.contains { $0.name == "child.txt" } }
        check(manager.fileTreeImportDirectory == target.appendingPathComponent("folder").path, "Directory selection sets import target")
        key(124)
        check(manager.fileTree.items[table.selectedRow].name == "child.txt", "Right arrow selects first child")
        key(123)
        check(manager.fileTree.items[table.selectedRow].name == "folder", "Left arrow selects parent")
        key(123)
        wait("Left arrow collapses folder") { !self.manager.fileTree.items.contains { $0.name == "child.txt" } }
        let folderCell = table.view(atColumn: 0, row: row("folder"), makeIfNecessary: true)!
        check(folderCell.accessibilityPerformPress(), "Accessibility press is handled")
        wait("Accessibility press expands folder") { self.manager.fileTree.items.contains { $0.name == "child.txt" } }

        table.selectRowIndexes(IndexSet(integer: row("ordinary.txt")), byExtendingSelection: false)
        key(120)
        let rename = editField()
        type("cancelled.txt", into: rename)
        _ = panel.control(rename, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        settle()
        check(fm.fileExists(atPath: ordinary.path) && !fm.fileExists(atPath: target.appendingPathComponent("cancelled.txt").path),
              "Escape cancels rename")
        check(descendants(table).compactMap { $0 as? NSTextField }.allSatisfy { !$0.isEditable }, "Cancelled editor is removed")

        key(120)
        let committedRename = editField()
        type("renamed.txt", into: committedRename)
        _ = panel.control(committedRename, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        wait("Enter commits rename") { self.manager.fileTree.items.contains { $0.name == "renamed.txt" } }
        check(fm.fileExists(atPath: target.appendingPathComponent("renamed.txt").path) && !fm.fileExists(atPath: ordinary.path),
              "Rename moved production file")

        manager.fileTree.beginNewFile(in: target.path)
        let cancelledDraft = editField()
        type("cancelled-draft.txt", into: cancelledDraft)
        _ = panel.control(cancelledDraft, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        settle()
        check(manager.fileTree.draft == nil && !fm.fileExists(atPath: target.appendingPathComponent("cancelled-draft.txt").path),
              "Escape cancels draft")

        manager.fileTree.beginNewFile(in: target.path)
        let draft = editField()
        type("created.txt", into: draft)
        try Data("refresh".utf8).write(to: target.appendingPathComponent("background-refresh.txt"))
        manager.fileTree.sync(root: target.path)
        wait("Background refresh adds row during edit") { self.manager.fileTree.items.contains { $0.name == "background-refresh.txt" } }
        let restoredDraft = editField()
        check(restoredDraft.stringValue == "created.txt", "Background listing preserves input")
        _ = panel.control(restoredDraft, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        wait("Enter commits file draft") { self.manager.fileTree.items.contains { $0.name == "created.txt" } }
        check(fm.fileExists(atPath: target.appendingPathComponent("created.txt").path), "Draft creates production file")
        manager.fileContentSearch.activate()
        wait("Search replaces tree") { self.descendants(self.panel).contains { $0 is FileContentSearchPanel } }
        manager.fileContentSearch.deactivate()
        wait("Tree returns after search") { !self.descendants(self.panel).contains { $0 is FileContentSearchPanel } }
        check(table.numberOfRows == manager.fileTree.items.count, "Search round trip preserves rows")

        let other = TerminalManager()
        let otherRoot = fixture.appendingPathComponent("other-target")
        try fm.createDirectory(at: otherRoot, withIntermediateDirectories: false)
        other.selectedProject?.customDirectory = otherRoot.path
        other.syncFileTree()
        check(manager.fileTree !== other.fileTree, "Each manager owns a separate model")
        check(manager.fileTree.rootPath == target.path && other.fileTree.rootPath == otherRoot.path, "Independent workspace roots")

        let source = fixture.appendingPathComponent("drop-source.txt")
        try Data("dropped".utf8).write(to: source)
        let drag = FileTreeDragFixture(url: source, window: window)
        let settingsPane = SettingsEditorPane()
        _ = settingsPane.view
        guard let dragSwitch = descendants(settingsPane.view).compactMap({ $0 as? NSSwitch }).first(where: {
            $0.accessibilityLabel() == "Import by dragging into the file tree"
        }) else { fail("Production drag import settings switch missing") }
        func setDragImport(_ enabled: Bool) {
            dragSwitch.state = enabled ? .on : .off
            check(dragSwitch.sendAction(dragSwitch.action!, to: dragSwitch.target), "Production settings switch action routes")
            settle()
            check(AppSettings.shared.fileTreeDragImport == enabled, "Production switch updates import setting")
        }
        func validate(_ row: Int) -> NSDragOperation {
            panel.tableView(table, validateDrop: drag, proposedRow: row, proposedDropOperation: .on)
        }
        check(validate(row("folder")) == [], "Disabled setting rejects Finder drop")
        setDragImport(true)
        check(validate(row("folder")) == .copy, "Enabled setting accepts folder drop")
        setDragImport(false)
        check(!panel.tableView(table, acceptDrop: drag, row: row("folder"), dropOperation: .on),
              "Disabling setting after drag validation rejects the drop")
        check(!fm.fileExists(atPath: target.appendingPathComponent("folder/drop-source.txt").path), "Disabled drop leaves no copy")
        let otherPanel = AppKitFileTreePanel(frame: panel.frame)
        otherPanel.configure(manager: other, git: GitStatusModel())
        let otherTable = descendants(otherPanel).compactMap { $0 as? NSTableView }.first!
        check(otherPanel.tableView(otherTable, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on) == [],
              "Disabled preference gates a second workspace panel")
        setDragImport(true)
        check(otherPanel.tableView(otherTable, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on) == .copy,
              "Enabled preference reaches a second workspace panel")
        drag.draggingSource = table
        check(validate(row("folder")) == [], "Self-origin drop is rejected")
        drag.draggingSource = nil
        manager.fileTree.beginNewFile(in: target.path)
        settle()
        check(validate(row("folder")) == [], "Active draft rejects drop")
        manager.fileTree.cancelDraft()
        settle()
        check(validate(row("folder")) == .copy, "Folder drop becomes available after draft cancellation")
        check(panel.tableView(table, acceptDrop: drag, row: row("folder"), dropOperation: .on), "Folder drop enters controller")
        wait("Folder import finishes") { !FileTreeImportController.shared.isImporting }
        check(try String(contentsOf: target.appendingPathComponent("folder/drop-source.txt"), encoding: .utf8) == "dropped",
              "Folder drop copied into selected folder")
        check(fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: otherRoot.appendingPathComponent("drop-source.txt").path),
              "Source and other workspace are preserved")
        check(validate(-1) == .copy, "Empty area drop is accepted")
        check(panel.tableView(table, acceptDrop: drag, row: -1, dropOperation: .on), "Empty area drop enters controller")
        wait("Root import finishes") { !FileTreeImportController.shared.isImporting }
        check(fm.fileExists(atPath: target.appendingPathComponent("drop-source.txt").path), "Empty area drop targets root")

        manager.fileTree.sync(root: "")
        settle()
        check(importButton?.isEnabled == false && validate(-1) == [], "Empty model disables import and drop")
        manager.fileTree.configureRemote(try SSHEndpoint(host: "127.0.0.1", port: 1))
        settle()
        check(importButton?.isHidden == true && validate(-1) == [], "Remote tree hides import and rejects drop")
        manager.fileTree.configureRemote(nil)
        manager.syncFileTree()
        settle()
        check(QuickTerminalOffscreen.isSafe(), "Final offscreen and focus isolation")
        drag.draggingPasteboard.releaseGlobally()
        print("PASS \(CommandLine.arguments[1]): \(checks) production file-tree AppKit, keyboard, accessibility and drop checks")
        cleanup()
        exit(0)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    private func row(_ name: String) -> Int {
        guard let row = manager.fileTree.items.firstIndex(where: { $0.name == name }) else { fail("Missing row: \(name)") }
        return row
    }
    private func editField() -> NSTextField {
        settle()
        guard let field = descendants(table).compactMap({ $0 as? NSTextField }).first(where: \.isEditable) else {
            fail("Inline editor missing after \(checks) checks: rename=\(manager.fileTree.renamingPath ?? "nil") draft=\(String(describing: manager.fileTree.draft)) selected=\(table.selectedRow)")
        }
        return field
    }
    private func type(_ text: String, into field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else { fail("Field editor missing") }
        editor.string = text
        editor.didChangeText()
    }
    private func key(_ code: UInt16) {
        table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: "",
                                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
        settle()
    }
    private func settle() {
        let deadline = Date().addingTimeInterval(0.12)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        panel?.layoutSubtreeIfNeeded()
    }
    private func wait(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        check(condition(), message)
        settle()
    }
    private func check(_ value: Bool, _ message: String) {
        if !value { fail(message) }
        checks += 1
    }
    private func cleanup() {
        FileTreeImportController.shared.cancel()
        window?.close()
        TerminalManager.prepareForApplicationQuit(endAll: true)
        _ = try? PTYMuxCommandLine.exchange(method: "shutdown", timeout: 0.5)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
    }
    func fail(_ message: String) -> Never {
        fputs("FAIL \(message)\n", stderr)
        cleanup()
        exit(1)
    }
}

@main
struct FileTreePanelTests {
    @MainActor static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        precondition(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            == URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path)
        QuickTerminalOffscreen.install()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        AppLocalization.apply(.english)
        let probe = FileTreePanelProbe()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                do { try probe.start() } catch { probe.fail(error.localizedDescription) }
            }
        }
        zshellApp.main()
    }
}
