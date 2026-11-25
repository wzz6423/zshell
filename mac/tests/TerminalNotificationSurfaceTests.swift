import AppKit
import Foundation
import UserNotifications
@testable import zshell

@MainActor
private final class NotificationSurfaceDelivery: TerminalNotificationDelivery {
    var allowsDelivery = false
    var defersSettings = false
    var settingsCompletions: [@Sendable (TerminalNotificationAuthorization) -> Void] = []
    var delivered: [TerminalNotificationRecord] = []
    func configure(delegate: any UNUserNotificationCenterDelegate) {}
    func settings(_ completion: @escaping @Sendable (TerminalNotificationAuthorization) -> Void) {
        if defersSettings { settingsCompletions.append(completion) } else { completion(.init(status: allowsDelivery ? .allowed : .denied)) }
    }
    func finishSettings() {
        let callbacks = settingsCompletions
        settingsCompletions.removeAll()
        callbacks.forEach { $0(.init(status: allowsDelivery ? .allowed : .denied)) }
    }
    func authorize(_ completion: @escaping @Sendable (Bool) -> Void) {
        preconditionFailure("The fixture must never request notification permission")
    }
    func deliver(_ record: TerminalNotificationRecord) { delivered.append(record) }
    func remove(ids: [UUID]) {}
}

@main
@MainActor
struct TerminalNotificationSurfaceTests {
    static func main() {
        do { try run() } catch { fputs("Notification surface failed: \(error)\n", stderr); exit(1) }
    }

    static func pump(_ duration: TimeInterval = 0.02) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    static func wait(_ message: String, _ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline { if predicate() { return }; pump() }
        throw NSError(domain: "NotificationSurface", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else {
            throw NSError(
                domain: "NotificationSurface", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        print("PASS \(CommandLine.arguments[1]): \(message)")
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let history = TerminalNotificationHistoryStore(url: root.appendingPathComponent("notifications/records.json"))
        let delivery = NotificationSurfaceDelivery()
        let service = TerminalNotificationService(history: history, delivery: delivery)
        TerminalNotificationService.shared = service
        service.configure()
        try wait("notification history did not load") { !history.isLoading }

        AppSettings.shared.terminalBackend = CommandLine.arguments[1] == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        AppSettings.shared.notifyFinishSeconds = 0
        AppSettings.shared.notifyOnError = true
        AppSettings.shared.quickTerminalMode = .reuse
        let first = TerminalManager(), second = TerminalManager()
        guard let project1 = first.selectedProject, let project2 = second.selectedProject,
            let session1 = project1.sessions.first, let session2 = project2.sessions.first
        else {
            throw NSError(domain: "NotificationSurface", code: 3)
        }
        var windows: [NSWindow] = []
        func mount(_ session: TerminalSession, manager: TerminalManager) {
            let surface = session.surface
            surface.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
            let window = NSWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = surface
            manager.attach(to: window)
            window.orderFront(nil)
            surface.setSurfaceVisible(true)
            windows.append(window)
        }
        mount(session1, manager: first)
        mount(session2, manager: second)
        defer {
            GlobalTerminalOverlay.shared.stop()
            first.projects.forEach { $0.terminateAll() }
            second.projects.forEach { $0.terminateAll() }
            pump(0.3)
            windows.forEach {
                $0.contentView = nil; $0.close()
            }
        }
        try wait("both terminal processes did not launch") { session1.shellPid != nil && session2.shellPid != nil }
        func send(_ text: String, to session: TerminalSession) { session.sendCommand(text); session.sendEnter() }
        send("printf 'NOTIFICATION_FIXTURE_READY\\n'", to: session2)
        try wait("terminal prompt did not respond") {
            session2.surface.readVisibleText(maxLines: 100, maxColumns: 200)?.contains("NOTIFICATION_FIXTURE_READY") == true
        }
        let evidence = root.appendingPathComponent("shell-hooks.txt")
        send(
            "printf '%s %s %s' ${+functions[_zshell_notify_precmd]} ${+functions[_zshell_notify_preexec]} ${_zshell_notify_on_error:-unset} > "
                + TerminalSession.shellQuote(evidence.path), to: session2)
        try wait("shell integration evidence did not appear") { FileManager.default.fileExists(atPath: evidence.path) }
        let hooks = try String(contentsOf: evidence, encoding: .utf8)
        try check(hooks == "1 1 1", "real zsh loaded the command notification hooks: \(hooks)")
        pump(0.3)
        let commandID = UUID()
        send("printf '\\033]777;notify;zshell-command:\(commandID):1:7;Fixture failed\\033\\\\'", to: session2)
        try wait("backend did not forward OSC notification and exit metadata") {
            history.records.contains { $0.kind == .command && $0.message == "Fixture failed" && $0.isFailure }
        }
        guard let record = history.records.first(where: { $0.message == "Fixture failed" }) else { preconditionFailure() }
        try check(
            record.target.terminalID == session2.id && record.target.projectID == project2.id,
            "real PTY delivers structured failure with its window and project")
        let replay = "printf '\\033]777;notify;zshell-command:\(commandID):1:7;Fixture failed\\033\\\\'"
        send(replay, to: session1)
        try wait("duplicate event did not reach the other surface") {
            history.record(id: record.id)?.target.terminalID == session1.id
        }
        try check(
            history.records.filter { $0.message == "Fixture failed" }.count == 1,
            "replayed command metadata is deduplicated across terminal surfaces")
        // Ghostty throttles OSC desktop notifications before they reach the app.
        pump(1.3)
        send("false", to: session2)
        do {
            try wait("zsh failure notification did not arrive") {
                history.records.contains {
                    $0.kind == .command && $0.isFailure && $0.message.hasPrefix("false failed") && $0.message.contains("exit 1")
                }
            }
        } catch {
            let stateFile = root.appendingPathComponent("shell-notify-state.txt")
            send(
                "printf '%s %s %s' $_zshell_notify_sequence $_zshell_notify_stamp $_zshell_notify_word > "
                    + TerminalSession.shellQuote(stateFile.path), to: session2)
            try? wait("shell state did not appear") { FileManager.default.fileExists(atPath: stateFile.path) }
            print("DIAGNOSTIC notify state=\((try? String(contentsOf: stateFile, encoding: .utf8)) ?? "missing")")
            print("DIAGNOSTIC terminal=\(session2.surface.readVisibleText(maxLines: 100, maxColumns: 200) ?? "")")
            print("DIAGNOSTIC history=\(history.records.map { "\($0.kind):\($0.message)" })")
            print("DIAGNOSTIC command lifecycle=\(session2.commandLifecycle)")
            throw error
        }
        try check(history.filtered(.failed).count >= 2, "real zsh exit status reaches the failed filter")

        let controller = TerminalNotificationCenterController(service: service)
        let menu = NSMenu()
        let terminal = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        terminal.identifier = .init(AppMenuController.Menu.terminal.rawValue)
        terminal.submenu = NSMenu(title: terminal.title)
        let notifications = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        notifications.identifier = .init(AppMenuController.Menu.notifications.rawValue)
        notifications.submenu = NSMenu(title: notifications.title)
        terminal.submenu!.addItem(notifications)
        menu.addItem(terminal)
        controller.installMenu(in: menu)
        controller.installMenu(in: menu)
        try check(
            menu.items.count == 1 && notifications.submenu?.items.count == 2,
            "native notification menu installs once")
        controller.show()
        guard let panel = controller.windowController?.window,
            let content = panel.contentViewController as? TerminalNotificationCenterViewController
        else { preconditionFailure() }
        pump(0.2)
        let views = descendants(content.view)
        guard
            let filter = views.compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.identifier?.rawValue == "notification-filter" }),
            let showPane = views.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "notification-open" }),
            let markRead = views.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "notification-mark-read" }),
            let allRead = views.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "notification-mark-all-read" }),
            let remove = views.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "notification-remove" }),
            let clear = views.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "notification-clear" })
        else {
            preconditionFailure("Notification controls are missing")
        }
        content.view.layoutSubtreeIfNeeded()
        let bounds = content.view.bounds.insetBy(dx: -1, dy: -1)
        try check(remove.isHidden, "remove stays hidden until a notification is selected")
        for control in [filter, showPane, markRead, allRead, clear] as [NSView] {
            let frame = control.convert(control.bounds, to: content.view)
            try check(
                !control.isHidden && frame.width > 0 && frame.height > 0 && bounds.contains(frame),
                "native control remains visible inside the panel: \(control.identifier?.rawValue ?? "unknown")")
        }
        filter.selectedSegment = TerminalNotificationHistoryStore.Filter.failed.rawValue
        NSApp.sendAction(filter.action!, to: filter.target, from: filter)
        try check(
            content.table.numberOfRows == history.filtered(.failed).count && content.table.numberOfRows >= 2,
            "native panel filters failed notifications")
        panel.contentView?.layoutSubtreeIfNeeded()
        if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("panel.png"))
        }
        let originalRow = history.filtered(.failed).firstIndex { $0.id == record.id }!
        content.table.selectRowIndexes(IndexSet(integer: originalRow), byExtendingSelection: false)
        try check(!remove.isHidden, "remove appears once a notification is selected")
        let originalFrame = panel.frame
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            pump(0.05)
            panel.setContentSize(NSSize(width: 680, height: 420))
            content.view.layoutSubtreeIfNeeded()
            for control in [filter, showPane, markRead, allRead, remove, clear] as [NSView] {
                let frame = control.convert(control.bounds, to: content.view)
                guard frame.width > 0 && content.view.bounds.insetBy(dx: -1, dy: -1).contains(frame) else {
                    throw NSError(
                        domain: "NotificationSurface", code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Minimum-size panel clips \(language.rawValue) control: \(control.identifier?.rawValue ?? "unknown")"
                        ])
                }
            }
        }
        try check(true, "minimum-size notification panel fits all controls in 17 languages")
        AppLocalization.apply(.english)
        pump(0.05)
        panel.setFrame(originalFrame, display: false)
        markRead.performClick(nil)
        try wait("mark read did not update the selected record") { history.record(id: record.id)?.isRead == true }
        try check(history.record(id: record.id)?.isRead == true, "native mark-read action updates the selected record")
        allRead.performClick(nil)
        try wait("mark all read did not update history") { history.filtered(.unread).isEmpty }
        try check(history.filtered(.unread).isEmpty, "native mark-all-read action updates history")
        guard let removable = history.filtered(.failed).first(where: { $0.id != record.id }) else { preconditionFailure() }
        let removeRow = history.filtered(.failed).firstIndex { $0.id == removable.id }!
        content.table.selectRowIndexes(IndexSet(integer: removeRow), byExtendingSelection: false)
        remove.performClick(nil)
        try wait("remove did not delete the selected record") {
            history.record(id: removable.id) == nil && content.table.numberOfRows == history.filtered(.failed).count
        }
        try check(history.record(id: removable.id) == nil, "native remove action deletes the selected record")
        let otherProject = first.newProject()
        try check(first.selectedProjectID == otherProject.id, "fixture switched to another project")
        let row = history.filtered(.failed).firstIndex { $0.id == record.id }!
        content.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        NSApp.sendAction(content.table.action!, to: content.table.target, from: content.table)
        try check(
            first.selectedProjectID == project1.id
                && project1.selectedTab?.paneID(forContent: session1.id) == project1.selectedTab?.focusedPaneID,
            "clicking a row reveals the originating window, project, tab and pane")
        let latestTarget = history.record(id: record.id)!.target
        session1.terminate()
        try wait("closed terminal did not finish teardown") { session1.hasExited }
        try check(!TerminalManager.notificationAvailable(for: latestTarget), "closed pane remains unavailable")

        let overlay = GlobalTerminalOverlay.shared
        overlay.toggle()
        guard let quick = overlay.workspace, let quickSession = quick.sessions.first else { preconditionFailure() }
        try wait("Quick Terminal process did not launch") { quickSession.shellPid != nil }
        quickSession.terminalDidRequestDesktopNotification(title: "Fixture", body: "Quick notice")
        guard let quickRecord = history.records.first(where: { $0.message == "Quick notice" }) else { preconditionFailure() }
        try check(
            quickRecord.target.terminalID == quickSession.id && quickRecord.target.projectName != nil,
            "Quick Terminal notifications retain their target")
        overlay.toggle()
        try check(
            service.open(id: quickRecord.id) && overlay.workspace === quick
                && quick.focusedPaneID == quick.paneID(forContent: quickSession.id),
            "opening a notification restores and focuses the hidden Quick Terminal")
        controller.show()
        pump(0.1)
        clear.performClick(nil)
        try wait("clear history action did not remove all records") { history.records.isEmpty }
        try check(history.records.isEmpty, "native clear-history action removes all records")

        project2.customName = "Policy fixture"
        let sidebar = ProjectSidebarNSView(manager: second, tabDrag: TabSplitDragCoordinator(), bottomBarHeight: 32)
        sidebar.frame = NSRect(x: 0, y: 0, width: 180, height: 520)
        windows[1].contentView?.addSubview(sidebar)
        sidebar.refresh()
        sidebar.layoutSubtreeIfNeeded()
        guard
            let projectRow = descendants(sidebar).compactMap({ $0 as? WorkspaceItemView }).first(where: {
                ($0.accessibilityLabel() ?? "").hasPrefix("Policy fixture")
            })
        else { preconditionFailure("Project sidebar row is missing") }
        func choose(_ title: String) throws {
            for item in projectRow.menuItems?() ?? [] {
                if case .action(let label, let enabled, let handler) = item, label == title, enabled {
                    handler(); sidebar.refresh(); sidebar.layoutSubtreeIfNeeded(); return
                }
            }
            throw NSError(domain: "NotificationSurface", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing project action: \(title)"])
        }
        try choose(String(localized: "Mute Notifications"))
        try check(project2.notificationsMuted, "native project menu mutes its own project")
        try check(
            (projectRow.accessibilityValue() as? String)?.contains(String(localized: "Notifications Muted")) == true
                && projectRow.toolTip?.contains(String(localized: "Notifications Muted")) == true,
            "muted project exposes its state to accessibility and its tooltip")
        let images = descendants(projectRow).compactMap { $0 as? NSImageView }
        try check(images.contains { !$0.isHidden && $0.image != nil }, "muted project keeps a visible state icon at minimum sidebar width")
        try choose(String(localized: "Unmute Notifications"))
        try check(
            !project2.notificationsMuted
                && (projectRow.accessibilityValue() as? String)?.contains(String(localized: "Notifications Muted")) != true
                && projectRow.toolTip?.contains(String(localized: "Notifications Muted")) != true,
            "unmuting resets sidebar accessibility and tooltip state")

        delivery.allowsDelivery = true
        try choose(String(localized: "Mute Notifications"))
        send("printf '\\033]777;notify;Fixture;Muted PTY notice\\033\\\\'", to: session2)
        try wait("muted PTY notification did not reach history") { history.records.contains { $0.message == "Muted PTY notice" } }
        pump(0.1)
        try check(delivery.delivered.isEmpty, "real backend keeps muted terminal notifications in history without delivery")
        send("printf '\\a'", to: session2)
        try wait("muted PTY bell did not reach history") { history.records.contains { $0.kind == .bell } }
        try check(delivery.delivered.isEmpty, "real backend records muted bells without delivery")
        pump(1.3)
        send("false", to: session2)
        try wait("muted command failure did not reach history") {
            history.records.contains { $0.kind == .command && $0.isFailure && $0.message.hasPrefix("false failed") }
        }
        try check(delivery.delivered.isEmpty, "real command failures remain in muted project history")
        try wait("muted project original zsh can arm a reminder") { session2.canNotifyWhenNextCommandFinishes }
        let countBeforeReminder = history.records.count
        try check(session2.armNextCommandNotification(), "project mute keeps the one-shot reminder available")
        send("true", to: session2)
        try wait("muted one-shot reminder did not finish in history") {
            history.records.count == countBeforeReminder + 1 && session2.nextCommandNotification == nil
        }
        try check(
            history.records.first?.kind == .command && history.records.first?.target.projectID == project2.id
                && delivery.delivered.isEmpty,
            "muted one-shot reminder records exactly one command result without delivery")
        AgentAutomationMonitor.shared.unregister(session2)
        session2.agentStatus = ZshellAgentStatus(
            alias: "Policy Agent", kind: .codex, phase: .blocked, authority: .integration, reason: "fixture",
            updatedAt: Date(), processID: nil, unseen: false, progress: nil, attention: .approval, tasks: [])
        try wait("muted project approval did not deliver") { delivery.delivered.contains { $0.isPending } }
        try check(
            history.filtered(.pending).count == 1 && delivery.delivered.last?.target.projectID == project2.id,
            "muted project approval retains its project routing and macOS delivery candidate")
        session2.agentStatus = nil

        try choose(String(localized: "Unmute Notifications"))
        let destination = first.newProject()
        destination.notificationsMuted = true
        delivery.defersSettings = true
        service.post(message: "Before cross-window move", sessionID: session2.id)
        let tab = project2.selectedTab!
        let moved = second.moveTab(id: tab.id, from: project2.id, to: destination.id, in: ObjectIdentifier(first))
        try check(
            moved.succeeded && destination.sessions.contains { $0 === session2 }, "tab transfer keeps the real session across windows")
        delivery.finishSettings()
        pump(0.1)
        try check(delivery.delivered.count == 1, "queued delivery uses the muted destination project after transfer")
        destination.notificationsMuted = false
        service.post(message: "New owner", sessionID: session2.id)
        delivery.finishSettings()
        try wait("unmuted destination notification did not deliver") { delivery.delivered.count == 2 }
        try check(delivery.delivered.last?.target.projectID == destination.id, "new notifications resolve the transferred project's UUID")

        service.post(message: "Before project closes", sessionID: session2.id)
        first.close(destination)
        delivery.finishSettings()
        pump(0.1)
        try check(
            delivery.delivered.count == 2 && history.records.contains { $0.message == "Before project closes" },
            "closing a real project drops queued delivery and preserves notification history")
        project2.notificationsMuted = true
        pump(0.6)
        let saved = SessionStore.load().flatMap(\.projects).first { $0.customName == "Policy fixture" }
        try check(saved?.notificationsMuted == true, "project mute autosaves in the existing window snapshot")
        first.windowClosed()
        second.windowClosed()
        let restoredManager = TerminalManager()
        defer { restoredManager.windowClosed() }
        guard let restoredProject = restoredManager.projects.first(where: { $0.customName == "Policy fixture" }) else {
            preconditionFailure("Muted project did not restore")
        }
        try check(
            restoredProject.notificationsMuted && restoredProject.id != project2.id
                && restoredProject.conversationHistoryProjectID == project2.conversationHistoryProjectID,
            "reopening the saved workspace restores mute using the existing persistent identity")
        restoredManager.close(restoredProject)
        pump(0.6)
        try check(
            !SessionStore.load().flatMap(\.projects).contains { $0.customName == "Policy fixture" },
            "explicit project close removes its saved mute policy")
        try check(QuickTerminalOffscreen.isSafe(), "fixture windows remain offscreen and do not take focus")
    }
}
