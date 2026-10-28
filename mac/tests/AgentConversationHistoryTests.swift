import AppKit
import Darwin
import Foundation
@testable import zshell

private enum HistoryTestFailure: Error { case failed(String) }

@main
@MainActor
struct AgentConversationHistoryTests {
    private static var checks = 0
    private static let fileManager = FileManager.default
    private static var windows: [NSWindow] = []
    private static var managers: [TerminalManager] = []
    private static var fixtureRoot: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HISTORY_TEST_ROOT"]!).resolvingSymlinksInPath()
    }

    static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        if ZshellCommandLine.shouldRun { ZshellCommandLine.main() }
        if CommandLine.arguments[1] == "--history-wire" {
            do {
                let arguments = CommandLine.arguments
                let params = try JSONDecoder().decode([String: ZshellJSONValue].self, from: Data(arguments[6].utf8))
                let request = ZshellAutomationRequest(version: 1, id: UUID().uuidString,
                    method: arguments[5], token: arguments[3], terminalID: arguments[4], params: params)
                let response = try ZshellAutomationSocketServer.exchange(path: arguments[2], request: request,
                    expectedPeerProcessID: arguments.count > 7 ? pid_t(arguments[7]) : nil)
                print(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
                exit(0)
            } catch { fputs("\(error)\n", stderr); exit(1) }
        }
        setbuf(stdout, nil)
        do {
            if CommandLine.arguments[1] == "store" {
                try stores()
                try arguments()
            } else {
                let app = NSApplication.shared
                app.setActivationPolicy(.prohibited)
                defer {
                    managers.forEach { $0.windowClosed() }
                    pump(0.5)
                    windows.forEach { $0.contentView = nil; $0.close() }
                    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: app)
                    _ = try? PTYMuxCommandLine.exchange(method: "shutdown")
                }
                AppSettings.shared.terminalBackend = CommandLine.arguments[1] == "ghostty" ? .libghostty : .alacritty
                AppSettings.shared.resumeAgentConversations = false
                AppSettings.shared.preserveTerminalSessions = false
                try terminals(providerBin: URL(fileURLWithPath: CommandLine.arguments[2]))
            }
            print("Conversation history \(CommandLine.arguments[1]): \(checks) checks passed")
        } catch {
            fputs("Conversation history failed after \(checks) checks: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw HistoryTestFailure.failed(message) }
        checks += 1
        print("PASS \(message)")
    }

    private static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        var rejected = false
        do { try operation() } catch { rejected = true }
        try check(rejected, message)
    }

    private static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    private static func wait(_ message: String, timeout: TimeInterval = 8, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { pump(0.01) }
        try check(condition(), message)
    }

    private static func identity(_ provider: AgentConversationIdentity.Provider = .claude,
                                 sessionID: String? = nil, cwd: URL? = nil, config: URL? = nil,
                                 file: URL? = nil, alias: String? = nil) -> AgentConversationIdentity {
        AgentConversationIdentity(provider: provider,
            sessionID: sessionID ?? (provider == .opencode ? "ses_" + UUID().uuidString : UUID().uuidString),
            workingDirectory: (cwd ?? fixtureRoot).path, configDirectory: config?.path,
            sessionFile: file?.path, alias: alias)!
    }

    private static func stores() throws {
        let url = fixtureRoot.appendingPathComponent("store/records.json")
        let store = AgentConversationHistoryStore(url: url)
        let project = UUID(), terminal = UUID()
        let conversation = identity(alias: "Café repair")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let id = store.note(conversation, projectID: project, projectName: "Fixture", title: "Fix café", terminalID: terminal, at: date)
        store.flush()
        try check(store.records.count == 1 && store.persistenceError == nil, "verified identity saves")
        var metadata = stat()
        lstat(url.path, &metadata)
        let firstInode = metadata.st_ino
        try check(metadata.st_mode & 0o777 == 0o600, "history file is private 0600")
        lstat(url.deletingLastPathComponent().path, &metadata)
        try check(metadata.st_mode & 0o777 == 0o700, "history directory is private 0700")
        let secondTerminal = UUID()
        try check(store.note(conversation, projectID: project, projectName: "Fixture", title: "\u{1b}Fix café\n", terminalID: secondTerminal, at: date.addingTimeInterval(1)) == id,
                  "repeat provider session keeps one history UUID")
        store.flush()
        lstat(url.path, &metadata)
        try check(metadata.st_ino != firstInode && (try fileManager.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) == ["records.json"],
                  "saving atomically replaces the file and leaves no temporary entries")
        store.ended(id: id, terminalID: terminal, at: date.addingTimeInterval(2))
        try check(store.record(id: id)?.endedAt == nil, "old terminal cannot end the current binding")
        store.ended(id: id, terminalID: secondTerminal, at: date.addingTimeInterval(3))
        try check(store.record(id: id)?.endedAt != nil, "closing a conversation preserves its history")
        try store.setArchived(true, id: id)
        try check(store.search().isEmpty && store.search(filter: .archived).count == 1 && store.search(filter: .all).count == 1,
                  "Recent omits archived entries while All includes them")
        let reloaded = AgentConversationHistoryStore(url: url)
        try check(reloaded.record(id: id)?.isArchived == true && reloaded.record(id: id)?.endedAt != nil,
                  "archive and closed state survive reload")
        try store.setArchived(false, id: id)
        try check(store.search("CAFE claude").first?.id == id, "search folds case and diacritics across fields")
        try check(store.search("Fixture", projectID: UUID()).isEmpty, "search respects the requested project")
        try rejects("cross-project archive is rejected") { try store.setArchived(true, id: id, projectID: UUID()) }
        try rejects("cross-project deletion is rejected") { try store.delete(id: id, projectID: UUID()) }
        for index in 0..<205 {
            store.note(identity(), projectID: project, projectName: "Bounded", title: "Record \(index)",
                       terminalID: UUID(), at: date.addingTimeInterval(Double(index + 10)))
        }
        store.flush()
        try check(store.records.count == 200 && store.search().count == 20 && store.record(id: id) == nil,
                  "history retains the newest 200 conversations and Recent returns 20")
        try check(AgentConversationHistoryStore(url: url).records.map(\.id) == store.records.map(\.id),
                  "a burst flush persists the newest complete history snapshot")
        try check(store.search("Record 204", filter: .all).first?.title == "Record 204", "newest records rank first")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let valid = (saved["records"] as! [[String: Any]])[0]
        var corrupt = valid
        corrupt["identity"] = ["provider": "other", "sessionID": "shell-command"]
        let mixed = try JSONSerialization.data(withJSONObject: ["version": 1, "records": [valid, "bad", corrupt, valid]])
        try PersistentCLIConnection.writePrivate(mixed, to: url)
        try check(AgentConversationHistoryStore(url: url).records.count == 1, "malformed entries and duplicates are skipped independently")
        try PersistentCLIConnection.writePrivate(Data("{\"version\":2,\"records\":[]}".utf8), to: url)
        try check(AgentConversationHistoryStore(url: url).persistenceError != nil, "unknown persistence version is rejected")
        try PersistentCLIConnection.writePrivate(Data(repeating: 65, count: 8 * 1024 * 1024 + 1), to: url)
        try check(AgentConversationHistoryStore(url: url).persistenceError != nil, "oversized history is rejected before decoding")
        try PersistentCLIConnection.writePrivate(mixed, to: url)
        chmod(url.path, 0o644)
        try check(AgentConversationHistoryStore(url: url).records.isEmpty, "non-private history files are rejected")
        chmod(url.path, 0o600)
        let linkedURL = url.deletingLastPathComponent().appendingPathComponent("linked.json")
        try fileManager.createSymbolicLink(at: linkedURL, withDestinationURL: url)
        try check(AgentConversationHistoryStore(url: linkedURL).persistenceError != nil, "history loading never follows a symlink")
        let piFile = fixtureRoot.appendingPathComponent("kept.jsonl")
        try Data("provider owned".utf8).write(to: piFile)
        let piID = store.note(identity(.pi, file: piFile), projectID: project, projectName: "Pi", title: nil, terminalID: UUID())
        try store.delete(id: piID)
        store.flush()
        try check(fileManager.fileExists(atPath: piFile.path), "deleting history leaves provider conversation files intact")
        try check(AgentConversationHistoryStore(url: url).record(id: piID) == nil,
                  "pending observations cannot resurrect a deleted history record")
        let remaining = store.records[0].id
        let beforeFailedSave = try Data(contentsOf: url)
        chmod(url.deletingLastPathComponent().path, 0o755)
        let failedObservation = identity()
        let failedID = store.note(failedObservation, projectID: project, projectName: "Failed write", title: nil, terminalID: UUID())
        store.flush()
        try check(store.persistenceError != nil && store.record(id: failedID) != nil && (try Data(contentsOf: url)) == beforeFailedSave,
                  "failed background save keeps observed history and the previous durable snapshot")
        pump(0.02)
        try check(store.persistenceError != nil, "older successful callbacks cannot clear the newest background write failure")
        try rejects("unsafe persistence cannot partially archive in memory") { try store.setArchived(true, id: remaining) }
        try check(store.record(id: remaining)?.isArchived == false, "failed archive preserves the previous record")
        chmod(url.deletingLastPathComponent().path, 0o700)
        let repaired = identity()
        store.note(repaired, projectID: project, projectName: "Repaired", title: nil, terminalID: UUID())
        store.flush()
        try check(store.persistenceError == nil, "a successful background save clears the previous persistence error")
        try check(AgentConversationHistoryStore(url: url).record(id: failedID) != nil,
                  "a later successful write persists observations retained after failure")
    }

    private static func arguments() throws {
        let id = UUID().uuidString
        let recent = try AgentConversationHistoryCommandLine.parse(["history", "--query", "fix"])
        try check(recent.filter == "recent" && recent.query == "fix", "CLI defaults to Recent")
        let resume = try AgentConversationHistoryCommandLine.parse(["resume", "--id", id, "--focus"])
        try check(resume.focus && resume.id?.uuidString == id, "CLI accepts explicit history ID and focus")
        for values in [["resume", "--id", id, "--all"], ["archive", "--id", id, "--focus"],
                       ["history", "--all", "--archived"], ["history", "--query", "a\nb"],
                       ["history", "--query", String(repeating: "a", count: 1_025)],
                       ["delete"], ["resume", "--id", "latest"], ["history", "--connection", "relative"],
                       ["resume", "--id", id, "--id", id], ["history", "projects", "--project", id]] {
            try rejects("CLI rejects invalid history options \(values.first!)") { _ = try AgentConversationHistoryCommandLine.parse(values) }
        }
        for key in ["ZSHELL_CLI_STATE", "ZSHELL_CLI_TOKEN", "ZSHELL_TERMINAL_ID", "ZSHELL_AUTOMATION_SOCKET", "ZSHELL_PERSISTENT_CONNECTION"] {
            try check(AgentConversationHistoryCommandLine.isPaneInvocation([key: ""]), "partial pane marker \(key) cannot fall back to external control")
        }
    }

    private static func newManager() -> (TerminalManager, Project) {
        let manager = TerminalManager()
        managers.append(manager)
        manager.projects.forEach { manager.close($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        windows.append(window)
        manager.attach(to: window)
        let project = Project(fallbackName: "History fixture", manager: manager, createInitialSession: false)
        project.customDirectory = fixtureRoot.path
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        return (manager, project)
    }

    private static func attach(_ session: TerminalSession) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.surface
        session.surface.frame = NSRect(x: 0, y: 0, width: 800, height: 440)
        session.surface.setSurfaceVisible(true)
        windows.append(window)
    }

    private static func launchInfo(_ session: TerminalSession) -> [String: Any]? {
        let url = fixtureRoot.appendingPathComponent("launch-\(session.id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func runCLI(_ arguments: [String], environment extra: [String: String] = [:]) throws -> (status: Int32, output: String, error: String) {
        let output = fixtureRoot.appendingPathComponent("stdout-\(UUID()).txt")
        let error = fixtureRoot.appendingPathComponent("stderr-\(UUID()).txt")
        fileManager.createFile(atPath: output.path, contents: nil)
        fileManager.createFile(atPath: error.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: error)
        defer { try? stdout.close(); try? stderr.close(); try? fileManager.removeItem(at: output); try? fileManager.removeItem(at: error) }
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(extra) { _, value in value }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(12)
        while process.isRunning && Date() < deadline { pump(0.01) }
        if process.isRunning { process.terminate(); throw HistoryTestFailure.failed("CLI timed out: \(arguments)") }
        process.waitUntilExit()
        return (process.terminationStatus, try String(contentsOf: output, encoding: .utf8), try String(contentsOf: error, encoding: .utf8))
    }

    private static func json(_ value: String) throws -> ZshellJSONValue {
        try JSONDecoder().decode(ZshellJSONValue.self, from: Data(value.utf8))
    }

    private static func requestProvider(_ session: TerminalSession, values: [String: Any]) throws -> [String: Any] {
        let responseURL = fixtureRoot.appendingPathComponent("response-\(session.id).json")
        try? fileManager.removeItem(at: responseURL)
        try JSONSerialization.data(withJSONObject: values).write(to: fixtureRoot.appendingPathComponent("command-\(session.id).json"), options: .atomic)
        try wait("provider-side request finishes") { fileManager.fileExists(atPath: responseURL.path) }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: responseURL)) as! [String: Any]
    }

    private static func wire(_ connection: AgentConversationHistoryConnection, method: String, params: [String: ZshellJSONValue], token: String? = nil,
                             terminalID: String = "", path: String? = nil, expectedPID: pid_t? = nil) throws -> ZshellAutomationResponse {
        let text = String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
        var arguments = ["--history-wire", path ?? connection.socketPath, token ?? connection.token, terminalID, method, text]
        if let expectedPID { arguments.append(String(expectedPID)) }
        let result = try runCLI(arguments)
        guard result.status == 0 else { throw CLIError.message(result.error) }
        return try JSONDecoder().decode(ZshellAutomationResponse.self, from: Data(result.output.utf8))
    }

    private static func terminals(providerBin: URL) throws {
        let (manager, project) = newManager()
        let (otherManager, otherProject) = newManager()
        let store = AgentConversationHistoryStore.shared
        let descriptorURL = AgentConversationHistoryPaths.connectionsURL.appendingPathComponent("\(getpid()).json")
        let connection = try AgentConversationHistoryConnection.load(from: descriptorURL)
        try check(connection.processIsCurrent && connection.processID == getpid(), "external connection binds the exact app process")
        let projects = try runCLI(["+agent", "history", "projects"])
        try check(projects.status == 0 && (try json(projects.output)).arrayValue?.count == 2, "ordinary external terminal discovers explicit project scopes")
        let missingProject = try runCLI(["+agent", "history"])
        try check(missingProject.status != 0 && missingProject.error.contains("--project"), "external history requires an explicit project UUID")
        let projectText = project.conversationHistoryProjectID.uuidString
        for params in [["project_id": ZshellJSONValue.string(projectText), "query": .number(1)],
                       ["project_id": .string(projectText), "filter": .bool(false)],
                       ["project_id": .string(projectText), "command": .string("echo unsafe")],
                       ["project_id": .number(1)]] {
            try check(try wire(connection, method: "history.list", params: params).ok == false, "control rejects malformed JSON types or unknown parameters")
        }
        try check(try wire(connection, method: "pane.list", params: [:]).ok == false, "external control exposes only history methods")
        try check(try wire(connection, method: "history.projects", params: [:], token: "wrong").ok == false, "expired external capability is rejected")
        try rejects("client verifies kernel peer PID") { _ = try wire(connection, method: "history.projects", params: [:], expectedPID: getpid() + 1) }
        let originalDescriptor = try Data(contentsOf: descriptorURL)
        var descriptor = try JSONSerialization.jsonObject(with: originalDescriptor) as! [String: Any]
        descriptor["startedSeconds"] = 0
        try PersistentCLIConnection.writePrivate(try JSONSerialization.data(withJSONObject: descriptor), to: descriptorURL)
        try rejects("descriptor rejects a reused PID with a different launch time") { _ = try AgentConversationHistoryConnection.load(from: descriptorURL) }
        try PersistentCLIConnection.writePrivate(originalDescriptor, to: descriptorURL)
        for provider in AgentConversationIdentity.Provider.allCases {
            let sessionID = provider == .opencode ? "ses_" + UUID().uuidString : UUID().uuidString
            let cwd = fixtureRoot.appendingPathComponent("\(provider.rawValue)-cwd", isDirectory: true)
            let configuration = fixtureRoot.appendingPathComponent("\(provider.rawValue)-configuration", isDirectory: true)
            try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: configuration, withIntermediateDirectories: true)
            let sessionFile = fixtureRoot.appendingPathComponent("\(provider.rawValue).jsonl")
            if provider == .pi {
                let header = try JSONSerialization.data(withJSONObject: ["type": "session", "id": sessionID, "cwd": cwd.path])
                try (header + Data([10])).write(to: sessionFile)
            }
            project.launchSettings.environmentVariables = [
                .init(name: "HISTORY_TEST_ROOT", value: fixtureRoot.path), .init(name: "HISTORY_TEST_SESSION", value: sessionID),
                .init(name: "HISTORY_TEST_SESSION_FILE", value: sessionFile.path),
                .init(name: provider.configurationVariable, value: configuration.path),
            ]
            if provider == .opencode {
                project.launchSettings.environmentVariables += [.init(name: "XDG_DATA_HOME", value: configuration.path + "/data")]
            }
            guard let session = project.newSession(directory: cwd.path) else {
                throw HistoryTestFailure.failed("The provider fixture session did not start.")
            }
            attach(session)
            try wait("\(provider.rawValue) shell starts") { session.shellPid != nil && session.surface.foregroundPid == session.shellPid }
            session.surface.sendText("/usr/bin/python3 \(TerminalSession.shellQuote(providerBin.appendingPathComponent(provider.rawValue).path))\r")
            try wait("\(provider.rawValue) trusted root hook creates history") {
                session.agentConversationHistoryID != nil && session.agentConversationOwner?.isAlive == true
            }
            let id = session.agentConversationHistoryID!
            let record = store.record(id: id)!
            try check(record.identity.sessionID == sessionID && record.identity.configDirectory == configuration.path,
                      "\(provider.rawValue) history keeps exact session and configuration")
            try check(TerminalManager.openConversation(record)?.session === session, "\(provider.rawValue) reports the actual live terminal")
            let sessionCount = project.sessions.count
            let revealed = try manager.resumeConversation(id: id, in: project, focus: false)
            try check(revealed.context.session === session && project.sessions.count == sessionCount, "\(provider.rawValue) resume reveals a live conversation without duplicating it")
            try rejects("\(provider.rawValue) scoped resume rejects another project") { _ = try otherManager.resumeConversation(id: id, in: otherProject, focus: false) }
            let crossWindow = try otherManager.resumeConversation(id: id, focus: false)
            try check(crossWindow.context.session === session && crossWindow.context.manager === manager,
                      "\(provider.rawValue) UI resume resolves an already open conversation across windows")
            let otherScope = otherProject.conversationHistoryProjectID
            otherProject.conversationHistoryProjectID = project.conversationHistoryProjectID
            try rejects("\(provider.rawValue) equal history scopes cannot duplicate a live conversation across windows") {
                _ = try otherManager.resumeConversation(id: id, in: otherProject, focus: false)
            }
            let ambiguous = try runCLI(["+agent", "resume", "--project", projectText, "--id", id.uuidString])
            try check(ambiguous.status != 0 && ambiguous.error.contains("--window"), "external resume requires a window for an ambiguous live project")
            let selectedWindow = try runCLI(["+agent", "resume", "--project", projectText, "--id", id.uuidString, "--window", manager.conversationHistoryWindowID.uuidString])
            try check(selectedWindow.status == 0 && (try json(selectedWindow.output)).objectValue?["terminal_id"]?.stringValue == session.id.uuidString,
                      "explicit window resumes the one existing conversation")
            otherProject.conversationHistoryProjectID = otherScope
            let paneEnvironment = ZshellCLIService.shared.terminalEnvironment(for: session.id)
            let inPane = try runCLI(["+agent", "history", "--all"], environment: paneEnvironment)
            try check(inPane.status == 0 && (try json(inPane.output)).objectValue?["project_id"]?.stringValue == projectText,
                      "\(provider.rawValue) in-pane history keeps its project scope")
            let escaped = try runCLI(["+agent", "history", "--project", otherProject.conversationHistoryProjectID.uuidString], environment: paneEnvironment)
            try check(escaped.status != 0, "\(provider.rawValue) pane CLI cannot select another project")
            let crossID = try wire(connection, method: "history.archive", params: ["project_id": .string(otherProject.conversationHistoryProjectID.uuidString), "id": .string(id.uuidString)])
            try check(!crossID.ok && !record.isArchived, "\(provider.rawValue) external archive cannot use a foreign history UUID")
            if provider == .claude {
                let command: [String: Any] = ["scrub": true, "arguments": ["+agent", "history", "--project", otherProject.conversationHistoryProjectID.uuidString, "--connection", descriptorURL.path]]
                let response = try requestProvider(session, values: command)
                try check(response["status"] as? Int != 0 && (response["stderr"] as? String)?.contains("project_scope_required") == true,
                          "real pane descendant cannot gain cross-project history by clearing its environment")
            }
            try store.setArchived(true, id: id)
            let archived = try runCLI(["+agent", "history", "--project", projectText, "--archived"])
            try check(archived.status == 0 && (try json(archived.output)).objectValue?["records"]?.arrayValue?.contains(where: { $0.objectValue?["id"]?.stringValue == id.uuidString }) == true,
                      "\(provider.rawValue) archived history is discoverable externally")
            _ = try requestProvider(session, values: ["hook": true])
            try check(store.record(id: id)?.isArchived == true && store.records.filter { $0.identity.sessionID == sessionID }.count == 1,
                      "\(provider.rawValue) repeated SessionStart preserves archive choice and one record")
            try Data().write(to: fixtureRoot.appendingPathComponent("stop-\(session.id)"))
            try wait("\(provider.rawValue) provider exit ends the history binding") { session.refreshAgentConversationHistory(); return store.record(id: id)?.endedAt != nil }
            try check(!session.hasExited && session.shellPid.map { kill($0, 0) == 0 } == true,
                      "\(provider.rawValue) history survives agent exit while its original shell lives")
            let previousTab = project.selectedTabID
            let resumed = try manager.resumeConversation(id: id, in: project, focus: false)
            try check(resumed.action == "resume_started" && resumed.context.session.id != session.id && project.selectedTabID == previousTab,
                      "\(provider.rawValue) manual resume creates a background terminal despite automatic restore being off")
            let pendingCount = project.sessions.count
            let pending = try manager.resumeConversation(id: id, in: project, focus: false)
            try check(pending.context.session === resumed.context.session && project.sessions.count == pendingCount,
                      "\(provider.rawValue) pending resume is deduplicated")
            attach(resumed.context.session)
            try wait("\(provider.rawValue) resumed provider reports its exact history") { resumed.context.session.agentConversationOwner?.isAlive == true && launchInfo(resumed.context.session) != nil }
            let expected = provider == .claude ? ["--resume", sessionID] : provider == .codex ? ["resume", "--no-daemon", sessionID]
                : provider == .pi ? ["--session", sessionFile.path] : ["--session", sessionID]
            let launched = launchInfo(resumed.context.session)!
            let launchedDirectory = (launched["cwd"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            try check(launched["argv"] as? [String] == expected && launchedDirectory == cwd.standardizedFileURL.path,
                      "\(provider.rawValue) exact resume argv/cwd: \(launched["argv"] ?? "missing") / \(launched["cwd"] ?? "missing")")
            let savedConfiguration = launched["configuration"] as? [String: String]
            try check(savedConfiguration?[provider.configurationVariable] == configuration.path
                      && (provider != .opencode || savedConfiguration?["XDG_DATA_HOME"] == configuration.path + "/data"),
                      "\(provider.rawValue) restores its original configuration environment")
            try check(store.records.filter { $0.identity.sessionID == sessionID }.count == 1 && store.record(id: id)?.isArchived == false,
                      "\(provider.rawValue) resumed history remains one unarchived record")
            for (method, params) in [("history.resume", ["project_id": ZshellJSONValue.string(projectText), "id": .string(id.uuidString), "focus": .string("yes")]),
                                     ("history.archive", ["project_id": .string(projectText), "id": .string(id.uuidString), "focus": .bool(true)])] {
                try check(try wire(connection, method: method, params: params).ok == false, "mutation rejects an invalid JSON focus type or unknown parameter")
            }
            project.closeContent(.session(resumed.context.session))
            project.closeContent(.session(session))
            pump(0.25)
            store.flush()
            try check(store.record(id: id)?.endedAt != nil && AgentConversationHistoryStore(url: AgentConversationHistoryPaths.recordsURL).record(id: id) != nil,
                      "\(provider.rawValue) closed terminals leave reloadable history")
            if provider == .pi {
                let mismatched = try JSONSerialization.data(withJSONObject: ["type": "session", "id": UUID().uuidString, "cwd": cwd.path])
                try (mismatched + Data([10])).write(to: sessionFile)
                try rejects("mismatched Pi file fails before creating a terminal") { _ = try manager.resumeConversation(id: id, in: project, focus: false) }
                try fileManager.removeItem(at: sessionFile)
                try rejects("missing Pi file fails before creating a terminal") { _ = try manager.resumeConversation(id: id, in: project, focus: false) }
            } else {
                try fileManager.removeItem(at: configuration)
                try rejects("missing configuration fails before creating a terminal") { _ = try manager.resumeConversation(id: id, in: project, focus: false) }
                try fileManager.createDirectory(at: configuration, withIntermediateDirectories: true)
            }
            try fileManager.removeItem(at: cwd)
            try rejects("missing working directory fails before creating a terminal") { _ = try manager.resumeConversation(id: id, in: project, focus: false) }
        }
        try unscopedTerminal(project: project, providerBin: providerBin, descriptorURL: descriptorURL)
        try persistentTerminal(manager: manager, project: project, providerBin: providerBin)
        try menus()
        let pendingID = store.note(identity(), projectID: project.conversationHistoryProjectID,
                                   projectName: "Quit flush", title: nil, terminalID: UUID())
        TerminalManager.prepareForApplicationQuit(endAll: true)
        try check(AgentConversationHistoryStore(url: AgentConversationHistoryPaths.recordsURL).record(id: pendingID) != nil,
                  "application quit flushes its pending background history write")
    }

    private static func unscopedTerminal(project: Project, providerBin: URL, descriptorURL: URL) throws {
        var settings = TerminalLaunchSettings()
        settings.environmentVariables = [
            .init(name: "HISTORY_TEST_ROOT", value: fixtureRoot.path),
            .init(name: "HISTORY_TEST_SESSION", value: UUID().uuidString),
            .init(name: "HISTORY_TEST_NO_HOOK", value: "1"),
        ]
        let session = TerminalSession(initialDirectory: fixtureRoot.path, launchSettings: settings, allowsPersistence: false)
        attach(session)
        try wait("unscoped quick-terminal shell starts") { session.isShellAvailableForAutomation }
        session.surface.sendText("'\(providerBin.appendingPathComponent("claude").path)'\n")
        try wait("unscoped terminal launches a real descendant") { launchInfo(session) != nil }
        try check(managers.allSatisfy { !$0.projects.contains(where: { $0.sessions.contains(where: { $0 === session }) }) },
                  "quick-terminal fixture is outside every project")
        let response = try requestProvider(session, values: ["scrub": true, "arguments": [
            "+agent", "history", "--project", project.conversationHistoryProjectID.uuidString,
            "--connection", descriptorURL.path,
        ]])
        try check(response["status"] as? Int != 0 && (response["stderr"] as? String)?.contains("project_scope_required") == true,
                  "quick-terminal descendants cannot acquire external history by clearing their environment")
        session.terminate()
        pump(0.15)
    }

    private static func persistentTerminal(manager: TerminalManager, project: Project, providerBin: URL) throws {
        let cwd = fixtureRoot.appendingPathComponent("persistent-cwd", isDirectory: true)
        let configuration = fixtureRoot.appendingPathComponent("persistent-configuration", isDirectory: true)
        try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: configuration, withIntermediateDirectories: true)
        project.launchSettings.environmentVariables = [
            .init(name: "HISTORY_TEST_ROOT", value: fixtureRoot.path),
            .init(name: "HISTORY_TEST_SESSION", value: UUID().uuidString),
            .init(name: "CLAUDE_CONFIG_DIR", value: configuration.path),
        ]
        AppSettings.shared.preserveTerminalSessions = true
        guard let original = project.newSession(directory: cwd.path, commandArguments: [providerBin.appendingPathComponent("claude").path]) else {
            throw HistoryTestFailure.failed("The persistent provider fixture session did not start.")
        }
        attach(original)
        try wait("persistent provider reports a verified conversation") { original.agentConversationOwner?.isAlive == true }
        try check(PersistentPTY.reconnect(id: original.id) != nil, "history fixture uses a real persistent PTY")
        let id = original.agentConversationHistoryID!, pid = original.agentConversationProcessID!
        original.prepareForApplicationQuit(preserve: true)
        project.closeContent(.session(original), terminate: false)
        AppSettings.shared.preserveTerminalSessions = false
        let resumed = try manager.resumeConversation(id: id, in: project, focus: false)
        attach(resumed.context.session)
        try check(resumed.action == "reconnected" && resumed.context.session.id == original.id
                  && resumed.context.session.shellPid == pid && kill(pid, 0) == 0,
                  "history reconnects the surviving PTY instead of relaunching the provider")
        try check(resumed.context.session.agentConversationOwner == nil && resumed.context.session.agentConversationResumeDeadline == nil,
                  "PTY reconnect does not invent a current conversation identity")
        let again = try manager.resumeConversation(id: id, in: project, focus: false)
        try check(again.action == "revealed_terminal" && again.context.session === resumed.context.session,
                  "a repeated unverified reconnect reveals its existing terminal")
        pump(0.9)
        try check(AgentAutomationMonitor.shared.ownsTerminalProcess(pid),
                  "the monitor keeps the reconnected PTY while its old renderer remains alive")
        _ = try requestProvider(resumed.context.session, values: ["hook": true])
        try wait("reconnected PTY refreshes identity through the rotated pane capability") {
            resumed.context.session.agentConversationOwner?.isAlive == true
        }
        let verified = try manager.resumeConversation(id: id, in: project, focus: false)
        try check(verified.action == "revealed" && verified.context.session.agentConversationProcessID == pid,
                  "verified reconnect still owns the original provider process")
        project.closeContent(.session(resumed.context.session))
        pump(0.3)
        try check(kill(pid, 0) != 0 && AgentConversationHistoryStore.shared.record(id: id)?.endedAt != nil,
                  "closing the reconnected terminal ends its PTY and retains history")
    }

    private static func menus() throws {
        let main = NSMenu(title: "Main")
        NSApp.mainMenu = main
        let applicationDelegate = ZshellApplicationDelegate()
        AppMenuLocalization.shared.start(applicationDelegate: applicationDelegate)
        let agents = main.items.first { $0.identifier?.rawValue == "zshell-agents-menu" }!
        for _ in 0..<3 {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
        }
        try check(agents.submenu?.items.filter { $0.identifier?.rawValue.hasPrefix("agent-conversation-history") == true }.count == 2,
                  "AppKit menu installs history and all-conversation search without duplicates")
        try check(agents.submenu?.items.allSatisfy { $0.target === AgentConversationHistoryController.shared } == true,
                  "history menu actions route through the AppKit controller")
        let attention = agents.submenu?.items.first { $0.identifier?.rawValue == "agent-attention" }
        try check(attention?.keyEquivalent == "a" && attention?.keyEquivalentModifierMask == [.command, .shift],
                  "the native Agents menu preserves the attention command shortcut")
        agents.submenu?.removeAllItems()
        pump(0.05)
        try check(agents.submenu?.items.count == 3,
                  "history actions return after submenu contents are rebuilt")
        agents.submenu = NSMenu(title: agents.title)
        pump(0.05)
        try check(agents.submenu?.items.count == 3,
                  "history actions return after the Agents submenu is replaced")
        main.removeItem(agents)
        pump(0.05)
        try check(main.items.filter { $0.identifier?.rawValue == "zshell-agents-menu" }.count == 1,
                  "the native Agents menu returns after main-menu reconciliation")
    }
}
