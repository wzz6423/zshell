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

    func forkConversation(
        id: UUID, in requestedProject: Project? = nil, focus: Bool, timeout: TimeInterval = 30
    ) async throws -> ConversationContext {
        try Task.checkCancellation()
        let store = AgentConversationHistoryStore.shared
        guard let record = store.record(id: id, projectID: requestedProject?.conversationHistoryProjectID) else {
            throw AgentConversationHistoryError.notFound
        }
        guard AppSettings.shared.aiEnabled else { throw AgentConversationHistoryError.forkDisabled }
        if record.identity.remoteHostID != nil {
            return try await forkRemoteConversation(record, in: requestedProject, focus: focus, timeout: timeout)
        }
        try Self.validateConversationResume(record.identity)
        guard record.identity.forkLaunch() != nil else { throw AgentConversationHistoryError.unavailableSessionFile }
        let existingProject = requestedProject
            ?? projects.first(where: { !$0.isRemote && $0.conversationHistoryProjectID == record.projectID })
        try await Self.validateConversationFork(record.identity, launchSettings: existingProject?.launchSettings ?? .init())
        try Task.checkCancellation()
        guard AppSettings.shared.aiEnabled else { throw AgentConversationHistoryError.forkDisabled }
        try Self.validateConversationResume(record.identity)
        let project = existingProject ?? makeConversationHistoryProject(record, focus: focus)
        guard !project.isRemote, projects.contains(where: { $0 === project }),
              !TerminalManager.isRemovingWorktree(containing: record.identity.workingDirectory) else {
            throw AgentConversationHistoryError.differentProject
        }
        let session = project.forkConversation(record, focus: focus)
        let context = ConversationContext(manager: self, project: project, session: session)
        if focus { Self.revealSession(id: session.id) }
        try await confirmConversationFork(context, source: record.identity, timeout: timeout)
        return context
    }

    static func validateConversationFork(
        _ identity: AgentConversationIdentity, launchSettings: TerminalLaunchSettings, timeout: TimeInterval = 8
    ) async throws {
        guard let launch = identity.forkLaunch() else { throw AgentConversationHistoryError.unavailableSessionFile }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ZSHELL_") }
        environment.merge(launchSettings.environment.filter {
            !TerminalLaunchSettings.isProtectedEnvironmentVariable($0.key)
        }, uniquingKeysWith: { _, value in value })
        let unset = launch.configurationVariables.union(["CODEX_THREAD_ID"]).subtracting(launch.environment.keys)
            .sorted().map { "-u \(TerminalSession.shellQuote($0))" }.joined(separator: " ")
        let values = launch.environment.sorted { $0.key < $1.key }
            .map { TerminalSession.shellQuote("\($0.key)=\($0.value)") }.joined(separator: " ")
        let arguments = identity.provider.forkHelpArguments.map(TerminalSession.shellQuote).joined(separator: " ")
        let command = "cd \(TerminalSession.shellQuote(launch.workingDirectory)) && exec /usr/bin/env \(unset) -- \(values) \(arguments)"
        let probeEnvironment = environment
        let shell = TerminalSession.loginShell()
        let probeArguments = ["-l", "-i", "-c", "exec /bin/sh -c \(TerminalSession.shellQuote(command))"]
        let probe = Task.detached(priority: .userInitiated) {
            try BoundedProcessRunner.run(executableURL: URL(fileURLWithPath: shell),
                arguments: probeArguments,
                timeout: timeout, outputLimit: 65_536, environment: probeEnvironment, standardInput: Data())
        }
        let result = try await withTaskCancellationHandler { try await probe.value } onCancel: { probe.cancel() }
        if result.timedOut { throw AgentConversationHistoryError.forkCheckTimedOut }
        guard result.terminationStatus == 0, !result.output.wasTruncated,
              identity.provider.supportsNativeFork(help: result.output.stdout + "\n" + result.output.stderr) else {
            throw AgentConversationHistoryError.forkUnavailable
        }
    }

    private func confirmConversationFork(
        _ context: ConversationContext, source: AgentConversationIdentity, timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard projects.contains(where: { $0 === context.project }),
                  context.project.sessions.contains(where: { $0 === context.session }),
                  !context.session.hasExited else { break }
            if let identity = context.session.agentResume, source.acceptsFork(identity),
               context.session.hasOpenConversation(identity) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AgentConversationHistoryError.forkUnconfirmed
    }

    private func forkRemoteConversation(
        _ record: AgentConversationHistoryRecord, in requestedProject: Project?, focus: Bool, timeout: TimeInterval
    ) async throws -> ConversationContext {
        guard let hostID = record.identity.remoteHostID,
              let directory = record.identity.remoteProjectDirectory else { throw AgentConversationHistoryError.notFound }
        if let requestedProject, requestedProject.sharedHost?.id != hostID || requestedProject.remoteDirectory != directory {
            throw AgentConversationHistoryError.differentProject
        }
        guard let host = requestedProject?.sharedHost
            ?? projects.first(where: { $0.sharedHost?.id == hostID })?.sharedHost
            ?? RemoteHostStore.shared.hosts.first(where: { $0.id == hostID }) else {
            throw AgentConversationHistoryError.unavailableConfiguration
        }
        let info = try await Task.detached(priority: .userInitiated) {
            try RemoteHostClient.fork(host: host, identity: record.identity)
        }.value
        guard info.project == directory, let remoteID = UUID(uuidString: info.sessionId) else {
            throw AgentConversationHistoryError.notFound
        }
        if Task.isCancelled || requestedProject.map({ project in !projects.contains(where: { $0 === project }) }) == true {
            try? await Task.detached { try RemoteHostClient.terminate(host: host, directory: directory, sessionID: remoteID) }.value
            try Task.checkCancellation()
            throw AgentConversationHistoryError.differentProject
        }
        let previousSelection = selectedProjectID
        let project = requestedProject ?? sharedProject(host: host, directory: directory)
        let previousTab = project.selectedTabID
        project.attachRemoteSession(info)
        guard let session = project.sessions.first(where: { $0.remoteConnection?.sessionID == remoteID }) else {
            throw AgentConversationHistoryError.notFound
        }
        session.agentConversationForkSource = record.identity
        let context = ConversationContext(manager: self, project: project, session: session)
        if focus { Self.revealSession(id: session.id) }
        else { selectedProjectID = previousSelection; project.selectedTabID = previousTab }
        try await confirmConversationFork(context, source: record.identity, timeout: timeout)
        return context
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
