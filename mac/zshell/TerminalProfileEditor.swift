import AppKit
import GhosttyTheme

@MainActor
enum TerminalProfileEditor {
    private static var controller: TerminalProfileEditorWindowController?

    static func show(relativeTo parent: NSWindow?) {
        let controller = controller ?? TerminalProfileEditorWindowController()
        self.controller = controller
        controller.present(relativeTo: parent)
    }
}

@MainActor
final class TerminalProfileEditorWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate
{
    private let table = NSTableView()
    private let name = NSTextField()
    private let host = NSTextField()
    private let user = NSTextField()
    private let directory = NSTextField()
    private let program = NSTextField()
    private let font = NSTextField()
    private let size = NSTextField()
    private let startup = NSTextField()
    private let arguments = NSTextField()
    private let initialization = NSTextField()
    private let environment = NSTextView()
    private let enabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let darkTheme = NSPopUpButton()
    private let lightTheme = NSPopUpButton()
    private let cursor = NSPopUpButton()
    private let blinking = NSPopUpButton()
    private let error = NSTextField(wrappingLabelWithString: "")
    private let emptyList = NSTextField(wrappingLabelWithString: "")
    private let add = NSButton()
    private let remove = NSButton()
    private let up = NSButton()
    private let down = NSButton()
    private let save = NSButton()
    private var profiles: [TerminalProfile] = []
    private var selected = -1
    private var isSelecting = false
    private var languageObserver: NSObjectProtocol?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 690),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("terminal-profiles")
        window.contentMinSize = NSSize(width: 740, height: 580)
        super.init(window: window)
        configureContent()
        languageObserver = NotificationCenter.default.addObserver(
            forName: AppLocalization.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.commitFields()
                self.configureContent()
                self.select(self.selected)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    func present(relativeTo parent: NSWindow?) {
        guard let window, window.sheetParent == nil else { return }
        profiles = AppSettings.shared.terminalProfiles
        select(profiles.isEmpty ? -1 : 0)
        guard let host = AppWindowPresentation.hostWindow(relativeTo: parent) else { return }
        AppWindowPresentation.presentSheet(window, on: host)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard profiles.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("TerminalProfileName")
        let label = table.makeView(withIdentifier: id, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = id
        label.stringValue = profiles[row].name
        label.textColor = profiles[row].enabled ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelecting, table.selectedRow != selected else { return }
        let next = table.selectedRow
        guard commitFields() else {
            isSelecting = true
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            isSelecting = false
            return
        }
        select(next)
    }

    func controlTextDidChange(_ notification: Notification) { updateValidation() }
    func textDidChange(_ notification: Notification) { updateValidation() }

    private var textFields: [NSTextField] {
        [name, host, user, directory, program, font, size, startup, arguments, initialization]
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        window?.title = String(localized: "Terminal Profiles")
        table.tableColumns.forEach(table.removeTableColumn)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name")))
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel(String(localized: "Terminal Profiles"))
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.borderType = .bezelBorder
        emptyList.stringValue = String(localized: "No terminal profiles yet. Click Add to create one.")
        emptyList.alignment = .center
        emptyList.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyList.textColor = .secondaryLabelColor

        for field in textFields {
            field.delegate = self
            field.controlSize = .small
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        [host, user, directory, program].forEach { $0.placeholderString = String(localized: "Any") }
        [font, size, startup, arguments, initialization].forEach {
            $0.placeholderString = String(localized: "Inherit")
        }
        enabled.title = String(localized: "Enable automatic matching")
        enabled.target = self
        enabled.action = #selector(fieldsChanged)

        for popup in [darkTheme, lightTheme, cursor, blinking] {
            popup.removeAllItems()
            popup.addItem(withTitle: String(localized: "Inherit"))
            popup.controlSize = .small
            popup.target = self
            popup.action = #selector(fieldsChanged)
        }
        for (popup, themes) in [(darkTheme, Theme.commonDarkThemes), (lightTheme, Theme.commonLightThemes)] {
            for theme in themes {
                popup.addItem(withTitle: theme.name)
                popup.lastItem?.representedObject = theme.name
            }
        }
        for shape in TerminalCursorShape.allCases {
            cursor.addItem(withTitle: shape.title)
            cursor.lastItem?.representedObject = shape.rawValue
        }
        blinking.addItems(withTitles: [String(localized: "On"), String(localized: "Off")])

        environment.isRichText = false
        environment.allowsUndo = true
        environment.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        environment.delegate = self
        let environmentScroll = NSScrollView()
        environmentScroll.documentView = environment
        environmentScroll.hasVerticalScroller = true
        environmentScroll.borderType = .bezelBorder
        environmentScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 12
        grid.rowSpacing = 8
        func row(_ title: String, _ control: NSView) {
            let label = NSTextField(wrappingLabelWithString: title)
            label.alignment = .right
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            control.setAccessibilityLabel(title)
            grid.addRow(with: [label, control])
        }
        row(String(localized: "Name"), name)
        row(String(localized: "Host pattern"), host)
        row(String(localized: "User pattern"), user)
        row(String(localized: "Directory pattern"), directory)
        row(String(localized: "Foreground program pattern"), program)
        row(String(localized: "Dark theme"), darkTheme)
        row(String(localized: "Light theme"), lightTheme)
        row(String(localized: "Font family"), font)
        row(String(localized: "Font size"), size)
        row(String(localized: "Cursor Shape"), cursor)
        row(String(localized: "Cursor blinking"), blinking)
        row(String(localized: "Startup program"), startup)
        row(String(localized: "Startup arguments"), arguments)
        row(String(localized: "Initialization Command"), initialization)
        row(String(localized: "Environment Variables"), environmentScroll)
        grid.column(at: 0).width = 155
        grid.column(at: 1).xPlacement = .fill

        let rules = detail(String(localized: "Rules are checked from top to bottom. All filled conditions must match. * matches any text; ? matches one character."))
        let scope = detail(String(localized: "Appearance changes apply immediately to this pane. Environment and startup settings apply only to new terminals; switching profiles never runs a command."))
        let environmentHelp = detail(String(localized: "Enter one NAME=value per line. Values are saved as plain text in config.toml."))
        let form = NSStackView(views: [rules, enabled, grid, environmentHelp, scope])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.translatesAutoresizingMaskIntoConstraints = false
        let formScroll = NSScrollView()
        let document = TerminalProfileFormDocumentView()
        // A frame-based document view turns its initial zero frame into
        // required constraints, which collapses the form and the whole sheet.
        document.translatesAutoresizingMaskIntoConstraints = false
        formScroll.documentView = document
        formScroll.hasVerticalScroller = true
        formScroll.drawsBackground = false
        document.addSubview(form)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: formScroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: formScroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
            form.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            form.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            form.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            form.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            grid.widthAnchor.constraint(equalTo: form.widthAnchor),
            rules.widthAnchor.constraint(equalTo: form.widthAnchor),
            scope.widthAnchor.constraint(equalTo: form.widthAnchor),
            environmentHelp.widthAnchor.constraint(equalTo: form.widthAnchor),
        ])

        configure(add, String(localized: "Add"), #selector(addProfile))
        configure(remove, String(localized: "Remove"), #selector(removeProfile))
        configure(up, String(localized: "Move Up"), #selector(moveProfileUp))
        configure(down, String(localized: "Move Down"), #selector(moveProfileDown))
        configure(save, String(localized: "Save"), #selector(saveProfiles))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelEditing))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let footer = NSStackView(views: [add, remove, up, down, NSView(), cancel, save])
        footer.orientation = .horizontal
        footer.spacing = 8
        for view in [list, emptyList, formScroll, error, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            list.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            list.widthAnchor.constraint(equalToConstant: 175),
            list.bottomAnchor.constraint(equalTo: error.topAnchor, constant: -12),
            emptyList.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            emptyList.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 12),
            emptyList.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -12),
            formScroll.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 16),
            formScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            formScroll.topAnchor.constraint(equalTo: list.topAnchor),
            formScroll.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            error.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            error.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            error.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func detail(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configure(_ button: NSButton, _ title: String, _ action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
    }

    private func select(_ row: Int) {
        isSelecting = true
        defer { isSelecting = false }
        selected = profiles.indices.contains(row) ? row : -1
        table.reloadData()
        emptyList.isHidden = !profiles.isEmpty
        let profile = selected >= 0 ? profiles[selected] : TerminalProfile(name: "")
        if selected >= 0 { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        name.stringValue = profile.name
        enabled.state = profile.enabled ? .on : .off
        host.stringValue = profile.host
        user.stringValue = profile.user
        directory.stringValue = profile.directory
        program.stringValue = profile.program
        font.stringValue = profile.appearance.fontFamily ?? ""
        size.stringValue = profile.appearance.fontSize.map(TOML.number) ?? ""
        startup.stringValue = profile.startupProgram
        arguments.stringValue = profile.startupArguments
        initialization.stringValue = profile.launchSettings.initializationCommand ?? ""
        environment.string = profile.launchSettings.environmentVariables.map { $0.name + "=" + $0.value }.joined(separator: "\n")
        select(darkTheme, value: profile.appearance.themeDark)
        select(lightTheme, value: profile.appearance.themeLight)
        select(cursor, value: profile.appearance.cursorShape)
        blinking.selectItem(at: profile.appearance.cursorBlinking.map { $0 ? 1 : 2 } ?? 0)
        textFields.forEach { $0.isEnabled = selected >= 0 }
        [enabled, darkTheme, lightTheme, cursor, blinking].forEach { $0.isEnabled = selected >= 0 }
        environment.isEditable = selected >= 0
        updateValidation()
    }

    private func select(_ popup: NSPopUpButton, value: String?) {
        let item = popup.itemArray.first { $0.representedObject as? String == value }
        if let value, item == nil {
            popup.addItem(withTitle: value)
            popup.lastItem?.representedObject = value
            popup.select(popup.lastItem)
        } else { popup.select(item ?? popup.item(at: 0)) }
    }

    private func readFields() -> TerminalProfile? {
        guard profiles.indices.contains(selected) else { return nil }
        var candidate = profiles[selected]
        candidate.name = name.stringValue
        candidate.enabled = enabled.state == .on
        candidate.host = host.stringValue
        candidate.user = user.stringValue
        candidate.directory = directory.stringValue
        candidate.program = program.stringValue
        let fontSize = size.stringValue.isEmpty ? nil : Double(size.stringValue)
        guard size.stringValue.isEmpty || fontSize != nil else { return nil }
        candidate.appearance = .init(
            themeDark: darkTheme.selectedItem?.representedObject as? String,
            themeLight: lightTheme.selectedItem?.representedObject as? String,
            fontFamily: font.stringValue.isEmpty ? nil : font.stringValue,
            fontSize: fontSize,
            cursorShape: cursor.selectedItem?.representedObject as? String,
            cursorBlinking: blinking.indexOfSelectedItem == 0 ? nil : blinking.indexOfSelectedItem == 1
        )
        candidate.startupProgram = startup.stringValue
        candidate.startupArguments = arguments.stringValue
        candidate.launchSettings.initializationCommand = initialization.stringValue.isEmpty ? nil : initialization.stringValue
        var variables: [TerminalEnvironmentVariable] = []
        for line in environment.string.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { return nil }
            variables.append(.init(name: String(line[..<separator]), value: String(line[line.index(after: separator)...])))
        }
        candidate.launchSettings.environmentVariables = variables
        guard candidate.isValid,
              [candidate.appearance.themeDark, candidate.appearance.themeLight].compactMap({ $0 }).allSatisfy({ Theme.definition(named: $0) != nil }),
              case .success = TerminalStartupCommand.resolve(
                program: candidate.startupProgram, arguments: candidate.startupArguments,
                requireLocalExecutable: false
              )
        else { return nil }
        return candidate
    }

    @discardableResult
    private func commitFields() -> Bool {
        guard selected >= 0 else { return true }
        guard let candidate = readFields() else { updateValidation(); return false }
        profiles[selected] = candidate
        return true
    }

    private func updateValidation() {
        let valid = selected < 0 || readFields() != nil
        error.stringValue = valid ? "" : String(localized: "Check the name, patterns, font size (8–32), executable path, and NAME=value entries. Protected terminal variables cannot be overridden.")
        save.isEnabled = valid
        add.isEnabled = valid && profiles.count < TerminalProfile.maximumCount
        remove.isEnabled = selected >= 0
        up.isEnabled = valid && selected > 0
        down.isEnabled = valid && selected >= 0 && selected < profiles.count - 1
    }

    @objc private func fieldsChanged() { updateValidation() }
    @objc private func addProfile() {
        guard commitFields(), profiles.count < TerminalProfile.maximumCount else { return }
        profiles.append(TerminalProfile(name: String(localized: "New Terminal Profile")))
        select(profiles.count - 1)
        window?.makeFirstResponder(name)
        name.selectText(nil)
    }
    @objc private func removeProfile() {
        guard profiles.indices.contains(selected) else { return }
        profiles.remove(at: selected)
        select(min(selected, profiles.count - 1))
    }
    @objc private func moveProfileUp() { move(-1) }
    @objc private func moveProfileDown() { move(1) }
    private func move(_ offset: Int) {
        let next = selected + offset
        guard profiles.indices.contains(next), commitFields() else { return }
        profiles.swapAt(selected, next)
        select(next)
    }
    @objc private func saveProfiles() {
        guard commitFields(), profiles.allSatisfy(\.isValid) else { return }
        AppSettings.shared.terminalProfiles = profiles
        dismiss()
    }
    @objc private func cancelEditing() { dismiss() }
    private func dismiss() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        else { close() }
    }
}

/// Flipped so the form starts at the top of its scroll view.
private final class TerminalProfileFormDocumentView: NSView {
    override var isFlipped: Bool { true }
}
