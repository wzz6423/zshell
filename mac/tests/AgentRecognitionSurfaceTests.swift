import AppKit
import Darwin
import Foundation
@testable import zshell

@main
@MainActor
struct AgentRecognitionSurfaceTests {
    static var checks = 0
    static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        setbuf(stdout, nil)
        do { try run() }
        catch { fputs("Agent recognition surface failed after \(checks): \(error)\n", stderr); exit(1) }
    }

    static func pump(_ duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    static func run() throws {
        let backend = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        let settings = AppSettings.shared
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.terminalStartupProgram = ""
        settings.preserveTerminalSessions = false
        settings.restoreTerminalHistory = false
        settings.customAgentRecognitionRules = true
        settings.agentScreenInference = true
        settings.notifyOnAgentAttention = false
        settings.notifyOnAgentCompletion = false
        let rules = AgentRecognitionRulesStore.shared
        let frog = AgentRecognitionManifest(id: "frog", name: "原始工具名", executables: ["frog-cli"], rules: [
            .init(id: "approval", phase: .blocked, priority: 200, region: "bottom_non_empty_lines(6)", attention: .approval,
                  gate: .init(lineRegex: ["^Allow .+\\? \\[y/n\\]$"])),
            .init(id: "activity", phase: .working, priority: 100, gate: .init(contains: ["hopping…"])),
        ])
        let wrapper = AgentRecognitionManifest(id: "claude", name: "Native Wrapper", executables: [], aliases: ["claude-wrapper"], rules: frog.rules)
        let session = TerminalSession(initialDirectory: root.path, commandArguments: ["/bin/zsh", "-f"], allowsPersistence: false)
        let view = session.surface
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        QuickTerminalOffscreen.prepare(window)
        view.setSurfaceVisible(true)
        defer {
            session.terminate()
            pump(0.3)
            window.contentView = nil
            window.close()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: app)
        }
        func text() -> String { session.automationVisibleText(maxLines: 16, maxColumns: 240) }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else {
                fputs("FAIL \(backend): \(label)\nstatus=\(String(describing: session.agentStatus)) foreground=\(String(describing: view.foregroundPid)) shell=\(String(describing: session.shellPid))\n\(text())\n", stderr)
                throw NSError(domain: label, code: 1)
            }
            checks += 1
            print("PASS \(backend): \(label)")
        }
        func wait(_ label: String, timeout: Double = 8, _ condition: () -> Bool) throws {
            let until = Date().addingTimeInterval(timeout)
            while !condition(), Date() < until { pump(0.02) }
            try check(condition(), label)
        }
        func save(_ values: [AgentRecognitionManifest]) throws {
            var finished = false
            var error: String?
            rules.save(values) { error = $0; finished = true }
            try wait("valid rules save") { finished }
            try check(error == nil, "rules are written successfully")
        }
        func command(_ directory: URL, _ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        }
        func launch(_ name: String, folder: String) throws -> (URL, pid_t) {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            view.sendText("/usr/bin/python3 \(TerminalSession.shellQuote(root.appendingPathComponent(name + ".py").path)) \(TerminalSession.shellQuote(directory.path))")
            view.sendEnter()
            try wait("real \(name) owns foreground PTY") {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("pid.json")),
                      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
                      let pid = record["pid"] else { return false }
                return view.foregroundPid == pid_t(pid) && text().contains("hopping…")
            }
            let data = try Data(contentsOf: directory.appendingPathComponent("pid.json"))
            let record = try JSONSerialization.jsonObject(with: data) as! [String: Int]
            return (directory, pid_t(record["pid"]!))
        }
        try save([frog, wrapper])
        try wait("disposable interactive shell owns its PTY") { session.shellPid != nil && view.foregroundPid == session.shellPid }
        view.sendText("printf 'RECOGNITION_SHELL_READY\\n'")
        view.sendEnter()
        try wait("disposable interactive shell is ready") { session.automationVisibleText(maxLines: 500, maxColumns: 240).contains("RECOGNITION_SHELL_READY") }
        let (frogRoot, frogPID) = try launch("frog-cli", folder: "frog")
        try wait("custom ID and raw name reach process status") { session.agentStatus?.recognitionID == "frog" }
        try check(session.agentStatus?.kind == .program && session.agentStatus?.displayName == "原始工具名", "custom agents retain program kind and raw name")
        try wait("two live samples infer working") { session.agentStatus?.authority == .screen && session.agentStatus?.phase == .working }
        try check(session.agentObservation.screenEvidenceSamples == 2, "screen evidence requires two samples")
        settings.agentScreenInference = false
        try check(session.agentStatus?.authority == .process && session.agentStatus?.phase == .idle && session.agentObservation.screenEvidence == nil,
                  "screen switch immediately withdraws old screen authority")
        pump(0.3)
        try check(session.agentStatus?.recognitionID == "frog", "screen switch preserves custom process identity")
        settings.agentScreenInference = true
        try wait("screen inference resumes from fresh samples") { session.agentStatus?.authority == .screen }
        let priorSample = session.agentObservation.lastScreenCheck
        try wait("screen sampling continues after publishing a state") { session.agentObservation.lastScreenCheck > priorSample }
        try command(frogRoot, ["lines": ["Allow sampling check? [y/n]"]])
        try wait("new footer starts a first matching sample") {
            session.agentObservation.screenEvidence?.phase == .blocked && session.agentObservation.screenEvidenceSamples == 1
        }
        try check(session.agentStatus?.authority != .screen && session.agentStatus?.phase != .blocked,
                  "one matching sample cannot publish a new inferred state")
        try wait("second matching sample publishes the changed state") {
            session.agentStatus?.phase == .blocked && session.agentObservation.screenEvidenceSamples == 2
        }
        session.agentObservation.isCollectingAlternateScreenHistory = true
        try wait("transcript collection cannot infer a screen state") { session.agentStatus?.authority == .process && session.agentObservation.screenEvidence == nil }
        session.agentObservation.isCollectingAlternateScreenHistory = false
        try command(frogRoot, ["alternate": false, "history": true, "lines": ["clean live footer"]])
        try wait("clean footer replaces working marker") { text().contains("clean live footer") }
        try wait("old working scrollback does not become live evidence") { session.agentStatus?.authority == .process && session.agentStatus?.phase == .idle }
        view.scroll(toFraction: 0)
        try wait("both backends expose history inspection") { !session.terminalIsAtLiveBottom }
        pump(1.6)
        try check(session.agentStatus?.authority != .screen && session.agentObservation.screenEvidence == nil, "history viewport cannot infer stale working text")
        view.scroll(toFraction: 1)
        try wait("viewport returns to live bottom") { session.terminalIsAtLiveBottom }
        try command(frogRoot, ["lines": ["Allow update? [y/n]"]])
        try wait("custom approval rule infers blocked") { session.agentStatus?.phase == .blocked && session.agentStatus?.attention == .approval }
        let revision = rules.revision
        try "[[agents]]\nid = 42".write(to: rules.url, atomically: true, encoding: .utf8)
        try wait("invalid live TOML reports an error") { rules.error != nil }
        try check(rules.revision == revision && rules.manifests == [frog, wrapper], "invalid edits retain the last valid rules")
        try Data([0xff, 0xfe]).write(to: rules.url, options: .atomic)
        pump(0.8)
        try check(rules.revision == revision && rules.manifests == [frog, wrapper], "invalid UTF8 cannot replace valid rules")
        try save([frog, wrapper])
        try FileManager.default.removeItem(at: rules.url)
        try wait("deleting agents.toml restores built-ins") { rules.manifests.isEmpty && rules.error == nil }
        try wait("deleted custom tool disappears from running status") { session.agentStatus == nil }
        try save([frog, wrapper])
        try wait("custom rules can be restored live") { session.agentStatus?.recognitionID == "frog" }
        settings.customAgentRecognitionRules = false
        try check(session.agentStatus == nil && session.agentObservation.screenEvidence == nil, "custom switch immediately withdraws custom process and screen identity")
        settings.customAgentRecognitionRules = true
        try wait("custom switch re-enables recognition") { session.agentStatus?.recognitionID == "frog" }
        let program = try ZshellAgentReport(params: ["name": .string("Verified Frog"), "state": .string("working")])
        try check(session.reportAutomationProgram(program, ownerPID: frogPID, peerProcessID: frogPID),
                  "verified custom process accepts its own program report")
        try check(session.agentStatus?.authority == .report && session.agentStatus?.displayName == "Verified Frog",
                  "program report takes priority and displays its raw name")
        settings.agentScreenInference = false
        try check(session.agentStatus?.authority == .report, "screen switch preserves explicit program report")
        settings.agentScreenInference = true
        pump(1.7)
        try check(session.agentStatus?.authority == .report && session.agentObservation.screenEvidence == nil,
                  "screen approval cannot replace a program report")
        try check(!session.reportAutomationProgram(program, ownerPID: frogPID, peerProcessID: getpid()),
                  "unrelated peer cannot borrow custom process ownership")
        try check(session.clearAutomationProgram(peerProcessID: frogPID), "verified custom process clears its own report")
        try check(!session.reportAutomationAgent(phase: .working, reason: "invalid provider", provider: .claude, peerProcessID: frogPID),
                  "custom programs cannot report native provider authority")
        try command(frogRoot, ["exit": true])
        try wait("custom process returns control to its shell") { view.foregroundPid == session.shellPid }
        let (wrapperRoot, wrapperPID) = try launch("claude-wrapper", folder: "wrapper")
        try wait("wrapper alias uses the built-in Claude identity") { session.agentStatus?.recognitionID == "claude" }
        try check(ZshellAgentKind.recognize(processID: wrapperPID) == nil && ZshellAgentKind.recognizeBuiltin(processID: wrapperPID) == .claude,
                  "native alias evidence is distinct from fixed process recognition")
        let identity = AgentConversationIdentity(provider: .claude, sessionID: UUID().uuidString, workingDirectory: root.path)!
        let event = AgentConversationSessionEvent(identity: identity, reporterPID: wrapperPID, source: nil)
        try check(session.acceptAgentConversation(event, peerProcessID: wrapperPID), "alias-only session hook binds its own live conversation")
        try check(session.agentObservation.integrationOwner == nil, "session hook alone does not create lifecycle authority")
        settings.agentScreenInference = false
        try check(session.agentResume?.matchesConversation(identity) == true, "screen switch preserves valid alias-only conversation")
        settings.customAgentRecognitionRules = false
        try check(session.agentResume == nil, "custom switch immediately withdraws alias-only conversation")
        settings.customAgentRecognitionRules = true
        try check(session.acceptAgentConversation(event, peerProcessID: wrapperPID), "fresh session hook restores alias conversation")
        try check(session.reportAutomationAgent(phase: .working, reason: "native working", provider: .claude, peerProcessID: wrapperPID), "verified alias accepts native lifecycle report")
        try check(session.agentStatus?.authority == .integration, "native lifecycle takes priority")
        settings.agentScreenInference = true
        try check(session.agentStatus?.authority == .integration && session.agentResume?.matchesConversation(identity) == true,
                  "enabling screen inference preserves native alias state and conversation")
        try command(wrapperRoot, ["lines": ["Allow update? [y/n]"]])
        pump(3.3)
        try check(session.agentStatus?.phase == .working && session.agentStatus?.authority == .integration && session.agentObservation.screenEvidence == nil,
                  "screen approval cannot replace native lifecycle")
        try check(!session.reportAutomationAgent(phase: .done, reason: "wrong peer", provider: .claude, peerProcessID: getpid()),
                  "unrelated peer cannot update native alias authority")
        settings.agentScreenInference = false
        try check(session.agentStatus?.authority == .integration && session.agentResume?.matchesConversation(identity) == true,
                  "disabling screen inference preserves native alias state and conversation")
        settings.customAgentRecognitionRules = false
        try check(session.agentObservation.integrationOwner == nil && session.agentStatus?.authority != .integration && session.agentResume == nil,
                  "custom switch withdraws native alias state and conversation")
        settings.customAgentRecognitionRules = true
        pump(0.4)
        try check(session.agentObservation.integrationOwner == nil && session.agentResume == nil, "restored alias requires fresh native and conversation reports")
        try check(session.acceptAgentConversation(event, peerProcessID: wrapperPID), "fresh session event rebinds conversation")
        try check(session.reportAutomationAgent(phase: .working, reason: "fresh native", provider: .claude, peerProcessID: wrapperPID), "fresh report restores native authority")
        try save([frog])
        try check(session.agentObservation.integrationOwner == nil && session.agentStatus?.authority != .integration && session.agentResume == nil,
                  "deleting alias rule withdraws native state and conversation")
        try check(!session.reportAutomationAgent(phase: .working, reason: "removed alias", provider: .claude, peerProcessID: wrapperPID),
                  "removed alias cannot immediately report native authority")
        try check(QuickTerminalOffscreen.isSafe(), "real PTY validation never presents a window or takes focus")
        print("\(checks) \(backend) agent recognition production checks passed")
    }
}
