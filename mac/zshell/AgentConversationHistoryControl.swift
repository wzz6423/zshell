import AppKit
import Darwin
import Foundation

struct AgentConversationHistoryConnection: Codable {
    let version: Int
    let userID: uid_t
    let processID: pid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let bundleIdentifier: String
    let socketPath: String
    let token: String

    var processIsCurrent: Bool {
        guard let process = ZshellAgentProcessIdentity(pid: processID) else { return false }
        return process.startedSeconds == startedSeconds && process.startedMicroseconds == startedMicroseconds
    }

    static func load(from url: URL) throws -> Self {
        try PersistentCLIConnection.verifyPrivateDirectory(url.deletingLastPathComponent())
        let connection = try JSONDecoder().decode(Self.self, from: PersistentCLIConnection.readPrivate(url))
        var metadata = stat()
        guard connection.version == 1, connection.userID == geteuid(), connection.processIsCurrent,
              connection.token.utf8.count == 72, connection.socketPath.hasPrefix("/tmp/zshell-history-"),
              lstat(connection.socketPath, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o600 else {
            throw CLIError.message("The history control connection is invalid or expired.")
        }
        return connection
    }

    static func discover() throws -> Self {
        let directory = AgentConversationHistoryPaths.connectionsURL
        try PersistentCLIConnection.verifyPrivateDirectory(directory)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let connections = urls.compactMap { try? load(from: $0) }
        guard connections.count == 1, let connection = connections.first else {
            throw CLIError.message(connections.isEmpty
                ? "Open Zshell before using conversation history from an external terminal."
                : "Several Zshell instances are running. Select an owner-only descriptor with --connection PATH in \(directory.path).")
        }
        return connection
    }

    func request(method: String, params: [String: ZshellJSONValue]) throws -> ZshellJSONValue {
        guard processIsCurrent else { throw CLIError.message("The history control connection has expired.") }
        let request = ZshellAutomationRequest(
            version: 1, id: UUID().uuidString, method: method, token: token, terminalID: "", params: params
        )
        let response = try ZshellAutomationSocketServer.exchange(
            path: socketPath, request: request, expectedPeerProcessID: processID
        )
        guard response.version == 1, response.id == request.id else {
            throw CLIError.message("Zshell returned a mismatched history response.")
        }
        guard response.ok, let value = response.result else {
            throw CLIError.message("\(response.error?.code ?? "history_error"): \(response.error?.message ?? "Zshell rejected the history request.")")
        }
        return value
    }
}

@MainActor
final class AgentConversationHistoryControlService {
    static let shared = AgentConversationHistoryControlService()
    private var server: ZshellAutomationSocketServer?
    private var descriptorURL: URL?
    private var terminationObserver: NSObjectProtocol?
    private let token = UUID().uuidString + UUID().uuidString

    private init() {
        do {
            try AgentConversationHistoryPaths.prepare()
            try PersistentCLIConnection.preparePrivateDirectory(AgentConversationHistoryPaths.connectionsURL)
            let pid = getpid()
            guard let identity = ZshellAgentProcessIdentity(pid: pid) else {
                throw CLIError.message("Could not identify the history control process.")
            }
            let socketPath = "/tmp/zshell-history-\(geteuid())-\(pid)-\(UUID().uuidString.prefix(8)).sock"
            server = try ZshellAutomationSocketServer(path: socketPath) { [weak self] request, reply in
                Task { @MainActor [weak self] in
                    guard let self else {
                        reply(.failure(id: request.id, code: "unavailable", message: "History control is unavailable."))
                        return
                    }
                    reply(self.handle(request))
                }
            }
            let descriptor = AgentConversationHistoryConnection(
                version: 1, userID: geteuid(), processID: pid,
                startedSeconds: identity.startedSeconds, startedMicroseconds: identity.startedMicroseconds,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "zshell", socketPath: socketPath, token: token
            )
            let url = AgentConversationHistoryPaths.connectionsURL.appendingPathComponent("\(pid).json")
            try PersistentCLIConnection.writePrivate(try JSONEncoder().encode(descriptor), to: url)
            descriptorURL = url
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        } catch {
            server = nil
            NSLog("zshell: could not start conversation history control: \(error)")
        }
    }

    private func handle(_ request: ZshellAutomationRequest) -> ZshellAutomationResponse {
        guard request.version == 1, request.terminalID.isEmpty, request.token == token,
              let peer = request.peerProcessID else {
            return .failure(id: request.id, code: "unauthorized", message: "The history control capability is invalid or expired.")
        }
        // Scrubbing inherited variables must not give an in-pane agent the
        // user's cross-project history capability.
        guard !Self.isManagedTerminalProcess(peer) else {
            return .failure(id: request.id, code: "project_scope_required",
                            message: "Processes inside Zshell terminals must use their project-scoped automation capability.")
        }
        return AgentConversationHistoryRouter.external(request)
    }

    static func isManagedTerminalProcess(_ pid: pid_t) -> Bool {
        AgentAutomationMonitor.shared.ownsTerminalProcess(pid)
    }

    private func stop() {
        server = nil
        if let descriptorURL { try? FileManager.default.removeItem(at: descriptorURL) }
        descriptorURL = nil
    }
}

@MainActor
enum AgentConversationHistoryRouter {
    static func scoped(
        _ request: ZshellAutomationRequest, caller: ZshellAutomationRouter.PaneContext
    ) -> ZshellAutomationResponse {
        do {
            let method = String(request.method.dropFirst("agent.history.".count))
            if method == "projects" {
                guard request.params.isEmpty else { throw CLIError.message("history projects takes no project target inside a pane.") }
                return .success(id: request.id, result: projects(only: caller.project))
            }
            guard request.params["project_id"] == nil, request.params["window_id"] == nil else {
                throw CLIError.message("In-pane history operations cannot select another project or window.")
            }
            return try operate(request, method: method, manager: caller.manager, project: caller.project,
                               projectID: caller.project.conversationHistoryProjectID)
        } catch { return failure(request, error) }
    }

    static func external(_ request: ZshellAutomationRequest) -> ZshellAutomationResponse {
        do {
            guard request.method.hasPrefix("history.") else { throw CLIError.message("Unknown history control method.") }
            let method = String(request.method.dropFirst("history.".count))
            if method == "projects" {
                guard request.params.isEmpty else { throw CLIError.message("history projects takes no project target.") }
                return .success(id: request.id, result: projects())
            }
            guard let value = request.params["project_id"]?.stringValue, let projectID = UUID(uuidString: value) else {
                throw CLIError.message("External history operations require an explicit --project UUID from history projects.")
            }
            let candidates = TerminalManager.automationManagers.flatMap { manager in
                manager.projects.filter { !$0.isRemote && $0.conversationHistoryProjectID == projectID }
                    .map { (manager: manager, project: $0) }
            }
            let requestedWindow: UUID?
            if let window = request.params["window_id"] {
                guard let text = window.stringValue, let id = UUID(uuidString: text) else {
                    throw CLIError.message("--window must be a window UUID from history projects.")
                }
                requestedWindow = id
            } else { requestedWindow = nil }
            let selected = candidates.filter { requestedWindow == nil || $0.manager.conversationHistoryWindowID == requestedWindow }
            guard selected.count <= 1 else { throw CLIError.message("This history project is open in several windows. Select --window UUID.") }
            if !candidates.isEmpty, selected.isEmpty { throw AgentConversationHistoryError.differentProject }
            let manager = selected.first?.manager ?? TerminalManager.automationManagers.first(where: {
                $0.presentationWindow != nil && (requestedWindow == nil || $0.conversationHistoryWindowID == requestedWindow)
            })
            guard candidates.count > 0 || AgentConversationHistoryStore.shared.records.contains(where: { $0.projectID == projectID }) else {
                throw AgentConversationHistoryError.notFound
            }
            return try operate(request, method: method, manager: manager, project: selected.first?.project, projectID: projectID)
        } catch { return failure(request, error) }
    }

    private static func operate(
        _ request: ZshellAutomationRequest, method: String,
        manager: TerminalManager?, project: Project?, projectID: UUID
    ) throws -> ZshellAutomationResponse {
        let store = AgentConversationHistoryStore.shared
        let targeting: Set<String> = method == "resume" ? ["project_id", "window_id"] : ["project_id"]
        if method == "list" {
            guard Set(request.params.keys).isSubset(of: targeting.union(["query", "filter"])) else {
                throw CLIError.message("Unknown history list parameter.")
            }
            guard request.params["query"].map({ $0.stringValue != nil }) ?? true,
                  request.params["filter"].map({ $0.stringValue != nil }) ?? true else {
                throw CLIError.message("History query and filter must be strings.")
            }
            let query = request.params["query"]?.stringValue ?? ""
            guard query.utf8.count <= 1_024,
                  !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw CLIError.message("History search must be control-free and at most 1024 UTF-8 bytes.")
            }
            let filterName = request.params["filter"]?.stringValue ?? "recent"
            let filter: AgentConversationHistoryStore.Filter
            switch filterName {
            case "recent": filter = .recent
            case "all": filter = .all
            case "archived": filter = .archived
            default: throw CLIError.message("History filter must be recent, all, or archived.")
            }
            return .success(id: request.id, result: .object([
                "project_id": .string(projectID.uuidString), "filter": .string(filterName),
                "records": .array(store.search(query, filter: filter, projectID: projectID).map(recordJSON)),
                "maximum_records": .number(Double(AgentConversationHistoryStore.maximumRecords)),
            ]))
        }
        let options: Set<String> = method == "resume" ? ["id", "focus"] : ["id"]
        guard Set(request.params.keys).isSubset(of: targeting.union(options)) else {
            throw CLIError.message("Unknown history operation parameter.")
        }
        guard request.params["focus"].map({ $0.boolValue != nil }) ?? true else {
            throw CLIError.message("History focus must be a boolean.")
        }
        guard
              let value = request.params["id"]?.stringValue, let id = UUID(uuidString: value),
              let record = store.record(id: id, projectID: projectID) else {
            throw AgentConversationHistoryError.notFound
        }
        switch method {
        case "archive", "unarchive":
            try store.setArchived(method == "archive", id: id, projectID: projectID)
            guard let updated = store.record(id: id) else { throw AgentConversationHistoryError.notFound }
            return .success(id: request.id, result: recordJSON(updated))
        case "delete":
            try store.delete(id: id, projectID: projectID)
            return .success(id: request.id, result: .object(["id": .string(id.uuidString), "deleted": .bool(true)]))
        case "resume":
            guard let manager else { throw AgentConversationHistoryError.noWindow }
            let focus = request.params["focus"]?.boolValue ?? false
            let result = try manager.resumeConversation(id: id, in: project, focus: focus)
            let context = result.context
            return .success(id: request.id, result: .object([
                "id": .string(record.id.uuidString), "action": .string(result.action),
                "terminal_id": .string(context.session.id.uuidString),
                "project_id": .string(context.project.conversationHistoryProjectID.uuidString),
                "live_project_id": .string(context.project.id.uuidString),
                "window_id": .string(context.manager.conversationHistoryWindowID.uuidString),
                "reconnected": .bool(context.session.reconnectedToPersistentPTY),
            ]))
        default: throw CLIError.message("Unknown history operation.")
        }
    }

    static func recordJSON(_ record: AgentConversationHistoryRecord) -> ZshellJSONValue {
        let date = ISO8601DateFormatter()
        let live = TerminalManager.openConversation(record)
        return .object([
            "id": .string(record.id.uuidString), "provider": .string(record.identity.provider.rawValue),
            "session_id": .string(record.identity.sessionID), "project_id": .string(record.projectID.uuidString),
            "project_name": .string(record.projectName), "title": .string(record.displayTitle),
            "cwd": .string(record.identity.workingDirectory),
            "config_directory": record.identity.configDirectory.map(ZshellJSONValue.string) ?? .null,
            "configuration_environment": .object((record.identity.configurationEnvironment ?? [:]).mapValues(ZshellJSONValue.string)),
            "session_file": record.identity.sessionFile.map(ZshellJSONValue.string) ?? .null,
            "alias": record.identity.alias.map(ZshellJSONValue.string) ?? .null,
            "started_at": .string(date.string(from: record.startedAt)),
            "updated_at": .string(date.string(from: record.updatedAt)),
            "ended_at": record.endedAt.map { .string(date.string(from: $0)) } ?? .null,
            "archived": .bool(record.isArchived), "running": .bool(live != nil),
            "terminal_id": live.map { .string($0.session.id.uuidString) } ?? .null,
        ])
    }

    private static func projects(only project: Project? = nil) -> ZshellJSONValue {
        let store = AgentConversationHistoryStore.shared
        let live = TerminalManager.automationManagers.flatMap { manager in
            manager.projects.filter { !$0.isRemote && (project == nil || $0 === project) }.map { (manager, $0) }
        }
        let ids = Set(live.map { $0.1.conversationHistoryProjectID })
            .union(store.records.filter { project == nil || $0.projectID == project?.conversationHistoryProjectID }.map(\.projectID))
        return .array(ids.sorted { $0.uuidString < $1.uuidString }.map { id in
            let entries = live.filter { $0.1.conversationHistoryProjectID == id }
            let record = store.records.first { $0.projectID == id }
            return .object([
                "project_id": .string(id.uuidString),
                "name": .string(entries.first?.1.name ?? record?.projectName ?? ""),
                "cwd": entries.first?.1.customDirectory.map(ZshellJSONValue.string)
                    ?? record.map { .string($0.identity.workingDirectory) } ?? .null,
                "records": .number(Double(store.records.filter { $0.projectID == id }.count)),
                "windows": .array(entries.map { .object([
                    "window_id": .string($0.0.conversationHistoryWindowID.uuidString),
                    "live_project_id": .string($0.1.id.uuidString),
                ]) }),
            ])
        })
    }

    private static func failure(_ request: ZshellAutomationRequest, _ error: any Error) -> ZshellAutomationResponse {
        .failure(id: request.id, code: error is AgentConversationHistoryError ? "history_unavailable" : "invalid_params",
                 message: (error as? AgentConversationHistoryError)?.errorDescription ?? String(describing: error))
    }
}
