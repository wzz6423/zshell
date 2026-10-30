import AppKit
import Combine

@MainActor
final class TerminalCommandHistoryController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static let shared = TerminalCommandHistoryController()
    private let store: TerminalCommandHistoryStore
    private weak var manager: TerminalManager?
    private weak var previousResponder: NSResponder?
    private weak var previousWindow: NSWindow?
    private var panel: NSPanel?
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let showButton = NSButton()
    private let copyButton = NSButton()
    private let insertButton = NSButton()
    private let deleteButton = NSButton()
    private let clearButton = NSButton()
    private var entries: [TerminalCommandHistoryEntry] = []
    private var observations: [AnyCancellable] = []
    private var managerObservations: [AnyCancellable] = []
    private var selectionObservation: AnyCancellable?
    private weak var observedSession: TerminalSession?
    private var readinessObservation: AnyCancellable?
    private var runningStates: [UUID: Bool] = [:]
    private var reloadScheduled = false
    private var selectionUpdateScheduled = false
    private var restoresFocusOnClose = true

    // The list owns presentation only; the command-block integration supplies
    // navigation and prompt insertion without retaining a terminal or surface.
    var canReveal: (TerminalCommandHistoryEntry) -> Bool = TerminalCommandHistoryActions.canReveal
    var reveal: (TerminalCommandHistoryEntry) -> Bool = TerminalCommandHistoryActions.reveal
    var canInsert: (TerminalCommandHistoryEntry) -> Bool = TerminalCommandHistoryActions.canInsert
    var insert: (TerminalCommandHistoryEntry) -> Bool = TerminalCommandHistoryActions.insert

    init(store: TerminalCommandHistoryStore? = nil) {
        self.store = store ?? .shared
        super.init()
        self.store.$entries.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &observations)
        self.store.$isLoading.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &observations)
        self.store.$persistenceError.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleSelectionUpdate() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: AppLocalization.didChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.localize() }
            .store(in: &observations)
    }

    func installMenu(in mainMenu: NSMenu) {
        guard let terminalMenu = mainMenu.items.first(where: {
            $0.submenu?.items.contains(where: { $0.action == NSSelectorFromString("toggleQuickTerminal") }) == true
        })?.submenu else { return }
        let id = NSUserInterfaceItemIdentifier("terminal-command-history")
        let title = String(localized: "Command History…")
        let item = terminalMenu.items.first { $0.identifier == id }
            ?? NSMenuItem(title: title, action: #selector(showFromMenu(_:)), keyEquivalent: "")
        item.identifier = id
        if item.title != title { item.title = title }
        if item.target !== self { item.target = self }
        if item.menu == nil { terminalMenu.addItem(item) }
    }

    func show(for manager: TerminalManager) {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow) else { return }
        if manager.isCommandPaletteVisible { manager.dismissCommandPalette() }
        if panel == nil { configure() }
        guard let panel else { return }
        if panel.isVisible { close() }
        self.manager = manager
        previousWindow = host
        previousResponder = host.firstResponder
        managerObservations = TerminalManager.automationManagers.map { manager in
            manager.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleSelectionUpdate() }
        }
        searchField.stringValue = ""
        statusLabel.stringValue = ""
        localize()
        AppWindowPresentation.attach(panel, to: host, placement: .centered)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        // ZLE readiness changes without an app-model event while the user types.
        readinessObservation = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect().sink { [weak self] _ in self?.scheduleSelectionUpdate() }
    }

    func close(ifOwnedBy manager: TerminalManager? = nil, restoreFocus: Bool = true) {
        if let manager, self.manager !== manager { return }
        restoresFocusOnClose = restoreFocus
        panel?.close()
        restoresFocusOnClose = true
    }

    func windowWillClose(_ notification: Notification) {
        if let sheet = panel?.attachedSheet { panel?.endSheet(sheet, returnCode: .abort) }
        if let panel { AppWindowPresentation.hideChild(panel) }
        if restoresFocusOnClose, let previousWindow, let previousResponder,
           let view = previousResponder as? NSView, view.window === previousWindow,
           !view.isHiddenOrHasHiddenAncestor {
            previousWindow.makeFirstResponder(previousResponder)
        }
        previousWindow = nil
        previousResponder = nil
        self.manager = nil
        managerObservations.removeAll()
        selectionObservation = nil
        observedSession = nil
        readinessObservation = nil
        runningStates.removeAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        TerminalManager.activeWindowManager != nil
    }

    @objc private func showFromMenu(_ sender: Any?) {
        guard let manager = TerminalManager.activeWindowManager else { return }
        show(for: manager)
    }

    private func configure() {
        let panel = TerminalCommandHistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 620, height: 380)
        panel.identifier = NSUserInterfaceItemIdentifier("terminal-command-history")
        panel.delegate = self
        self.panel = panel
        guard let content = panel.contentView else { return }
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityIdentifier("command-history-search")
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(showSelection(_:))
        table.doubleAction = #selector(showSelection(_:))
        table.rowHeight = 76
        table.headerView = nil
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = false
        table.setAccessibilityIdentifier("command-history-list")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.lineBreakMode = .byTruncatingTail
        for (button, action, id) in [
            (showButton, #selector(showSelection(_:)), "command-history-show"),
            (copyButton, #selector(copySelection(_:)), "command-history-copy"),
            (insertButton, #selector(insertSelection(_:)), "command-history-insert"),
            (deleteButton, #selector(deleteSelection(_:)), "command-history-delete"),
            (clearButton, #selector(clearHistory(_:)), "command-history-clear"),
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(id)
        }
        showButton.keyEquivalent = "\r"
        let actions = NSStackView(views: [copyButton, insertButton, showButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        let footer = NSStackView(views: [countLabel, NSView(), deleteButton, clearButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        for view in [searchField, scrollView, emptyLabel, statusLabel, actions, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -32),
            statusLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 36),
            statusLabel.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: searchField.leadingAnchor),
            actions.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        let keyViews: [NSView] = [searchField, table, copyButton, insertButton, showButton, deleteButton, clearButton]
        for index in keyViews.indices { keyViews[index].nextKeyView = keyViews[(index + 1) % keyViews.count] }
    }

    private var selected: TerminalCommandHistoryEntry? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    private func localize() {
        guard panel != nil else { return }
        panel?.title = String(localized: "Command History")
        searchField.placeholderString = String(localized: "Search commands or directories…")
        searchField.setAccessibilityLabel(String(localized: "Search commands or directories…"))
        table.setAccessibilityLabel(String(localized: "Command History"))
        showButton.title = String(localized: "Show Output")
        copyButton.title = String(localized: "Copy Command")
        insertButton.title = String(localized: "Insert into Terminal")
        insertButton.toolTip = String(localized: "Inserts the command without running it.")
        deleteButton.title = String(localized: "Delete")
        clearButton.title = String(localized: "Clear History…")
        reload()
    }

    private func scheduleReload() {
        guard panel?.isVisible == true, !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    private func scheduleSelectionUpdate() {
        guard panel?.isVisible == true, !selectionUpdateScheduled else { return }
        selectionUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.selectionUpdateScheduled = false
            guard self?.panel?.isVisible == true else { return }
            self?.updateSelection()
        }
    }

    private func reload() {
        guard panel != nil else { return }
        let id = selected?.id
        entries = store.search(searchField.stringValue)
        runningStates.removeAll()
        table.reloadData()
        if !entries.isEmpty {
            let row = id.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        emptyLabel.isHidden = !entries.isEmpty
        emptyLabel.stringValue = store.isLoading ? String(localized: "Loading command history…")
            : searchField.stringValue.isEmpty ? String(localized: "Executed commands appear here.")
            : String(localized: "No matching commands.")
        countLabel.stringValue = String(localized: "Commands: \(entries.count)")
        updateSelection()
    }

    private func updateSelection() {
        let visible = table.rows(in: table.visibleRect)
        if visible.location != NSNotFound {
            for row in visible.location..<min(NSMaxRange(visible), entries.count) {
                let entry = entries[row]
                guard entry.finishedAt == nil,
                      let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TerminalCommandHistoryCell else { continue }
                let running = TerminalCommandHistoryActions.isRunning(entry)
                if runningStates[entry.id] != running {
                    runningStates[entry.id] = running
                    cell.configure(entry, isRunning: running)
                }
            }
        }
        let entry = selected
        let session = entry.flatMap { ZshellAutomationRouter.context(forSession: $0.terminalID)?.session }
        if observedSession !== session {
            observedSession = session
            selectionObservation = session?.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.scheduleSelectionUpdate()
            }
        }
        showButton.isEnabled = entry.map(canReveal) ?? false
        copyButton.isEnabled = entry != nil
        insertButton.isEnabled = entry.map(canInsert) ?? false
        deleteButton.isEnabled = entry != nil
        clearButton.isEnabled = !store.entries.isEmpty || store.persistenceError != nil
        statusLabel.toolTip = store.persistenceError
        if store.persistenceError != nil {
            statusLabel.stringValue = String(localized: "Command history could not be loaded or saved.")
        } else if let entry, let session, !session.hasExited {
            statusLabel.stringValue = canReveal(entry)
                ? String(localized: "Select a command to show its original output.")
                : String(localized: "The original output is no longer available.")
            if !canInsert(entry) {
                statusLabel.stringValue += " " + String(localized: "Insertion requires an empty prompt in the original pane.")
            }
        } else if entry != nil {
            statusLabel.stringValue = String(localized: "The original pane is closed. You can still copy the command.")
        } else { statusLabel.stringValue = "" }
        if store.persistenceError == nil {
            statusLabel.toolTip = statusLabel.stringValue.isEmpty ? nil : statusLabel.stringValue
        }
    }

    @objc private func showSelection(_ sender: Any?) {
        if let clickedTable = sender as? NSTableView, clickedTable.clickedRow < 0 { return }
        guard let entry = selected else { return }
        if reveal(entry) { close(restoreFocus: false) }
        else { updateSelection() }
    }

    @objc private func copySelection(_ sender: Any?) {
        guard let entry = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.command, forType: .string)
    }

    @objc private func insertSelection(_ sender: Any?) {
        guard let entry = selected else { return }
        if insert(entry) { close(restoreFocus: false) }
        else { updateSelection() }
    }

    @objc private func deleteSelection(_ sender: Any?) {
        guard let entry = selected else { return }
        store.delete(id: entry.id)
    }

    @objc private func clearHistory(_ sender: Any?) {
        guard let panel else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear Command History?")
        alert.informativeText = String(localized: "This removes Zshell’s saved command history. Terminal output and your shell’s history are kept.")
        alert.addButton(withTitle: String(localized: "Clear History"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.clear()
        }
    }
}

@MainActor
private final class TerminalCommandHistoryPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

extension TerminalCommandHistoryController: NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("command-history-cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? TerminalCommandHistoryCell
            ?? TerminalCommandHistoryCell()
        cell.identifier = id
        let entry = entries[row]
        let running = TerminalCommandHistoryActions.isRunning(entry)
        runningStates[entry.id] = running
        cell.configure(entry, isRunning: running)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func controlTextDidChange(_ notification: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.insertNewline(_:)): showSelection(nil); return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !entries.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(table.selectedRow + delta, 0), entries.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        default: return false
        }
    }
}

@MainActor
private final class TerminalCommandHistoryCell: NSTableCellView {
    private let command = NSTextField(labelWithString: "")
    private let directory = NSTextField(labelWithString: "")
    private let metadata = NSTextField(labelWithString: "")
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    init() {
        super.init(frame: .zero)
        command.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        command.lineBreakMode = .byTruncatingTail
        directory.font = .systemFont(ofSize: 11)
        directory.textColor = .secondaryLabelColor
        directory.lineBreakMode = .byTruncatingMiddle
        metadata.font = .systemFont(ofSize: 11)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        for view in [command, directory, metadata] {
            view.maximumNumberOfLines = 1
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            command.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            command.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            command.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            directory.leadingAnchor.constraint(equalTo: command.leadingAnchor),
            directory.trailingAnchor.constraint(equalTo: command.trailingAnchor),
            directory.topAnchor.constraint(equalTo: command.bottomAnchor, constant: 4),
            metadata.leadingAnchor.constraint(equalTo: command.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: command.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: directory.bottomAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ entry: TerminalCommandHistoryEntry, isRunning: Bool) {
        command.stringValue = entry.command.replacingOccurrences(of: "\n", with: " ↵ ")
        command.toolTip = entry.command
        directory.stringValue = entry.workingDirectory
        Self.dateFormatter.locale = AppLocalization.current.locale
        var parts = [Self.dateFormatter.string(from: entry.startedAt)]
        if let duration = entry.durationNanos {
            let seconds = Double(duration) / 1_000_000_000
            parts.append(String(localized: "Duration: \(seconds.formatted(.number.precision(.fractionLength(0...3)).locale(AppLocalization.current.locale))) s"))
        } else { parts.append(String(localized: "Duration unavailable")) }
        if let code = entry.exitCode { parts.append(String(localized: "Exit: \(code)")) }
        else { parts.append(isRunning ? String(localized: "Running") : String(localized: "Exit status unavailable")) }
        metadata.stringValue = parts.joined(separator: " · ")
        toolTip = [entry.command, entry.workingDirectory, metadata.stringValue].joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(toolTip)
    }
}
