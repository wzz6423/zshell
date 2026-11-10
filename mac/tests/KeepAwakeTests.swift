import AppKit
import IOKit.pwr_mgt
@testable import zshell

@main
@MainActor
struct KeepAwakeTests {
    private static var checks = 0
    private static var sessions: [TerminalSession] = []

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else {
            fputs("Keep-awake probe failed: \(message)\n", stderr)
            KeepAwakeController.shared.stop()
            sessions.forEach { $0.terminate() }
            TerminalManager.automationManagers.forEach { $0.projects.forEach { $0.terminateAll() } }
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            exit(1)
        }
    }

    private static func status(_ phase: ZshellAgentPhase, authority: ZshellAgentStateAuthority = .report) -> ZshellAgentStatus {
        .init(alias: "fixture", kind: .program, phase: phase, authority: authority,
              reason: "fixture", updatedAt: Date(), processID: nil, unseen: phase == .done,
              progress: nil, attention: nil, tasks: [])
    }

    private static func session(remote: RemoteSessionConnection? = nil, paste: RemotePasteTarget? = nil,
                                restoredID: UUID? = nil) -> TerminalSession {
        let value = TerminalSession(commandArguments: ["/bin/cat"], restoredSessionID: restoredID,
            allowsPersistence: false, remoteConnection: remote, remotePasteTarget: paste,
            usesConfiguredStartupCommand: false, usesConfiguredInitializationCommand: false)
        sessions.append(value)
        return value
    }

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppLocalization.apply(.english)
        setbuf(stdout, nil)
        let settings = AppSettings.shared
        check(AppSettings.configURL.path.hasPrefix(CommandLine.arguments[2]), "disposable configuration home")
        settings.terminalBackend = CommandLine.arguments[1] == "ghostty" ? .libghostty : .alacritty
        settings.terminalStartupProgram = "/bin/cat"
        settings.terminalStartupArguments = ""
        settings.preserveTerminalSessions = false
        settings.restoreTerminalHistory = false
        settings.keepAwakeMode = .off
        let controller = KeepAwakeController.shared
        controller.start()
        defer {
            controller.stop()
            sessions.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(3)
            while sessions.contains(where: { !$0.hasExited }), Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }
        check(!controller.isActive, "off holds no assertion")
        settings.keepAwakeMode = .whileAgentsWork
        check(!controller.isActive, "no local agents allows sleep")

        let firstManager = TerminalManager()
        let secondManager = TerminalManager()
        let first = Project(fallbackName: "First", manager: firstManager, createInitialSession: false)
        let background = Project(fallbackName: "Background", manager: firstManager, createInitialSession: false)
        let otherWindow = Project(fallbackName: "Other window", manager: secondManager, createInitialSession: false)
        firstManager.projects.append(contentsOf: [first, background])
        secondManager.projects.append(otherWindow)
        defer {
            for manager in [firstManager, secondManager] {
                manager.projects.forEach { $0.terminateAll() }
                manager.projects.removeAll()
            }
        }

        let lead = session()
        let working = session()
        let tab = PaneTab(content: .session(lead))
        let leadID = tab.focusedPaneID
        tab.split(Pane(content: .session(working)), toward: .right, beside: leadID, focusInserted: false)
        first.tabs = [tab]
        first.selectedTabID = tab.id
        firstManager.selectedProjectID = first.id
        lead.agentStatus = status(.blocked)
        working.agentStatus = status(.working)
        check(tab.agentRollup?.phase == .blocked && tab.focusedPaneID == leadID,
              "waiting pane takes rollup and focus ahead of working split")
        check(controller.isActive && controller.lastError == nil, "background split holds a real assertion")
        tab.toggleZoom()
        check(controller.isActive, "zoomed waiting pane does not hide working split from power policy")
        lead.agentStatus = status(.done)
        check(tab.agentRollup?.phase == .done && controller.isActive, "unread completion does not hide working split")
        working.agentStatus = status(.idle)
        check(!controller.isActive, "idle split releases immediately")
        for phase in [ZshellAgentPhase.blocked, .done, .created, .unknown] {
            working.agentStatus = status(phase)
            check(!controller.isActive, "non-working phase \(phase.rawValue) allows sleep")
        }
        for authority in [ZshellAgentStateAuthority.screen, .process] {
            working.agentStatus = status(.idle, authority: authority)
            check(!controller.isActive, "idle inference never implies work")
        }

        let otherProjectSession = session()
        background.tabs = [PaneTab(content: .session(otherProjectSession))]
        otherProjectSession.agentStatus = status(.working)
        check(controller.isActive && firstManager.selectedProjectID == first.id, "unselected project counts")
        otherProjectSession.agentStatus = status(.blocked)
        check(!controller.isActive, "last agent waiting releases")
        let otherWindowSession = session()
        otherWindow.tabs = [PaneTab(content: .session(otherWindowSession))]
        otherWindowSession.agentStatus = status(.working)
        check(controller.isActive, "other window counts without being active")
        let standalone = session()
        standalone.agentStatus = status(.working)
        otherWindowSession.agentStatus = status(.idle)
        check(controller.isActive, "standalone Quick Terminal-style session counts")
        standalone.terminate()
        check(!controller.isActive, "closing last working session releases before async teardown")

        let endpoint = try SSHEndpoint(host: "localhost")
        let ssh = session(paste: .ssh(endpoint: endpoint, authentication: .agent, credentialID: nil))
        ssh.agentStatus = status(.working)
        check(!controller.isActive, "legacy SSH agent does not prevent local sleep")
        let host = try RemoteHost(name: "Fixture", address: "tailscale://fixture.invalid:7373")
        let connection = try RemoteSessionConnection(host: host, directory: "/tmp", sessionID: UUID(),
            createIfMissing: false, command: nil, launchSettings: .init())
        defer { connection.stopMonitoring() }
        let remote = session(remote: connection)
        remote.agentStatus = status(.working)
        AgentAutomationMonitor.shared.register(remote)
        check(!AgentAutomationMonitor.shared.hasWorkingLocalAgent && !controller.isActive,
              "shared remote session remains excluded even if registered")

        let old = session()
        old.agentStatus = status(.working)
        check(controller.isActive, "old live session counts")
        let replacement = session(restoredID: old.id)
        check(!controller.isActive, "reconnected ID retires old renderer activity")
        old.terminate()
        replacement.agentStatus = status(.working)
        check(controller.isActive, "closing old renderer preserves replacement registration")
        replacement.hasExited = true
        check(!controller.isActive, "relay exit retires stale working state immediately")

        settings.keepAwakeMode = .whileRunning
        check(controller.isActive, "application mode holds with no working local agent")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(!controller.isActive, "system sleep notification releases")
        AgentAutomationMonitor.shared.agentActivityChanged()
        check(!controller.isActive, "refresh during system sleep cannot reacquire")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        check(controller.isActive, "wake reapplies selected mode")
        settings.keepAwakeMode = .off
        check(!controller.isActive, "off releases synchronously")
        settings.keepAwakeMode = .whileRunning
        controller.stop()
        check(!controller.isActive, "application exit releases")
        settings.keepAwakeMode = .whileAgentsWork
        check(!controller.isActive, "stopped controller no longer observes settings")

        try failureLifecycle()
        try systemAssertion()
        print("Keep-awake production probe: \(checks) checks passed (\(CommandLine.arguments[1]))")
    }

    private static func failureLifecycle() throws {
        let settings = AppSettings.shared
        settings.keepAwakeMode = .whileRunning
        var time = Date()
        var createCount = 0
        var releaseCount = 0
        var rejectCreate = true
        var rejectRelease = false
        let controller = KeepAwakeController(assertions: .init(create: {
            createCount += 1
            return (rejectCreate ? kIOReturnNotPermitted : kIOReturnSuccess, 42)
        }, release: { _ in
            releaseCount += 1
            return rejectRelease ? kIOReturnNotPermitted : kIOReturnSuccess
        }), now: { time })
        defer { controller.stop() }
        controller.start()
        check(!controller.isActive && controller.lastError == kIOReturnNotPermitted,
              "create failure never reports active")
        controller.localAgentActivityChanged(false)
        check(createCount == 1, "failure does not spin on unchanged activity")
        rejectCreate = false
        time.addTimeInterval(6)
        controller.localAgentActivityChanged(false)
        check(controller.isActive && controller.lastError == nil, "successful retry reports actual assertion")
        rejectRelease = true
        settings.keepAwakeMode = .off
        check(controller.isActive && controller.lastError == kIOReturnNotPermitted,
              "release failure keeps truthful active state")
        check(controller.statusDescription.contains("Could not stop"), "release failure describes remaining prevention")
        rejectRelease = false
        time.addTimeInterval(6)
        controller.localAgentActivityChanged(false)
        check(!controller.isActive && controller.lastError == nil && releaseCount == 2,
              "release retry clears assertion and error")

        settings.keepAwakeMode = .whileRunning
        var disposed = false
        var transient: KeepAwakeController? = KeepAwakeController(assertions: .init(
            create: { (kIOReturnSuccess, 43) }, release: { _ in disposed = true; return kIOReturnSuccess }))
        transient?.start()
        check(transient?.isActive == true, "transient controller holds")
        transient = nil
        check(disposed, "controller deinit releases and removes observations")
        settings.keepAwakeMode = .off
    }

    private static func systemAssertion() throws {
        let (result, id) = KeepAwakeController.Assertions.system.create()
        check(result == kIOReturnSuccess, "real IOKit assertion create")
        let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
        check(properties?[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep,
              "assertion prevents only user idle system sleep")
        check(properties?[kIOPMAssertionLevelKey] as? Int == kIOPMAssertionLevelOn, "assertion is enabled")
        check(KeepAwakeController.Assertions.system.release(id) == kIOReturnSuccess, "real assertion release")
        check(IOPMAssertionCopyProperties(id) == nil, "released assertion no longer exists")
    }
}
