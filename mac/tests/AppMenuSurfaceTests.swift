import AppKit
@testable import zshell

@MainActor
private final class AppMenuProbe {
    private var mainMenu: NSMenu?
    private var originalItems: [NSMenuItem] = []
    private var originalGroups: [AppMenuController.Menu: NSMenu] = [:]
    private var removalObservation: NSObjectProtocol?
    private var missingCount = 0
    private var pulses = 0
    private var fixtureManager: TerminalManager?
    private var fixtureWindow: NSWindow?

    func start() {
        setbuf(stdout, nil)
        guard let menu = NSApp.mainMenu else { fail("主菜单未安装") }
        mainMenu = menu
        originalItems = menu.items
        let expected: [AppMenuController.Menu] = [.application, .file, .edit, .view, .terminal, .window, .help]
        guard menu.items.map({ $0.identifier?.rawValue }) == expected.map(\.rawValue) else {
            fail("顶部应只有 7 个应用菜单：\(menu.items.map(\.title))")
        }
        for group in [AppMenuController.Menu.projects, .tabs, .browser, .agents, .notifications] {
            guard let submenu = AppMenuController.submenu(group, in: menu) else { fail("子菜单缺项：\(group)") }
            originalGroups[group] = submenu
        }
        guard QuickTerminalOffscreen.isSafe() else { fail("测试应用进入了用户屏幕或取得焦点") }
        guard AppSettings.shared.terminalBackend.rawValue == CommandLine.arguments[1] else {
            fail("终端后端未隔离")
        }
        guard let manager = TerminalManager.activeWindowManager, let window = manager.presentationWindow else {
            fail("AppKit runner 未创建初始工作区窗口")
        }
        fixtureManager = manager
        fixtureWindow = window
        AppMenuController.shared.refresh()
        guard let surface = manager.selectedProject?.selectedSession?.surface,
              CommandLine.arguments[1] == "libghostty" ? surface is ZshellTerminalView : surface is AlacrittyTerminalView else {
            fail("真实工作区未创建指定终端后端")
        }
        removalObservation = NotificationCenter.default.addObserver(
            forName: NSMenu.didRemoveItemNotification, object: menu, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let menu = self.mainMenu else { return }
                let titles = menu.items.map(\.title)
                let missing = self.originalItems.filter { original in !menu.items.contains { $0 === original } }.map(\.title)
                if !missing.isEmpty {
                    self.missingCount += 1
                    if self.missingCount <= 3 { print("MISSING \(missing)：\(titles)") }
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.pulses += 1
                if self.pulses <= 20 {
                    // 同时覆盖普通设置写入和不改变值的工作区发布，避免把触发绑定到浏览器导入。
                    if self.pulses.isMultiple(of: 2) { AppSettings.shared.notifyOnError.toggle() }
                    else { AppSettings.shared.objectWillChange.send() }
                    if self.pulses == 5 || self.pulses == 12 { self.fixtureManager?.objectWillChange.send() }
                } else {
                    timer.invalidate()
                    self.finish()
                }
            }
        }
    }

    private func finish() {
        print("RESULT \(CommandLine.arguments[1]): 20 次工作区发布，\(missingCount) 次顶部菜单缺项")
        guard missingCount == 0 else { fail("顶部菜单在工作区发布时被移除") }
        guard let mainMenu, NSApp.mainMenu === mainMenu,
              mainMenu.items.count == originalItems.count,
              zip(mainMenu.items, originalItems).allSatisfy({ $0 === $1 }) else {
            fail("工作区发布替换了主菜单或顶部菜单项")
        }
        guard NSApp.servicesMenu != nil, NSApp.windowsMenu != nil, NSApp.helpMenu != nil else {
            fail("系统服务、窗口或帮助菜单未注册")
        }
        for (group, original) in originalGroups {
            guard AppMenuController.submenu(group, in: mainMenu) === original else { fail("刷新替换了子菜单：\(group)") }
        }
        verifyMenuCommands(in: mainMenu)
        settle()
        if let removalObservation { NotificationCenter.default.removeObserver(removalObservation) }
        removalObservation = nil
        guard missingCount == 0 else { fail("窗口或菜单动作期间顶部菜单被移除") }
        guard QuickTerminalOffscreen.isSafe() else { fail("测试结束时离屏隔离失效") }
        cleanup()
        print("PASS \(CommandLine.arguments[1]): 主菜单和所有顶部菜单项保持原实例")
        exit(0)
    }

    private func verifyMenuCommands(in menu: NSMenu) {
        guard let manager = fixtureManager,
              let file = AppMenuController.submenu(.file, in: menu),
              let view = AppMenuController.submenu(.view, in: menu),
              let terminal = AppMenuController.submenu(.terminal, in: menu),
              let projects = AppMenuController.submenu(.projects, in: menu),
              let tabs = AppMenuController.submenu(.tabs, in: menu),
              let browser = AppMenuController.submenu(.browser, in: menu),
              let agents = AppMenuController.submenu(.agents, in: menu),
              let notifications = AppMenuController.submenu(.notifications, in: menu) else {
            fail("基础菜单或测试工作区不可用")
        }
        func descendants(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items + menu.items.compactMap(\.submenu).flatMap(descendants)
        }
        func check(_ value: Bool, _ message: String) { if !value { fail(message) } }
        func item(_ title: String) -> NSMenuItem {
            guard let item = descendants(menu).first(where: { $0.title == title }) else { fail("缺少动作：\(title)") }
            return item
        }
        func perform(_ title: String) {
            let item = item(title)
            guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else {
                fail("动作未路由：\(title)")
            }
            AppMenuController.shared.refresh()
        }
        check(projects.supermenu === NSApp.windowsMenu && tabs.supermenu === NSApp.windowsMenu,
              "项目和标签页不在系统窗口菜单下")
        check(browser.supermenu === view && agents.supermenu === terminal && notifications.supermenu === terminal,
              "浏览器、Agent 或通知归属错误")
        for command in AppCommand.allCases {
            let item = item(command.title)
            let shortcut = AppSettings.shared.commandShortcut(for: command)
            check(descendants(menu).filter { $0.title == command.title && $0.action != nil }.count == 1,
                  "动作被复制：\(command.rawValue)")
            check(item.keyEquivalent == String(shortcut.character)
                  && item.keyEquivalentModifierMask == shortcut.modifiers, "快捷键未保持：\(command.rawValue)")
        }
        let standardActions = ["Undo": "undo:", "Redo": "redo:", "Cut": "cut:", "Copy": "copy:",
                               "Paste": "paste:", "Delete": "delete:", "Select All": "selectAll:",
                               "Minimize": "performMiniaturize:", "Zoom": "performZoom:",
                               "Bring All to Front": "arrangeInFront:", "Enter Full Screen": "toggleFullScreen:"]
        for (title, selector) in standardActions {
            check(item(title).action == NSSelectorFromString(selector) && item(title).target == nil,
                  "系统动作未保留 responder chain：\(title)")
        }
        let originalOpener = AppMenuController.shared.openWindow
        var opened = false
        AppMenuController.shared.openWindow = { opened = true }
        perform("New Window")
        check(opened, "新窗口动作未进入工作区 opener")
        AppMenuController.shared.openWindow = originalOpener
        let expected: [(String, String, NSEvent.ModifierFlags)] = [
            ("Reopen Closed Session", "t", [.command, .shift]), ("Toggle Prompt Queue", "m", [.command, .shift]),
            ("Save", "s", .command), ("Find…", "f", .command), ("Find and Replace…", "f", [.command, .option]),
            ("Find Next", "g", .command), ("Use Selection for Find", "e", .command), ("Quick Launch…", "o", .command),
            ("Toggle Info Panel", "i", [.command, .shift]), ("Toggle Markdown Preview", "v", [.command, .shift]),
            ("Focus Address Bar", "l", .command), ("Reload Page", "r", .command), ("Split Right", "d", .command),
            ("Split Down", "d", [.command, .shift]), ("Focus Pane Left", "\u{f702}", [.command, .option]),
            ("Focus Pane Right", "\u{f703}", [.command, .option]), ("Focus Pane Up", "\u{f700}", [.command, .option]),
            ("Focus Pane Down", "\u{f701}", [.command, .option]), ("Focus Previous Pane", "[", .command),
            ("Focus Next Pane", "]", .command), ("Toggle Pane Zoom", "\r", [.command, .shift]),
            ("Equalize Panes", "=", [.command, .control]), ("Next Tab", "]", [.command, .shift]),
            ("Previous Tab", "[", [.command, .shift]),
        ]
        for (title, key, modifiers) in expected {
            let item = item(title)
            check(item.keyEquivalent == key && item.keyEquivalentModifierMask == modifiers, "固定快捷键未保持：\(title)")
        }
        let fullScreen = item("Enter Full Screen")
        // AppKit 可将标准全屏动作的 Control-Command-F 改为系统的 Fn-F。
        check(fullScreen.keyEquivalent == "f"
              && [.function, [.command, .control]].contains(fullScreen.keyEquivalentModifierMask),
              "标准全屏快捷键未保持")
        for title in ["New SSH Project…", "New Browser Tab", "Find Previous", "Stop Loading", "Open in Default Browser",
                      "Split Left", "Split Up", "Import Browser Data…", "Imported Browser History",
                      "Notification History…", "Show Unread Notifications", "Agent Conversation History",
                      "Search All Agent Conversations", "Workspace Templates…", "Command History…"] {
            check(item(title).action != nil && item(title).keyEquivalent.isEmpty
                  && descendants(menu).filter { $0.title == title && $0.action != nil }.count == 1,
                  "无快捷键动作遗漏或被复制：\(title)")
        }
        let terminalActions = ["Quick Terminal": "toggleQuickTerminal", "Search Terminal Logs": "searchTerminalLogs",
                               "Project Terminal Environment…": "editProjectTerminalEnvironment",
                               "Tab Terminal Environment…": "editTabTerminalEnvironment"]
        for (title, selector) in terminalActions {
            check(item(title).menu === terminal && item(title).action == NSSelectorFromString(selector),
                  "终端入口归属或动作改变：\(title)")
        }
        let attention = item("Next Agent Needing Attention")
        check(attention.menu === agents && attention.keyEquivalent == "a"
              && attention.keyEquivalentModifierMask == [.command, .shift], "Agent 注意力快捷键改变")
        let quickTerminal = item("Quick Terminal")
        check(quickTerminal.isHidden, "禁用 Quick Terminal 后菜单入口未隐藏")
        AppSettings.shared.quickTerminalEnabled = true
        AppMenuLocalization.shared.perform(NSSelectorFromString("refresh"))
        check(!quickTerminal.isHidden && item("Quick Terminal") === quickTerminal,
              "启用 Quick Terminal 替换或遗漏了原入口")
        AppSettings.shared.quickTerminalEnabled = false
        AppSettings.shared.terminalTextHints = true
        AppMenuLocalization.shared.perform(NSSelectorFromString("refresh"))
        let copyHint = item("Copy Terminal Hint…")
        let openHint = item("Open Terminal Hint…")
        // AppKit may clear the duplicate Hide Others equivalent; the existing
        // local monitor still owns this chord while a terminal has focus.
        check(copyHint.menu === terminal && openHint.menu === terminal
              && copyHint.keyEquivalent == "h" && copyHint.keyEquivalentModifierMask == [.command, .shift]
              && ["", "h"].contains(openHint.keyEquivalent) && openHint.keyEquivalentModifierMask == [.command, .option]
              && TerminalHintMenu.shared.items(for: nil).last?.keyEquivalent == "h",
              "终端提示入口或快捷键改变")
        AppSettings.shared.terminalTextHints = false
        AppMenuLocalization.shared.perform(NSSelectorFromString("refresh"))
        check(!terminal.items.contains { $0 === copyHint || $0 === openHint }, "禁用终端提示未移除入口")
        AppSettings.shared.terminalTextHints = true
        AppMenuLocalization.shared.perform(NSSelectorFromString("refresh"))
        check(terminal.items.filter { $0.identifier?.rawValue == "zshell-copy-terminal-hint" }.count == 1
              && terminal.items.filter { $0.identifier?.rawValue == "zshell-open-terminal-hint" }.count == 1,
              "启用终端提示复制或遗漏了入口")
        let staticActions = descendants(menu).filter { $0.action != nil && $0.menu !== NSApp.windowsMenu }
        AppMenuController.shared.install()
        for _ in 0..<20 { AppMenuLocalization.shared.perform(NSSelectorFromString("refresh")) }
        let refreshedActions = descendants(menu).filter { $0.action != nil && $0.menu !== NSApp.windowsMenu }
        check(staticActions.count == refreshedActions.count
              && zip(staticActions, refreshedActions).allSatisfy { $0 === $1 }, "刷新替换或复制了动作")
        let resize = item("Resize Pane").submenu!
        for (title, key) in [("Up", "\u{f700}"), ("Down", "\u{f701}"), ("Left", "\u{f702}"), ("Right", "\u{f703}")] {
            let resizeItem = resize.items.first { $0.title == title }!
            check(resizeItem.keyEquivalent == key && resizeItem.keyEquivalentModifierMask == [.command, .control],
                  "分屏调整快捷键未保留：\(title)")
        }
        let left = manager.isLeftSidebarVisible
        perform("Toggle Left Sidebar")
        check(manager.isLeftSidebarVisible != left, "侧栏动作没有进入当前工作区")
        perform("Toggle Left Sidebar")
        let count = manager.projects.count
        perform("New Project")
        check(manager.projects.count == count + 1, "新建项目菜单未路由")
        let project = manager.selectedProject!
        project.customName = "File"
        perform("New Session")
        let firstTab = project.tabs.last!
        firstTab.customName = "Window"
        perform("New Session")
        project.tabs.last?.customName = "Custom tab"
        AppMenuController.shared.refresh()
        let projectItem = projects.items.last { $0.title == "File" }!
        let tabItem = tabs.items.last { $0.title == "Window" }!
        check(projectItem.state == .on && tabItem.state == .off && tabs.items.last?.state == .on,
              "项目或标签页没有显示当前选中状态")
        project.customName = "Renamed project"
        firstTab.customName = "Renamed tab"
        AppMenuController.shared.refresh()
        check(projectItem.title == "Renamed project" && projects.items.contains { $0 === projectItem }, "项目重命名替换了菜单项")
        check(tabItem.title == "Renamed tab" && tabs.items.contains { $0 === tabItem }, "标签页重命名替换了菜单项")
        check(tabItem.keyEquivalentModifierMask == .control, "标签页数字快捷键未保留 Control")
        NSApp.sendAction(tabItem.action!, to: tabItem.target, from: tabItem)
        AppMenuController.shared.refresh()
        check(project.selectedTab?.id == firstTab.id, "动态标签页动作未按 ID 路由")
        check(tabItem.state == .on && tabs.items.filter { $0.state == .on }.count == 1,
              "标签页切换没有更新唯一选中勾")
        let other = manager.projects.first { $0 !== project }!
        manager.selectedProjectID = other.id
        NSApp.sendAction(projectItem.action!, to: projectItem.target, from: projectItem)
        AppMenuController.shared.refresh()
        check(manager.selectedProjectID == project.id, "动态项目动作未按 ID 路由")
        check(projectItem.state == .on && projects.items.filter { $0.state == .on }.count == 1,
              "项目切换没有更新唯一选中勾")
        manager.moveProject(project.id, to: other.id)
        AppMenuController.shared.refresh()
        check(projects.items[3] === projectItem && projectItem.keyEquivalent == "1",
              "项目重排未复用菜单项或更新数字快捷键")
        project.customName = "File"
        firstTab.customName = "Window"
        AppMenuController.shared.refresh()
        let newSessionItem = item(AppCommand.newSession.title)
        let remapped = CommandShortcut(character: "j", modifiers: [.command, .option])
        AppSettings.shared.commandShortcuts[.newSession] = remapped
        AppMenuController.shared.refresh()
        check(item(AppCommand.newSession.title) === newSessionItem && newSessionItem.keyEquivalent == "j"
              && newSessionItem.keyEquivalentModifierMask == remapped.modifiers, "快捷键重映射替换了菜单项")
        AppSettings.shared.commandShortcuts[.newSession] = nil
        AppMenuController.shared.refresh()
        for index in 0..<10 {
            let extra = Project(fallbackName: "Fixture \(index)", manager: manager, createInitialSession: false)
            manager.projects.append(extra)
            manager.selectedProject?.newSession()
        }
        AppMenuController.shared.refresh()
        check(projects.items.count == 12 && tabs.items.suffix(9).map(\.keyEquivalent) == (1...9).map(String.init),
              "动态项目和标签页未保持前 9 项数字快捷键")
        let staticTabs = Array(tabs.items.dropLast(9))
        for closing in project.tabs.dropFirst(2) { project.close(closing) }
        AppMenuController.shared.refresh()
        check(tabs.items.count == staticTabs.count + 2 && zip(tabs.items, staticTabs).allSatisfy { $0 === $1 },
              "9 → 2 个标签页把动态项插入了静态动作前")
        for _ in 0..<3 { project.newSession() }
        AppMenuController.shared.refresh()
        check(tabs.items.count == staticTabs.count + 5 && zip(tabs.items, staticTabs).allSatisfy { $0 === $1 }
              && tabs.items.suffix(5).map(\.keyEquivalent) == (1...5).map(String.init),
              "2 → 5 个标签页未保持静态动作与数字快捷键")
        let moving = project.tabs.last!
        let movingItem = tabs.items.last!
        project.moveTab(moving.id, to: project.tabs.first!.id)
        AppMenuController.shared.refresh()
        check(tabs.items[staticTabs.count] === movingItem && movingItem.keyEquivalent == "1",
              "标签页重排没有复用 ID 菜单项")
        let previousCount = TerminalManager.automationManagers.count
        originalOpener?()
        settle()
        check(TerminalManager.automationManagers.count == previousCount + 1, "工作区 opener 未创建第二窗口")
        check(NSApp.mainMenu === menu && menu.items.count == originalItems.count
              && zip(menu.items, originalItems).allSatisfy { $0 === $1 }, "新窗口创建替换了主菜单")
        if let second = TerminalManager.activeWindowManager, second !== manager {
            let secondProject = second.newProject()
            secondProject.customName = "Other window project"
            second.newSession()
            let selected = secondProject.selectedTab!
            selected.customName = "Other window tab"
            AppMenuController.shared.refresh()
            check(projects.items.last?.title == secondProject.name && projects.items.last?.state == .on
                  && tabs.items.last?.title == selected.displayTitle && tabs.items.last?.state == .on,
                  "第二窗口没有更新子菜单和选中勾")
            second.presentationWindow?.close()
            AppMenuController.shared.refresh()
            check(projects.items.contains { $0.title == "File" && $0.state == .on }
                  && !projects.items.contains { $0.title == secondProject.name }, "关闭第二窗口后子菜单没有回到当前窗口")
        } else { fail("新建窗口没有成为当前工作区") }
        for otherManager in TerminalManager.automationManagers where otherManager !== manager {
            otherManager.presentationWindow?.close()
        }
        AppMenuController.shared.refresh()
        let oldTitles = originalItems.map(\.title)
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            AppMenuController.shared.refresh()
            AppMenuLocalization.shared.perform(NSSelectorFromString("refresh"))
            check(NSApp.mainMenu === menu && zip(menu.items, originalItems).allSatisfy { $0 === $1 }, "切换语言替换了顶部菜单")
            check(menu.items[1].title == String(localized: "File"), "文件菜单未随语言切换")
            let titles: [(AppMenuController.Menu, String)] = [
                (.edit, String(localized: "Edit")), (.view, String(localized: "View")),
                (.terminal, String(localized: "Terminal")), (.window, String(localized: "Window")),
                (.help, String(localized: "Help")), (.projects, String(localized: "Projects")),
                (.tabs, String(localized: "Tabs")), (.browser, String(localized: "Browser")),
                (.agents, String(localized: "Agents")), (.notifications, String(localized: "Notifications")),
            ]
            for (id, title) in titles {
                check(AppMenuController.submenu(id, in: menu)?.title == title, "菜单未随语言切换：\(id)")
            }
            for (group, original) in originalGroups {
                check(AppMenuController.submenu(group, in: menu) === original, "语言切换替换了子菜单：\(group)")
            }
            check(descendants(menu).filter { $0.identifier?.rawValue == "browser-profile-import" }.first?.title
                  == String(localized: "Import Browser Data…"), "嵌套浏览器导入动作未本地化")
            check(projectItem.title == "File" && tabItem.title == "Window", "用户命名被当成本地化查找键")
        }
        AppLocalization.apply(.english)
        AppMenuController.shared.refresh()
        AppMenuLocalization.shared.perform(NSSelectorFromString("refresh"))
        check(menu.items.map(\.title) == oldTitles && newSessionItem.title == AppCommand.newSession.title, "返回英文未恢复原菜单标题")
        verifyBrowserImport(manager: manager, menu: menu)
        manager.newBrowserTab(initialURL: "about:blank")
        AppMenuController.shared.refresh()
        browser.update()
        check(item("Reload Page").isEnabled && manager.hasSelectedBrowser, "浏览器动作未跟随选中面板验证")
        manager.selectTab(index: 0)
        browser.update()
        check(!item("Reload Page").isEnabled, "纯终端状态没有禁用浏览器动作")
        manager.projects.forEach { manager.close($0) }
        AppMenuController.shared.refresh()
        check(projects.items.count == 3 && tabs.items.last?.isSeparatorItem == true, "关闭全部项目后动态菜单残留")
        file.update()
        check(newSessionItem.isEnabled, "无项目工作区的新建会话动作意外禁用")
        verifyWindowLifecycle(menu: menu, opener: originalOpener)
        print("PASS \(CommandLine.arguments[1]): 原动作、快捷键、动态 ID、17 种语言及系统菜单")
    }

    private func verifyBrowserImport(manager: TerminalManager, menu: NSMenu) {
        guard let project = manager.selectedProject else { fail("批量导入缺少项目") }
        manager.selectTab(index: 0)
        let selected = project.selectedTabID
        let count = project.tabs.count
        BrowserProfileImportController.shared.show(for: manager)
        guard let panel = NSApp.windows.first(where: { $0.title == String(localized: "Browser Data Import") }),
              let content = panel.contentView else { fail("真实浏览器导入面板未显示") }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let controls = views(content)
        func button(_ title: String) -> NSButton {
            guard let button = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                fail("浏览器导入缺少控件：\(title)")
            }
            return button
        }
        func click(_ button: NSButton) {
            guard let action = button.action, NSApp.sendAction(action, to: button.target, from: button) else {
                fail("浏览器导入控件未路由：\(button.title)")
            }
        }
        let preview = button("Preview")
        waitUntil("fixture Chrome profile 发现超时") { preview.isEnabled }
        for (title, state) in [("Cookies", NSControl.StateValue.off), ("History", .off), ("Open Tabs", .on)] {
            let checkbox = button(title)
            checkbox.state = state
            click(checkbox)
        }
        click(preview)
        let importing = button("Import")
        waitUntil("真实会话预览超时") { importing.isEnabled }
        click(importing)
        waitUntil("真实批量会话导入超时") { button("Preview").isEnabled }
        guard project.tabs.count == count + 24, project.selectedTabID == selected else {
            fail("真实批量导入未创建 24 个标签页或改变了终端选中项")
        }
        let imported = project.tabs.filter { !$0.browsers.isEmpty }
        guard imported.count == 24 else { fail("批量导入标签页类型错误") }
        for tab in imported { project.close(tab) }
        panel.close()
        settle()
        AppMenuController.shared.refresh()
        guard project.tabs.count == count, project.selectedTabID == selected,
              project.selectedSession != nil, NSApp.mainMenu === menu,
              zip(menu.items, originalItems).allSatisfy({ $0 === $1 }) else {
            fail("批量导入后关闭浏览器未回到原终端或改变菜单实例")
        }
        print("PASS \(CommandLine.arguments[1]): 真实 Chrome 会话预览、24 标签页导入及关闭后回到终端")
    }

    private func verifyWindowLifecycle(menu: NSMenu, opener: (() -> Void)?) {
        guard let manager = fixtureManager, let window = fixtureWindow,
              let opener else { fail("工作区 opener 未保持") }
        manager.newProject().customName = "Reopen fixture"
        window.setContentSize(NSSize(width: 940, height: 610))
        let frameName = window.frameAutosaveName
        window.close()
        settle()
        guard TerminalManager.automationManagers.isEmpty else { fail("最后窗口关闭未清理唯一 manager") }
        AppMenuController.shared.refresh()
        let file = AppMenuController.submenu(.file, in: menu)!
        let terminal = AppMenuController.submenu(.terminal, in: menu)!
        file.update()
        terminal.update()
        guard menu.items.count == 7, NSApp.windowsMenu === AppMenuController.submenu(.window, in: menu),
              NSApp.helpMenu === AppMenuController.submenu(.help, in: menu),
              file.items.first(where: { $0.title == "New Window" })?.isEnabled == true,
              file.items.first(where: { $0.title == "New Session" })?.isEnabled == false,
              terminal.items.first(where: { $0.title == "Project Terminal Environment…" })?.isEnabled == false else {
            fail("无工作区窗口时菜单实例、系统菜单或可用状态改变")
        }
        guard UserDefaults.standard.string(forKey: "NSWindow Frame \(frameName)") != nil else {
            fail("关闭窗口未保存原 main-AppWindow-N frame")
        }
        opener()
        settle()
        guard let reopened = TerminalManager.activeWindowManager,
              reopened.selectedProject?.name == "Reopen fixture",
              reopened.presentationWindow?.frameAutosaveName == frameName else {
            fail("最后窗口关闭后重开未恢复会话与 autosave 名")
        }
        guard NSApp.mainMenu === menu && menu.items.count == originalItems.count
                && zip(menu.items, originalItems).allSatisfy({ $0 === $1 }) else {
            fail("最后窗口重开替换了主菜单")
        }
        fixtureManager = reopened
        fixtureWindow = reopened.presentationWindow
        print("PASS \(CommandLine.arguments[1]): 新窗口、最后窗口关闭/重开、会话与 autosave")
    }

    private func settle() {
        let end = Date().addingTimeInterval(0.1)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    private func waitUntil(_ failure: String, condition: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !condition() && Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if !condition() { fail(failure) }
    }

    private func cleanup() {
        fixtureWindow?.close()
        TerminalManager.prepareForApplicationQuit(endAll: true)
        _ = try? PTYMuxCommandLine.exchange(method: "shutdown", timeout: 0.5)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
    }

    private func fail(_ message: String) -> Never {
        fputs("FAIL \(message)\n", stderr)
        cleanup()
        exit(1)
    }
}

@main
struct AppMenuSurfaceTests {
    @MainActor static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        precondition(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
                     == URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path)
        QuickTerminalOffscreen.install()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        AppLocalization.apply(.english)
        let probe = AppMenuProbe()
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
            MainActor.assumeIsolated { probe.start() }
        }
        zshellApp.main()
    }
}
