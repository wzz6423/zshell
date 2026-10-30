import AppKit
import Combine

@MainActor
final class TerminalNotificationCenterController: NSObject {
    static let shared = TerminalNotificationCenterController()
    private let service: TerminalNotificationService
    private(set) var windowController: NSWindowController?

    init(service: TerminalNotificationService? = nil) {
        self.service = service ?? .shared
        super.init()
    }

    func installMenu(in mainMenu: NSMenu) {
        let identifier = NSUserInterfaceItemIdentifier("zshell-notifications-menu")
        let title = String(localized: "Notifications")
        let item = mainMenu.items.first { $0.identifier == identifier }
            ?? NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if item.identifier != identifier { item.identifier = identifier }
        if item.title != title { item.title = title }
        let menu = item.submenu ?? NSMenu(title: title)
        if item.submenu == nil { item.submenu = menu }
        if menu.title != title { menu.title = title }
        let commands: [(String, String, Selector)] = [
            ("notification-history", String(localized: "Notification History…"), #selector(showHistory(_:))),
            ("notification-unread", String(localized: "Show Unread Notifications"), #selector(showUnread(_:))),
        ]
        for (id, title, action) in commands {
            let id = NSUserInterfaceItemIdentifier(id)
            let command = menu.items.first { $0.identifier == id }
                ?? NSMenuItem(title: title, action: action, keyEquivalent: "")
            if command.identifier != id { command.identifier = id }
            if command.title != title { command.title = title }
            if command.target !== self { command.target = self }
            if command.action != action { command.action = action }
            if command.menu == nil { menu.addItem(command) }
        }
        if item.menu == nil {
            let index = mainMenu.items.firstIndex { $0.identifier?.rawValue == "zshell-agents-menu" }
                .map { $0 + 1 } ?? mainMenu.items.count
            mainMenu.insertItem(item, at: index)
        }
    }

    func show(filter: TerminalNotificationHistoryStore.Filter = .all) {
        if windowController == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 680, height: 420)
            panel.level = .normal
            panel.identifier = NSUserInterfaceItemIdentifier("notification-history")
            panel.contentViewController = TerminalNotificationCenterViewController(service: service)
            panel.center()
            windowController = NSWindowController(window: panel)
        }
        guard let window = windowController?.window,
              let controller = window.contentViewController as? TerminalNotificationCenterViewController else { return }
        if let host = TerminalManager.activeWindowManager?.presentationWindow, host !== window {
            AppWindowPresentation.position(window, relativeTo: host, placement: .centered)
        }
        controller.select(filter: filter)
        windowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.table)
    }

    @objc private func showHistory(_ sender: Any?) { show() }
    @objc private func showUnread(_ sender: Any?) { show(filter: .unread) }
}

@MainActor
final class TerminalNotificationCenterViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private let service: TerminalNotificationService
    private let filters = NSSegmentedControl()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton()
    private let readButton = NSButton()
    private let allReadButton = NSButton()
    private let removeButton = NSButton()
    private let clearButton = NSButton()
    private var records: [TerminalNotificationRecord] = []
    private var observations = Set<AnyCancellable>()
    private var topologyObservation: AnyCancellable?

    init(service: TerminalNotificationService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        filters.segmentCount = TerminalNotificationHistoryStore.Filter.allCases.count
        filters.trackingMode = .selectOne
        filters.selectedSegment = 0
        filters.target = self
        filters.action = #selector(filterChanged(_:))
        filters.identifier = NSUserInterfaceItemIdentifier("notification-filter")
        table.headerView = nil
        table.rowHeight = 72
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notification"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(openSelection(_:))
        table.identifier = NSUserInterfaceItemIdentifier("notification-list")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        detailsLabel.font = .systemFont(ofSize: 12)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.maximumNumberOfLines = 2
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.maximumNumberOfLines = 2
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)
        let actions: [(NSButton, Selector, String)] = [
            (openButton, #selector(openSelection(_:)), "notification-open"),
            (readButton, #selector(markSelectionRead(_:)), "notification-mark-read"),
            (allReadButton, #selector(markAllRead(_:)), "notification-mark-all-read"),
            (removeButton, #selector(removeSelection(_:)), "notification-remove"),
            (clearButton, #selector(clearHistory(_:)), "notification-clear"),
        ]
        for (button, action, id) in actions {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.identifier = NSUserInterfaceItemIdentifier(id)
        }
        openButton.keyEquivalent = "\r"
        // One left-aligned row; the panel's minimum width keeps every button at its natural size.
        let actionsRow = NSStackView(views: [openButton, readButton, allReadButton, removeButton, clearButton])
        actionsRow.spacing = 8
        actionsRow.detachesHiddenViews = true
        actionsRow.setHuggingPriority(.required, for: .horizontal)
        for button in [openButton, readButton, allReadButton, removeButton, clearButton] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        countLabel.alignment = .right
        for child in [filters, countLabel, scroll, emptyLabel, detailsLabel, errorLabel, actionsRow] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            filters.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            filters.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            countLabel.centerYAnchor.constraint(equalTo: filters.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: filters.trailingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: detailsLabel.topAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
            detailsLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            detailsLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            detailsLabel.heightAnchor.constraint(equalToConstant: 34),
            detailsLabel.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -4),
            errorLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            errorLabel.heightAnchor.constraint(equalToConstant: 28),
            errorLabel.bottomAnchor.constraint(equalTo: actionsRow.topAnchor, constant: -8),
            actionsRow.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            actionsRow.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            actionsRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
        ])
        service.history.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: AppLocalization.didChange).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.localize() }.store(in: &observations)
        localize()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.title = String(localized: "Notification History")
        reload()
    }

    func select(filter: TerminalNotificationHistoryStore.Filter) {
        _ = view
        filters.selectedSegment = filter.rawValue
        reload()
    }

    private var selected: TerminalNotificationRecord? {
        records.indices.contains(table.selectedRow) ? records[table.selectedRow] : nil
    }

    private func localize() {
        view.window?.title = String(localized: "Notification History")
        for (index, title) in [String(localized: "All"), String(localized: "Unread"),
                              String(localized: "Failed"), String(localized: "Pending")].enumerated() {
            filters.setLabel(title, forSegment: index)
        }
        filters.setAccessibilityLabel(String(localized: "Notification filter"))
        table.setAccessibilityLabel(String(localized: "Notification History"))
        openButton.title = String(localized: "Show Pane")
        readButton.title = String(localized: "Mark as Read")
        allReadButton.title = String(localized: "Mark All as Read")
        removeButton.title = String(localized: "Remove")
        clearButton.title = String(localized: "Clear History")
        reload()
    }

    private func reload() {
        guard isViewLoaded else { return }
        let selectedID = selected?.id
        records = service.history.filtered(.init(rawValue: filters.selectedSegment) ?? .all)
        table.reloadData()
        if let index = selectedID.flatMap({ id in records.firstIndex { $0.id == id } }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        emptyLabel.isHidden = !records.isEmpty
        // Alternating stripes behind an empty list read as a stray gray block under the empty-state text.
        table.usesAlternatingRowBackgroundColors = !records.isEmpty
        emptyLabel.stringValue = service.history.isLoading ? String(localized: "Loading notifications…")
            : String(localized: "No notifications in this filter.")
        countLabel.stringValue = String(localized: "Notifications: \(records.count)")
        errorLabel.stringValue = service.history.persistenceError == nil ? ""
            : String(localized: "Notification history could not be loaded or saved.")
        allReadButton.isEnabled = service.history.records.contains { !$0.isRead }
        clearButton.isEnabled = !service.history.records.isEmpty
        updateSelection()
    }

    private func updateSelection() {
        let record = selected
        readButton.isEnabled = record?.isRead == false
        removeButton.isHidden = record == nil
        openButton.isEnabled = record != nil
        topologyObservation = record.flatMap { TerminalManager.notificationContext(for: $0.target)?.manager }
            .map { manager in
                manager.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateDetails() }
            }
        updateDetails()
    }

    private func updateDetails() {
        guard let record = selected else { detailsLabel.stringValue = ""; return }
        let unavailable = !TerminalManager.notificationAvailable(for: record.target)
        let context = [record.target.remoteHostName, record.target.projectName, record.target.tabName]
            .compactMap { $0 }.joined(separator: " · ")
        detailsLabel.stringValue = [context, unavailable ? String(localized: "This pane is closed or unavailable.") : ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("notification-row")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? TerminalNotificationCell
            ?? TerminalNotificationCell()
        cell.identifier = id
        cell.update(records[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    @objc private func filterChanged(_ sender: Any?) { reload() }

    @objc private func openSelection(_ sender: Any?) {
        guard let record = selected else { return }
        if service.open(id: record.id) { view.window?.orderOut(nil) }
        else { detailsLabel.stringValue = String(localized: "This pane is closed or unavailable.") }
    }

    @objc private func markSelectionRead(_ sender: Any?) {
        if let record = selected { service.markRead(id: record.id) }
    }
    @objc private func markAllRead(_ sender: Any?) { service.markAllRead() }
    @objc private func removeSelection(_ sender: Any?) {
        if let record = selected { service.remove(id: record.id) }
    }
    @objc private func clearHistory(_ sender: Any?) { service.clear() }
}

@MainActor
private final class TerminalNotificationCell: NSTableCellView {
    private let message = NSTextField(labelWithString: "")
    private let context = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        message.lineBreakMode = .byTruncatingTail
        context.lineBreakMode = .byTruncatingMiddle
        context.font = .systemFont(ofSize: 11)
        context.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        for child in [message, context, status] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            message.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            context.leadingAnchor.constraint(equalTo: message.leadingAnchor),
            context.trailingAnchor.constraint(equalTo: message.trailingAnchor),
            context.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 3),
            status.leadingAnchor.constraint(equalTo: message.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: message.trailingAnchor),
            status.topAnchor.constraint(equalTo: context.bottomAnchor, constant: 3),
        ])
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ record: TerminalNotificationRecord) {
        message.stringValue = record.message
        message.font = .systemFont(ofSize: 13, weight: record.isRead ? .regular : .semibold)
        context.stringValue = [record.target.remoteHostName, record.target.projectName, record.target.tabName]
            .compactMap { $0 }.joined(separator: " · ")
        var states = [record.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(AppLocalization.current.locale))]
        if !record.isRead { states.append(String(localized: "Unread")) }
        if record.isFailure { states.append(String(localized: "Failed")) }
        if record.isPending { states.append(String(localized: "Pending")) }
        status.stringValue = states.joined(separator: " · ")
        status.textColor = record.isFailure ? .systemRed : .secondaryLabelColor
        toolTip = [message.stringValue, context.stringValue, status.stringValue].joined(separator: "\n")
        setAccessibilityLabel(toolTip)
    }
}
