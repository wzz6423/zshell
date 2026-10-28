import AppKit
import Darwin
import Foundation
@testable import zshell

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; stored = value }
}

private final class Events: @unchecked Sendable {
    let values = Box<[ZshellJSONValue]>([])
    let done = Box<Bool>(false)
    let error = Box<String?>(nil)
    init(environment: [String: String], params: [String: ZshellJSONValue] = [:]) {
        DispatchQueue.global().async {
            do {
                _ = try ZshellAutomationSocketServer.followEvents(
                    path: environment["ZSHELL_AUTOMATION_SOCKET"]!,
                    request: .init(version: 1, id: UUID().uuidString, method: "events.subscribe",
                                   token: environment["ZSHELL_AUTOMATION_TOKEN"]!,
                                   terminalID: environment["ZSHELL_TERMINAL_ID"]!, params: params),
                    timeoutMS: 15_000
                ) { value in
                    self.values.set(self.values.get() + [value])
                    return false
                }
            } catch { self.error.set(String(describing: error)) }
            self.done.set(true)
        }
    }
    func has(_ event: String, terminalID: UUID? = nil) -> Bool {
        values.get().contains { value in
            value.objectValue?["event"]?.stringValue == event &&
            (terminalID == nil || value.objectValue?["data"]?.objectValue?["terminal_id"]?.stringValue == terminalID!.uuidString)
        }
    }
}

@MainActor private final class EventTestApplication: NSApplication {
    override var isActive: Bool { true }
}

@MainActor private final class EventTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@main
@MainActor
struct AutomationEventTests {
    static func main() throws {
        setbuf(stdout, nil)
        _ = EventTestApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let backend = CommandLine.arguments[1]
        let bundle = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = URL(fileURLWithPath: CommandLine.arguments[3])
        precondition(!AppSettings.shared.aiEnabled)
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.terminalBackend = backend == "alacritty" ? .alacritty : .libghostty
        let manager = TerminalManager()
        let project = manager.selectedProject!
        let owner = project.selectedSession!
        var windows: [NSWindow] = []
        func mount(_ session: TerminalSession) {
            let window = EventTestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = session.surface
            session.surface.setSurfaceVisible(true)
            windows.append(window)
            if windows.count == 1 { manager.attach(to: window) }
        }
        mount(owner)
        defer {
            for window in windows { window.contentView = nil }
            for current in TerminalManager.automationManagers { current.projects.forEach { $0.terminateAll() } }
            pump(1)
        }
        wait("owner shell ready") { owner.isCommandTaskShellReady }
        let envPath = root.appendingPathComponent("environment")
        owner.sendCommand("/usr/bin/env > '" + envPath.path + "'")
        owner.sendEnter()
        wait("terminal environment") { FileManager.default.fileExists(atPath: envPath.path) && owner.isCommandTaskShellReady }
        let environment = Dictionary(try String(contentsOf: envPath, encoding: .utf8).split(separator: "\n").compactMap { line -> (String, String)? in
            guard let split = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<split]), String(line[line.index(after: split)...]))
        }, uniquingKeysWith: { _, new in new })
        let events = Events(environment: environment)
        wait("stream ready") { events.has("stream.ready") }

        let executable = bundle.appendingPathComponent("Contents/MacOS/zshell")
        let cliOutput = root.appendingPathComponent("cli-events.ndjson")
        FileManager.default.createFile(atPath: cliOutput.path, contents: nil)
        let output = try FileHandle(forWritingTo: cliOutput)
        let cli = Process()
        cli.executableURL = executable
        cli.arguments = ["+events", "--event", "command.task.finished", "--once", "--timeout", "10000"]
        cli.environment = environment
        cli.standardOutput = output
        cli.standardError = output
        try cli.run()
        wait("bundled CLI subscribed") { (try? String(contentsOf: cliOutput, encoding: .utf8).contains("stream.ready")) == true }

        let timeoutCLI = Process()
        timeoutCLI.executableURL = executable
        timeoutCLI.arguments = ["+events", "--event", "agent.attention", "--once", "--timeout", "100"]
        timeoutCLI.environment = environment
        timeoutCLI.standardOutput = FileHandle.nullDevice
        timeoutCLI.standardError = FileHandle.nullDevice
        try timeoutCLI.run()
        wait("bundled CLI timeout") { !timeoutCLI.isRunning }
        precondition(timeoutCLI.terminationStatus == 124)

        let created = try rpc(environment, method: "pane.split", params: ["edge": .string("right"), "focus": .bool(false)])
        let targetID = UUID(uuidString: created.objectValue!["terminal_id"]!.stringValue!)!
        let target = project.sessions.first { $0.id == targetID }!
        let targetPane = project.selectedTab!.paneID(forContent: target.id)!
        mount(target)
        wait("created events") { events.has("session.created", terminalID: target.id) && events.has("pane.created", terminalID: target.id) }
        wait("worker shell ready") { target.isCommandTaskShellReady }
        let taskResult = try rpc(environment, method: "pane.run", params: [
            "pane_id": .string(targetPane.uuidString),
            "argv": .array([.string("/bin/sh"), .string("-c"), .string("printf EVENT-COMMAND-DONE; exit 7")]),
        ])
        let taskID = UUID(uuidString: taskResult.objectValue!["task_id"]!.stringValue!)!
        wait("task finished") { TerminalCommandTaskStore.shared.task(id: taskID, projectID: project.id)?.state == .completed }
        wait("shell and task events") { events.has("command.finished", terminalID: target.id) && events.has("command.task.finished", terminalID: target.id) }
        let task = TerminalCommandTaskStore.shared.task(id: taskID, projectID: project.id)!
        precondition(task.exitCode == 7 && task.output?.contains("EVENT-COMMAND-DONE") == true)
        wait("bundled CLI --once") { !cli.isRunning }
        try output.close()
        precondition(cli.terminationStatus == 0)
        let lines = try String(contentsOf: cliOutput, encoding: .utf8).split(separator: "\n")
        precondition(lines.count == 2 && lines.last!.contains("command.task.finished"))

        let filtered = Events(environment: environment, params: [
            "pane_id": .string(targetPane.uuidString), "events": .array([.string("focus.changed")]),
        ])
        wait("pane filter ready") { filtered.has("stream.ready") }
        let originalFocus = project.selectedTab!.focusedPaneID
        project.selectedTab!.focusedPaneID = targetPane
        wait("focus event") { events.has("focus.changed") }
        project.selectedTab!.focusedPaneID = originalFocus
        wait("filtered focus gain and loss") { filtered.values.get().count == 3 }
        project.selectedTab!.focusedPaneID = targetPane
        let beforeReport = events.values.get().count
        let cliPath = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        target.sendCommand(cliPath + " +agent report working --name StreamProgram --progress 25; /bin/sleep 0.2; "
                           + cliPath + " +agent report blocked --name StreamProgram --attention approval --progress 50; /bin/sleep 0.2; "
                           + cliPath + " +agent report done --name StreamProgram --progress 100")
        target.sendEnter()
        wait("authenticated program report completion") {
            events.values.get().dropFirst(beforeReport).contains {
                $0.objectValue?["event"]?.stringValue == "agent.finished"
                    && $0.objectValue?["data"]?.objectValue?["agent"]?.objectValue?["alias"]?.stringValue == "StreamProgram"
            }
        }
        project.selectedTab!.focusedPaneID = originalFocus
        target.agentObservation.programReport = nil
        target.agentStatus = nil
        // Feed the same status model native hooks and authenticated reports use.
        func status(_ phase: ZshellAgentPhase, progress: Int?, attention: ZshellAgentAttention?) {
            target.agentStatus = .init(alias: "worker", kind: .codex, phase: phase, authority: .integration,
                                       reason: "event fixture", updatedAt: Date(), processID: nil, unseen: false,
                                       progress: progress, attention: attention, tasks: [])
        }
        status(.working, progress: 25, attention: nil)
        status(.blocked, progress: 50, attention: .approval)
        status(.done, progress: 100, attention: nil)
        wait("agent events") { events.has("agent.progress", terminalID: target.id) && events.has("agent.attention", terminalID: target.id) && events.has("agent.finished", terminalID: target.id) }
        target.agentStatus = nil

        let foreign = manager.newProject()
        let foreignSession = foreign.selectedSession!
        mount(foreignSession)
        let foreignPane = foreign.selectedTab!.focusedPaneID
        let rejected = Events(environment: environment, params: ["pane_id": .string(foreignPane.uuidString)])
        wait("cross-project rejected") { rejected.done.get() }
        precondition(rejected.error.get()?.contains("pane_not_found") == true)
        precondition(!events.values.get().contains { $0.objectValue?["project_id"]?.stringValue == foreign.id.uuidString })
        let forged = environment.merging(["ZSHELL_TERMINAL_ID": foreignSession.id.uuidString]) { _, new in new }
        let unauthorized = Events(environment: forged)
        wait("forged owner rejected") { unauthorized.done.get() }
        precondition(unauthorized.error.get()?.contains("unauthorized") == true)
        let external = Process()
        external.executableURL = executable
        external.arguments = ["+events", "--timeout", "1"]
        external.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "CFFIXED_USER_HOME": root.path]
        external.standardOutput = FileHandle.nullDevice
        external.standardError = FileHandle.nullDevice
        try external.run()
        wait("environment removal rejected") { !external.isRunning }
        precondition(external.terminationStatus != 0)

        let sourceTab = project.tabs.first { $0.allPanes.contains { $0.id == targetPane } }!
        let beforeMove = events.values.get().count
        let extracted = project.extractPaneAsAdjacentTab(targetPane, from: sourceTab.id)!
        wait("tab metadata updated") {
            events.values.get().dropFirst(beforeMove).contains {
                $0.objectValue?["event"]?.stringValue == "pane.updated"
                    && $0.objectValue?["data"]?.objectValue?["tab_id"]?.stringValue == extracted.id.uuidString
            }
        }
        precondition(!events.values.get().dropFirst(beforeMove).contains {
            $0.objectValue?["event"]?.stringValue == "session.closed"
        })
        precondition(project.moveTab(extracted.id, into: sourceTab.id, toward: .right, beside: originalFocus))
        wait("tab merge metadata updated") {
            events.values.get().filter { $0.objectValue?["event"]?.stringValue == "pane.updated" }.count >= 2
        }
        let replacement = TerminalSession(initialDirectory: root.path, allowsPersistence: false)
        mount(replacement)
        func replacing(_ node: PaneNode, with content: PaneContent) -> PaneNode {
            switch node {
            case .pane(var pane):
                if pane.id == targetPane { pane.content = content }
                return .pane(pane)
            case .split(var split):
                split.first = replacing(split.first, with: content)
                split.second = replacing(split.second, with: content)
                return .split(split)
            }
        }
        sourceTab.layout = replacing(sourceTab.layout, with: .session(replacement))
        wait("same-pane terminal replacement") {
            events.has("session.closed", terminalID: target.id)
                && events.has("session.created", terminalID: replacement.id)
                && events.has("pane.updated", terminalID: replacement.id)
        }
        target.terminate()
        let filePath = root.appendingPathComponent("replacement.txt")
        try "event fixture".write(to: filePath, atomically: true, encoding: .utf8)
        let firstFile = FileTab(path: filePath.path)
        let secondFile = FileTab(path: filePath.path)
        sourceTab.layout = replacing(sourceTab.layout, with: .file(firstFile))
        sourceTab.layout = replacing(sourceTab.layout, with: .file(secondFile))
        wait("same-kind content identity updated") {
            events.values.get().contains {
                $0.objectValue?["event"]?.stringValue == "pane.updated"
                    && $0.objectValue?["data"]?.objectValue?["content_id"]?.stringValue == secondFile.id.uuidString
                    && $0.objectValue?["data"]?.objectValue?["from"]?.objectValue?["content_id"]?.stringValue == firstFile.id.uuidString
            }
        }
        sourceTab.layout = replacing(sourceTab.layout, with: .session(replacement))
        project.closeContent(.session(replacement))
        wait("closed events") { events.has("pane.closed", terminalID: replacement.id) && events.has("session.closed", terminalID: replacement.id) }
        let scope = Events(environment: environment)
        wait("scope stream ready") { scope.has("stream.ready") }
        let ownerTab = project.tabs.first { $0.sessions.contains { $0.id == owner.id } }!
        let transferred = project.detachTabForTransfer(id: ownerTab.id)!
        foreign.adoptTransferredTab(transferred, manager: manager)
        wait("project transfer revokes") { scope.done.get() && events.done.get() }
        let oldCount = scope.values.get().count
        foreign.newSession()
        pump(0.2)
        precondition(scope.values.get().count == oldCount)

        let renewed = ZshellCLIService.shared.terminalEnvironment(for: owner.id)
        let rotated = Events(environment: renewed)
        wait("renewed stream") { rotated.has("stream.ready") }
        _ = ZshellCLIService.shared.terminalEnvironment(for: owner.id)
        wait("rotation revokes") { rotated.done.get() }
        let expired = Events(environment: renewed)
        wait("expired capability rejected") { expired.done.get() }
        precondition(expired.error.get()?.contains("unauthorized") == true)

        let otherManager = TerminalManager()
        let another = otherManager.selectedProject!
        let crossWindow = ZshellCLIService.shared.terminalEnvironment(for: owner.id)
        let windowEvents = Events(environment: crossWindow)
        wait("window stream") { windowEvents.has("stream.ready") }
        let currentTab = foreign.tabs.first { $0.sessions.contains { $0.id == owner.id } }!
        let moved = foreign.detachTabForTransfer(id: currentTab.id)!
        another.adoptTransferredTab(moved, manager: otherManager)
        wait("window transfer revokes") { windowEvents.done.get() }
        let closingEnvironment = ZshellCLIService.shared.terminalEnvironment(for: owner.id)
        let closing = Events(environment: closingEnvironment)
        wait("closing stream") { closing.has("stream.ready") }
        another.closeContent(.session(owner))
        wait("closing owner revokes") { closing.done.get() }
        print("\(backend): real PTYs + authenticated socket + CLI: create/close, focus, shell/task exit 7, agent status/progress/attention/finish, tab moves and same-pane replacement, scope/forgery/env removal, project/window moves, token rotation and close passed")
    }

    private static func rpc(_ environment: [String: String], method: String,
                            params: [String: ZshellJSONValue]) throws -> ZshellJSONValue {
        let box = Box<Result<ZshellJSONValue, Error>?>(nil)
        DispatchQueue.global().async {
            do { box.set(.success(try AppConnection(environment: environment).automationRequest(method: method, params: params))) }
            catch { box.set(.failure(error)) }
        }
        wait("RPC \(method)") { box.get() != nil }
        return try box.get()!.get()
    }

    private static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    private static func wait(_ name: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { pump(0.01) }
        precondition(condition(), "Timed out: \(name)")
    }
}
