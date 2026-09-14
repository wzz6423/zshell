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

    init(
        id: UUID = UUID(),
        name: String,
        user: String?,
        host: String,
        port: Int?,
        directory: String?,
        group: String?
    ) {
        self.id = id
        self.name = name
        self.user = user
        self.host = host
        self.port = port
        self.directory = directory
        self.group = group
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
        case id, name, user, host, port, directory, group
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
            group: try container.decodeIfPresent(String.self, forKey: .group)
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

/// The SSH project dialog: a small titled window listing saved projects —
/// grouped, one click connects, per-row edit/delete — above the connection
/// form. Replaces the old one-shot alert, whose accessory view broke its own
/// layout and which kept no history of previously entered projects.
@MainActor
final class SSHProjectController: NSObject {
    static let shared = SSHProjectController()

    private static let windowWidth: CGFloat = 500
    private static let listHeight: CGFloat = 210
    private static let rowHeight: CGFloat = 34
    private static let headerHeight: CGFloat = 26
    /// Content height: list box + gap + form stack (header + 5-row grid +
    /// buttons) + insets. An exact fit matters — every extra point the outer
    /// stack cannot spend on spacing is dumped into the grid as a stretched,
    /// blank band after its first row.
    private static let formHeight: CGFloat = 256

    private weak var manager: TerminalManager?
    private var window: NSWindow?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyStateLabel = NSTextField(labelWithString: "")

    private let groupField = NSTextField()
    private let hostField = NSTextField()
    private let userField = NSTextField()
    private let portField = NSTextField()
    private let directoryField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let newButton = NSButton(title: "", target: nil, action: nil)
    private let connectButton = NSButton(title: "", target: nil, action: nil)
    private var formHeaderLabel: NSTextField?

    /// The entry being edited, if the form was filled from a row's edit
    /// button; saving replaces it instead of appending.
    private var editingEntryID: UUID?

    private enum DisplayRow {
        case header(String)
        case entry(SSHProjectEntry)
    }

    /// Rows as they appear in the table — grouped sections when at least one
    /// entry carries a group, otherwise the saved order.
    private var displayRows: [DisplayRow] = []

    private var selectedEntry: SSHProjectEntry? {
        let row = tableView.selectedRow
        guard row >= 0, case .entry(let entry) = displayRows[row] else { return nil }
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
        self.manager = manager
        let window = self.window ?? makeWindow()
        self.window = window

        clearForm()
        reloadList()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hostField)
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.windowWidth,
                height: Self.listHeight + Self.formHeight
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

        return window
    }

    private func buildList(in content: NSView) {
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
        tableView.doubleAction = #selector(rowClicked)
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
        content.addSubview(scrollView)

        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyStateLabel)

        let listBorder = HairlineBox()
        listBorder.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(listBorder)

        NSLayoutConstraint.activate([
            listBorder.topAnchor.constraint(
                equalTo: content.topAnchor, constant: 16
            ),
            listBorder.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: 16
            ),
            listBorder.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -16
            ),
            listBorder.heightAnchor.constraint(equalToConstant: Self.listHeight),
            scrollView.topAnchor.constraint(equalTo: listBorder.topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: listBorder.bottomAnchor, constant: -1),
            scrollView.leadingAnchor.constraint(equalTo: listBorder.leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: listBorder.trailingAnchor, constant: -1),
            emptyStateLabel.centerXAnchor.constraint(equalTo: listBorder.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: listBorder.centerYAnchor),
        ])
    }

    private func buildForm(in content: NSView) {
        groupField.placeholderString = String(
            localized: "Optional, e.g. Production",
            comment: "Placeholder of the SSH project group field."
        )
        hostField.placeholderString = String(
            localized: "example.com",
            comment: "Placeholder of the SSH host field."
        )
        userField.placeholderString = NSUserName()
        portField.placeholderString = "22"
        directoryField.placeholderString = "~/project"

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
        formHeaderLabel = formHeader

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
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300
        grid.translatesAutoresizingMaskIntoConstraints = false

        newButton.title = String(localized: "New", comment: "Button clearing the SSH form for a fresh entry.")
        newButton.bezelStyle = .rounded
        newButton.controlSize = .small
        newButton.target = self
        newButton.action = #selector(clearFormClicked)

        saveButton.title = String(localized: "Save", comment: "Button saving the SSH form into the list.")
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"

        connectButton.title = String(localized: "Connect", comment: "Button connecting the SSH form's project.")
        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .small
        connectButton.target = self
        connectButton.action = #selector(connectClicked)

        let buttons = NSStackView(views: [newButton, NSView(), errorLabel, saveButton, connectButton])
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
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func formRow(_ title: String, _ field: NSView) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return [label, field]
    }

    // MARK: - List updates

    private func reloadList() {
        let entries = SSHProjectStore.shared.entries
        var rows: [DisplayRow] = []
        if entries.contains(where: { !$0.displayGroup.isEmpty }) {
            var seenGroups: [String] = []
            var entriesByGroup: [String: [SSHProjectEntry]] = [:]
            for entry in entries {
                let group = entry.displayGroup
                if entriesByGroup[group] == nil {
                    seenGroups.append(group)
                    entriesByGroup[group] = []
                }
                entriesByGroup[group]?.append(entry)
            }
            for group in seenGroups {
                rows.append(.header(group))
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
            localized: "No saved projects yet. Fill in the form below and click Save.",
            comment: "Empty state of the saved SSH project list."
        )
        tableView.sizeLastColumnToFit()
    }

    // MARK: - Form state

    private func clearForm() {
        groupField.stringValue = ""
        hostField.stringValue = ""
        userField.stringValue = ""
        portField.stringValue = ""
        directoryField.stringValue = ""
        editingEntryID = nil
        hideError()
        saveButton.title = String(localized: "Save", comment: "Button saving the SSH form into the list.")
    }

    private func fillForm(from entry: SSHProjectEntry) {
        groupField.stringValue = entry.group ?? ""
        hostField.stringValue = entry.host
        userField.stringValue = entry.user ?? ""
        portField.stringValue = entry.port.map(String.init) ?? ""
        directoryField.stringValue = entry.directory ?? ""
        editingEntryID = entry.id
        hideError()
        saveButton.title = String(
            localized: "Update",
            comment: "Button saving edits to an existing SSH project."
        )
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    private func hideError() {
        errorLabel.isHidden = true
    }

    /// Builds an entry from the form. Throws `SSHEndpoint.ValidationError` for
    /// bad connection fields; an empty host reports "Enter a host."
    private func entryFromForm(name: String) throws -> (SSHProjectEntry, SSHEndpoint) {
        let endpoint = try SSHEndpoint(
            host: hostField.stringValue,
            user: userField.stringValue.isEmpty ? nil : userField.stringValue,
            port: portField.stringValue.isEmpty ? nil : portField.integerValue
        )
        let directory = directoryField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let group = groupField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = SSHProjectEntry(
            id: editingEntryID ?? UUID(),
            name: name,
            user: endpoint.user,
            host: endpoint.host,
            port: endpoint.port,
            directory: directory.isEmpty ? nil : directory,
            group: group.isEmpty ? nil : group
        )
        return (entry, endpoint)
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, case .entry(let entry) = displayRows[row] else { return }
        connect(entry)
    }

    @objc private func clearFormClicked() {
        clearForm()
        tableView.deselectAll(nil)
        window?.makeFirstResponder(hostField)
    }

    @objc private func saveClicked() {
        do {
            let (entry, _) = try entryFromForm(name: "")
            if SSHProjectStore.shared.entries.contains(where: { $0.id == entry.id }) {
                SSHProjectStore.shared.update(entry)
            } else {
                SSHProjectStore.shared.add(entry)
            }
            clearForm()
        } catch let error as SSHEndpoint.ValidationError {
            showError(error.errorDescription ?? error.localizedDescription)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func connectClicked() {
        do {
            // Connecting while editing also persists the edits, so "Update,
            // then connect" is one click.
            let (entry, endpoint) = try entryFromForm(name: "")
            if editingEntryID != nil {
                SSHProjectStore.shared.update(entry)
            }
            connect(entry, endpoint: endpoint)
        } catch let error as SSHEndpoint.ValidationError {
            showError(error.errorDescription ?? error.localizedDescription)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func connect(_ entry: SSHProjectEntry, endpoint: SSHEndpoint? = nil) {
        guard let manager else { return }
        do {
            let endpoint = try endpoint ?? SSHEndpoint(
                host: entry.host, user: entry.user, port: entry.port
            )
            window?.orderOut(nil)
            manager.newSSHProject(
                endpoint: endpoint,
                remoteDirectory: entry.directory
            )
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func editEntry(_ entry: SSHProjectEntry) {
        fillForm(from: entry)
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
}

/// A group section header row.
private final class SSHGroupHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        label.stringValue = title
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
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            editButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
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
        setAccessibilityLabel(
            [entry.displayName, entry.destination]
                .joined(separator: ", ")
        )
    }
}

/// A 1pt hairline box border drawn around the list area.
private final class HairlineBox: NSView {
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
    /// The section title an entry sorts under; ungrouped entries share one
    /// bucket rendered with the app's "Ungrouped" label.
    var displayGroup: String {
        let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
            ? String(localized: "Ungrouped", comment: "Section title for SSH projects without a group.")
            : trimmed
    }
}
