"""Exercise production session CLI, owner-only control, routing, and pane snapshots."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
snapshot = (ROOT / "mac/zshell/SessionStore.swift").read_text()
content = snapshot[snapshot.index("        enum PaneContentSnapshot:"):
                   snapshot.index("        struct ColumnSnapshot:")]
identity = (ROOT / "mac/zshell/AgentStatusReporting.swift").read_text()
identity = identity[identity.index("struct ZshellAgentProcessIdentity:"):
                    identity.index("struct ZshellAgentReport:")]

fixture = r'''
import AppKit
import Darwin
import Foundation

enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let value): value } }
}
struct EditorState: Codable {}
struct AgentConversationIdentity: Codable { let id: String }
struct SessionSnapshot { struct ProjectSnapshot {
SNAPSHOT
} }
IDENTITY
enum PersistentCLIConnection {
    static func resolvedEnvironment(_ value: [String: String]) throws -> [String: String] { value }
}
struct AppConnection {
    init(environment: [String: String]) throws {}
    func automationRequest(method: String, params: [String: ZshellJSONValue], timeout: TimeInterval) throws -> ZshellJSONValue {
        throw CLIError.message("unused terminal connection")
    }
}
@MainActor final class TerminalSession {
    let id = UUID()
    var shellPid: pid_t?
    var hasExited = false
    var worktree: SessionWorktree?
    init(shellPid: pid_t? = nil) { self.shellPid = shellPid }
    func waitUntilStarted() async -> Bool { true }
}
enum PaneContent { case session(TerminalSession) }
@MainActor final class Project {
    let id = UUID()
    var name = "Fixture"
    var isRemote = false
    var selectedTabID: UUID?
    var sessions: [TerminalSession] = []
    func newSession(directory: String? = nil, commandArguments: [String]? = nil, environmentPath: String? = nil) -> TerminalSession? {
        let session = TerminalSession()
        sessions.append(session)
        selectedTabID = session.id
        return session
    }
    func closeContent(_ content: PaneContent, confirmWorktree: Bool, recordClosedSession: Bool = true) {
        if case .session(let session) = content { sessions.removeAll { $0.id == session.id } }
    }
}
@MainActor final class TerminalManager {
    static var automationManagers: [TerminalManager] = []
    var projects: [Project] = []
    var selectedProjectID: UUID?
    static func worktreeIsInUse(_ path: String, excluding id: UUID? = nil) -> Bool { false }
    func newWorktreeSession(in project: Project, branch: String, directory: String?, sourceDirectory: String?,
                           base: SessionWorktreeService.Base, commandArguments: [String]?, environmentPath: String?, focus: Bool) async throws -> TerminalSession {
        fatalError("worktree mutations are covered by the real-repository probe")
    }
    func closeWorktreeSession(_ session: TerminalSession, in project: Project, removeWorktree: Bool) async throws -> Bool {
        project.sessions.removeAll { $0.id == session.id }
        return false
    }
}
@MainActor enum ZshellAutomationRouter {
    struct PaneContext { let session: TerminalSession }
    static func context(forSession id: UUID) -> PaneContext? {
        TerminalManager.automationManagers.flatMap(\.projects).flatMap(\.sessions)
            .first(where: { $0.id == id }).map { PaneContext(session: $0) }
    }
    static func paneSnapshot(_ context: PaneContext, caller: PaneContext?) -> ZshellJSONValue {
        .object(["terminal_id": .string(context.session.id.uuidString),
                 "is_caller": .bool(context.session.id == caller?.session.id)])
    }
}

@main @MainActor struct SessionControlProbe {
    static var checks = 0
    static var failures = 0
    static func check(_ passed: Bool, _ name: String) {
        checks += 1
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") \(name)")
    }
    static func rejects(_ name: String, _ operation: () throws -> Void) {
        do { try operation(); check(false, name) }
        catch { check(true, name) }
    }
    static func request(_ method: String, project: UUID? = nil, params: [String: ZshellJSONValue] = [:], peer: pid_t? = nil) -> ZshellAutomationRequest {
        var values = params
        if let project { values["project_id"] = .string(project.uuidString) }
        return ZshellAutomationRequest(version: 1, id: UUID().uuidString, method: method, token: "fixture",
                                       terminalID: ZshellSessionControlConnection.callerID,
                                       params: values, peerProcessID: peer)
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        let id = UUID()
        let parsed = try ZshellSessionCommandLine.parse(["new", "--project", id.uuidString.lowercased(), "--branch", "feature/one",
            "--worktree", "../checkout", "--base", "HEAD", "--focus", "--", "/bin/echo", "two words"], cwd: root.path)
        check(parsed.projectID == id.uuidString && parsed.branch == "feature/one" && parsed.base == "HEAD", "CLI preserves the branch and baseline and normalizes project identity")
        check(parsed.worktreePath == root.deletingLastPathComponent().appendingPathComponent("checkout").path,
              "CLI resolves an explicit relative worktree path")
        check(parsed.arguments == ["/bin/echo", "two words"] && parsed.focus, "CLI keeps argv boundaries and explicit focus")
        let close = try ZshellSessionCommandLine.parse(["close", "--session", id.uuidString])
        check(!close.removeWorktree, "CLI defaults to keeping the worktree")
        check(try ZshellSessionCommandLine.parse(["close", "--session", id.uuidString, "--remove-worktree"]).removeWorktree,
              "CLI cleanup requires an explicit close action")
        for values in [["new", "--worktree", "/tmp/new"], ["new", "--branch", "x", "--base"],
                       ["new", "--focus", "--no-focus"], ["new", "--branch", "x", "--branch", "y"],
                       ["new", "--project", "bad"], ["list", "--cwd", "/tmp"], ["check"],
                       ["close", "--session", id.uuidString, "--keep-worktree", "--remove-worktree"],
                       ["projects", "--project", id.uuidString], ["new", "--"], ["new", "--unknown"]] {
            rejects("CLI refuses invalid options: \(values.joined(separator: " "))") { _ = try ZshellSessionCommandLine.parse(values) }
        }

        let worktree = SessionWorktree(path: "/fixture/worktree", repositoryRoot: "/fixture/repo", commonGitDirectory: "/fixture/repo/.git",
            gitDirectory: "/fixture/repo/.git/worktrees/worktree", branch: "feature", baseReference: "refs/heads/main", createdBranch: true, initialHead: "abc")
        let pane = SessionSnapshot.ProjectSnapshot.PaneSnapshot(content: .session(workingDirectory: worktree.path), weight: 1,
            historyKey: "history", terminalID: id, worktree: worktree)
        let data = try JSONEncoder().encode(pane)
        let restored = try JSONDecoder().decode(SessionSnapshot.ProjectSnapshot.PaneSnapshot.self, from: data)
        check(restored.worktree == worktree && restored.terminalID == id, "full production pane snapshot restores worktree association and terminal identity")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "worktree")
        let legacy = try JSONDecoder().decode(SessionSnapshot.ProjectSnapshot.PaneSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        check(legacy.worktree == nil && legacy.terminalID == id, "older pane snapshots still decode")
        object["worktree"] = ["bad": "metadata"]
        let corrupt = try JSONDecoder().decode(SessionSnapshot.ProjectSnapshot.PaneSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        check(corrupt.worktree == nil && corrupt.historyKey == "history", "invalid worktree metadata does not discard the pane or history")

        let manager = TerminalManager()
        let first = Project(), second = Project()
        let owned = TerminalSession(shellPid: getpid())
        first.sessions = [owned]
        manager.projects = [first, second]
        TerminalManager.automationManagers = [manager]
        let scoped = await ZshellSessionAutomationRouter.routeExternal(request("session.projects", peer: getpid()))
        check(scoped.result?.arrayValue?.count == 1, "a pane process clearing its environment still sees only its own project")
        let refused = await ZshellSessionAutomationRouter.routeExternal(request("session.new", project: second.id, peer: getpid()))
        check(!refused.ok && refused.error?.code == "project_scope_violation" && second.sessions.isEmpty,
              "a pane process cannot reach another project through external discovery")
        let external = await ZshellSessionAutomationRouter.routeExternal(request("session.projects", peer: getppid()))
        check(external.result?.arrayValue?.count == 2, "a real external process can discover open project IDs")
        let noProject = await ZshellSessionAutomationRouter.routeExternal(request("session.list", peer: getppid()))
        check(!noProject.ok && noProject.error?.code == "project_required", "external control requires an explicit project")
        let new = await ZshellSessionAutomationRouter.routeExternal(request("session.new", project: second.id, peer: getppid()))
        check(new.ok && second.sessions.count == 1 && first.sessions.count == 1, "external new session targets only the explicitly selected project")
        check(new.result?.objectValue?["is_caller"]?.boolValue == false, "external creation does not mark its new session as the caller")
        let ownList = await ZshellSessionAutomationRouter.routeExternal(request("session.list", project: first.id, peer: getpid()))
        check(ownList.result?.arrayValue?.first?.objectValue?["is_caller"]?.boolValue == true, "cleared-environment pane commands retain their calling session identity")
        let externalList = await ZshellSessionAutomationRouter.routeExternal(request("session.list", project: first.id, peer: getppid()))
        check(externalList.result?.arrayValue?.first?.objectValue?["is_caller"]?.boolValue == false, "external listing has no calling terminal")
        let noPeer = await ZshellSessionAutomationRouter.routeExternal(request("session.projects"))
        check(!noPeer.ok && noPeer.error?.code == "invalid_external_caller", "external control refuses missing kernel credentials")
        let paneRead = await ZshellSessionAutomationRouter.routeExternal(request("pane.read", project: second.id, peer: getppid()))
        check(!paneRead.ok && paneRead.error?.code == "method_not_found", "external session capability cannot read or write panes")
        let invalid = await ZshellSessionAutomationRouter.route(request("session.new", params: ["branch": .bool(true)]), manager: manager, project: first)
        check(!invalid.ok && invalid.error?.code == "invalid_params", "typed session API refuses malformed branch values")

        let socketPath = root.appendingPathComponent("control.sock").path
        let token = UUID().uuidString + UUID().uuidString
        let server = try ZshellAutomationSocketServer(path: socketPath) { request, reply in
            if request.token != token { reply(.failure(id: request.id, code: "unauthorized", message: "invalid token")); return }
            Task { @MainActor in reply(await ZshellSessionAutomationRouter.routeExternal(request)) }
        }
        let manifestURL = try ZshellSessionControlConnection.publish(socketPath: socketPath, token: token)
        let connection = try ZshellSessionControlConnection(connectionURL: manifestURL)
        check(connection.manifest.processID == getpid(), "owner-only manifest identifies the running controller")
        let wireResult = try? await Task.detached {
            try connection.request(method: "session.new", params: ["project_id": .string(second.id.uuidString)])
        }.value
        check(wireResult == nil && second.sessions.count == 1, "socket kernel PID defeats the cleared-environment cross-project escape")
        let spoof = request("session.new", project: second.id, peer: getppid())
        let encoded = try JSONEncoder().encode(spoof)
        check(!String(decoding: encoded, as: UTF8.self).contains("peerProcessID"), "caller-supplied peer PID is excluded from the wire protocol")
        rejects("external client refuses non-session methods") { _ = try connection.request(method: "pane.read", params: [:]) }
        _ = chmod(manifestURL.path, 0o644)
        rejects("world-readable connection token is refused") { _ = try ZshellSessionControlConnection(connectionURL: manifestURL) }
        _ = chmod(manifestURL.path, 0o600)
        _ = chmod(manifestURL.deletingLastPathComponent().path, 0o755)
        rejects("non-private connection directory is refused") { _ = try ZshellSessionControlConnection(connectionURL: manifestURL) }
        _ = chmod(manifestURL.deletingLastPathComponent().path, 0o700)
        _ = chmod(socketPath, 0o666)
        rejects("non-private session socket is refused") { _ = try ZshellSessionControlConnection(connectionURL: manifestURL) }
        _ = chmod(socketPath, 0o600)
        let link = manifestURL.deletingLastPathComponent().appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: manifestURL)
        rejects("symlinked connection token is refused") { _ = try ZshellSessionControlConnection(connectionURL: link) }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.removeItem(at: manifestURL)
        withExtendedLifetime(server) {}
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
'''.replace("SNAPSHOT", content).replace("IDENTITY", identity)

with tempfile.TemporaryDirectory(prefix="zshell-session-control-tests-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Probe.swift"
    source.write_text(fixture)
    binary = temporary / "probe"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-DDEBUG",
        str(ROOT / "mac/zshell/GitCommandRunner.swift"),
        str(ROOT / "mac/zshell/SessionWorktreeService.swift"),
        str(ROOT / "mac/zshell/ZshellAutomationProtocol.swift"),
        str(ROOT / "mac/zshell/ZshellSessionCommandLine.swift"),
        str(ROOT / "mac/zshell/ZshellSessionControlConnection.swift"),
        str(ROOT / "mac/zshell/ZshellSessionAutomationRouter.swift"), str(source), "-o", str(binary),
    ], check=True)
    environment = os.environ.copy()
    environment["CFFIXED_USER_HOME"] = str(temporary / "home")
    subprocess.run([str(binary), str(temporary)], env=environment, check=True)
