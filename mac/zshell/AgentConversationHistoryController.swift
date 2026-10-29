import AppKit
import Combine

@MainActor
final class AgentConversationHistoryController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static let shared = AgentConversationHistoryController()
    private let store = AgentConversationHistoryStore.shared
    private weak var manager: TerminalManager?
    private weak var hostWindow: NSWindow?
    private var panel: NSPanel?
    private let searchField = NSSearchField()
    private let filters = NSSegmentedControl()
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let resumeButton = NSButton()
    private let forkButton = NSButton()
    private let forkMenuItem = NSMenuItem()
    private let archiveButton = NSButton()
    private let deleteButton = NSButton()
    private var entries: [AgentConversationHistoryRecord] = []
    private var observations: [AnyCancellable] = []
    private var managerObservation: AnyCancellable?
    private var forkTask: Task<Void, Never>?
    private var forkTaskID: UUID?

    private override init() {
        super.init()
        store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: AppLocalization.didChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.localize() }
            .store(in: &observations)
    }

    func installMenu(in mainMenu: NSMenu) {
        let identifier = NSUserInterfaceItemIdentifier("zshell-agents-menu")
        let title = String(localized: "Agents")
        let item = mainMenu.items.first { $0.identifier == identifier }
            ?? NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if item.identifier != identifier { item.identifier = identifier }
        if item.title != title { item.title = title }
        let menu = item.submenu ?? NSMenu(title: title)
        if item.submenu == nil { item.submenu = menu }
        if menu.title != title { menu.title = title }
        let commands: [(String, String, Selector)] = [
            ("agent-attention", String(localized: "Next Agent Needing Attention"), #selector(focusNextAgent(_:))),
            ("agent-conversation-history", String(localized: "Agent Conversation History"), #selector(showHistoryFromMenu(_:))),
            ("agent-conversation-history-search", String(localized: "Search All Agent Conversations"), #selector(searchAllFromMenu(_:))),
        ]
        for (id, title, action) in commands {
            let identifier = NSUserInterfaceItemIdentifier(id)
            let command = menu.items.first { $0.identifier == identifier }
                ?? NSMenuItem(title: title, action: action, keyEquivalent: id == "agent-attention" ? "a" : "")
            if command.identifier != identifier { command.identifier = identifier }
            if command.target !== self { command.target = self }
            if command.action != action { command.action = action }
            if id == "agent-attention", command.keyEquivalentModifierMask != [.command, .shift] {
                command.keyEquivalentModifierMask = [.command, .shift]
            }
            if command.title != title { command.title = title }
            if command.menu == nil { menu.addItem(command) }
        }
        if item.menu == nil {
            let index = mainMenu.items.firstIndex { $0.title == String(localized: "Browser") }
                .map { $0 + 1 } ?? mainMenu.items.count
            mainMenu.insertItem(item, at: index)
        }
    }

    func show(for manager: TerminalManager, filter: AgentConversationHistoryStore.Filter) {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow) else { return }
        if panel == nil { configure() }
        guard let panel else { return }
        hostWindow?.removeChildWindow(panel)
        if self.manager !== manager { forkTask?.cancel(); forkTask = nil; forkTaskID = nil }
        self.manager = manager
        hostWindow = host
        managerObservation = manager.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateSelection()
        }
        filters.selectedSegment = filter.rawValue
        searchField.stringValue = ""
        statusLabel.stringValue = ""
        localize()
        let origin = NSPoint(x: host.frame.midX - panel.frame.width / 2,
                             y: host.frame.midY - panel.frame.height / 2)
        panel.setFrameOrigin(origin)
        host.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func close(ifOwnedBy manager: TerminalManager? = nil) {
        if let manager, self.manager !== manager { return }
        forkTask?.cancel()
        forkTask = nil
        forkTaskID = nil
        if let panel { hostWindow?.removeChildWindow(panel); panel.close() }
        self.manager = nil
        hostWindow = nil
        managerObservation = nil
    }

    func windowWillClose(_ notification: Notification) {
        forkTask?.cancel()
        forkTask = nil
        forkTaskID = nil
        if let panel { hostWindow?.removeChildWindow(panel) }
        managerObservation = nil
        manager = nil
        hostWindow = nil
    }

    private func configure() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 520, height: 440)
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("agent-conversation-history")
        panel.level = .normal
        self.panel = panel
        guard let content = panel.contentView else { return }

        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        filters.segmentCount = AgentConversationHistoryStore.Filter.allCases.count
        filters.trackingMode = .selectOne
        filters.target = self
        filters.action = #selector(filterChanged(_:))

        table.headerView = nil
        table.rowHeight = 68
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(resumeSelection(_:))
        let menu = NSMenu()
        forkMenuItem.target = self
        forkMenuItem.action = #selector(forkSelection(_:))
        menu.addItem(forkMenuItem)
        table.menu = menu
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        detailsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailsLabel.isSelectable = true
        detailsLabel.maximumNumberOfLines = 4
        detailsLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .systemRed
        statusLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.lineBreakMode = .byTruncatingTail
        for (button, action) in [(resumeButton, #selector(resumeSelection(_:))),
                                 (forkButton, #selector(forkSelection(_:))),
                                 (archiveButton, #selector(archiveSelection(_:))),
                                 (deleteButton, #selector(deleteSelection(_:)))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        resumeButton.keyEquivalent = "\r"
        forkButton.image = NSImage(systemSymbolName: "arrow.branch", accessibilityDescription: nil)
        forkButton.imagePosition = .imageOnly
        let actions = NSStackView(views: [countLabel, NSView(), forkButton, deleteButton, archiveButton, resumeButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        for view in [searchField, filters, scrollView, emptyLabel, detailsLabel, statusLabel, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            filters.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            filters.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: detailsLabel.topAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -32),
            detailsLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            detailsLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            detailsLabel.heightAnchor.constraint(equalToConstant: 64),
            detailsLabel.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 32),
            statusLabel.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -10),
            actions.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private var selected: AgentConversationHistoryRecord? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    private func localize() {
        panel?.title = String(localized: "Agent Conversation History")
        searchField.placeholderString = String(localized: "Search conversations…")
        searchField.setAccessibilityLabel(String(localized: "Search conversations…"))
        for (index, label) in [String(localized: "Recent"), String(localized: "All"), String(localized: "Archived")].enumerated() {
            filters.setLabel(label, forSegment: index)
        }
        filters.setAccessibilityLabel(String(localized: "Conversation history filter"))
        table.setAccessibilityLabel(String(localized: "Agent Conversation History"))
        deleteButton.title = String(localized: "Delete…")
        let forkTitle = String(localized: "Fork Conversation in New Pane")
        forkButton.toolTip = forkTitle
        forkButton.setAccessibilityLabel(forkTitle)
        forkMenuItem.title = forkTitle
        reload()
    }

    private func reload() {
        guard panel != nil else { return }
        let selectedID = selected?.id
        let filter = AgentConversationHistoryStore.Filter(rawValue: filters.selectedSegment) ?? .recent
        entries = store.search(searchField.stringValue, filter: filter)
        table.reloadData()
        if !entries.isEmpty {
            let row = selectedID.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        emptyLabel.isHidden = !entries.isEmpty
        emptyLabel.stringValue = searchField.stringValue.isEmpty
            ? String(localized: "Conversations appear after a supported agent reports its session.")
            : String(localized: "No matching conversations.")
        countLabel.stringValue = String(localized: "Conversations: \(entries.count)")
        if store.persistenceError != nil {
            statusLabel.stringValue = String(localized: "Conversation history could not be loaded or saved.")
            statusLabel.toolTip = store.persistenceError
        } else if statusLabel.toolTip != nil {
            statusLabel.stringValue = ""
            statusLabel.toolTip = nil
        }
        updateSelection()
    }

    private func updateSelection() {
        let record = selected
        resumeButton.isEnabled = record != nil && forkTask == nil
        forkButton.isEnabled = record != nil && forkTask == nil
        archiveButton.isEnabled = record != nil && forkTask == nil
        deleteButton.isEnabled = record != nil && forkTask == nil
        resumeButton.title = record.flatMap(TerminalManager.openConversation) == nil
            ? String(localized: "Resume Conversation") : String(localized: "Show Conversation")
        archiveButton.title = record?.isArchived == true ? String(localized: "Unarchive") : String(localized: "Archive")
        guard let record else { detailsLabel.stringValue = ""; return }
        var details = [record.identity.provider.displayName + " · " + record.identity.sessionID,
                       String(localized: "Working Directory") + ": " + record.identity.workingDirectory]
        if let config = record.identity.configDirectory {
            details.append(String(localized: "Configuration Directory") + ": " + config)
        }
        if let file = record.identity.sessionFile { details.append(String(localized: "Session File") + ": " + file) }
        detailsLabel.stringValue = details.joined(separator: "\n")
        detailsLabel.toolTip = detailsLabel.stringValue
    }

    @objc private func filterChanged(_ sender: Any?) { statusLabel.stringValue = ""; reload() }

    @objc func showHistoryFromMenu(_ sender: Any?) {
        TerminalManager.activeWindowManager?.showConversationHistory()
    }

    @objc func searchAllFromMenu(_ sender: Any?) {
        TerminalManager.activeWindowManager?.showConversationHistory(all: true)
    }

    @objc private func focusNextAgent(_ sender: Any?) {
        TerminalManager.activeWindowManager?.focusNextAgentAttention()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === forkMenuItem {
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            return entries.indices.contains(row) && forkTask == nil && manager != nil
        }
        if menuItem.action == #selector(focusNextAgent(_:)) {
            return TerminalManager.activeWindowManager?.hasAgentAttention == true
        }
        return TerminalManager.activeWindowManager != nil
    }

    @objc private func forkSelection(_ sender: Any?) {
        if sender as? NSMenuItem === forkMenuItem, entries.indices.contains(table.clickedRow) {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
        guard forkTask == nil, let record = selected, let manager else { return }
        statusLabel.stringValue = String(localized: "Forking conversation…")
        let taskID = UUID()
        forkTaskID = taskID
        forkTask = Task { @MainActor [weak self] in
            do {
                _ = try await manager.forkConversation(id: record.id, focus: true)
                guard !Task.isCancelled, self?.forkTaskID == taskID else { return }
                self?.close()
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.forkTaskID == taskID else { return }
                self.statusLabel.stringValue = error.localizedDescription
            }
            guard let self, self.forkTaskID == taskID else { return }
            self.forkTaskID = nil
            self.forkTask = nil
            self.updateSelection()
        }
        updateSelection()
    }

    @objc private func resumeSelection(_ sender: Any?) {
        guard forkTask == nil, let record = selected, let manager else { return }
        if record.identity.remoteHostID != nil {
            statusLabel.stringValue = String(localized: "Connecting…")
            Task { @MainActor [weak self] in
                do {
                    _ = try await manager.resumeRemoteConversation(id: record.id, focus: true)
                    self?.close()
                } catch { self?.statusLabel.stringValue = error.localizedDescription }
            }
            return
        }
        do {
            _ = try manager.resumeConversation(id: record.id, focus: true)
            close()
        } catch { statusLabel.stringValue = error.localizedDescription }
    }

    @objc private func archiveSelection(_ sender: Any?) {
        guard let record = selected else { return }
        do { try store.setArchived(!record.isArchived, id: record.id); statusLabel.stringValue = "" }
        catch { statusLabel.stringValue = error.localizedDescription }
    }

    @objc private func deleteSelection(_ sender: Any?) {
        guard let record = selected, let panel else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete this conversation history record?")
        alert.informativeText = String(localized: "The provider’s conversation files are kept. You can still resume the conversation using the provider’s CLI.")
        alert.addButton(withTitle: String(localized: "Delete History Record"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.store.delete(id: record.id); self.statusLabel.stringValue = "" }
            catch { self.statusLabel.stringValue = error.localizedDescription }
        }
    }
}

extension AgentConversationHistoryController: NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("history-row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ConversationHistoryCell
            ?? ConversationHistoryCell()
        cell.identifier = identifier
        let record = entries[row]
        let date = DateFormatter()
        date.locale = AppLocalization.current.locale
        date.dateStyle = .medium
        date.timeStyle = .short
        let state = TerminalManager.openConversation(record) != nil
            ? String(localized: "Open Conversation")
            : record.isArchived ? String(localized: "Archived") : String(localized: "Saved Conversation")
        cell.configure(title: record.displayTitle,
                       metadata: [record.identity.provider.displayName, record.projectName, state, date.string(from: record.updatedAt)].joined(separator: " · "),
                       directory: record.identity.workingDirectory)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func controlTextDidChange(_ notification: Notification) { statusLabel.stringValue = ""; reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard !entries.isEmpty else { return true }
            let delta = command == #selector(NSResponder.moveUp(_:)) ? -1 : 1
            let row = min(max(table.selectedRow + delta, 0), entries.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)): resumeSelection(nil); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }
}

private final class ConversationHistoryCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        directoryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        directoryLabel.textColor = .secondaryLabelColor
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        for label in [titleLabel, metadataLabel, directoryLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 1
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            ])
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            metadataLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            directoryLabel.topAnchor.constraint(equalTo: metadataLabel.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, metadata: String, directory: String) {
        titleLabel.stringValue = title
        metadataLabel.stringValue = metadata
        directoryLabel.stringValue = directory
        toolTip = [title, metadata, directory].joined(separator: "\n")
    }
}
