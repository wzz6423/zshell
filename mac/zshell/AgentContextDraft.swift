import AppKit
import Combine

@MainActor
final class AgentContextDraft {
    nonisolated static let maximumBytes = 262_144
    nonisolated static let maximumSources = 64

    struct Source {
        enum Kind { case selection, commandOutput }
        let kind: Kind
        let terminalTitle: String
        let command: String?

        init(kind: Kind, terminalTitle: String, command: String?) {
            self.kind = kind
            self.terminalTitle = AgentConversationHistoryRecord.normalizedText(terminalTitle, maximumBytes: 320) ?? ""
            self.command = AgentConversationHistoryRecord.normalizedText(command, maximumBytes: 320)
        }

        var label: String {
            let kind = kind == .selection ? String(localized: "Selection") : String(localized: "Command Output")
            return "\(kind) · \(terminalTitle)" + (command.map { " · \($0)" } ?? "")
        }
    }

    private(set) var text = ""
    private(set) var sources: [Source] = []
    var target: AgentContextDraftTarget?

    @discardableResult
    func append(_ text: String, source: Source) -> Bool {
        let separator = self.text.isEmpty ? "" : "\n\n"
        guard !text.isEmpty, sources.count < Self.maximumSources,
            text.utf8.count + separator.utf8.count <= Self.maximumBytes - self.text.utf8.count
        else { return false }
        self.text += separator + text
        sources.append(source)
        return true
    }

    @discardableResult
    func edit(_ text: String) -> Bool {
        guard text.utf8.count <= Self.maximumBytes else { return false }
        self.text = text
        if text.isEmpty { sources.removeAll() }
        return true
    }

    @discardableResult
    func copy(to pasteboard: NSPasteboard) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// A draft points at a process incarnation and conversation, never the pane's
/// next occupant. Changing focus or moving tabs cannot silently retarget it.
@MainActor
struct AgentContextDraftTarget: Equatable {
    let projectID: UUID
    let terminalID: UUID
    let process: ZshellAgentProcessIdentity
    let conversation: AgentConversationIdentity?
    let kind: ZshellAgentKind
    let recognitionID: String?
    let alias: String
    let name: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projectID == rhs.projectID && lhs.terminalID == rhs.terminalID
            && lhs.process == rhs.process && lhs.conversation == rhs.conversation
            && lhs.kind == rhs.kind && lhs.recognitionID == rhs.recognitionID && lhs.alias == rhs.alias
    }

    init?(context: ZshellAutomationRouter.PaneContext) {
        guard let session = context.session, !session.hasExited,
            session.remoteConnection == nil, session.remotePasteTarget == nil,
            let status = session.agentStatus, let pid = session.surface.foregroundPid,
            let process = ZshellAgentProcessIdentity(pid: pid),
            session.isAutomationAgentRunning(kind: status.kind)
        else { return nil }
        projectID = context.project.id
        terminalID = session.id
        self.process = process
        conversation = session.agentResume
        kind = status.kind
        recognitionID = status.recognitionID
        alias = status.alias
        let agent = AgentConversationHistoryRecord.normalizedText(status.displayName, maximumBytes: 320) ?? status.kind.displayName
        let tab = AgentConversationHistoryRecord.normalizedText(context.tab.displayTitle ?? session.title, maximumBytes: 320) ?? ""
        name = "\(agent) · \(tab)"
    }

    func context(in project: Project) -> ZshellAutomationRouter.PaneContext? {
        guard project.id == projectID, process.isAlive,
            let context = ZshellAutomationRouter.context(forSession: terminalID),
            context.project === project, context.manager.projects.contains(where: { $0 === project }),
            let session = context.session, !session.hasExited,
            session.surface.foregroundPid == process.pid,
            session.agentResume == conversation,
            let status = session.agentStatus, status.kind == kind,
            status.alias == alias, status.recognitionID == recognitionID,
            session.isAutomationAgentRunning(kind: kind)
        else { return nil }
        return context
    }
}

@MainActor
final class AgentContextDraftMenuTarget: NSObject, NSMenuItemValidation {
    private weak var session: TerminalSession?
    private weak var project: Project?
    private let location: TerminalCommandOutputLocation?

    private init(session: TerminalSession, project: Project, location: TerminalCommandOutputLocation?) {
        self.session = session
        self.project = project
        self.location = location
    }

    static func item(for surface: any TerminalBackendSurface, location: TerminalCommandOutputLocation? = nil) -> NSMenuItem {
        let item = NSMenuItem(
            title: location == nil ? String(localized: "Add Selection to Agent Draft") : String(localized: "Add Output to Agent Draft"),
            action: #selector(add(_:)), keyEquivalent: "")
        item.identifier = .init(location == nil ? "zshell-draft-selection" : "zshell-draft-output")
        if let session = surface.events as? TerminalSession, session.surface === surface,
            let context = ZshellAutomationRouter.context(forSession: session.id), context.session === session
        {
            let target = AgentContextDraftMenuTarget(session: session, project: context.project, location: location)
            item.target = target
            item.representedObject = target
            item.isEnabled = target.validateMenuItem(item)
        } else {
            item.isEnabled = false
        }
        return item
    }

    private func sourceContext() -> ZshellAutomationRouter.PaneContext? {
        guard let session, let project,
            let context = ZshellAutomationRouter.context(forSession: session.id),
            context.session === session, context.project === project
        else { return nil }
        return context
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let session, sourceContext() != nil else { return false }
        if let location {
            guard let region = session.surface.commandRegion(at: location) else { return false }
            return region.outputStart < region.outputEnd
        }
        return session.surface.hasSelection
    }

    @objc private func add(_ sender: NSMenuItem) {
        guard let context = sourceContext(), let session else { return }
        let surface = session.surface
        let text: String?
        let source: AgentContextDraft.Source
        if let location {
            text =
                surface.commandRegion(at: location) == nil
                ? nil : surface.commandText(at: location, part: .output, maxBytes: AgentContextDraft.maximumBytes)
            let command = surface.commandRecords.first { $0.outputLocation == location }?.command
            source = .init(kind: .commandOutput, terminalTitle: session.title, command: command)
        } else {
            text = surface.readSelectedText(maxBytes: AgentContextDraft.maximumBytes)
            source = .init(kind: .selection, terminalTitle: session.title, command: nil)
        }
        let controller = AgentContextDraftController.shared
        guard let text, !text.isEmpty else {
            controller.show(
                for: context.project, manager: context.manager,
                error: String(localized: "The source is unavailable or exceeds 256 KiB. Select a smaller range."))
            return
        }
        let appended = context.project.agentContextDraft.append(text, source: source)
        controller.show(
            for: context.project, manager: context.manager,
            error: appended ? nil : String(localized: "The draft can hold 256 KiB and 64 sources. Remove text before adding more."))
    }
}
