import AppKit
import Foundation

@MainActor
enum BrowserImportedHistoryStore {
    private static let maximumRecords = 50_000
    private static let maximumBytes = 32 * 1_024 * 1_024
    static var directory: URL {
        AgentUsagePaths.applicationSupportDirectory.appendingPathComponent("browser-history", isDirectory: true)
    }
    static var file: URL { directory.appendingPathComponent("records.json") }

    static func load(from destination: URL? = nil) throws -> [BrowserImportedPage] {
        let url = destination ?? file
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        try PersistentCLIConnection.verifyPrivateDirectory(url.deletingLastPathComponent())
        let data = try PersistentCLIConnection.readPrivate(url, maximumBytes: maximumBytes)
        let pages = try JSONDecoder().decode([BrowserImportedPage].self, from: data)
        guard pages.count <= maximumRecords, pages.allSatisfy({ BrowserImportedPage.safeURL($0.url) }) else {
            throw CocoaError(.coderInvalidValue)
        }
        return pages
    }

    static func merge(_ incoming: [BrowserImportedPage], to destination: URL? = nil) throws -> (saved: Int, skipped: Int) {
        let url = destination ?? file
        try AgentConversationHistoryPaths.prepare(url.deletingLastPathComponent())
        let old = try load(from: url)
        var byURL: [String: BrowserImportedPage] = [:]
        for page in old + incoming where BrowserImportedPage.safeURL(page.url) {
            if let existing = byURL[page.url], existing.visitedAt > page.visitedAt { continue }
            byURL[page.url] = page
        }
        let all = byURL.values.sorted { $0.visitedAt > $1.visitedAt }
        let retained = Array(all.prefix(maximumRecords))
        let encoded = try JSONEncoder().encode(retained)
        guard encoded.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try PersistentCLIConnection.writePrivate(encoded, to: url, durable: true)
        let savedURLs = Set(retained.map(\.url))
        let saved = incoming.filter { savedURLs.contains($0.url) }.count
        return (saved, incoming.count - saved)
    }
}

@MainActor
final class BrowserImportedHistoryController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = BrowserImportedHistoryController()
    private weak var manager: TerminalManager?
    private var panel: NSPanel?
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton()
    private var allPages: [BrowserImportedPage] = []
    private var pages: [BrowserImportedPage] = []

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(localize), name: AppLocalization.didChange, object: nil)
    }

    func show(manager: TerminalManager) {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow) else { return }
        if panel == nil { configure() }
        guard let panel else { return }
        self.manager = manager
        do { allPages = try BrowserImportedHistoryStore.load(); status.stringValue = "" }
        catch { allPages = []; status.stringValue = error.localizedDescription }
        search.stringValue = ""
        localize()
        reload()
        AppWindowPresentation.attach(panel, to: host, placement: .centered)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
    }

    private func configure() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 340)
        panel.delegate = self
        self.panel = panel
        guard let content = panel.contentView else { return }
        search.delegate = self
        search.sendsSearchStringImmediately = true
        table.headerView = nil
        table.rowHeight = 34
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openSelection(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        status.textColor = .secondaryLabelColor
        openButton.target = self
        openButton.action = #selector(openSelection(_:))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        for view in [search, scroll, status, openButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: openButton.topAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
            openButton.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            openButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    @objc private func localize() {
        panel?.title = String(localized: "Imported Browser History")
        search.placeholderString = String(localized: "Search imported history…")
        search.setAccessibilityLabel(String(localized: "Search imported history…"))
        table.setAccessibilityLabel(String(localized: "Imported Browser History"))
        openButton.title = String(localized: "Open Page")
    }

    private func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pages = query.isEmpty ? allPages : allPages.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query)
        }
        table.reloadData()
        openButton.isEnabled = false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard pages.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("browser-history-page")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                                         label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                                         label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        let page = pages[row]
        cell.textField?.stringValue = page.title.isEmpty ? page.url : "\(page.title) — \(page.url)"
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { openButton.isEnabled = pages.indices.contains(table.selectedRow) }
    func controlTextDidChange(_ notification: Notification) { reload() }
    @objc private func openSelection(_ sender: Any?) {
        guard pages.indices.contains(table.selectedRow), let manager else { return }
        manager.newBrowserTab(initialURL: pages[table.selectedRow].url)
        panel?.close()
    }
    func windowWillClose(_ notification: Notification) {
        if let panel { panel.parent?.removeChildWindow(panel) }
        manager = nil
    }
}
