import AppKit
import Combine

@MainActor
final class SSHConfigHostPickerController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let source: @Sendable () throws -> SSHConfigHosts
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let chooseButton = NSButton()
    private let cancelButton = NSButton()
    private var panel: NSPanel?
    private weak var owner: NSWindow?
    private var completion: ((String?) -> Void)?
    private var hosts: [String] = []
    private var rows: [String] = []
    private var loading = false
    private var failure: (any Error)?
    private var revision = UUID()
    private var task: Task<Void, Never>?
    private var readerTask: Task<[String], any Error>?
    private var languageObservation: AnyCancellable?
    private var ownerObservation: AnyCancellable?

    init(source: @escaping @Sendable () throws -> SSHConfigHosts = { try SSHConfigHosts.configured() }) {
        self.source = source
        super.init()
        languageObservation = NotificationCenter.default.publisher(for: AppLocalization.didChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.localize() }
    }

    func present(on owner: NSWindow, selecting host: String, completion: @escaping (String?) -> Void) {
        close()
        if panel == nil { configure() }
        guard let panel else { return }
        self.owner = owner
        self.completion = completion
        ownerObservation = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: owner)
            .sink { [weak self] _ in self?.close() }
        hosts = []
        rows = []
        loading = true
        failure = nil
        searchField.stringValue = ""
        revision = UUID()
        let current = revision
        localize()
        table.reloadData()
        owner.beginSheet(panel) { [weak self] _ in
            guard let self, self.revision == current else { return }
            self.close()
        }
        panel.makeFirstResponder(searchField)
        let source = source
        let reader = Task.detached(priority: .userInitiated) { try source().read() }
        readerTask = reader
        task = Task { [weak self] in
            let result = await reader.result
            guard !Task.isCancelled, let self, self.revision == current, self.owner != nil else { return }
            self.loading = false
            switch result {
            case .success(let hosts):
                self.hosts = hosts
                self.filter(selecting: host)
            case .failure(let error):
                if !(error is CancellationError) { self.failure = error }
                self.updateStatus()
            }
            self.readerTask = nil
            self.task = nil
        }
    }

    func close() { finish(nil) }

    private func finish(_ host: String?) {
        revision = UUID()
        readerTask?.cancel()
        task?.cancel()
        readerTask = nil
        task = nil
        let completion = completion
        self.completion = nil
        ownerObservation = nil
        if let panel, let owner = panel.sheetParent { owner.endSheet(panel) }
        panel?.orderOut(nil)
        owner = nil
        completion?(host)
    }

    func windowWillClose(_ notification: Notification) { close() }

    private func configure() {
        let panel = SSHConfigHostPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 350),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.identifier = NSUserInterfaceItemIdentifier("ssh-config-host-picker")
        self.panel = panel
        guard let content = panel.contentView else { return }
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityIdentifier("ssh-config-host-search")
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(chooseHost(_:))
        table.rowHeight = 28
        table.headerView = nil
        table.intercellSpacing = .zero
        table.allowsEmptySelection = true
        table.setAccessibilityIdentifier("ssh-config-host-list")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseHost(_:))
        chooseButton.keyEquivalent = "\r"
        chooseButton.setAccessibilityIdentifier("ssh-config-host-choose")
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancelButton, chooseButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for view in [searchField, scroll, statusLabel, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
            statusLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 32),
            statusLabel.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: searchField.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func localize() {
        panel?.title = String(localized: "SSH Config Hosts")
        searchField.placeholderString = String(localized: "Search SSH hosts")
        searchField.setAccessibilityLabel(String(localized: "Search SSH hosts"))
        table.setAccessibilityLabel(String(localized: "SSH Config Hosts"))
        chooseButton.title = String(localized: "Choose")
        cancelButton.title = String(localized: "Cancel")
        updateStatus()
    }

    private func filter(selecting host: String? = nil) {
        let selected = host ?? selectedHost
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = query.isEmpty ? hosts : hosts.filter { $0.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if let selected, let index = rows.firstIndex(of: selected) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateStatus()
    }

    private var selectedHost: String? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    private func updateStatus() {
        chooseButton.isEnabled = !loading && failure == nil && selectedHost != nil
        statusLabel.textColor = failure == nil ? .secondaryLabelColor : .systemRed
        if let failure {
            statusLabel.stringValue = failure.localizedDescription
        } else if loading {
            statusLabel.stringValue = String(localized: "Reading SSH configuration")
        } else if hosts.isEmpty {
            statusLabel.stringValue = String(localized: "No named hosts found in the SSH configuration.")
        } else if rows.isEmpty {
            statusLabel.stringValue = String(localized: "No matching hosts.")
        } else {
            statusLabel.stringValue = ""
        }
    }

    @objc private func chooseHost(_ sender: Any?) {
        guard chooseButton.isEnabled, let host = selectedHost else { return }
        finish(host)
    }

    @objc private func cancel(_ sender: Any?) { close() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ssh-config-host")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = rows[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateStatus() }
    func controlTextDidChange(_ notification: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            guard !rows.isEmpty else { return true }
            let row = min(table.selectedRow + 1, rows.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !rows.isEmpty else { return true }
            let row = max(table.selectedRow - 1, 0)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            chooseHost(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}

@MainActor
private final class SSHConfigHostPickerPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
