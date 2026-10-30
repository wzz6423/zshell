import AppKit

@MainActor
enum TerminalCommandHistoryActions {
    static func canReveal(_ entry: TerminalCommandHistoryEntry) -> Bool {
        guard let session = ZshellAutomationRouter.context(forSession: entry.terminalID)?.session,
              !session.hasExited,
              let location = session.commandRecords.first(where: { $0.id == entry.id })?.outputLocation else { return false }
        return session.surface.commandRegion(at: location) != nil
    }

    static func reveal(_ entry: TerminalCommandHistoryEntry) -> Bool {
        guard let session = ZshellAutomationRouter.context(forSession: entry.terminalID)?.session,
              !session.hasExited,
              let location = session.commandRecords.first(where: { $0.id == entry.id })?.outputLocation,
              session.surface.revealCommand(at: location) else { return false }
        return focusOrigin(entry)
    }

    static func isRunning(_ entry: TerminalCommandHistoryEntry) -> Bool {
        guard entry.finishedAt == nil,
              let session = ZshellAutomationRouter.context(forSession: entry.terminalID)?.session,
              !session.hasExited else { return false }
        return session.commandRecords.contains { $0.id == entry.id && $0.finishedAt == nil }
    }

    static func canInsert(_ entry: TerminalCommandHistoryEntry) -> Bool {
        guard entry.isValid,
              let session = ZshellAutomationRouter.context(forSession: entry.terminalID)?.session,
              session.isShellAvailableForAutomation, session.terminalPromptQueueIsReady,
              session.promptQueue.commands.isEmpty,
              !TerminalCommandTaskStore.shared.hasActiveTask(terminalID: session.id) else { return false }
        return true
    }

    static func insert(_ entry: TerminalCommandHistoryEntry) -> Bool {
        guard canInsert(entry),
              let session = ZshellAutomationRouter.context(forSession: entry.terminalID)?.session else { return false }
        session.sendCommand(entry.command, asPaste: true)
        return focusOrigin(entry)
    }

    static func focusOrigin(_ entry: TerminalCommandHistoryEntry) -> Bool {
        guard let context = ZshellAutomationRouter.context(forSession: entry.terminalID),
              let session = context.session, !session.hasExited else { return false }
        TerminalManager.revealSession(id: session.id)
        // Pane selection reparents the existing surface on the next layout pass.
        DispatchQueue.main.async { [weak session] in
            guard let session,
                  let context = ZshellAutomationRouter.context(forSession: session.id),
                  context.manager.selectedProjectID == context.project.id,
                  context.project.selectedTabID == context.tab.id,
                  context.tab.focusedPaneID == context.pane.id else { return }
            session.surface.window?.makeFirstResponder(session.surface)
        }
        return true
    }
}
