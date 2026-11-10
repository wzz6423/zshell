import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AgentRecognitionRulesController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = AgentRecognitionRulesController()
    private let store = AgentRecognitionRulesStore.shared
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let editButton = NSButton()
    private let deleteButton = NSButton()
    private let resetButton = NSButton()
    private var entries: [AgentRecognitionManifest] = []
    private var observations: [AnyCancellable] = []
    private var busy = false
    private weak var hostWindow: NSWindow?
    private var editor: AgentRecognitionRulesEditor?

    private init() {
        super.init(window: nil)
        store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: AppLocalization.didChange).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.editor?.close()
            self?.editor = nil
            self?.window?.close()
            self?.window = nil
        }.store(in: &observations)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let host = AppWindowPresentation.hostWindow() else { return }
        if window == nil { configure() }
        guard let window else { return }
        hostWindow?.removeChildWindow(window)
        hostWindow = host
        reload()
        window.setFrameOrigin(NSPoint(x: host.frame.midX - window.frame.width / 2, y: host.frame.midY - window.frame.height / 2))
        host.addChildWindow(window, ordered: .above)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func configure() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = String(localized: "Agent Recognition Rules")
        panel.minSize = NSSize(width: 480, height: 470)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("agent-recognition-rules")
        window = panel
        guard let content = panel.contentView else { return }

        let introduction = NSTextField(wrappingLabelWithString: String(localized: "Add command names or replace an agent’s screen rules. Changes apply to running local panes."))
        introduction.textColor = .secondaryLabelColor
        let path = NSTextField(wrappingLabelWithString: store.url.path)
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        path.textColor = .secondaryLabelColor
        path.isSelectable = true
        let tableColumn = NSTableColumn(identifier: .init("agent"))
        tableColumn.resizingMask = .autoresizingMask
        table.addTableColumn(tableColumn)
        table.headerView = nil
        table.rowHeight = 54
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(editSelection)
        table.setAccessibilityLabel(String(localized: "Agent Recognition Rules"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        let add = SettingsActionButton(title: String(localized: "Add Agent…")) { [weak self] in self?.edit(.newAgentExample, replacing: nil) }
        configure(editButton, title: String(localized: "Edit…"), action: #selector(editSelection))
        configure(deleteButton, title: String(localized: "Delete"), action: #selector(deleteSelection))
        configure(resetButton, title: String(localized: "Restore Default"), action: #selector(resetSelection))
        let importButton = SettingsActionButton(title: String(localized: "Import…")) { [weak self] in self?.importRules() }
        let exportButton = SettingsActionButton(title: String(localized: "Export…")) { [weak self] in self?.exportRules() }
        let resetAll = SettingsActionButton(title: String(localized: "Reset All Rules…")) { [weak self] in self?.resetAll() }
        let file = SettingsActionButton(title: String(localized: "Reveal Rules File")) { [weak self] in self?.revealFile() }
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        controls.addArrangedSubview(actionRow([add, editButton]))
        controls.addArrangedSubview(actionRow([deleteButton, resetButton]))
        let fileControls = NSStackView()
        fileControls.orientation = .vertical
        fileControls.alignment = .leading
        fileControls.spacing = 8
        fileControls.addArrangedSubview(actionRow([importButton, exportButton]))
        fileControls.addArrangedSubview(actionRow([file, resetAll]))
        status.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [introduction, path, scroll, controls, fileControls, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        for view in [introduction, path, scroll, status] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    private func actionRow(_ buttons: [NSView]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private var selected: AgentRecognitionManifest? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    private func reload() {
        let selectedID = selected?.id
        let overrides = Dictionary(uniqueKeysWithValues: store.manifests.map { ($0.id, $0) })
        entries = ZshellAgentKind.allCases.filter { $0 != .program }.map {
            overrides[$0.rawValue] ?? AgentRecognitionManifest.editableDefault($0)
        } + store.manifests.filter { AgentRecognitionManifest.builtinKind($0.id) == nil }
        table.reloadData()
        if let selectedID, let row = entries.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        if !busy { status.stringValue = store.error ?? "" }
        updateSelection()
    }

    private func updateSelection() {
        editButton.isEnabled = !busy && selected != nil
        deleteButton.isEnabled = !busy && selected.map { AgentRecognitionManifest.builtinKind($0.id) == nil } == true
        resetButton.isEnabled = !busy && selected.map { value in
            AgentRecognitionManifest.builtinKind(value.id) != nil && store.manifests.contains { $0.id == value.id }
        } == true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let names = (entry.executables + entry.aliases)
        let custom = store.manifests.contains { $0.id == entry.id }
        let identifier = NSUserInterfaceItemIdentifier("agent-recognition-rule-row")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? AgentRecognitionRuleRowView ?? AgentRecognitionRuleRowView()
        rowView.identifier = identifier
        rowView.apply(name: entry.name, detail: names.isEmpty ? entry.id : names.joined(separator: ", "), custom: custom)
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    @objc private func editSelection() {
        guard !busy, let selected else { return }
        edit(selected, replacing: selected.id)
    }

    private func edit(_ manifest: AgentRecognitionManifest, replacing id: String?) {
        guard !busy, let window, editor == nil else { return }
        let editor = AgentRecognitionRulesEditor(manifest: manifest, store: store, replacing: id) { [weak self] in self?.editor = nil }
        self.editor = editor
        guard let editorWindow = editor.window else { return }
        window.beginSheet(editorWindow)
    }

    @objc private func deleteSelection() {
        guard !busy, let selected, AgentRecognitionManifest.builtinKind(selected.id) == nil else { return }
        save(store.manifests.filter { $0.id != selected.id })
    }

    @objc private func resetSelection() {
        guard !busy, let selected, AgentRecognitionManifest.builtinKind(selected.id) != nil else { return }
        save(store.manifests.filter { $0.id != selected.id })
    }

    private func save(_ values: [AgentRecognitionManifest]) {
        busy = true
        status.stringValue = String(localized: "Saving…")
        updateSelection()
        store.save(values) { [weak self] error in
            guard let self else { return }
            self.busy = false
            self.reload()
            self.status.stringValue = error ?? ""
        }
    }

    private func resetAll() {
        guard !busy, let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Reset All Agent Rules?")
        alert.informativeText = String(localized: "Custom agents and overrides will be removed. Built-in recognition will be restored.")
        alert.addButton(withTitle: String(localized: "Reset"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in if response == .alertFirstButtonReturn { self?.save([]) } }
    }

    private func revealFile() {
        guard !busy else { return }
        if FileManager.default.fileExists(atPath: store.url.path) { NSWorkspace.shared.activateFileViewerSelecting([store.url]); return }
        store.save(store.manifests) { [weak self] error in
            guard let self else { return }
            if let error { self.status.stringValue = error }
            else { NSWorkspace.shared.activateFileViewerSelecting([self.store.url]) }
        }
    }

    private func importRules() {
        guard !busy, let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.busy = true
            self.status.stringValue = String(localized: "Loading…")
            self.updateSelection()
            Task { @MainActor [self] in
                let result = await Task.detached(priority: .utility) { Result { try AgentRecognitionManifest.parse(SettingsConfigFile.read(at: url)) } }.value
                self.busy = false
                self.updateSelection()
                switch result {
                case let .failure(error): self.status.stringValue = error.localizedDescription
                case let .success(manifests):
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Replace Agent Rules?")
                    alert.informativeText = String(localized: "The imported file will replace custom agents and screen overrides.")
                    alert.addButton(withTitle: String(localized: "Import"))
                    alert.addButton(withTitle: String(localized: "Cancel"))
                    alert.beginSheetModal(for: window) { [weak self] response in if response == .alertFirstButtonReturn { self?.save(manifests) } }
                }
            }
        }
    }

    private func exportRules() {
        guard !busy, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .data]
        panel.nameFieldStringValue = "agents.toml"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let text = AgentRecognitionManifest.serialize(self.store.manifests)
            Task { @MainActor in
                let result = await Task.detached(priority: .utility) { Result { try SettingsConfigFile.write(text, at: url) } }.value
                if case let .failure(error) = result { self.status.stringValue = error.localizedDescription }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        editor?.close()
        editor = nil
        if let window { hostWindow?.removeChildWindow(window) }
        hostWindow = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy && editor?.isSaving != true }
}

private final class AgentRecognitionRuleRowView: NSView {
    private let name = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        name.maximumNumberOfLines = 1
        detail.maximumNumberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.textColor = .secondaryLabelColor
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [text, badge])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for field in [name, detail] { field.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(name: String, detail: String, custom: Bool) {
        self.name.stringValue = name
        self.detail.stringValue = detail
        badge.stringValue = custom ? String(localized: "Custom") : String(localized: "Built-in")
        setAccessibilityLabel("\(name), \(detail), \(badge.stringValue)")
    }
}

@MainActor
private final class AgentRecognitionRulesEditor: NSWindowController {
    private let store: AgentRecognitionRulesStore
    private let replacing: String?
    private let textView = NSTextView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    private var cancelButton: NSButton?
    private let onClose: () -> Void
    private var saving = false
    var isSaving: Bool { saving }

    init(manifest: AgentRecognitionManifest, store: AgentRecognitionRulesStore, replacing: String?, onClose: @escaping () -> Void) {
        self.store = store
        self.replacing = replacing
        self.onClose = onClose
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = String(localized: "Edit Agent Rules")
        panel.minSize = NSSize(width: 480, height: 360)
        panel.isReleasedWhenClosed = false
        guard let content = panel.contentView else { return }
        let help = NSTextField(wrappingLabelWithString: String(localized: "Edit the agent’s TOML. Remove its screen rules or set screen_enabled = false to keep only process recognition."))
        help.textColor = .secondaryLabelColor
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = AgentRecognitionManifest.serialize([manifest])
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(String(localized: "Agent TOML"))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.borderType = .bezelBorder
        let cancel = SettingsActionButton(title: String(localized: "Cancel")) { [weak self] in self?.close() }
        cancelButton = cancel
        cancel.keyEquivalent = "\u{1b}"
        saveButton.title = String(localized: "Save")
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        let buttons = NSStackView(views: [cancel, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        errorLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [help, scroll, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        for view in [help, scroll, errorLabel] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        panel.initialFirstResponder = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func save() {
        guard !saving else { return }
        let text = textView.string
        saving = true
        saveButton.isEnabled = false
        cancelButton?.isEnabled = false
        errorLabel.stringValue = String(localized: "Saving…")
        Task { @MainActor [self] in
            let parsed = await Task.detached(priority: .utility) { Result { try AgentRecognitionManifest.parse(text) } }.value
            switch parsed {
            case let .failure(error): finish(error.localizedDescription)
            case let .success(manifests):
                guard manifests.count == 1, let edited = manifests.first else { finish(String(localized: "Edit exactly one agent in this window.")); return }
                guard !store.manifests.contains(where: { $0.id == edited.id && $0.id != replacing }) else {
                    finish(String(localized: "An agent with this ID already exists.")); return
                }
                var values = store.manifests.filter { $0.id != replacing }
                values.append(edited)
                store.save(values) { [weak self] error in
                    if let error { self?.finish(error) } else { self?.saving = false; self?.close() }
                }
            }
        }
    }

    private func finish(_ error: String) {
        saving = false
        saveButton.isEnabled = true
        cancelButton?.isEnabled = true
        errorLabel.stringValue = error
    }

    override func close() {
        guard !saving else { return }
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        super.close()
        onClose()
    }
}
