import AppKit
import Combine

@MainActor
final class RemoteHostStore: ObservableObject {
    static let shared = RemoteHostStore()
    @Published private(set) var hosts: [RemoteHost] = []
    private static var fileURL: URL { AppSettings.configURL.deletingLastPathComponent().appendingPathComponent("remote-hosts.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL) {
            hosts = (try? JSONDecoder().decode([RemoteHost].self, from: data)) ?? []
        }
    }

    func save(_ host: RemoteHost) throws {
        var updated = hosts
        if let index = updated.firstIndex(where: { $0.id == host.id }) { updated[index] = host }
        else { updated.append(host) }
        try persist(updated)
    }

    func remove(_ host: RemoteHost) throws { try persist(hosts.filter { $0.id != host.id }) }

    private func persist(_ updated: [RemoteHost]) throws {
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RemoteSessionConnection.writePrivate(updated, to: Self.fileURL)
        hosts = updated
    }
}

@MainActor
final class RemoteHostsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = RemoteHostsController()
    private weak var manager: TerminalManager?
    private let store = RemoteHostStore.shared
    private let table = NSTableView()
    private let nameField = NSTextField(string: "")
    private let addressField = NSTextField(string: "")
    private let executableField = NSTextField(string: "~/.local/bin/zshell-server")
    private let directoryField = NSTextField(string: "~")
    private let nameLabel = NSTextField(labelWithString: "")
    private let addressLabel = NSTextField(labelWithString: "")
    private let executableLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let newButton = NSButton()
    private let saveButton = NSButton()
    private let removeButton = NSButton()
    private let connectButton = NSButton()
    private let openButton = NSButton()
    private let docsButton = NSButton()
    private var editingID: UUID?
    private var busy = false
    private var observation: AnyCancellable?
    private var languageObservation: NSObjectProtocol?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 540, height: 500)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        observation = store.$hosts.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.table.reloadData() }
        }
        languageObservation = NotificationCenter.default.addObserver(forName: AppLocalization.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            assumeMainActor { self.refreshLabels() }
        }
        refreshLabels()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(for manager: TerminalManager) {
        self.manager = manager
        table.reloadData()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 28
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        let grid = NSGridView(views: [[nameLabel, nameField], [addressLabel, addressField],
                                     [executableLabel, executableField], [directoryLabel, directoryField]])
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        for field in [nameField, addressField, executableField, directoryField] { field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        for button in [newButton, saveButton, removeButton, connectButton, openButton, docsButton] { button.bezelStyle = .rounded; button.target = self }
        newButton.action = #selector(newHost)
        saveButton.action = #selector(saveHost)
        removeButton.action = #selector(removeHost)
        connectButton.action = #selector(connectHost)
        openButton.action = #selector(openProject)
        docsButton.action = #selector(openDocumentation)
        let editButtons = NSStackView(views: [newButton, saveButton, removeButton])
        editButtons.spacing = 8
        let connectButtons = NSStackView(views: [connectButton, openButton, docsButton])
        connectButtons.spacing = 8
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [scroll, editButtons, grid, explanation, connectButtons, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func refreshLabels() {
        window?.title = String(localized: "Remote Hosts")
        nameLabel.stringValue = String(localized: "Name")
        addressLabel.stringValue = String(localized: "Address")
        executableLabel.stringValue = String(localized: "Server Executable")
        directoryLabel.stringValue = String(localized: "Remote Directory")
        addressField.placeholderString = String(localized: "ssh://me@devbox or tailscale://devbox:7373")
        newButton.title = String(localized: "Add Host")
        saveButton.title = String(localized: "Save")
        removeButton.title = String(localized: "Remove")
        connectButton.title = String(localized: "Connect Host")
        openButton.title = String(localized: "Open Remote Project")
        docsButton.title = String(localized: "Setup Guide")
        explanation.stringValue = String(localized: "Install zshell-server on the host first. SSH uses your existing keys, agent, and trusted host keys. Remote jobs keep running when Zshell closes.")
        table.setAccessibilityLabel(String(localized: "Remote Hosts"))
        for (field, label) in [(nameField, nameLabel), (addressField, addressLabel),
                               (executableField, executableLabel), (directoryField, directoryLabel)] {
            field.setAccessibilityLabel(label.stringValue)
        }
        updateButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.hosts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.hosts.indices.contains(row) else { return nil }
        let host = store.hosts[row]
        let label = NSTextField(labelWithString: "\(host.name)  ·  \(host.address)")
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = host.address
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard store.hosts.indices.contains(table.selectedRow) else { return }
        let host = store.hosts[table.selectedRow]
        editingID = host.id
        nameField.stringValue = host.name
        addressField.stringValue = host.address
        executableField.stringValue = host.serverPath
        statusLabel.stringValue = ""
        statusLabel.textColor = .secondaryLabelColor
        updateButtons()
    }

    private func hostFromForm() throws -> RemoteHost {
        try RemoteHost(id: editingID ?? UUID(), name: nameField.stringValue,
                       address: addressField.stringValue, serverPath: executableField.stringValue)
    }

    private func updateButtons() {
        for button in [newButton, saveButton, connectButton, openButton] { button.isEnabled = !busy }
        removeButton.isEnabled = !busy && editingID != nil
    }

    @objc private func newHost() {
        editingID = nil
        table.deselectAll(nil)
        nameField.stringValue = ""
        addressField.stringValue = ""
        executableField.stringValue = "~/.local/bin/zshell-server"
        statusLabel.stringValue = ""
        updateButtons()
        window?.makeFirstResponder(nameField)
    }

    @objc private func saveHost() {
        do { let host = try hostFromForm(); try store.save(host); editingID = host.id; statusLabel.stringValue = String(localized: "Host saved."); statusLabel.textColor = .secondaryLabelColor; updateButtons() }
        catch { showError(error) }
    }

    @objc private func removeHost() {
        guard let host = store.hosts.first(where: { $0.id == editingID }) else { return }
        do { try store.remove(host); newHost() } catch { showError(error) }
    }

    @objc private func connectHost() {
        guard let manager else { return }
        do {
            let host = try hostFromForm()
            try store.save(host)
            editingID = host.id
            busy = true; updateButtons()
            statusLabel.stringValue = String(localized: "Connecting…")
            statusLabel.textColor = .secondaryLabelColor
            Task { @MainActor [weak self, weak manager] in
                defer { self?.busy = false; self?.updateButtons() }
                do {
                    let projects = try await Task.detached(priority: .userInitiated) { try RemoteHostClient.catalog(host: host) }.value
                    try manager?.synchronizeRemoteHost(host, projects: projects)
                    self?.statusLabel.stringValue = String(localized: "Connected to \(host.name).")
                } catch { self?.showError(error) }
            }
        } catch { showError(error) }
    }

    @objc private func openProject() {
        guard let manager else { return }
        do {
            let host = try hostFromForm()
            let directory = directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.save(host)
            editingID = host.id
            busy = true; updateButtons()
            statusLabel.stringValue = String(localized: "Connecting…")
            statusLabel.textColor = .secondaryLabelColor
            Task { @MainActor [weak self, weak manager] in
                defer { self?.busy = false; self?.updateButtons() }
                do {
                    let session = try await Task.detached(priority: .userInitiated) { try RemoteHostClient.create(host: host, directory: directory.isEmpty ? "~" : directory) }.value
                    manager?.openSharedProject(host: host, session: session)
                    self?.statusLabel.stringValue = String(localized: "Connected to \(host.name).")
                } catch { self?.showError(error) }
            }
        } catch { showError(error) }
    }

    @objc private func openDocumentation() {
        let language = AppLocalization.current.identifier
        let prefix = language == "zh-Hans" ? "" : language + "/"
        NSWorkspace.shared.open(URL(string: "https://wzz6423.github.io/zshell/\(prefix)docs/remote-sessions")!)
    }

    private func showError(_ error: Error) {
        statusLabel.stringValue = error.localizedDescription
        statusLabel.textColor = .systemRed
    }

    static func endSession(_ session: TerminalSession, relativeTo window: NSWindow?) {
        guard let connection = session.remoteConnection else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "End this remote session?")
        alert.informativeText = String(localized: "This ends the remote shell and all its jobs for every connected client.")
        alert.addButton(withTitle: String(localized: "End Session"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = AppWindowPresentation.hostWindow(relativeTo: window) else { return }
        let host = connection.host
        let directory = connection.projectDirectory
        let id = connection.sessionID
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                do { try await Task.detached(priority: .userInitiated) { try RemoteHostClient.terminate(host: host, directory: directory, sessionID: id) }.value }
                catch {
                    let errorAlert = NSAlert(error: error)
                    _ = await errorAlert.beginSheetModal(for: window)
                }
            }
        }
    }
}
