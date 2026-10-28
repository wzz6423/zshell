import AppKit
import Foundation

extension TerminalManager {
    struct ConversationContext {
        let manager: TerminalManager
        let project: Project
        let session: TerminalSession
    }

    static func openConversation(_ record: AgentConversationHistoryRecord) -> ConversationContext? {
        for manager in automationManagers {
            for project in manager.projects {
                if let session = project.sessions.first(where: { $0.hasOpenConversation(record.identity) }) {
                    return .init(manager: manager, project: project, session: session)
                }
            }
        }
        return nil
    }

    func showConversationHistory(all: Bool = false) {
        if isCommandPaletteVisible { dismissCommandPalette() }
        AgentConversationHistoryController.shared.show(for: self, filter: all ? .all : .recent)
    }

    func resumeConversation(
        id: UUID, in requestedProject: Project? = nil, focus: Bool
    ) throws -> (context: ConversationContext, action: String) {
        let store = AgentConversationHistoryStore.shared
        guard let record = store.record(id: id, projectID: requestedProject?.conversationHistoryProjectID) else {
            throw AgentConversationHistoryError.notFound
        }
        guard record.identity.remoteHostID == nil else { throw AgentConversationHistoryError.differentProject }
        if let live = Self.openConversation(record) {
            if let requestedProject,
               live.manager !== self || live.project !== requestedProject {
                throw AgentConversationHistoryError.differentProject
            }
            try store.setArchived(false, id: id)
            if focus { Self.revealSession(id: live.session.id) }
            return (live, "revealed")
        }

        let existing = Self.automationManagers.flatMap { manager in
            manager.projects.flatMap { project in
                project.sessions.filter { $0.id == record.terminalID }.map {
                    ConversationContext(manager: manager, project: project, session: $0)
                }
            }
        }.first
        // A reconnected terminal can predate the current provider hook. Keep
        // that live PTY without asserting that its saved conversation is current.
        if let existing, !existing.session.hasExited, existing.session.reconnectedToPersistentPTY,
           existing.session.agentResume?.matchesConversation(record.identity) == true {
            if let requestedProject,
               existing.manager !== self || existing.project !== requestedProject {
                throw AgentConversationHistoryError.differentProject
            }
            if record.isArchived { try store.setArchived(false, id: id) }
            if focus { Self.revealSession(id: existing.session.id) }
            return (existing, "revealed_terminal")
        }
        guard AppSettings.shared.aiEnabled else { throw AgentConversationHistoryError.disabled }
        let reconnectID = existing == nil || existing?.session.hasExited == true
            ? record.terminalID : nil
        let livePTY = reconnectID.flatMap { PersistentPTY.reconnect(id: $0) }
        if livePTY == nil { try Self.validateConversationResume(record.identity) }
        if record.isArchived { try store.setArchived(false, id: id) }

        let project = requestedProject
            ?? projects.first(where: { !$0.isRemote && $0.conversationHistoryProjectID == record.projectID })
            ?? makeConversationHistoryProject(record, focus: focus)
        guard !project.isRemote else { throw AgentConversationHistoryError.differentProject }
        if let existing, existing.session.hasExited, livePTY != nil {
            guard existing.manager === self, existing.project === project else {
                throw AgentConversationHistoryError.differentProject
            }
            existing.project.closeContent(.session(existing.session), terminate: false)
        }
        let session = project.resumeConversation(
            record, focus: focus, restoredTerminalID: livePTY == nil ? nil : reconnectID
        )
        if focus { Self.revealSession(id: session.id) }
        return (.init(manager: self, project: project, session: session),
                session.reconnectedToPersistentPTY ? "reconnected" : "resume_started")
    }

    static func validateConversationResume(_ identity: AgentConversationIdentity) throws {
        guard identity.remoteHostID == nil else { throw AgentConversationHistoryError.differentProject }
        func isDirectory(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
        guard isDirectory(identity.workingDirectory) else { throw AgentConversationHistoryError.unavailableDirectory }
        if let configDirectory = identity.configDirectory, !isDirectory(configDirectory) {
            throw AgentConversationHistoryError.unavailableConfiguration
        }
        guard identity.resumeLaunch(enabled: true) != nil else {
            throw AgentConversationHistoryError.unavailableSessionFile
        }
    }

    func resumeRemoteConversation(id: UUID, in requestedProject: Project? = nil, focus: Bool) async throws -> ConversationContext {
        let store = AgentConversationHistoryStore.shared
        guard let record = store.record(id: id, projectID: requestedProject?.conversationHistoryProjectID),
              let hostID = record.identity.remoteHostID,
              let directory = record.identity.remoteProjectDirectory else { throw AgentConversationHistoryError.notFound }
        if let live = Self.openConversation(record) {
            if let requestedProject, live.manager !== self || live.project !== requestedProject {
                throw AgentConversationHistoryError.differentProject
            }
            if record.isArchived { try store.setArchived(false, id: id) }
            if focus { Self.revealSession(id: live.session.id) }
            return live
        }
        guard AppSettings.shared.aiEnabled else { throw AgentConversationHistoryError.disabled }
        if let requestedProject, requestedProject.sharedHost?.id != hostID || requestedProject.remoteDirectory != directory {
            throw AgentConversationHistoryError.differentProject
        }
        guard let host = requestedProject?.sharedHost
            ?? projects.first(where: { $0.sharedHost?.id == hostID })?.sharedHost
            ?? RemoteHostStore.shared.hosts.first(where: { $0.id == hostID }) else {
            throw AgentConversationHistoryError.unavailableConfiguration
        }
        let info = try await Task.detached(priority: .userInitiated) {
            try RemoteHostClient.resume(host: host, identity: record.identity)
        }.value
        guard store.record(id: id)?.identity == record.identity,
              info.project == directory, let remoteID = UUID(uuidString: info.sessionId) else {
            throw AgentConversationHistoryError.notFound
        }
        if let requestedProject, !projects.contains(where: { $0 === requestedProject }) {
            throw AgentConversationHistoryError.differentProject
        }
        let previousSelection = selectedProjectID
        let project = requestedProject ?? sharedProject(host: host, directory: directory)
        project.attachRemoteSession(info)
        guard let session = project.sessions.first(where: { $0.remoteConnection?.sessionID == remoteID }) else {
            throw AgentConversationHistoryError.notFound
        }
        session.agentConversationHistoryID = record.id
        if record.isArchived { try store.setArchived(false, id: id) }
        if focus { Self.revealSession(id: session.id) }
        else { selectedProjectID = previousSelection }
        return .init(manager: self, project: project, session: session)
    }
}
