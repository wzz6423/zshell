import AppKit
import Combine

@MainActor
final class AppMenuController: NSObject, NSMenuDelegate {
    static let shared = AppMenuController()
    var openWindow: (() -> Void)?
    private var titleUpdates: [() -> Void] = []
    private var shortcutUpdates: [() -> Void] = []
    private var mainMenu: NSMenu?
    private var projectsMenu: NSMenu?
    private var tabsMenu: NSMenu?
    private var projectItems: [UUID: AppCommandMenuItem] = [:]
    private var tabItems: [UUID: AppCommandMenuItem] = [:]
    private weak var focusedManager: TerminalManager?
    private var managerObservation: AnyCancellable?
    private var windowObservations: [NSObjectProtocol] = []
    private var dynamicRefreshScheduled = false
    private var updaterObservation: AnyCancellable?

    private var manager: TerminalManager? { TerminalManager.activeWindowManager }

    func install() {
        guard mainMenu == nil else { return }
        let menu = NSMenu()
        mainMenu = menu
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Zshell"
        let application = addMenu(to: menu, title: { appName })
        standard(application, title: { String(localized: "About \(appName)") }, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        command(application, title: { Updater.shared.updateActionTitle }, enabled: {
            Updater.shared.canCheckForUpdates && !Updater.shared.isUpdating
        }) { Updater.shared.checkForUpdates() }
        application.addItem(.separator())
        command(application, title: { String(localized: "Settings…") }, key: ",") { SettingsWindowController.shared.show() }
        let keepAwake = addMenu(to: application, title: { String(localized: "Keep computer awake") })
        for mode in KeepAwakeMode.allCases {
            let item = command(keepAwake, title: { mode.title }) { AppSettings.shared.keepAwakeMode = mode }
            titleUpdates.append {
                let state: NSControl.StateValue = AppSettings.shared.keepAwakeMode == mode ? .on : .off
                if item.state != state { item.state = state }
            }
        }
        application.addItem(.separator())
        command(application, title: { String(localized: "Export Settings…") }) { SettingsImportExport.exportSettings() }
        command(application, title: { String(localized: "Import Settings…") }) { SettingsImportExport.importSettings() }
        application.addItem(.separator())
        NSApp.servicesMenu = addMenu(to: application, title: { String(localized: "Services") })
        application.addItem(.separator())
        standard(application, title: { String(localized: "Hide \(appName)") }, action: #selector(NSApplication.hide(_:)), key: "h")
        standard(application, title: { String(localized: "Hide Others") }, action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option])
        standard(application, title: { String(localized: "Show All") }, action: #selector(NSApplication.unhideAllApplications(_:)))
        application.addItem(.separator())
        standard(application, title: { String(localized: "Quit \(appName)") }, action: #selector(NSApplication.terminate(_:)), key: "q")

        let file = addMenu(to: menu, title: { String(localized: "File") })
        managed(file, .newProject) { $0.newProject() }
        managed(file, title: { String(localized: "New SSH Project…") }) { $0.promptForSSHProject() }
        managed(file, .newSession) { $0.newSession() }
        managed(file, title: { String(localized: "Reopen Closed Session") }, key: "t", modifiers: [.command, .shift], enabled: { $0.canReopenClosedSession }) { $0.reopenClosedSession() }
        managed(file, title: { String(localized: "Toggle Prompt Queue") }, key: "m", modifiers: [.command, .shift], enabled: { $0.canTogglePromptQueue }) { $0.togglePromptQueue() }
        managed(file, title: { String(localized: "New Browser Tab") }) { $0.newBrowserTab() }
        let newWindow = command(file, title: { AppCommand.newWindow.title }) { [weak self] in self?.openWindow?() }
        shortcutUpdates.append { newWindow.apply(AppSettings.shared.commandShortcut(for: .newWindow)) }
        let close = command(file, title: { AppCommand.closePane.title }, enabled: { NSApp.keyWindow != nil }) { [weak self] in
            // 面板关闭仅归主工作区，设置等独立窗口保留 AppKit 的标准关闭行为。
            if let manager = self?.manager, manager.selectedProject != nil,
               NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true {
                manager.closeSelectedTab()
            } else { NSApp.keyWindow?.performClose(nil) }
        }
        shortcutUpdates.append { close.apply(AppSettings.shared.commandShortcut(for: .closePane)) }
        file.addItem(.separator())
        managed(file, title: { String(localized: "Save") }, key: "s") { $0.saveSelectedFile() }

        let edit = addMenu(to: menu, title: { String(localized: "Edit") })
        standard(edit, title: { String(localized: "Undo") }, action: NSSelectorFromString("undo:"), key: "z")
        standard(edit, title: { String(localized: "Redo") }, action: NSSelectorFromString("redo:"), key: "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        standard(edit, title: { String(localized: "Cut") }, action: #selector(NSText.cut(_:)), key: "x")
        standard(edit, title: { String(localized: "Copy") }, action: #selector(NSText.copy(_:)), key: "c")
        standard(edit, title: { String(localized: "Paste") }, action: #selector(NSText.paste(_:)), key: "v")
        standard(edit, title: { String(localized: "Delete") }, action: #selector(NSText.delete(_:)))
        standard(edit, title: { String(localized: "Select All") }, action: #selector(NSText.selectAll(_:)), key: "a")
        let find = addMenu(to: edit, title: { String(localized: "Find") })
        managed(find, title: { String(localized: "Find…") }, key: "f", enabled: { $0.canFind }) { $0.performFindAction(.show) }
        managed(find, title: { String(localized: "Find and Replace…") }, key: "f", modifiers: [.command, .option], enabled: { $0.canReplace }) { $0.performFindAction(.replace) }
        managed(find, title: { String(localized: "Find Next") }, key: "g", enabled: { $0.canFind }) { $0.performFindAction(.next) }
        managed(find, title: { String(localized: "Find Previous") }, enabled: { $0.canFind }) { $0.performFindAction(.previous) }
        managed(find, title: { String(localized: "Use Selection for Find") }, key: "e", enabled: { $0.canFind }) { $0.performFindAction(.useSelection) }
        edit.addItem(.separator())
        managed(edit, .clearTerminal, enabled: { $0.canClearActiveTerminal }) { $0.clearActiveTerminal() }

        let view = addMenu(to: menu, title: { String(localized: "View") })
        managed(view, .commandPalette) { $0.toggleCommandPalette() }
        managed(view, title: { String(localized: "Quick Launch…") }, key: "o") { $0.toggleQuickLaunch() }
        view.addItem(.separator())
        managed(view, .toggleLeftSidebar) { $0.toggleLeftSidebar() }
        managed(view, .toggleRightSidebar, enabled: { $0.selectedProject != nil }) { $0.toggleSidebar() }
        managed(view, .toggleFilesPanel, enabled: { $0.selectedProject != nil }) { $0.togglePanel(.files) }
        managed(view, .toggleGitPanel, enabled: { $0.selectedProject != nil }) { $0.togglePanel(.git) }
        managed(view, title: { String(localized: "Toggle Info Panel") }, key: "i", modifiers: [.command, .shift], enabled: { $0.selectedProject != nil }) { $0.togglePanel(.info) }
        view.addItem(.separator())
        managed(view, title: { String(localized: "Toggle Markdown Preview") }, key: "v", modifiers: [.command, .shift], enabled: { $0.canToggleMarkdownPreview }) { $0.toggleMarkdownPreview() }
        view.addItem(.separator())
        standard(view, title: {
            NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
                ? String(localized: "Exit Full Screen") : String(localized: "Enter Full Screen")
        }, action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control])

        let projects = addMenu(to: menu, title: { String(localized: "Projects") })
        projectsMenu = projects
        managed(projects, .nextProject) { $0.selectNextProject() }
        managed(projects, .previousProject) { $0.selectPreviousProject() }
        projects.addItem(.separator())

        let browser = addMenu(to: menu, title: { String(localized: "Browser") })
        managed(browser, title: { String(localized: "Focus Address Bar") }, key: "l", enabled: { $0.hasSelectedBrowser }) { $0.focusBrowserAddressBar() }
        managed(browser, title: { String(localized: "Reload Page") }, key: "r", enabled: { $0.hasSelectedBrowser }) { $0.reloadSelectedBrowser() }
        managed(browser, title: { String(localized: "Stop Loading") }, enabled: { $0.hasSelectedBrowser }) { $0.stopSelectedBrowser() }
        browser.addItem(.separator())
        managed(browser, title: { String(localized: "Open in Default Browser") }, enabled: { $0.hasSelectedBrowser }) { $0.openSelectedPageInDefaultBrowser() }

        let tabs = addMenu(to: menu, title: { String(localized: "Tabs") })
        tabsMenu = tabs
        managed(tabs, title: { String(localized: "Split Right") }, key: "d", enabled: { $0.canSplit }) { $0.splitRight() }
        managed(tabs, title: { String(localized: "Split Down") }, key: "d", modifiers: [.command, .shift], enabled: { $0.canSplit }) { $0.splitDown() }
        managed(tabs, title: { String(localized: "Split Left") }, enabled: { $0.canSplit }) { $0.splitLeft() }
        managed(tabs, title: { String(localized: "Split Up") }, enabled: { $0.canSplit }) { $0.splitUp() }
        tabs.addItem(.separator())
        managed(tabs, title: { String(localized: "Focus Pane Left") }, key: "\u{f702}", modifiers: [.command, .option]) { $0.focusPaneLeft() }
        managed(tabs, title: { String(localized: "Focus Pane Right") }, key: "\u{f703}", modifiers: [.command, .option]) { $0.focusPaneRight() }
        managed(tabs, title: { String(localized: "Focus Pane Up") }, key: "\u{f700}", modifiers: [.command, .option]) { $0.focusPaneUp() }
        managed(tabs, title: { String(localized: "Focus Pane Down") }, key: "\u{f701}", modifiers: [.command, .option]) { $0.focusPaneDown() }
        managed(tabs, title: { String(localized: "Focus Previous Pane") }, key: "[") { $0.focusPreviousPane() }
        managed(tabs, title: { String(localized: "Focus Next Pane") }, key: "]") { $0.focusNextPane() }
        tabs.addItem(.separator())
        managed(tabs, title: { String(localized: "Toggle Pane Zoom") }, key: "\r", modifiers: [.command, .shift], enabled: { $0.hasSplitPanes }) { $0.togglePaneZoom() }
        managed(tabs, title: { String(localized: "Equalize Panes") }, key: "=", modifiers: [.command, .control], enabled: { $0.hasSplitPanes }) { $0.equalizePanes() }
        let resize = addMenu(to: tabs, title: { String(localized: "Resize Pane") })
        managed(resize, title: { String(localized: "Up") }, key: "\u{f700}", modifiers: [.command, .control], enabled: { $0.hasSplitPanes }) { $0.resizePaneUp() }
        managed(resize, title: { String(localized: "Down") }, key: "\u{f701}", modifiers: [.command, .control], enabled: { $0.hasSplitPanes }) { $0.resizePaneDown() }
        managed(resize, title: { String(localized: "Left") }, key: "\u{f702}", modifiers: [.command, .control], enabled: { $0.hasSplitPanes }) { $0.resizePaneLeft() }
        managed(resize, title: { String(localized: "Right") }, key: "\u{f703}", modifiers: [.command, .control], enabled: { $0.hasSplitPanes }) { $0.resizePaneRight() }
        tabs.addItem(.separator())
        managed(tabs, title: { String(localized: "Next Tab") }, key: "]", modifiers: [.command, .shift]) { $0.selectNextTab() }
        managed(tabs, title: { String(localized: "Previous Tab") }, key: "[", modifiers: [.command, .shift]) { $0.selectPreviousTab() }
        tabs.addItem(.separator())

        let windows = addMenu(to: menu, title: { String(localized: "Window") })
        NSApp.windowsMenu = windows
        standard(windows, title: { String(localized: "Minimize") }, action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        standard(windows, title: { String(localized: "Zoom") }, action: #selector(NSWindow.performZoom(_:)))
        windows.addItem(.separator())
        standard(windows, title: { String(localized: "Bring All to Front") }, action: #selector(NSApplication.arrangeInFront(_:)))
        let help = addMenu(to: menu, title: { String(localized: "Help") })
        NSApp.helpMenu = help
        standard(help, title: { String(localized: "Help") }, action: #selector(NSApplication.showHelp(_:)), key: "?")

        // AppKit 保留菜单实例，工作区内容重算不会移除顶层菜单。
        NSApp.mainMenu = menu
        updaterObservation = Updater.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refresh()
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            windowObservations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        titleUpdates.forEach { $0() }
        shortcutUpdates.forEach { $0() }
        refreshDynamicItems()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func refreshDynamicItems() {
        let manager = manager
        if focusedManager !== manager {
            focusedManager = manager
            managerObservation = manager?.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.scheduleDynamicRefresh()
            }
        }
        if let projectsMenu {
            let projects = Array((manager?.visibleSidebarProjects ?? []).prefix(9))
            let ids = Set(projects.map(\.id))
            for id in projectItems.keys.filter({ !ids.contains($0) }) {
                if let item = projectItems.removeValue(forKey: id) { projectsMenu.removeItem(item) }
            }
            for (index, project) in projects.enumerated() {
                let id = project.id
                let item = projectItems[id] ?? AppCommandMenuItem(title: project.name, enabled: { [weak self] in
                    self?.manager?.visibleSidebarProjects.contains { $0.id == id } == true
                }) { [weak self] in
                    guard let manager = self?.manager,
                          let index = manager.visibleSidebarProjects.firstIndex(where: { $0.id == id }) else { return }
                    manager.selectProject(index: index)
                }
                projectItems[id] = item
                if item.title != project.name { item.title = project.name }
                item.apply(CommandShortcut(character: Character("\(index + 1)"), modifiers: .command))
                place(item, in: projectsMenu, at: index + 3)
            }
        }
        if let tabsMenu {
            let tabs = Array((manager?.selectedProject?.tabs ?? []).prefix(9))
            let ids = Set(tabs.map(\.id))
            for id in tabItems.keys.filter({ !ids.contains($0) }) {
                if let item = tabItems.removeValue(forKey: id) { tabsMenu.removeItem(item) }
            }
            let start = tabsMenu.items.count - tabItems.count
            for (index, tab) in tabs.enumerated() {
                let id = tab.id
                let title = tab.displayTitle ?? String(localized: "Tab \(index + 1)")
                let item = tabItems[id] ?? AppCommandMenuItem(title: title, enabled: { [weak self] in
                    self?.manager?.selectedProject?.tabs.contains { $0.id == id } == true
                }) { [weak self] in
                    guard let manager = self?.manager,
                          let index = manager.selectedProject?.tabs.firstIndex(where: { $0.id == id }) else { return }
                    manager.selectTab(index: index)
                }
                tabItems[id] = item
                if item.title != title { item.title = title }
                item.apply(CommandShortcut(character: Character("\(index + 1)"), modifiers: .control))
                place(item, in: tabsMenu, at: start + index)
            }
        }
    }

    private func scheduleDynamicRefresh() {
        guard !dynamicRefreshScheduled else { return }
        dynamicRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.dynamicRefreshScheduled = false
            self?.refreshDynamicItems()
        }
    }

    private func place(_ item: NSMenuItem, in menu: NSMenu, at index: Int) {
        if item.menu === menu, menu.index(of: item) == index { return }
        item.menu?.removeItem(item)
        menu.insertItem(item, at: index)
    }

    private func addMenu(to parent: NSMenu, title: @escaping () -> String) -> NSMenu {
        let item = NSMenuItem(title: title(), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: item.title)
        menu.delegate = self
        item.submenu = menu
        parent.addItem(item)
        titleUpdates.append {
            let title = title()
            if item.title != title { item.title = title }
            if menu.title != title { menu.title = title }
        }
        return menu
    }

    private func standard(_ menu: NSMenu, title: @escaping () -> String, action: Selector,
                          key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
        let item = NSMenuItem(title: title(), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        menu.addItem(item)
        titleUpdates.append { let value = title(); if item.title != value { item.title = value } }
    }

    @discardableResult
    private func command(_ menu: NSMenu, title: @escaping () -> String, key: String = "",
                         modifiers: NSEvent.ModifierFlags = .command,
                         enabled: @escaping () -> Bool = { true }, action: @escaping () -> Void) -> AppCommandMenuItem {
        let item = AppCommandMenuItem(title: title(), enabled: enabled, action: action)
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        menu.addItem(item)
        titleUpdates.append { let value = title(); if item.title != value { item.title = value } }
        return item
    }

    private func managed(_ menu: NSMenu, _ appCommand: AppCommand,
                         enabled: @escaping (TerminalManager) -> Bool = { _ in true },
                         action: @escaping (TerminalManager) -> Void) {
        let item = managed(menu, title: { appCommand.title }, enabled: enabled, action: action)
        shortcutUpdates.append { item.apply(AppSettings.shared.commandShortcut(for: appCommand)) }
    }

    @discardableResult
    private func managed(_ menu: NSMenu, title: @escaping () -> String, key: String = "",
                         modifiers: NSEvent.ModifierFlags = .command,
                         enabled: @escaping (TerminalManager) -> Bool = { _ in true },
                         action: @escaping (TerminalManager) -> Void) -> AppCommandMenuItem {
        command(menu, title: title, key: key, modifiers: modifiers, enabled: { [weak self] in
            self?.manager.map(enabled) ?? false
        }) { [weak self] in if let manager = self?.manager { action(manager) } }
    }
}

/// 与项目已有的闭包菜单项相同，由 AppKit 在执行快捷键前验证当前工作区状态。
@MainActor
private final class AppCommandMenuItem: NSMenuItem, NSMenuItemValidation {
    private let onAction: () -> Void
    private let isAvailable: () -> Bool

    init(title: String, enabled: @escaping () -> Bool, action: @escaping () -> Void) {
        isAvailable = enabled
        onAction = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isAvailable() }
    @objc private func invoke() { if isAvailable() { onAction() } }
    func apply(_ shortcut: CommandShortcut) {
        let key = String(shortcut.character)
        if keyEquivalent != key { keyEquivalent = key }
        if keyEquivalentModifierMask != shortcut.modifiers { keyEquivalentModifierMask = shortcut.modifiers }
    }
}
