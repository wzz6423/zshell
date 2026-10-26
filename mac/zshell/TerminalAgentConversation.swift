import Darwin
import Foundation

extension TerminalSession {
    func refreshAgentConversationHistory() {
        if let owner = agentConversationOwner, !owner.isAlive {
            recordAgentConversation(nil, processID: nil)
        } else if let deadline = agentConversationResumeDeadline,
                  Date() >= deadline, let identity = agentResume,
                  ZshellAgentKind(rawValue: identity.provider.rawValue)
                    .map(isAutomationAgentRunning(kind:)) != true {
            recordAgentConversation(nil, processID: nil)
        }
    }

    func hasOpenConversation(_ identity: AgentConversationIdentity) -> Bool {
        guard !hasExited, let current = agentResume, current.matchesConversation(identity) else { return false }
        if agentConversationOwner?.isAlive == true { return true }
        guard let deadline = agentConversationResumeDeadline else { return false }
        return Date() < deadline || ZshellAgentKind(rawValue: identity.provider.rawValue)
            .map(isAutomationAgentRunning(kind:)) == true
    }

    func acceptAgentConversation(_ event: AgentConversationSessionEvent, peerProcessID: pid_t?) -> Bool {
        guard AppSettings.shared.aiEnabled, !hasExited,
              let shellPID = shellPid,
              let foregroundPID = surface.foregroundPid,
              let agentPID = AgentConversationBinding.reportingRootAgentPID(
                peerPID: peerProcessID,
                reporterPID: event.reporterPID,
                shellPID: shellPID,
                foregroundPID: foregroundPID,
                provider: event.identity.provider,
                process: Self.conversationProcessEvidence
              )
        else { return false }

        let identity = AgentConversationIdentity(
            provider: event.identity.provider,
            sessionID: event.identity.sessionID,
            workingDirectory: event.identity.workingDirectory,
            configDirectory: event.identity.configDirectory,
            sessionFile: event.identity.sessionFile,
            alias: agentStatus?.alias ?? event.identity.alias,
            configurationEnvironment: event.identity.configurationEnvironment
        )
        guard let identity,
              identity.provider != .opencode || !Self.openCodeIsAttached(agentPID)
        else { return false }
        recordAgentConversation(identity, processID: agentPID)
        return true
    }

    func clearAgentConversation(
        provider: AgentConversationIdentity.Provider, reporterPID: Int32, peerProcessID: pid_t?
    ) -> Bool {
        guard AppSettings.shared.aiEnabled, !hasExited,
              let shellPID = shellPid,
              let foregroundPID = surface.foregroundPid,
              let agentPID = AgentConversationBinding.reportingRootAgentPID(
                peerPID: peerProcessID,
                reporterPID: reporterPID,
                shellPID: shellPID,
                foregroundPID: foregroundPID,
                provider: provider,
                process: Self.conversationProcessEvidence
              ),
              agentResume == nil || agentResume?.provider == provider,
              agentConversationProcessID == nil || agentConversationProcessID == agentPID
        else { return false }
        recordAgentConversation(nil, processID: nil)
        return true
    }

    /// An agent deliberately exited before quit must not reappear as a
    /// conversation merely because its last hook once occupied this shell.
    var conversationIdentityForPersistence: AgentConversationIdentity? {
        guard !hasExited, let identity = agentResume,
              let processID = agentConversationProcessID,
              let shellPID = shellPid,
              let foregroundPID = surface.foregroundPid,
              (identity.provider != .opencode || !Self.openCodeIsAttached(processID)),
              AgentConversationBinding.rootAgentPID(
                reporterPID: processID,
                shellPID: shellPID,
                foregroundPID: foregroundPID,
                provider: identity.provider,
                process: Self.conversationProcessEvidence
              ) == processID else { return nil }
        return identity
    }

    private static func openCodeIsAttached(_ pid: pid_t) -> Bool {
        let arguments = processArguments(pid: pid) ?? []
        let operands = arguments.dropFirst().prefix { $0 != "--" }
        return operands.contains("attach")
    }

    private static func conversationProcessEvidence(_ pid: pid_t) -> AgentConversationBinding.ProcessEvidence? {
        guard let parent = AgentConversationBinding.parentPID(pid) else { return nil }
        let kind = ZshellAgentKind.recognize(processID: pid)
        return .init(
            parentPID: parent,
            groupID: getpgid(pid),
            provider: kind.flatMap { AgentConversationIdentity.Provider(rawValue: $0.rawValue) },
            isProviderLauncher: kind == .codex && AgentConversationBinding.isCodexLauncher(
                executablePath: processExecutablePath(pid: pid),
                arguments: processArguments(pid: pid) ?? []
            )
        )
    }
}
