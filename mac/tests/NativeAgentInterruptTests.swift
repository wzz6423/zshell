import AppKit
import Darwin
import Foundation
@testable import zshell

@MainActor
private final class NativeInterruptApplication: NSApplication {
    var inputEvent: NSEvent?
    var fixtureActive = true
    override var currentEvent: NSEvent? { inputEvent ?? super.currentEvent }
    override var isActive: Bool { fixtureActive }
}

@MainActor
private final class NativeInterruptWindow: NSWindow {
    var fixtureKey = true
    override var isKeyWindow: Bool { fixtureKey }
}

@main
@MainActor
struct NativeAgentInterruptTests {
    static var checks = 0
    static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        if ZshellCommandLine.shouldRun { ZshellCommandLine.main() }
        setbuf(stdout, nil)
        do { try run() }
        catch { fputs("Native interrupt failed after \(checks): \(error)\n", stderr); exit(1) }
    }
    static func pump(_ duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }
    static func run() throws {
        let args = CommandLine.arguments
        let backend = args[1], provider = args[2]
        let root = URL(fileURLWithPath: args[3]).resolvingSymlinksInPath()
        let launch = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("launch.json")))
        let app = NativeInterruptApplication.shared as! NativeInterruptApplication
        app.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        AppSettings.shared.resumeAgentConversations = false
        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let project = Project(fallbackName: "Native interrupt fixture", manager: manager, createInitialSession: false)
        project.customDirectory = root.appendingPathComponent("project").path
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        let window = NativeInterruptWindow(contentRect: NSRect(x: -100000, y: -100000, width: 1050, height: 630),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        manager.attach(to: window)
        guard let session = project.newSession(commandArguments: launch,
            usesConfiguredStartupCommand: false, usesConfiguredInitializationCommand: false) else { throw NSError(domain: "new session", code: 1) }
        let view = session.surface
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 1050, height: 630)
        view.setSurfaceVisible(true)
        window.makeFirstResponder(view)
        QuickTerminalOffscreen.prepare(window)
        defer {
            if let owner = session.agentObservation.integrationOwner, owner.isAlive { kill(owner.pid, SIGTERM) }
            session.terminate()
            manager.windowClosed()
            pump(0.5)
            window.contentView = nil
            window.close()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: app)
            _ = try? PTYMuxCommandLine.exchange(method: "shutdown")
        }
        func text() -> String { session.automationVisibleText(maxLines: 40, maxColumns: 240) }
        func dump(_ label: String) {
            try? Data(text().utf8).write(to: root.appendingPathComponent("viewport-\(label).txt"))
            let line = "STATE \(label): phase=\(String(describing: session.agentStatus?.phase)) integration=\(String(describing: session.agentObservation.integrationPhase)) pending=\(session.agentObservation.pendingInterrupt != nil) interrupted=\(session.agentObservation.integrationInterrupted) owner=\(String(describing: session.agentObservation.integrationOwner?.pid)) foreground=\(String(describing: view.foregroundPid)) shell=\(String(describing: session.shellPid)) resume=\(session.agentResume?.sessionID ?? "none")"
            print(line)
            if let owner = session.agentObservation.integrationOwner?.pid, let foreground = view.foregroundPid {
                print("GROUP owner=\(getpgid(owner)) foreground=\(getpgid(foreground)) shell=\(session.shellPid.map { getpgid($0) } ?? -1)")
            }
        }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { dump("failed"); fputs("\(text())\n", stderr); throw NSError(domain: label, code: 1) }
            checks += 1
            print("PASS \(backend) \(provider): \(label)")
        }
        func wait(_ label: String, timeout: Double = 15, _ condition: () -> Bool) throws {
            let until = Date().addingTimeInterval(timeout)
            while !condition(), Date() < until { pump(0.02) }
            try check(condition(), label)
        }
        func events() -> [String] {
            guard let data = try? String(contentsOf: root.appendingPathComponent("hooks.jsonl"), encoding: .utf8) else { return [] }
            return data.split(separator: "\n").compactMap { line in
                guard let dict = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let event = dict["event"] as? [String: Any] else { return nil }
                return event["hook_event_name"] as? String
            }
        }
        func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], plain: String? = nil) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: plain ?? characters,
                isARepeat: false, keyCode: code)!
            app.inputEvent = event
            defer { app.inputEvent = nil }
            view.keyDown(with: event)
        }
        func review() -> AgentReviewTurn? { AgentTurnReviewStore.shared.records(in: project.customDirectory!).first { $0.sessionID == session.id } }
        func working(_ index: Int) throws {
            if provider == "claude" {
                session.sendCommand("Wait for the local API. Probe \(index).", asPaste: true)
                session.sendEnter()
            }
            try wait("official UserPromptSubmit reaches production lifecycle", timeout: 25) {
                events().filter { $0 == "UserPromptSubmit" }.count >= index
                    && session.agentObservation.integrationPhase == .working
                    && review()?.isActive == true
            }
            try wait("local streaming API holds the real provider", timeout: 15) {
                FileManager.default.fileExists(atPath: root.appendingPathComponent("stream-\(index)").path)
            }
            if provider == "claude" {
                try wait("real busy footer is interrupt evidence") {
                    ZshellAgentInterruptEvidence.isClaudeWorking(session.automationVisibleText(maxLines: 16, maxColumns: 240))
                }
            }
            try wait("turn review captured its before snapshot") { review()?.before != nil }
            dump("working-\(index)")
        }
        func settled(_ index: Int) throws {
            try wait("confirmed interrupt restores native idle", timeout: 12) {
                session.agentObservation.integrationPhase == .idle && session.agentObservation.pendingInterrupt == nil
                    && session.agentObservation.integrationInterrupted
            }
            try check(session.agentStatus?.phase == .idle && session.agentStatus?.unseen == false,
                "interrupt does not create unread done")
            try check(review()?.isActive == false && review()?.after == nil && review()?.failure != nil,
                "interrupted turn review aborts without a successful after snapshot")
            app.fixtureActive = false
            window.fixtureKey = false
            pump(1.3)
            try check(session.agentStatus?.phase == .idle && session.agentStatus?.unseen == false,
                "losing focus keeps the interrupted parent idle")
            app.fixtureActive = true
            window.fixtureKey = true
            dump("idle-\(index)")
        }
        let shellCommand = root.appendingPathComponent("shell-command")
        if FileManager.default.fileExists(atPath: shellCommand.path) {
            try wait("ordinary shell is ready") { session.shellPid != nil && text().contains("%") }
            let command = try String(contentsOf: shellCommand, encoding: .utf8)
            session.sendCommand(command)
            session.sendEnter()
        }
        try wait("official SessionStart binds real provider identity", timeout: 30) {
            session.agentResume != nil && session.agentObservation.integrationOwner?.isAlive == true
                && session.agentObservation.declaredKind?.rawValue == provider && events().contains("SessionStart")
        }
        try check(TerminalManager.automationFocusedSessionID == session.id, "complete production project is focused in the fixture")
        let identity = session.agentResume!
        if provider == "claude" {
            try wait("provider input is ready", timeout: 15) { text().contains("❯") }
            if !FileManager.default.fileExists(atPath: shellCommand.path), backend == "ghostty" {
                let owner = session.agentObservation.integrationOwner!
                try check(session.shellPid == owner.pid && view.foregroundPid != owner.pid
                    && view.foregroundPid == getpgid(owner.pid)
                    && view.foregroundPid.flatMap(ZshellAgentProcessIdentity.init(pid:)) == nil,
                    "direct Ghostty provider inherits an exited leader's foreground group")
            } else {
                try check(view.foregroundPid == session.agentObservation.integrationOwner?.pid,
                    "job-controlled native provider occupies the foreground group")
            }
        }
        try working(1)
        key("\u{1b}", code: 53)
        if provider == "claude" {
            try check(session.agentObservation.pendingInterrupt != nil, "physical Escape creates a bounded candidate")
        } else {
            try wait("official Codex Interrupt hook fires") { events().contains("Interrupt") }
        }
        try settled(1)
        try check(session.agentResume == identity, "Escape retains the provider conversation identity")
        if provider == "claude" {
            try check(!events().contains("Stop"), "real Claude does not emit Stop on Escape")
            try working(2)
            key("\u{3}", code: 8, flags: .control, plain: "c")
            try check(session.agentObservation.pendingInterrupt != nil, "physical Ctrl-C creates a bounded candidate")
            try settled(2)
            try check(!events().contains("Stop"), "real Claude does not emit Stop on Ctrl-C")
            try check(session.agentResume == identity, "Ctrl-C retains the provider conversation identity")
            func injectedHook(_ name: String, child: String? = nil) throws {
                let owner = session.agentObservation.integrationOwner!.pid
                var payload: [String: ZshellJSONValue] = ["hook_event_name": .string(name), "session_id": .string(identity.sessionID)]
                if let child { payload["agent_id"] = .string(child); payload["parent_session_id"] = .string(identity.sessionID) }
                let event = ZshellAgentLifecycleEvent.parse(provider: .claude, payload: payload)!
                try check(session.reportAutomationAgent(phase: event.phase, reason: event.reason, provider: .claude,
                    peerProcessID: owner, attention: event.attention, task: event.task, endsSession: event.endsSession,
                    interrupted: event.interrupted), "injected verified \(name) preserves real provider ownership")
            }
            try working(3)
            try injectedHook("SubagentStart", child: "retained-child")
            key("\u{1b}", code: 53)
            try check(session.agentObservation.pendingInterrupt != nil, "parent Escape starts while a child remains active")
            try wait("real parent settles without erasing its active child") {
                session.agentObservation.integrationPhase == .idle && session.agentObservation.pendingInterrupt == nil
                    && session.agentObservation.integrationInterrupted
            }
            try check(session.agentStatus?.phase == .working
                && session.agentObservation.integrationTasks.contains { $0.id == "retained-child" && $0.phase == .working },
                "real interrupt keeps active child working")
            try check(review()?.isActive == false && review()?.after == nil, "parent interrupt aborts review while retaining child")
            try injectedHook("SubagentStop", child: "retained-child")
            try wait("settled child exposes the interrupted parent's idle") { session.agentStatus?.phase == .idle }
            try working(4)
            key("\u{1b}", code: 53)
            try check(session.agentObservation.pendingInterrupt != nil, "another real Escape creates its own candidate")
            try injectedHook("PostToolUse")
            try check(session.agentObservation.pendingInterrupt == nil, "new native hook cancels real interrupt candidate")
            pump(1.2)
            try check(session.agentObservation.integrationPhase == .working, "cancelled real candidate cannot later settle")
            try working(5)
            key("\u{1b}", code: 53)
            try check(session.agentObservation.pendingInterrupt != nil, "exit scenario begins with a real bounded candidate")
            let exiting = session.agentObservation.integrationOwner!
            kill(exiting.pid, SIGKILL)
            try wait("owner exit clears native interrupt state", timeout: 10) {
                session.agentObservation.pendingInterrupt == nil && session.agentObservation.integrationOwner == nil
                    && session.agentStatus == nil
            }
            try check(review()?.isActive == false && review()?.after == nil, "owner exit aborts incomplete review")
        } else {
            try check(events().filter { $0 == "Interrupt" }.count == 1 && !events().contains("Stop"),
                "official Interrupt reaches the router without a Stop completion")
        }
        print("Offscreen frame=\(window.frame) frontmost=\(String(describing: NSWorkspace.shared.frontmostApplication?.processIdentifier)) self=\(getpid())")
        app.fixtureActive = false
        window.fixtureKey = false
        try check(QuickTerminalOffscreen.isSafe()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid()
            && NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) }, "real CLI validation never claims user focus")
        print("\(checks) native \(provider) \(backend) production checks passed")
    }
}
