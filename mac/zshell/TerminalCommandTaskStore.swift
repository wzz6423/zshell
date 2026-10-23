import Foundation

@MainActor
final class TerminalCommandTaskStore {
    static let shared = TerminalCommandTaskStore()
    private static let retainedResultLimit = 256
    private static let activeTaskLimit = 64
    private var tasks: [UUID: TerminalCommandTask] = [:]
    private var activeByTerminal: [UUID: UUID] = [:]
    private var completionReadyAt: [UUID: UInt64] = [:]
    private var retainedResults: [UUID] = []

    func task(id: UUID, projectID: UUID) -> TerminalCommandTask? {
        guard let task = tasks[id], task.projectID == projectID else { return nil }
        return task
    }

    func hasActiveTask(terminalID: UUID) -> Bool {
        activeByTerminal[terminalID] != nil
    }

    var canSubmit: Bool { activeByTerminal.count < Self.activeTaskLimit }

    func submit(
        argv: [String], projectID: UUID, paneID: UUID,
        session: TerminalSession, afterShellStartup: Bool = false
    ) -> TerminalCommandTask {
        let task = TerminalCommandTask(
            projectID: projectID, paneID: paneID, terminalID: session.id, argv: argv
        )
        tasks[task.id] = task
        guard !hasActiveTask(terminalID: session.id) else {
            stop(task.id, state: .unavailable, code: "shell_busy",
                 message: String(localized: "This terminal already has a pending or running command task."))
            return tasks[task.id]!
        }
        guard canSubmit else {
            stop(task.id, state: .unavailable, code: "task_limit",
                 message: String(localized: "Zshell already has 64 pending or running command tasks. Wait for one to finish before starting another."))
            return tasks[task.id]!
        }
        activeByTerminal[session.id] = task.id
        guard session.supportsCommandTaskShellIntegration else {
            stop(task.id, state: .unsupported, code: "command_wait_unsupported",
                 message: Self.unsupportedMessage)
            return tasks[task.id]!
        }
        Task { [weak session] in
            if afterShellStartup {
                let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
                while let session, !session.hasExited,
                      !session.isCommandTaskShellReady,
                      DispatchTime.now().uptimeNanoseconds < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard self.tasks[task.id]?.state == .pending else { return }
                }
                guard let session, !session.hasExited else {
                    self.stop(task.id, state: .closed, code: "pane_closed",
                              message: String(localized: "The task's terminal was closed before the command finished."))
                    return
                }
                guard session.isCommandTaskShellReady else {
                    self.stop(task.id, state: .unavailable, code: "shell_not_ready",
                              message: String(localized: "The new terminal did not reach an empty shell prompt within 30 seconds."))
                    return
                }
                self.start(task.id, session: session)
            } else if let session {
                self.start(task.id, session: session)
            }
            // The immutable result is authoritative even if a backend drops
            // a completion event. Capture after its PTY output has settled.
            while self.tasks[task.id]?.state.isTerminal == false {
                try? await Task.sleep(for: .milliseconds(100))
                guard let session, !session.hasExited else {
                    self.terminalClosed(id: task.terminalID)
                    return
                }
                self.observeCompletion(in: session)
            }
        }
        return tasks[task.id]!
    }

    func observeCompletion(in session: TerminalSession, captureImmediately: Bool = false) {
        guard let id = activeByTerminal[session.id], var task = tasks[id],
              let directory = session.commandTaskDirectoryURL,
              let shellPID = session.shellPid else { return }
        let result = TerminalCommandTaskShellResult.read(
            taskID: id, shellPID: shellPID, directory: directory
        )
        guard result != nil else { return }
        guard ZshellAutomationRouter.commandTaskIsInOriginalProject(task) else {
            stop(id, state: .unavailable, code: "task_scope_changed",
                 message: String(localized: "The command's terminal moved to another project before its result was captured."))
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if !captureImmediately, completionReadyAt[id] == nil {
            completionReadyAt[id] = now + 50_000_000
            return
        }
        guard captureImmediately || now >= (completionReadyAt[id] ?? now) else { return }
        guard task.observeCompletion(
            sequence: session.commandLifecycle.completionSequence,
            shellResult: result,
            output: {
                session.automationRecentText(
                    maxLines: TerminalCommandTask.outputLimitLines,
                    maxColumns: TerminalCommandTask.outputLimitColumns
                )
            }
        ) else { return }
        tasks[id] = task
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(id.uuidString + ".result")
        )
        retainResult(id)
        session.schedulePromptQueueDispatch()
    }

    func terminalClosed(id: UUID) {
        guard let taskID = activeByTerminal[id] else { return }
        stop(taskID, state: .closed, code: "pane_closed",
             message: String(localized: "The task's terminal was closed before the command finished."))
    }

    func terminalClosed(in session: TerminalSession) {
        observeCompletion(in: session, captureImmediately: true)
        terminalClosed(id: session.id)
    }

    func recordUnsupported(
        argv: [String], projectID: UUID, paneID: UUID, terminalID: UUID
    ) -> TerminalCommandTask {
        var task = TerminalCommandTask(
            projectID: projectID, paneID: paneID, terminalID: terminalID, argv: argv
        )
        task.stop(state: .unsupported, code: "command_wait_unsupported", message: Self.unsupportedMessage)
        tasks[task.id] = task
        retainResult(task.id)
        return task
    }

    static var unsupportedMessage: String {
        String(localized: "Command results require an empty prompt in Zshell's original zsh shell. Nested shells and other startup programs are unsupported.")
    }

    private func start(_ id: UUID, session: TerminalSession) {
        guard var task = tasks[id], task.state == .pending else { return }
        guard ZshellAutomationRouter.commandTaskIsInOriginalProject(task) else {
            stop(id, state: .unavailable, code: "task_scope_changed",
                 message: String(localized: "The command's terminal moved to another project before its result was captured."))
            return
        }
        guard session.isCommandTaskShellReady, let directory = session.commandTaskDirectoryURL else {
            stop(id, state: .unsupported, code: "command_wait_unsupported",
                 message: Self.unsupportedMessage)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            stop(id, state: .unavailable, code: "task_storage_failed",
                 message: String(localized: "Zshell could not prepare the command's result file."))
            return
        }
        task.start()
        tasks[id] = task
        session.cancelPromptQueueDispatch()
        let command = (["_zshell_command_task", id.uuidString] + task.argv)
            .map(TerminalSession.shellQuote).joined(separator: " ")
        session.sendCommand(command)
        session.sendEnter()
    }

    private func stop(_ id: UUID, state: TerminalCommandTask.State, code: String, message: String) {
        guard var task = tasks[id], !task.state.isTerminal else { return }
        task.stop(state: state, code: code, message: message)
        tasks[id] = task
        retainResult(id)
    }

    private func retainResult(_ id: UUID) {
        guard let task = tasks[id] else { return }
        if activeByTerminal[task.terminalID] == id { activeByTerminal[task.terminalID] = nil }
        completionReadyAt[id] = nil
        retainedResults.append(id)
        while retainedResults.count > Self.retainedResultLimit {
            tasks[retainedResults.removeFirst()] = nil
        }
    }
}

extension TerminalSession {
    var isCommandTaskShellReady: Bool {
        guard isShellAvailableForAutomation, terminalPromptQueueIsReady,
              processExecutablePath(pid: shellPid ?? 0).map({ ($0 as NSString).lastPathComponent == "zsh" }) == true,
              let directory = commandTaskDirectoryURL?.deletingLastPathComponent(),
              let shellPID = shellPid,
              let ready = try? String(
                contentsOf: directory.appendingPathComponent("command-task-ready.pid"),
                encoding: .utf8
              ) else { return false }
        return ready.trimmingCharacters(in: .whitespacesAndNewlines) == String(shellPID)
    }
}
