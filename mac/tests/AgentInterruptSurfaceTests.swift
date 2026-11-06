import AppKit
import Darwin
import GhosttyTerminal
@testable import zshell

@MainActor
private final class InterruptTestApplication: NSApplication {
    var inputEvent: NSEvent?
    override var currentEvent: NSEvent? { inputEvent ?? super.currentEvent }
    override var isActive: Bool { true }
}

@MainActor
private final class InterruptTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@main
@MainActor
struct AgentInterruptSurfaceTests {
    static func main() {
        do { try run() }
        catch { fputs("Agent interrupt surfaces failed: \(error)\n", stderr); exit(1) }
    }

    private static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    private static func run() throws {
        setbuf(stdout, nil)
        let app = InterruptTestApplication.shared as! InterruptTestApplication
        app.setActivationPolicy(.prohibited)
        let backend = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let inheritsProcessGroup = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "inherited"
        let fixture = root.appendingPathComponent("claude.py")
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        let session = TerminalSession(initialDirectory: root.path,
            commandArguments: ["/usr/bin/python3", fixture.path, root.path], allowsPersistence: false)
        let view = session.surface
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let window = InterruptTestWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        window.contentView = view
        window.makeFirstResponder(view)
        view.setSurfaceVisible(true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("zshell-interrupt-\(UUID())"))
        defer {
            session.terminate()
            pump(0.3)
            window.contentView = nil
            pasteboard.releaseGlobally()
        }
        var checks = 0
        func text() -> String { session.automationVisibleText(maxLines: 16, maxColumns: 240) }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else {
                fputs("FAIL: \(backend) \(label)\n\(text())\n", stderr)
                throw NSError(domain: label, code: 1)
            }
            checks += 1
            print("PASS: \(backend) \(label)")
        }
        func wait(_ label: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(6)
            while !condition(), Date() < deadline { pump(0.02) }
            try check(condition(), label)
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
        try wait("real Claude fixture owns the foreground PTY") {
            session.surface.foregroundPid != nil && session.shellPid != nil
                && ZshellAgentKind.recognize(processID: session.shellPid!) == .claude
                && text().contains("❯ restored prompt")
        }
        let owner = session.shellPid!
        if inheritsProcessGroup {
            try check(session.surface.foregroundPid != owner && getpgid(owner) == session.surface.foregroundPid,
                      "direct Ghostty launch inherits its exited leader's foreground group")
            try check(ZshellAgentProcessIdentity(pid: session.surface.foregroundPid!) == nil,
                      "the inherited foreground leader is no longer a live owner")
        } else {
            try check(session.surface.foregroundPid == owner, "job-controlled provider owns its foreground group")
        }
        let identity = AgentConversationIdentity(provider: .claude, sessionID: UUID().uuidString,
                                                  workingDirectory: root.path)!
        try check(session.recordAgentConversation(identity, processID: owner), "provider conversation is retained")
        func hook(_ name: String, child: String? = nil) throws {
            var payload: [String: ZshellJSONValue] = ["hook_event_name": .string(name),
                                                      "session_id": .string(identity.sessionID)]
            if let child {
                payload["agent_id"] = .string(child)
                payload["parent_session_id"] = .string(identity.sessionID)
            }
            let event = ZshellAgentLifecycleEvent.parse(provider: .claude, payload: payload)!
            try check(session.reportAutomationAgent(phase: event.phase, reason: event.reason,
                provider: .claude, peerProcessID: owner, attention: event.attention, task: event.task,
                endsSession: event.endsSession, interrupted: event.interrupted), "verified native \(name) accepted")
        }
        func working(restore: Bool = true) throws {
            try hook("UserPromptSubmit")
            try JSONSerialization.data(withJSONObject: ["busy": true, "restore": restore])
                .write(to: root.appendingPathComponent("command.json"), options: .atomic)
            try wait("busy footer is live") { text().contains("esc to interrupt") }
        }
        func escape() throws {
            key("\u{1b}", code: 53)
            try check(session.agentObservation.pendingInterrupt != nil, "real Escape starts a guarded candidate")
        }
        func settled() throws {
            try wait("stable restored input settles the native parent") {
                session.agentObservation.integrationPhase == .idle
                    && session.agentObservation.pendingInterrupt == nil
            }
            try check(session.agentResume == identity, "interrupt keeps the same conversation")
            try check(session.agentStatus?.unseen == false, "interrupt creates no unread completion")
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as! [String: Any]
            try check(state["oscIdle"] as? Bool == true,
                      "provider OSC idle does not interfere with native confirmation")
        }
        func remainsWorking() throws {
            pump(1.7)
            try check(session.agentObservation.integrationPhase == .working, "cancelled candidate cannot settle later")
        }

        try hook("SessionStart")
        try working()
        try escape()
        try wait("provider restores its input without a Stop hook") { !text().contains("esc to interrupt") }
        let idleReport = try ZshellAgentReport(params: ["name": .string("claude-code"), "state": .string("idle")])
        try check(session.reportAutomationProgram(idleReport, ownerPID: owner, peerProcessID: owner),
                  "concurrent program idle uses verified process ownership")
        try check(session.reportAutomationProgram(idleReport, ownerPID: owner, peerProcessID: owner),
                  "an immediate program refresh remains accepted")
        try check(session.agentObservation.integrationPhase == .working,
                  "immediate program refreshes cannot satisfy the stable interval")
        try settled()
        try check(session.agentStatus?.phase == .idle, "Escape returns an interrupted parent to idle")
        try working()
        key("\u{3}", code: 8, flags: .control, plain: "c")
        try check(session.agentObservation.pendingInterrupt != nil, "real Ctrl-C starts a guarded candidate")
        try settled()
        try check(session.agentStatus?.phase == .idle, "Ctrl-C returns an interrupted parent to idle")
        let input = try Data(contentsOf: root.appendingPathComponent("input.bin"))
        try check(input.contains(0x1b) && input.contains(0x03), "both physical control keys reach the provider PTY")

        try hook("SubagentStart", child: "active-child")
        try working()
        try escape()
        try settled()
        try check(session.agentStatus?.phase == .working
            && session.agentObservation.integrationTasks.contains { $0.id == "active-child" && $0.phase == .working },
                  "an active child stays working after its parent is interrupted")
        try hook("SubagentStop", child: "active-child")

        try hook("PermissionRequest", child: "waiting-child")
        try working()
        key("\u{1b}", code: 53)
        try check(session.agentObservation.pendingInterrupt == nil, "a waiting child prevents parent interrupt inference")
        try hook("SubagentStop", child: "waiting-child")

        try working(restore: false)
        try escape()
        try JSONSerialization.data(withJSONObject: ["busy": true, "foregroundChild": true])
            .write(to: root.appendingPathComponent("command.json"), options: .atomic)
        try wait("a different live child becomes foreground") {
            session.surface.foregroundPid != owner
                && session.surface.foregroundPid.map { ZshellAgentProcessIdentity(pid: $0) != nil } == true
        }
        try wait("foreground ownership change cancels the candidate") { session.agentObservation.pendingInterrupt == nil }
        try check(session.agentObservation.integrationPhase == .working,
                  "a live foreground child cannot settle its parent's turn")
        key("\u{1b}", code: 53)
        try check(session.agentObservation.pendingInterrupt == nil, "a foreground child cannot start a parent candidate")
        try JSONSerialization.data(withJSONObject: ["busy": true, "foregroundChild": false])
            .write(to: root.appendingPathComponent("command.json"), options: .atomic)
        try wait("provider regains its foreground group") { session.surface.foregroundPid == getpgid(owner) }

        try working(restore: false)
        try escape()
        try remainsWorking()
        try check(session.agentObservation.pendingInterrupt != nil, "an unchanged busy footer is never enough")

        try working()
        try escape()
        key("x", code: 7)
        try check(session.agentObservation.pendingInterrupt == nil, "ordinary input cancels the candidate")
        try remainsWorking()

        try working()
        try escape()
        let inputClient = view as! NSTextInputClient
        inputClient.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(session.agentObservation.pendingInterrupt == nil, "IME composition cancels the candidate")
        key("\u{1b}", code: 53)
        try check(session.agentObservation.pendingInterrupt == nil, "Escape during IME never starts a candidate")
        inputClient.unmarkText()
        try remainsWorking()

        try working()
        try escape()
        pasteboard.clearContents()
        pasteboard.setString("pasted text", forType: .string)
        _ = session.terminalHandleUserPaste(pasteboard, paste: { view.sendPaste($0) })
        view.sendPaste("pasted text")
        try check(session.agentObservation.pendingInterrupt == nil, "user paste cancels the candidate")
        try remainsWorking()

        try working()
        try escape()
        session.sendCommand("new input")
        try check(session.agentObservation.pendingInterrupt == nil, "automation input cancels the candidate")
        try remainsWorking()

        try working()
        try escape()
        try hook("UserPromptSubmit")
        try check(session.agentObservation.pendingInterrupt == nil, "a newer native hook cancels the candidate")
        try remainsWorking()

        try working()
        try escape()
        let replacementIdentity = AgentConversationIdentity(provider: .claude, sessionID: UUID().uuidString,
                                                             workingDirectory: root.path)!
        try check(session.recordAgentConversation(replacementIdentity, processID: owner),
                  "the same process can bind a newer conversation")
        try wait("a conversation change cancels the candidate") { session.agentObservation.pendingInterrupt == nil }
        try remainsWorking()
        try check(session.recordAgentConversation(identity, processID: owner), "the fixture restores its original conversation")

        try working()
        session.terminalIsAtLiveBottom = false
        key("\u{1b}", code: 53)
        try check(session.agentObservation.pendingInterrupt == nil, "scrollback never becomes interrupt evidence")
        session.terminalIsAtLiveBottom = true

        try working(restore: false)
        try escape()
        Darwin.kill(owner, SIGTERM)
        try wait("exiting owner clears the pending candidate and native status") {
            session.agentObservation.pendingInterrupt == nil
                && session.agentObservation.integrationOwner == nil && session.agentStatus == nil
        }
        print("\(checks) local \(backend) Agent interrupt production checks passed")
    }
}
