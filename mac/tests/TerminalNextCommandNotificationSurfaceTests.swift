import AppKit
import UserNotifications
@testable import zshell

private enum NextCommandFailure: Error { case failed(String) }

@MainActor
private final class NextCommandApplication: NSApplication {
    weak var fixtureWindow: NSWindow?
    override var keyWindow: NSWindow? { fixtureWindow ?? super.keyWindow }
}

@MainActor
private final class NextCommandDelivery: TerminalNotificationDelivery {
    var delivered: [TerminalNotificationRecord] = []
    var removed: [UUID] = []
    func configure(delegate: any UNUserNotificationCenterDelegate) {}
    func settings(_ completion: @escaping @Sendable (TerminalNotificationAuthorization) -> Void) {
        completion(.init(status: .allowed))
    }
    func authorize(_ completion: @escaping @Sendable (Bool) -> Void) { preconditionFailure("No permission sheet in fixtures") }
    func deliver(_ record: TerminalNotificationRecord) { delivered.append(record) }
    func remove(ids: [UUID]) { removed += ids }
}

@main
@MainActor
struct TerminalNextCommandNotificationSurfaceTests {
    private static var backend = ""
    private static var checks = 0

    static func main() {
        do { try run() } catch { fputs("Next command surface failed: \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        setbuf(stdout, nil)
        let app = NextCommandApplication.shared as! NextCommandApplication
        let gui = CommandLine.arguments.contains("--gui")
        let previousApplication = NSWorkspace.shared.frontmostApplication
        if gui {
            NSApp.setActivationPolicy(.regular)
            NSApp.finishLaunching()
        } else {
            NSApp.setActivationPolicy(.prohibited)
            QuickTerminalOffscreen.install()
        }
        defer {
            if gui, let previousApplication, previousApplication.processIdentifier != getpid() { previousApplication.activate(options: []) }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        backend = CommandLine.arguments[2]
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard ["/tmp/zshell-next-command-surfaces-", "/private/tmp/zshell-next-command-surfaces-"].contains(where: home.path.hasPrefix)
        else {
            throw NextCommandFailure.failed("surface tests require disposable HOME")
        }
        let settings = AppSettings.shared
        settings.language = .english
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.terminalStartupProgram = ""
        settings.restoreTerminalHistory = false
        settings.preserveTerminalSessions = false
        settings.browserAccessEnabled = false
        settings.resumeAgentConversations = false
        settings.promptQueueAutoDispatch = false
        settings.notifyFinishSeconds = 0
        settings.notifyOnError = false
        let history = TerminalNotificationHistoryStore(url: root.appendingPathComponent("records.json"))
        let delivery = NextCommandDelivery()
        let service = TerminalNotificationService(history: history, delivery: delivery)
        TerminalNotificationService.shared = service
        service.configure()
        try wait("notification history loads") { !history.isLoading }
        AppMenuController.shared.install()
        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let project = Project(fallbackName: "Next command fixture", manager: manager, createInitialSession: false)
        project.customDirectory = root.path
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        guard let session = project.newSession(directory: root.path) else { throw NextCommandFailure.failed("fixture session missing") }
        let surface = session.surface
        let header = PaneHeaderNSView(frame: .zero)
        header.configure(
            content: .session(session), isFocused: true, allowsMove: false, focus: {}, onMove: { _ in }, onMoveEnded: {},
            onSplit: { _ in }, onClose: {})
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 530))
        header.frame = NSRect(x: 0, y: 500, width: 900, height: 30)
        surface.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        container.addSubview(surface)
        container.addSubview(header)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        manager.attach(to: window)
        surface.onBecomeFirstResponder = { [weak session] in session?.terminalDidBecomeFocused() }
        window.makeKeyAndOrderFront(nil)
        if gui {
            NSApp.activate(ignoringOtherApps: true)
            try wait("native fixture receives menu focus") { NSApp.keyWindow === window }
        } else {
            app.fixtureWindow = window
        }
        window.makeFirstResponder(surface)
        surface.setSurfaceVisible(true)
        defer {
            manager.windowClosed()
            pump(0.3)
            window.contentView = nil
            window.close()
            app.fixtureWindow = nil
        }
        try wait("original shell reaches empty prompt") { session.terminalPromptQueueIsReady && session.canNotifyWhenNextCommandFinishes }
        func contextItem(_ terminal: TerminalSession = session) throws -> NSMenuItem {
            guard
                let item = TerminalContextMenu.make(for: terminal.surface, linkTarget: nil).items.first(where: {
                    $0.identifier?.rawValue == "terminal-next-command-notification"
                })
            else { throw NextCommandFailure.failed("context menu item missing") }
            return item
        }
        func invoke(_ item: NSMenuItem) throws {
            guard let action = item.action else { throw NextCommandFailure.failed("menu action missing") }
            try check(NSApp.sendAction(action, to: item.target, from: item), "native menu action dispatches")
        }
        func run(_ command: String, in terminal: TerminalSession = session) throws {
            try wait("empty prompt accepts command") { terminal.terminalPromptQueueIsReady }
            let sequence = terminal.commandLifecycle.completionSequence
            try check(terminal.sendCommand(command) && terminal.sendEnter(), "real PTY accepts command")
            try wait("command returns to original empty prompt") {
                terminal.commandLifecycle.completionSequence > sequence && terminal.terminalPromptQueueIsReady
            }
        }
        let controller = TerminalNextCommandNotificationController.shared
        let menuItem = try contextItem()
        try check(menuItem.isEnabled && menuItem.state == .off, "context menu exposes available one-shot reminder")
        try invoke(menuItem)
        try check(session.nextCommandNotification != nil && menuItem.state == .on, "menu arms the exact pane and exposes cancel")
        pump(0.1)
        header.layoutSubtreeIfNeeded()
        guard
            let indicator = descendants(header).first(where: { $0.identifier?.rawValue == "terminal-next-command-notification-indicator" })
        else {
            throw NextCommandFailure.failed("header notification state missing")
        }
        try check(
            !indicator.isHidden && indicator.frame.width > 0 && indicator.toolTip?.isEmpty == false, "armed header exposes icon and tooltip"
        )
        let before = history.records.count
        try run("true")
        try wait("short successful command delivers once without automatic settings") {
            history.records.count == before + 1 && session.nextCommandNotification == nil && delivery.delivered.count == 1
        }
        guard let record = history.records.first else { throw NextCommandFailure.failed("command notification missing") }
        try check(
            record.kind == .command && !record.isFailure && record.target.terminalID == session.id && record.target.projectID == project.id,
            "explicit completion shares notification history and source routing")
        try run("false")
        pump(0.2)
        try check(history.records.count == before + 1, "following command cannot consume the finished one-shot reminder")
        try invoke(try contextItem())
        try invoke(try contextItem())
        try run("true")
        try check(history.records.count == before + 1, "cancelled reminder does not deliver")

        try invoke(try contextItem())
        let running = root.appendingPathComponent("running")
        try check(
            session.sendCommand("printf running > " + TerminalSession.shellQuote(running.path) + "; sleep 0.6") && session.sendEnter(),
            "armed command starts")
        try wait("armed command runs") { FileManager.default.fileExists(atPath: running.path) }
        try invoke(try contextItem())
        try wait("cancelled running command returns") { session.terminalPromptQueueIsReady }
        pump(0.2)
        try check(history.records.count == before + 1, "execution-stage cancel suppresses explicit completion")

        try? FileManager.default.removeItem(at: running)
        try check(
            session.sendCommand("printf running > " + TerminalSession.shellQuote(running.path) + "; sleep 0.6") && session.sendEnter(),
            "current command starts before arm")
        try wait("current command is running") { FileManager.default.fileExists(atPath: running.path) }
        try invoke(try contextItem())
        try wait("current command returns without consuming reminder") { session.terminalPromptQueueIsReady }
        try check(session.nextCommandNotification != nil && history.records.count == before + 1, "busy arm waits for the next command")
        try run("false")
        try wait("next command failure consumes reminder") { session.nextCommandNotification == nil && history.records.count == before + 2 }
        try check(
            history.records.first?.isFailure == true && history.filtered(.failed).count == 1, "real nonzero status reaches failed history")

        try invoke(try contextItem())
        surface.isReadOnly = true
        let cancelReadOnly = try contextItem()
        try check(cancelReadOnly.isEnabled && cancelReadOnly.state == .on, "read-only pane keeps cancellation available")
        try invoke(cancelReadOnly)
        try invoke(try contextItem())
        try check(session.nextCommandNotification != nil, "read-only pane allows host-side arming")
        surface.isReadOnly = false
        try run("true")
        try wait("read-only reminder follows the same root command") {
            session.nextCommandNotification == nil && history.records.count == before + 3
        }

        try check(session.armNextCommandNotification(), "reminder arms for late-result cancellation")
        session.observeNextCommandNotification()
        session.cancelNextCommandNotification()
        try check(session.armNextCommandNotification(), "new reminder supersedes a cancelled background read")
        let replacementRequest = session.nextCommandNotification!.request.id
        pump(0.2)
        try check(session.nextCommandNotification?.request.id == replacementRequest, "late read cannot clear a newly armed reminder")
        session.cancelNextCommandNotification()

        let nested = root.appendingPathComponent("nested")
        try check(
            session.sendCommand("printf nested > " + TerminalSession.shellQuote(nested.path) + "; zsh -di") && session.sendEnter(),
            "nested shell starts")
        try wait("nested shell owns current command") { FileManager.default.fileExists(atPath: nested.path) }
        pump(0.2)
        try invoke(try contextItem())
        try check(session.sendCommand("false") && session.sendEnter(), "nested shell command runs")
        pump(0.2)
        try check(
            session.nextCommandNotification != nil && history.records.count == before + 3, "nested completion leaves root reminder armed")
        try check(session.sendCommand("exit") && session.sendEnter(), "nested shell exits")
        try wait("original root prompt resumes") { session.terminalPromptQueueIsReady }
        try check(session.nextCommandNotification != nil, "return from current nested shell does not consume next root reminder")
        try run("true")
        try wait("following original command consumes nested-stage arm") {
            session.nextCommandNotification == nil && history.records.count == before + 4
        }

        try invoke(try contextItem())
        let request = session.nextCommandNotification!.request
        session.terminalDidRequestDesktopNotification(
            title: "zshell-command:\(request.integrationID):999:0", body: "Synthetic terminal message")
        try check(session.nextCommandNotification?.request.id == request.id, "desktop notification title cannot consume a reminder")
        service.clear()
        try check(
            session.sendCommand("true") && session.sendEnter() && session.sendCommand("false") && session.sendEnter(),
            "rapid root commands enter one PTY burst")
        try wait("rapid commands retain one immutable reminder result") {
            session.nextCommandNotification == nil && history.records.count == 1
        }
        try check(history.records.first?.isFailure == false, "rapid later failure cannot overwrite earlier success")

        settings.notifyOnError = true
        guard let automaticSession = project.newSession(directory: root.path) else {
            throw NextCommandFailure.failed("automatic fixture missing")
        }
        let inactiveWindow = QuickTerminalFocusFixtureWindow(
            contentRect: NSRect(origin: QuickTerminalOffscreen.origin, size: NSSize(width: 700, height: 400)),
            styleMask: [.titled], backing: .buffered, defer: false)
        inactiveWindow.isReleasedWhenClosed = false
        inactiveWindow.ignoresMouseEvents = true
        inactiveWindow.contentView = automaticSession.surface
        automaticSession.surface.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        inactiveWindow.orderFront(nil)
        automaticSession.surface.setSurfaceVisible(true)
        defer { inactiveWindow.contentView = nil; inactiveWindow.close() }
        try wait("inactive pane shell is ready") {
            automaticSession.terminalPromptQueueIsReady && automaticSession.canNotifyWhenNextCommandFinishes
        }
        try check(automaticSession.armNextCommandNotification(), "inactive pane arms explicitly")
        let duplicatesBefore = history.records.count
        try run("false", in: automaticSession)
        try wait("automatic and one-shot completion share one record") {
            automaticSession.nextCommandNotification == nil && history.records.count == duplicatesBefore + 1
        }
        pump(1.3)
        try check(
            history.records.count == duplicatesBefore + 1 && history.records.first?.isFailure == true,
            "automatic OSC and private result do not duplicate")

        let terminalMenu = AppMenuController.submenu(.terminal, in: NSApp.mainMenu!)!
        guard let mainItem = terminalMenu.items.first(where: { $0.identifier?.rawValue == "terminal-next-command-notification" }) else {
            throw NextCommandFailure.failed("Terminal menu reminder missing")
        }
        project.selectedTabID = project.tabs.first { $0.sessions.contains(where: { $0 === session }) }?.id
        if gui {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try wait("native Terminal menu regains current window focus") { NSApp.keyWindow === window }
        }
        window.makeFirstResponder(surface)
        controller.refresh(mainItem)
        try check(mainItem.isEnabled && mainItem.state == .off, "Terminal menu targets current terminal")
        try invoke(mainItem)
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            if gui {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try wait("localized menu restores native focus in \(language.rawValue)") { NSApp.keyWindow === window }
                window.makeFirstResponder(surface)
            }
            AppMenuController.shared.refresh()
            controller.refresh(mainItem)
            pump(0.05)
            header.frame.size.width = 120
            header.layoutSubtreeIfNeeded()
            try check(
                !mainItem.title.isEmpty && mainItem.state == .on && !indicator.isHidden,
                "armed state remains available in \(language.rawValue)")
        }
        AppLocalization.apply(.english)
        try invoke(mainItem)
        let target = record.target
        try check(service.open(id: record.id) == false, "cleared record cannot navigate to a new pane")
        if let latest = history.records.first {
            try check(service.open(id: latest.id), "notification opens its exact inactive source pane")
            try check(
                history.record(id: latest.id)?.isRead == true && delivery.removed.contains(latest.id),
                "opening marks notification read and removes delivery")
        }
        try check(automaticSession.armNextCommandNotification(), "inactive reminder arms before application quit")
        automaticSession.prepareForApplicationQuit(preserve: true)
        try check(automaticSession.nextCommandNotification == nil, "application quit discards pending reminder")
        guard let replacementSession = project.newSession(directory: root.path) else {
            throw NextCommandFailure.failed("replacement fixture missing")
        }
        let replacementWindow = QuickTerminalFocusFixtureWindow(
            contentRect: NSRect(origin: QuickTerminalOffscreen.origin, size: NSSize(width: 700, height: 400)),
            styleMask: [.titled], backing: .buffered, defer: false)
        replacementWindow.isReleasedWhenClosed = false
        replacementWindow.ignoresMouseEvents = true
        replacementWindow.contentView = replacementSession.surface
        replacementSession.surface.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        replacementWindow.orderFront(nil)
        replacementSession.surface.setSurfaceVisible(true)
        defer { replacementWindow.contentView = nil; replacementWindow.close() }
        try wait("replacement fixture starts original shell") {
            replacementSession.canNotifyWhenNextCommandFinishes && replacementSession.terminalPromptQueueIsReady
        }
        try check(replacementSession.armNextCommandNotification(), "replacement fixture arms")
        try check(replacementSession.sendCommand("exec zsh -di") && replacementSession.sendEnter(), "root shell is replaced in real PTY")
        try wait("shell replacement cancels inherited reminder") { replacementSession.nextCommandNotification == nil }
        try check(!replacementSession.canNotifyWhenNextCommandFinishes, "replacement shell cannot reuse original readiness")
        try check(TerminalManager.notificationAvailable(for: target), "live origin remains available")
        window.makeFirstResponder(surface)
        try invoke(try contextItem())
        let staleItem = try contextItem()
        session.terminate()
        try check(session.nextCommandNotification == nil, "closing pane clears reminder synchronously")
        try wait("closed session completes teardown") { session.hasExited }
        controller.refresh(staleItem)
        try check(
            !staleItem.isEnabled && !TerminalManager.notificationAvailable(for: target),
            "stale menu and closed notification target stay unavailable")
        if !gui { try check(QuickTerminalOffscreen.isSafe(), "native fixture remains offscreen and preserves user focus") }
        print("PASS \(backend): \(checks) next-command surface checks")
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NextCommandFailure.failed(message) }
        checks += 1
        print("PASS \(backend) \(message)")
    }
    private static func wait(_ message: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { pump(0.02) }
        try check(condition(), message)
    }
    private static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }
}
