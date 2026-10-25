//
//  ZshellAutomationRouter.swift
//  zshell
//

import AppKit
import Foundation

/// Main-actor command router behind the authenticated Unix socket. A caller's
/// capability resolves to one terminal and therefore one project. Targets are
/// searched only inside that project; no request can reach another window or
/// project by guessing a UUID.
@MainActor
enum ZshellAutomationRouter {
    private struct PaneContext {
        let manager: TerminalManager
        let project: Project
        let tab: PaneTab
        let pane: Pane

        var session: TerminalSession? {
            guard case .session(let session) = pane.content else { return nil }
            return session
        }
    }

    static func route(
        _ request: ZshellAutomationRequest,
        callerTerminalID: UUID
    ) async -> ZshellAutomationResponse {
        guard let caller = context(forSession: callerTerminalID) else {
            return failure(
                request, "caller_closed",
                "The terminal that owned this capability is no longer open."
            )
        }

        switch request.method {
        case "protocol.info":
            return success(request, .object([
                "version": .number(1),
                "scope": .string("project"),
                "current_terminal_id": .string(callerTerminalID.uuidString),
                "reads_mark_seen": .bool(false),
                "split_focus_default": .bool(false),
            ]))

        case "pane.current":
            return success(request, paneSnapshot(caller, caller: caller))

        case "pane.list":
            return success(
                request,
                .array(projectContexts(caller.project, manager: caller.manager).map {
                    paneSnapshot($0, caller: caller)
                })
            )

        case "pane.get":
            guard let target = targetPane(request, caller: caller) else {
                return failure(request, "pane_not_found", "No matching pane exists in this project.")
            }
            return success(request, paneSnapshot(target, caller: caller))

        case "pane.split":
            return splitPane(request, caller: caller)

        case "pane.run":
            return runInPane(request, caller: caller)

        case "pane.task":
            return commandTask(request, caller: caller)

        case "pane.send":
            return sendToPane(request, caller: caller)

        case "pane.read":
            return await readPane(request, caller: caller)

        case "agent.list":
            let agents = projectContexts(caller.project, manager: caller.manager)
                .compactMap { context -> ZshellJSONValue? in
                    guard context.session?.agentStatus != nil else { return nil }
                    return paneSnapshot(context, caller: caller)
                }
            return success(request, .array(agents))

        case "agent.get":
            guard let target = targetAgent(request, caller: caller) else {
                return failure(request, "agent_not_found", "No matching agent exists in this project.")
            }
            return success(request, paneSnapshot(target, caller: caller))

        case "agent.start":
            return startAgent(request, caller: caller)

        case "agent.prompt":
            return promptAgent(request, caller: caller)

        case "agent.report":
            return reportAgent(request, caller: caller)

        case "agent.usage.report":
            // Usage reporting is a private hook installed by Zshell, so it must
            // originate from a real terminal pane the same way `agent.report` does.
            // A non-pane caller has no business writing the global usage snapshot.
            guard caller.session != nil else {
                return failure(
                    request,
                    "terminal_required",
                    "The caller is not a terminal pane."
                )
            }
            guard let usage = request.params["usage"],
                  AgentUsageModel.shared.acceptClaudeStatusLine(usage)
            else {
                return failure(
                    request,
                    "invalid_usage",
                    "usage must contain at least one current Claude Code rate-limit window."
                )
            }
            return success(request, .object(["accepted": .bool(true)]))

        default:
            return failure(
                request, "method_not_found",
                "Unknown automation method \(request.method)."
            )
        }
    }

    private static func splitPane(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) -> ZshellAutomationResponse {
        guard let target = targetPane(request, caller: caller) else {
            return failure(request, "pane_not_found", "No matching pane exists in this project.")
        }
        guard !target.pane.content.isDiff else {
            return failure(request, "pane_not_splittable", "Diff panes cannot be split.")
        }
        guard let edgeName = request.params["edge"]?.stringValue,
              let edge = paneEdge(edgeName)
        else {
            return failure(
                request, "invalid_params",
                "edge must be one of left, right, top, or bottom."
            )
        }
        let focus = request.params["focus"]?.boolValue ?? false
        let directory = request.params["cwd"]?.stringValue
        if let directory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: directory, isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                return failure(
                    request, "invalid_directory",
                    "The requested working directory does not exist."
                )
            }
        }
        let argv: [String]?
        if let value = request.params["argv"] {
            guard let arguments = validatedCommandArguments(value) else {
                return failure(request, "invalid_params",
                               "argv must contain 1 to 256 control-free arguments. Direct exit, logout, or exec cannot return command results; use /bin/sh -c for a finite subprocess.")
            }
            argv = arguments
        } else {
            argv = nil
        }
        if argv != nil {
            guard case .local = caller.project.location, TerminalSession.canLaunchCommandTaskShell else {
                return failure(request, "command_wait_unsupported", unsupportedCommandWaitMessage)
            }
            guard TerminalCommandTaskStore.shared.canSubmit else {
                return failure(request, "task_limit", commandTaskLimitMessage)
            }
        }

        guard let created = caller.project.automationSplitTerminal(
            beside: target.pane.id,
            toward: edge,
            directory: directory,
            focus: focus
        ) else {
            return failure(request, "pane_not_splittable", "The target pane could not be split.")
        }
        if focus { TerminalManager.revealSession(id: created.session.id) }
        let context = PaneContext(
            manager: caller.manager,
            project: caller.project,
            tab: created.tab,
            pane: created.pane
        )
        guard let argv else { return success(request, paneSnapshot(context, caller: caller)) }
        let task = TerminalCommandTaskStore.shared.submit(
            argv: argv, projectID: caller.project.id, paneID: created.pane.id,
            session: created.session, afterShellStartup: true
        )
        return success(request, paneWithTask(context, caller: caller, task: task))
    }

    private static func runInPane(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) -> ZshellAutomationResponse {
        guard let target = targetPane(request, caller: caller),
              let session = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        if request.params["require_command_result"]?.boolValue == true,
           session.id == caller.session?.id {
            return failure(request, "wait_deadlock", commandWaitDeadlockMessage)
        }
        guard session.isShellAvailableForAutomation else {
            if request.params["require_command_result"]?.boolValue == true,
               session.surface.foregroundPid != session.shellPid,
               let foregroundPID = session.surface.foregroundPid,
               let executable = processExecutablePath(pid: foregroundPID),
               ["zsh", "bash", "fish", "sh"].contains((executable as NSString).lastPathComponent) {
                return failure(request, "command_wait_unsupported", unsupportedCommandWaitMessage)
            }
            return failure(
                request, "shell_busy",
                "The target terminal does not have an available foreground shell."
            )
        }
        guard let argv = validatedCommandArguments(request.params["argv"]) else {
            return failure(
                request, "invalid_params",
                "argv must contain 1 to 256 control-free arguments. Direct exit, logout, or exec cannot return command results; use /bin/sh -c for a finite subprocess."
            )
        }
        guard !TerminalCommandTaskStore.shared.hasActiveTask(terminalID: session.id) else {
            return failure(request, "shell_busy", commandTaskBusyMessage)
        }
        if session.isCommandTaskShellReady {
            guard TerminalCommandTaskStore.shared.canSubmit else {
                return failure(request, "task_limit", commandTaskLimitMessage)
            }
            let task = TerminalCommandTaskStore.shared.submit(
                argv: argv, projectID: caller.project.id, paneID: target.pane.id,
                session: session
            )
            return success(request, paneWithTask(target, caller: caller, task: task))
        }
        if request.params["require_command_result"]?.boolValue == true {
            return failure(request, "command_wait_unsupported", unsupportedCommandWaitMessage)
        }
        if session.supportsCommandTaskShellIntegration,
           session.surface.foregroundPid == session.shellPid {
            return failure(request, "shell_not_ready", unsupportedCommandWaitMessage)
        }
        let task = TerminalCommandTaskStore.shared.recordUnsupported(
            argv: argv, projectID: caller.project.id, paneID: target.pane.id, terminalID: session.id
        )
        let command = argv.map(shellQuote).joined(separator: " ")
        session.sendCommand(command)
        session.sendEnter()
        return success(request, paneWithTask(target, caller: caller, task: task))
    }

    private static var unsupportedCommandWaitMessage: String {
        TerminalCommandTaskStore.unsupportedMessage
    }

    private static var commandTaskBusyMessage: String {
        String(localized: "This terminal already has a pending or running command task.")
    }

    private static var commandTaskLimitMessage: String {
        String(localized: "Zshell already has 64 pending or running command tasks. Wait for one to finish before starting another.")
    }

    private static var commandWaitDeadlockMessage: String {
        String(localized: "A command cannot wait for its own terminal. Run or wait from another pane, or create a split with --wait.")
    }

    private static func validatedCommandArguments(_ value: ZshellJSONValue?) -> [String]? {
        guard let argv = stringArray(value), !argv.isEmpty, argv.count <= 256,
              !argv[0].isEmpty,
              !TerminalCommandTaskShellIntegration.replacesOriginalShell(argv),
              argv.allSatisfy({ $0.utf8.count <= 16_384 && isSafeShellArgument($0) }),
              argv.map(TerminalSession.shellQuote).joined(separator: " ").utf8.count <= 65_536
        else { return nil }
        return argv
    }

    private static func paneWithTask(
        _ target: PaneContext, caller: PaneContext, task: TerminalCommandTask
    ) -> ZshellJSONValue {
        var value = paneSnapshot(target, caller: caller).objectValue ?? [:]
        value["task_id"] = .string(task.id.uuidString)
        value["task"] = task.json
        return .object(value)
    }

    private static func commandTask(
        _ request: ZshellAutomationRequest, caller: PaneContext
    ) -> ZshellAutomationResponse {
        guard let value = request.params["task_id"]?.stringValue,
              let id = UUID(uuidString: value) else {
            return failure(request, "invalid_params", "task_id must be a command task UUID.")
        }
        guard let task = TerminalCommandTaskStore.shared.task(id: id, projectID: caller.project.id) else {
            return failure(request, "task_not_found",
                           String(localized: "No matching command task is retained in this project. The task may belong to another project, have expired, or predate this app session."))
        }
        if let target = context(forSession: task.terminalID), target.project.id != caller.project.id {
            return failure(request, "task_not_found",
                           String(localized: "No matching command task is retained in this project. The task may belong to another project, have expired, or predate this app session."))
        }
        if request.params["wait"]?.boolValue == true, !task.state.isTerminal,
           task.terminalID == caller.session?.id {
            return failure(request, "wait_deadlock", commandWaitDeadlockMessage)
        }
        return success(request, .object([
            "task_id": .string(id.uuidString),
            "task": task.json,
        ]))
    }

    static func commandTaskIsInOriginalProject(_ task: TerminalCommandTask) -> Bool {
        context(forSession: task.terminalID)?.project.id == task.projectID
    }

    private static func sendToPane(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) -> ZshellAutomationResponse {
        guard let target = targetPane(request, caller: caller),
              let session = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        guard let text = request.params["text"]?.stringValue,
              text.utf8.count <= 262_144 else {
            return failure(
                request, "invalid_params",
                "text is required and is limited to 256 KiB."
            )
        }
        session.sendCommand(text)
        if request.params["enter"]?.boolValue == true {
            session.sendEnter()
        }
        return success(request, paneSnapshot(target, caller: caller))
    }

    private static func readPane(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) async -> ZshellAutomationResponse {
        guard let callerSessionID = caller.session?.id else {
            return failure(
                request, "caller_closed",
                "The terminal that owned this capability is no longer open."
            )
        }
        guard let target = targetPane(request, caller: caller),
              let session = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        let targetPaneID = target.pane.id
        let targetSessionID = session.id
        let lines = min(max(request.params["lines"]?.intValue ?? 80, 1), 500)
        let columns = min(max(request.params["columns"]?.intValue ?? 400, 1), 2_000)
        do {
            let text = try await session.automationReadText(
                maxLines: lines,
                maxColumns: columns,
                requireIdleAgentForHistory:
                    request.params["require_idle_agent"]?.boolValue == true
            )
            guard let currentCaller = context(forSession: callerSessionID) else {
                return failure(
                    request, "caller_closed",
                    "The terminal that owned this capability is no longer open."
                )
            }
            guard let currentTarget = targetPane(request, caller: currentCaller),
                  currentTarget.pane.id == targetPaneID,
                  currentTarget.session?.id == targetSessionID else {
                return failure(
                    request, "pane_not_found",
                    "No matching pane exists in this project."
                )
            }
            return success(request, .object([
                "pane": paneSnapshot(currentTarget, caller: currentCaller),
                "text": .string(text),
                "lines": .number(Double(lines)),
                "columns": .number(Double(columns)),
            ]))
        } catch ZshellAutomationReadError.agentNotIdle {
            return failure(
                request,
                "agent_not_idle",
                "Alternate-screen transcript history is available only after the agent settles. Wait for idle or done, then read again."
            )
        } catch {
            return failure(
                request,
                "read_failed",
                "Zshell could not read the terminal transcript."
            )
        }
    }

    private static func startAgent(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) -> ZshellAutomationResponse {
        guard let target = targetPane(request, caller: caller),
              let session = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        guard session.isShellAvailableForAutomation else {
            return failure(
                request, "shell_busy",
                "Agents can start only in an existing terminal with an available shell."
            )
        }
        guard !TerminalCommandTaskStore.shared.hasActiveTask(terminalID: session.id) else {
            return failure(request, "shell_busy", commandTaskBusyMessage)
        }
        guard session.agentStatus == nil else {
            return failure(
                request, "agent_already_declared",
                "This terminal already has an active or pending agent."
            )
        }
        guard let alias = request.params["alias"]?.stringValue,
              isValidAlias(alias) else {
            return failure(
                request, "invalid_alias",
                "alias must be 1 to 64 ASCII letters, numbers, dots, underscores, or hyphens."
            )
        }
        guard let kindName = request.params["kind"]?.stringValue,
              let kind = ZshellAgentKind(rawValue: kindName) else {
            return failure(
                request, "invalid_agent_kind",
                "Supported kinds: \(ZshellAgentKind.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        let duplicate = caller.project.sessions.contains {
            $0.id != session.id && $0.agentStatus?.alias == alias
        }
        guard !duplicate else {
            return failure(
                request, "alias_in_use",
                "Another agent in this project already uses alias \(alias)."
            )
        }
        let extra = stringArray(request.params["argv"]) ?? []
        guard extra.count <= 128,
              extra.allSatisfy({
                  $0.utf8.count <= 16_384 && isSafeShellArgument($0)
              }) else {
            return failure(
                request, "invalid_params",
                "Agent arguments exceed the protocol limits or contain terminal control characters."
            )
        }

        session.declareAutomationAgent(alias: alias, kind: kind)
        let command = ([kind.executable] + extra).map(shellQuote).joined(separator: " ")
        session.sendCommand(command)
        session.sendEnter()
        if request.params["focus"]?.boolValue == true {
            TerminalManager.revealSession(id: session.id)
        }
        return success(request, paneSnapshot(target, caller: caller))
    }

    private static func promptAgent(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) -> ZshellAutomationResponse {
        guard let target = targetAgent(request, caller: caller),
              let session = target.session,
              let status = session.agentStatus else {
            return failure(request, "agent_not_found", "No matching agent exists in this project.")
        }
        guard status.phase == .created
                || status.phase == .working
                || status.phase == .idle
                || status.phase == .done else {
            return failure(
                request, "agent_not_ready",
                "\(status.alias) is \(status.phase.rawValue); guarded prompts require created, working, idle, or done. Use +pane send for explicit raw input."
            )
        }
        guard session.isAutomationAgentRunning(kind: status.kind) else {
            return failure(
                request, "agent_not_running",
                "\(status.alias) has exited; start it again before sending a guarded prompt."
            )
        }
        guard let prompt = request.params["text"]?.stringValue,
              !prompt.isEmpty, prompt.utf8.count <= 262_144,
              isSafePromptText(prompt) else {
            return failure(
                request, "invalid_prompt",
                "Prompt text must be non-empty, contain no terminal control characters, and fit within 256 KiB."
            )
        }

        let normalized = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.contains("\n") {
            session.sendCommand("\u{1b}[200~" + normalized + "\u{1b}[201~")
        } else {
            session.sendCommand(normalized)
        }
        session.sendEnter()
        session.markAutomationAgentPrompted()
        return success(request, paneSnapshot(target, caller: caller))
    }

    private static func reportAgent(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) -> ZshellAutomationResponse {
        guard let session = caller.session else {
            return failure(request, "terminal_required", "The caller is not a terminal pane.")
        }
        guard let name = request.params["state"]?.stringValue,
              let phase = ZshellAgentPhase(rawValue: name),
              phase != .created else {
            return failure(
                request, "invalid_params",
                "state must be working, blocked, done, idle, or unknown."
            )
        }
        let reason = request.params["reason"]?.stringValue
        guard reason?.utf8.count ?? 0 <= 4_096 else {
            return failure(request, "invalid_params", "reason is limited to 4 KiB.")
        }
        guard session.reportAutomationAgent(phase: phase, reason: reason) else {
            return failure(
                request, "agent_not_recognized",
                "Declare or start an agent in this terminal before reporting its state."
            )
        }
        return success(request, paneSnapshot(caller, caller: caller))
    }

    private static func targetPane(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) -> PaneContext? {
        guard let value = request.params["pane_id"] else { return caller }
        guard let string = value.stringValue, let id = UUID(uuidString: string) else {
            return nil
        }
        return projectContexts(caller.project, manager: caller.manager)
            .first { $0.pane.id == id }
    }

    private static func targetAgent(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) -> PaneContext? {
        if request.params["pane_id"] != nil {
            guard let pane = targetPane(request, caller: caller),
                  pane.session?.agentStatus != nil else { return nil }
            return pane
        }
        if let alias = request.params["alias"]?.stringValue {
            return projectContexts(caller.project, manager: caller.manager).first {
                $0.session?.agentStatus?.alias == alias
            }
        }
        return caller.session?.agentStatus == nil ? nil : caller
    }

    private static func context(forSession id: UUID) -> PaneContext? {
        for manager in TerminalManager.automationManagers {
            for project in manager.projects {
                for tab in project.tabs {
                    for pane in tab.allPanes {
                        guard case .session(let session) = pane.content,
                              session.id == id else { continue }
                        return PaneContext(
                            manager: manager, project: project, tab: tab, pane: pane
                        )
                    }
                }
            }
        }
        return nil
    }

    private static func projectContexts(
        _ project: Project,
        manager: TerminalManager
    ) -> [PaneContext] {
        project.tabs.flatMap { tab in
            tab.allPanes.map {
                PaneContext(manager: manager, project: project, tab: tab, pane: $0)
            }
        }
    }

    private static func paneSnapshot(
        _ context: PaneContext,
        caller: PaneContext
    ) -> ZshellJSONValue {
        let contentKind: String = switch context.pane.content {
        case .session: "terminal"
        case .file: "file"
        case .browser: "browser"
        case .diff: "diff"
        }
        var object: [String: ZshellJSONValue] = [
            "project_id": .string(context.project.id.uuidString),
            "project_name": .string(context.project.name),
            "tab_id": .string(context.tab.id.uuidString),
            "pane_id": .string(context.pane.id.uuidString),
            "content": .string(contentKind),
            "title": .string(context.pane.content.title),
            "is_caller": .bool(context.pane.id == caller.pane.id),
            "is_focused": .bool(
                context.manager.selectedProjectID == context.project.id
                    && context.project.selectedTabID == context.tab.id
                    && context.tab.focusedPaneID == context.pane.id
            ),
        ]
        if let session = context.session {
            object["terminal_id"] = .string(session.id.uuidString)
            object["cwd"] = .string(session.currentDirectoryPath)
            object["shell_available"] = .bool(session.isShellAvailableForAutomation)
            object["exited"] = .bool(session.hasExited)
            object["agent"] = session.agentStatus.map(agentSnapshot) ?? .null
        }
        return .object(object)
    }

    private static func agentSnapshot(_ status: ZshellAgentStatus) -> ZshellJSONValue {
        .object([
            "alias": .string(status.alias),
            "kind": .string(status.kind.rawValue),
            "state": .string(status.phase.rawValue),
            "authority": .string(status.authority.rawValue),
            "reason": .string(status.reason),
            "updated_at": .string(ISO8601DateFormatter().string(from: status.updatedAt)),
            "process_id": status.processID.map { .number(Double($0)) } ?? .null,
            "unseen": .bool(status.unseen),
        ])
    }

    private static func paneEdge(_ value: String) -> PaneDropEdge? {
        switch value {
        case "left": return .left
        case "right": return .right
        case "top", "up": return .top
        case "bottom", "down": return .bottom
        default: return nil
        }
    }

    private static func stringArray(_ value: ZshellJSONValue?) -> [String]? {
        guard let values = value?.arrayValue else { return nil }
        let strings = values.compactMap(\.stringValue)
        return strings.count == values.count ? strings : nil
    }

    private static func isValidAlias(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isSafePromptText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value))
                || scalar.value == 0x0A
                || scalar.value == 0x0D
                || scalar.value == 0x09
        }
    }

    private static func isSafeShellArgument(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func success(
        _ request: ZshellAutomationRequest,
        _ result: ZshellJSONValue
    ) -> ZshellAutomationResponse {
        .success(id: request.id, result: result)
    }

    private static func failure(
        _ request: ZshellAutomationRequest,
        _ code: String,
        _ message: String
    ) -> ZshellAutomationResponse {
        .failure(id: request.id, code: code, message: message)
    }
}
