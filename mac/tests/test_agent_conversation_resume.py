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
refresh_start = settings.index("    func reconcileAIEnabled() {")
refresh = settings[
    refresh_start:settings.index("\n    }\n", refresh_start) + len("\n    }\n")
]
session = source("TerminalSession.swift")
record = session[
    session.index("    @discardableResult\n    func recordAgentConversation("):
    session.index("    deinit {", session.index("    func recordAgentConversation("))
]
snapshot = source("SessionStore.swift")
snapshot_types = snapshot[
    snapshot.index("        enum PaneContentSnapshot: Codable {"):
    snapshot.index("        struct ColumnSnapshot: Codable {")
]
worktree_types = ""
if "SessionWorktree" in snapshot_types:
    worktree = source("SessionWorktreeService.swift")
    worktree_types = worktree[:worktree.index("nonisolated struct SessionWorktreeError:")]
kind = source("AgentAutomation.swift")
kind = kind[kind.index("enum ZshellAgentKind:"):kind.index("enum ZshellAgentPhase:")]
process_identity = source("AgentStatusReporting.swift")
process_identity = process_identity[
    process_identity.index("struct ZshellAgentProcessIdentity:"):
    process_identity.index("struct ZshellAgentReport:")
]
has_lifecycle = "ZshellAgentLifecycleHooks" in refresh
has_profiles = False
startup_fixture = ""
startup_checks = ""
if "PersistentPTY.reconnect" in session:
    startup = session[session.index("        let sessionID ="):
                      session.index("        let backend =", session.index("        let sessionID ="))]
    has_profiles = "TerminalProfile.firstMatch" in startup
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
        restoredSessionID: UUID?, agentResume: AgentConversationIdentity?, agentFork: AgentConversationIdentity? = nil,
        isRestoredSession: Bool = true, allowsPersistence: Bool = true,
        explicitlyResumeConversation: Bool = false, remoteConnection: Bool? = nil,
        usesConfiguredStartupCommand: Bool = true__PROFILE_PARAMETERS__
    ) -> (id: UUID, resume: AgentConversationIdentity.ResumeLaunch?,
          command: [String]?, shell: String, directory: String, preserve: Bool__PROFILE_RESULT_TYPES__) {
__PROFILE_LOCAL_STATE__
STARTUP
        return (sessionID, resumeLaunch, directCommand, shellPath, directory, preserve__PROFILE_RESULT_VALUES__)
    }
}
'''.replace("STARTUP", startup).replace("__PROFILE_PARAMETERS__", r''',
        launchSettings: TerminalLaunchSettings = .init(),
        initialTerminalProfile: TerminalProfile? = nil, remotePasteTarget: Bool? = nil
''' if has_profiles else "").replace("__PROFILE_RESULT_TYPES__", r''',
          profileID: UUID?, settings: TerminalLaunchSettings, appearance: TerminalProfileAppearance
''' if has_profiles else "").replace("__PROFILE_LOCAL_STATE__",
    "        var launchTerminalProfileID: UUID?" if has_profiles else ""
).replace("__PROFILE_RESULT_VALUES__",
    ", launchTerminalProfileID, launchSettings, initialAppearance" if has_profiles else ""
)
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
    if "remoteConnection" in startup:
        startup_checks += r'''
        PersistentPTY.fixture = .init(workingDirectory: "/local-fixture")
        PersistentPTY.requests = []
        let remote = ResumeStartupProbe.launch(
            initialDirectory: "/remote-fixture", restoredSessionID: terminalID,
            agentResume: nil, remoteConnection: true
        )
        check(PersistentPTY.requests.isEmpty && !remote.preserve,
              "a remote session never reconnects or preserves a local persistent terminal")
        check(remote.directory == "/remote-fixture",
              "a remote session keeps its remote directory instead of a local PTY directory")
        PersistentPTY.fixture = nil
'''
    if has_profiles:
        startup_checks += r'''
        let baseSettings = TerminalLaunchSettings(environmentVariables: [
            .init(name: "PROFILE_CASE", value: "base"), .init(name: "BASE_ONLY", value: "retained"),
        ], initializationCommand: "printf base-init")
        var profile = TerminalProfile(name: "resume fixture")
        profile.directory = home.path
        profile.startupProgram = "/bin/sh"
        profile.startupArguments = "-c 'printf profile-started'"
        profile.appearance.fontSize = 18
        profile.launchSettings = .init(environmentVariables: [
            .init(name: "PROFILE_CASE", value: "matched"),
        ], initializationCommand: "printf profile-init")
        AppSettings.shared.terminalProfiles = [profile]
        let profileArguments = ["/bin/sh", "-c", "printf profile-started"]
        let fresh = ResumeStartupProbe.launch(
            initialDirectory: home.path, restoredSessionID: nil, agentResume: nil,
            isRestoredSession: false, launchSettings: baseSettings
        )
        check(fresh.command == profileArguments && fresh.profileID == profile.id,
              "a new terminal uses its matched profile startup instead of the global startup command")
        check(fresh.settings.environment == ["PROFILE_CASE": "matched", "BASE_ONLY": "retained"]
              && fresh.settings.initializationCommand == "printf profile-init"
              && fresh.appearance == profile.appearance,
              "production startup merges profile settings and keeps its appearance")
        let integrated = ResumeStartupProbe.launch(
            initialDirectory: home.path, restoredSessionID: nil, agentResume: nil,
            isRestoredSession: false, usesConfiguredStartupCommand: false, launchSettings: baseSettings
        )
        check(integrated.command == nil && integrated.shell == "/bin/zsh",
              "an integrated shell suppresses both profile and global startup commands")
        check(integrated.profileID == profile.id && integrated.settings == fresh.settings
              && integrated.appearance == profile.appearance,
              "suppressing startup commands still applies matched profile settings and appearance")
        let explicitArguments = ["/bin/echo", "explicit-started"]
        let explicit = ResumeStartupProbe.launch(
            initialDirectory: home.path, commandArguments: explicitArguments,
            restoredSessionID: nil, agentResume: nil, isRestoredSession: false
        )
        check(explicit.command == explicitArguments && explicit.profileID == profile.id,
              "explicit argv takes priority over a matched profile startup command")
        let restoredShell = ResumeStartupProbe.launch(
            initialDirectory: home.path, restoredSessionID: nil, agentResume: nil
        )
        check(restoredShell.command == nil && restoredShell.shell == "/bin/zsh"
              && restoredShell.profileID == profile.id,
              "restoring an ordinary shell never launches its matched profile startup command")
        let profileResume = ResumeStartupProbe.launch(
            initialDirectory: "/", restoredSessionID: nil, agentResume: restored,
            launchSettings: baseSettings
        )
        check(profileResume.command == ["claude", "--resume", event.identity.sessionID]
              && profileResume.directory == home.path && profileResume.profileID == profile.id,
              "exact agent resume wins over profile startup and matches the resume working directory")
        let explicitResume = ResumeStartupProbe.launch(
            initialDirectory: "/", commandArguments: explicitArguments,
            restoredSessionID: nil, agentResume: restored, isRestoredSession: false,
            explicitlyResumeConversation: true
        )
        check(explicitResume.command == ["claude", "--resume", event.identity.sessionID]
              && explicitResume.profileID == profile.id,
              "an explicit conversation resume also takes priority over explicit argv and profile startup")
        let profileFork = ResumeStartupProbe.launch(
            initialDirectory: "/", commandArguments: explicitArguments,
            restoredSessionID: nil, agentResume: restored, agentFork: restored,
            isRestoredSession: false
        )
        check(profileFork.command == ["claude", "--resume", event.identity.sessionID, "--fork-session"]
              && profileFork.directory == home.path && profileFork.profileID == profile.id,
              "agent fork takes priority over ordinary resume, explicit argv, and profile startup")
        PersistentPTY.fixture = .init(workingDirectory: home.path)
        let profileAttached = ResumeStartupProbe.launch(
            initialDirectory: "/", restoredSessionID: terminalID, agentResume: restored,
            launchSettings: baseSettings
        )
        check(profileAttached.resume == nil && profileAttached.command == nil
              && profileAttached.profileID == profile.id && profileAttached.settings == fresh.settings,
              "matching a profile during PTY reconnect never relaunches its startup or saved agent")
        PersistentPTY.fixture = nil
        let profileRemote = ResumeStartupProbe.launch(
            initialDirectory: home.path, restoredSessionID: nil, agentResume: nil,
            remoteConnection: true, launchSettings: baseSettings
        )
        check(profileRemote.profileID == nil && profileRemote.settings == baseSettings,
              "remote terminals never automatically apply a matching local profile")
        let profileSSH = ResumeStartupProbe.launch(
            initialDirectory: home.path, restoredSessionID: nil, agentResume: nil,
            launchSettings: baseSettings, remotePasteTarget: true
        )
        check(profileSSH.profileID == nil && profileSSH.settings == baseSettings,
              "SSH paste targets also bypass automatic local profile selection")
        let explicitRemoteProfile = ResumeStartupProbe.launch(
            initialDirectory: home.path, restoredSessionID: nil, agentResume: nil,
            remoteConnection: true, launchSettings: baseSettings, initialTerminalProfile: profile
        )
        check(explicitRemoteProfile.profileID == profile.id && explicitRemoteProfile.settings == baseSettings
              && explicitRemoteProfile.appearance == profile.appearance,
              "an explicit remote profile keeps appearance without replacing the supplied remote launch settings")
        AppSettings.shared.terminalProfiles = []
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
__PROFILE_SETTINGS__
REFRESH
}

@MainActor
final class TerminalSession {
    struct AgentStatus { var alias: String? }
    struct Surface { var foregroundPid: pid_t? }
    struct RemoteStatus {
        enum State { case connected, failed }
        var state: State
    }
    var remoteConnection: Bool?
    var remoteStatus: RemoteStatus?
    var hasExited = false
    var shellPid: pid_t?
    var surface = Surface()
    var agentStatus: AgentStatus?
    var agentResume: AgentConversationIdentity?
    var agentConversationProcessID: pid_t?
    var agentConversationOwner: ZshellAgentProcessIdentity?
    var agentConversationResumeDeadline: Date?
    var agentConversationForkSource: AgentConversationIdentity?
    var agentConversationForkProcess: ZshellAgentProcessIdentity?
    var onAgentConversationChanged: ((TerminalSession, AgentConversationIdentity?) -> Void)?
    func isAutomationAgentRunning(kind: ZshellAgentKind) -> Bool {
        surface.foregroundPid.flatMap(ZshellAgentKind.recognize(processID:)) == kind
    }
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
        check(restored?.forkLaunch()?.arguments == ["claude", "--resume", event.identity.sessionID, "--fork-session"],
              "Claude forks through its native resume operation")
        let forkTerminal = TerminalSession()
        forkTerminal.shellPid = getpid()
        forkTerminal.surface.foregroundPid = agent.processIdentifier
        forkTerminal.agentConversationForkSource = event.identity
        check(!forkTerminal.acceptAgentConversation(event, peerProcessID: agent.processIdentifier)
              && forkTerminal.agentResume == nil && forkTerminal.agentConversationProcessID == nil,
              "a pending fork cannot claim the source conversation")
        let forkIdentity = AgentConversationIdentity(provider: .claude, sessionID: UUID().uuidString,
            workingDirectory: event.identity.workingDirectory, configDirectory: event.identity.configDirectory)!
        let forkEvent = AgentConversationSessionEvent(identity: forkIdentity, reporterPID: agent.processIdentifier, source: "resume")
        check(forkTerminal.acceptAgentConversation(forkEvent, peerProcessID: agent.processIdentifier)
              && forkTerminal.agentResume == forkIdentity && forkTerminal.agentConversationForkSource == nil,
              "a verified independent fork uses its own identity")
        check(terminal.agentResume == event.identity && terminal.agentConversationOwner?.isAlive == true,
              "fork binding leaves the original live conversation unchanged")
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
).replace("__PROFILE_SETTINGS__",
    "    var terminalProfiles: [TerminalProfile] = []" if has_profiles else ""
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
                      + worktree_types
                      + "struct SessionSnapshot { struct ProjectSnapshot {\n"
                      + snapshot_types + "} }\n" + kind + process_identity + fixture)
    production = ["AgentConversationIdentity.swift", "AgentConversationBinding.swift",
                  "TerminalAgentConversation.swift", "ProcessWorkingDirectory.swift",
                  "ZshellAgentSessionHooks.swift", "ZshellAgentIntegrations.swift",
                  "ZshellAutomationSkill.swift", "CodexTitleConfiguration.swift",
                  "ZshellAutomationProtocol.swift"]
    if has_lifecycle:
        production.append("ZshellAgentLifecycleHooks.swift")
    runner = source("AgentUsage.swift")
    runner = "import Foundation\nimport Darwin\n" + runner[runner.index("nonisolated struct ProcessCommandResult") :]
    runner_path = root / "ProcessRunner.swift"
    runner_path.write_text(runner)
    sources = [str(runner_path)]
    if has_profiles:
        production.extend(["TerminalProfiles.swift", "TerminalEnvironmentSettings.swift",
                           "TerminalStartupCommand.swift"])
        toml = "import Foundation\n" + settings[settings.index("nonisolated enum TOML {"):]
        toml_path = root / "TOML.swift"
        toml_path.write_text(toml)
        sources.append(str(toml_path))
        if "SettingsConfigFile." in toml:
            production.append("SettingsConfigFile.swift")
    for filename in production:
        path = root / filename
        path.write_text(source(filename))
        sources.append(str(path))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    "-module-cache-path", str(root / "ModuleCache"),
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
