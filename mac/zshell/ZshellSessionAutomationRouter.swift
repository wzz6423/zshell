import AppKit
import Foundation

@MainActor
enum ZshellSessionAutomationRouter {
    static func routeExternal(_ request: ZshellAutomationRequest) async -> ZshellAutomationResponse {
        guard let peer = request.peerProcessID, peer > 1 else {
            return failure(request, "invalid_external_caller", "Session control requires kernel process credentials.")
        }
        // Clearing bridge variables does not turn a pane's program into an
        // external controller. Kernel ancestry preserves its project scope.
        for manager in TerminalManager.automationManagers {
            for project in manager.projects {
                if let session = project.sessions.first(where: {
                    !$0.hasExited && $0.shellPid.map { ZshellAgentProcessIdentity.isDescendant(peer, of: $0) } == true
                }) {
                    return await route(request, manager: manager, project: project,
                                       caller: ZshellAutomationRouter.context(forSession: session.id))
                }
            }
        }
        if request.method == "session.projects" {
            guard request.params.isEmpty else { return failure(request, "invalid_params", "projects accepts no parameters.") }
            return .success(id: request.id, result: .array(TerminalManager.automationManagers.flatMap { manager in
                manager.projects.map(projectSnapshot)
            }))
        }
        guard let id = request.params["project_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let owner = TerminalManager.automationManagers.first(where: { $0.projects.contains(where: { $0.id == id }) }),
              let project = owner.projects.first(where: { $0.id == id }) else {
            return failure(request, "project_required", "Choose an open project with --project. Run `zshell +session projects` to list IDs.")
        }
        return await route(request, manager: owner, project: project)
    }

    static func route(
        _ request: ZshellAutomationRequest, manager: TerminalManager, project: Project,
        caller: ZshellAutomationRouter.PaneContext? = nil
    ) async -> ZshellAutomationResponse {
        if let target = request.params["project_id"], target.stringValue != project.id.uuidString {
            return failure(request, "project_scope_violation", "This terminal can only control sessions in its own project.")
        }
        if request.method == "session.projects" {
            guard request.params.isEmpty else { return failure(request, "invalid_params", "projects accepts no parameters.") }
            return .success(id: request.id, result: .array([projectSnapshot(project)]))
        }
        switch request.method {
        case "session.list":
            guard Set(request.params.keys).isSubset(of: ["project_id"]) else { return invalidParams(request) }
            return .success(id: request.id, result: .array(project.sessions.compactMap {
                sessionSnapshot($0, caller: caller)
            }))
        case "session.new":
            return await newSession(request, manager: manager, project: project, caller: caller)
        case "session.check", "session.close":
            guard Set(request.params.keys).isSubset(of: ["project_id", "session_id", "remove_worktree"]),
                  request.params["remove_worktree"] == nil || request.params["remove_worktree"]?.boolValue != nil,
                  let id = request.params["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let session = project.sessions.first(where: { $0.id == id }) else {
                return failure(request, "session_not_found", "No matching session exists in this project.")
            }
            do {
                if request.method == "session.check" {
                    guard let worktree = session.worktree else {
                        return failure(request, "no_worktree", "This session has no associated worktree.")
                    }
                    let inspection = try await SessionWorktreeService().inspect(worktree)
                    let shared = TerminalManager.worktreeIsInUse(worktree.path, excluding: session.id)
                    let reason = shared
                        ? String(localized: "Other open sessions still use this worktree. Close them before removing it.")
                        : inspection.refusal
                    return .success(id: request.id, result: .object([
                        "session_id": .string(id.uuidString), "worktree": worktree.snapshot,
                        "changed_paths": .number(Double(inspection.changedPaths)),
                        "unmerged_commits": inspection.unmergedCommits.map { .number(Double($0)) } ?? .null,
                        "shared": .bool(shared), "can_remove": .bool(inspection.canRemove && !shared),
                        "reason": reason.map(ZshellJSONValue.string) ?? .null,
                    ]))
                }
                let remove = request.params["remove_worktree"]?.boolValue ?? false
                let removed = try await manager.closeWorktreeSession(session, in: project, removeWorktree: remove)
                return .success(id: request.id, result: .object([
                    "session_id": .string(id.uuidString), "closed": .bool(true), "worktree_removed": .bool(removed),
                ]))
            } catch {
                return failure(request, "worktree_cleanup_refused", error.localizedDescription)
            }
        default:
            return failure(request, "method_not_found", "External session control cannot invoke \(request.method).")
        }
    }

    private static func newSession(
        _ request: ZshellAutomationRequest, manager: TerminalManager, project: Project,
        caller: ZshellAutomationRouter.PaneContext?
    ) async -> ZshellAutomationResponse {
        guard !project.isRemote else {
            return failure(request, "local_project_required", "Session control currently requires a local project.")
        }
        let allowed: Set<String> = ["project_id", "branch", "cwd", "worktree_path", "base", "focus", "argv", "path"]
        guard Set(request.params.keys).isSubset(of: allowed),
              request.params["focus"] == nil || request.params["focus"]?.boolValue != nil else { return invalidParams(request) }
        for key in ["branch", "cwd", "worktree_path", "base", "path"] {
            if let value = request.params[key], value.stringValue == nil { return invalidParams(request) }
        }
        let directory = request.params["cwd"]?.stringValue
        if let value = request.params["cwd"], value.stringValue == nil { return invalidParams(request) }
        if let directory, !directory.hasPrefix("/") || directory.contains("\0") {
            return failure(request, "invalid_directory", "cwd must be an absolute directory.")
        }
        if let directory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                return failure(request, "invalid_directory", "cwd must be an existing directory.")
            }
        }
        var argv: [String]?
        if let value = request.params["argv"] {
            guard let values = value.arrayValue, !values.isEmpty, values.count <= 256 else { return invalidParams(request) }
            let strings = values.compactMap(\.stringValue)
            guard strings.count == values.count, strings.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 16_384 }) else {
                return invalidParams(request)
            }
            argv = strings
        }
        let focus = request.params["focus"]?.boolValue ?? false
        do {
            let session: TerminalSession
            if let branch = request.params["branch"]?.stringValue {
                let base: SessionWorktreeService.Base = switch request.params["base"]?.stringValue ?? "default" {
                case "default": .repositoryDefault
                case "HEAD": .currentHead
                case let value: .reference(value)
                }
                session = try await manager.newWorktreeSession(in: project, branch: branch,
                    directory: request.params["worktree_path"]?.stringValue, sourceDirectory: directory,
                    base: base, commandArguments: argv, environmentPath: request.params["path"]?.stringValue, focus: focus)
            } else {
                guard request.params["worktree_path"] == nil, request.params["base"] == nil else { return invalidParams(request) }
                let previous = project.selectedTabID
                guard let created = project.newSession(directory: directory, commandArguments: argv,
                                                       environmentPath: request.params["path"]?.stringValue) else {
                    return failure(request, "worktree_busy", "The target worktree is being removed.")
                }
                session = created
                if focus { manager.selectedProjectID = project.id }
                if !focus { project.selectedTabID = previous }
                guard await session.waitUntilStarted() else {
                    project.closeContent(.session(session), confirmWorktree: false, recordClosedSession: false)
                    return failure(request, "session_start_failed", "The terminal could not start.")
                }
            }
            guard let snapshot = sessionSnapshot(session, caller: caller) else {
                return failure(request, "session_start_failed", "The new session exited before it could be returned.")
            }
            return .success(id: request.id, result: snapshot)
        } catch {
            return failure(request, "worktree_session_failed", error.localizedDescription)
        }
    }

    private static func projectSnapshot(_ project: Project) -> ZshellJSONValue {
        .object(["project_id": .string(project.id.uuidString), "name": .string(project.name),
                 "remote": .bool(project.isRemote), "sessions": .number(Double(project.sessions.count))])
    }

    private static func sessionSnapshot(_ session: TerminalSession, caller: ZshellAutomationRouter.PaneContext?) -> ZshellJSONValue? {
        guard let context = ZshellAutomationRouter.context(forSession: session.id) else { return nil }
        return ZshellAutomationRouter.paneSnapshot(context, caller: caller)
    }

    private static func invalidParams(_ request: ZshellAutomationRequest) -> ZshellAutomationResponse {
        failure(request, "invalid_params", "The session command contains invalid parameters.")
    }

    private static func failure(_ request: ZshellAutomationRequest, _ code: String, _ message: String) -> ZshellAutomationResponse {
        .failure(id: request.id, code: code, message: message)
    }
}

extension SessionWorktree {
    var snapshot: ZshellJSONValue {
        .object(["path": .string(path), "repository_root": .string(repositoryRoot),
                 "branch": branch.map(ZshellJSONValue.string) ?? .null,
                 "base": baseReference.map(ZshellJSONValue.string) ?? .null])
    }
}
