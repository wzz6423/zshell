//
//  QuickLaunchPanelController.swift
//  zshell
//

import AppKit
import Combine
import FuzzyMatch

/// The borderless panel hosting Quick Launch. It becomes key — the search
/// field must take typing — while `nonactivatingPanel` keeps the owning app
/// frontmost, matching how Spotlight-style overlays behave.
final class QuickLaunchPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// The panel has no menu bar, so entry management shortcuts are matched
    /// here instead of through menu key equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let controller else {
            return super.performKeyEquivalent(with: event)
        }

        switch (event.charactersIgnoringModifiers, flags == .command) {
        case ("n", true):
            controller.addEntry()
            return true
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

/// The Quick Launch overlay: a floating panel over the key window listing the
/// saved command and SSH entries. Typing fuzzy-filters the list, Return
/// launches the selection in a new terminal session, and ⌘N / ⌘E / ⌘⌫ manage
/// entries. One shared panel; opening again repositions it over the current
/// key window.
@MainActor
final class QuickLaunchPanelController: NSObject {
    static let shared = QuickLaunchPanelController()

    private static let panelWidth: CGFloat = 560
    private static let searchBarHeight: CGFloat = 44
    private static let footerHeight: CGFloat = 28
    private static let rowHeight: CGFloat = 30
    private static let maxListHeight: CGFloat = 260
    private static let emptyListHeight: CGFloat = 74
    private static let topOffset: CGFloat = 110

    private var panel: QuickLaunchPanel?
    private weak var manager: TerminalManager?

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyStateView = NSView()
    private let emptyTitleLabel = NSTextField(labelWithString: "")
    private let emptyHintLabel = NSTextField(labelWithString: "")
    private var listHeightConstraint: NSLayoutConstraint?
    private var lifetime: [AnyCancellable] = []

    /// Entries as they appear in the list — the saved order, or the fuzzy
    /// filter's ranking once the user types.
    private var visibleEntries: [QuickLaunchEntry] = []
    private var query = "" {
        didSet {
            guard query != oldValue else { return }
            refilterAndReload()
        }
    }

    private var selectedEntry: QuickLaunchEntry? {
        let row = tableView.selectedRow
        guard visibleEntries.indices.contains(row) else { return nil }
        return visibleEntries[row]
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
        self.manager = manager
        let panel = self.panel ?? makePanel()
        self.panel = panel

        searchField.stringValue = ""
        query = ""
        refilterAndReload()
        applyTheme()
        position(panel: panel)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func position(panel: NSPanel) {
        let size = contentSize()
        // Position over the window Quick Launch was invoked from; the panel
        // is not key yet at this point, so the key window is that window.
        guard let host = NSApp.keyWindow, host !== panel else {
            if let screen = NSScreen.main {
                panel.setFrame(
                    NSRect(
                        x: screen.visibleFrame.midX - size.width / 2,
                        y: screen.visibleFrame.midY - size.height / 2 + 80,
                        width: size.width,
                        height: size.height
                    ),
                    display: false
                )
            }
            return
        }
        let hostFrame = host.frame
        panel.setFrame(
            NSRect(
                x: hostFrame.midX - size.width / 2,
                y: hostFrame.maxY - Self.topOffset - size.height,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }

    private func contentSize() -> NSSize {
        let listHeight = visibleEntries.isEmpty
            ? Self.emptyListHeight
            : min(CGFloat(visibleEntries.count) * Self.rowHeight + 12, Self.maxListHeight)
        let height = Self.searchBarHeight + 1 + listHeight + 1 + Self.footerHeight
        return NSSize(width: Self.panelWidth, height: height)
    }

    // MARK: - Panel construction

    private func makePanel() -> QuickLaunchPanel {
        let panel = QuickLaunchPanel(
            contentRect: NSRect(origin: .zero, size: contentSize()),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.controller = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]

        let content = QuickLaunchPanelContentView()
        content.onEffectiveAppearanceChange = { [weak self] in self?.applyTheme() }
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        panel.contentView = content

        buildSearchBar(in: content)
        buildList(in: content)
        buildFooter(in: content)

        self.panel = panel
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

        let bar = NSStackView(views: [icon, searchField])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
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
            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
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
        tableView.doubleAction = #selector(tableViewDoubleClicked)
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
        let hints: [(key: String, label: String)] = [
            ("↩", String(localized: "Launch", comment: "Quick Launch footer hint: Return launches the selected entry.")),
            ("⌘N", String(localized: "New", comment: "Quick Launch footer hint: ⌘N creates an entry.")),
            ("⌘E", String(localized: "Edit", comment: "Quick Launch footer hint: ⌘E edits the selected entry.")),
            ("⌘⌫", String(localized: "Delete", comment: "Quick Launch footer hint: ⌘⌫ deletes the selected entry.")),
        ]
        var views: [NSView] = []
        for hint in hints {
            let key = NSTextField(labelWithString: hint.key)
            key.font = .systemFont(ofSize: 11)
            key.textColor = .tertiaryLabelColor
            let label = NSTextField(labelWithString: hint.label)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            views.append(contentsOf: [key, label])
        }
        let footer = NSStackView(views: views)
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 4
        footer.setCustomSpacing(14, after: views[1])
        footer.setCustomSpacing(14, after: views[3])
        footer.setCustomSpacing(14, after: views[5])
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
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
        // Theme colors are dynamic; resolving into CG colors snapshots the
        // current appearance, so this runs on every theme and appearance edge.
        layer.backgroundColor = Theme.background.usingColorSpace(.sRGB)?.cgColor
        layer.borderColor = Theme.divider.usingColorSpace(.sRGB)?
            .withAlphaComponent(0.5)
            .cgColor
        layer.borderWidth = 1
    }

    // MARK: - List updates

    private func refilterAndReload() {
        refilter()
        reload()
    }

    private func refilter() {
        let entries = QuickLaunchStore.shared.entries
        let pattern = query.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else {
            visibleEntries = entries
            return
        }
        let fuzzyQuery = Self.fuzzyMatcher.prepare(pattern)
        var buffer = Self.fuzzyMatcher.makeBuffer()
        var matches: [(entry: QuickLaunchEntry, score: Double, order: Int)] = []
        for (order, entry) in entries.enumerated() {
            var candidate = [entry.name, entry.detail]
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
        visibleEntries = matches.map(\.entry)
    }

    private func reload() {
        guard let panel else { return }
        tableView.reloadData()

        let size = contentSize()
        listHeightConstraint?.constant = size.height - Self.searchBarHeight - Self.footerHeight - 2
        panel.setContentSize(size)
        tableView.sizeLastColumnToFit()

        if visibleEntries.isEmpty {
            emptyStateView.isHidden = false
            scrollView.isHidden = true
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                emptyTitleLabel.stringValue = String(
                    localized: "No Quick Launch Entries",
                    comment: "Empty state of the Quick Launch panel with no saved entries."
                )
                emptyHintLabel.stringValue = String(
                    localized: "Press ⌘N to add your first entry.",
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
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    // MARK: - Actions

    private func moveSelection(_ delta: Int) {
        guard !visibleEntries.isEmpty else { return }
        let count = visibleEntries.count
        let current = max(0, tableView.selectedRow)
        let next = (current + delta + count) % count
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func launchSelection() {
        guard let entry = selectedEntry, let manager else { return }
        close()
        manager.runQuickLaunchEntry(entry)
    }

    func addEntry() {
        presentEditor(editing: nil)
    }

    func editSelectedEntry() {
        guard let entry = selectedEntry else { return }
        presentEditor(editing: entry)
    }

    func deleteSelectedEntry() {
        guard let entry = selectedEntry, let panel else { return }
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

    private func presentEditor(editing entry: QuickLaunchEntry?) {
        QuickLaunchEditorController.present(editing: entry, relativeTo: panel)
    }

    @objc private func tableViewDoubleClicked() {
        launchSelection()
    }
}

// MARK: - Table data

extension QuickLaunchPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleEntries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let entry = visibleEntries[row]
        let cell = (tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("quickLaunchRow"),
            owner: nil
        ) as? QuickLaunchRowView) ?? QuickLaunchRowView()
        cell.identifier = NSUserInterfaceItemIdentifier("quickLaunchRow")
        cell.configure(entry: entry)
        return cell
    }
}

/// One list row: kind symbol, entry name, and the command or `user@host` it
/// runs, mirroring the command palette's row layout.
private final class QuickLaunchRowView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

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

        let stack = NSStackView(views: [iconView, titleLabel, detailLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(entry: QuickLaunchEntry) {
        iconView.image = NSImage(
            systemSymbolName: entry.symbolName,
            accessibilityDescription: nil
        )
        titleLabel.stringValue = entry.name
        let detail = entry.detail ?? ""
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
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
