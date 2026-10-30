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
                QuickTerminalOffscreen.install()
                defer {
                    AgentConversationHistoryController.shared.close()
                    managers.forEach { $0.windowClosed() }
                    pump(0.5)
                    windows.forEach { $0.contentView = nil; $0.close() }
                    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: app)
                    _ = try? PTYMuxCommandLine.exchange(method: "shutdown")
                }
                AppSettings.shared.terminalBackend = CommandLine.arguments[1].hasSuffix("ghostty") ? .libghostty : .alacritty
                AppSettings.shared.resumeAgentConversations = false
                AppSettings.shared.preserveTerminalSessions = false
                if CommandLine.arguments[1].hasPrefix("native-pi-") { try nativePi() }
                else { try terminals(providerBin: URL(fileURLWithPath: CommandLine.arguments[2])) }
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

    private static func awaitOperation<T>(_ operation: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let task = Task { @MainActor in
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(45)
        while result == nil && Date() < deadline { pump(0.01) }
        guard let result else { task.cancel(); throw HistoryTestFailure.failed("Async history operation timed out") }
        return try result.get()
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
        let fork = try AgentConversationHistoryCommandLine.parse(["fork", "--id", id, "--focus", "--project", id, "--window", id])
        try check(fork.method == "fork" && fork.focus && fork.params["focus"]?.boolValue == true,
                  "fork CLI preserves explicit identity, project, window and focus")
        for values in [["resume", "--id", id, "--all"], ["archive", "--id", id, "--focus"],
                       ["history", "--all", "--archived"], ["history", "--query", "a\nb"],
                       ["history", "--query", String(repeating: "a", count: 1_025)],
                       ["delete"], ["resume", "--id", "latest"], ["history", "--connection", "relative"],
                       ["resume", "--id", id, "--id", id], ["history", "projects", "--project", id],
                       ["fork"], ["fork", "--id", "latest"], ["fork", "--id", id, "--all"]] {
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
        window.identifier = NSUserInterfaceItemIdentifier("main-history-\(UUID())")
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
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
        window.isReleasedWhenClosed = false
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

    private static func runCLI(_ arguments: [String], environment extra: [String: String] = [:],
                               whileRunning: (() -> Void)? = nil) throws -> (status: Int32, output: String, error: String) {
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
        let deadline = Date().addingTimeInterval(45)
        while process.isRunning && Date() < deadline { whileRunning?(); pump(0.01) }
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
        do {
            let siblingURL = descriptorURL.deletingLastPathComponent().appendingPathComponent("other-bundle.json")
            defer { try? fileManager.removeItem(at: siblingURL) }
            var sibling = try JSONSerialization.jsonObject(with: originalDescriptor) as! [String: Any]
            sibling["bundleIdentifier"] = "sh.zshell.other-fixture"
            try PersistentCLIConnection.writePrivate(try JSONSerialization.data(withJSONObject: sibling), to: siblingURL)
            try check(try AgentConversationHistoryConnection.discover(bundleIdentifier: connection.bundleIdentifier).processID == getpid(),
                      "native hooks select their own bundle when Debug and Release descriptors coexist")
            try rejects("native hooks reject a different bundle identifier") {
                _ = try AgentConversationHistoryConnection.discover(bundleIdentifier: "sh.zshell.absent-fixture")
            }
            try rejects("unscoped discovery still rejects several live descriptors") {
                _ = try AgentConversationHistoryConnection.discover()
            }
        }
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
            if provider == .codex {
                project.launchSettings.environmentVariables += [.init(name: "CODEX_THREAD_ID", value: sessionID)]
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
            try forks(manager: manager, project: project, source: session, record: record,
                      sessionFile: sessionFile, providerBin: providerBin)
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
            let expected = provider == .claude ? ["--resume", sessionID] : provider == .codex ? ["resume", sessionID]
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

    private static func forks(manager: TerminalManager, project: Project, source: TerminalSession,
                              record: AgentConversationHistoryRecord, sessionFile: URL, providerBin: URL) throws {
        let store = AgentConversationHistoryStore.shared
        let provider = record.identity.provider
        let sourcePID = source.agentConversationProcessID!
        let original = store.record(id: record.id)!
        let originalFile = provider == .pi ? try Data(contentsOf: sessionFile) : nil
        let previousTab = project.selectedTabID
        let sessions = Set(project.sessions.map(\.id))
        let task = Task { @MainActor in try await manager.forkConversation(id: record.id, in: project, focus: false) }
        try wait("\(provider.rawValue) native fork creates a new terminal") { project.sessions.contains { !sessions.contains($0.id) } }
        let newSession = project.sessions.first { !sessions.contains($0.id) }!
        try check(newSession.agentResume?.sessionID != record.identity.sessionID && newSession.agentConversationHistoryID != record.id,
                  "\(provider.rawValue) pending fork never pre-registers the source")
        attach(newSession)
        let context = try awaitOperation { try await task.value }
        let forked = store.record(id: context.session.agentConversationHistoryID!)!
        let launched = launchInfo(newSession)!
        let expected = provider == .claude ? ["--resume", record.identity.sessionID, "--fork-session"]
            : provider == .codex ? ["fork", record.identity.sessionID]
            : provider == .pi ? ["--fork", sessionFile.path] : ["--session", record.identity.sessionID, "--fork"]
        try check(launched["argv"] as? [String] == expected && record.identity.acceptsFork(forked.identity),
                  "\(provider.rawValue) native argv produces an independent provider identity")
        let launchedPID = (launched["pid"] as? Int).map(pid_t.init)
        try check(launchedPID != nil && launched["pgid"] as? Int == launched["pid"] as? Int
                  && newSession.surface.foregroundPid == launchedPID
                  && ZshellAgentKind(rawValue: provider.rawValue).map(newSession.isAutomationAgentRunning(kind:)) == true
                  && !newSession.isShellAvailableForAutomation,
                  "\(provider.rawValue) native fork runs as the pane's foreground job")
        try check(newSession.startupCommandForTemplate == nil,
                  "\(provider.rawValue) fork argv is not captured as a template startup command")
        try check(forked.id != record.id && forked.terminalID == newSession.id && project.selectedTabID == previousTab,
                  "\(provider.rawValue) fork records a distinct background pane without stealing focus")
        try check(store.record(id: record.id) == original && source.agentConversationProcessID == sourcePID && kill(sourcePID, 0) == 0,
                  "\(provider.rawValue) fork leaves the source record and running process intact")
        let profile = launched["configuration"] as? [String: String]
        try check(profile?[provider.configurationVariable] == record.identity.configDirectory,
                  "\(provider.rawValue) fork restores the original provider profile")
        if provider == .codex {
            try check((launched["inherited_codex_thread"] as? String).map(\.isEmpty) ?? true,
                      "Codex fork does not inherit the source thread ID")
        }
        if let originalFile { try check(try Data(contentsOf: sessionFile) == originalFile, "Pi native fork leaves its source file unchanged") }
        project.closeContent(.session(newSession))

        if provider == .claude {
            try forkControls(manager: manager, project: project, source: source, record: record)
            try AppSettings.shared.setAIEnabled(false)
            try rejects("disabled AI integration rejects native fork before creating a pane") {
                _ = try awaitOperation { try await manager.forkConversation(id: record.id, in: project, focus: false) }
            }
            try AppSettings.shared.setAIEnabled(true)
            let unsupported = fixtureRoot.appendingPathComponent("unsupported-fork")
            try Data().write(to: unsupported)
            let before = project.sessions.count
            try rejects("old provider CLI fails before creating a pane") {
                _ = try awaitOperation { try await manager.forkConversation(id: record.id, in: project, focus: false) }
            }
            try check(project.sessions.count == before && kill(sourcePID, 0) == 0, "unsupported fork keeps the source and pane count intact")
            try fileManager.removeItem(at: unsupported)
            let slow = fixtureRoot.appendingPathComponent("slow-fork-help")
            try Data().write(to: slow)
            try rejects("native fork capability check is bounded") {
                _ = try awaitOperation { try await TerminalManager.validateConversationFork(record.identity, launchSettings: project.launchSettings, timeout: 0.2) }
            }
            try fileManager.removeItem(at: slow)

            let paneEnvironment = ZshellCLIService.shared.terminalEnvironment(for: source.id)
            var scopedSession: TerminalSession?
            let response = try runCLI(["+agent", "fork", "--id", record.id.uuidString], environment: paneEnvironment) {
                if scopedSession == nil, let created = project.sessions.first(where: { $0 !== source }) {
                    scopedSession = created
                    attach(created)
                }
            }
            let value = try json(response.output).objectValue
            try check(response.status == 0 && value?["source_id"]?.stringValue == record.id.uuidString
                      && value?["id"]?.stringValue != record.id.uuidString && value?["terminal_id"]?.stringValue == scopedSession?.id.uuidString,
                      "scoped CLI reports the confirmed new history record and source ID")
            project.closeContent(.session(scopedSession!))
            var externalSession: TerminalSession?
            let external = try runCLI(["+agent", "fork", "--project", project.conversationHistoryProjectID.uuidString,
                                       "--id", record.id.uuidString, "--window", manager.conversationHistoryWindowID.uuidString]) {
                if externalSession == nil, let created = project.sessions.first(where: { $0 !== source }) {
                    externalSession = created
                    attach(created)
                }
            }
            try check(external.status == 0 && (try json(external.output)).objectValue?["terminal_id"]?.stringValue == externalSession?.id.uuidString,
                      "external CLI fork preserves explicit project and window scope")
            project.closeContent(.session(externalSession!))

            project.launchSettings.environmentVariables.append(.init(name: "HISTORY_TEST_NO_FORK_HOOK", value: "1"))
            let pending = Task { @MainActor in try await manager.forkConversation(id: record.id, in: project, focus: false, timeout: 0.5) }
            try wait("unconfirmed fork creates an inspectable pane") { project.sessions.count > before }
            let pendingSession = project.sessions.first { $0 !== source }!
            attach(pendingSession)
            try rejects("an unconfirmed native fork never reports success") { _ = try awaitOperation { try await pending.value } }
            try check(pendingSession.agentResume == nil && pendingSession.agentConversationHistoryID == nil
                      && store.record(id: record.id) == original && kill(sourcePID, 0) == 0,
                      "an unconfirmed fork keeps a separate pane without rebinding source history")
            try Data().write(to: fixtureRoot.appendingPathComponent("stop-\(pendingSession.id)"))
            try wait("an unconfirmed fork's exit retires its source restriction") {
                pendingSession.refreshAgentConversationHistory()
                return pendingSession.agentConversationForkSource == nil
            }
            try check(!pendingSession.hasExited, "an exited unconfirmed fork leaves its fallback shell")
            project.closeContent(.session(pendingSession))
            project.launchSettings.environmentVariables.removeAll { $0.name == "HISTORY_TEST_NO_FORK_HOOK" }

            let cancelled = Task { @MainActor in try await manager.forkConversation(id: record.id, in: project, focus: false) }
            cancelled.cancel()
            try rejects("cancelled fork does not create a pane") { _ = try awaitOperation { try await cancelled.value } }
            try check(project.sessions.count == before, "cancellation preserves topology")
        }
        if provider == .pi {
            try fileManager.removeItem(at: sessionFile)
            defer { if let originalFile { try? originalFile.write(to: sessionFile) } }
            let count = project.sessions.count
            try rejects("Pi missing source file fails before creating a fork pane") {
                _ = try awaitOperation { try await manager.forkConversation(id: record.id, in: project, focus: false) }
            }
            try check(project.sessions.count == count, "missing Pi source preserves pane topology")
        }
    }

    private static func nativePi() throws {
        let environment = ProcessInfo.processInfo.environment
        let pi = environment["HISTORY_TEST_NATIVE_PI"]!
        let sourceFile = URL(fileURLWithPath: environment["HISTORY_TEST_SESSION_FILE"]!)
        try ZshellAgentIntegrations.installAvailable()
        let store = AgentConversationHistoryStore.shared
        let (manager, project) = newManager()
        guard let source = project.newSession(directory: fixtureRoot.path,
            commandArguments: [pi, "--session", sourceFile.path]) else {
            throw HistoryTestFailure.failed("The native Pi source pane did not start")
        }
        attach(source)
        try wait("installed Pi TUI reports its native session through the production integration", timeout: 20) {
            source.agentResume?.sessionID == environment["HISTORY_TEST_SESSION"]
                && source.agentConversationOwner?.isAlive == true
        }
        let sourceIdentity = source.agentResume!
        let original = try Data(contentsOf: sourceFile)
        let record = store.record(id: source.agentConversationHistoryID!)!
        let sourcePID = source.agentConversationProcessID!
        let previousTab = project.selectedTabID
        let before = Set(project.sessions.map(\.id))
        let operation = Task { @MainActor in
            try await manager.forkConversation(id: record.id, in: project, focus: false)
        }
        try wait("installed Pi native fork creates its own pane") {
            project.sessions.contains { !before.contains($0.id) }
        }
        let forked = project.sessions.first { !before.contains($0.id) }!
        attach(forked)
        let context = try awaitOperation { try await operation.value }
        let forkIdentity = context.session.agentResume!
        try check(sourceIdentity.acceptsFork(forkIdentity) && context.session === forked,
            "actual Pi TUI confirms an independent session ID and file")
        let sourceEntries = String(decoding: original, as: UTF8.self).split(separator: "\n")
            .map { Data($0.utf8) }
        let forkEntries = try Data(contentsOf: URL(fileURLWithPath: forkIdentity.sessionFile!))
        let forkLines = String(decoding: forkEntries, as: UTF8.self).split(separator: "\n").map { Data($0.utf8) }
        let retained = try zip(sourceEntries.dropFirst(), forkLines.dropFirst()).allSatisfy {
            let source = try JSONSerialization.jsonObject(with: $0.0) as! NSDictionary
            let fork = try JSONSerialization.jsonObject(with: $0.1) as! NSDictionary
            return source.isEqual(fork)
        }
        try check(forkLines.count >= sourceEntries.count && retained,
            "actual Pi pane retains native tree entries, thinking, tools and extension data")
        let sourceData = try Data(contentsOf: sourceFile)
        try check(sourceData == original && source.agentResume == sourceIdentity
            && source.agentConversationProcessID == sourcePID && kill(sourcePID, 0) == 0
            && store.record(id: record.id) == record,
            "actual Pi fork preserves the original conversation file, binding and running TUI")
        try check(project.selectedTabID == previousTab && store.record(id: forked.agentConversationHistoryID!)?.id != record.id,
            "actual Pi background fork keeps selection and owns a separate history record")
        try check(QuickTerminalOffscreen.isSafe(), "actual Pi TUI probes stay offscreen and preserve user focus")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func historyControls(manager: TerminalManager, record: AgentConversationHistoryRecord)
        throws -> (panel: NSWindow, table: NSTableView, button: NSButton, menu: NSMenu) {
        manager.showConversationHistory(all: true)
        guard let panel = NSApp.windows.first(where: { $0.identifier?.rawValue == "agent-conversation-history" }),
              let content = panel.contentView,
              let search = descendants(content).compactMap({ $0 as? NSSearchField }).first,
              let table = descendants(content).compactMap({ $0 as? NSTableView }).first,
              let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: {
                  $0.accessibilityLabel() == String(localized: "Fork Conversation in New Pane")
              }), let menu = table.menu else {
            throw HistoryTestFailure.failed("The AppKit fork controls are missing")
        }
        search.stringValue = record.identity.sessionID
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try check(table.numberOfRows == 1 && button.isEnabled, "AppKit history selects the exact source conversation")
        return (panel, table, button, menu)
    }

    private static func forkControls(manager: TerminalManager, project: Project, source: TerminalSession,
                                     record: AgentConversationHistoryRecord) throws {
        let store = AgentConversationHistoryStore.shared
        let original = store.record(id: record.id)!
        let sourcePID = source.agentConversationProcessID!
        for useMenu in [false, true] {
            let controls = try historyControls(manager: manager, record: record)
            let sessions = Set(project.sessions.map(\.id))
            if useMenu {
                controls.table.deselectAll(nil)
                controls.menu.update()
                try check(!controls.menu.items[0].isEnabled, "AppKit fork context menu rejects empty selection")
                controls.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                controls.menu.update()
                try check(controls.menu.items[0].isEnabled, "AppKit fork context menu validates the selected conversation")
                controls.menu.performActionForItem(at: 0)
            } else { controls.button.performClick(nil) }
            controls.menu.update()
            try check(!controls.button.isEnabled && !controls.menu.items[0].isEnabled,
                      "AppKit disables repeated fork actions while native launch is pending")
            _ = NSApp.sendAction(controls.table.doubleAction!, to: controls.table.target, from: controls.table)
            try check(controls.panel.isVisible && project.sessions.count <= sessions.count + 1,
                      "AppKit double-click resume cannot interrupt a pending fork")
            try wait("AppKit \(useMenu ? "context menu" : "branch button") creates a fork pane") {
                project.sessions.contains { !sessions.contains($0.id) }
            }
            let session = project.sessions.first { !sessions.contains($0.id) }!
            attach(session)
            try wait("AppKit fork waits for an independent identity before closing history") {
                session.agentConversationHistoryID != nil && !controls.panel.isVisible
            }
            try check(record.identity.acceptsFork(session.agentResume!)
                      && project.selectedSession === session && source.agentConversationProcessID == sourcePID
                      && store.record(id: record.id) == original && kill(sourcePID, 0) == 0,
                      "AppKit fork focuses the new conversation and preserves the live source")
            project.closeContent(.session(session))
        }

        project.launchSettings.environmentVariables.append(.init(name: "HISTORY_TEST_NO_FORK_HOOK", value: "1"))
        let pendingControls = try historyControls(manager: manager, record: record)
        let sessions = Set(project.sessions.map(\.id))
        pendingControls.button.performClick(nil)
        try wait("AppKit cancellable fork creates an inspectable pane") {
            project.sessions.contains { !sessions.contains($0.id) }
        }
        let pending = project.sessions.first { !sessions.contains($0.id) }!
        attach(pending)
        try wait("unconfirmed AppKit fixture reports its source hook") { launchInfo(pending) != nil }
        AgentConversationHistoryController.shared.close(ifOwnedBy: manager)
        project.launchSettings.environmentVariables.removeAll { $0.name == "HISTORY_TEST_NO_FORK_HOOK" }
        let nextControls = try historyControls(manager: manager, record: record)
        let nextSessions = Set(project.sessions.map(\.id))
        let hookGate = fixtureRoot.appendingPathComponent("pause-fork-hook")
        try Data().write(to: hookGate)
        defer { try? fileManager.removeItem(at: hookGate) }
        nextControls.button.performClick(nil)
        pump(0.2)
        try check(!nextControls.button.isEnabled && nextControls.panel.isVisible,
                  "a cancelled AppKit callback cannot clear a newly reopened fork operation")
        try wait("reopened AppKit fork creates its own pane") {
            project.sessions.contains { !nextSessions.contains($0.id) }
        }
        let next = project.sessions.first { !nextSessions.contains($0.id) }!
        attach(next)
        try wait("reopened AppKit fork reaches the native hook gate") { launchInfo(next) != nil }
        try fileManager.removeItem(at: hookGate)
        try wait("reopened AppKit fork confirms its independent identity") {
            next.agentConversationHistoryID != nil && !nextControls.panel.isVisible
        }
        try check(pending.agentConversationHistoryID == nil && pending.agentResume == nil
                  && store.record(id: record.id) == original && kill(sourcePID, 0) == 0,
                  "closing history cancels confirmation without rebinding source history")
        project.closeContent(.session(pending))
        project.closeContent(.session(next))
        try check(QuickTerminalOffscreen.isSafe(), "AppKit fork probes stay offscreen and preserve user focus")
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
        // Mirror the app's leading application and File menus; other
        // controllers install their own commands into File, not Agents.
        for title in ["zshell", "File"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            main.addItem(item)
        }
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
