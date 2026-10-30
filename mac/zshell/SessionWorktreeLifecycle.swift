import AppKit
import Foundation

extension TerminalManager {
    private enum WorktreeLifecycle {
        static var removingPaths = Set<String>()
        static var closingSessions = Set<UUID>()
        static var creatingProjects = Set<UUID>()
    }

    static func isRemovingWorktree(containing directory: String) -> Bool {
        WorktreeLifecycle.removingPaths.contains { SessionWorktreeService.contains(directory, in: $0) }
    }

    static func worktreeIsInUse(_ path: String, excluding sessionID: UUID? = nil) -> Bool {
        let sessions = automationManagers.flatMap(\.projects).flatMap(\.sessions)
            + GlobalTerminalOverlay.shared.allSessions
        return sessions.contains { session in
            guard session.id != sessionID else { return false }
            return session.worktree?.path == path
                || SessionWorktreeService.contains(session.currentDirectoryPath, in: path)
                || session.foregroundDirectoryPath.map { SessionWorktreeService.contains($0, in: path) } == true
        } || GlobalTerminalOverlay.shared.pendingSessionsUseWorktree(path, excluding: sessionID)
    }

    static func removeWorktreeFromGitPanel(_ worktree: SessionWorktree) async throws {
        guard WorktreeLifecycle.removingPaths.insert(worktree.path).inserted else {
            throw SessionWorktreeError(message: String(localized: "The worktree is being removed. Try again after cleanup finishes."))
        }
        defer { WorktreeLifecycle.removingPaths.remove(worktree.path) }
        try await SessionWorktreeService().remove(worktree, requireMerged: false) {
            await MainActor.run { worktreeIsInUse(worktree.path) }
        }
    }

    func worktreeSourceDirectory(for project: Project) -> String {
        project.selectedSession?.foregroundDirectoryPath
            ?? project.selectedSession?.currentDirectoryPath
            ?? project.customDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    func promptForWorktreeSession(in project: Project? = nil) {
        guard let project = project ?? selectedProject, !project.isRemote else { NSSound.beep(); return }
        Task { @MainActor in
            await NewWorktreeSessionController.present(manager: self, project: project)
        }
    }

    func newWorktreeSession(
        in project: Project, branch: String, directory: String? = nil,
        sourceDirectory: String? = nil, base: SessionWorktreeService.Base = .repositoryDefault,
        expectedHead: String? = nil, commandArguments: [String]? = nil,
        environmentPath: String? = nil, focus: Bool = true
    ) async throws -> TerminalSession {
        guard projects.contains(where: { $0 === project }), !project.isRemote else {
            throw SessionWorktreeError(message: String(localized: "Choose an open local project for the worktree session."))
        }
        guard WorktreeLifecycle.creatingProjects.insert(project.id).inserted else {
            throw SessionWorktreeError(message: String(localized: "A worktree session is already being created in this project."))
        }
        defer { WorktreeLifecycle.creatingProjects.remove(project.id) }
        let service = SessionWorktreeService()
        let worktree = try await service.create(
            in: sourceDirectory ?? worktreeSourceDirectory(for: project), branch: branch,
            at: directory, base: base, expectedHead: expectedHead
        )
        var session: TerminalSession?
        do {
            guard projects.contains(where: { $0 === project }) else {
                throw SessionWorktreeError(message: String(localized: "The project closed before the worktree session could start."))
            }
            let previousTab = project.selectedTabID
            session = project.newSession(directory: worktree.path, commandArguments: commandArguments,
                                         environmentPath: environmentPath, tabTitle: branch, worktree: worktree)
            guard let session else {
                throw SessionWorktreeError(message: String(localized: "The worktree is being removed. Try again after cleanup finishes."))
            }
            if focus { selectedProjectID = project.id }
            if !focus { project.selectedTabID = previousTab }
            guard await session.waitUntilStarted(), projects.contains(where: { $0 === project }),
                  project.sessions.contains(where: { $0.id == session.id }) else {
                throw SessionWorktreeError(message: String(localized: "The terminal could not start in the worktree."))
            }
            return session
        } catch {
            let reserved = WorktreeLifecycle.removingPaths.insert(worktree.path).inserted
            defer { if reserved { WorktreeLifecycle.removingPaths.remove(worktree.path) } }
            var stopped = true
            if let session {
                project.closeContent(.session(session), confirmWorktree: false, recordClosedSession: false)
                stopped = await session.waitUntilTerminated()
            }
            var removed = false
            if reserved, stopped {
                removed = await service.rollback(worktree) {
                    await MainActor.run { Self.worktreeIsInUse(worktree.path) }
                }
            }
            if !removed {
                throw SessionWorktreeError(message: String(localized: "\(error.localizedDescription) The worktree was kept at \(worktree.path)."))
            }
            throw error
        }
    }

    func openWorktreeSession(at path: String) {
        guard let project = selectedProject, !project.isRemote else { NSSound.beep(); return }
        Task { @MainActor in
            do {
                let association = try await SessionWorktreeService().association(at: path, sourceDirectory: path)
                guard projects.contains(where: { $0 === project }) else { return }
                project.newSession(directory: association.path, worktree: association)
            } catch {
                // The primary checkout has no removable association but remains
                // an ordinary terminal target in the existing Git panel.
                if FileManager.default.fileExists(atPath: path) {
                    project.newSession(directory: path)
                } else {
                    await showWorktreeError(error, in: presentationWindow)
                }
            }
        }
    }

    @discardableResult
    func requestCloseWorktreeSession(_ session: TerminalSession, in project: Project) async -> Bool {
        guard let worktree = session.worktree else {
            project.closeContent(.session(session), confirmWorktree: false)
            return true
        }
        guard WorktreeLifecycle.closingSessions.insert(session.id).inserted else { return false }
        defer { WorktreeLifecycle.closingSessions.remove(session.id) }
        var refusal: String?
        do { refusal = try await SessionWorktreeService().inspect(worktree).refusal }
        catch { refusal = error.localizedDescription }
        if Self.worktreeIsInUse(worktree.path, excluding: session.id) {
            refusal = String(localized: "Other open sessions still use this worktree. Close them before removing it.")
        }
        guard projects.contains(where: { $0 === project }), project.sessions.contains(where: { $0.id == session.id }),
              let host = AppWindowPresentation.hostWindow(relativeTo: presentationWindow) else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Close Session in Worktree?")
        let detail = String(localized: "\(worktree.path)\nThe Git branch will be kept.")
        alert.informativeText = refusal.map { detail + "\n\n" + $0 } ?? detail
        alert.addButton(withTitle: String(localized: "Keep Worktree"))
        let remove = alert.addButton(withTitle: String(localized: "Remove Worktree"))
        remove.isEnabled = refusal == nil
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        let response = await alert.beginSheetModal(for: host)
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn,
              project.sessions.contains(where: { $0.id == session.id }) else { return false }
        do {
            _ = try await closeWorktreeSession(session, in: project,
                                              removeWorktree: response == .alertSecondButtonReturn)
            return true
        } catch {
            await showWorktreeError(error, in: host)
            return !project.sessions.contains(where: { $0.id == session.id })
        }
    }

    @discardableResult
    func closeWorktreeSession(_ session: TerminalSession, in project: Project, removeWorktree: Bool) async throws -> Bool {
        guard projects.contains(where: { $0 === project }), project.sessions.contains(where: { $0.id == session.id }) else {
            throw SessionWorktreeError(message: String(localized: "The selected session is no longer available."))
        }
        guard removeWorktree else {
            project.closeContent(.session(session), confirmWorktree: false)
            return false
        }
        guard let worktree = session.worktree else {
            throw SessionWorktreeError(message: String(localized: "This session has no associated worktree."))
        }
        guard WorktreeLifecycle.removingPaths.insert(worktree.path).inserted else {
            throw SessionWorktreeError(message: String(localized: "The worktree is being removed. Try again after cleanup finishes."))
        }
        defer { WorktreeLifecycle.removingPaths.remove(worktree.path) }
        let service = SessionWorktreeService()
        let inspection = try await service.inspect(worktree)
        if let refusal = inspection.refusal { throw SessionWorktreeError(message: refusal) }
        guard !Self.worktreeIsInUse(worktree.path, excluding: session.id) else {
            throw SessionWorktreeError(message: String(localized: "Other open sessions still use this worktree. Close them before removing it."))
        }
        project.closeContent(.session(session), confirmWorktree: false)
        guard await session.waitUntilTerminated() else {
            throw SessionWorktreeError(message: String(localized: "The session is still stopping. Its worktree was kept."))
        }
        do {
            try await service.remove(worktree, expected: inspection) {
                await MainActor.run { Self.worktreeIsInUse(worktree.path) }
            }
            return true
        } catch {
            throw SessionWorktreeError(message: String(localized: "The session closed, but its worktree was kept. \(error.localizedDescription)"))
        }
    }

    func showWorktreeError(_ error: Error, in window: NSWindow?) async {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: window) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Worktree Session")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        _ = await alert.beginSheetModal(for: host)
    }
}
