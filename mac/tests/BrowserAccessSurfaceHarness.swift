import AppKit
import Foundation
import Darwin
@testable import zshell

@MainActor
private final class BrowserAccessFixtureDelegate: NSObject, NSApplicationDelegate {
    private let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    private var workspace: ZshellWorkspaceWindowController?
    private var project: Project?
    private var previous: TerminalSession?
    private var first: TerminalSession?
    private var second: TerminalSession?
    private var timer: Timer?
    private var frames: [NSWindow] = []
    private var stateControllers: [BrowserAccessController] = []
    private var handledCommands = 0
    private var isCapabilityProbe: Bool { CommandLine.arguments[2] == "capability" }
    private var isVisibleProbe: Bool { CommandLine.arguments.contains("--visible") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLocalization.apply(.english)
        let settings = AppSettings.shared
        settings.terminalBackend = CommandLine.arguments[2] == "ghostty" ? .libghostty : .alacritty
        settings.quickTerminalEnabled = false
        settings.restoreTerminalHistory = false
        settings.preserveTerminalSessions = false
        settings.resumeAgentConversations = false
        settings.notifyOnError = false
        settings.notifyOnAgentAttention = false
        settings.notifyOnAgentCompletion = false
        settings.browserAccessInterface = "loopback"
        settings.browserAccessPort = Int(ProcessInfo.processInfo.environment["ZSHELL_BROWSER_PROBE_PORT"] ?? "") ?? 39443
        settings.browserAccessEnabled = false
        if isCapabilityProbe {
            BrowserAccessController.shared.start()
            settings.browserAccessEnabled = true
            startTimer()
            return
        }
        TerminalFont.registerBundledFonts()
        let workspace = ZshellWorkspaceWindowController(number: 1)
        self.workspace = workspace
        let manager = workspace.manager
        manager.projects.forEach { $0.terminateAll() }
        manager.projects.removeAll()
        let project = Project(fallbackName: "Browser fixture 中文", manager: manager, createInitialSession: false)
        project.customName = "Browser fixture 中文"
        self.project = project
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        previous = open()
        BrowserAccessController.shared.start()
        settings.browserAccessEnabled = true
        first = open()
        second = open()
        project.select(index: 1)
        for session in [first, second].compactMap({ $0 }) {
            let view = session.surface
            view.frame = NSRect(x: 0, y: 0, width: 760, height: 440)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.onBecomeFirstResponder = { [weak session] in session?.terminalDidBecomeFocused() }
            window.makeFirstResponder(view)
            view.setSurfaceVisible(true)
            frames.append(window)
        }
        workspace.window?.setContentSize(NSSize(width: 1000, height: 650))
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        first?.surface.setSurfaceVisible(true)
        if isVisibleProbe {
            workspace.window?.makeKeyAndOrderFront(nil)
            SettingsWindowController.shared.show(category: .browserAccess)
        }
        startTimer()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func open() -> TerminalSession? {
        project?.newSession(directory: root.path, commandArguments: ["/bin/zsh", "-f"],
            usesConfiguredStartupCommand: false, usesConfiguredInitializationCommand: false)
    }

    private func update() {
        let access = BrowserAccessController.shared
        let state: [String: Any] = [
            "url": access.localURL?.absoluteString ?? "", "remote": access.remoteURL?.absoluteString ?? "",
            "error": access.error ?? "", "enabled": AppSettings.shared.browserAccessEnabled,
            "pending": access.pending.map { ["id": $0.id.uuidString, "code": $0.code] },
            "clients": access.clients.map { $0.id.uuidString }, "first": first?.id.uuidString ?? "", "second": second?.id.uuidString ?? "",
            "previousPersistent": previous?.persistentSessionID?.uuidString ?? "", "preserve": AppSettings.shared.preserveTerminalSessions,
            "pid": first?.shellPid ?? 0, "text": first?.surface.readVisibleText(maxLines: 150, maxColumns: 512) ?? "",
            "handledCommands": handledCommands,
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: state) {
            try? bytes.write(to: root.appendingPathComponent("status.json"), options: .atomic)
        }
        let commandURL = root.appendingPathComponent("command")
        guard let command = try? String(contentsOf: commandURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: commandURL)
        switch command.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "approve": if let pending = access.pending.first { access.approve(pending.id) }
        case "revoke": access.revoke(nil)
        case "disable": AppSettings.shared.browserAccessEnabled = false
        case "enable": AppSettings.shared.browserAccessEnabled = true
        case "retry": access.retry()
        case "restart": access.stop(); access.start()
        case "state-race": verifyStateRace()
        case "clients-ui": verifyClientControls()
        case "close": if let second { project?.closeContent(.session(second)) }; second = nil
        case "sleep": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        case "wake": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        case "layout": verifyLayout()
        case "quit": NSApp.terminate(nil)
        default: break
        }
        handledCommands += 1
    }

    private func verifyLayout() {
        var results: [[String: Any]] = []
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            let pane = SettingsBrowserAccessPane()
            pane.setCategory(.browserAccess)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = pane
            for width in [480.0, 600, 900] {
                window.setContentSize(NSSize(width: width, height: 460))
                pane.view.layoutSubtreeIfNeeded()
                let labels = descendants(pane.view).compactMap { $0 as? NSTextField }
                    .filter { !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty }
                let invalid = labels.filter {
                    $0.frame.width <= 0 || $0.frame.height + 1 < $0.cell!.cellSize(forBounds:
                        NSRect(x: 0, y: 0, width: $0.frame.width, height: 10000)).height
                }
                results.append(["language": language.rawValue, "width": width, "invalid": invalid.map(\.stringValue)])
            }
            let actualNames = descendants(pane.view).compactMap { $0 as? NSPopUpButton }.flatMap(\.itemTitles)
            let prefix = String(localized: "LAN") + " · "
            let interfaceNames = BrowserAccessController.shared.interfaces.filter { !$0.isLoopback && !$0.isTailscale }
                .map { prefix + $0.name + " · " + $0.address }
            if !interfaceNames.allSatisfy(actualNames.contains), !results.isEmpty {
                results[results.count - 1]["invalid"] = ["Localized network name is missing"]
            }
            window.close()
        }
        if let bytes = try? JSONSerialization.data(withJSONObject: results) {
            try? bytes.write(to: root.appendingPathComponent("layout.json"), options: .atomic)
        }
        AppLocalization.apply(.english)
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants($0) }
    }

    private func verifyClientControls() {
        let pane = SettingsBrowserAccessPane()
        pane.setCategory(.browserAccess)
        let views = descendants(pane.view)
        let group = views.compactMap { $0 as? SettingsGroup }
            .first { $0.headerTitle == String(localized: "Authorized Clients") }
        let revoke = views.compactMap { $0 as? NSButton }
            .first { $0.title == String(localized: "Revoke All Clients") }
        let controls = ["groupVisible": group?.isHidden == false, "revokeEnabled": revoke?.isEnabled == true,
                        "savedNameVisible": views.compactMap { $0 as? NSTextField }.contains {
                            BrowserAccessController.shared.clients.map(\.name).contains($0.stringValue) && !$0.isHiddenOrHasHiddenAncestor
                        }]
        if let data = try? JSONSerialization.data(withJSONObject: controls) {
            try? data.write(to: root.appendingPathComponent("clients-ui.json"), options: .atomic)
        }
    }

    private func verifyStateRace() {
        Task { @MainActor in
            let state = root.appendingPathComponent("state-race", isDirectory: true)
            let file = state.appendingPathComponent("clients.json")
            var checks: [String: Bool] = [:]
            func waitForState(_ predicate: () -> Bool) async throws -> Bool {
                let deadline = Date().addingTimeInterval(5)
                while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
                return predicate()
            }
            let queue = DispatchQueue(label: "browser-probe.delayed-state")
            let gate = DispatchSemaphore(value: 0)
            let writeGate = DispatchSemaphore(value: 0)
            queue.async { _ = gate.wait(timeout: .now() + 3) }
            let controller = BrowserAccessController(directory: state, stateQueue: queue)
            stateControllers.append(controller)
            do {
                let authorization = try BrowserAccessAuthorization(directory: state)
                let pairing = try authorization.begin(name: "Saved offline", address: "127.0.0.1", origin: "http://127.0.0.1:39444")
                try authorization.approve(authorization.pairings[0].id)
                _ = authorization.status(ticket: pairing.ticket, address: "127.0.0.1", origin: "http://127.0.0.1:39444")
                controller.start()
                try await Task.sleep(for: .milliseconds(50))
                checks["readOffMain"] = controller.clients.isEmpty
                controller.revoke(nil)
                gate.signal()
                try await Task.sleep(for: .milliseconds(400))
                checks["oldReadCannotRestoreRevoke"] = controller.clients.isEmpty
                checks["offlineRevokePersisted"] = try JSONDecoder().decode([BrowserAccessClient].self, from: Data(contentsOf: file)).isEmpty
                controller.stop()

                let live = try BrowserAccessAuthorization(directory: state)
                let request = try live.begin(name: "Saved before enable", address: "127.0.0.1", origin: "http://127.0.0.1:39444")
                try live.approve(live.pairings[0].id)
                _ = live.status(ticket: request.ticket, address: "127.0.0.1", origin: "http://127.0.0.1:39444")
                controller.start()
                checks["disabledClientsLoaded"] = try await waitForState {
                    controller.clients.count == 1 && controller.localURL == nil
                }
                queue.async { _ = writeGate.wait(timeout: .now() + 3) }
                controller.revoke(nil)
                AppSettings.shared.browserAccessEnabled = true
                try await Task.sleep(for: .milliseconds(100))
                checks["enableWaitsForRevoke"] = controller.localURL == nil
                writeGate.signal()
                checks["enabledWithoutRevokedClient"] = try await waitForState {
                    controller.localURL != nil && controller.clients.isEmpty
                }
                if checks["enabledWithoutRevokedClient"] == false {
                    let details: [String: Any] = ["url": controller.localURL?.absoluteString ?? "",
                        "clients": controller.clients.map(\.name), "error": controller.error ?? "", "starting": controller.isStarting]
                    if let data = try? JSONSerialization.data(withJSONObject: details) {
                        try? data.write(to: root.appendingPathComponent("state-race-detail.json"), options: .atomic)
                    }
                }
                AppSettings.shared.browserAccessEnabled = false
                controller.stop()
                try await Task.sleep(for: .milliseconds(100))
                checks["stoppedStateStaysClosed"] = controller.localURL == nil && controller.clients.isEmpty
            } catch { checks[error.localizedDescription] = false }
            gate.signal()
            writeGate.signal()
            controller.stop()
            if let data = try? JSONSerialization.data(withJSONObject: checks) {
                try? data.write(to: root.appendingPathComponent("state-race.json"), options: .atomic)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        BrowserAccessController.shared.stop()
        stateControllers.forEach { $0.stop() }
        guard !isCapabilityProbe else { return }
        workspace?.manager.projects.forEach { $0.terminateAll() }
        frames.forEach { $0.contentView = nil }
        _ = try? PTYMuxCommandLine.exchange(method: "terminateAll")
        // Session termination is asynchronous in the daemon.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if (try? PTYMuxCommandLine.exchange(method: "shutdown")) != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

@main
struct BrowserAccessSurfaceHarness {
    @MainActor static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--visible") {
            application.setActivationPolicy(.regular)
        } else {
            application.setActivationPolicy(.prohibited)
            QuickTerminalOffscreen.install()
        }
        let delegate = BrowserAccessFixtureDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
