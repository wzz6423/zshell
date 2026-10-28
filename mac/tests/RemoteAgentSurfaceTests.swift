import AppKit
import Darwin
import Foundation
@testable import zshell

private final class RemoteAgentBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private final class RemoteAgentEvents: @unchecked Sendable {
    let values = RemoteAgentBox<[ZshellJSONValue]>([])
    let error = RemoteAgentBox<String?>(nil)
    init(environment: [String: String]) {
        DispatchQueue.global().async {
            do {
                _ = try ZshellAutomationSocketServer.followEvents(
                    path: environment["ZSHELL_AUTOMATION_SOCKET"]!,
                    request: .init(version: 1, id: UUID().uuidString, method: "events.subscribe",
                        token: environment["ZSHELL_AUTOMATION_TOKEN"]!,
                        terminalID: environment["ZSHELL_TERMINAL_ID"]!, params: [:]), timeoutMS: 90_000
                ) { value in self.values.set(self.values.get() + [value]); return false }
            } catch { self.error.set(String(describing: error)) }
        }
    }
    func count(_ event: String, terminalID: UUID) -> Int {
        values.get().filter {
            $0.objectValue?["event"]?.stringValue == event
                && $0.objectValue?["data"]?.objectValue?["terminal_id"]?.stringValue == terminalID.uuidString
        }.count
    }
}

@MainActor private final class RemoteAgentApplication: NSApplication {
    override var isActive: Bool { true }
}

@MainActor private final class RemoteAgentWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isVisible: Bool { true }
}

@main
@MainActor
struct RemoteAgentSurfaceTests {
    static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        if RemoteSessionRelay.shouldRun { RemoteSessionRelay.run() }
        do { try run() }
        catch { fputs("Remote Agent surfaces failed: \(error)\n", stderr); exit(1) }
    }

    private static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    private static func wait(_ label: String, timeout: TimeInterval = 18, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return }; pump(0.015) }
        throw NSError(domain: "RemoteAgentSurfaceTest", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }

    private static func run() throws {
        setbuf(stdout, nil)
        _ = RemoteAgentApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let backend = CommandLine.arguments[1]
        let host = try RemoteHost(name: "Official Codex SSH fixture", address: CommandLine.arguments[3], serverPath: CommandLine.arguments[5])
        let directory = CommandLine.arguments[4]
        let root = URL(fileURLWithPath: CommandLine.arguments[6])
        let codex = CommandLine.arguments[7]
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        precondition(AppSettings.shared.aiEnabled)
        let manager = TerminalManager()
        manager.projects.forEach { $0.terminateAll() }
        let project = manager.sharedProject(host: host, directory: directory)
        manager.selectedProjectID = project.id
        var windows: [NSWindow] = []
        var remoteIDs: Set<UUID> = []
        var checks = 0
        var completed = false

        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: "RemoteAgentSurfaceTest", code: 2, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1; print("PASS \(backend): \(label)")
        }
        func mount(_ session: TerminalSession) {
            let surface = session.surface
            surface.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            let window = RemoteAgentWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("main-remote-agent-probe")
            window.contentView = surface
            surface.setSurfaceVisible(true)
            windows.append(window)
            if windows.count == 1 { manager.attach(to: window) }
        }
        func start() throws -> TerminalSession {
            let transport = try RemoteHostTransport(host: host)
            defer { transport.close() }
            try transport.handshake()
            let remoteID = UUID()
            let info = try transport.exchange(RemoteFrame(kind: "create", project: directory,
                sessionId: remoteID.uuidString, command: ["/bin/sh", "-ic", "exec " + TerminalSession.shellQuote(codex)]))
                .decodedResult(RemoteSessionInfo.self)
            remoteIDs.insert(remoteID)
            project.attachRemoteSession(info)
            let session = project.sessions.first { $0.remoteConnection?.sessionID == remoteID }!
            mount(session)
            return session
        }
        func report(_ id: String, event: String) throws {
            let response = root.appendingPathComponent("response-\(id).json")
            try? FileManager.default.removeItem(at: response)
            try JSONSerialization.data(withJSONObject: ["hook_event_name": event])
                .write(to: root.appendingPathComponent("report-\(id).json"), options: .atomic)
            try wait("held official hook did not publish \(event)") { FileManager.default.fileExists(atPath: response.path) }
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: response)) as! [String: Any]
            try check(value["status"] as? Int == 0, "production native hook accepts \(event)")
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

        defer {
            if !completed {
                for session in project.sessions {
                    print("DIAGNOSTIC \(backend) status=\(String(describing: session.remoteStatus)) title=\(session.title) text=\(session.surface.readVisibleText(maxLines: 60, maxColumns: 200) ?? "")")
                }
            }
            AgentConversationHistoryController.shared.close(ifOwnedBy: manager)
            for window in windows { window.contentView = nil }
            manager.projects.forEach { $0.terminateAll() }
            pump(0.25)
            for id in remoteIDs { try? RemoteHostClient.terminate(host: host, directory: directory, sessionID: id) }
        }

        let first = try start(), second = try start()
        try wait("both official Codex TUIs did not send titles over SSH") {
            first.remoteStatus?.state == .connected && second.remoteStatus?.state == .connected
                && first.title.contains("...") && second.title.contains("...")
        }
        try check(first.agentResume == nil && second.agentResume == nil, "native titles await a verified full provider identity")
        let events = RemoteAgentEvents(environment: ZshellCLIService.shared.terminalEnvironment(for: first.id))
        try wait("authenticated event stream did not start") { events.values.get().contains { $0.objectValue?["event"]?.stringValue == "stream.ready" } }
        for session in [first, second] {
            session.sendCommand("zshell isolated native SSH binding verification")
            pump(0.35); session.sendEnter()
            try wait("official SessionStart did not bind: \(session.title)") { session.agentResume?.provider == .codex && session.agentStatus?.phase == .working }
        }
        let firstIdentity = first.agentResume!, secondIdentity = second.agentResume!
        try check(firstIdentity.sessionID != secondIdentity.sessionID && firstIdentity.workingDirectory == secondIdentity.workingDirectory,
            "same-cwd native shared daemon preserves two distinct full IDs")
        try check(firstIdentity.remoteHostID == host.id && firstIdentity.remoteProjectDirectory == directory,
            "conversation identity keeps its SSH host and project")
        try wait("remote Agent event did not arrive") { events.count("agent.status", terminalID: first.id) > 0 }
        let event = events.values.get().first { $0.objectValue?["event"]?.stringValue == "agent.status"
            && $0.objectValue?["data"]?.objectValue?["terminal_id"]?.stringValue == first.id.uuidString }!
        try check(event.objectValue?["data"]?.objectValue?["host_id"]?.stringValue == host.id.uuidString
            && event.objectValue?["data"]?.objectValue?["remote_session_id"]?.stringValue == first.remoteConnection?.sessionID.uuidString,
            "authenticated events identify the host and remote PTY")
        let listings = try RemoteHostClient.catalog(host: host)
        AgentConversationHistoryStore.shared.importRemote(listings.first { $0.directory == directory }!.conversations, host: host, project: project)
        let store = AgentConversationHistoryStore.shared
        let found = store.search(secondIdentity.sessionID, filter: .all, projectID: project.conversationHistoryProjectID)
        try check(found.count == 1 && found[0].identity == secondIdentity, "existing history search returns the exact remote conversation")
        manager.showConversationHistory(all: true)
        guard let panel = NSApp.windows.first(where: { window in window.contentView.map { descendants($0).contains { $0 is NSSearchField } } ?? false }),
              let content = panel.contentView,
              let search = descendants(content).compactMap({ $0 as? NSSearchField }).first,
              let table = descendants(content).compactMap({ $0 as? NSTableView }).first else {
            throw NSError(domain: "RemoteHistoryAppKitMissing", code: 1)
        }
        panel.orderOut(nil)
        search.stringValue = secondIdentity.sessionID
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try wait("AppKit history table did not apply remote query") { table.numberOfRows == 1 }
        try check(true, "AppKit search filters the remote history without a new UI")
        AgentConversationHistoryController.shared.close(ifOwnedBy: manager)
        project.selectedTabID = project.tabs.first { $0.sessions.contains { $0.id == second.id } }!.id
        try report(firstIdentity.sessionID, event: "PermissionRequest")
        try wait("approval did not reach first pane") { first.agentStatus?.attention == .approval }
        try check(second.agentStatus?.phase == .working, "native approval affects only the exact remote pane")
        try report(firstIdentity.sessionID, event: "Stop")
        try wait("completion did not reach first pane") { first.agentStatus?.phase == .done && events.count("agent.finished", terminalID: first.id) == 1 }
        let doneStatus = first.remoteStatus!
        first.acceptRemoteAgentStatus(doneStatus)
        first.acceptRemoteAgentStatus(doneStatus)
        try check(events.count("agent.finished", terminalID: first.id) == 1, "repeated status observations emit one completion event")
        project.selectedTabID = project.tabs.first { $0.sessions.contains { $0.id == first.id } }!.id
        first.acknowledgeRemoteAgent()
        try wait("focused completion was not acknowledged") { first.agentStatus?.phase != .done }
        first.remoteConnection?.reconnect()
        try wait("remote Agent reconnect failed") { first.remoteStatus?.state == .connected }
        pump(0.6)
        try check(events.count("agent.finished", terminalID: first.id) == 1, "focus and reconnect do not repeat a completed turn")
        let firstRecord = store.search(firstIdentity.sessionID, filter: .all, projectID: project.conversationHistoryProjectID).first!
        let originalRemote = first.remoteConnection!.sessionID
        project.closeContent(.session(first), terminate: false)
        var resumed: Result<TerminalManager.ConversationContext, Error>?
        Task { @MainActor in
            do { resumed = .success(try await manager.resumeRemoteConversation(id: firstRecord.id, in: project, focus: false)) }
            catch { resumed = .failure(error) }
        }
        try wait("asynchronous remote history resume did not finish") { resumed != nil }
        let restored = try resumed!.get().session
        mount(restored)
        try wait("resumed remote PTY did not reconnect") { restored.remoteStatus?.state == .connected }
        try check(restored.remoteConnection?.sessionID == originalRemote, "history recovery reuses the existing daemon PTY asynchronously")
        try report(secondIdentity.sessionID, event: "PermissionRequest")
        try wait("second native pane stopped receiving hooks") { second.agentStatus?.attention == .approval }
        try check(true, "second shared Agent remains exact after the first local pane closes")
        let restoredRemote = restored.remoteConnection!.sessionID
        project.closeContent(.session(restored), terminate: false)
        try RemoteHostClient.terminate(host: host, directory: directory, sessionID: restoredRemote)
        pump(0.6)
        resumed = nil
        Task { @MainActor in
            do { resumed = .success(try await manager.resumeRemoteConversation(id: firstRecord.id, in: project, focus: false)) }
            catch { resumed = .failure(error) }
        }
        try wait("ended remote conversation did not invoke provider resume") { resumed != nil }
        let restarted = try resumed!.get().session
        mount(restarted)
        remoteIDs.insert(restarted.remoteConnection!.sessionID)
        try wait("official resumed Codex did not reconnect to its full thread") {
            restarted.remoteStatus?.state == .connected && restarted.title.contains(String(firstIdentity.sessionID.prefix(29)))
        }
        restarted.sendCommand("zshell isolated exact resume verification"); pump(0.35); restarted.sendEnter()
        try wait("official resumed Codex did not rebind its identity") { restarted.agentResume?.sessionID == firstIdentity.sessionID }
        try check(restarted.remoteConnection?.sessionID != originalRemote, "ended PTY resumes the exact official provider UUID")
        completed = true
        print("\(checks) \(backend) official Codex SSH Agent surface checks passed")
    }
}
