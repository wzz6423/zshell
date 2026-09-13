//
//  FileContentSearchView.swift
//  zshell
//

import AppKit
import Combine
import SwiftUI

/// The Files panel's content-search surface, replacing the file tree while a
/// search is active: a search row (query, case toggle, stop, close), the
/// match count over the anchored root, and the streamed result rows.
struct FileContentSearchPanelView: NSViewRepresentable {
    let model: FileContentSearchModel
    let fontScale: CGFloat
    let openResult: (FileContentSearchModel.Match) -> Void

    func makeNSView(context: Context) -> FileContentSearchPanel {
        let panel = FileContentSearchPanel()
        panel.configure(model: model, fontScale: fontScale, openResult: openResult)
        return panel
    }

    func updateNSView(_ panel: FileContentSearchPanel, context: Context) {
        panel.update(fontScale: fontScale, openResult: openResult)
    }
}

/// AppKit search surface driven by `FileContentSearchModel`. The panel
/// subscribes to the model itself, so streaming updates never re-render the
/// owning SwiftUI tree — the ~200 ms flush cadence lands directly here.
@MainActor
final class FileContentSearchPanel: NSView {
    private let searchField = NSTextField(string: "")
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let stopButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let rootLabel = NSTextField(labelWithString: "")
    private lazy var tableView = FileSearchResultTableView(onOpen: { [weak self] in
        self?.openSelected()
    }, onCancel: { [weak self] in
        self?.closeRequested()
    })
    private let scrollView = NSScrollView()

    private var model: FileContentSearchModel?
    private var openResult: ((FileContentSearchModel.Match) -> Void)?
    private var modelObserver: AnyCancellable?
    private var fontScale: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUpViews() {
        let searchField = self.searchField
        searchField.placeholderString = String(localized: "Search File Contents")
        searchField.bezelStyle = .roundedBezel
        searchField.delegate = self
        searchField.setAccessibilityLabel(String(localized: "Search File Contents"))

        // A recessed push-on/push-off button reads as pressed while matching
        // case, the way VS Code's "Aa" toggle does.
        let caseButton = self.caseButton
        caseButton.setButtonType(.pushOnPushOff)
        caseButton.bezelStyle = .recessed
        caseButton.toolTip = String(localized: "Match Case")
        caseButton.setAccessibilityLabel(String(localized: "Match Case"))
        caseButton.target = self
        caseButton.action = #selector(caseToggled)

        let stopImage = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        let stopButton = self.stopButton
        stopButton.image = stopImage
        stopButton.isBordered = false
        stopButton.contentTintColor = .secondaryLabelColor
        stopButton.toolTip = String(localized: "Stop Search")
        stopButton.setAccessibilityLabel(String(localized: "Stop Search"))
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.isHidden = true

        let closeButton = self.closeButton
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = String(localized: "Close Search")
        closeButton.setAccessibilityLabel(String(localized: "Close Search"))
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let buttonRow = NSStackView(views: [caseButton, stopButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 4
        buttonRow.alignment = .centerY
        // The stop button only exists while a search runs; detaching keeps
        // it from reserving space when hidden.
        buttonRow.detachesHiddenViews = true

        let statusLabel = self.statusLabel
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let rootLabel = self.rootLabel
        rootLabel.textColor = .secondaryLabelColor
        rootLabel.lineBreakMode = .byTruncatingHead
        rootLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The tree's SwiftUI background shows through the results area.
        let scrollView = self.scrollView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        // A single click on a row opens the hit, the same way the file tree
        // opens a file; arrow-key selection stays non-committal.
        tableView.target = self
        tableView.action = #selector(rowClicked)

        for view in [searchField, buttonRow, statusLabel, rootLabel, scrollView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: buttonRow.leadingAnchor, constant: -6),

            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            buttonRow.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 7),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            rootLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 1),
            rootLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rootLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: rootLabel.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configure(
        model: FileContentSearchModel,
        fontScale: CGFloat,
        openResult: @escaping (FileContentSearchModel.Match) -> Void
    ) {
        self.model = model
        self.fontScale = fontScale
        self.openResult = openResult
        modelObserver = model.objectWillChange.sink { [weak self] _ in
            // The sink runs inside the model's willSet, before the published
            // values actually change; read them on the next pass.
            DispatchQueue.main.async { self?.syncFromModel() }
        }
        searchField.stringValue = model.query
        applyFonts()
        syncFromModel()
        // Only a fresh activation focuses the field — a panel that remounts
        // because its tab came back into view must not steal focus.
        if model.consumeFocusRequest() {
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(self.searchField)
            }
        }
    }

    func update(
        fontScale: CGFloat,
        openResult: @escaping (FileContentSearchModel.Match) -> Void
    ) {
        self.openResult = openResult
        guard fontScale != self.fontScale else { return }
        self.fontScale = fontScale
        applyFonts()
        tableView.reloadData()
    }

    override func layout() {
        super.layout()
        // Keep the single results column as wide as the panel.
        tableView.sizeLastColumnToFit()
    }

    override func cancelOperation(_ sender: Any?) {
        closeRequested()
    }

    // MARK: - Model sync

    private func syncFromModel() {
        guard let model else { return }
        if searchField.stringValue != model.query {
            searchField.stringValue = model.query
        }
        statusLabel.stringValue = statusText(for: model)
        rootLabel.stringValue = model.rootPath
        rootLabel.isHidden = model.rootPath.isEmpty
        stopButton.isHidden = !model.isRunning
        caseButton.state = model.isCaseSensitive ? .on : .off
        tableView.reloadData()
    }

    private func statusText(for model: FileContentSearchModel) -> String {
        // Verbatim process output, not localized content.
        if let failure = model.failureMessage { return failure }
        if model.isTruncated {
            return String(
                localized: "Results are truncated — showing the first \(model.matches.count) matches",
                comment: "File-content search status. The placeholder is the number of matches shown."
            )
        }
        if model.isRunning {
            return String(localized: "Searching…", comment: "File-content search status.")
        }
        if model.wasStopped {
            return String(
                localized: "Stopped — \(model.matches.count) matches",
                comment: "File-content search status after pressing stop. The placeholder is the number of matches found so far."
            )
        }
        if model.matches.isEmpty {
            return model.query.trimmingCharacters(in: .whitespaces).isEmpty
                ? ""
                : String(localized: "No matches", comment: "File-content search status.")
        }
        return String(
            localized: "\(model.matches.count) matches",
            comment: "File-content search status. The placeholder is the number of matched lines."
        )
    }

    private func applyFonts() {
        searchField.font = .systemFont(ofSize: 11.5 * fontScale)
        caseButton.font = .systemFont(ofSize: 9.5 * fontScale, weight: .medium)
        statusLabel.font = .systemFont(ofSize: 10.5 * fontScale, weight: .medium)
        rootLabel.font = .systemFont(ofSize: 9.5 * fontScale)
        // Two-line rows: the file:line header above the matched content.
        tableView.rowHeight = 28 * fontScale + 4
    }

    // MARK: - Actions

    @objc private func caseToggled() {
        model?.isCaseSensitive = caseButton.state == .on
    }

    @objc private func stopClicked() {
        model?.stop()
    }

    @objc private func closeClicked() {
        closeRequested()
    }

    @objc private func rowClicked() {
        openSelected()
    }

    /// Hops one runloop tick: the SwiftUI tree that owns this panel is torn
    /// down synchronously on deactivate, and removing the view under a live
    /// event handler (an Escape in the field, a click on the close button)
    /// would deallocate the first responder mid-event.
    private func closeRequested() {
        DispatchQueue.main.async { [weak self] in
            self?.model?.deactivate()
        }
    }

    private func openSelected() {
        guard let model,
              tableView.selectedRow >= 0,
              model.matches.indices.contains(tableView.selectedRow)
        else { return }
        openResult?(model.matches[tableView.selectedRow])
    }
}

extension FileContentSearchPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        // Persist the query as it is typed, so leaving and re-entering the
        // search row keeps it.
        model?.query = searchField.stringValue
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            model?.run()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeRequested()
            return true
        default:
            return false
        }
    }
}

/// Results table whose Return opens the selected row and Escape restores the
/// file tree; a single click opens via the table's action.
private final class FileSearchResultTableView: NSTableView {
    let onOpen: () -> Void
    let onCancel: () -> Void

    init(onOpen: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onCancel = onCancel
        super.init(frame: .zero)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        addTableColumn(column)
        headerView = nil
        rowHeight = 32
        selectionHighlightStyle = .regular
        backgroundColor = .clear
        style = .plain
        allowsMultipleSelection = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // return / keypad enter
            onOpen()
        case 53: // escape
            onCancel()
        default:
            super.keyDown(with: event)
        }
    }
}

extension FileContentSearchPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        model?.matches.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let model, model.matches.indices.contains(row) else { return nil }
        let match = model.matches[row]
        let identifier = NSUserInterfaceItemIdentifier("matchCell")
        let cell: FileSearchResultCell
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileSearchResultCell {
            cell = reused
        } else {
            cell = FileSearchResultCell(identifier: identifier)
        }
        cell.configure(
            path: match.path,
            line: match.line,
            content: match.content,
            fontScale: fontScale
        )
        return cell
    }
}

/// One search hit: "relative/path:line" over the matched line content.
private final class FileSearchResultCell: NSTableCellView {
    private let pathLabel = NSTextField(labelWithString: "")
    private let contentLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        for label in [pathLabel, contentLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            pathLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            contentLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 1),
            contentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        updateColors(for: backgroundStyle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(path: String, line: Int, content: String, fontScale: CGFloat) {
        // Both fields are user content — file paths and file text — and are
        // never localized.
        pathLabel.stringValue = path + ":" + String(line)
        contentLabel.stringValue = content
        pathLabel.font = .systemFont(ofSize: 9.5 * fontScale)
        contentLabel.font = .systemFont(ofSize: 11 * fontScale)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors(for: backgroundStyle) }
    }

    private func updateColors(for backgroundStyle: NSView.BackgroundStyle) {
        let selected = backgroundStyle == .emphasized || backgroundStyle == .raised
        pathLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        contentLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
    }
}
