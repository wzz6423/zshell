//
//  SettingsWindowController.swift
//  zshell
//

import AppKit

/// One page of settings. Categories exist so a setting can be found by where
/// it acts, rather than by scrolling one long form.
enum SettingsCategory: String, CaseIterable {
    case general
    case shortcuts
    case appearance
    case terminal
    case editor
    case browser
    case automation
    case recommendations
    case updates

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .shortcuts: String(localized: "Shortcuts")
        case .appearance: String(localized: "Appearance")
        case .terminal: String(localized: "Terminal")
        case .editor: String(localized: "Editor")
        case .browser: String(localized: "Browser")
        case .automation: String(localized: "AI")
        case .recommendations: String(localized: "Recommendations")
        case .updates: String(localized: "Updates")
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "keyboard"
        case .appearance: "paintpalette.fill"
        case .terminal: "terminal.fill"
        case .editor: "curlybraces"
        case .browser: "globe"
        case .automation: "sparkles"
        case .recommendations: "star.circle.fill"
        case .updates: "arrow.down.circle.fill"
        }
    }

    func makePane() -> SettingsPaneViewController {
        switch self {
        case .general: SettingsGeneralPane()
        case .shortcuts: SettingsShortcutsPane()
        case .appearance: SettingsAppearancePane()
        case .terminal: SettingsTerminalPane()
        case .editor: SettingsEditorPane()
        case .browser: SettingsBrowserPane()
        case .automation: SettingsAutomationPane()
        case .recommendations: SettingsRecommendationsPane()
        case .updates: SettingsUpdatesPane()
        }
    }
}

/// The settings window (⌘,). One shared instance: reopening brings the same
/// window forward, still on the category last used.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private static let categoryDefaultsKey = "zshell.settings.category"
    private static let frameAutosaveName = "Settings"
    private static let sidebarWidth: CGFloat = 240
    private static let legacyContentHeight: CGFloat = 660
    private static let legacyContentSize = NSSize(width: 720, height: 560)
    private static let defaultContentSize = NSSize(width: 900, height: 640)
    private static let sidebarIdentifier = NSToolbarItem.Identifier("settings.sidebar")
    private static let navigationIdentifier = NSToolbarItem.Identifier("settings.navigation")

    private let sidebar = SettingsSidebarViewController()
    private let content = SettingsContentViewController()
    private let split = NSSplitViewController()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private var history: [SettingsCategory] = []
    private var historyIndex = -1

    private init() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 280
        sidebarItem.preferredThicknessFraction = Self.sidebarWidth / Self.defaultContentSize.width
        sidebarItem.canCollapse = true
        sidebarItem.titlebarSeparatorStyle = .none
        split.addSplitViewItem(sidebarItem)
        split.splitView.autosaveName = "SettingsSidebar"

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 480
        split.addSplitViewItem(contentItem)

        let window = SettingsWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Assigning the content view controller resizes the window to that
        // controller's fitting size, discarding the contentRect above, so the
        // default size is applied after it.
        window.contentViewController = split
        window.contentMinSize = NSSize(width: 720, height: 460)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Cmd-W closes the key window unless a main window is up front, so this
        // identifier must not start with "main" — see ZshellCommands.
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.settingsController = self
        configureNavigationButton(backButton, symbol: "chevron.backward", key: "[", action: #selector(goBack(_:)))
        configureNavigationButton(forwardButton, symbol: "chevron.forward", key: "]", action: #selector(goForward(_:)))
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar
        window.setContentSize(Self.defaultContentSize)
        let restoredFrame = window.setFrameUsingName(Self.frameAutosaveName)
        if !restoredFrame { window.center() }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if restoredFrame {
            let restoredSize = window.contentRect(forFrameRect: window.frame).size
            if restoredSize == Self.legacyContentSize {
                window.setContentSize(Self.defaultContentSize)
                window.saveFrame(usingName: Self.frameAutosaveName)
            } else if restoredSize.height == Self.legacyContentHeight {
                window.setContentSize(NSSize(width: restoredSize.width, height: Self.defaultContentSize.height))
                window.saveFrame(usingName: Self.frameAutosaveName)
            }
        }
        updateToolbarLanguage()
        updateNavigation()

        sidebar.onSelect = { [weak self] category in self?.select(category) }
        sidebar.onSelectResult = { [weak self] result in
            guard let self else { return }
            self.select(result.category)
            self.sidebar.select(result)
            self.content.reveal(result)
        }
        sidebar.onSearchResultsChanged = { [weak self] results in self?.updateSearchState(results) }
        content.onClearSearch = { [weak self] in self?.sidebar.clearSearch() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshLanguage), name: AppLocalization.didChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        if content.category == nil { select(restoredCategory) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.sidebarIdentifier, .sidebarTrackingSeparator, Self.navigationIdentifier, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == Self.sidebarIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
            item.label = String(localized: "Toggle Sidebar")
            item.toolTip = item.label
            item.target = split
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            return item
        }
        if itemIdentifier == .sidebarTrackingSeparator {
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: split.splitView, dividerIndex: 0)
        }
        guard itemIdentifier == Self.navigationIdentifier else { return nil }
        let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
        let back = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("settings.back"))
        back.view = backButton
        let forward = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("settings.forward"))
        forward.view = forwardButton
        group.subitems = [back, forward]
        return group
    }

    fileprivate func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            switch key {
            case "[": goBack(nil)
            case "]": goForward(nil)
            case "f":
                split.splitViewItems.first?.isCollapsed = false
                sidebar.focusSearch()
            default: return false
            }
            return true
        }
        if flags == [.command, .control], key == "s" {
            split.toggleSidebar(nil)
            return true
        }
        return false
    }

    @objc private func refreshLanguage() {
        content.refreshLanguage()
        sidebar.refreshLanguage()
        updateToolbarLanguage()
    }

    private var restoredCategory: SettingsCategory {
        content.category
            ?? UserDefaults.standard.string(forKey: Self.categoryDefaultsKey)
                .flatMap(SettingsCategory.init(rawValue:))
            ?? .general
    }

    private func select(_ category: SettingsCategory, recordHistory: Bool = true) {
        content.show(category)
        sidebar.select(category)
        UserDefaults.standard.set(category.rawValue, forKey: Self.categoryDefaultsKey)
        if recordHistory, historyIndex < 0 || history[historyIndex] != category {
            history.removeSubrange((historyIndex + 1)..<history.count)
            history.append(category)
            historyIndex = history.count - 1
        }
        updateNavigation()
    }

    private func updateSearchState(_ results: [SettingsSearchResult]) {
        guard sidebar.isSearching else {
            content.show(restoredCategory)
            return
        }
        if let category = content.category, results.contains(where: { $0.category == category }) {
            content.show(category)
        } else {
            content.showSearchPrompt(hasResults: !results.isEmpty)
        }
    }

    @objc private func goBack(_ sender: Any?) {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        sidebar.clearSearch()
        select(history[historyIndex], recordHistory: false)
    }

    @objc private func goForward(_ sender: Any?) {
        guard historyIndex + 1 < history.count else { return }
        historyIndex += 1
        sidebar.clearSearch()
        select(history[historyIndex], recordHistory: false)
    }

    private func updateNavigation() {
        backButton.isEnabled = historyIndex > 0
        forwardButton.isEnabled = historyIndex + 1 < history.count
    }

    private func configureNavigationButton(_ button: NSButton, symbol: String, key: String, action: Selector) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = .command
        button.target = self
        button.action = action
    }

    private func updateToolbarLanguage() {
        window?.title = String(localized: "zshell Settings")
        for (button, label) in [(backButton, String(localized: "Back")), (forwardButton, String(localized: "Forward"))] {
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        for item in window?.toolbar?.items ?? [] {
            if item.itemIdentifier == Self.sidebarIdentifier {
                item.label = String(localized: "Toggle Sidebar")
                item.toolTip = item.label
            } else if let group = item as? NSToolbarItemGroup {
                group.label = String(localized: "Settings Navigation")
                group.subitems.first?.label = String(localized: "Back")
                group.subitems.last?.label = String(localized: "Forward")
            }
        }
    }
}

/// Window-scoped commands keep settings search and navigation from reaching
/// the main terminal window's identically bound commands.
private final class SettingsWindow: NSWindow {
    weak var settingsController: SettingsWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Shortcut recorders must see the chord before navigation consumes it.
        if let button = firstResponder as? NSButton, button.performKeyEquivalent(with: event) { return true }
        if settingsController?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Holds the visible pane. Cached panes and saved offsets keep each category's
/// scroll position through navigation, search, and language changes.
private final class SettingsContentViewController: NSViewController {
    var onClearSearch: (() -> Void)?
    private(set) var category: SettingsCategory?
    private var panes: [SettingsCategory: SettingsPaneViewController] = [:]
    private var scrollPositions: [SettingsCategory: NSPoint] = [:]
    private let searchPrompt = NSStackView()
    private let promptTitle = NSTextField(labelWithString: "")
    private let promptDescription = NSTextField(wrappingLabelWithString: "")
    private let clearSearchButton = NSButton(title: "", target: nil, action: nil)
    private var hasSearchResults: Bool?

    override func loadView() {
        let container = NSView()
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 32, weight: .regular))
        symbol.contentTintColor = .tertiaryLabelColor
        symbol.setAccessibilityElement(false)
        promptTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        promptTitle.alignment = .center
        promptDescription.font = .systemFont(ofSize: NSFont.systemFontSize)
        promptDescription.textColor = .secondaryLabelColor
        promptDescription.alignment = .center
        clearSearchButton.bezelStyle = .rounded
        clearSearchButton.target = self
        clearSearchButton.action = #selector(clearSearch(_:))
        searchPrompt.orientation = .vertical
        searchPrompt.alignment = .centerX
        searchPrompt.spacing = 12
        for view in [symbol, promptTitle, promptDescription, clearSearchButton] as [NSView] {
            searchPrompt.addArrangedSubview(view)
        }
        searchPrompt.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchPrompt)
        NSLayoutConstraint.activate([
            searchPrompt.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            searchPrompt.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            searchPrompt.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            searchPrompt.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
            promptDescription.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        searchPrompt.isHidden = true
        view = container
    }

    func refreshLanguage() {
        for (category, pane) in panes where pane.isViewLoaded {
            if let scroll = pane.view as? NSScrollView { scrollPositions[category] = scroll.contentView.bounds.origin }
        }
        let visibleCategory = children.isEmpty ? nil : category
        removeVisiblePane()
        panes.removeAll()
        if let visibleCategory { show(visibleCategory) }
        if let hasSearchResults { updateSearchPrompt(hasResults: hasSearchResults) }
    }

    func show(_ category: SettingsCategory) {
        let pane = panes[category] ?? {
            let pane = category.makePane()
            pane.setCategory(category)
            panes[category] = pane
            return pane
        }()
        guard self.category != category || children.first !== pane else { return }

        let paneView = pane.view
        paneView.translatesAutoresizingMaskIntoConstraints = false
        saveVisiblePosition()
        removeVisiblePane()
        hasSearchResults = nil
        searchPrompt.isHidden = true
        addChild(pane)
        view.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneView.topAnchor.constraint(equalTo: view.topAnchor),
            paneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.category = category
        if let position = scrollPositions[category], let scroll = paneView as? NSScrollView {
            view.layoutSubtreeIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: position)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func reveal(_ result: SettingsSearchResult) {
        guard category == result.category else { return }
        _ = panes[result.category]?.revealSearchResult(result.title, in: result.section)
    }

    func showSearchPrompt(hasResults: Bool) {
        _ = view
        saveVisiblePosition()
        removeVisiblePane()
        hasSearchResults = hasResults
        updateSearchPrompt(hasResults: hasResults)
        searchPrompt.isHidden = false
    }

    private func updateSearchPrompt(hasResults: Bool) {
        promptTitle.stringValue = hasResults ? String(localized: "Select a Setting") : String(localized: "No Settings Found")
        promptDescription.stringValue = hasResults
            ? String(localized: "Choose a search result to view its settings.")
            : String(localized: "Try a different search.")
        clearSearchButton.title = String(localized: "Clear Search")
    }

    private func saveVisiblePosition() {
        guard let category, let scroll = children.first?.view as? NSScrollView else { return }
        scrollPositions[category] = scroll.contentView.bounds.origin
    }

    private func removeVisiblePane() {
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
    }

    @objc private func clearSearch(_ sender: Any?) {
        onClearSearch?()
    }
}
