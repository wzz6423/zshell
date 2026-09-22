//
//  QuickLaunchPanelController.swift
//  zshell
//

import AppKit
import Combine
import FuzzyMatch

/// The borderless panel hosting Quick Launch. It becomes key — the search
/// field must take typing — while remaining a child of the owning Zshell
/// window so it cannot float above another application or Space.
final class QuickLaunchPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// The panel has no menu bar, so entry management shortcuts are matched
    /// here instead of through menu key equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let controller else {
            return super.performKeyEquivalent(with: event)
        }

        if flags == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "n" {
            controller.addEntry()
            return true
        }

        switch (event.charactersIgnoringModifiers, flags == .command) {
        case ("e", true):
            controller.editSelectedEntry()
            return true
        // kVK_Delete with ⌘ is the documented ⌘⌫ delete shortcut.
        case ("\u{7f}", true) where event.keyCode == 51:
            controller.deleteSelectedEntry()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    weak var controller: QuickLaunchPanelController?
}

/// The Quick Launch overlay: a child panel over the owning window listing the
/// saved command and SSH entries. Typing fuzzy-filters the list, Return
/// launches the selection in a new terminal session, and ⌘⇧N / ⌘E / ⌘⌫ manage
/// entries. One shared panel; opening again repositions it over the current
/// key window.
@MainActor
final class QuickLaunchPanelController: NSObject {
    static let shared = QuickLaunchPanelController()

    private static let panelWidth: CGFloat = 560
    private static let searchBarHeight: CGFloat = 44
    private static let footerHeight: CGFloat = 28
    private static let rowHeight: CGFloat = 30
    private static let headerHeight: CGFloat = 26
    private static let maxListHeight: CGFloat = 260
    private static let emptyListHeight: CGFloat = 74
    private static let topOffset: CGFloat = 110

    private var panel: QuickLaunchPanel?
    private weak var hostWindow: NSWindow?
    private weak var manager: TerminalManager?

    private let searchField = NSTextField()
    private let clearButton = NSButton()
    private var selectionButtons: [NSButton] = []
    // A table subclass: without it the table claims every mouse-down
    // (including ones on the rows' buttons), so the row's edit/delete
    // buttons could never receive a click.
    private let tableView = RowButtonTableView()
    private let scrollView = NSScrollView()
    private let emptyStateView = NSView()
    private let emptyTitleLabel = NSTextField(labelWithString: "")
    private let emptyHintLabel = NSTextField(labelWithString: "")
    private var listHeightConstraint: NSLayoutConstraint?
    private var lifetime: [AnyCancellable] = []

    /// Window-base location of the last mouse-down, recorded by a local
    /// monitor so the row's launch action can tell the row's edit/delete
    /// button clicks from plain row clicks.
    private var lastMouseDownLocation: NSPoint?
    private var mouseDownMonitor: Any?

    /// Rows as they appear in the list — grouped sections in the saved order
    /// when no filter is active, or the fuzzy filter's flat ranking once the
    /// user types.
    private var displayRows: [DisplayRow] = []
    private var query = "" {
        didSet {
            guard query != oldValue else { return }
            refilterAndReload(preservingSelection: false)
        }
    }

    private enum DisplayRow {
        case header(String)
        case entry(QuickLaunchEntry)

        var isEntry: Bool {
            if case .entry = self { return true }
            return false
        }
    }

    /// The entry shown at a table row, or nil for a group header.
    private func entry(atRow row: Int) -> QuickLaunchEntry? {
        guard displayRows.indices.contains(row),
              case .entry(let entry) = displayRows[row] else { return nil }
        return entry
    }

    private var selectedEntry: QuickLaunchEntry? {
        entry(atRow: tableView.selectedRow)
    }

    /// Smith-Waterman scoring, identical to the command palette so both
    /// overlays rank the same way.
    private static let fuzzyMatcher = FuzzyMatcher(config: .smithWaterman)

    private override init() {
        super.init()
        Theme.changes.objectWillChange.sink { [weak self] _ in
            self?.applyTheme()
        }.store(in: &lifetime)
        // Entries edited in the standalone editor window must show up here
        // without the panel being reopened; `@Published` fires from `willSet`,
        // so the refreshed list is read one hop later.
        QuickLaunchStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refilterAndReload() }
        }.store(in: &lifetime)
    }

    // MARK: - Show / close

    func toggle(manager: TerminalManager) {
        if panel?.isVisible == true {
            close()
        } else {
            show(manager: manager)
        }
    }

    func show(manager: TerminalManager) {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow) else { return }
        self.manager = manager
        hostWindow = host
        let panel = self.panel ?? makePanel()
        self.panel = panel

        searchField.stringValue = ""
        query = ""
        updateClearButton()
        refilterAndReload(preservingSelection: false)
        applyTheme()
        AppWindowPresentation.attach(panel, to: host, placement: .topCentered(Self.topOffset))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func close() {
        if let panel { AppWindowPresentation.hideChild(panel) }
        hostWindow = nil
    }

    private func contentSize() -> NSSize {
        let listHeight = displayRows.isEmpty
            ? Self.emptyListHeight
            : min(
                displayRows.reduce(0) { partial, row in
                    partial + (row.isEntry ? Self.rowHeight : Self.headerHeight)
                } + 12,
                Self.maxListHeight
            )
        let height = Self.searchBarHeight + 1 + listHeight + 1 + Self.footerHeight
        return NSSize(width: Self.panelWidth, height: height)
    }

    // MARK: - Panel construction

    private func makePanel() -> QuickLaunchPanel {
        let panel = QuickLaunchPanel(
            contentRect: NSRect(origin: .zero, size: contentSize()),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.controller = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .normal
        panel.collectionBehavior = []

        let content = QuickLaunchPanelContentView()
        content.onEffectiveAppearanceChange = { [weak self] in self?.applyTheme() }
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        panel.contentView = content

        // Sheet dimming is a sibling of the content view, so clip the window
        // frame as well to keep the panel's rounded corners transparent.
        if let frameView = content.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = 12
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.masksToBounds = true
        }

        buildSearchBar(in: content)
        buildList(in: content)
        buildFooter(in: content)

        self.panel = panel
        if mouseDownMonitor == nil {
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                if event.window === self?.panel {
                    self?.lastMouseDownLocation = event.locationInWindow
                }
                return event
            }
        }
        applyTheme()
        return panel
    }

    private func buildSearchBar(in content: NSView) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 15)
        searchField.placeholderString = String(
            localized: "Search quick launch entries…",
            comment: "Placeholder of the Quick Launch search field."
        )
        searchField.delegate = self
        searchField.setAccessibilityLabel(String(
            localized: "Search quick launch entries…",
            comment: "Accessibility label of the Quick Launch search field."
        ))

        // Two distinct affordances at the bar's right: the clear glyph is
        // the native search-field "erase" style and only appears while the
        // field has text; the close button is a bare ✕ at the bar's edge —
        // the borderless panel has no title bar, so before it Escape was
        // the only way out.
        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: nil
        )
        clearButton.isBordered = false
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearButton.setAccessibilityLabel(String(
            localized: "Clear Search",
            comment: "Accessibility label of the Quick Launch search clear button."
        ))

        let closeButton = NSButton(
            image: NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: nil
            ) ?? NSImage(),
            target: self,
            action: #selector(closeClicked)
        )
        closeButton.image = closeButton.image?.withSymbolConfiguration(
            .init(pointSize: 11, weight: .medium)
        )
        closeButton.isBordered = false
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setAccessibilityLabel(String(
            localized: "Close",
            comment: "Accessibility label of the Quick Launch panel's close button."
        ))

        let bar = NSStackView(views: [icon, searchField, clearButton, closeButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.setCustomSpacing(2, after: searchField)
        bar.setCustomSpacing(10, after: clearButton)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        let separator = HairlineView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.searchBarHeight),
            // Explicit heights: an image-only borderless button's natural
            // size is its ~11pt glyph, a click target far too small to hit.
            clearButton.widthAnchor.constraint(equalToConstant: 18),
            clearButton.heightAnchor.constraint(equalToConstant: 20),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        updateClearButton()
    }

    @objc private func closeClicked() {
        close()
    }

    @objc private func clearClicked() {
        searchField.stringValue = ""
        query = ""
        panel?.makeFirstResponder(searchField)
        updateClearButton()
    }

    private func updateClearButton() {
        clearButton.isHidden = searchField.stringValue.isEmpty
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
        // Row buttons handle their own clicks; the launch action ignores
        // events arriving after the panel closes, including a second click.
        tableView.action = #selector(tableViewClicked)
        tableView.setAccessibilityLabel(String(
            localized: "Quick Launch entries",
            comment: "Accessibility label of the Quick Launch entry list."
        ))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = Self.panelWidth
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        emptyTitleLabel.alignment = .center
        emptyTitleLabel.font = .systemFont(ofSize: 13)
        emptyTitleLabel.textColor = .secondaryLabelColor
        emptyHintLabel.alignment = .center
        emptyHintLabel.font = .systemFont(ofSize: 11)
        emptyHintLabel.textColor = .tertiaryLabelColor

        let emptyStack = NSStackView(views: [emptyTitleLabel, emptyHintLabel])
        emptyStack.orientation = .vertical
        emptyStack.spacing = 4
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyStack)
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyStateView)

        let listHeight = NSLayoutConstraint(
            item: scrollView,
            attribute: .height,
            relatedBy: .equal,
            toItem: nil,
            attribute: .notAnAttribute,
            multiplier: 1,
            constant: Self.emptyListHeight
        )
        listHeightConstraint = listHeight

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(
                equalTo: content.topAnchor,
                constant: Self.searchBarHeight + 1
            ),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listHeight,
            emptyStateView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            emptyStack.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
        ])
    }

    private func buildFooter(in content: NSView) {
        // The old footer was static key hints; they are buttons now so every
        // action also has a visible, clickable affordance.
        let hints: [(key: String, label: String, action: Selector)] = [
            ("↩", String(localized: "Launch", comment: "Quick Launch footer hint: Return launches the selected entry."), #selector(launchClicked)),
            ("⌘⇧N", String(localized: "New", comment: "Quick Launch footer hint: ⌘⇧N creates an entry."), #selector(newClicked)),
            ("⌘E", String(localized: "Edit", comment: "Quick Launch footer hint: ⌘E edits the selected entry."), #selector(editClicked)),
            ("⌘⌫", String(localized: "Delete", comment: "Quick Launch footer hint: ⌘⌫ deletes the selected entry."), #selector(deleteClicked)),
        ]
        var views: [NSView] = []
        for hint in hints {
            let button = NSButton(
                title: "\(hint.key)  \(hint.label)",
                target: self,
                action: hint.action
            )
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = .secondaryLabelColor
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            if hint.action != #selector(newClicked) {
                selectionButtons.append(button)
            }
            if hint.action == #selector(launchClicked) {
                button.keyEquivalent = "\r"
            }
            views.append(button)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cliHint = NSTextField(labelWithString: String(
            localized: "Run: zshell <name>",
            comment: "Quick Launch footer hint. Keep zshell unchanged; <name> is the saved entry name."
        ))
        cliHint.font = .systemFont(ofSize: 11)
        cliHint.textColor = .secondaryLabelColor
        cliHint.alignment = .right
        cliHint.lineBreakMode = .byTruncatingTail
        cliHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cliHint.toolTip = String(
            localized: "In the Zshell terminal, run zshell followed by the exact entry name. Quote names containing spaces, for example: zshell \"My Command\".",
            comment: "Explains how to launch a saved Quick Launch entry from the bundled zshell CLI. Keep zshell unchanged."
        )
        cliHint.setAccessibilityHelp(cliHint.toolTip)
        views.append(contentsOf: [spacer, cliHint])

        let footer = NSStackView(views: views)
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 4
        footer.setCustomSpacing(14, after: views[0])
        footer.setCustomSpacing(14, after: views[1])
        footer.setCustomSpacing(14, after: views[2])
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        let separator = HairlineView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
    }

    private func applyTheme() {
        guard let content = panel?.contentView, let layer = content.layer else { return }
        // Publishers can fire outside drawing, where the current appearance
        // differs from the panel's. Resolve layer colors in the panel's scope.
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = Theme.background.usingColorSpace(.sRGB)?.cgColor
            layer.borderColor = Theme.divider.usingColorSpace(.sRGB)?
                .withAlphaComponent(0.5)
                .cgColor
        }
        layer.borderWidth = 1
    }

    // MARK: - List updates

    private func refilterAndReload(preservingSelection: Bool = true) {
        let selectedID = preservingSelection ? selectedEntry?.id : nil
        refilter()
        reload(selectedID: selectedID)
    }

    private func refilter() {
        let entries = QuickLaunchStore.shared.entries
        displayRows.removeAll(keepingCapacity: true)
        let pattern = query.trimmingCharacters(in: .whitespaces)
        guard pattern.isEmpty else {
            displayRows = fuzzyRanked(entries: entries, pattern: pattern)
                .map { DisplayRow.entry($0.entry) }
            return
        }
        // No filter: group the saved order into sections, keeping each
        // group's first appearance position. Entries without a group share
        // one "Ungrouped" section, which only exists next to real groups.
        if entries.contains(where: { !$0.groupKey.isEmpty }) {
            var groupOrder: [String] = []
            var entriesByGroup: [String: [QuickLaunchEntry]] = [:]
            for entry in entries {
                let group = entry.groupKey
                if entriesByGroup[group] == nil {
                    groupOrder.append(group)
                    entriesByGroup[group] = []
                }
                entriesByGroup[group]?.append(entry)
            }
            for group in groupOrder {
                displayRows.append(.header(group.isEmpty
                    ? String(localized: "Ungrouped", comment: "Section title for Quick Launch entries without a group.")
                    : group))
                displayRows.append(
                    contentsOf: entriesByGroup[group, default: []].map { DisplayRow.entry($0) }
                )
            }
        } else {
            displayRows = entries.map(DisplayRow.entry)
        }
    }

    /// Smith-Waterman scoring, identical to the command palette so both
    /// overlays rank the same way.
    private func fuzzyRanked(
        entries: [QuickLaunchEntry],
        pattern: String
    ) -> [(entry: QuickLaunchEntry, score: Double, order: Int)] {
        let fuzzyQuery = Self.fuzzyMatcher.prepare(pattern)
        var buffer = Self.fuzzyMatcher.makeBuffer()
        var matches: [(entry: QuickLaunchEntry, score: Double, order: Int)] = []
        for (order, entry) in entries.enumerated() {
            var candidate = [entry.name, entry.detail, entry.group]
                .compactMap { $0 }
                .joined(separator: " ")
            guard let score = candidate.withUTF8({ bytes in
                Self.fuzzyMatcher.score(utf8: bytes, against: fuzzyQuery, buffer: &buffer)?.score
            }) else { continue }
            matches.append((entry, score, order))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.order < $1.order
        }
        return matches
    }

    private func reload(selectedID: UUID?) {
        guard let panel else { return }
        tableView.reloadData()

        let size = contentSize()
        listHeightConstraint?.constant = size.height - Self.searchBarHeight - Self.footerHeight - 2
        panel.setContentSize(size)
        if let hostWindow {
            AppWindowPresentation.position(
                panel,
                relativeTo: hostWindow,
                placement: .topCentered(Self.topOffset)
            )
        }
        tableView.sizeLastColumnToFit()

        if displayRows.isEmpty {
            emptyStateView.isHidden = false
            scrollView.isHidden = true
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                emptyTitleLabel.stringValue = String(
                    localized: "No Quick Launch Entries",
                    comment: "Empty state of the Quick Launch panel with no saved entries."
                )
                emptyHintLabel.stringValue = String(
                    localized: "Press ⌘⇧N to add your first entry.",
                    comment: "Hint in the empty Quick Launch panel."
                )
            } else {
                emptyTitleLabel.stringValue = String(
                    localized: "No Matches",
                    comment: "Empty state when a filter matches nothing."
                )
                emptyHintLabel.stringValue = ""
            }
        } else {
            emptyStateView.isHidden = true
            scrollView.isHidden = false
            let selectedRow = selectedID.flatMap { id in
                displayRows.indices.first { entry(atRow: $0)?.id == id }
            }
                ?? displayRows.firstIndex(where: \.isEntry)
            if let selectedRow {
                tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(selectedRow)
            }
        }
        updateSelectionButtons()
    }

    private func updateSelectionButtons() {
        let hasSelection = selectedEntry != nil
        for button in selectionButtons { button.isEnabled = hasSelection }
    }

    // MARK: - Actions

    /// Moves the selection to the next/previous entry row, stepping over
    /// group headers.
    private func moveSelection(_ delta: Int) {
        let entryRows = displayRows.indices.filter { displayRows[$0].isEntry }
        guard let first = entryRows.first, let last = entryRows.last else { return }
        var next = tableView.selectedRow + delta
        // Wrap around within the entry rows only.
        if next < first { next = last }
        if next > last { next = first }
        while !displayRows.indices.contains(next) || !displayRows[next].isEntry {
            next += delta > 0 ? 1 : -1
            if next < first { next = last }
            if next > last { next = first }
        }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func launchSelection() {
        guard panel?.isVisible == true, let entry = selectedEntry, let manager else { return }
        close()
        manager.runQuickLaunchEntry(entry)
    }

    @objc private func tableViewClicked() {
        guard panel?.isVisible == true else { return }
        // NSTableView fires this action for any click that selects a row.
        // With RowButtonTableView the row's buttons now receive their own
        // mouse-downs, so this normally only sees plain row clicks; the
        // button check stays as a guard for edge cases (e.g. a press that
        // started on a button and drifted). Clicks always fill clickedRow;
        // the selectedRow fallback covers programmatic action dispatch.
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, !clickLandedOnRowButton() else { return }
        if let entry = entry(atRow: row) {
            close()
            manager?.runQuickLaunchEntry(entry)
        }
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

    @objc private func launchClicked() {
        launchSelection()
    }

    func addEntry() {
        presentEditor(editing: nil)
    }

    @objc private func newClicked() {
        addEntry()
    }

    func editSelectedEntry() {
        guard let entry = selectedEntry else { return }
        editSelectedEntry(entry)
    }

    private func editSelectedEntry(_ entry: QuickLaunchEntry) {
        presentEditor(editing: entry)
    }

    @objc private func editClicked() {
        editSelectedEntry()
    }

    func deleteSelectedEntry() {
        guard let entry = selectedEntry else { return }
        deleteEntry(entry)
    }

    private func deleteEntry(_ entry: QuickLaunchEntry) {
        guard let panel else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Delete “\(entry.name)”?",
            comment: "Quick Launch entry deletion confirmation. The placeholder is an entry name."
        )
        alert.informativeText = String(
            localized: "The entry is removed from Quick Launch. Terminals it launched stay open.",
            comment: "Explanation in the Quick Launch deletion confirmation."
        )
        alert.addButton(withTitle: String(localized: "Delete"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        Task { @MainActor in
            let response = await alert.beginSheetModal(for: panel)
            guard response == .alertFirstButtonReturn else { return }
            QuickLaunchStore.shared.remove(entry)
        }
    }

    @objc private func deleteClicked() {
        deleteSelectedEntry()
    }

    private func presentEditor(editing entry: QuickLaunchEntry?) {
        QuickLaunchEditorController.present(editing: entry, relativeTo: panel)
    }
}

private extension QuickLaunchEntry {
    /// Keep the empty group distinct from a group named "Ungrouped".
    var groupKey: String {
        group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Table data

extension QuickLaunchPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayRows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        displayRows[row].isEntry ? Self.rowHeight : Self.headerHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        displayRows[row].isEntry
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        switch displayRows[row] {
        case .header(let title):
            let cell = (tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("quickLaunchHeader"),
                owner: nil
            ) as? QuickLaunchHeaderView) ?? QuickLaunchHeaderView()
            cell.identifier = NSUserInterfaceItemIdentifier("quickLaunchHeader")
            cell.configure(title: title)
            return cell
        case .entry(let entry):
            let cell = (tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("quickLaunchRow"),
                owner: nil
            ) as? QuickLaunchRowView) ?? QuickLaunchRowView()
            cell.identifier = NSUserInterfaceItemIdentifier("quickLaunchRow")
            cell.configure(entry: entry)
            cell.onEdit = { [weak self] in self?.editSelectedEntry(entry) }
            cell.onDelete = { [weak self] in self?.deleteEntry(entry) }
            return cell
        }
    }
}

/// A group section header row.
private final class QuickLaunchHeaderView: NSView {
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

/// One list row: kind symbol, entry name, and the command or `user@host` it
/// runs, mirroring the command palette's row layout. Trailing edit/delete
/// buttons take their own clicks without launching the entry.
private final class QuickLaunchRowView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    init() {
        super.init(frame: .zero)

        iconView.setAccessibilityElement(false)
        titleLabel.font = .systemFont(ofSize: 12.5)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let editButton = NSButton(
            image: NSImage(
                systemSymbolName: "pencil",
                accessibilityDescription: nil
            ) ?? NSImage(),
            target: self,
            action: #selector(editClicked)
        )
        editButton.isBordered = false
        editButton.contentTintColor = .tertiaryLabelColor
        editButton.setAccessibilityLabel(String(
            localized: "Edit",
            comment: "Accessibility label of a Quick Launch row's edit button."
        ))
        let deleteButton = NSButton(
            image: NSImage(
                systemSymbolName: "trash",
                accessibilityDescription: nil
            ) ?? NSImage(),
            target: self,
            action: #selector(deleteClicked)
        )
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .tertiaryLabelColor
        deleteButton.setAccessibilityLabel(String(
            localized: "Delete",
            comment: "Accessibility label of a Quick Launch row's delete button."
        ))

        let trailingSpacer = NSView()
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            iconView, titleLabel, detailLabel, trailingSpacer, editButton, deleteButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.setCustomSpacing(2, after: detailLabel)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            editButton.widthAnchor.constraint(equalToConstant: 18),
            // Same as the search bar: keep a real click target, not the
            // glyph's natural ~11pt.
            editButton.heightAnchor.constraint(equalToConstant: 20),
            deleteButton.widthAnchor.constraint(equalToConstant: 18),
            deleteButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func editClicked() { onEdit?() }
    @objc private func deleteClicked() { onDelete?() }

    func configure(entry: QuickLaunchEntry) {
        iconView.image = NSImage(
            systemSymbolName: entry.symbolName,
            accessibilityDescription: nil
        )
        titleLabel.stringValue = entry.name
        let detail = entry.detail ?? ""
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        toolTip = [entry.name, detail].filter { !$0.isEmpty }.joined(separator: "\n")
        setAccessibilityLabel(
            [entry.name, detail.isEmpty ? nil : detail]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }
}

/// A 1pt drawn hairline that re-resolves on appearance changes.
private final class HairlineView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The panel's root view, reporting appearance changes so the resolved layer
/// colors track a system light/dark switch even when no theme was selected.
private final class QuickLaunchPanelContentView: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }
}

// MARK: - Search field keyboard routing

extension QuickLaunchPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === searchField else { return }
        query = searchField.stringValue
        updateClearButton()
    }

    /// Keyboard routing while the search field holds focus: arrows move the
    /// selection, Return launches, Escape closes.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            launchSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}
