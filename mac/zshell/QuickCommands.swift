//
//  QuickCommands.swift
//  zshell
//

import AppKit
import Foundation

struct QuickCommandPreset: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var command: String

    init(id: UUID = UUID(), name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.rangeOfCharacter(from: .controlCharacters) == nil
            && command.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

@MainActor
final class QuickCommandStore {
    static let shared = QuickCommandStore()

    private static let defaultsKey = "zshell.quick-command-presets"
    private(set) var presets: [QuickCommandPreset]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([QuickCommandPreset].self, from: data) {
            presets = decoded.filter(\.isValid)
        } else {
            presets = []
        }
    }

    func replace(with presets: [QuickCommandPreset]) {
        guard presets.allSatisfy(\.isValid),
              let data = try? JSONEncoder().encode(presets) else { return }
        self.presets = presets
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
final class QuickCommandMenuTarget: NSObject {
    func menuItems() -> [NSMenuItem] {
        let store = QuickCommandStore.shared
        var items: [NSMenuItem] = []
        if store.presets.isEmpty {
            let empty = NSMenuItem(
                title: String(localized: "No Quick Commands"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            items.append(empty)
        } else {
            for preset in store.presets {
                let parent = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: preset.name)
                let insert = item(
                    String(localized: "Insert into Terminal"),
                    #selector(insertPreset(_:)),
                    preset: preset
                )
                insert.toolTip = String(
                    localized: "Inserts the command without running it."
                )
                submenu.addItem(insert)
                let run = item(
                    String(localized: "Run Command"),
                    #selector(runPreset(_:)),
                    preset: preset
                )
                run.toolTip = String(
                    localized: "Runs the command immediately in this terminal."
                )
                submenu.addItem(run)
                parent.submenu = submenu
                items.append(parent)
            }
        }
        items.append(.separator())
        let manage = NSMenuItem(
            title: String(localized: "Manage Quick Commands…"),
            action: #selector(managePresets),
            keyEquivalent: ""
        )
        manage.target = self
        items.append(manage)
        return items
    }

    private func item(
        _ title: String,
        _ action: Selector,
        preset: QuickCommandPreset
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = preset.id.uuidString
        return item
    }

    private func preset(from sender: NSMenuItem) -> QuickCommandPreset? {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID) else { return nil }
        return QuickCommandStore.shared.presets.first { $0.id == id }
    }

    @objc private func insertPreset(_ sender: NSMenuItem) {
        guard let preset = preset(from: sender) else { return }
        TerminalManager.insertQuickCommand(preset)
    }

    @objc private func runPreset(_ sender: NSMenuItem) {
        guard let preset = preset(from: sender) else { return }
        TerminalManager.runQuickCommand(preset)
    }

    @objc private func managePresets() {
        TerminalManager.manageQuickCommands()
    }
}

@MainActor
enum QuickCommandEditor {
    private static var controller: QuickCommandEditorWindowController?

    static func show(relativeTo parent: NSWindow?) {
        let controller = controller ?? QuickCommandEditorWindowController()
        self.controller = controller
        controller.present(relativeTo: parent)
    }
}

@MainActor
final class QuickCommandEditorWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate
{
    private let tableView = NSTableView()
    private let nameField = NSTextField()
    private let commandField = NSTextField()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let saveButton = NSButton()
    private var presets: [QuickCommandPreset]
    private var selectedRow = -1

    init() {
        presets = QuickCommandStore.shared.presets
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Quick Commands")
        window.identifier = NSUserInterfaceItemIdentifier("quick-commands")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 500, height: 320)
        super.init(window: window)
        configureContent()
        select(row: presets.isEmpty ? -1 : 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(relativeTo parent: NSWindow?) {
        presets = QuickCommandStore.shared.presets
        tableView.reloadData()
        select(row: presets.isEmpty ? -1 : min(max(selectedRow, 0), presets.count - 1))
        guard let window else { return }
        guard let host = AppWindowPresentation.hostWindow(relativeTo: parent) else { return }
        AppWindowPresentation.presentSheet(window, on: host)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { presets.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("QuickCommandName")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        field.stringValue = presets[row].name
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow != selectedRow else { return }
        commitFields()
        select(row: tableView.selectedRow, reloadTable: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        updateSaveEnabled()
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        column.title = String(localized: "Name")
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        scrollView.documentView = tableView

        configureField(nameField, placeholder: String(localized: "Name"))
        configureField(commandField, placeholder: String(localized: "Command"))

        addButton.title = String(localized: "Add")
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addPreset)
        addButton.setAccessibilityLabel(String(localized: "Add Quick Command"))
        removeButton.title = String(localized: "Remove")
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removePreset)
        removeButton.setAccessibilityLabel(String(localized: "Remove Quick Command"))

        saveButton.title = String(localized: "Save")
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(savePresets)
        let cancelButton = NSButton(
            title: String(localized: "Cancel"),
            target: self,
            action: #selector(cancel)
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let fieldStack = NSStackView(views: [nameField, commandField])
        fieldStack.orientation = .vertical
        fieldStack.alignment = .width
        fieldStack.spacing = 10
        let listButtons = NSStackView(views: [addButton, removeButton])
        listButtons.orientation = .horizontal
        listButtons.spacing = 8
        let footer = NSStackView(views: [listButtons, NSView(), cancelButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        for view in [scrollView, fieldStack, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            scrollView.widthAnchor.constraint(equalToConstant: 190),
            fieldStack.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 16),
            fieldStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            fieldStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func configureField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.delegate = self
        field.isEnabled = false
    }

    private func commitFields() {
        guard presets.indices.contains(selectedRow) else { return }
        presets[selectedRow].name = nameField.stringValue
        presets[selectedRow].command = commandField.stringValue
    }

    private func select(row: Int, reloadTable: Bool = true) {
        selectedRow = presets.indices.contains(row) ? row : -1
        if reloadTable { tableView.reloadData() }
        if selectedRow >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            nameField.stringValue = presets[selectedRow].name
            commandField.stringValue = presets[selectedRow].command
        } else {
            tableView.deselectAll(nil)
            nameField.stringValue = ""
            commandField.stringValue = ""
        }
        nameField.isEnabled = selectedRow >= 0
        commandField.isEnabled = selectedRow >= 0
        removeButton.isEnabled = selectedRow >= 0
        updateSaveEnabled()
    }

    private func updateSaveEnabled() {
        var candidate = presets
        if candidate.indices.contains(selectedRow) {
            candidate[selectedRow].name = nameField.stringValue
            candidate[selectedRow].command = commandField.stringValue
        }
        let hasEditedRow = candidate.indices.contains(selectedRow)
        saveButton.isEnabled = candidate.allSatisfy(\.isValid)
            && (candidate.isEmpty || hasEditedRow)
    }

    @objc private func addPreset() {
        commitFields()
        presets.append(QuickCommandPreset(
            name: String(localized: "New Quick Command"),
            command: ""
        ))
        select(row: presets.count - 1)
        window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    @objc private func removePreset() {
        guard presets.indices.contains(selectedRow) else { return }
        let next = min(selectedRow, presets.count - 2)
        presets.remove(at: selectedRow)
        select(row: next)
    }

    @objc private func savePresets() {
        commitFields()
        guard presets.allSatisfy(\.isValid) else { return }
        QuickCommandStore.shared.replace(with: presets)
        dismiss()
    }

    @objc private func cancel() {
        dismiss()
    }

    private func dismiss() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            close()
        }
    }
}
