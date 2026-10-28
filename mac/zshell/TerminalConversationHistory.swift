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
}
