//
//  SettingsSidebar.swift
//  zshell
//

import AppKit
import Combine

/// Categories and setting search share native buttons so keyboard and
/// accessibility activation follow the same path as a click.
final class SettingsSidebarViewController: NSViewController, NSSearchFieldDelegate {
    private static let rowInset: CGFloat = 12

    var onSelect: ((SettingsCategory) -> Void)?
    var onSelectResult: ((SettingsSearchResult) -> Void)?
    var onSearchResultsChanged: (([SettingsSearchResult]) -> Void)?

    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let categoryStack = NSStackView()
    private let resultStack = NSStackView()
    private let noResultsLabel = NSTextField(wrappingLabelWithString: "")
    private let rows = SettingsSidebarSection.allCases.flatMap { section in
        section.categories.map { SettingsSidebarRow(category: $0) }
    }
    private var headers: [SettingsSidebarSection: NSTextField] = [:]
    private var resultRows: [SettingsSidebarRow] = []
    private var selected: SettingsCategory?
    private var selectedResult: String?
    private(set) var searchResults: [SettingsSearchResult] = []
    private var observations: Set<AnyCancellable> = []

    var isSearching: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        searchField.controlSize = .regular
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self

        categoryStack.orientation = .vertical
        categoryStack.alignment = .leading
        categoryStack.spacing = 16
        for section in SettingsSidebarSection.allCases {
            let header = NSTextField(labelWithString: section.title)
            header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            header.textColor = .secondaryLabelColor
            header.lineBreakMode = .byTruncatingTail
            headers[section] = header

            let groupRows = rows.filter { section.categories.contains($0.category) }
            let group = NSStackView(views: [header] + groupRows)
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 2
            group.setCustomSpacing(5, after: header)
            categoryStack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: categoryStack.widthAnchor).isActive = true
            header.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 8).isActive = true
            header.trailingAnchor.constraint(lessThanOrEqualTo: group.trailingAnchor, constant: -8).isActive = true
            for row in groupRows {
                row.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
                row.onActivate = { [weak self] in self?.onSelect?(row.category) }
                row.onMove = { [weak self, weak row] offset in
                    guard let row else { return }
                    self?.move(from: row, by: offset)
                }
            }
        }

        resultStack.orientation = .vertical
        resultStack.alignment = .leading
        resultStack.spacing = 2
        resultStack.isHidden = true

        noResultsLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        noResultsLabel.textColor = .secondaryLabelColor
        noResultsLabel.alignment = .center
        noResultsLabel.isHidden = true

        let stack = NSStackView(views: [categoryStack, resultStack, noResultsLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        let document = SettingsSidebarDocumentView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let versionLabel = NSTextField(labelWithString: version.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown")
        versionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.lineBreakMode = .byTruncatingTail

        for subview in [searchField, scroll, versionLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.rowInset),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.rowInset),
            searchField.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: versionLabel.topAnchor, constant: -10),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.rowInset),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Self.rowInset),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            categoryStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            noResultsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            versionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.rowInset + 8),
            versionLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -Self.rowInset),
            versionLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        view = container
        refreshLanguage()
        Publishers.Merge4(
            AppSettings.shared.objectWillChange,
            Updater.shared.objectWillChange,
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
                .map { _ in () },
            SettingsVisibility.recommendationsDidChange
        )
        .merge(with: NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .map { _ in () })
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else { return }
            for row in self.rows + self.resultRows { row.needsDisplay = true }
            if self.isSearching { self.updateSearchResults(onlyIfChanged: true) }
        }
        .store(in: &observations)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateEmphasis()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowKeyStateChanged(_:)),
                name: name,
                object: view.window
            )
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Removing every observer also unregisters the search field's delegate.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: view.window)
        }
    }

    func refreshLanguage() {
        searchField.placeholderString = String(localized: "Search Settings")
        searchField.setAccessibilityLabel(String(localized: "Search Settings"))
        noResultsLabel.stringValue = String(localized: "No Settings Found")
        for (section, label) in headers { label.stringValue = section.title }
        rows.forEach { $0.refreshLanguage() }
        updateSearchResults()
    }

    func select(_ category: SettingsCategory) {
        selected = category
        selectedResult = nil
        updateSelection()
    }

    func select(_ result: SettingsSearchResult) {
        selected = result.category
        selectedResult = resultID(result)
        updateSelection()
    }

    func clearSearch() {
        guard !searchField.stringValue.isEmpty else { return }
        searchField.stringValue = ""
        selectedResult = nil
        updateSearchResults()
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ notification: Notification) {
        updateSearchResults()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard let first = isSearching ? resultRows.first : rows.first else { return true }
            view.window?.makeFirstResponder(first)
            first.scrollToVisible(first.bounds)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), isSearching {
            clearSearch()
            return true
        }
        return false
    }

    private func updateSearchResults(onlyIfChanged: Bool = false) {
        let results = isSearching ? SettingsSearchIndex.results(for: searchField.stringValue) : []
        guard !onlyIfChanged || results != searchResults else { return }
        searchResults = results
        for row in resultRows {
            resultStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        resultRows = searchResults.map { result in
            let row = SettingsSidebarRow(result: result)
            row.onActivate = { [weak self] in self?.onSelectResult?(result) }
            row.onMove = { [weak self, weak row] offset in
                guard let row else { return }
                self?.move(from: row, by: offset)
            }
            resultStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: resultStack.widthAnchor).isActive = true
            return row
        }
        if !searchResults.contains(where: { resultID($0) == selectedResult }) {
            selectedResult = nil
        }
        categoryStack.isHidden = isSearching
        resultStack.isHidden = !isSearching || searchResults.isEmpty
        noResultsLabel.isHidden = !isSearching || !searchResults.isEmpty
        updateSelection()
        updateEmphasis()
        onSearchResultsChanged?(searchResults)
    }

    private func updateSelection() {
        for row in rows { row.isSelectedRow = row.category == selected }
        for (row, result) in zip(resultRows, searchResults) {
            row.isSelectedRow = resultID(result) == selectedResult
        }
    }

    private func move(from row: SettingsSidebarRow, by offset: Int) {
        let visibleRows = isSearching ? resultRows : rows
        guard let index = visibleRows.firstIndex(where: { $0 === row }) else { return }
        let next = index + offset
        guard visibleRows.indices.contains(next) else {
            if next < 0 { focusSearch() }
            return
        }
        let nextRow = visibleRows[next]
        view.window?.makeFirstResponder(nextRow)
        nextRow.scrollToVisible(nextRow.bounds)
        nextRow.performClick(nil)
    }

    private func resultID(_ result: SettingsSearchResult) -> String {
        [result.category.rawValue, result.section ?? "", result.title].joined(separator: "\u{1f}")
    }

    @objc private func windowKeyStateChanged(_ notification: Notification) {
        updateEmphasis()
    }

    private func updateEmphasis() {
        let emphasized = view.window?.isKeyWindow ?? false
        for row in rows + resultRows { row.isEmphasized = emphasized }
    }
}

private enum SettingsSidebarSection: CaseIterable {
    case basics, workspace, tools, about

    var title: String {
        switch self {
        case .basics: String(localized: "Basics")
        case .workspace: String(localized: "Workspace")
        case .tools: String(localized: "AI & Tools")
        case .about: String(localized: "About")
        }
    }

    var categories: [SettingsCategory] {
        switch self {
        case .basics: [.general, .appearance, .shortcuts]
        case .workspace: [.terminal, .editor, .browser, .browserAccess]
        case .tools: [.automation, .recommendations]
        case .about: [.updates]
        }
    }
}

private final class SettingsSidebarDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A full-width category or search result. Category colors stay recognizable
/// while selection emphasis follows the window's key state.
private final class SettingsSidebarRow: NSButton {
    let category: SettingsCategory
    var onActivate: (() -> Void)?
    var onMove: ((Int) -> Void)?

    var isSelectedRow = false {
        didSet {
            guard isSelectedRow != oldValue else { return }
            needsDisplay = true
            updateTint()
            setAccessibilityValue(isSelectedRow)
        }
    }

    var isEmphasized = false {
        didSet {
            guard isEmphasized != oldValue else { return }
            needsDisplay = true
            updateTint()
        }
    }

    private let iconView: SettingsIconView
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField?

    init(category: SettingsCategory, result: SettingsSearchResult? = nil) {
        self.category = category
        iconView = SettingsIconView(
            symbolName: category.symbolName,
            color: category.iconColor,
            size: SettingsMetrics.sidebarSymbolWidth
        )
        titleLabel = NSTextField(labelWithString: result?.title ?? category.title)
        subtitleLabel = result.map {
            NSTextField(labelWithString: [category.title, $0.section].compactMap { $0 }.joined(separator: " · "))
        }
        super.init(frame: .zero)

        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(titleLabel.stringValue)
        setAccessibilityValue(false)
        if let subtitleLabel { setAccessibilityHelp(subtitleLabel.stringValue) }
        target = self
        action = #selector(invoke)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityElement(false)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let subtitleLabel {
            subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.setAccessibilityElement(false)
            subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = NSStackView(views: [titleLabel] + (subtitleLabel.map { [$0] } ?? []))
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        titleLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        subtitleLabel?.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true

        for subview in [iconView, labels] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: subtitleLabel == nil ? SettingsMetrics.sidebarRowHeight : 48),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateTint()
    }

    convenience init(result: SettingsSearchResult) {
        self.init(category: result.category, result: result)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        // NSButtonCell would paint its own pressed state over the row's colors.
        if isSelectedRow {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            let tint: NSColor = isEmphasized ? .controlAccentColor : .labelColor
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            tint.withAlphaComponent(isDark ? 0.18 : 0.10).setFill()
            path.fill()
            let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            tint.withAlphaComponent(highContrast ? 1 : (isDark ? 0.42 : 0.24)).setStroke()
            path.lineWidth = highContrast ? 1 : 0.5
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 125 { onMove?(1); return }
            if event.keyCode == 126 { onMove?(-1); return }
            if event.keyCode == 36 { performClick(nil); return }
        }
        super.keyDown(with: event)
    }

    func refreshLanguage() {
        guard subtitleLabel == nil else { return }
        titleLabel.stringValue = category.title
        setAccessibilityLabel(category.title)
    }

    @objc private func invoke() {
        onActivate?()
    }

    private func updateTint() {
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: isSelectedRow ? .semibold : .regular)
        titleLabel.textColor = isSelectedRow && isEmphasized ? .controlAccentColor : .labelColor
        subtitleLabel?.textColor = .secondaryLabelColor
    }
}
