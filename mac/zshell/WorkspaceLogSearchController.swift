import AppKit
import Foundation

nonisolated private final class WorkspaceLogCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

@MainActor
final class WorkspaceLogSearchController: NSObject, NSWindowDelegate {
    static let shared = WorkspaceLogSearchController()
    private let resultLimit = 1_000
    private let cacheLimit = 32 * 1024 * 1024
    private let worker = DispatchQueue(label: "sh.zshell.workspace-log-search", qos: .userInitiated)
    private weak var manager: TerminalManager?
    private weak var hostWindow: NSWindow?
    private var panel: NSPanel?
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var cancellation = WorkspaceLogCancellation()
    private var generation = 0
    private var isScanning = false
    private var isNavigating = false
    // Bumped whenever a navigation is abandoned, so a late reveal from an
    // earlier activation can neither close the panel nor leave isNavigating set.
    private var navigation = 0
    private weak var navigatingSession: TerminalSession?

    private struct Source {
        let session: TerminalSession
        let context: String
    }
    private struct Cache {
        let revision: UInt64
        let text: String
        let bytes: Int
        let capturedAt: Date
    }
    private struct Row {
        let sessionID: UUID
        let context: String
        let snippet: String
        let occurrence: Int
        let total: Int
        let fingerprint: Data
        var selectionKey: (sessionID: UUID, occurrence: Int, snippet: String) { (sessionID, occurrence, snippet) }
    }
    private var cache: [UUID: Cache] = [:]
    private var rows: [Row] = []
    private var scannedRevisions: [UUID: UInt64] = [:]
    private var totalMatches = 0
    private var hadCaptureFailure = false
    private var reselect: (sessionID: UUID, occurrence: Int, snippet: String)?

    func show(for manager: TerminalManager) {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow) else { return }
        if panel == nil { configure() }
        guard let panel else { return }
        close()
        self.manager = manager
        hostWindow = host
        panel.title = String(localized: "Search Terminal Logs")
        searchField.placeholderString = String(localized: "Search Terminal Logs")
        searchField.setAccessibilityLabel(String(localized: "Search Terminal Logs"))
        table.setAccessibilityLabel(String(localized: "Search Terminal Logs"))
        searchField.stringValue = ""
        status.stringValue = String(localized: "Search the current terminal buffers.")
        panel.setFrameOrigin(NSPoint(x: host.frame.midX - panel.frame.width / 2,
                                    y: host.frame.midY - panel.frame.height / 2))
        host.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshIfChanged() }
        }
    }

    func close(ifOwnedBy manager: TerminalManager? = nil) {
        if let manager, self.manager !== manager { return }
        generation += 1
        cancelNavigation()
        reselect = nil
        cancellation.cancel()
        debounce?.cancel()
        debounce = nil
        timer?.invalidate()
        timer = nil
        if let panel { hostWindow?.removeChildWindow(panel); panel.orderOut(nil) }
        self.manager = nil
        hostWindow = nil
        isScanning = false
        cache.removeAll()
        rows.removeAll()
        scannedRevisions.removeAll()
        table.reloadData()
    }

    func windowWillClose(_ notification: Notification) { close() }

    private func configure() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 450, height: 300)
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("workspace-log-search-panel")
        self.panel = panel
        guard let content = panel.contentView else { return }
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        table.headerView = nil
        table.rowHeight = 51
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(openSelection(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("log-result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        for view in [searchField, scroll, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private func sources() -> [Source] {
        guard let manager else { return [] }
        return manager.projects.flatMap { project in
            project.tabs.flatMap { tab in
                tab.allPanes.enumerated().compactMap { index, pane in
                    guard case .session(let session) = pane.content else { return nil }
                    let tabName = tab.displayTitle ?? session.title
                    let paneName = String(localized: "Pane \(index + 1)")
                    return Source(session: session, context: [project.name, tabName, paneName, session.title].joined(separator: " · "))
                }
            }
        }
    }

    private func refreshIfChanged() {
        guard !isScanning, !isNavigating, !searchField.stringValue.isEmpty else { return }
        let current = sources()
        guard current.count == scannedRevisions.count,
              current.allSatisfy({ scannedRevisions[$0.session.id] == $0.session.surface.logContentRevision })
        else {
            // The rescan rebuilds the rows; keep the match the user picked,
            // or Return would open the first row instead.
            reselect = rows.indices.contains(table.selectedRow)
                ? rows[table.selectedRow].selectionKey : nil
            beginSearch()
            return
        }
    }

    private func cancelNavigation() {
        navigation += 1
        isNavigating = false
        navigatingSession?.find.cancelLogReveal()
        navigatingSession = nil
    }

    private func beginSearch() {
        generation += 1
        // The rows a pending navigation came from are about to be replaced.
        cancelNavigation()
        cancellation.cancel()
        cancellation = WorkspaceLogCancellation()
        rows.removeAll()
        scannedRevisions.removeAll()
        totalMatches = 0
        hadCaptureFailure = false
        table.reloadData()
        let query = searchField.stringValue
        guard !query.isEmpty else {
            isScanning = false
            status.stringValue = String(localized: "Search the current terminal buffers.")
            return
        }
        guard query.rangeOfCharacter(from: .newlines) == nil, !query.contains("\0") else {
            isScanning = false
            status.stringValue = String(localized: "Enter a single line to search.")
            return
        }
        isScanning = true
        status.stringValue = String(localized: "Searching…")
        let sources = sources()
        let liveIDs = Set(sources.map { $0.session.id })
        cache = cache.filter { liveIDs.contains($0.key) }
        scan(sources, at: 0, query: query, generation: generation, cancellation: cancellation)
    }

    private func scan(_ sources: [Source], at index: Int, query: String, generation: Int,
                      cancellation: WorkspaceLogCancellation) {
        guard self.generation == generation, !cancellation.isCancelled() else { return }
        guard index < sources.count else {
            isScanning = false
            reselect = nil
            if hadCaptureFailure { status.stringValue = String(localized: "Some terminal buffers could not be searched.") }
            else if totalMatches > rows.count {
                status.stringValue = String(localized: "Results are truncated — showing the first \(resultLimit) matches")
            }
            else if rows.isEmpty { status.stringValue = String(localized: "No Matches") }
            else { status.stringValue = "" }
            return
        }
        let source = sources[index]
        let sessionID = source.session.id
        let currentRevision = source.session.surface.logContentRevision
        let cachedEntry = cache[sessionID].flatMap {
            $0.revision == currentRevision || Date().timeIntervalSince($0.capturedAt) < 2 ? $0 : nil
        }
        let cached = cachedEntry?.text
        let revision = cachedEntry?.revision ?? currentRevision
        let capture = cached == nil ? TerminalHistorySerializer.takeLogCapture(from: source.session.surface) : nil
        let remaining = max(0, resultLimit - rows.count)
        worker.async { [weak self] in
            if cancellation.isCancelled() { capture?.discard(); return }
            let text = cached ?? capture?.read()
            if cancellation.isCancelled() { return }
            let result = text.map {
                WorkspaceLogSearchIndex.search(text: $0, query: query, limit: remaining,
                                               isCancelled: { cancellation.isCancelled() })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation, !cancellation.isCancelled() else { return }
                self.scannedRevisions[sessionID] = revision
                if let text, let result, !result.cancelled {
                    let bytes = text.utf8.count
                    if cached == nil, bytes <= self.cacheLimit {
                        if self.cache.values.reduce(bytes, { $0 + $1.bytes }) > self.cacheLimit { self.cache.removeAll() }
                        self.cache[sessionID] = Cache(revision: revision, text: text, bytes: bytes, capturedAt: Date())
                    }
                    self.totalMatches += result.total
                    let start = self.rows.count
                    self.rows.append(contentsOf: result.matches.map {
                        Row(sessionID: sessionID, context: source.context, snippet: $0.snippet,
                            occurrence: $0.occurrence, total: result.total, fingerprint: result.fingerprint)
                    })
                    // reloadData drops the table selection; inserting keeps a row picked mid-scan.
                    self.table.insertRows(at: IndexSet(start..<self.rows.count))
                    if let key = self.reselect, let row = self.rows.firstIndex(where: { $0.selectionKey == key }) {
                        self.reselect = nil
                        self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
                } else { self.hadCaptureFailure = true }
                self.scan(sources, at: index + 1, query: query, generation: generation, cancellation: cancellation)
            }
        }
    }

    @objc private func openSelection(_ sender: Any?) {
        let index = sender == nil ? table.selectedRow : table.clickedRow
        guard rows.indices.contains(index), let manager else { return }
        let row = rows[index]
        guard let session = manager.projects.flatMap(\.sessions).first(where: { $0.id == row.sessionID }) else {
            beginSearch(); return
        }
        let query = searchField.stringValue
        cancelNavigation()
        isNavigating = true
        navigatingSession = session
        manager.revealSession(session)
        status.stringValue = String(localized: "Searching…")
        let currentNavigation = navigation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak session] in
            guard let self, self.navigation == currentNavigation else { return }
            guard let session, self.manager?.projects.flatMap(\.sessions).contains(where: { $0 === session }) == true,
                  let capture = TerminalHistorySerializer.takeLogCapture(from: session.surface) else {
                self.isNavigating = false
                self.beginSearch()
                return
            }
            self.worker.async { [weak self, weak session] in
                let fingerprint = capture.read().map(WorkspaceLogSearchIndex.fingerprint)
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, self.navigation == currentNavigation else { return }
                    guard let session else { self.isNavigating = false; return }
                    guard fingerprint == row.fingerprint else {
                        self.isNavigating = false
                        self.beginSearch()
                        return
                    }
                    session.find.revealLogMatch(needle: query, occurrence: row.occurrence, total: row.total) { [weak self, weak session] success in
                        guard let self, self.navigation == currentNavigation else { return }
                        self.isNavigating = false
                        self.navigatingSession = nil
                        if success {
                            let host = self.hostWindow
                            self.close()
                            host?.makeKeyAndOrderFront(nil)
                            if let session { session.surface.window?.makeFirstResponder(session.surface) }
                        } else {
                            self.status.stringValue = String(localized: "The result changed or could not be located. Search again.")
                        }
                    }
                }
            }
        }
    }
}

extension WorkspaceLogSearchController: NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    func controlTextDidChange(_ notification: Notification) {
        generation += 1
        cancellation.cancel()
        cancelNavigation()
        reselect = nil
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.debounce = nil
            self?.beginSearch()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.insertNewline(_:)):
            // The rows still belong to the previous query until the debounced
            // search runs; search now instead of opening a stale result.
            if let pending = debounce {
                pending.cancel()
                debounce = nil
                beginSearch()
                return true
            }
            if table.selectedRow < 0, !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            openSelection(nil)
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard !rows.isEmpty else { return true }
            let delta = command == #selector(NSResponder.moveUp(_:)) ? -1 : 1
            let row = min(max(table.selectedRow + delta, 0), rows.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        default: return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("workspace-log-result")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? WorkspaceLogResultCell
            ?? WorkspaceLogResultCell()
        cell.identifier = identifier
        cell.configure(context: rows[row].context, snippet: rows[row].snippet)
        return cell
    }
}

private final class WorkspaceLogResultCell: NSTableCellView {
    private let context = NSTextField(labelWithString: "")
    private let snippet = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        context.font = .systemFont(ofSize: 11)
        context.textColor = .secondaryLabelColor
        snippet.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        for label in [context, snippet] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            ])
        }
        NSLayoutConstraint.activate([
            context.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            snippet.topAnchor.constraint(equalTo: context.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(context: String, snippet: String) {
        self.context.stringValue = context
        self.snippet.stringValue = snippet
        toolTip = [context, snippet].joined(separator: "\n")
    }
}
