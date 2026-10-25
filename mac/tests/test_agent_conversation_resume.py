"""Exercise real provider-hook refresh and live conversation persistence.

Run: python3 -B mac/tests/test_agent_conversation_resume.py [--source-ref <ref>]
All provider settings, skills, processes, and binaries stay in a disposable home.
"""
import argparse
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-ref")
args = parser.parse_args()


def source(name):
    path = "mac/zshell/" + name
    if args.source_ref:
        return subprocess.check_output(
            ["git", "show", f"{args.source_ref}:{path}"], cwd=ROOT, text=True
        )
    return (ROOT / path).read_text()


settings = source("AppSettings.swift")
refresh = settings[
    settings.index("    func reconcileAIEnabled() {"):
    settings.index("    private func save() {", settings.index("    func reconcileAIEnabled() {"))
]
session = source("TerminalSession.swift")
record = session[
    session.index("    func recordAgentConversation("):
    session.index("    deinit {", session.index("    func recordAgentConversation("))
]
snapshot = source("SessionStore.swift")
snapshot_types = snapshot[
    snapshot.index("        enum PaneContentSnapshot: Codable {"):
    snapshot.index("        struct ColumnSnapshot: Codable {")
]
kind = source("AgentAutomation.swift")
kind = kind[kind.index("enum ZshellAgentKind:"):kind.index("enum ZshellAgentPhase:")]
has_lifecycle = "ZshellAgentLifecycleHooks" in refresh
startup_fixture = ""
startup_checks = ""
if "PersistentPTY.reconnect" in session:
    startup = session[session.index("        let sessionID ="):
                      session.index("        let backend =", session.index("        let sessionID ="))]
    startup_fixture = r'''
@MainActor
struct PersistentPTY {
    let workingDirectory: String
    static var fixture: PersistentPTY?
    static var requests: [UUID] = []
    static func reconnect(id: UUID) -> PersistentPTY? {
        requests.append(id)
        return fixture
    }
}
@MainActor
enum ResumeStartupProbe {
    static func configuredStartupCommand() -> [String]? { ["/bin/false"] }
    static func loginShell() -> String { "/bin/zsh" }
    static func validWorkingDirectory(_ path: String?) -> String { path ?? "/" }
    static func launch(
        initialDirectory: String?, commandArguments: [String]? = nil,
        restoredSessionID: UUID?, agentResume: AgentConversationIdentity?,
        isRestoredSession: Bool = true, allowsPersistence: Bool = true
    ) -> (id: UUID, resume: AgentConversationIdentity.ResumeLaunch?,
          command: [String]?, shell: String, directory: String, preserve: Bool) {
STARTUP
        return (sessionID, resumeLaunch, directCommand, shellPath, directory, preserve)
    }
}
'''.replace("STARTUP", startup)
    startup_checks = r'''
        let terminalID = UUID()
        PersistentPTY.fixture = .init(workingDirectory: home.appendingPathComponent("live").path)
        let attached = ResumeStartupProbe.launch(
            initialDirectory: "/", restoredSessionID: terminalID, agentResume: restored
        )
        check(PersistentPTY.requests == [terminalID] && attached.id == terminalID,
              "restoration reconnects the saved persistent terminal before selecting a resume command")
        check(attached.resume == nil && attached.command == nil && attached.shell == "/bin/zsh",
              "production startup never relaunches Claude or startup commands in an existing PTY")
        check(attached.directory == PersistentPTY.fixture?.workingDirectory && attached.preserve,
              "a live PTY keeps its working directory and persistence")
        PersistentPTY.fixture = nil
        let restarted = ResumeStartupProbe.launch(
            initialDirectory: "/", restoredSessionID: terminalID, agentResume: restored
        )
        check(restarted.resume?.arguments == ["claude", "--resume", event.identity.sessionID]
              && restarted.directory == event.identity.workingDirectory && restarted.shell == "claude",
              "production startup resumes the exact saved identity only when its PTY cannot reconnect")
        let reopened = TerminalSession()
        reopened.shellPid = getpid()
        reopened.surface.foregroundPid = agent.processIdentifier
        reopened.agentResume = restored
        check(reopened.conversationIdentityForPersistence == nil,
              "repeated PTY reconnects never inherit unverified conversation process metadata")
        let persistentSnapshot = SessionSnapshot.ProjectSnapshot.PaneSnapshot(
            content: .session(workingDirectory: home.path), weight: 1,
            agentResume: restored, terminalID: terminalID
        )
        let persistentRoundTrip = try JSONDecoder().decode(
            SessionSnapshot.ProjectSnapshot.PaneSnapshot.self,
            from: JSONEncoder().encode(persistentSnapshot)
        )
        check(persistentRoundTrip.terminalID == terminalID && persistentRoundTrip.agentResume == restored,
              "snapshot preserves both persistent terminal and provider conversation identities")
'''
fixture = r'''
import Darwin
import Foundation

@MainActor
final class AppSettings {
    static let shared = AppSettings()
    var aiEnabled = true
    var resumeAgentConversations = true
    var preserveTerminalSessions = false
REFRESH
}

@MainActor
final class TerminalSession {
    struct AgentStatus { var alias: String? }
    struct Surface { var foregroundPid: pid_t? }
    var hasExited = false
    var shellPid: pid_t?
    var surface = Surface()
    var agentStatus: AgentStatus?
    var agentResume: AgentConversationIdentity?
    var agentConversationProcessID: pid_t?
RECORD
}

STARTUP_FIXTURE

@main
struct AgentResumeRegression {
    @MainActor
    static func main() throws {
        if CommandLine.arguments.contains("--fixture-agent") {
            Thread.sleep(forTimeInterval: 30)
            return
        }
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(name)")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let mode = CommandLine.arguments[1]
        AppSettings.shared.aiEnabled = mode != "disabled"
        AppSettings.shared.reconcileAIEnabled()
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        let hooks = settings["hooks"] as? [String: Any]
        let sessionHooks = hooks?["SessionStart"] as? [[String: Any]]
        let shouldInstall = mode != "disabled"
        check((sessionHooks?.isEmpty == false) == shouldInstall,
              "\(mode): enabled provider SessionStart hook survives an unrelated skill conflict")
        let link = home.appendingPathComponent(".claude/hooks/zshell-session-hook.sh")
        check(FileManager.default.fileExists(atPath: link.path) == shouldInstall,
              "\(mode): provider hook points to the bundled executable script")
        check(settings["fixture"] as? String == "preserve", "provider settings keep unrelated user values")
LIFECYCLE_CHECKS
        let userSkill = home.appendingPathComponent(".claude/skills/zshell-automation/SKILL.md")
        if mode == "modified" {
            check((try String(contentsOf: userSkill, encoding: .utf8)) == "user-owned skill\n",
                  "refresh never overwrites a modified user skill")
        }

        let agentURL = home.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(
            at: agentURL,
            withDestinationURL: Bundle.main.executableURL!
        )
        let agent = Process()
        agent.executableURL = agentURL
        agent.arguments = ["--fixture-agent"]
        try agent.run()
        defer { if agent.isRunning { agent.terminate(); agent.waitUntilExit() } }
        check(ZshellAgentKind.recognize(processID: agent.processIdentifier) == .claude,
              "fixture uses native process and argv provider recognition")
        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "11111111-2222-3333-4444-555555555555",
            "cwd": home.path,
            "source": "startup",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = AgentConversationSessionEvent.sessionStart(
            provider: .claude, payload: data, environment: [:],
            reporterPID: agent.processIdentifier, currentDirectory: home.path, homeURL: home
        )!
        let terminal = TerminalSession()
        terminal.shellPid = getpid()
        terminal.surface.foregroundPid = agent.processIdentifier
        if mode == "disabled" {
            check(!terminal.acceptAgentConversation(event, peerProcessID: agent.processIdentifier),
                  "disabled AI rejects even a valid provider event")
            AppSettings.shared.aiEnabled = true
        }
        check(terminal.acceptAgentConversation(event, peerProcessID: agent.processIdentifier),
              "live Claude SessionStart binds to its actual pane process")
        // Failed turns do not exit the Claude process or alter its conversation ID.
        terminal.agentStatus = nil
        let saved = terminal.conversationIdentityForPersistence
        check(saved == event.identity, "live Claude on an error screen still persists its exact conversation identity")
        let snapshot = SessionSnapshot.ProjectSnapshot.PaneSnapshot(
            content: .session(workingDirectory: home.path), weight: 1, agentResume: saved
        )
        let restoredSnapshot = try JSONDecoder().decode(
            SessionSnapshot.ProjectSnapshot.PaneSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        let restored = restoredSnapshot.agentResume
        check(restored == event.identity, "saved pane snapshot round-trip preserves the provider identity")
        check(restored?.resumeLaunch(enabled: true)?.arguments == ["claude", "--resume", event.identity.sessionID],
              "reopening the pane resumes that exact saved Claude conversation")
        check(restored?.resumeLaunch(enabled: false) == nil, "disabled resume does not launch a saved conversation")
        check(restored?.resumeLaunch(enabled: true, hasLiveTerminal: true) == nil,
              "a reconnected live terminal does not launch a duplicate agent")
STARTUP_CHECKS
        let ordinary = TerminalSession()
        ordinary.shellPid = getpid()
        ordinary.surface.foregroundPid = getpid()
        check(ordinary.conversationIdentityForPersistence == nil, "an ordinary shell never gains a conversation to resume")
        check(!terminal.acceptAgentConversation(event, peerProcessID: getpid()),
              "an unrelated socket peer cannot claim another agent's session")
        agent.terminate()
        agent.waitUntilExit()
        terminal.surface.foregroundPid = getpid()
        check(terminal.conversationIdentityForPersistence == nil,
              "a deliberately exited agent is not silently relaunched")
        print("Agent conversation resume regression: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
'''.replace("REFRESH", refresh).replace("RECORD", record).replace(
    "STARTUP_FIXTURE", startup_fixture
).replace("STARTUP_CHECKS", startup_checks).replace("LIFECYCLE_CHECKS", r'''
        let lifecycleLink = home.appendingPathComponent(".claude/hooks/zshell-lifecycle-hook.sh")
        check(FileManager.default.fileExists(atPath: lifecycleLink.path) == shouldInstall,
              "provider lifecycle hook also survives an unrelated skill conflict")
        let commands = sessionHooks?.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String } ?? []
        check(commands.filter { $0.contains("zshell-session-hook.sh") }.count == (shouldInstall ? 1 : 0)
              && commands.filter { $0.contains("zshell-lifecycle-hook.sh") }.count == (shouldInstall ? 1 : 0),
              "SessionStart preserves both separately managed identity and lifecycle hooks")
''' if has_lifecycle else "")

with tempfile.TemporaryDirectory(prefix="zshell-agent-resume-") as temporary:
    root = Path(temporary)
    app = root / "ResumeProbe.app/Contents"
    resources = app / "Resources"
    executable = app / "MacOS/ResumeProbe"
    executable.parent.mkdir(parents=True)
    resources.mkdir()
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "sh.zshell.resume-fixture",
        "CFBundleExecutable": executable.name,
        "CFBundlePackageType": "APPL",
    }))
    bundled_resources = [
        "Skills/zshell-automation/SKILL.md", "Skills/zshell-automation/agents/openai.yaml",
        "AgentIntegrations/zshell-session-hook.sh",
    ]
    if has_lifecycle:
        bundled_resources.append("AgentIntegrations/zshell-lifecycle-hook.sh")
    for relative in bundled_resources:
        destination = resources / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "mac/zshell" / relative, destination)
    helper = root / "Probe.swift"
    helper.write_text("import Foundation\nstruct EditorState: Codable {}\n"
                      + "struct SessionSnapshot { struct ProjectSnapshot {\n"
                      + snapshot_types + "} }\n" + kind + fixture)
    production = ["AgentConversationIdentity.swift", "AgentConversationBinding.swift",
                  "TerminalAgentConversation.swift", "ProcessWorkingDirectory.swift",
                  "ZshellAgentSessionHooks.swift", "ZshellAgentIntegrations.swift",
                  "ZshellAutomationSkill.swift"]
    if has_lifecycle:
        production.append("ZshellAgentLifecycleHooks.swift")
    sources = []
    for filename in production:
        path = root / filename
        path.write_text(source(filename))
        sources.append(str(path))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    *sources, str(helper), "-o", str(executable)], check=True)
    failures = []
    for mode in ("modified", "healthy", "disabled"):
        home = root / mode
        claude = home / ".claude"
        claude.mkdir(parents=True)
        (claude / "settings.json").write_text(json.dumps({"fixture": "preserve"}))
        if mode == "modified":
            skill = claude / "skills/zshell-automation"
            skill.mkdir(parents=True)
            (skill / "SKILL.md").write_text("user-owned skill\n")
            (skill / "agents").mkdir()
            (skill / "agents/openai.yaml").write_text("user-owned metadata\n")
            (skill / ".zshell-managed.json").write_text(json.dumps({
                "format_version": 2, "skill": "zshell-automation", "links": {
                    "SKILL.md": str(resources / "Skills/zshell-automation/SKILL.md"),
                    "agents/openai.yaml": str(resources / "Skills/zshell-automation/agents/openai.yaml"),
                },
            }))
        env = {key: value for key, value in os.environ.items()
               if key not in {"CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR",
                              "XDG_CONFIG_HOME", "GROK_HOME"}}
        env["CFFIXED_USER_HOME"] = str(home)
        result = subprocess.run([str(executable), mode], env=env, capture_output=True, text=True, timeout=40)
        print(result.stdout, end="")
        if result.returncode:
            failures.append(mode)
    if failures:
        raise SystemExit("Failing scenarios: " + ", ".join(failures))
