import AppKit
import Combine

@MainActor
final class EditorDraftRecoveryController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = EditorDraftRecoveryController()
    private var panel: NSPanel?
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView()
    private let restore = NSButton(title: "", target: nil, action: nil)
    private let delete = NSButton(title: "", target: nil, action: nil)
    private weak var manager: TerminalManager?
    private weak var host: NSWindow?
    private var records: [EditorDraftRecord] = []
    private var generation = 0
    private var loading = false
    private var languageObservation: AnyCancellable?

    func show(for manager: TerminalManager) {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow) else { return }
        if panel == nil { configure() }
        guard let panel else { return }
        if self.host !== host { self.host?.removeChildWindow(panel) }
        self.manager = manager
        self.host = host
        localize()
        panel.setFrameOrigin(NSPoint(x: host.frame.midX - panel.frame.width / 2,
                                    y: host.frame.midY - panel.frame.height / 2))
        host.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        refresh()
    }

    func close() {
        generation += 1
        if let panel { host?.removeChildWindow(panel); panel.orderOut(nil) }
        records.removeAll()
        preview.string = ""
        table.reloadData()
        manager = nil
        host = nil
    }

    func windowWillClose(_ notification: Notification) { close() }

    private func configure() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 530),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 350)
        panel.identifier = NSUserInterfaceItemIdentifier("editor-draft-recovery")
        panel.delegate = self
        self.panel = panel
        guard let content = panel.contentView else { return }
        table.delegate = self
        table.dataSource = self
        table.headerView = nil
        table.rowHeight = 52
        table.usesAlternatingRowBackgroundColors = true
        let column = NSTableColumn(identifier: .init("draft"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.borderType = .bezelBorder
        list.documentView = table
        preview.isEditable = false
        preview.isRichText = false
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.isVerticallyResizable = true
        preview.autoresizingMask = .width
        preview.textContainerInset = NSSize(width: 8, height: 8)
        let previewScroll = NSScrollView()
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.borderType = .bezelBorder
        previewScroll.documentView = preview
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [restore, delete] { button.target = self; button.bezelStyle = .rounded }
        restore.action = #selector(restoreSelected)
        restore.keyEquivalent = "\r"
        delete.action = #selector(deleteSelected)
        delete.hasDestructiveAction = true
        let actions = NSStackView(views: [delete, NSView(), restore])
        actions.orientation = .horizontal
        actions.spacing = 8
        for view in [status, list, previewScroll, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            list.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            list.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            list.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.35),
            previewScroll.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            previewScroll.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 12),
            previewScroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        languageObservation = NotificationCenter.default.publisher(for: AppLocalization.didChange)
            .sink { [weak self] _ in self?.localize(); self?.table.reloadData() }
    }

    private func localize() {
        panel?.title = String(localized: "Recover Drafts")
        table.setAccessibilityLabel(String(localized: "Recover Drafts"))
        preview.setAccessibilityLabel(String(localized: "Your Draft"))
        restore.title = String(localized: "Restore Draft")
        delete.title = String(localized: "Delete Backup")
        updateSelection()
    }

    private func refresh() {
        generation += 1
        let expected = generation
        loading = true
        updateSelection()
        EditorDraftStore.shared.prepareListing()
        Task { [weak self] in
            do {
                let records = try await EditorDraftStore.shared.archive.records()
                guard let self, self.generation == expected else { return }
                self.loading = false
                self.records = records
                self.table.reloadData()
                if !records.isEmpty { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                self.updateSelection()
            } catch {
                guard let self, self.generation == expected else { return }
                self.loading = false
                self.status.stringValue = String(localized: "Could not read editor draft backups.")
                self.restore.isEnabled = false
                self.delete.isEnabled = false
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        let name = NSTextField(labelWithString: URL(fileURLWithPath: record.path).lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let path = NSTextField(labelWithString: record.path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        let timestamp = NSTextField(labelWithString: record.updatedAt.formatted(date: .abbreviated, time: .shortened))
        timestamp.font = .systemFont(ofSize: 11)
        timestamp.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name, path])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.setHuggingPriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let rowView = NSStackView(views: [labels, timestamp])
        rowView.orientation = .horizontal
        rowView.alignment = .centerY
        rowView.spacing = 12
        rowView.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func updateSelection() {
        let selected = records.indices.contains(table.selectedRow) ? records[table.selectedRow] : nil
        restore.isEnabled = !loading && selected != nil && manager != nil
        delete.isEnabled = !loading && selected != nil
        preview.string = selected?.text ?? ""
        if loading { status.stringValue = String(localized: "Loading drafts…") }
        else if records.isEmpty { status.stringValue = String(localized: "No editor drafts to recover.") }
        else { status.stringValue = String(localized: "Restoring opens an unsaved editor. Files on disk are unchanged until you save.") }
    }

    @objc func restoreSelected() {
        guard !loading, records.indices.contains(table.selectedRow), let manager else { return }
        guard manager.restoreEditorDraft(records[table.selectedRow]) else { return }
        close()
    }

    @objc private func deleteSelected() {
        guard !loading, records.indices.contains(table.selectedRow), let panel else { return }
        let record = records[table.selectedRow]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete this draft backup?")
        alert.informativeText = String(localized: "The backup will be removed. Open edits and the file on disk are kept.")
        alert.addButton(withTitle: String(localized: "Delete Backup")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            EditorDraftStore.shared.discard(record.id)
            self?.refresh()
        }
    }
}

extension TerminalManager {
    @discardableResult
    func restoreEditorDraft(_ record: EditorDraftRecord) -> Bool {
        guard record.isValid else { return false }
        for manager in [self] + Self.automationManagers.filter({ $0 !== self }) {
            for project in manager.projects {
                for tab in project.tabs {
                    if let pane = tab.allPanes.first(where: { $0.content.draftID == record.id }) {
                        manager.selectedProjectID = project.id
                        project.selectedTabID = tab.id
                        tab.focusPane(pane.id)
                        manager.presentationWindow?.deminiaturize(nil)
                        manager.presentationWindow?.makeKeyAndOrderFront(nil)
                        if pane.content.isDirty { return true }
                        switch (pane.content, record.source) {
                        case (.file(let file), .file(let path)) where file.path == path:
                            file.restoreDraft(record.text, baseline: record.baseline)
                            if let state = record.sanitizedEditorState() { file.editorState = state }
                            return true
                        case (.diff(let diff), .diff(let root, let path, _, _)) where diff.repoRoot == root && diff.path == path:
                            diff.restoreDraft(record)
                            return true
                        default: break
                        }
                    }
                }
            }
        }
        let directory: String
        switch record.source {
        case .file(let path): directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        case .diff(let root, _, _, _): directory = root
        }
        let project: Project
        if let existing = projects.first(where: { !$0.isRemote && $0.customDirectory == directory }) {
            project = existing
        } else {
            _ = openOrFocusDirectories([directory])
            guard let selectedProject else { return false }
            project = selectedProject
        }
        selectedProjectID = project.id
        let content: PaneContent
        switch record.source {
        case .file(let path):
            let file = FileTab(path: path, draftID: record.id)
            file.restoreDraft(record.text, baseline: record.baseline)
            if let state = record.sanitizedEditorState() { file.editorState = state }
            content = .file(file)
        case .diff(let root, let path, let untracked, let original):
            let diff = DiffTab(repoRoot: root, path: path, staged: false, untracked: untracked,
                               origPath: original, draftID: record.id)
            diff.restoreDraft(record)
            content = .diff(diff)
        }
        let tab = PaneTab(content: content)
        project.append(tab)
        return true
    }
}
