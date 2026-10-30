import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class WorkspaceTemplateController: NSObject, NSWindowDelegate, NSMenuItemValidation, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = WorkspaceTemplateController()
    private let store: WorkspaceTemplateStore
    private weak var manager: TerminalManager?
    private var panel: NSPanel?
    private let table = NSTableView()
    private let details = NSTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let rootLabel = NSTextField(labelWithString: "")
    private let rootField = NSTextField()
    private let hostLabel = NSTextField(labelWithString: "")
    private let hostPopup = NSPopUpButton()
    private let remoteDirectoryLabel = NSTextField(labelWithString: "")
    private let remoteDirectoryField = NSTextField()
    private var applying = false
    private var remoteNotice: String?
    private var localBox: NSStackView?
    private var remoteBox: NSStackView?
    private let saveButton = NSButton()
    private let importButton = NSButton()
    private let renameButton = NSButton()
    private let deleteButton = NSButton()
    private let editButton = NSButton()
    private let exportButton = NSButton()
    private let chooseButton = NSButton()
    private let applyButton = NSButton()
    private var entries: [WorkspaceTemplateStore.Entry] = []
    private var observations: [AnyCancellable] = []
    private var managerObservation: AnyCancellable?
    private var editor: WorkspaceTemplateEditorController?

    init(store: WorkspaceTemplateStore? = nil) {
        let store = store ?? .shared
        self.store = store
        super.init()
        store.$entries.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: AppLocalization.didChange).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.localize() }.store(in: &observations)
    }

    func installMenu(in mainMenu: NSMenu) {
        guard let fileMenu = mainMenu.items.dropFirst().first?.submenu else { return }
        let identifier = NSUserInterfaceItemIdentifier("zshell-workspace-templates-menu")
        let title = String(localized: "Workspace Templates")
        let item = fileMenu.items.first { $0.identifier == identifier }
            ?? NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = identifier
        if item.title != title { item.title = title }
        let menu = item.submenu ?? NSMenu(title: title)
        if item.submenu == nil { item.submenu = menu }
        if menu.title != title { menu.title = title }
        for (id, title, action) in [
            ("workspace-template-save", String(localized: "Save Project as Template…"), #selector(saveFromMenu(_:))),
            ("workspace-template-manage", String(localized: "Workspace Templates…"), #selector(showFromMenu(_:))),
        ] {
            let identifier = NSUserInterfaceItemIdentifier(id)
            let command = menu.items.first { $0.identifier == identifier }
                ?? NSMenuItem(title: title, action: action, keyEquivalent: "")
            command.identifier = identifier
            if command.title != title { command.title = title }
            if command.target !== self { command.target = self }
            if command.action != action { command.action = action }
            if command.menu == nil { menu.addItem(command) }
        }
        if item.menu == nil { fileMenu.addItem(item) }
    }

    func show(for manager: TerminalManager) {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow) else { return }
        if panel == nil { configure() }
        guard let panel else { return }
        self.manager = manager
        let project = manager.selectedProject
        let directory = project?.selectedSession?.currentDirectoryPath ?? NSHomeDirectory()
        rootField.stringValue = project?.isRemote == false
            ? project?.panelRoot(followingSessionAt: directory).root ?? directory : NSHomeDirectory()
        statusLabel.stringValue = store.loadError ?? ""
        managerObservation = manager.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSaveAvailability() }
        localize()
        AppWindowPresentation.attach(panel, to: host, placement: .centered)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(table)
    }

    func close(ifOwnedBy manager: TerminalManager? = nil) {
        if let manager, self.manager !== manager { return }
        if let panel { panel.close() }
    }

    func windowWillClose(_ notification: Notification) {
        editor?.close()
        if let panel {
            if let sheet = panel.attachedSheet {
                panel.endSheet(sheet)
                sheet.orderOut(nil)
            }
            panel.parent?.removeChildWindow(panel)
        }
        editor = nil
        managerObservation = nil
        manager = nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let manager = TerminalManager.activeWindowManager else { return false }
        if menuItem.action == #selector(saveFromMenu(_:)) {
            return manager.selectedProject.map(WorkspaceTemplate.canCapture) ?? false
        }
        return true
    }

    @objc private func showFromMenu(_ sender: Any?) {
        guard let manager = TerminalManager.activeWindowManager else { return }
        show(for: manager)
    }

    @objc private func saveFromMenu(_ sender: Any?) {
        showFromMenu(sender)
        saveCurrentProject(sender)
    }

    private func configure() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 760, height: 520)
        panel.identifier = NSUserInterfaceItemIdentifier("workspace-templates")
        panel.delegate = self
        self.panel = panel
        guard let content = panel.contentView else { return }
        for (button, action) in [(saveButton, #selector(saveCurrentProject(_:))), (importButton, #selector(importTemplate(_:))),
                                 (renameButton, #selector(renameTemplate(_:))), (deleteButton, #selector(deleteTemplate(_:))),
                                 (editButton, #selector(editTemplate(_:))), (exportButton, #selector(exportTemplate(_:))),
                                 (chooseButton, #selector(chooseRoot(_:))), (applyButton, #selector(applyTemplate(_:)))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        applyButton.keyEquivalent = "\r"
        rootField.lineBreakMode = .byTruncatingMiddle
        rootField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remoteDirectoryField.lineBreakMode = .byTruncatingMiddle
        hostPopup.target = self
        hostPopup.action = #selector(hostChanged(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("template-name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 32
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        listScroll.documentView = table
        details.isEditable = false
        details.isSelectable = true
        details.isRichText = false
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.textContainerInset = NSSize(width: 10, height: 10)
        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detailScroll.documentView = details
        details.frame = NSRect(x: 0, y: 0, width: 560, height: 300)
        details.minSize = NSSize(width: 0, height: 0)
        details.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        details.autoresizingMask = [.width]
        details.isVerticallyResizable = true
        details.isHorizontallyResizable = false
        details.textContainer?.widthTracksTextView = true
        statusLabel.textColor = .systemRed
        statusLabel.font = .systemFont(ofSize: 12)
        let toolbar = stack([saveButton, importButton, NSView()], vertical: false)
        let listActions = stack([renameButton, deleteButton, NSView()], vertical: false)
        let detailActions = stack([editButton, exportButton, NSView()], vertical: false)
        let rootRow = stack([rootField, chooseButton], vertical: false)
        let applyRow = stack([NSView(), applyButton], vertical: false)
        let left = stack([listScroll, listActions], vertical: true)
        let localBox = stack([rootLabel, rootRow], vertical: true)
        let remoteBox = stack([hostLabel, hostPopup, remoteDirectoryLabel, remoteDirectoryField], vertical: true)
        let right = stack([detailScroll, detailActions, localBox, remoteBox, statusLabel, applyRow], vertical: true)
        self.localBox = localBox
        self.remoteBox = remoteBox
        let body = stack([left, right], vertical: false)
        body.alignment = .top
        let all = stack([toolbar, body], vertical: true)
        all.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            all.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            all.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            all.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            left.widthAnchor.constraint(equalToConstant: 240),
            left.heightAnchor.constraint(equalTo: body.heightAnchor),
            right.heightAnchor.constraint(equalTo: body.heightAnchor),
            right.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            statusLabel.widthAnchor.constraint(equalTo: right.widthAnchor),
            detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    private func stack(_ views: [NSView], vertical: Bool) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = 10
        if vertical {
            for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        return stack
    }

    private func localize() {
        guard panel != nil else { return }
        panel?.title = String(localized: "Workspace Templates")
        saveButton.title = String(localized: "Save Project as Template…")
        importButton.title = String(localized: "Import…")
        renameButton.title = String(localized: "Rename…")
        deleteButton.title = String(localized: "Delete…")
        editButton.title = String(localized: "Edit…")
        exportButton.title = String(localized: "Export…")
        chooseButton.title = String(localized: "Choose…")
        applyButton.title = String(localized: "Apply Template")
        rootLabel.stringValue = String(localized: "Project Root")
        rootField.setAccessibilityLabel(rootLabel.stringValue)
        hostLabel.stringValue = String(localized: "Remote Host")
        hostPopup.setAccessibilityLabel(hostLabel.stringValue)
        remoteDirectoryLabel.stringValue = String(localized: "Remote Directory")
        remoteDirectoryField.setAccessibilityLabel(remoteDirectoryLabel.stringValue)
        table.setAccessibilityLabel(String(localized: "Workspace Templates"))
        details.setAccessibilityLabel(String(localized: "Template Preview"))
        reload()
    }

    private var selected: WorkspaceTemplateStore.Entry? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    private func reload(selecting id: UUID? = nil) {
        guard panel != nil else { return }
        let selectedID = id ?? selected?.id
        entries = store.entries
        table.reloadData()
        if !entries.isEmpty {
            table.selectRowIndexes(IndexSet(integer: selectedID.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0),
                                  byExtendingSelection: false)
        }
        updateSelection()
    }

    private func updateSelection() {
        let template = selected?.template
        for button in [renameButton, editButton, exportButton, deleteButton, applyButton] { button.isEnabled = template != nil }
        updateSaveAvailability()
        applyButton.isEnabled = template != nil && manager != nil && !applying
        details.string = template.map(preview) ?? String(localized: "Save a project or import a template to get started.")
        let remote = template?.remote
        localBox?.isHidden = remote != nil
        remoteBox?.isHidden = remote == nil
        if let remoteNotice, statusLabel.stringValue == remoteNotice { statusLabel.stringValue = "" }
        remoteNotice = nil
        guard let remote, !applying else { return }
        remoteDirectoryField.stringValue = remote.directory
        hostPopup.removeAllItems()
        let hosts = RemoteHostStore.shared.hosts
        for host in hosts {
            hostPopup.addItem(withTitle: host.name)
            hostPopup.lastItem?.representedObject = host.id
        }
        if let index = hosts.firstIndex(where: { $0.name == remote.host }) {
            hostPopup.selectItem(at: index)
        } else {
            hostPopup.insertItem(withTitle: String(localized: "Choose a Saved Host"), at: 0)
            hostPopup.selectItem(at: 0)
            showRemoteNotice(WorkspaceTemplateError.remoteHostUnavailable(remote.host).localizedDescription)
        }
    }

    private func showRemoteNotice(_ message: String) {
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = message
        remoteNotice = message
    }

    @objc private func hostChanged(_ sender: Any?) {
        if hostPopup.selectedItem?.representedObject != nil, let remoteNotice, statusLabel.stringValue == remoteNotice {
            statusLabel.stringValue = ""
        }
    }

    private func updateSaveAvailability() {
        let enabled = manager?.selectedProject.map(WorkspaceTemplate.canCapture) ?? false
        if saveButton.isEnabled != enabled { saveButton.isEnabled = enabled }
    }

    private func preview(_ template: WorkspaceTemplate) -> String {
        var lines = [template.name, ""]
        if let remote = template.remote {
            lines += [String(localized: "Remote Host") + ": " + remote.host, String(localized: "Remote Directory") + ": " + remote.directory, ""]
        }
        for (index, tab) in template.tabs.enumerated() {
            lines.append(String(localized: "Tab \(index + 1)") + (tab.name.map { " · " + $0 } ?? ""))
            var paneIndex = 0
            func append(_ layout: WorkspaceTemplate.Layout, indent: String) {
                switch layout {
                case .pane(let pane):
                    let number = paneIndex + 1
                    let command = tab.terminals.first { $0.paneIndex == paneIndex }
                    paneIndex += 1
                    switch pane.content {
                    case .session(let directory):
                        lines.append(indent + String(localized: "Pane \(number)") + " · " + String(localized: "Terminal"))
                        lines.append(indent + "  " + String(localized: "Working Directory") + ": " + directory)
                        let argv = command?.argv?.map(TerminalSession.shellQuote).joined(separator: " ")
                        lines.append(indent + "  " + String(localized: "Startup Program") + ": " + (argv ?? String(localized: "Login Shell")))
                        if let initialization = command?.initializationCommand {
                            lines.append(indent + "  " + String(localized: "Initialization Command") + ": " + initialization)
                        }
                    case .browser(let url): lines.append(indent + String(localized: "Pane \(number)") + " · " + (url ?? String(localized: "New Browser Tab")))
                    case .file, .diff, .commitDiff: break
                    }
                case .split(let axis, let fraction, let first, let second):
                    lines.append(indent + (axis == .horizontal ? String(localized: "Horizontal Split") : String(localized: "Vertical Split"))
                                 + " · " + String(format: "%.0f%% / %.0f%%", fraction * 100, (1 - fraction) * 100))
                    append(first, indent: indent + "  ")
                    append(second, indent: indent + "  ")
                }
            }
            append(tab.layout, indent: "  ")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func saveCurrentProject(_ sender: Any?) {
        guard let project = manager?.selectedProject, let panel else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save Project as Template…")
        let name = NSTextField(string: project.name)
        name.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        name.setAccessibilityLabel(String(localized: "Template Name"))
        alert.accessoryView = name
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                let template = try WorkspaceTemplate.capture(project: project, name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
                let id = try self.store.add(template)
                self.statusLabel.stringValue = ""
                self.reload(selecting: id)
            } catch { self.statusLabel.stringValue = error.localizedDescription }
        }
        alert.window.makeFirstResponder(name)
    }

    @objc private func importTemplate(_ sender: Any?) {
        guard let panel else { return }
        let open = NSOpenPanel()
        open.allowedContentTypes = [.json]
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        open.prompt = String(localized: "Import")
        open.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = open.url, let self else { return }
            do { let id = try self.store.importTemplate(from: url); self.statusLabel.stringValue = ""; self.reload(selecting: id) }
            catch { self.statusLabel.stringValue = error.localizedDescription }
        }
    }

    @objc private func exportTemplate(_ sender: Any?) {
        guard let selected, let panel else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.json]
        save.nameFieldStringValue = "workspace-template.json"
        save.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = save.url, let self else { return }
            do { try self.store.exportTemplate(selected.id, to: url); self.statusLabel.stringValue = "" }
            catch { self.statusLabel.stringValue = error.localizedDescription }
        }
    }

    @objc private func renameTemplate(_ sender: Any?) {
        guard let selected, let panel else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Template Name")
        let field = NSTextField(string: selected.template.name)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.setAccessibilityLabel(String(localized: "Template Name"))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.store.rename(selected.id, to: field.stringValue); self.statusLabel.stringValue = "" }
            catch { self.statusLabel.stringValue = error.localizedDescription }
        }
        alert.window.makeFirstResponder(field)
    }

    @objc private func editTemplate(_ sender: Any?) {
        guard let selected, let panel else { return }
        editor = WorkspaceTemplateEditorController(entry: selected, store: store)
        editor?.show(on: panel)
    }

    @objc private func deleteTemplate(_ sender: Any?) {
        guard let selected, let panel else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete Template?")
        alert.informativeText = selected.template.name
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.store.delete(selected.id); self.statusLabel.stringValue = "" }
            catch { self.statusLabel.stringValue = error.localizedDescription }
        }
    }

    @objc private func chooseRoot(_ sender: Any?) {
        guard let panel else { return }
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.allowsMultipleSelection = false
        open.directoryURL = URL(fileURLWithPath: rootField.stringValue, isDirectory: true)
        open.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = open.url else { return }
            self?.rootField.stringValue = url.path
            self?.statusLabel.stringValue = ""
        }
    }

    @objc private func applyTemplate(_ sender: Any?) {
        guard let selected, let manager, !applying else { return }
        if let remote = selected.template.remote {
            guard let id = hostPopup.selectedItem?.representedObject as? UUID,
                  let host = RemoteHostStore.shared.hosts.first(where: { $0.id == id }) else {
                showRemoteNotice(WorkspaceTemplateError.remoteHostUnavailable(remote.host).localizedDescription)
                return
            }
            applying = true
            applyButton.isEnabled = false
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = String(localized: "Connecting…")
            let directory = remoteDirectoryField.stringValue
            Task { @MainActor [weak self] in
                var failure: Error?
                do { try await manager.applyRemoteWorkspaceTemplate(selected.template, host: host, directory: directory) }
                catch { failure = error }
                guard let self else { return }
                self.applying = false
                self.statusLabel.textColor = .systemRed
                self.statusLabel.stringValue = failure?.localizedDescription ?? ""
                self.applyButton.isEnabled = self.selected != nil && self.manager != nil
                if failure == nil { self.close() }
            }
            return
        }
        do { try manager.applyWorkspaceTemplate(selected.template, projectRoot: rootField.stringValue); close() }
        catch { statusLabel.stringValue = error.localizedDescription }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("workspace-template-row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = entries[row].template.name
        cell.toolTip = entries[row].template.name
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
}
