//
//  SSHProjectController.swift
//  zshell
//

import AppKit
import Combine

/// One saved SSH project: the connection fields plus the remote directory it
/// opens. Persisted next to `quick-launch.json` so the dialog's list survives
/// relaunches; groups are free-form labels the list sections by.
struct SSHProjectEntry: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var user: String?
    var host: String
    var port: Int?
    var directory: String?
    var group: String?
    var authentication: SSHAuthentication

    init(
        id: UUID = UUID(),
        name: String,
        user: String?,
        host: String,
        port: Int?,
        directory: String?,
        group: String?,
        authentication: SSHAuthentication = .agent
    ) {
        self.id = id
        self.name = name
        self.user = user
        self.host = host
        self.port = port
        self.directory = directory
        self.group = group
        self.authentication = authentication
    }

    /// `user@host:port`, the connection summary shown under the name.
    var destination: String {
        var target = user.map { "\($0)@\(host)" } ?? host
        if let port { target += ":\(port)" }
        return target
    }

    /// A blank name falls back to the destination, so the list never shows an
    /// unlabeled row.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? destination : trimmed
    }

    var symbolName: String { "network" }
}

extension SSHProjectEntry {
    private enum CodingKeys: String, CodingKey {
        case id, name, user, host, port, directory, group, authentication
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            user: try container.decodeIfPresent(String.self, forKey: .user),
            host: try container.decode(String.self, forKey: .host),
            port: try container.decodeIfPresent(Int.self, forKey: .port),
            directory: try container.decodeIfPresent(String.self, forKey: .directory),
            group: try container.decodeIfPresent(String.self, forKey: .group),
            authentication: try container.decodeIfPresent(
                SSHAuthentication.self, forKey: .authentication
            ) ?? .agent
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(user, forKey: .user)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(port, forKey: .port)
        try container.encodeIfPresent(directory, forKey: .directory)
        try container.encodeIfPresent(group, forKey: .group)
        if authentication != .agent {
            try container.encode(authentication, forKey: .authentication)
        }
    }
}

/// The saved SSH projects, persisted as JSON under the same Debug/Release-
/// separated directory as `QuickLaunchStore` (`~/.config/zshell/` vs
/// `~/.config/zshell-dev/`). Mirrors its file approach.
@MainActor
final class SSHProjectStore: ObservableObject {
    static let shared = SSHProjectStore()

    @Published private(set) var entries: [SSHProjectEntry] = []

    static var fileURL: URL {
        AppSettings.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("ssh-projects.json")
    }

    private init() {
        entries = Self.load()
    }

    func add(_ entry: SSHProjectEntry) {
        entries.append(entry)
        save()
    }

    func update(_ entry: SSHProjectEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func remove(_ entry: SSHProjectEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
        SSHCredentialStore.shared.remove(entry.id)
    }

    private func save() {
        let url = Self.fileURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("zshell: failed to write \(url.path): \(error)")
        }
    }

    private static func load() -> [SSHProjectEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([SSHProjectEntry].self, from: data)
        } catch {
            // A hand-edited or outdated file degrades to an empty list rather
            // than blocking the dialog; the next save overwrites it.
            NSLog("zshell: failed to read \(fileURL.path): \(error)")
            return []
        }
    }
}

/// The SSH project dialog keeps saved-project browsing separate from editing,
/// so the next action is clear without losing grouped rows or one-click
/// connect/edit/delete controls.
@MainActor
final class SSHProjectController: NSObject {
    static let shared = SSHProjectController()

    private static let windowWidth: CGFloat = 500
    private static let listHeight: CGFloat = 210
    private static let listContentHeight: CGFloat = 278
    private static let rowHeight: CGFloat = 34
    private static let headerHeight: CGFloat = 26
    private static let fallbackFormContentHeight: CGFloat = 240
    private static let formFieldCornerRadius: CGFloat = 6

    private weak var manager: TerminalManager?
    private var window: NSWindow?
    private weak var hostWindow: NSWindow?

    // A table subclass: without it the table claims every mouse-down
    // (including ones on the rows' buttons), so the row's edit/delete
    // buttons could never receive a click.
    private let tableView = RowButtonTableView()
    private let scrollView = NSScrollView()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let listContainer = NSView()
    private let formContainer = NSView()

    private let groupField = NSComboBox()
    private let hostField = NSTextField()
    private let userField = NSTextField()
    private let portField = NSTextField()
    private let directoryField = NSTextField()
    private let authenticationField = NSPopUpButton()
    private let passwordField = NSSecureTextField()
    private let privateKeyPathField = NSTextField()
    private let privateKeyContentField = NSTextView()
    private let privateKeyContentScrollView = NSScrollView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let newButton = NSButton(title: "", target: nil, action: nil)
    private let connectButton = NSButton(title: "", target: nil, action: nil)
    private var formStack: NSStackView?
    private var formGrid: NSGridView?
    private var passwordRow: NSGridRow?
    private var privateKeyPathRow: NSGridRow?
    private var privateKeyContentRow: NSGridRow?

    /// The entry being edited, if the form was filled from a row's edit
    /// button; saving replaces it instead of appending.
    private var editingEntryID: UUID?

    /// Window-base location of the last mouse-down, recorded by a local
    /// monitor so the row's connect action can tell the row's edit/delete
    /// button clicks from plain row clicks.
    private var lastMouseDownLocation: NSPoint?
    private var mouseDownMonitor: Any?

    private enum DisplayRow {
        case header(String)
        case entry(SSHProjectEntry)
    }

    /// Rows as they appear in the table — grouped sections when at least one
    /// entry carries a group, otherwise the saved order.
    private var displayRows: [DisplayRow] = []

    private enum DisplayMode: Equatable {
        case savedProjects
        case form
    }

    private var displayMode: DisplayMode = .savedProjects

    private var selectedEntry: SSHProjectEntry? {
        let row = tableView.selectedRow
        guard displayRows.indices.contains(row), case .entry(let entry) = displayRows[row] else { return nil }
        return entry
    }

    private override init() {
        super.init()
        SSHProjectStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reloadList() }
        }.store(in: &lifetime)
    }

    private var lifetime: [AnyCancellable] = []

    func present(for manager: TerminalManager) {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow) else { return }
        self.manager = manager
        hostWindow = host
        let window = self.window ?? makeWindow()
        self.window = window

        showSavedProjects()
        AppWindowPresentation.attach(window, to: host, placement: .centered)
        window.makeKeyAndOrderFront(nil)
        focusSavedProjects()
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.windowWidth,
                height: Self.listContentHeight
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "New SSH Project")
        window.isReleasedWhenClosed = false

        let content = NSView()
        window.contentView = content

        buildList(in: content)
        buildForm(in: content)
        applyDisplayMode(resizeWindow: false)

        if mouseDownMonitor == nil {
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                if event.window === self?.window {
                    self?.lastMouseDownLocation = event.locationInWindow
                }
                return event
            }
        }

        return window
    }

    private func buildList(in content: NSView) {
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(listContainer)
        NSLayoutConstraint.activate([
            listContainer.topAnchor.constraint(equalTo: content.topAnchor),
            listContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.style = .fullWidth
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        // One click on a row connects — the dialog's primary "one-click
        // invoke"; the row's trailing buttons handle edit and delete.
        tableView.action = #selector(rowClicked)
        tableView.setAccessibilityLabel(String(
            localized: "Saved SSH Projects",
            comment: "Accessibility label of the saved SSH project list."
        ))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        column.width = Self.windowWidth
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(scrollView)

        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(emptyStateLabel)

        let listBorder = HairlineBox()
        listBorder.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listBorder)

        newButton.title = String(
            localized: "New",
            comment: "Button opening the SSH project form."
        )
        newButton.bezelStyle = .rounded
        newButton.controlSize = .small
        newButton.target = self
        newButton.action = #selector(newClicked)

        connectButton.title = String(
            localized: "Connect",
            comment: "Button connecting the selected saved SSH project."
        )
        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .small
        connectButton.target = self
        connectButton.action = #selector(connectSelectedClicked)

        let buttonRow = NSStackView(views: [newButton, NSView(), connectButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            listBorder.topAnchor.constraint(
                equalTo: listContainer.topAnchor, constant: 16
            ),
            listBorder.leadingAnchor.constraint(
                equalTo: listContainer.leadingAnchor, constant: 16
            ),
            listBorder.trailingAnchor.constraint(
                equalTo: listContainer.trailingAnchor, constant: -16
            ),
            listBorder.heightAnchor.constraint(equalToConstant: Self.listHeight),
            scrollView.topAnchor.constraint(equalTo: listBorder.topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: listBorder.bottomAnchor, constant: -1),
            scrollView.leadingAnchor.constraint(equalTo: listBorder.leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: listBorder.trailingAnchor, constant: -1),
            emptyStateLabel.centerXAnchor.constraint(equalTo: listBorder.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: listBorder.centerYAnchor),
            buttonRow.topAnchor.constraint(equalTo: listBorder.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: -16),
        ])
    }

    private func buildForm(in content: NSView) {
        formContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(formContainer)
        NSLayoutConstraint.activate([
            formContainer.topAnchor.constraint(equalTo: content.topAnchor),
            formContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            formContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            formContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        groupField.placeholderString = String(
            localized: "Optional, e.g. Production",
            comment: "Placeholder of the SSH project group field."
        )
        groupField.isEditable = true
        groupField.completes = true
        groupField.numberOfVisibleItems = 6
        groupField.bezelStyle = .roundedBezel
        groupField.controlSize = .regular
        groupField.isButtonBordered = true
        groupField.delegate = self
        hostField.placeholderString = String(
            localized: "example.com",
            comment: "Placeholder of the SSH host field."
        )
        userField.placeholderString = NSUserName()
        portField.placeholderString = "22"
        directoryField.placeholderString = "~/project"
        authenticationField.addItems(withTitles: [
            String(localized: "SSH Agent", comment: "SSH project authentication method."),
            String(localized: "Password", comment: "SSH project authentication method."),
            String(localized: "Private Key File", comment: "SSH project authentication method."),
            String(localized: "Private Key Text", comment: "SSH project authentication method."),
        ])
        authenticationField.target = self
        authenticationField.action = #selector(authenticationChanged)
        passwordField.placeholderString = String(
            localized: "Saved in Keychain",
            comment: "Placeholder for a previously saved SSH password."
        )
        privateKeyPathField.placeholderString = "~/.ssh/id_ed25519"
        privateKeyContentField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        privateKeyContentField.isRichText = false
        privateKeyContentField.isAutomaticQuoteSubstitutionEnabled = false
        privateKeyContentField.isAutomaticDashSubstitutionEnabled = false
        privateKeyContentScrollView.documentView = privateKeyContentField
        privateKeyContentScrollView.hasVerticalScroller = true
        privateKeyContentScrollView.borderType = .bezelBorder
        privateKeyContentScrollView.translatesAutoresizingMaskIntoConstraints = false
        privateKeyContentScrollView.heightAnchor.constraint(equalToConstant: 84).isActive = true

        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true

        let formHeader = NSTextField(labelWithString: String(
            localized: "Connection",
            comment: "Header above the SSH connection form."
        ))
        formHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        formHeader.textColor = .secondaryLabelColor

        let privateKeyPathRow = NSStackView(views: [
            privateKeyPathField,
            NSButton(
                image: NSImage(systemSymbolName: "folder", accessibilityDescription: String(
                    localized: "Choose Private Key File",
                    comment: "Accessibility label for the button choosing an SSH private key file."
                )) ?? NSImage(),
                target: self,
                action: #selector(choosePrivateKeyFile)
            ),
        ])
        privateKeyPathRow.orientation = .horizontal
        privateKeyPathRow.spacing = 6
        privateKeyPathRow.arrangedSubviews.last?.setContentHuggingPriority(.required, for: .horizontal)

        let grid = NSGridView(views: [
            formRow(String(localized: "Group", comment: "SSH project form label for the group."), groupField),
            formRow(String(localized: "Host", comment: "SSH project form label for the host."), hostField),
            formRow(String(localized: "User", comment: "SSH project form label for the user."), userField),
            formRow(String(localized: "Port", comment: "SSH project form label for the port."), portField),
            formRow(
                String(
                    localized: "Remote Directory",
                    comment: "SSH project form label for the remote directory."
                ),
                directoryField
            ),
            formRow(
                String(localized: "Authentication", comment: "SSH project form label for authentication."),
                authenticationField
            ),
            formRow(String(localized: "Password", comment: "SSH project form label for a password."), passwordField),
            formRow(
                String(localized: "Private Key File", comment: "SSH project form label for a private key path."),
                privateKeyPathRow
            ),
            formRow(
                String(localized: "Private Key Text", comment: "SSH project form label for pasted private key content."),
                privateKeyContentScrollView
            ),
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
        formGrid = grid
        passwordRow = grid.row(at: 6)
        self.privateKeyPathRow = grid.row(at: 7)
        privateKeyContentRow = grid.row(at: 8)
        updateAuthenticationFields(resizeWindow: false)

        saveButton.title = String(localized: "Save", comment: "Button saving the SSH form into the list.")
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"

        cancelButton.title = String(localized: "Cancel", comment: "Button discarding SSH project form changes.")
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [NSView(), errorLabel, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [formHeader, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        formContainer.addSubview(stack)
        formStack = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: formContainer.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: formContainer.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: formContainer.bottomAnchor, constant: -16
            ),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func formRow(_ title: String, _ field: NSView) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return [label, field]
    }

    @objc private func authenticationChanged() {
        updateAuthenticationFields()
    }

    @objc private func choosePrivateKeyFile() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(
            localized: "Choose",
            comment: "Button title confirming private key file selection."
        )
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.privateKeyPathField.stringValue = url.path
        }
    }

    private func updateAuthenticationFields(resizeWindow: Bool = true) {
        let index = authenticationField.indexOfSelectedItem
        passwordRow?.isHidden = index != 1
        privateKeyPathRow?.isHidden = index != 2
        privateKeyContentRow?.isHidden = index != 3
        guard resizeWindow, displayMode == .form else { return }
        applyDisplayMode()
    }

    private func showSavedProjects(selecting entryID: UUID? = nil) {
        clearForm()
        tableView.deselectAll(nil)
        reloadList()
        if let entryID { selectEntry(id: entryID) }
        displayMode = .savedProjects
        applyDisplayMode()
        updateConnectButton()
    }

    private func showForm() {
        displayMode = .form
        applyDisplayMode()
    }

    private func applyDisplayMode(resizeWindow: Bool = true) {
        let showsSavedProjects = displayMode == .savedProjects
        listContainer.isHidden = !showsSavedProjects
        formContainer.isHidden = showsSavedProjects
        window?.title = showsSavedProjects
            ? String(localized: "Saved SSH Projects")
            : String(localized: "New SSH Project")

        guard resizeWindow, let window else { return }
        let oldFrame = window.frame
        let contentHeight = showsSavedProjects
            ? Self.listContentHeight
            : formContentHeight()
        window.setContentSize(NSSize(width: Self.windowWidth, height: contentHeight))
        window.setFrameOrigin(NSPoint(
            x: oldFrame.midX - window.frame.width / 2,
            y: oldFrame.maxY - window.frame.height
        ))
    }

    private func formContentHeight() -> CGFloat {
        guard let formStack else { return Self.fallbackFormContentHeight }
        formStack.layoutSubtreeIfNeeded()
        return ceil(formStack.fittingSize.height + 36)
    }

    private func focusSavedProjects() {
        if SSHProjectStore.shared.entries.isEmpty {
            window?.makeFirstResponder(newButton)
        } else {
            window?.makeFirstResponder(tableView)
        }
    }

    private func selectEntry(id: UUID) {
        guard let row = displayRows.firstIndex(where: {
            guard case .entry(let entry) = $0 else { return false }
            return entry.id == id
        }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func updateConnectButton() {
        connectButton.isEnabled = selectedEntry != nil
    }

    // MARK: - List updates

    private func reloadList() {
        let entries = SSHProjectStore.shared.entries
        reloadGroupOptions(entries)
        var rows: [DisplayRow] = []
        if entries.contains(where: { !$0.groupKey.isEmpty }) {
            var seenGroups: [String] = []
            var entriesByGroup: [String: [SSHProjectEntry]] = [:]
            for entry in entries {
                let group = entry.groupKey
                if entriesByGroup[group] == nil {
                    seenGroups.append(group)
                    entriesByGroup[group] = []
                }
                entriesByGroup[group]?.append(entry)
            }
            for group in seenGroups {
                rows.append(.header(group.isEmpty
                    ? String(localized: "Ungrouped", comment: "Section title for SSH projects without a group.")
                    : group))
                rows.append(
                    contentsOf: entriesByGroup[group, default: []].map { DisplayRow.entry($0) }
                )
            }
        } else {
            rows = entries.map(DisplayRow.entry)
        }
        displayRows = rows
        tableView.reloadData()

        let empty = entries.isEmpty
        emptyStateLabel.isHidden = !empty
        emptyStateLabel.stringValue = String(
            localized: "No saved projects yet. Click New to add one.",
            comment: "Empty state of the saved SSH project list."
        )
        tableView.sizeLastColumnToFit()
        updateConnectButton()
    }

    private func reloadGroupOptions(_ entries: [SSHProjectEntry]) {
        let currentValue = groupField.stringValue
        var seenGroups = Set<String>()
        let groups = entries.compactMap { entry -> String? in
            let group = entry.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !group.isEmpty, seenGroups.insert(group).inserted else { return nil }
            return group
        }
        groupField.removeAllItems()
        groupField.addItems(withObjectValues: groups)
        groupField.stringValue = currentValue
        let groupHint = groups.isEmpty
            ? String(
                localized: "No saved groups yet. Type a name to create one.",
                comment: "SSH project group field hint when there are no saved groups."
            )
            : String(
                localized: "Optional, e.g. Production",
                comment: "Placeholder of the SSH project group field."
            )
        groupField.placeholderString = groupHint
        groupField.toolTip = groupHint
        groupField.setAccessibilityHelp(groupHint)
    }

    // MARK: - Form state

    private func clearForm() {
        groupField.stringValue = ""
        hostField.stringValue = ""
        userField.stringValue = ""
        portField.stringValue = ""
        directoryField.stringValue = ""
        authenticationField.selectItem(at: 0)
        passwordField.stringValue = ""
        privateKeyPathField.stringValue = ""
        privateKeyContentField.string = ""
        updateAuthenticationFields(resizeWindow: false)
        editingEntryID = nil
        hideError()
    }

    private func fillForm(from entry: SSHProjectEntry) {
        groupField.stringValue = entry.group ?? ""
        hostField.stringValue = entry.host
        userField.stringValue = entry.user ?? ""
        portField.stringValue = entry.port.map(String.init) ?? ""
        directoryField.stringValue = entry.directory ?? ""
        passwordField.stringValue = ""
        privateKeyContentField.string = ""
        switch entry.authentication {
        case .agent:
            authenticationField.selectItem(at: 0)
            privateKeyPathField.stringValue = ""
        case .password:
            authenticationField.selectItem(at: 1)
            privateKeyPathField.stringValue = ""
        case .privateKeyPath(let path):
            authenticationField.selectItem(at: 2)
            privateKeyPathField.stringValue = path
        case .privateKeyContent:
            authenticationField.selectItem(at: 3)
            privateKeyPathField.stringValue = ""
        }
        updateAuthenticationFields(resizeWindow: false)
        editingEntryID = entry.id
        hideError()
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        if displayMode == .form { applyDisplayMode() }
    }

    private func hideError() {
        errorLabel.isHidden = true
    }

    /// Builds an entry from the form. Throws `SSHEndpoint.ValidationError` for
    /// bad connection fields; an empty host reports "Enter a host."
    private func entryFromForm(
        name: String
    ) throws -> (entry: SSHProjectEntry, endpoint: SSHEndpoint, credential: String?) {
        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portText)
        if !portText.isEmpty, port == nil {
            throw SSHEndpoint.ValidationError.invalidPort
        }
        let endpoint = try SSHEndpoint(
            host: hostField.stringValue,
            user: userField.stringValue.isEmpty ? nil : userField.stringValue,
            port: port
        )
        let directory = directoryField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let group = groupField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let existingEntry = SSHProjectStore.shared.entries.first { $0.id == editingEntryID }
        let authentication = try authenticationFromForm(existingEntry: existingEntry)
        let entry = SSHProjectEntry(
            id: editingEntryID ?? UUID(),
            name: existingEntry?.name ?? name,
            user: endpoint.user,
            host: endpoint.host,
            port: endpoint.port,
            directory: directory.isEmpty ? nil : directory,
            group: group.isEmpty ? nil : group,
            authentication: authentication.method
        )
        return (entry, endpoint, authentication.credential)
    }

    private func authenticationFromForm(
        existingEntry: SSHProjectEntry?
    ) throws -> (method: SSHAuthentication, credential: String?) {
        switch authenticationField.indexOfSelectedItem {
        case 0:
            return (.agent, nil)
        case 1:
            let password = passwordField.stringValue
            if !password.isEmpty { return (.password, password) }
            guard existingEntry?.authentication == .password else {
                throw SSHAuthentication.Error.missingCredential
            }
            return (.password, nil)
        case 2:
            let path = privateKeyPathField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                throw SSHAuthentication.Error.missingCredential
            }
            return (.privateKeyPath(path), nil)
        case 3:
            let key = privateKeyContentField.string
            if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (.privateKeyContent, key)
            }
            guard existingEntry?.authentication == .privateKeyContent else {
                throw SSHAuthentication.Error.missingCredential
            }
            return (.privateKeyContent, nil)
        default:
            return (.agent, nil)
        }
    }

    private func saveCredential(
        _ credential: String?,
        for entry: SSHProjectEntry,
        previousEntry: SSHProjectEntry?
    ) throws {
        if let credential {
            try SSHCredentialStore.shared.save(credential, for: entry.id)
            return
        }
        if entry.authentication.requiresCredential {
            guard previousEntry?.authentication == entry.authentication,
                  try SSHCredentialStore.shared.load(entry.id) != nil
            else { throw SSHAuthentication.Error.missingCredential }
            return
        }
        SSHCredentialStore.shared.remove(entry.id)
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        // Clicks always fill clickedRow; the selectedRow fallback covers
        // programmatic action dispatch (and is harmless otherwise, since
        // the two agree for a normal click).
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard displayRows.indices.contains(row), case .entry(let entry) = displayRows[row] else { return }
        // RowButtonTableView hands the rows' buttons their own mouse-downs,
        // so this action only fires for plain row clicks; the button check
        // remains as a guard for drifted presses.
        if clickLandedOnRowButton() { return }
        connect(entry)
    }

    /// True when the click that fired `tableView.action` landed on a button
    /// inside the table; that button's action handles the click instead.
    /// Prefers the live mouse-up event and falls back to the mouse-down
    /// location recorded by the local monitor.
    private func clickLandedOnRowButton() -> Bool {
        let location: NSPoint?
        if let event = NSApp.currentEvent, event.type == .leftMouseUp {
            location = event.locationInWindow
        } else {
            location = lastMouseDownLocation
        }
        guard let location else { return false }
        let tableLocation = tableView.convert(location, from: nil)
        var view = tableView.hitTest(tableLocation)
        while let current = view, current !== tableView {
            if current is NSButton { return true }
            view = current.superview
        }
        return false
    }

    @objc private func newClicked() {
        clearForm()
        showForm()
        window?.makeFirstResponder(hostField)
    }

    @objc private func cancelClicked() {
        showSavedProjects()
        focusSavedProjects()
    }

    @objc private func saveClicked() {
        do {
            let result = try entryFromForm(name: "")
            let previousEntry = SSHProjectStore.shared.entries.first { $0.id == result.entry.id }
            try saveCredential(
                result.credential,
                for: result.entry,
                previousEntry: previousEntry
            )
            if previousEntry != nil {
                SSHProjectStore.shared.update(result.entry)
            } else {
                SSHProjectStore.shared.add(result.entry)
            }
            showSavedProjects(selecting: result.entry.id)
        } catch let error as SSHEndpoint.ValidationError {
            showError(error.errorDescription ?? error.localizedDescription)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func connectSelectedClicked() {
        guard let entry = selectedEntry else { return }
        connect(entry)
    }

    private func connect(_ entry: SSHProjectEntry) {
        guard let window, window.isVisible, let manager else { return }
        do {
            let endpoint = try SSHEndpoint(
                host: entry.host, user: entry.user, port: entry.port
            )
            if entry.authentication.requiresCredential {
                guard try SSHCredentialStore.shared.load(entry.id) != nil else {
                    throw SSHAuthentication.Error.missingCredential
                }
            }
            AppWindowPresentation.hideChild(window)
            hostWindow = nil
            manager.newSSHProject(
                endpoint: endpoint,
                remoteDirectory: entry.directory,
                authentication: entry.authentication,
                credentialID: entry.id
            )
        } catch {
            fillForm(from: entry)
            showForm()
            showError(error.localizedDescription)
            window.makeFirstResponder(hostField)
        }
    }

    private func editEntry(_ entry: SSHProjectEntry) {
        fillForm(from: entry)
        showForm()
        window?.makeFirstResponder(hostField)
    }

    private func deleteEntry(_ entry: SSHProjectEntry) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Delete “\(entry.displayName)”?",
            comment: "SSH project deletion confirmation. The placeholder is a project name."
        )
        alert.informativeText = String(
            localized: "The project is removed from the saved list. Open terminals stay open.",
            comment: "Explanation in the SSH project deletion confirmation."
        )
        alert.addButton(withTitle: String(localized: "Delete"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        guard let window else { return }
        Task { @MainActor in
            let response = await alert.beginSheetModal(for: window)
            guard response == .alertFirstButtonReturn else { return }
            if editingEntryID == entry.id { clearForm() }
            SSHProjectStore.shared.remove(entry)
        }
    }
}

extension SSHProjectController: NSComboBoxDelegate {
    func comboBoxWillPopUp(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo === groupField else { return }
        Task { @MainActor [weak self, weak combo] in
            guard let self, let combo else { return }
            alignGroupComboPopup(combo)
        }
    }

    private func alignGroupComboPopup(_ combo: NSComboBox) {
        guard let hostWindow = combo.window else { return }
        let fieldFrame = hostWindow.convertToScreen(combo.convert(combo.bounds, to: nil))
        let popup = NSApp.windows
            .filter { window in
                window.isVisible
                    && window !== hostWindow
                    && window.className.contains("ComboBox")
                    && window.frame.width >= fieldFrame.width * 0.5
            }
            .min { lhs, rhs in
                abs(lhs.frame.midX - fieldFrame.midX) < abs(rhs.frame.midX - fieldFrame.midX)
            }
        guard let popup else { return }

        var popupFrame = popup.frame
        popupFrame.origin.x = fieldFrame.minX
        popupFrame.size.width = fieldFrame.width
        let belowOriginY = fieldFrame.minY - popupFrame.height
        if let screen = hostWindow.screen, belowOriginY >= screen.visibleFrame.minY {
            popupFrame.origin.y = belowOriginY
        } else {
            popupFrame.origin.y = fieldFrame.maxY
        }
        popup.setFrame(popupFrame, display: false)
        popup.backgroundColor = .textBackgroundColor
        popup.isOpaque = false
        popup.contentView?.wantsLayer = true
        popup.contentView?.layer?.cornerRadius = Self.formFieldCornerRadius
        popup.contentView?.layer?.cornerCurve = .continuous
        popup.contentView?.layer?.masksToBounds = true
    }
}

// MARK: - Table data

extension SSHProjectController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayRows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch displayRows[row] {
        case .header: Self.headerHeight
        case .entry: Self.rowHeight
        }
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        switch displayRows[row] {
        case .header(let title):
            let cell = (tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("sshGroupHeader"),
                owner: nil
            ) as? SSHGroupHeaderView) ?? SSHGroupHeaderView()
            cell.identifier = NSUserInterfaceItemIdentifier("sshGroupHeader")
            cell.configure(title: title)
            return cell
        case .entry(let entry):
            let cell = (tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("sshProjectRow"),
                owner: nil
            ) as? SSHProjectRowView) ?? SSHProjectRowView()
            cell.identifier = NSUserInterfaceItemIdentifier("sshProjectRow")
            cell.configure(entry: entry)
            cell.onEdit = { [weak self] in self?.editEntry(entry) }
            cell.onDelete = { [weak self] in self?.deleteEntry(entry) }
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .entry = displayRows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateConnectButton()
    }
}

/// A group section header row.
private final class SSHGroupHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        label.stringValue = title
        toolTip = title
        setAccessibilityLabel(title)
    }
}

/// One saved-project row: kind symbol, project name, `user@host:port` and the
/// remote directory, with trailing edit and delete buttons so both actions are
/// one click and never trigger the row's connect action.
private final class SSHProjectRowView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    init() {
        super.init(frame: .zero)

        iconView.setAccessibilityElement(false)
        iconView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleLabel.font = .systemFont(ofSize: 12.5)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let editButton = Self.iconButton(
            symbol: "pencil",
            accessibilityLabel: String(
                localized: "Edit",
                comment: "Accessibility label of a row's edit button."
            ),
            action: #selector(editClicked)
        )
        editButton.target = self
        let deleteButton = Self.iconButton(
            symbol: "trash",
            accessibilityLabel: String(
                localized: "Delete",
                comment: "Accessibility label of a row's delete button."
            ),
            action: #selector(deleteClicked)
        )
        deleteButton.target = self

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .horizontal
        textStack.alignment = .firstBaseline
        textStack.spacing = 8

        let stack = NSStackView(views: [iconView, textStack, editButton, deleteButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        stack.setCustomSpacing(6, after: textStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            // Explicit heights: an image-only bordered-less button's natural
            // size is its ~11pt glyph, a click target far too small to hit.
            editButton.widthAnchor.constraint(equalToConstant: 22),
            editButton.heightAnchor.constraint(equalToConstant: 22),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func iconButton(
        symbol: String,
        accessibilityLabel: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(image: NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        ) ?? NSImage(), target: nil, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    @objc private func editClicked() { onEdit?() }
    @objc private func deleteClicked() { onDelete?() }

    func configure(entry: SSHProjectEntry) {
        iconView.image = NSImage(
            systemSymbolName: entry.symbolName,
            accessibilityDescription: nil
        )
        titleLabel.stringValue = entry.displayName
        var detail = entry.destination
        if let directory = entry.directory, !directory.isEmpty {
            detail += "  ·  \(directory)"
        }
        detailLabel.stringValue = detail
        toolTip = [entry.displayName, detail].joined(separator: "\n")
        setAccessibilityLabel(
            [entry.displayName, entry.destination]
                .joined(separator: ", ")
        )
    }
}

/// A 1pt hairline box border drawn around the list area.
private final class HairlineBox: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        path.lineWidth = 1
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private extension SSHProjectEntry {
    /// Keep the empty group distinct from a group named "Ungrouped".
    var groupKey: String {
        group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
