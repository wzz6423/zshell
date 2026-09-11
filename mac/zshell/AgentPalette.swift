//
//  AgentPalette.swift
//  zshell
//

import AppKit
import Combine
import FuzzyMatch

@MainActor
final class AgentPaletteController: NSObject {
    private struct Entry {
        let sessionID: UUID
        let alias: String
        let kind: ZshellAgentKind
        let phase: ZshellAgentPhase
        let projectName: String
        let sessionTitle: String
        let directory: String

        var searchText: String {
            [
                alias,
                kind.displayName,
                kind.rawValue,
                phase.rawValue,
                phase.paletteDescription,
                projectName,
                sessionTitle,
                directory,
            ].joined(separator: " ")
        }
    }

    private struct Match {
        let entry: Entry
        let score: Double
        let order: Int
    }

    private static let fuzzyMatcher = FuzzyMatcher(config: .smithWaterman)

    private weak var manager: TerminalManager?
    private weak var window: NSWindow?
    private weak var previousResponder: NSResponder?
    private var managerObservation: AnyCancellable?
    private var refreshScheduled = false
    private var entries: [Entry] = []
    private var filteredEntries: [Entry] = []

    private let overlay = AgentPaletteOverlayView()
    private let panel = AgentPalettePanelView()
    private let searchField = AgentPaletteSearchField()
    private let tableView = AgentPaletteTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")

    var isPresented: Bool { overlay.superview != nil }

    override init() {
        super.init()
        configureViews()
    }

    func present(for manager: TerminalManager, in window: NSWindow) {
        if isPresented {
            dismiss(restoreFocus: true)
            return
        }
        guard let contentView = window.contentView else { return }

        self.manager = manager
        self.window = window
        if let responder = window.firstResponder, TerminalManager.isStableWorkspaceResponder(responder) {
            previousResponder = responder
        }

        overlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        overlay.onDismiss = { [weak self] in self?.dismiss(restoreFocus: true) }

        managerObservation = manager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        searchField.stringValue = ""
        refresh()
        window.makeFirstResponder(searchField)
    }

    func dismiss(restoreFocus: Bool) {
        guard isPresented else { return }
        managerObservation = nil
        overlay.removeFromSuperview()
        let window = self.window
        let responder = previousResponder
        self.window = nil
        previousResponder = nil
        manager = nil

        guard restoreFocus, let window, let responder else { return }
        DispatchQueue.main.async {
            if let current = window.firstResponder,
               current !== responder,
               TerminalManager.isStableWorkspaceResponder(current) {
                return
            }
            window.makeFirstResponder(responder)
        }
    }

    private func configureViews() {
        overlay.addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            panel.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 110),
            panel.widthAnchor.constraint(equalToConstant: 560),
            panel.heightAnchor.constraint(equalToConstant: 374),
        ])

        searchField.placeholderString = String(
            localized: "Search agents…",
            comment: "Placeholder in the running agent palette search field."
        )
        searchField.font = .systemFont(ofSize: 15)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.onMove = { [weak self] delta in self?.moveSelection(delta) }
        searchField.onConfirm = { [weak self] in self?.revealSelection() }
        searchField.onEscape = { [weak self] in self?.handleEscape() }

        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(revealSelection)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agent"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)

        panel.install(searchField: searchField, scrollView: scrollView, emptyLabel: emptyLabel)
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard let manager else { return }
        entries = manager.projects.flatMap { project in
            project.sessions.compactMap { session -> Entry? in
                guard let status = session.agentStatus else { return nil }
                return Entry(
                    sessionID: session.id,
                    alias: status.alias,
                    kind: status.kind,
                    phase: status.phase,
                    projectName: project.name,
                    sessionTitle: session.title,
                    directory: Self.abbreviate(session.foregroundDirectoryPath
                        ?? session.currentDirectoryPath)
                )
            }
        }.sorted(by: Self.ranksBefore)

        let selectedID = selectedEntry?.sessionID
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredEntries = entries
        } else {
            let fuzzyQuery = Self.fuzzyMatcher.prepare(query)
            var buffer = Self.fuzzyMatcher.makeBuffer()
            var matches: [Match] = []
            for (order, entry) in entries.enumerated() {
                var candidate = entry.searchText
                guard let score = candidate.withUTF8({ bytes in
                    Self.fuzzyMatcher.score(
                        utf8: bytes,
                        against: fuzzyQuery,
                        buffer: &buffer
                    )?.score
                }) else { continue }
                matches.append(Match(entry: entry, score: score, order: order))
            }
            matches.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.order < $1.order
            }
            filteredEntries = matches.map(\.entry)
        }

        tableView.reloadData()
        if let selectedID,
           let row = filteredEntries.firstIndex(where: { $0.sessionID == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !filteredEntries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        updateEmptyState(query: query)
        scrollSelectionToVisible()
    }

    private static func ranksBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let leftPriority = lhs.phase.palettePriority
        let rightPriority = rhs.phase.palettePriority
        if leftPriority != rightPriority { return leftPriority > rightPriority }
        let projectOrder = lhs.projectName.localizedStandardCompare(rhs.projectName)
        if projectOrder != .orderedSame { return projectOrder == .orderedAscending }
        return lhs.alias.localizedStandardCompare(rhs.alias) == .orderedAscending
    }

    private static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    private var selectedEntry: Entry? {
        guard filteredEntries.indices.contains(tableView.selectedRow) else { return nil }
        return filteredEntries[tableView.selectedRow]
    }

    private func updateEmptyState(query: String) {
        let isEmpty = filteredEntries.isEmpty
        scrollView.isHidden = isEmpty
        emptyLabel.isHidden = !isEmpty
        emptyLabel.stringValue = query.isEmpty
            ? String(localized: "No running agents")
            : String(localized: "No agents match “\(query)”")
    }

    private func moveSelection(_ delta: Int) {
        guard !filteredEntries.isEmpty else { return }
        let current = max(0, tableView.selectedRow)
        let next = min(max(current + delta, 0), filteredEntries.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        scrollSelectionToVisible()
    }

    private func scrollSelectionToVisible() {
        guard tableView.selectedRow >= 0 else { return }
        tableView.scrollRowToVisible(tableView.selectedRow)
    }

    @objc private func revealSelection() {
        guard let manager, let entry = selectedEntry,
              let session = manager.projects.lazy.flatMap(\.sessions).first(where: {
                  $0.id == entry.sessionID
              })
        else { return }
        let targetWindow = window
        dismiss(restoreFocus: false)
        manager.revealSession(session)
        session.markAutomationAgentSeen()
        targetWindow?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { session.surface.window?.makeFirstResponder(session.surface) }
    }

    private func handleEscape() {
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            refresh()
        } else {
            dismiss(restoreFocus: true)
        }
    }
}

extension AgentPaletteController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        refresh()
    }
}

extension AgentPaletteController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEntries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard filteredEntries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("agent-row")
        let view = tableView.makeView(withIdentifier: identifier, owner: self)
            as? AgentPaletteRowView ?? AgentPaletteRowView()
        view.identifier = identifier
        let entry = filteredEntries[row]
        view.isPaletteSelected = row == tableView.selectedRow
        view.apply(
            alias: entry.alias,
            kind: entry.kind.displayName,
            phase: entry.phase,
            project: entry.projectName,
            sessionTitle: entry.sessionTitle,
            directory: entry.directory
        )
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<filteredEntries.count), columnIndexes: IndexSet(integer: 0))
    }
}

private extension ZshellAgentPhase {
    var palettePriority: Int {
        switch self {
        case .blocked: return 6
        case .done: return 5
        case .working: return 4
        case .created: return 3
        case .unknown: return 2
        case .idle: return 1
        }
    }

    var paletteDescription: String {
        switch self {
        case .created: return String(localized: "Agent starting")
        case .working: return String(localized: "Agent working")
        case .blocked: return String(localized: "Agent needs attention")
        case .done: return String(localized: "Agent finished")
        case .idle: return String(localized: "Agent idle")
        case .unknown: return String(localized: "Agent state unknown")
        }
    }
}

private final class AgentPaletteSearchField: NSSearchField {
    var onMove: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onMove?(1)
        case 126: onMove?(-1)
        case 36, 76: onConfirm?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
}

private final class AgentPaletteTableView: NSTableView {
    override func mouseDown(with event: NSEvent) {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked >= 0 {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        super.mouseDown(with: event)
    }
}

private final class AgentPaletteOverlayView: NSView {
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}

private final class AgentPalettePanelView: NSView {
    private let background = NSVisualEffectView()
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        addSubview(separator)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(
        searchField: NSSearchField,
        scrollView: NSScrollView,
        emptyLabel: NSTextField
    ) {
        for view in [searchField, scrollView, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            searchField.heightAnchor.constraint(equalToConstant: 30),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 43),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 22),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        // Keep clicks inside the panel from falling through to the backdrop.
    }
}

private final class AgentPaletteRowView: NSTableCellView {
    private let badge = AgentStatusBadgeView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let phaseLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    var isPaletteSelected = false {
        didSet { updateSelectionAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        phaseLabel.font = .systemFont(ofSize: 11, weight: .medium)
        phaseLabel.textColor = .secondaryLabelColor
        phaseLabel.alignment = .right

        for view in [badge, titleLabel, phaseLabel, subtitleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 9),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: phaseLabel.leadingAnchor, constant: -8),
            phaseLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            phaseLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            phaseLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        alias: String,
        kind: String,
        phase: ZshellAgentPhase,
        project: String,
        sessionTitle: String,
        directory: String
    ) {
        badge.apply(phase: phase, count: 1)
        titleLabel.stringValue = alias == kind ? kind : "\(alias) · \(kind)"
        phaseLabel.stringValue = phase.paletteDescription
        let context = sessionTitle == project ? project : "\(project) · \(sessionTitle)"
        subtitleLabel.stringValue = directory.isEmpty ? context : "\(context) · \(directory)"
        setAccessibilityLabel("\(titleLabel.stringValue), \(phaseLabel.stringValue), \(subtitleLabel.stringValue)")
        updateSelectionAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isPaletteSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
        }
        setAccessibilitySelected(isPaletteSelected)
    }
}
