import Foundation
@testable import zshell

private func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

private func rejects(_ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("Invalid report was accepted") }
    catch {}
}

private final class ObservedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ZshellAutomationRequest?

    func record(_ request: ZshellAutomationRequest) {
        lock.lock()
        defer { lock.unlock() }
        value = request
    }

    func latest() -> ZshellAutomationRequest? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@main
@MainActor
struct AgentStatusReportingTests {
    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zshell-report-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try reports()
        lifecycle()
        screens()
        try processes()
        try hooks(bundle: bundle, root: root)
        try wireAndCLI(bundle: bundle, root: root)
        print("Agent status: bounds, lifecycle, screen rules, process lifetime, hook merge, real socket and CLI passed")
    }

    private static func reports() throws {
        var params: [String: ZshellJSONValue] = [
            "name": .string("Build"), "state": .string("blocked"),
            "attention": .string("approval"), "progress": .number(42),
            "tasks": .array([.object([
                "id": .string("tests"), "title": .string("Tests"), "state": .string("working"),
            ])]),
        ]
        let report = try ZshellAgentReport(params: params)
        check(report.progress == 42 && report.attention == .approval && report.tasks.count == 1, "Valid report lost data")
        var childWait = params
        childWait["state"] = .string("working")
        childWait.removeValue(forKey: "attention")
        childWait["tasks"] = .array([.object([
            "id": .string("child"), "title": .string("Publish"), "state": .string("blocked"), "attention": .string("approval"),
        ])])
        let waiting = try ZshellAgentReport(params: childWait)
        check(waiting.activityPhase == .blocked && waiting.activityAttention == .approval, "Waiting child was hidden by parent progress")
        var unfinished = params
        unfinished["state"] = .string("done")
        unfinished.removeValue(forKey: "attention")
        check(try ZshellAgentReport(params: unfinished).activityPhase == .working, "Parent finished while its child was active")
        for value in [-1.0, 101, 1.5] {
            var invalid = params
            invalid["progress"] = .number(value)
            rejects { _ = try ZshellAgentReport(params: invalid) }
        }
        for key in ["pane_id", "authority", "provider"] {
            var invalid = params
            invalid[key] = .string("integration")
            rejects { _ = try ZshellAgentReport(params: invalid) }
        }
        for text in ["\u{1b}]7501;working\u{7}", "line\nline", String(repeating: "x", count: 1_025)] {
            var invalid = params
            invalid["reason"] = .string(text)
            rejects { _ = try ZshellAgentReport(params: invalid) }
        }
        params["state"] = .string("working")
        rejects { _ = try ZshellAgentReport(params: params) }
        params.removeValue(forKey: "attention")
        let task = params["tasks"]!.arrayValue!.first!
        params["tasks"] = .array([task, task])
        rejects { _ = try ZshellAgentReport(params: params) }
        params["tasks"] = .array((0..<33).map { .object([
            "id": .string(String($0)), "title": .string("Task"), "state": .string("working"),
        ]) })
        rejects { _ = try ZshellAgentReport(params: params) }
    }

    private static func lifecycle() {
        for provider in [ZshellAgentKind.codex, .claude] {
            func event(_ name: String, _ values: [String: ZshellJSONValue] = [:]) -> ZshellAgentLifecycleEvent? {
                ZshellAgentLifecycleEvent.parse(provider: provider, payload: values.merging(["hook_event_name": .string(name)]) { _, new in new })
            }
            check(event("UserPromptSubmit")?.phase == .working, "Prompt did not start work")
            check(event("PermissionRequest")?.attention == .approval, "Approval was lost")
            check(event("Stop")?.phase == .idle, "Stop did not settle")
            check(event("SessionEnd")?.endsSession == true, "Session did not end")
            check(event("SessionEnd", ["agent_id": .string("child")])?.endsSession == false, "Child ended its parent session")
            check(event("arbitrary terminal text") == nil, "Unknown event was trusted")
            check(event("SubagentStop", ["agent_id": .string("child"), "agent_type": .string("Explore")])?.task?.phase == .done, "Child completion was lost")
            check(event("Stop", ["agent_id": .string("child")])?.task != nil, "Child Stop became parent completion")
            check(event("SubagentStart", ["agent_id": .string(String(repeating: "x", count: 129))]) == nil, "Unbounded child id accepted")
            let currentID = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
            let staleID = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
            let identity = AgentConversationIdentity(provider: .init(rawValue: provider.rawValue)!,
                sessionID: currentID, workingDirectory: "/tmp/project")!
            for name in ["UserPromptSubmit", "Stop", "SessionEnd", "PermissionRequest"] {
                check(event(name, ["session_id": .string(currentID)])?.belongs(to: identity, provider: provider) == true,
                      "Current conversation lifecycle was rejected")
                check(event(name, ["session_id": .string(staleID)])?.belongs(to: identity, provider: provider) == false,
                      "Stale conversation changed the current lifecycle")
                check(event(name)?.belongs(to: identity, provider: provider) == true, "Legacy lifecycle lost process-based compatibility")
                let other = AgentConversationIdentity(provider: provider == .claude ? .codex : .claude,
                    sessionID: currentID, workingDirectory: "/tmp/project")!
                check(event(name, ["session_id": .string(currentID)])?.belongs(to: other, provider: provider) == false,
                      "Another provider borrowed the current conversation")
            }
            check(event("SessionStart", ["session_id": .string(staleID)])?.belongs(to: identity, provider: provider) == true,
                  "A root SessionStart could not establish its new identity")
            check(event("SessionStart", ["session_id": .string(currentID)])?.belongs(to: nil, provider: provider) == true,
                  "Initial SessionStart required an existing identity")
            for value in [ZshellJSONValue.string(""), .string("invalid"), .number(1), .null] {
                check(event("Stop", ["session_id": value]) == nil, "Malformed conversation ID bypassed lifecycle ownership")
                check(event("SubagentStop", ["agent_id": .string("child"), "parent_session_id": value]) == nil,
                      "Malformed parent ID bypassed child ownership")
            }
            let child: [String: ZshellJSONValue] = ["agent_id": .string("child"), "session_id": .string(staleID),
                                                  "parent_session_id": .string(currentID)]
            check(event("SubagentStop", child)?.belongs(to: identity, provider: provider) == true,
                  "Child lifecycle did not use its explicit parent identity")
            var staleChild = child
            staleChild["parent_session_id"] = .string(staleID)
            check(event("SubagentStop", staleChild)?.belongs(to: identity, provider: provider) == false,
                  "Child lifecycle updated a different parent conversation")
            check(event("Stop", ["agent_id": .string("child"), "session_id": .string(staleID)])?
                .belongs(to: identity, provider: provider) == true, "Child without a parent ID lost task-based compatibility")
        }
        check(ZshellAgentLifecycleEvent.parse(provider: .claude, payload: [
            "hook_event_name": .string("StopFailure"), "error": .string("authentication_failed"),
        ])?.attention == .login, "Authentication failure did not require login")
        check(ZshellAgentLifecycleEvent.parse(provider: .gemini, payload: ["hook_event_name": .string("Stop")]) == nil, "Unsupported native hook accepted")
    }

    private static func screens() {
        let approval = "Would you like to run the following command?\n› 1. Yes\n2. No\nPress enter to confirm"
        check(ZshellAgentScreenEvidence.detect(kind: .codex, text: approval)?.attention == .approval, "Codex approval not recognized")
        check(ZshellAgentScreenEvidence.detect(kind: .aider, text: approval) == nil, "Another process borrowed Codex's screen rules")
        check(ZshellAgentScreenEvidence.detect(kind: .codex, text: "Would you like to run the following command?") == nil, "Quoted heading became approval")
        check(ZshellAgentScreenEvidence.detect(kind: .claude, text: "Do you want to proceed?\nEsc to cancel")?.phase == .blocked, "Claude prompt not recognized")
        for text in ["Done", "Task completed successfully", "error: test failed", String(repeating: "x", count: 32_769)] {
            check(ZshellAgentScreenEvidence.detect(kind: .codex, text: text) == nil, "Ordinary output changed lifecycle")
        }
        let oldPrompt = approval + String(repeating: "\nunrelated output", count: 17)
        check(ZshellAgentScreenEvidence.detect(kind: .codex, text: oldPrompt) == nil, "Old transcript became live status")
    }

    private static func processes() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        let identity = ZshellAgentProcessIdentity(pid: child.processIdentifier)!
        check(identity.isAlive, "Live process lost")
        check(ZshellAgentProcessIdentity.isDescendant(child.processIdentifier, of: getpid()), "Parent credential lost")
        check(!ZshellAgentProcessIdentity.isDescendant(getpid(), of: child.processIdentifier), "Child can impersonate its parent")
        let report = try ZshellAgentReport(params: ["name": .string("Build"), "state": .string("working")])
        let observation = ZshellAgentProgramObservation(report: report, owner: identity, updatedAt: Date())
        check(!observation.isCurrent(at: Date().addingTimeInterval(121)), "Expired report survived")
        child.terminate()
        child.waitUntilExit()
        check(!identity.isAlive && !observation.isCurrent(at: Date()), "Exited owner retained a report")
    }

    private static func hooks(bundle: Bundle, root: URL) throws {
        let home = root.appendingPathComponent("hooks-home")
        let original: [String: Any] = [
            "theme": "keep", "hooks": ["SessionStart": [["hooks": [
                ["type": "command", "command": "user-hook"],
                ["type": "command", "command": "/bin/sh /saved/zshell-session-hook.sh claude _session-start", "timeout": 5],
            ]]]],
        ]
        for provider in [".claude", ".codex"] {
            let directory = home.appendingPathComponent(provider)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let config = directory.appendingPathComponent(provider == ".claude" ? "settings.json" : "hooks.json")
            try JSONSerialization.data(withJSONObject: original, options: .sortedKeys).write(to: config)
        }
        try ZshellAgentLifecycleHooks.installAvailable(bundle: bundle, homeURL: home, environment: [:])
        let settings = home.appendingPathComponent(".claude/settings.json")
        let first = try Data(contentsOf: settings)
        try ZshellAgentLifecycleHooks.installAvailable(bundle: bundle, homeURL: home, environment: [:])
        check(try Data(contentsOf: settings) == first, "Install was not idempotent")
        let installed = try JSONSerialization.jsonObject(with: first) as! [String: Any]
        check(installed["theme"] as? String == "keep", "Unrelated settings overwritten")
        check(String(decoding: first, as: UTF8.self).contains("zshell-session-hook"), "Resume hook was overwritten")
        try ZshellAgentLifecycleHooks.uninstallManaged(homeURL: home, environment: [:])
        for provider in [".claude", ".codex"] {
            let config = home.appendingPathComponent(provider + (provider == ".claude" ? "/settings.json" : "/hooks.json"))
            let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
            check(NSDictionary(dictionary: restored).isEqual(to: original), "Uninstall changed user or resume hooks")
        }
        try Data("{broken".utf8).write(to: settings)
        rejects { try ZshellAgentLifecycleHooks.preflightInstallAvailable(bundle: bundle, homeURL: home, environment: [:]) }
    }

    private static func wireAndCLI(bundle: Bundle, root: URL) throws {
        let socketPath = "/tmp/zshell-report-test-\(getpid()).sock"
        let observed = ObservedRequest()
        let server = try ZshellAutomationSocketServer(path: socketPath) { request, reply in
            observed.record(request)
            reply(.success(id: request.id, result: .object([
                "method": .string(request.method), "params": .object(request.params),
                "peer_pid": request.peerProcessID.map { .number(Double($0)) } ?? .null,
            ])))
        }
        defer { withExtendedLifetime(server) {} }
        var request = ZshellAutomationRequest(version: 1, id: "wire", method: "agent.report", token: "test", terminalID: UUID().uuidString, params: [:])
        request.peerProcessID = 1
        let encoded = try JSONEncoder().encode(request)
        check(!String(decoding: encoded, as: UTF8.self).contains("peerProcessID"), "Peer credential leaked onto wire")
        let reply = try ZshellAutomationSocketServer.exchange(path: socketPath, request: request)
        check(reply.result?.objectValue?["peer_pid"]?.intValue == Int(getpid()), "Peer PID came from JSON instead of kernel")

        func cli(_ arguments: [String], input: String = "") throws -> (Int32, String) {
            let process = Process()
            process.executableURL = bundle.executableURL
            process.arguments = ["+agent"] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["ZSHELL_AUTOMATION"] = "1"
            environment["ZSHELL_AUTOMATION_SOCKET"] = socketPath
            environment["ZSHELL_AUTOMATION_TOKEN"] = "test"
            environment["ZSHELL_TERMINAL_ID"] = UUID().uuidString
            environment["ZSHELL_CLI_STATE"] = root.appendingPathComponent("unused-themes.json").path
            environment["ZSHELL_CLI_TOKEN"] = "test"
            process.environment = environment
            let output = Pipe(), stdin = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = stdin
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try stdin.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let report = try cli(["report", "login", "--name", "Publish", "--progress", "25"])
        check(report.0 == 0, "Public reporting CLI failed: \(report.1)")
        let value = try JSONDecoder().decode(ZshellJSONValue.self, from: Data(report.1.utf8)).objectValue!
        check(value["method"]?.stringValue == "agent.report", "CLI used wrong reporting method")
        check(value["params"]?.objectValue?["attention"]?.stringValue == "login", "CLI dropped login reason")
        check(value["params"]?.objectValue?["process_id"]?.intValue == Int(getpid()), "CLI did not bind its parent")
        check(try cli(["report", "working", "--progress", "101"]).0 != 0, "CLI accepted unbounded progress")
        check(try cli(["report", "working", "--pane", UUID().uuidString]).0 != 0, "CLI accepted another pane target")
        check(try cli(["report", "--json"], input: String(repeating: "x", count: 32_769)).0 != 0, "CLI accepted oversized JSON")
        check(try cli(["clear"]).0 == 0, "CLI clear failed")
        check(try cli(["_lifecycle", "codex"], input: "{\"hook_event_name\":\"Stop\"}").1.trimmingCharacters(in: .whitespacesAndNewlines) == "{}", "Codex Stop hook emitted a decision")
        let status = try cli(["_lifecycle", "claude"], input: "{\"hook_event_name\":\"PermissionRequest\",\"tool_input\":{\"secret\":\"never forward\"}}")
        check(status.0 == 0 && status.1.isEmpty, "Claude hook affected its provider stdout")
        let forwarded = observed.latest()?.params["event"]?.objectValue
        check(forwarded?["hook_event_name"]?.stringValue == "PermissionRequest", "Native adapter did not reach socket")
        check(forwarded?["tool_input"] == nil, "Native adapter forwarded tool input")
    }
}
