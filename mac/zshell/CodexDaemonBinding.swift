import Darwin
import Foundation

/// The hook's daemon can predate the GUI or the pane that started it. Match its
/// complete identity with independent TUI output, never with its inherited cwd.
@MainActor
enum CodexDaemonBinding {
    private struct Entry {
        let event: AgentConversationSessionEvent
        let service: ZshellAgentProcessIdentity
        var updatedAt: Date
    }

    private static var entries: [Entry] = []
    private static let pendingLifetime: TimeInterval = 30
    private static let maximumEntries = 200

    static func service(peerPID: pid_t?, reporterPID: pid_t) -> ZshellAgentProcessIdentity? {
        AgentConversationBinding.sharedCodexServicePID(
            peerPID: peerPID, reporterPID: reporterPID,
            process: TerminalSession.conversationProcessEvidence
        ).flatMap(ZshellAgentProcessIdentity.init(pid:))
    }

    static func accept(_ event: AgentConversationSessionEvent, peerPID: pid_t?) -> Bool {
        guard AppSettings.shared.aiEnabled, event.identity.provider == .codex,
              let service = service(peerPID: peerPID, reporterPID: event.reporterPID) else { return false }
        prune()
        let matches = entries.indices.filter {
            entries[$0].event.identity.matchesConversation(event.identity) && entries[$0].service == service
        }
        if let index = matches.first { entries[index] = Entry(event: event, service: service, updatedAt: Date()) }
        else {
            if entries.count == maximumEntries { entries.removeFirst() }
            entries.append(Entry(event: event, service: service, updatedAt: Date()))
        }
        // Codex can publish its title before the first-turn SessionStart hook.
        // Reconcile both arrival orders without borrowing the daemon's cwd.
        reconcile()
        return true
    }

    static func titleChanged(in session: TerminalSession, title: String) -> String {
        guard let evidence = CodexTitleSessionEvidence(title: title),
              let owner = session.foregroundCodexConversationOwner else {
            clearBinding(in: session)
            session.agentObservation.codexConversationEvidence = nil
            return title
        }
        if let previous = session.agentObservation.codexConversationEvidence,
           previous.owner != owner || previous.title.sessionPrefix != evidence.sessionPrefix {
            clearBinding(in: session)
        }
        if let identity = session.agentResume, identity.provider == .codex,
           !evidence.matches(sessionID: identity.sessionID) {
            session.recordAgentConversation(nil, processID: nil)
        }
        session.agentObservation.codexConversationEvidence = (evidence, owner)
        prune()
        reconcile()
        return displayTitle(in: session, evidence: evidence)
    }

    static func lifecycleTarget(
        sessionID: String, peerPID: pid_t?, reporterPID: pid_t
    ) -> ZshellAutomationRouter.PaneContext? {
        guard AgentConversationIdentity.Provider.codex.accepts(sessionID: sessionID),
              let service = service(peerPID: peerPID, reporterPID: reporterPID) else { return nil }
        prune()
        var identities = entries.filter {
            $0.service == service && $0.event.identity.sessionID == sessionID
        }
        if identities.isEmpty {
            // A reconnected live PTY already has a complete saved identity.
            // Its independent current TUI title revalidates that identity; a
            // kernel-owned daemon event only restores the process incarnation.
            let saved = knownIdentities().filter { $0.sessionID == sessionID }
            if saved.count == 1, let identity = saved.first,
               let target = uniqueTarget(for: identity),
               target.session?.agentResume?.matchesConversation(identity) == true {
                let entry = Entry(event: .init(identity: identity, reporterPID: reporterPID, source: nil),
                                  service: service, updatedAt: Date())
                if entries.count == maximumEntries { entries.removeFirst() }
                entries.append(entry)
                identities = [entry]
            }
        }
        guard identities.count == 1, let entry = identities.first,
              let target = uniqueTarget(for: entry.event.identity),
              let session = target.session,
              session.agentResume?.matchesConversation(entry.event.identity) == true else { return nil }
        if let index = entries.firstIndex(where: {
            $0.service == service && $0.event.identity.matchesConversation(entry.event.identity)
        }) { entries[index].updatedAt = Date() }
        return target
    }

    private static func contexts() -> [ZshellAutomationRouter.PaneContext] {
        TerminalManager.automationManagers.flatMap { manager in
            manager.projects.flatMap { ZshellAutomationRouter.projectContexts($0, manager: manager) }
        }
    }

    private static func uniqueTarget(
        for identity: AgentConversationIdentity
    ) -> ZshellAutomationRouter.PaneContext? {
        let matches = contexts().filter { context in
            guard let session = context.session,
                  let evidence = session.agentObservation.codexConversationEvidence,
                  session.foregroundCodexConversationOwner == evidence.owner else { return false }
            return evidence.title.matches(sessionID: identity.sessionID)
        }
        if matches.count > 1 {
            for context in matches {
                guard let session = context.session,
                      session.agentResume?.provider == .codex else { continue }
                clearBinding(in: session, includingSaved: true)
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func reconcile() {
        let identities = knownIdentities()
        for target in contexts() {
            guard let session = target.session,
                  let evidence = session.agentObservation.codexConversationEvidence else { continue }
            // A truncated title must select one complete provider identity too.
            let candidates = identities.filter { evidence.title.matches(sessionID: $0.sessionID) }
            guard session.foregroundCodexConversationOwner == evidence.owner,
                  candidates.count == 1, let identity = candidates.first,
                  uniqueTarget(for: identity)?.session === session else {
                clearBinding(in: session, includingSaved: candidates.count > 1)
                continue
            }
            guard session.agentResume?.matchesConversation(identity) == true
                    || entries.contains(where: { $0.event.identity.matchesConversation(identity) }) else { continue }
            let aliased = AgentConversationIdentity(
                provider: .codex, sessionID: identity.sessionID,
                workingDirectory: identity.workingDirectory, configDirectory: identity.configDirectory,
                alias: session.agentStatus?.alias ?? identity.alias,
                configurationEnvironment: identity.configurationEnvironment
            )
            guard let aliased else { continue }
            if session.agentResume != aliased || session.agentConversationOwner != evidence.owner {
                session.recordAgentConversation(aliased, processID: evidence.owner.pid)
            }
            session.title = displayTitle(in: session, evidence: evidence.title)
        }
    }

    private static func knownIdentities() -> [AgentConversationIdentity] {
        var result: [AgentConversationIdentity] = []
        let saved = contexts().compactMap { context -> AgentConversationIdentity? in
            guard let session = context.session, session.remoteConnection == nil,
                  let identity = session.agentResume, identity.provider == .codex else { return nil }
            return identity
        }
        for identity in entries.map(\.event.identity) + saved {
            if !result.contains(where: { $0.matchesConversation(identity) }) { result.append(identity) }
        }
        return result
    }

    private static func clearBinding(in session: TerminalSession, includingSaved: Bool = false) {
        guard let previous = session.agentObservation.codexConversationEvidence,
              session.agentResume?.provider == .codex,
              includingSaved || session.agentConversationOwner == previous.owner else { return }
        session.recordAgentConversation(nil, processID: nil)
        if session.agentObservation.integrationOwner == previous.owner {
            session.clearAutomationAgentStatus()
        }
    }

    private static func displayTitle(in session: TerminalSession, evidence: CodexTitleSessionEvidence) -> String {
        guard let identity = session.agentResume,
              evidence.matches(sessionID: identity.sessionID),
              CodexTitleConfiguration.hidesManagedSessionID(configDirectory: identity.configDirectory)
        else { return evidence.originalTitle }
        return evidence.titleWithoutSessionID.isEmpty ? "Codex" : evidence.titleWithoutSessionID
    }

    private static func prune() {
        let now = Date()
        entries.removeAll { entry in
            guard entry.service.isAlive else { return true }
            if now.timeIntervalSince(entry.updatedAt) < pendingLifetime { return false }
            return !contexts().contains { context in
                context.session?.agentResume?.matchesConversation(entry.event.identity) == true
                    && context.session?.agentConversationOwner?.isAlive == true
            }
        }
    }
}

extension TerminalSession {
    var foregroundCodexConversationOwner: ZshellAgentProcessIdentity? {
        guard !hasExited, remoteConnection == nil, let shell = shellPid,
              let foreground = surface.foregroundPid,
              let root = AgentConversationBinding.rootAgentPID(
                reporterPID: foreground, shellPID: shell, foregroundPID: foreground,
                provider: .codex, process: Self.conversationProcessEvidence
              ) else { return nil }
        return ZshellAgentProcessIdentity(pid: root)
    }
}
