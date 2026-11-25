//
//  QuickCommands.swift
//  zshell
//

import AppKit
import Foundation

@MainActor
final class QuickCommandStore {
    static let shared = QuickCommandStore()

    private static let defaultsKey = "zshell.quick-command-presets"
    private(set) var presets: [QuickCommandPreset]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([QuickCommandPreset].self, from: data)
        {
            presets = decoded.filter(\.isValid)
        } else {
            presets = []
        }
    }

    func replace(with presets: [QuickCommandPreset]) {
        guard presets.allSatisfy(\.isValid),
            let data = try? JSONEncoder().encode(presets)
        else { return }
        self.presets = presets
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
final class QuickCommandMenuTarget: NSObject {
    var onInsertPreset: ((QuickCommandPreset) -> Void)?
    var onRunPreset: ((QuickCommandPreset) -> Void)?
    var onManagePresets: (() -> Void)?

    func menuItems() -> [NSMenuItem] {
        let store = QuickCommandStore.shared
        var items: [NSMenuItem] = []
        if !store.presets.isEmpty {
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
        if !items.isEmpty { items.append(.separator()) }
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
            let id = UUID(uuidString: rawID)
        else { return nil }
        return QuickCommandStore.shared.presets.first { $0.id == id }
    }

    @objc private func insertPreset(_ sender: NSMenuItem) {
        guard let preset = preset(from: sender) else { return }
        onInsertPreset?(preset)
    }

    @objc private func runPreset(_ sender: NSMenuItem) {
        guard let preset = preset(from: sender) else { return }
        onRunPreset?(preset)
    }

    @objc private func managePresets() {
        onManagePresets?()
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
    private let parameterEditor = QuickCommandParameterEditorView()
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let saveButton = NSButton()
    private var presets: [QuickCommandPreset]
    private var selectedRow = -1

    init() {
        presets = QuickCommandStore.shared.presets
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Quick Commands")
        window.identifier = NSUserInterfaceItemIdentifier("quick-commands")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 500)
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
        let field =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            window?.selectNextKeyView(control)
            return true
        }
        return false
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
        nameField.identifier = NSUserInterfaceItemIdentifier("quick-command-name")
        commandField.identifier = NSUserInterfaceItemIdentifier("quick-command-command")
        parameterEditor.onChange = { [weak self] in self?.updateSaveEnabled() }
        validationLabel.textColor = .secondaryLabelColor
        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let templateHelp = NSTextField(
            wrappingLabelWithString: String(
                localized: "Use {{name}} for each parameter as a separate, unquoted argument."
            ))
        templateHelp.textColor = .secondaryLabelColor
        templateHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

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
        saveButton.identifier = NSUserInterfaceItemIdentifier("quick-command-save")
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
        cancelButton.identifier = NSUserInterfaceItemIdentifier("quick-command-cancel")
        cancelButton.keyEquivalent = "\u{1b}"

        let fieldStack = NSStackView(views: [nameField, commandField, templateHelp, parameterEditor, validationLabel])
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
            fieldStack.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func configureField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.delegate = self
        field.isEnabled = false
    }

    private func commitFields() {
        guard presets.indices.contains(selectedRow) else { return }
        presets[selectedRow].name = nameField.stringValue
        presets[selectedRow].command = commandField.stringValue
        presets[selectedRow].parameters = parameterEditor.parameters
    }

    private func select(row: Int, reloadTable: Bool = true) {
        selectedRow = presets.indices.contains(row) ? row : -1
        if reloadTable { tableView.reloadData() }
        if selectedRow >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            nameField.stringValue = presets[selectedRow].name
            commandField.stringValue = presets[selectedRow].command
            parameterEditor.setParameters(presets[selectedRow].parameters)
        } else {
            tableView.deselectAll(nil)
            nameField.stringValue = ""
            commandField.stringValue = ""
            parameterEditor.setParameters([])
        }
        nameField.isEnabled = selectedRow >= 0
        commandField.isEnabled = selectedRow >= 0
        parameterEditor.isHidden = selectedRow < 0
        removeButton.isEnabled = selectedRow >= 0
        updateSaveEnabled()
    }

    private func updateSaveEnabled() {
        var candidate = presets
        if candidate.indices.contains(selectedRow) {
            candidate[selectedRow].name = nameField.stringValue
            candidate[selectedRow].command = commandField.stringValue
            candidate[selectedRow].parameters = parameterEditor.parameters
        }
        let hasEditedRow = candidate.indices.contains(selectedRow)
        validationLabel.stringValue = candidate.first(where: { !$0.isValid })?.validationError?.localizedDescription ?? ""
        saveButton.isEnabled =
            candidate.allSatisfy(\.isValid)
            && (candidate.isEmpty || hasEditedRow)
    }

    @objc private func addPreset() {
        commitFields()
        presets.append(
            QuickCommandPreset(
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
