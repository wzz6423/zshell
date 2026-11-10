import AppKit
import Combine
import SwiftUI

struct FileTreePanelView: NSViewRepresentable {
    let manager: TerminalManager
    let git: GitStatusModel
    let rootBadge: (text: String, description: String)?
    let currentFilePath: String?
    let fontScale: CGFloat
    let openSearchResult: (FileContentSearchModel.Match) -> Void

    func makeNSView(context: Context) -> AppKitFileTreePanel {
        let panel = AppKitFileTreePanel()
        panel.configure(manager: manager, git: git)
        panel.update(rootBadge: rootBadge, currentFilePath: currentFilePath,
                     fontScale: fontScale, openSearchResult: openSearchResult)
        return panel
    }

    func updateNSView(_ panel: AppKitFileTreePanel, context: Context) {
        panel.update(rootBadge: rootBadge, currentFilePath: currentFilePath,
                     fontScale: fontScale, openSearchResult: openSearchResult)
    }
}

@MainActor
final class AppKitFileTreePanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let searchButton = NSButton()
    private let revealButton = NSButton()
    private let importButton = NSButton()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton()
    private let header = NSView()
    private let notice = NSView()
    private let scrollView = NSScrollView()
    private let table = FileTreeTableView()
    private var searchPanel: FileContentSearchPanel?
    private weak var manager: TerminalManager?
    private weak var git: GitStatusModel?
    private var items: [FileTreeModel.Item] = []
    private var currentFilePath: String?
    private var metrics = SidebarLayoutMetrics(fontScale: 1)
    private var rootBadge: (text: String, description: String)?
    private var openSearchResult: (FileContentSearchModel.Match) -> Void = { _ in }
    private var observations: [AnyCancellable] = []
    private var syncScheduled = false
    private var lastRoot = ""
    private var selectedPath: String?
    private var dropPath: String?
    private var activeEdit: (item: FileTreeModel.Item, field: NSTextField)?
    private var editFocusScheduled = false
    private var updatingSelection = false

    private var model: FileTreeModel? { manager?.fileTree }
    private var isRemote: Bool { model?.isRemote == true || manager?.selectedProject?.isRemote == true }
    private var canMutate: Bool { !isRemote && !FileTreeImportController.shared.isImporting }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [titleLabel, pathLabel, badgeLabel] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            header.addSubview(label)
        }
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.textColor = .secondaryLabelColor
        badgeLabel.textColor = .secondaryLabelColor
        for button in [searchButton, revealButton, importButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
            button.contentTintColor = .secondaryLabelColor
            header.addSubview(button)
        }
        searchButton.action = #selector(toggleSearch)
        revealButton.action = #selector(revealRoot)
        importButton.action = #selector(chooseFiles)
        retryButton.target = self
        retryButton.action = #selector(retryRemote)
        retryButton.isBordered = false
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.maximumNumberOfLines = 4
        notice.addSubview(noticeLabel)
        notice.addSubview(retryButton)
        notice.isHidden = true
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateClickedRow)
        table.doubleAction = #selector(openClickedRow)
        table.setAccessibilityLabel(String(localized: "Files"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.menuForRow = { [weak self] row in self?.menu(for: row) }
        table.handleKey = { [weak self] event in self?.handleKey(event) ?? false }
        table.onDragExit = { [weak self] in self?.dropPath = nil; self?.updateVisibleRows() }
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy], forLocal: false)
        table.setDraggingSourceOperationMask([.copy], forLocal: true)
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        for view in [header, notice, scrollView] { addSubview(view) }
        setAccessibilityElement(false)
        refreshLanguage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(manager: TerminalManager, git: GitStatusModel) {
        self.manager = manager
        self.git = git
        observations = [
            manager.fileTree.objectWillChange.sink { [weak self] _ in self?.scheduleSync() },
            manager.fileContentSearch.$isActive.removeDuplicates().sink { [weak self] _ in self?.scheduleSync() },
            git.$fileDecorations.dropFirst().sink { [weak self] _ in self?.scheduleSync() },
            AppSettings.shared.objectWillChange.sink { [weak self] _ in self?.scheduleSync() },
            FileTreeImportController.shared.objectWillChange.sink { [weak self] _ in self?.scheduleSync() },
            NotificationCenter.default.publisher(for: AppLocalization.didChange).sink { [weak self] _ in
                self?.refreshLanguage()
                self?.scheduleSync()
            },
            NotificationCenter.default.publisher(for: .fileTreeImportDidFinish).sink { [weak self] notification in
                guard let self, notification.object as? TerminalManager === self.manager else { return }
                self.git?.refresh()
            },
            NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scrollView.contentView)
                .sink { [weak self] _ in self?.updateVisibleRows() },
        ]
        syncFromModel()
    }

    func update(rootBadge: (text: String, description: String)?, currentFilePath: String?, fontScale: CGFloat,
                openSearchResult: @escaping (FileContentSearchModel.Match) -> Void) {
        self.rootBadge = rootBadge
        self.currentFilePath = currentFilePath
        self.openSearchResult = openSearchResult
        metrics = SidebarLayoutMetrics(fontScale: fontScale)
        searchPanel?.update(fontScale: metrics.fontScale, openResult: openSearchResult)
        syncFromModel()
    }

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.syncScheduled = false
            self?.syncFromModel()
        }
    }

    private func syncFromModel() {
        guard let manager, let model else { return }
        titleLabel.stringValue = model.rootName
        pathLabel.stringValue = model.rootSubtitle
        pathLabel.toolTip = model.rootSubtitle
        titleLabel.font = .systemFont(ofSize: 12 * metrics.fontScale, weight: .semibold)
        pathLabel.font = .systemFont(ofSize: 10 * metrics.fontScale)
        badgeLabel.stringValue = rootBadge?.text ?? ""
        badgeLabel.font = .systemFont(ofSize: 9 * metrics.fontScale, weight: .medium)
        badgeLabel.setAccessibilityLabel(rootBadge?.description)
        badgeLabel.toolTip = rootBadge?.description
        searchButton.isHidden = isRemote
        revealButton.isHidden = isRemote
        importButton.isHidden = isRemote
        importButton.isEnabled = manager.canImportFiles && !model.rootPath.isEmpty
        retryButton.font = .systemFont(ofSize: 10.5 * metrics.fontScale, weight: .medium)
        noticeLabel.font = .systemFont(ofSize: 10.5 * metrics.fontScale)
        let searching = manager.fileContentSearch.isActive && !isRemote
        if searching, searchPanel == nil {
            endEditing(commit: true)
            let panel = FileContentSearchPanel()
            searchPanel = panel
            addSubview(panel)
            panel.configure(model: manager.fileContentSearch, fontScale: metrics.fontScale, openResult: openSearchResult)
        } else if !searching, let panel = searchPanel {
            panel.removeFromSuperview()
            searchPanel = nil
        }
        searchPanel?.isHidden = !searching
        scrollView.isHidden = searching
        if isRemote, let error = model.remoteError {
            noticeLabel.stringValue = error
            retryButton.isHidden = false
            notice.isHidden = searching
        } else if isRemote, model.isRemoteLoading, model.items.isEmpty {
            noticeLabel.stringValue = String(localized: "Loading remote directory…")
            retryButton.isHidden = true
            notice.isHidden = searching
        } else {
            notice.isHidden = true
        }
        let newHeight = metrics.lineHeight(designedFontSize: 11.5, minimum: 16) + 6
        if table.rowHeight != newHeight { table.rowHeight = newHeight }
        if lastRoot != model.rootPath {
            endEditing(commit: false)
            selectedPath = nil
            lastRoot = model.rootPath
            scrollView.contentView.scroll(to: .zero)
        }
        if items != model.items {
            let oldItems = items
            let stableRows = oldItems.count == model.items.count
                && zip(oldItems, model.items).allSatisfy { $0.path == $1.path }
            items = model.items
            if stableRows { updateVisibleRows() }
            else {
                // Keep the field editor during a background listing. Reload
                // only when row identity changes, then restore an active edit.
                let editText = activeEdit?.field.stringValue
                let editItem = activeEdit?.item
                activeEdit = nil
                updatingSelection = true
                table.reloadData()
                restoreSelection()
                updatingSelection = false
                if let editItem, let index = items.firstIndex(where: { $0.path == editItem.path }),
                   model.renamingPath == editItem.path || (editItem.isDraft && model.draft != nil) {
                    beginEditing(at: index, text: editText)
                }
            }
        } else { updateVisibleRows() }
        if activeEdit == nil, let index = items.firstIndex(where: { $0.isDraft || $0.path == model.renamingPath }) {
            beginEditing(at: index)
        } else if let edit = activeEdit,
                  model.renamingPath != edit.item.path && !(edit.item.isDraft && model.draft != nil) {
            endEditing(commit: false)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        let width = max(0, bounds.width - inset * 2)
        let lineHeight = metrics.lineHeight(designedFontSize: 12, weight: .semibold, minimum: 16)
        let subtitleHeight = metrics.lineHeight(designedFontSize: 10, minimum: 13)
        let controlsOnSecondLine = width < 220 * metrics.growthScale
        let headerHeight = lineHeight + subtitleHeight + 17 + (controlsOnSecondLine ? 24 * metrics.growthScale : 0)
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        let buttons = [importButton, searchButton, revealButton].filter { !$0.isHidden }
        let slot = max(22, metrics.slotSize(20))
        let controlsWidth = CGFloat(buttons.count) * slot
        let labelWidth = max(0, width - (controlsOnSecondLine ? 0 : controlsWidth + 6))
        let badgeWidth = rootBadge == nil ? 0 : min(labelWidth * 0.35, badgeLabel.intrinsicContentSize.width + 6)
        titleLabel.frame = NSRect(x: inset, y: 7, width: max(0, labelWidth - badgeWidth), height: lineHeight)
        pathLabel.frame = NSRect(x: inset, y: 7 + lineHeight + 1, width: labelWidth, height: subtitleHeight)
        badgeLabel.isHidden = badgeWidth == 0
        badgeLabel.frame = NSRect(x: inset + labelWidth - badgeWidth, y: 7, width: badgeWidth, height: lineHeight)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: bounds.width - inset - controlsWidth + CGFloat(index) * slot,
                                  y: controlsOnSecondLine ? 9 + lineHeight + subtitleHeight : 9,
                                  width: slot, height: slot)
            button.image = NSImage(systemSymbolName: button === importButton ? "square.and.arrow.down" : button === searchButton ? "magnifyingglass" : "arrow.up.forward.app",
                                   accessibilityDescription: nil)?.withSymbolConfiguration(
                .init(pointSize: 11 * metrics.fontScale, weight: .regular))
        }
        var y = headerHeight
        if !notice.isHidden {
            let retryWidth = retryButton.isHidden ? 0 : min(width * 0.35, retryButton.intrinsicContentSize.width + 8)
            let textWidth = max(1, width - retryWidth - (retryWidth > 0 ? 6 : 0))
            let textHeight = noticeLabel.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            let height = max(18, min(textHeight, 4 * (noticeLabel.font?.boundingRectForFont.height ?? 14))) + 8
            notice.frame = NSRect(x: inset, y: y, width: width, height: height)
            noticeLabel.frame = NSRect(x: 0, y: 0, width: textWidth, height: height - 8)
            retryButton.frame = NSRect(x: width - retryWidth, y: 0, width: retryWidth, height: 22)
            y += height
        }
        let content = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
        scrollView.frame = content.insetBy(dx: 6, dy: 0)
        searchPanel?.frame = content
        table.sizeLastColumnToFit()
        updateVisibleRows()
    }

    private func refreshLanguage() {
        for (button, title) in [(importButton, String(localized: "Import Files…")),
                                (searchButton, String(localized: "Search File Contents")),
                                (revealButton, String(localized: "Reveal in Finder"))] {
            button.toolTip = title
            button.setAccessibilityLabel(title)
        }
        retryButton.title = String(localized: "Retry")
        table.setAccessibilityLabel(String(localized: "Files"))
        updateVisibleRows()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FileTreeRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileTreeRowView ?? FileTreeRowView()
        cell.identifier = identifier
        configure(cell, at: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FileTreeSelectionRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        selectedPath = item(at: table.selectedRow)?.path
        manager?.fileTreeImportDirectory = item(at: table.selectedRow).map {
            $0.isDirectory ? $0.path : ($0.path as NSString).deletingLastPathComponent
        }
        updateVisibleRows()
    }

    private func configure(_ cell: FileTreeRowView, at row: Int) {
        guard let item = item(at: row), let model else { return }
        let decoration = isRemote ? nil : git?.fileDecoration(for: item.path, isDirectory: item.isDirectory)
        cell.configure(item: item, expanded: model.isExpanded(item), decoration: decoration,
                       current: item.path == currentFilePath, selected: item.path == selectedPath,
                       drop: item.path == dropPath, scale: metrics.fontScale)
        cell.onPress = { [weak self] in
            if item.isDirectory { self?.model?.toggle(item) }
            else if self?.isRemote == false { self?.manager?.previewFile(item.path) }
        }
    }

    private func updateVisibleRows() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<NSMaxRange(visible) where items.indices.contains(row) {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileTreeRowView {
                configure(cell, at: row)
            }
        }
    }

    private func item(at row: Int) -> FileTreeModel.Item? { items.indices.contains(row) ? items[row] : nil }

    private func restoreSelection() {
        guard let selectedPath, let row = items.firstIndex(where: { $0.path == selectedPath }) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func activateClickedRow() {
        guard let item = item(at: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow), !item.isDraft else { return }
        if item.isDirectory { model?.toggle(item) }
        else if !isRemote, NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        } else if !isRemote { manager?.previewFile(item.path) }
    }

    @objc private func openClickedRow() {
        guard let item = item(at: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow), !item.isDraft else { return }
        if !item.isDirectory, !isRemote { manager?.openFile(item.path) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "c", let item = item(at: table.selectedRow) {
            copyPath(item.path)
            return true
        }
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let item = item(at: table.selectedRow), !item.isDraft else { return false }
        switch event.keyCode {
        case 36, 76:
            if item.isDirectory { model?.toggle(item) } else if !isRemote { manager?.openFile(item.path) }
        case 49:
            if item.isDirectory { model?.toggle(item) } else if !isRemote { manager?.previewFile(item.path) }
        case 124:
            if item.isDirectory, model?.isExpanded(item) == false { model?.toggle(item) }
            else if item.isDirectory, items.indices.contains(table.selectedRow + 1), items[table.selectedRow + 1].depth > item.depth {
                table.selectRowIndexes(IndexSet(integer: table.selectedRow + 1), byExtendingSelection: false)
            }
        case 123:
            if item.isDirectory, model?.isExpanded(item) == true { model?.toggle(item) }
            else if let parent = items[..<table.selectedRow].lastIndex(where: { $0.depth < item.depth && $0.isDirectory }) {
                table.selectRowIndexes(IndexSet(integer: parent), byExtendingSelection: false)
                table.scrollRowToVisible(parent)
            }
        case 120:
            guard canMutate else { return false }
            model?.beginRename(item)
        default: return false
        }
        return true
    }

    private func menu(for row: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let model else { return menu }
        let item = item(at: row)
        let directory = item.map { $0.isDirectory ? $0.path : ($0.path as NSString).deletingLastPathComponent } ?? model.rootPath
        func add(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
            let item = FileTreeMenuItem(title: title, action: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if isRemote {
            if let item, item.isDirectory {
                add(String(localized: "cd Here")) { [weak self] in self?.cd(to: item.path) }
            }
            if let item { add(String(localized: "Copy Path")) { self.copyPath(item.path) } }
            return menu
        }
        if let item, !item.isDraft {
            if !item.isDirectory {
                add(String(localized: "Open")) { [weak self] in self?.manager?.openFile(item.path) }
                add(String(localized: "Open to the Side")) { [weak self] in self?.manager?.openFileToSide(item.path) }
            }
            let editor = AppSettings.shared.externalEditor
            add(editor.openTitle, enabled: editor.isAvailable) { editor.open(URL(fileURLWithPath: item.path)) }
            add(String(localized: "Open in Default App")) { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
            add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            add(String(localized: "Copy Path")) { self.copyPath(item.path) }
            if item.isDirectory { add(String(localized: "cd Here")) { [weak self] in self?.cd(to: item.path) } }
            menu.addItem(.separator())
        }
        add(String(localized: "Import Files…"), enabled: manager?.canImportFiles == true && !model.rootPath.isEmpty) { [weak self] in
            guard let manager = self?.manager else { return }
            manager.importFiles(into: directory)
        }
        if item == nil || item?.isDirectory == true {
            add(String(localized: "New File…"), enabled: canMutate) { model.beginNewFile(in: directory) }
            add(String(localized: "New Folder…"), enabled: canMutate) { model.beginNewFolder(in: directory) }
        }
        if let item, !item.isDraft {
            menu.addItem(.separator())
            add(String(localized: "Rename"), enabled: canMutate) { model.beginRename(item) }
            add(String(localized: "Move to Trash"), enabled: canMutate) { [weak self] in
                model.moveToTrash(item)
                self?.git?.refresh()
            }
        }
        return menu
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func cd(to path: String) {
        manager?.selectedSession?.sendCommand("cd " + TerminalSession.shellQuote(path) + "\n")
    }

    @objc private func toggleSearch() { manager?.fileContentSearch.toggle() }
    @objc private func revealRoot() {
        guard let model else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.rootPath)])
    }
    @objc private func chooseFiles() { manager?.importFiles() }
    @objc private func retryRemote() { model?.retryRemoteRoot() }

    private func beginEditing(at row: Int, text: String? = nil) {
        guard canMutate, let item = item(at: row) else { return }
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileTreeRowView else { return }
        let field = cell.beginEditing(text: text ?? (item.isDraft ? "" : item.name),
                                      placeholder: item.isDraft ? (item.isDirectory ? String(localized: "Folder name") : String(localized: "File name")) : String(localized: "Name"))
        field.delegate = self
        activeEdit = (item, field)
        guard !editFocusScheduled else { return }
        editFocusScheduled = true
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self else { return }
            self.editFocusScheduled = false
            guard let field, self.activeEdit?.field === field else { return }
            self.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    private func endEditing(commit: Bool) {
        guard let edit = activeEdit, let model else { return }
        let name = edit.field.stringValue
        activeEdit = nil
        edit.field.delegate = nil
        let currentEdit = model.renamingPath == edit.item.path || (edit.item.isDraft && model.draft != nil)
        if currentEdit, commit, canMutate {
            if edit.item.isDraft {
                if let created = model.commitDraft(name: name) { manager?.openFile(created) }
                git?.refresh()
            } else if let destination = model.rename(edit.item, to: name) {
                manager?.fileRenamed(from: edit.item.path, to: destination)
                selectedPath = destination
                git?.refresh()
            }
        } else if currentEdit {
            if edit.item.isDraft { model.cancelDraft() } else { model.cancelRename() }
        }
        if window?.firstResponder === edit.field.currentEditor() { window?.makeFirstResponder(table) }
        (edit.field.superview as? FileTreeRowView)?.endEditing()
        updateVisibleRows()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard !isRemote, let item = item(at: row), !item.isDraft, activeEdit == nil else { return nil }
        return URL(fileURLWithPath: item.path) as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard AppSettings.shared.fileTreeDragImport, manager?.canImportFiles == true, model?.rootPath.isEmpty == false,
              canMutate, !items.contains(where: \.isDraft),
              activeEdit == nil, !draggedURLs(info).isEmpty,
              info.draggingSource as? NSTableView !== table else {
            dropPath = nil
            updateVisibleRows()
            return []
        }
        let targetRow = row >= 0 && row < items.count ? row : -1
        let item = item(at: targetRow)
        dropPath = item.map { $0.isDirectory ? $0.path : ($0.path as NSString).deletingLastPathComponent } ?? model?.rootPath
        if item?.isDirectory == true { table.setDropRow(targetRow, dropOperation: .on) }
        else { table.setDropRow(-1, dropOperation: .on) }
        updateVisibleRows()
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        defer { dropPath = nil; updateVisibleRows() }
        guard AppSettings.shared.fileTreeDragImport, canMutate, let manager,
              let directory = dropPath, info.draggingSource as? NSTableView !== table else { return false }
        let urls = draggedURLs(info)
        guard !urls.isEmpty else { return false }
        FileTreeImportController.shared.importFiles(urls, manager: manager, directory: directory)
        return true
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

extension AppKitFileTreePanel: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === activeEdit?.field else { return }
        endEditing(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            endEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(commit: false)
            return true
        default: return false
        }
    }
}

private final class FileTreeTableView: NSTableView {
    var menuForRow: ((Int) -> NSMenu?)?
    var handleKey: ((NSEvent) -> Bool)?
    var onDragExit: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return menuForRow?(row)
    }

    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragExit?()
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField, field.isEditable, field.isDescendant(of: self) { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

private final class FileTreeSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
}

private final class FileTreeRowView: NSView {
    private let disclosure = NSImageView()
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var item: FileTreeModel.Item?
    private var scale: CGFloat = 1
    private var selected = false
    private var current = false
    private var drop = false
    private var hovered = false
    private var field: NSTextField?
    private var tracking: NSTrackingArea?
    var onPress: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [disclosure, icon, nameLabel, statusLabel] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: FileTreeModel.Item, expanded: Bool, decoration: GitStatusModel.FileDecoration?,
                   current: Bool, selected: Bool, drop: Bool, scale: CGFloat) {
        if self.item?.path != item.path {
            field?.delegate = nil
            field?.removeFromSuperview()
            field = nil
        }
        self.item = item
        self.current = current
        self.selected = selected
        self.drop = drop
        self.scale = scale
        disclosure.image = item.isDirectory && !item.isDraft
            ? NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8 * scale, weight: .semibold)) : nil
        disclosure.contentTintColor = .tertiaryLabelColor
        icon.image = item.isDirectory
            ? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10 * scale, weight: .regular))
            : MaterialFileIcon.image(forPath: item.path, appearance: effectiveAppearance)
        icon.contentTintColor = item.isDirectory ? Theme.accent.withAlphaComponent(0.8) : nil
        nameLabel.stringValue = item.name
        nameLabel.font = .systemFont(ofSize: 11.5 * scale)
        nameLabel.textColor = decoration?.fileTreeColor ?? (item.name.hasPrefix(".") ? .secondaryLabelColor.withAlphaComponent(0.55) : .secondaryLabelColor)
        nameLabel.isHidden = field != nil
        statusLabel.stringValue = decoration?.fileTreeBadge ?? ""
        statusLabel.font = .monospacedSystemFont(ofSize: 9 * scale, weight: .semibold)
        statusLabel.textColor = decoration?.fileTreeColor
        statusLabel.isHidden = field != nil || decoration == nil
        toolTip = item.path
        setAccessibilityLabel(item.name + (decoration.map { ", " + $0.fileTreeAccessibilityName } ?? ""))
        setAccessibilityValue(item.isDirectory ? (expanded ? String(localized: "Expanded") : String(localized: "Collapsed")) : nil)
        needsLayout = true
        needsDisplay = true
    }

    func beginEditing(text: String, placeholder: String) -> NSTextField {
        field?.removeFromSuperview()
        let input = NSTextField(string: text)
        input.placeholderString = placeholder
        input.font = .systemFont(ofSize: 11.5 * scale)
        input.isBezeled = true
        input.bezelStyle = .roundedBezel
        input.focusRingType = .exterior
        input.setAccessibilityLabel(placeholder)
        field = input
        addSubview(input)
        nameLabel.isHidden = true
        statusLabel.isHidden = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        return input
    }

    func endEditing() {
        field?.removeFromSuperview()
        field = nil
        nameLabel.isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        let glyph = max(14, 14 * scale)
        let indentation = min(CGFloat(item.depth) * 12, max(0, bounds.width * 0.35))
        let x = indentation + 6
        disclosure.frame = NSRect(x: x, y: (bounds.height - 12) / 2, width: 10, height: 12)
        icon.frame = NSRect(x: x + 15, y: (bounds.height - glyph) / 2, width: glyph, height: glyph)
        let labelX = x + 15 + glyph + 5
        let statusWidth = statusLabel.isHidden ? 0 : min(18 * scale, bounds.width * 0.1)
        let width = max(0, bounds.width - labelX - statusWidth - 6)
        nameLabel.frame = NSRect(x: labelX, y: 1, width: width, height: bounds.height - 2)
        statusLabel.frame = NSRect(x: bounds.width - statusWidth - 6, y: 1, width: statusWidth, height: bounds.height - 2)
        field?.frame = NSRect(x: labelX, y: 0, width: max(0, bounds.width - labelX - 4), height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let alpha: CGFloat = selected || current ? 0.09 : hovered || item?.isDraft == true ? 0.05 : 0
        if alpha > 0 {
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        if drop {
            Theme.accent.withAlphaComponent(0.55).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        self.tracking = tracking
        addTrackingArea(tracking)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func accessibilityPerformPress() -> Bool {
        guard let table = ancestorTable(), let onPress else { return false }
        let row = table.row(for: self)
        guard row >= 0 else { return false }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        onPress()
        return true
    }

    private func ancestorTable() -> NSTableView? {
        var view = superview
        while let current = view {
            if let table = current as? NSTableView { return table }
            view = current.superview
        }
        return nil
    }
}

private final class FileTreeMenuItem: NSMenuItem {
    private let onAction: () -> Void
    init(title: String, action: @escaping () -> Void) {
        onAction = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { if isEnabled { onAction() } }
}

private extension GitStatusModel.FileDecoration {
    var fileTreeBadge: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .untracked: "U"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .conflict: "!"
        case .ignored: "I"
        }
    }
    var fileTreeAccessibilityName: String {
        switch self {
        case .modified: String(localized: "Modified")
        case .added: String(localized: "Added")
        case .untracked: String(localized: "Untracked")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .copied: String(localized: "Copied")
        case .conflict: String(localized: "Conflict")
        case .ignored: String(localized: "Ignored")
        }
    }
    var fileTreeColor: NSColor {
        switch self {
        case .modified: NSColor(calibratedRed: 0.82, green: 0.60, blue: 0.13, alpha: 1)
        case .added, .untracked: NSColor(calibratedRed: 0.25, green: 0.73, blue: 0.31, alpha: 1)
        case .deleted: NSColor(calibratedRed: 1, green: 0.48, blue: 0.45, alpha: 1)
        case .renamed, .copied: NSColor(calibratedRed: 0.35, green: 0.65, blue: 1, alpha: 1)
        case .conflict: NSColor(calibratedRed: 0.74, green: 0.55, blue: 1, alpha: 1)
        case .ignored: NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        }
    }
}
