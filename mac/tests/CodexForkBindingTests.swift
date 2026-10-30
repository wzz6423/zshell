import Darwin
import Foundation

struct ZshellAgentProcessIdentity: Equatable {
    let pid: pid_t
    let startedSeconds: UInt64 = 1
    let startedMicroseconds: UInt64 = 0
    var isAlive: Bool { TerminalSession.conversationProcessEvidence(pid) != nil }
    init?(pid: pid_t) {
        guard TerminalSession.conversationProcessEvidence(pid) != nil else { return nil }
        self.pid = pid
    }
}

@MainActor enum AppSettings {
    static let shared = Settings()
    final class Settings { var aiEnabled = true }
}

enum CodexTitleConfiguration {
    static func hidesManagedSessionID(configDirectory: String?) -> Bool { false }
}

@MainActor final class TerminalSession {
    struct Surface { var foregroundPid: pid_t? }
    struct Status { var alias: String? }
    struct Observation {
        var codexConversationEvidence: (title: CodexTitleSessionEvidence, owner: ZshellAgentProcessIdentity)?
        var integrationOwner: ZshellAgentProcessIdentity?
    }
    nonisolated static func conversationProcessEvidence(_ pid: pid_t) -> AgentConversationBinding.ProcessEvidence? {
        switch pid {
        case 10, 11: .init(parentPID: 1, groupID: pid, provider: nil)
        case 20: .init(parentPID: 10, groupID: 20, provider: .codex)
        // The fork's /bin/sh wrapper (11) stays the job leader around Codex.
        case 30: .init(parentPID: 11, groupID: 11, provider: .codex)
        case 40: .init(parentPID: 1, groupID: 40, provider: .codex, isSharedService: true)
        case 50: .init(parentPID: 40, groupID: 40, provider: nil)
        default: nil
        }
    }
    nonisolated static func conversationChildPIDs(_ pid: pid_t) -> [pid_t] {
        switch pid {
        case 10: [20]
        case 11: [30]
        default: []
        }
    }
    var hasExited = false
    var remoteConnection: Bool?
    var shellPid: pid_t?
    var surface: Surface
    var agentResume: AgentConversationIdentity?
    var agentConversationForkSource: AgentConversationIdentity?
    var agentConversationProcessID: pid_t?
    var agentConversationOwner: ZshellAgentProcessIdentity?
    var agentConversationResumeDeadline: Date?
    var onAgentConversationChanged: ((TerminalSession, AgentConversationIdentity?) -> Void)?
    var agentObservation = Observation()
    var agentStatus: Status?
    var title = "Codex"

    init(shell: pid_t, foreground: pid_t) {
        shellPid = shell
        surface = Surface(foregroundPid: foreground)
    }
    func clearAutomationAgentStatus() { agentStatus = nil }
}

@MainActor final class TerminalManager {
    struct Project { let sessions: [TerminalSession] }
    static var automationManagers: [TerminalManager] = []
    let projects: [Project]
    init(sessions: [TerminalSession]) { projects = [.init(sessions: sessions)] }
}

@MainActor enum ZshellAutomationRouter {
    struct PaneContext { let session: TerminalSession? }
    static func projectContexts(_ project: TerminalManager.Project, manager: TerminalManager) -> [PaneContext] {
        project.sessions.map { .init(session: $0) }
    }
}

@main
@MainActor
struct CodexForkBindingTests {
    static func main() {
        let directory = FileManager.default.temporaryDirectory.path
        let original = AgentConversationIdentity(provider: .codex, sessionID: UUID().uuidString,
            workingDirectory: directory, configDirectory: directory)!
        let forked = AgentConversationIdentity(provider: .codex, sessionID: UUID().uuidString,
            workingDirectory: directory, configDirectory: directory)!
        let source = TerminalSession(shell: 10, foreground: 20)
        let fork = TerminalSession(shell: 11, foreground: 11)
        fork.agentConversationForkSource = original
        TerminalManager.automationManagers = [TerminalManager(sessions: [source, fork])]
        var sourceObservations = 0, forkObservations = 0
        source.onAgentConversationChanged = { _, _ in sourceObservations += 1 }
        fork.onAgentConversationChanged = { _, _ in forkObservations += 1 }
        _ = CodexDaemonBinding.titleChanged(in: source, title: original.sessionID)
        precondition(CodexDaemonBinding.accept(.init(identity: original, reporterPID: 50, source: nil), peerPID: 50))
        precondition(source.agentResume == original && source.agentConversationOwner?.pid == 20 && sourceObservations == 1)
        print("PASS shared Codex source binds to its actual foreground TUI")
        _ = CodexDaemonBinding.titleChanged(in: fork, title: original.sessionID)
        precondition(CodexDaemonBinding.accept(.init(identity: original, reporterPID: 50, source: nil), peerPID: 50))
        precondition(source.agentResume == original && source.agentConversationOwner?.pid == 20 && sourceObservations == 1,
                     "A pending fork's source title must not revoke the source binding")
        precondition(fork.agentResume == nil && fork.agentConversationOwner == nil && forkObservations == 0)
        print("PASS a pending fork's source title and shared hook leave source history unchanged")
        _ = CodexDaemonBinding.titleChanged(in: fork, title: forked.sessionID)
        precondition(CodexDaemonBinding.accept(.init(identity: forked, reporterPID: 50, source: nil), peerPID: 50))
        precondition(fork.agentResume == forked && fork.agentConversationOwner?.pid == 30
                     && fork.agentConversationForkSource == nil && forkObservations == 1)
        precondition(source.agentResume == original && source.agentConversationOwner?.pid == 20 && sourceObservations == 1)
        print("PASS shared Codex fork confirms an independent identity without modifying its source")
    }
}
