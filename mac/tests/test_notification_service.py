"""Compile production notification service with model fixtures; never contact macOS permissions."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "mac/tests/test_notification_history.py").read_text()
support_section = "\n".join(line[4:] if line.startswith("    ") else line for line in
                          source[source.index("    connections ="):source.index("    binary =")].splitlines())

with tempfile.TemporaryDirectory(prefix="zshell-notification-service-", dir="/tmp") as directory:
    temporary = Path(directory)
    support = temporary / "Support.swift"
    exec(support_section)
    support.write_text(support.read_text() + r'''
import AppKit
@MainActor final class AppSettings {
    static let shared = AppSettings()
    var notifyOnAgentAttention = true
    var notifyOnAgentCompletion = true
}
enum ZshellAgentKind: String { case codex }
enum ZshellAgentPhase: String { case working, blocked, done, idle, created }
enum ZshellAgentStateAuthority { case integration, report, command, screen }
enum ZshellAgentAttention: String { case approval, input, error }
struct ZshellAgentTaskStatus { let id: String; let phase: ZshellAgentPhase; let attention: ZshellAgentAttention? }
struct ZshellAgentStatus {
    let alias: String; let kind: ZshellAgentKind; let phase: ZshellAgentPhase
    let authority: ZshellAgentStateAuthority; let reason: String; let updatedAt: Date; let processID: pid_t?
    let unseen: Bool; let progress: Int?; let attention: ZshellAgentAttention?; let tasks: [ZshellAgentTaskStatus]
}
struct ProcessIdentity { let pid: Int32; let startedSeconds: UInt64; let startedMicroseconds: UInt64 }
struct Report { let activityPhase: ZshellAgentPhase }
struct Observation { let owner: ProcessIdentity; let report: Report }
struct AgentObservation { var integrationOwner: ProcessIdentity?; var programReport: Observation? }
struct RemoteAgentStatus { let generation: UInt64; let phase: String }
struct RemoteHost { let id: UUID; let name: String }
struct RemoteRelayStatus {
    enum State { case connected, connecting, failed, exited }
    var state: State; var agentStatus: RemoteAgentStatus?; var exitCode: Int32?
}
struct RemoteConnection { let host: RemoteHost; let sessionID: UUID }
struct Window { var isMiniaturized: Bool }
struct Surface { var hasEffectiveTerminalFocus = false; var window: Window? }
@MainActor final class TerminalSession {
    let id = UUID()
    var hasExited = false
    var surface = Surface(window: nil)
    var agentStatus: ZshellAgentStatus?
    var agentObservation = AgentObservation()
    var remoteStatus: RemoteRelayStatus?
    var remoteConnection: RemoteConnection?
}
struct Project { let id: UUID; let name: String }
struct Tab { let id: UUID; let displayTitle: String? }
struct Pane { let id: UUID }
@MainActor final class GlobalTerminalOverlay {
    static let shared = GlobalTerminalOverlay()
    func notificationPane(for id: UUID) -> (tab: Tab, pane: Pane, session: TerminalSession)? { nil }
}
enum ZshellAutomationRouter {
    struct PaneContext { let project: Project; let tab: Tab; let pane: Pane; let session: TerminalSession? }
    static func context(forSession: UUID) -> PaneContext? { nil }
}
@MainActor enum TerminalManager {
    static func automationIsSessionFocused(_ id: UUID) -> Bool { false }
    static func notificationContext(for target: TerminalNotificationTarget) -> ZshellAutomationRouter.PaneContext? { nil }
    static var connectedRemoteSession: TerminalSession?
    static func notificationSession(for target: TerminalNotificationTarget) -> TerminalSession? { connectedRemoteSession }
    static func connectedRemoteNotificationSession(for target: TerminalNotificationTarget, excluding id: UUID?) -> TerminalSession? {
        guard let session = connectedRemoteSession, session.id != id,
              session.remoteConnection?.host.id == target.remoteHostID,
              session.remoteConnection?.sessionID == target.remoteSessionID,
              session.remoteStatus?.state == .connected, !session.hasExited else { return nil }
        return session
    }
    static func revealNotification(target: TerminalNotificationTarget) -> Bool { false }
    static func revealSession(id: UUID) {}
}
@MainActor final class TerminalNotificationCenterController {
    static let shared = TerminalNotificationCenterController()
    func show() {}
}
''')
    binary = temporary / "service-probe"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-D", "DEBUG",
        "-module-cache-path", str(temporary / "ModuleCache"), str(support),
        str(ROOT / "mac/zshell/TerminalNotificationHistory.swift"),
        str(ROOT / "mac/zshell/TerminalNotificationService.swift"),
        str(ROOT / "mac/tests/TerminalNotificationServiceTests.swift"), "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary), str(temporary)], cwd=ROOT, check=True, timeout=45)
