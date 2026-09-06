//
//  SettingsWindowController.swift
//  zshell
//

import AppKit

/// One page of settings. Categories exist so a setting can be found by where
/// it acts, rather than by scrolling one long form.
enum SettingsCategory: String, CaseIterable {
    case general
    case appearance
    case terminal
    case editor
    case automation
    case updates

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .terminal: String(localized: "Terminal")
        case .editor: String(localized: "Editor")
        case .automation: String(localized: "Automation")
        case .updates: String(localized: "Updates")
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .terminal: "terminal.fill"
        case .editor: "curlybraces"
        case .automation: "sparkles"
        case .updates: "arrow.down.circle.fill"
        }
    }

    func makePane() -> SettingsPaneViewController {
        switch self {
        case .general: SettingsGeneralPane()
        case .appearance: SettingsAppearancePane()
        case .terminal: SettingsTerminalPane()
        case .editor: SettingsEditorPane()
        case .automation: SettingsAutomationPane()
        case .updates: SettingsUpdatesPane()
        }
    }
}

/// The settings window (⌘,). One shared instance: reopening brings the same
/// window forward, still on the category last used.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private static let categoryDefaultsKey = "zshell.settings.category"
    private static let frameAutosaveName = "Settings"
    private static let sidebarWidth: CGFloat = 188
    private static let defaultContentSize = NSSize(width: 720, height: 660)

    private let sidebar = SettingsSidebarViewController()
    private let content = SettingsContentViewController()

    private init() {
        let split = NSSplitViewController()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 440
        split.addSplitViewItem(contentItem)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Assigning the content view controller resizes the window to that
        // controller's fitting size, discarding the contentRect above, so the
        // default size is applied after it.
        window.contentViewController = split
        window.setContentSize(Self.defaultContentSize)
        window.contentMinSize = NSSize(width: 660, height: 460)
        // Cmd-W closes the key window unless a main window is up front, so this
        // identifier must not start with "main" — see ZshellCommands.
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        // setFrameAutosaveName writes the current frame immediately, so a
        // remembered one has to be restored before the name is set.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        super.init(window: window)

        sidebar.onSelect = { [weak self] category in
            self?.select(category)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        select(restoredCategory)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private var restoredCategory: SettingsCategory {
        content.category
            ?? UserDefaults.standard.string(forKey: Self.categoryDefaultsKey)
                .flatMap(SettingsCategory.init(rawValue:))
            ?? .general
    }

    private func select(_ category: SettingsCategory) {
        sidebar.select(category)
        content.show(category)
        window?.title = category.title
        UserDefaults.standard.set(category.rawValue, forKey: Self.categoryDefaultsKey)
    }
}

/// Holds the visible pane. Panes are kept once built so switching back keeps
/// each one's scroll position.
private final class SettingsContentViewController: NSViewController {
    private(set) var category: SettingsCategory?
    private var panes: [SettingsCategory: SettingsPaneViewController] = [:]

    override func loadView() {
        view = NSView()
    }

    func show(_ category: SettingsCategory) {
        guard self.category != category else { return }
        self.category = category

        let pane = panes[category] ?? {
            let pane = category.makePane()
            panes[category] = pane
            return pane
        }()

        for child in children where child !== pane {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        addChild(pane)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pane.view.topAnchor.constraint(equalTo: view.topAnchor),
            pane.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
