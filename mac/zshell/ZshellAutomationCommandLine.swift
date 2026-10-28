//
//  ZshellAutomationCommandLine.swift
//  zshell
//

import Foundation

/// Script-facing wrappers for Zshell's local automation protocol. Pane and agent
/// operations return JSON so scripts can compose stable IDs and state. Skill
/// management is human-readable by default and offers explicit `--json` output.
enum ZshellAutomationCommandLine {
    static func run(namespace: String, arguments: [String]) throws -> Int32 {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
            namespace == "+pane" ? printPaneHelp() : printAgentHelp()
            return 0
        }
        if namespace == "+agent", arguments == ["explain"] {
            printAgentContract()
            return 0
        }
        if namespace == "+agent", arguments.first == "_integration" {
            runAgentIntegration(Array(arguments.dropFirst()))
            return 0
        }
        if namespace == "+agent", arguments.first == "_lifecycle" {
            runAgentLifecycle(Array(arguments.dropFirst()))
            return 0
        }
        if namespace == "+agent", arguments.first == "_usage-statusline" {
            runAgentUsageStatusLine(Array(arguments.dropFirst()))
            return 0
        }
        if namespace == "+agent", arguments.first == "_session-start" {
            runAgentSessionStart(Array(arguments.dropFirst()))
            return 0
        }
        if namespace == "+agent", arguments.first == "skill" {
            try runAgentSkill(Array(arguments.dropFirst()))
            return 0
        }
        if namespace == "+agent", let command = arguments.first,
           ["history", "resume", "archive", "unarchive", "delete"].contains(command) {
            try AgentConversationHistoryCommandLine.run(arguments: arguments)
            return 0
        }

        let connection = try AppConnection()
        let result: ZshellJSONValue
        switch namespace {
        case "+pane":
            result = try runPane(arguments, connection: connection)
        case "+agent":
            result = try runAgent(arguments, connection: connection)
        default:
            throw CLIError.message("Unknown automation namespace \(namespace).")
        }
        try printJSON(result)
        return namespace == "+pane" ? TerminalCommandTaskWait.exitCode(for: result) : 0
    }

    // MARK: - Pane commands

    private static func runPane(
        _ arguments: [String],
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        let command = arguments[0]
        let tail = Array(arguments.dropFirst())
        switch command {
        case "current":
            try requireNoArguments(tail, command: "+pane current")
            return try connection.automationRequest(method: "pane.current")
        case "list":
            try requireNoArguments(tail, command: "+pane list")
            return try connection.automationRequest(method: "pane.list")
        case "protocol":
            try requireNoArguments(tail, command: "+pane protocol")
            return try connection.automationRequest(method: "protocol.info")
        case "get":
            let pane = try parsePaneOnly(tail, command: "+pane get")
            return try connection.automationRequest(
                method: "pane.get",
                params: targetParams(paneID: pane)
            )
        case "split":
            return try splitPane(tail, connection: connection)
        case "run":
            return try runInPane(tail, connection: connection)
        case "wait":
            return try waitForCommandTask(tail, connection: connection)
        case "send":
            return try sendToPane(tail, connection: connection)
        case "read":
            return try readPane(tail, connection: connection)
        case "wait-output":
            return try waitForOutput(tail, connection: connection)
        case "help", "--help", "-h":
            printPaneHelp()
            return .object(["help": .bool(true)])
        default:
            throw CLIError.message(
                "Unknown +pane command \(command). Run `zshell +pane --help`."
            )
        }
    }

    private static func splitPane(
        _ arguments: [String],
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        var paneID: String?
        var edge = "right"
        var cwd: String?
        var focus = false
        var wait = false
        var timeoutMS = 30_000
        var argv: [String]?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--" {
                argv = Array(arguments.dropFirst(index + 1))
                break
            }
            switch arguments[index] {
            case "--pane": paneID = try value(after: &index, in: arguments, option: "--pane")
            case "--current": paneID = nil
            case "--left": edge = "left"
            case "--right": edge = "right"
            case "--up", "--top": edge = "top"
            case "--down", "--bottom": edge = "bottom"
            case "--cwd": cwd = try value(after: &index, in: arguments, option: "--cwd")
            case "--focus": focus = true
            case "--no-focus": focus = false
            case "--wait": wait = true
            case "--timeout": timeoutMS = try integerValue(after: &index, in: arguments, option: "--timeout")
            default:
                throw unknownOption(arguments[index], command: "+pane split")
            }
            index += 1
        }
        var params = targetParams(paneID: paneID)
        params["edge"] = .string(edge)
        params["focus"] = .bool(focus)
        if let cwd { params["cwd"] = .string(cwd) }
        if let argv {
            guard !argv.isEmpty else { throw CLIError.message(String(localized: "No command was provided after `--`.")) }
            params["argv"] = .array(argv.map(ZshellJSONValue.string))
        }
        guard !wait || argv != nil else {
            throw CLIError.message(String(localized: "`zshell +pane split --wait` requires `-- command [arguments...]`."))
        }
        try validateTimeout(timeoutMS)
        let result = try connection.automationRequest(method: "pane.split", params: params)
        return try commandResult(result, wait: wait, timeoutMS: timeoutMS, connection: connection)
    }

    private static func runInPane(
        _ arguments: [String],
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        var paneID: String?
        var wait = false
        var timeoutMS = 30_000
        var index = 0
        while index < arguments.count, arguments[index] != "--" {
            switch arguments[index] {
            case "--pane": paneID = try value(after: &index, in: arguments, option: "--pane")
            case "--current": paneID = nil
            case "--wait": wait = true
            case "--timeout": timeoutMS = try integerValue(after: &index, in: arguments, option: "--timeout")
            default: throw unknownOption(arguments[index], command: "+pane run")
            }
            index += 1
        }
        guard index < arguments.count, arguments[index] == "--" else {
            throw CLIError.message("`zshell +pane run` requires `-- command [arguments...]`.")
        }
        let argv = Array(arguments.dropFirst(index + 1))
        guard !argv.isEmpty else {
            throw CLIError.message(String(localized: "No command was provided after `--`."))
        }
        var params = targetParams(paneID: paneID)
        params["argv"] = .array(argv.map(ZshellJSONValue.string))
        params["require_command_result"] = .bool(wait)
        try validateTimeout(timeoutMS)
        let result = try connection.automationRequest(method: "pane.run", params: params)
        return try commandResult(result, wait: wait, timeoutMS: timeoutMS, connection: connection)
    }

    private static func commandResult(
        _ result: ZshellJSONValue, wait: Bool, timeoutMS: Int, connection: AppConnection
    ) throws -> ZshellJSONValue {
        guard wait else { return result }
        guard let taskID = result.objectValue?["task_id"]?.stringValue else {
            throw CLIError.message(String(localized: "Zshell did not return a command task ID."))
        }
        return try TerminalCommandTaskWait.wait(
            taskID: taskID, timeoutMS: timeoutMS, connection: connection, initialResult: result
        )
    }

    private static func waitForCommandTask(
        _ arguments: [String], connection: AppConnection
    ) throws -> ZshellJSONValue {
        var taskID: String?
        var timeoutMS = 30_000
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--task": taskID = try value(after: &index, in: arguments, option: "--task")
            case "--timeout": timeoutMS = try integerValue(after: &index, in: arguments, option: "--timeout")
            default: throw unknownOption(arguments[index], command: "+pane wait")
            }
            index += 1
        }
        guard let taskID, UUID(uuidString: taskID) != nil else {
            throw CLIError.message(String(localized: "`zshell +pane wait` requires --task UUID from +pane run or split."))
        }
        try validateTimeout(timeoutMS)
        return try TerminalCommandTaskWait.wait(
            taskID: taskID, timeoutMS: timeoutMS, connection: connection
        )
    }

    private static func sendToPane(
        _ arguments: [String],
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        var paneID: String?
        var text: String?
        var enter = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane": paneID = try value(after: &index, in: arguments, option: "--pane")
            case "--current": paneID = nil
            case "--text": text = try value(after: &index, in: arguments, option: "--text")
            case "--enter": enter = true
            default: throw unknownOption(arguments[index], command: "+pane send")
            }
            index += 1
        }
        guard let text else {
            throw CLIError.message("`zshell +pane send` requires --text.")
        }
        var params = targetParams(paneID: paneID)
        params["text"] = .string(text)
        params["enter"] = .bool(enter)
        return try connection.automationRequest(method: "pane.send", params: params)
    }

    private static func readPane(
        _ arguments: [String],
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        let options = try parseReadOptions(arguments, command: "+pane read")
        return try connection.automationRequest(
            method: "pane.read",
            params: readParams(options)
        )
    }

    private static func waitForOutput(
        _ arguments: [String],
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        var read = ReadOptions()
        var needle: String?
        var timeoutMS = 30_000
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane": read.paneID = try value(after: &index, in: arguments, option: "--pane")
            case "--current": read.paneID = nil
            case "--lines": read.lines = try integerValue(after: &index, in: arguments, option: "--lines")
            case "--columns": read.columns = try integerValue(after: &index, in: arguments, option: "--columns")
            case "--contains": needle = try value(after: &index, in: arguments, option: "--contains")
            case "--timeout": timeoutMS = try integerValue(after: &index, in: arguments, option: "--timeout")
            default: throw unknownOption(arguments[index], command: "+pane wait-output")
            }
            index += 1
        }
        guard let needle, !needle.isEmpty else {
            throw CLIError.message("`zshell +pane wait-output` requires --contains.")
        }
        try validateTimeout(timeoutMS)
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1_000)
        repeat {
            let result = try connection.automationRequest(
                method: "pane.read", params: readParams(read)
            )
            if result.objectValue?["text"]?.stringValue?.contains(needle) == true {
                return result
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw CLIError.message("Timed out waiting for terminal output containing \(needle.debugDescription).")
    }

    // MARK: - Agent commands

    private static func runAgentSessionStart(_ arguments: [String]) {
        guard arguments.count == 1,
              let provider = AgentConversationIdentity.Provider(rawValue: arguments[0])
        else { return }
        let environment = ProcessInfo.processInfo.environment
        let isSharedCodex = provider == .codex && AgentConversationBinding.sharedCodexServicePID(
            peerPID: getpid(), reporterPID: getpid(), process: TerminalSession.conversationProcessEvidence
        ) != nil
        guard (environment["ZSHELL_AUTOMATION"] == "1" || isSharedCodex),
              let data = try? FileHandle.standardInput.read(upToCount: 1_048_577),
              let event = AgentConversationSessionEvent.sessionStart(
                provider: provider,
                payload: data,
                environment: environment,
                reporterPID: ProcessInfo.processInfo.processIdentifier,
                currentDirectory: FileManager.default.currentDirectoryPath
              ),
              let identityData = try? JSONEncoder().encode(event.identity),
              let identity = try? JSONDecoder().decode(ZshellJSONValue.self, from: identityData)
        else { return }
        sendNativeHook(
            method: "agent.session.start",
            params: [
                "identity": identity,
                "reporter_pid": .number(Double(event.reporterPID)),
                "source": event.source.map(ZshellJSONValue.string) ?? .null,
            ], isSharedCodex: isSharedCodex
        )
    }

    /// Private entry point for lifecycle hooks installed by Zshell. It is
    /// intentionally absent from help and never appears in an agent prompt.
    /// Hook failures stay passive; screen hints never become native evidence.
    private static func runAgentIntegration(_ arguments: [String]) {
        guard arguments.count == 2 || arguments.count == 3,
              arguments[0] == "grok",
              let phase = ZshellAgentPhase(rawValue: arguments[1]),
              phase == .working || phase == .blocked || phase == .idle
        else { return }

        let isGenuineStop = arguments.count == 3
            && arguments[2] == "--genuine-stop"
        if phase == .idle {
            // Process recognition owns startup idle. The only lifecycle event
            // allowed to end a Grok turn is a validated genuine Stop, which
            // also makes older cached SessionStart hooks harmless.
            guard isGenuineStop,
                  let event = try? JSONDecoder().decode(
                    ZshellJSONValue.self,
                    from: FileHandle.standardInput.readDataToEndOfFile()
                  ),
                  event.objectValue?["reason"]?.stringValue == "end_turn"
            else { return }
        } else if arguments.count != 2 {
            return
        }

        guard let connection = try? AppConnection() else { return }
        _ = try? connection.automationRequest(
            method: "agent.lifecycle",
            params: [
                "provider": .string("grok"),
                "state": .string(phase.rawValue),
                "attention": phase == .blocked ? .string("error") : .null,
            ],
            timeout: 15
        )
    }

    /// No hook output ever grants or denies approval. Only the small semantic
    /// fields are forwarded; prompts, tool arguments, and transcripts stay out.
    private static func runAgentLifecycle(_ arguments: [String]) {
        guard arguments.count == 1,
              let provider = ZshellAgentKind(rawValue: arguments[0]),
              provider == .codex || provider == .claude,
              let data = try? boundedInput(maximum: 1_048_576),
              let value = try? JSONDecoder().decode(ZshellJSONValue.self, from: data),
              let object = value.objectValue,
              ZshellAgentLifecycleEvent.parse(provider: provider, payload: object) != nil
        else { return }
        let fields: Set<String> = ["hook_event_name", "session_id", "parent_session_id", "agent_id", "agent_type", "notification_type", "error", "tool_name"]
        let event = object.filter { fields.contains($0.key) }
        let isSharedCodex = provider == .codex && AgentConversationBinding.sharedCodexServicePID(
            peerPID: getpid(), reporterPID: getpid(), process: TerminalSession.conversationProcessEvidence
        ) != nil
        sendNativeHook(
            method: "agent.lifecycle",
            params: ["provider": .string(provider.rawValue), "event": .object(event)],
            isSharedCodex: isSharedCodex
        )
        if provider == .codex,
           ["Stop", "SubagentStop"].contains(object["hook_event_name"]?.stringValue ?? "") {
            print("{}")
        }
    }

    private static func sendNativeHook(
        method: String, params: [String: ZshellJSONValue], isSharedCodex: Bool
    ) {
        if isSharedCodex {
            if let bundleIdentifier = Bundle.main.bundleIdentifier,
               let connection = try? AgentConversationHistoryConnection.discover(bundleIdentifier: bundleIdentifier) {
                _ = try? connection.request(method: method, params: params, timeout: 1)
            }
        } else if let connection = try? AppConnection() {
            _ = try? connection.automationRequest(method: method, params: params, timeout: 1)
        }
    }

    private static func boundedInput(maximum: Int) throws -> Data {
        var result = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: min(8_192, maximum + 1 - result.count)),
              !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= maximum else { throw CLIError.message("Input exceeds the report limit.") }
        }
        return result
    }

    /// Private Claude Code status-line adapter. It forwards only provider-owned
    /// percentages and reset epochs; the rest of the session payload is dropped.
    private static func runAgentUsageStatusLine(_ arguments: [String]) {
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        guard arguments.isEmpty, payload.count <= 1_048_576,
              let input = try? JSONDecoder().decode(ZshellJSONValue.self, from: payload),
              let rateLimits = input.objectValue?["rate_limits"]?.objectValue
        else { return }

        var windows: [String: ZshellJSONValue] = [:]
        for key in ["five_hour", "seven_day", "spend_limit"] {
            guard let source = rateLimits[key]?.objectValue,
                  case .number(let percent)? = source["used_percentage"],
                  percent.isFinite, percent >= 0
            else { continue }
            var window: [String: ZshellJSONValue] = [
                "used_percentage": .number(percent),
            ]
            if case .number(let epoch)? = source["resets_at"], epoch.isFinite {
                window["resets_at"] = .number(epoch)
            }
            windows[key] = .object(window)
        }
        guard !windows.isEmpty, let connection = try? AppConnection() else { return }
        _ = try? connection.automationRequest(
            method: "agent.usage.report",
            params: ["usage": .object(["windows": .object(windows)])],
            timeout: 1
        )
    }

    private static func runAgentSkill(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printAgentSkillHelp()
            return
        }
        let tail = Array(arguments.dropFirst())
        switch command {
        case "path":
            try requireNoArguments(tail, command: "+agent skill path")
            print(try ZshellAutomationSkill.bundledSkillURL().path)

        case "print":
            try requireNoArguments(tail, command: "+agent skill print")
            let contents = try ZshellAutomationSkill.bundledSkillText()
            print(contents, terminator: contents.hasSuffix("\n") ? "" : "\n")

        case "status":
            let options = try parseSkillOptions(
                tail,
                command: "+agent skill status",
                allowsForce: false
            )
            let destinations = try ZshellAutomationSkill.destinations(for: options.provider)
            let snapshots = try ZshellAutomationSkill.status(destinations: destinations)
            if options.json {
                var values: [ZshellJSONValue] = []
                for snapshot in snapshots { values.append(skillSnapshot(snapshot)) }
                try printJSON(skillResult(
                    action: "status",
                    provider: options.provider,
                    destinations: values,
                    changed: false
                ))
            } else {
                printSkillStatus(snapshots)
            }

        case "install":
            let options = try parseSkillOptions(
                tail,
                command: "+agent skill install",
                allowsForce: true
            )
            let destinations = try ZshellAutomationSkill.destinations(for: options.provider)
            let results = try ZshellAutomationSkill.install(
                destinations: destinations,
                force: options.force
            )
            let changed = results.contains { $0.previousState != .current }
            if options.json {
                var values: [ZshellJSONValue] = []
                for result in results { values.append(skillMutation(result)) }
                try printJSON(skillResult(
                    action: "install",
                    provider: options.provider,
                    destinations: values,
                    changed: changed,
                    reloadRecommended: changed
                ))
            } else {
                printSkillInstall(results, changed: changed)
            }

        case "uninstall":
            let options = try parseSkillOptions(
                tail,
                command: "+agent skill uninstall",
                allowsForce: true
            )
            let destinations = try ZshellAutomationSkill.destinations(for: options.provider)
            let results = try ZshellAutomationSkill.uninstall(
                destinations: destinations,
                force: options.force
            )
            let changed = results.contains { $0.previousState != .missing }
            if options.json {
                var values: [ZshellJSONValue] = []
                for result in results { values.append(skillMutation(result)) }
                try printJSON(skillResult(
                    action: "uninstall",
                    provider: options.provider,
                    destinations: values,
                    changed: changed,
                    reloadRecommended: changed
                ))
            } else {
                printSkillUninstall(results, changed: changed)
            }

        case "help", "--help", "-h":
            printAgentSkillHelp()

        default:
            throw CLIError.message(
                "Unknown +agent skill command \(command). Run `zshell +agent skill --help`."
            )
        }
    }

    private struct SkillOptions {
        var provider = "all"
        var force = false
        var json = false
    }

    private static func parseSkillOptions(
        _ arguments: [String],
        command: String,
        allowsForce: Bool
    ) throws -> SkillOptions {
        var result = SkillOptions()
        var didSetProvider = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--provider", "--for":
                guard !didSetProvider else {
                    throw CLIError.message("Choose only one --provider value.")
                }
                let option = arguments[index]
                result.provider = try value(
                    after: &index,
                    in: arguments,
                    option: option
                )
                didSetProvider = true
            case "--force" where allowsForce:
                result.force = true
            case "--json":
                result.json = true
            default:
                throw unknownOption(arguments[index], command: command)
            }
            index += 1
        }
        return result
    }

    private static func printSkillStatus(
        _ snapshots: [ZshellAutomationSkill.Snapshot]
    ) {
        print("Zshell automation skill")
        for snapshot in snapshots {
            print("  \(agentNames(snapshot.destination)): \(skillStateLabel(snapshot.state))")
            print("    \(abbreviatedHomePath(snapshot.url))")
        }
    }

    private static func printSkillInstall(
        _ results: [ZshellAutomationSkill.MutationResult],
        changed: Bool
    ) {
        if changed {
            print("Installed Zshell automation skill.")
        } else {
            print("Zshell automation skill is already installed and current.")
        }
        for result in results {
            let action = result.previousState == .current ? "Already linked" : "Linked"
            print("  \(agentNames(result.destination)): \(action)")
            print("    \(abbreviatedHomePath(result.url))")
        }
        if changed {
            print("\nRestart running agents to load the skill.")
        }
    }

    private static func printSkillUninstall(
        _ results: [ZshellAutomationSkill.MutationResult],
        changed: Bool
    ) {
        if changed {
            print("Uninstalled Zshell automation skill.")
        } else {
            print("Zshell automation skill is not installed.")
        }
        for result in results {
            let action = result.previousState == .missing ? "Not installed" : "Removed"
            print("  \(agentNames(result.destination)): \(action)")
            print("    \(abbreviatedHomePath(result.url))")
        }
        if changed {
            print("\nRestart running agents to refresh their available skills.")
        }
    }

    private static func agentNames(_ destination: ZshellAutomationSkill.Destination) -> String {
        let displayNames = destination.agents.map { agent in
            switch agent {
            case "codex": "Codex"
            case "gemini": "Gemini"
            case "grok": "Grok"
            case "cursor": "Cursor"
            case "opencode": "OpenCode"
            case "claude": "Claude"
            case "amp": "Amp"
            case "pi": "Pi"
            default: agent
            }
        }
        return displayNames.joined(separator: ", ")
    }

    private static func skillStateLabel(
        _ state: ZshellAutomationSkill.InstallationState
    ) -> String {
        switch state {
        case .missing: "Not installed"
        case .current: "Installed and current"
        case .updateAvailable: "Needs relinking"
        case .unmanaged: "Present but not managed by Zshell"
        case .modified: "Locally modified"
        }
    }

    private static func abbreviatedHomePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    private static func skillSnapshot(
        _ item: ZshellAutomationSkill.Snapshot
    ) -> ZshellJSONValue {
        .object([
            "destination": .string(item.destination.rawValue),
            "agents": .array(item.destination.agents.map(ZshellJSONValue.string)),
            "path": .string(item.url.path),
            "state": .string(item.state.rawValue),
        ])
    }

    private static func skillMutation(
        _ item: ZshellAutomationSkill.MutationResult
    ) -> ZshellJSONValue {
        .object([
            "destination": .string(item.destination.rawValue),
            "agents": .array(item.destination.agents.map(ZshellJSONValue.string)),
            "path": .string(item.url.path),
            "previous_state": .string(item.previousState.rawValue),
            "state": .string(item.state.rawValue),
        ])
    }

    private static func skillResult(
        action: String,
        provider: String,
        destinations: [ZshellJSONValue],
        changed: Bool,
        reloadRecommended: Bool = false
    ) throws -> ZshellJSONValue {
        .object([
            "skill": .string(ZshellAutomationSkill.name),
            "action": .string(action),
            "provider": .string(provider),
            "source_path": .string(try ZshellAutomationSkill.bundledSkillURL().path),
            "destinations": .array(destinations),
            "changed": .bool(changed),
            "reload_or_restart_agents": .bool(reloadRecommended),
        ])
    }

    private static func runAgent(
        _ arguments: [String],
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        let command = arguments[0]
        let tail = Array(arguments.dropFirst())
        switch command {
        case "list":
            try requireNoArguments(tail, command: "+agent list")
            return try connection.automationRequest(method: "agent.list")
        case "get":
            let target = try parseAgentTarget(tail, command: "+agent get")
            return try connection.automationRequest(
                method: "agent.get", params: target.params
            )
        case "start":
            return try startAgent(tail, connection: connection)
        case "prompt":
            return try promptAgent(tail, connection: connection)
        case "read":
            return try readAgent(tail, connection: connection)
        case "wait":
            return try waitForAgent(tail, connection: connection)
        case "report":
            return try reportAgent(tail, connection: connection)
        case "clear":
            try requireNoArguments(tail, command: "+agent clear")
            return try connection.automationRequest(method: "agent.clear")
        case "help", "--help", "-h":
            printAgentHelp()
            return .object(["help": .bool(true)])
        default:
            throw CLIError.message(
                "Unknown +agent command \(command). Run `zshell +agent --help`."
            )
        }
    }

    private static func reportAgent(
        _ arguments: [String], connection: AppConnection
    ) throws -> ZshellJSONValue {
        var params: [String: ZshellJSONValue]
        if arguments == ["--json"] {
            let data = try boundedInput(maximum: 32_768)
            guard let value = try JSONDecoder().decode(ZshellJSONValue.self, from: data).objectValue else {
                throw CLIError.message("Report JSON must be an object.")
            }
            params = value
        } else {
            guard let state = arguments.first, !state.hasPrefix("--") else {
                throw CLIError.message("`zshell +agent report` requires STATE or --json on stdin.")
            }
            params = ["state": .string(state), "name": .string("Program")]
            if state == "running" { params["state"] = .string("working") }
            if ZshellAgentAttention(rawValue: state) != nil {
                params["state"] = .string("blocked")
                params["attention"] = .string(state)
            }
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--name", "--reason", "--attention":
                    let option = arguments[index]
                    params[String(option.dropFirst(2))] = .string(try value(after: &index, in: arguments, option: option))
                case "--progress", "--pid":
                    let option = arguments[index]
                    let number = try integerValue(after: &index, in: arguments, option: option)
                    params[option == "--pid" ? "process_id" : "progress"] = .number(Double(number))
                case "--tasks":
                    let text = try value(after: &index, in: arguments, option: "--tasks")
                    guard text.utf8.count <= 32_768 else { throw CLIError.message("Task JSON exceeds 32 KiB.") }
                    params["tasks"] = try JSONDecoder().decode(ZshellJSONValue.self, from: Data(text.utf8))
                default: throw unknownOption(arguments[index], command: "+agent report")
                }
                index += 1
            }
        }
        if params["process_id"] == nil { params["process_id"] = .number(Double(getppid())) }
        _ = try ZshellAgentReport(params: params)
        return try connection.automationRequest(method: "agent.report", params: params)
    }

    private static func startAgent(
        _ arguments: [String],
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        guard let alias = arguments.first, !alias.hasPrefix("--") else {
            throw CLIError.message("`zshell +agent start` requires an alias.")
        }
        var paneID: String?
        var kind: String?
        var focus = false
        var timeoutMS = 30_000
        var extra: [String] = []
        var index = 1
        while index < arguments.count {
            if arguments[index] == "--" {
                extra = Array(arguments.dropFirst(index + 1))
                break
            }
            switch arguments[index] {
            case "--pane": paneID = try value(after: &index, in: arguments, option: "--pane")
            case "--current": paneID = nil
            case "--kind": kind = try value(after: &index, in: arguments, option: "--kind")
            case "--focus": focus = true
            case "--no-focus": focus = false
            case "--timeout": timeoutMS = try integerValue(
                after: &index, in: arguments, option: "--timeout"
            )
            default: throw unknownOption(arguments[index], command: "+agent start")
            }
            index += 1
        }
        guard let kind else {
            throw CLIError.message("`zshell +agent start` requires --kind.")
        }
        guard (3_000...300_000).contains(timeoutMS) else {
            throw CLIError.message("Agent start timeout must be between 3000 and 300000 milliseconds.")
        }
        var params = targetParams(paneID: paneID)
        params["alias"] = .string(alias)
        params["kind"] = .string(kind)
        params["focus"] = .bool(focus)
        params["argv"] = .array(extra.map(ZshellJSONValue.string))
        let launched = try connection.automationRequest(method: "agent.start", params: params)
        return try pollAgentStarted(
            target: stableTarget(
                from: launched,
                fallback: AgentTarget(alias: alias, paneID: paneID)
            ),
            timeoutMS: timeoutMS,
            connection: connection
        )
    }

    private static func promptAgent(
        _ arguments: [String],
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        var target = AgentTarget()
        var prompt: String?
        var wait = false
        var timeoutMS = 120_000
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane": target.paneID = try value(after: &index, in: arguments, option: "--pane")
            case "--text": prompt = try value(after: &index, in: arguments, option: "--text")
            case "--wait": wait = true
            case "--timeout": timeoutMS = try integerValue(after: &index, in: arguments, option: "--timeout")
            default:
                if arguments[index].hasPrefix("--") {
                    throw unknownOption(arguments[index], command: "+agent prompt")
                }
                positional.append(arguments[index])
            }
            index += 1
        }
        if target.paneID == nil, !positional.isEmpty {
            target.alias = positional.removeFirst()
        }
        if prompt == nil, !positional.isEmpty {
            prompt = positional.joined(separator: " ")
            positional.removeAll()
        }
        guard positional.isEmpty else {
            throw CLIError.message("Unexpected positional arguments after --text.")
        }
        guard target.alias != nil || target.paneID != nil else {
            throw CLIError.message("Name an agent alias or pass --pane.")
        }
        guard let prompt, !prompt.isEmpty else {
            throw CLIError.message("Pass prompt text with --text or after the alias.")
        }
        var params = target.params
        params["text"] = .string(prompt)
        let submitted = try connection.automationRequest(method: "agent.prompt", params: params, timeout: 15)
        guard wait else { return submitted }
        try validateTimeout(timeoutMS)
        return try pollAgent(
            target: stableTarget(from: submitted, fallback: target),
            states: [.idle, .done, .blocked],
            timeoutMS: timeoutMS,
            connection: connection
        )
    }

    private static func readAgent(
        _ arguments: [String],
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        var targetArgs: [String] = []
        var lines = 120
        var columns = 400
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--lines": lines = try integerValue(after: &index, in: arguments, option: "--lines")
            case "--columns": columns = try integerValue(after: &index, in: arguments, option: "--columns")
            default: targetArgs.append(arguments[index])
            }
            index += 1
        }
        let target = try parseAgentTarget(targetArgs, command: "+agent read")
        let agent = try connection.automationRequest(method: "agent.get", params: target.params)
        guard let paneID = agent.objectValue?["pane_id"]?.stringValue else {
            throw CLIError.message("Zshell returned an agent without a pane ID.")
        }
        return try connection.automationRequest(method: "pane.read", params: [
            "pane_id": .string(paneID),
            "lines": .number(Double(lines)),
            "columns": .number(Double(columns)),
            "require_idle_agent": .bool(true),
        ])
    }

    private static func waitForAgent(
        _ arguments: [String],
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        var targetArgs: [String] = []
        var stateNames = "idle,done,blocked"
        var timeoutMS = 120_000
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--state": stateNames = try value(after: &index, in: arguments, option: "--state")
            case "--timeout": timeoutMS = try integerValue(after: &index, in: arguments, option: "--timeout")
            default: targetArgs.append(arguments[index])
            }
            index += 1
        }
        let target = try parseAgentTarget(targetArgs, command: "+agent wait")
        let states = try parseAgentStates(stateNames)
        try validateTimeout(timeoutMS)
        return try pollAgent(
            target: target,
            states: states,
            timeoutMS: timeoutMS,
            connection: connection
        )
    }

    private static func pollAgent(
        target: AgentTarget,
        states: Set<ZshellAgentPhase>,
        timeoutMS: Int,
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1_000)
        repeat {
            let result = try connection.automationRequest(
                method: "agent.get", params: target.params
            )
            if let agent = result.objectValue?["agent"]?.objectValue,
               agent["authority"]?.stringValue != "screen",
               let name = agent["state"]?.stringValue,
               let phase = ZshellAgentPhase(rawValue: name), states.contains(phase) {
                return result
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw CLIError.message(
            "Timed out waiting for agent state \(states.map(\.rawValue).sorted().joined(separator: ", "))."
        )
    }

    private static func pollAgentStarted(
        target: AgentTarget,
        timeoutMS: Int,
        connection: AppConnection
    ) throws -> ZshellJSONValue {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1_000)
        repeat {
            do {
                let result = try connection.automationRequest(
                    method: "agent.get", params: target.params
                )
                if let agent = result.objectValue?["agent"]?.objectValue,
                   agent["authority"]?.stringValue != ZshellAgentStateAuthority.command.rawValue,
                   case .number? = agent["process_id"] {
                    return result
                }
            } catch let error as CLIError {
                guard case .message(let message) = error,
                      message.hasPrefix("agent_not_found:") else {
                    throw error
                }
                throw CLIError.message(
                    "agent_not_running: The launched agent exited before Zshell recognized it."
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw CLIError.message("Timed out waiting for Zshell to recognize the launched agent.")
    }

    // MARK: - Parsing

    private struct ReadOptions {
        var paneID: String?
        var lines = 80
        var columns = 400
    }

    private struct AgentTarget {
        var alias: String?
        var paneID: String?

        var params: [String: ZshellJSONValue] {
            if let paneID { return ["pane_id": .string(paneID)] }
            if let alias { return ["alias": .string(alias)] }
            return [:]
        }
    }

    private static func parsePaneOnly(
        _ arguments: [String], command: String
    ) throws -> String? {
        var paneID: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane": paneID = try value(after: &index, in: arguments, option: "--pane")
            case "--current": paneID = nil
            default: throw unknownOption(arguments[index], command: command)
            }
            index += 1
        }
        return paneID
    }

    private static func parseReadOptions(
        _ arguments: [String], command: String
    ) throws -> ReadOptions {
        var result = ReadOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane": result.paneID = try value(after: &index, in: arguments, option: "--pane")
            case "--current": result.paneID = nil
            case "--lines": result.lines = try integerValue(after: &index, in: arguments, option: "--lines")
            case "--columns": result.columns = try integerValue(after: &index, in: arguments, option: "--columns")
            default: throw unknownOption(arguments[index], command: command)
            }
            index += 1
        }
        return result
    }

    private static func parseAgentTarget(
        _ arguments: [String], command: String
    ) throws -> AgentTarget {
        var result = AgentTarget()
        var current = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane":
                guard result.paneID == nil, result.alias == nil, !current else {
                    throw CLIError.message("Choose exactly one agent alias, --pane, or --current.")
                }
                result.paneID = try value(after: &index, in: arguments, option: "--pane")
            case "--current":
                guard result.paneID == nil, result.alias == nil, !current else {
                    throw CLIError.message("Choose exactly one agent alias, --pane, or --current.")
                }
                current = true
            default:
                guard !arguments[index].hasPrefix("--"), result.alias == nil,
                      result.paneID == nil, !current else {
                    throw unknownOption(arguments[index], command: command)
                }
                result.alias = arguments[index]
            }
            index += 1
        }
        guard result.paneID != nil || result.alias != nil || current else {
            throw CLIError.message("\(command) requires an agent alias, --pane, or --current.")
        }
        return result
    }

    private static func stableTarget(
        from snapshot: ZshellJSONValue,
        fallback: AgentTarget
    ) -> AgentTarget {
        guard let paneID = snapshot.objectValue?["pane_id"]?.stringValue else {
            return fallback
        }
        return AgentTarget(alias: nil, paneID: paneID)
    }

    private static func readParams(_ options: ReadOptions) -> [String: ZshellJSONValue] {
        var params = targetParams(paneID: options.paneID)
        params["lines"] = .number(Double(options.lines))
        params["columns"] = .number(Double(options.columns))
        return params
    }

    private static func targetParams(paneID: String?) -> [String: ZshellJSONValue] {
        paneID.map { ["pane_id": .string($0)] } ?? [:]
    }

    private static func parseAgentStates(_ value: String) throws -> Set<ZshellAgentPhase> {
        let values = value.split(separator: ",").map(String.init)
        let states = Set(values.compactMap(ZshellAgentPhase.init(rawValue:)))
        guard !values.isEmpty, states.count == values.count else {
            throw CLIError.message(
                "--state accepts comma-separated created, working, blocked, done, idle, or unknown."
            )
        }
        return states
    }

    static func value(
        after index: inout Int,
        in arguments: [String],
        option: String
    ) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw CLIError.message("\(option) requires a value.")
        }
        return arguments[index]
    }

    static func integerValue(
        after index: inout Int,
        in arguments: [String],
        option: String
    ) throws -> Int {
        let raw = try value(after: &index, in: arguments, option: option)
        guard let result = Int(raw), result > 0 else {
            throw CLIError.message("\(option) requires a positive integer.")
        }
        return result
    }

    private static func validateTimeout(_ milliseconds: Int) throws {
        guard (100...3_600_000).contains(milliseconds) else {
            throw CLIError.message("Timeout must be between 100 and 3600000 milliseconds.")
        }
    }

    private static func requireNoArguments(
        _ arguments: [String], command: String
    ) throws {
        guard arguments.isEmpty else { throw unknownOption(arguments[0], command: command) }
    }

    private static func unknownOption(_ value: String, command: String) -> CLIError {
        .message("Unknown option \(value) for `zshell \(command)`. Run `zshell \(command.components(separatedBy: " ").first ?? command) --help`.")
    }

    static func printJSON(_ value: ZshellJSONValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let output = String(data: data, encoding: .utf8) else {
            throw CLIError.message("Could not encode Zshell's automation response.")
        }
        print(output)
    }

    // MARK: - Help

    private static func printPaneHelp() {
        print("""
        Usage:
          zshell +pane current
          zshell +pane list
          zshell +pane get [--pane ID | --current]
          zshell +pane split [--pane ID] [--left|--right|--up|--down] [--cwd PATH] [--focus] [--wait] [--timeout MS] [-- command [arguments...]]
          zshell +pane run [--pane ID] [--wait] [--timeout MS] -- command [arguments...]
          zshell +pane wait --task UUID [--timeout MS]
          zshell +pane send [--pane ID] --text TEXT [--enter]
          zshell +pane read [--pane ID] [--lines N] [--columns N]
          zshell +pane wait-output [--pane ID] --contains TEXT [--timeout MS]
          zshell +pane protocol

        Targets default to the invoking terminal. Splits default to the right
        and never steal focus unless --focus is explicit. `run` accepts argv
        and quotes each argument for the target shell. `send` is raw input.
        All successful results are JSON; reads do not mark agent output seen.
        Commands in the original zsh shell return a stable task_id. --wait and
        `wait --task` exit with the command's own status and include task.exit_code,
        task.duration_ms, and bounded task.output. Output is a recent screen snapshot,
        may include earlier commands or the prompt, and sets output_complete=false.
        Timeout exits 124, sets timed_out,
        and leaves the task running so it can be waited on again. Task results
        remain in this app session until the oldest of 256 retained results expires.
        There can be at most 64 pending or running tasks. A new split waits up to
        30 seconds for an empty original zsh prompt. Running --wait against the caller's
        pane, or waiting for an active task in that pane, is rejected.
        Nested shells, SSH, and custom startup programs do not support command results.
        Arguments are control-free, at most 256, 16 KiB each and 64 KiB quoted total.
        Direct exit, logout, and exec are rejected; run them inside /bin/sh -c.
        wait-output watches text; it does not prove that a command finished.
        """)
    }

    private static func printAgentHelp() {
        print("""
        Usage:
          zshell +agent list
          zshell +agent get ALIAS | --pane ID | --current
          zshell +agent start ALIAS --kind KIND [--pane ID] [--focus] [--timeout MS] [-- agent-arguments...]
          zshell +agent prompt ALIAS --text TEXT [--wait] [--timeout MS]
          zshell +agent read ALIAS [--lines N] [--columns N]
          zshell +agent wait ALIAS [--state idle,done,blocked] [--timeout MS]
          zshell +agent report STATE [--name NAME] [--reason TEXT] [--progress 0-100] [--attention REASON] [--tasks JSON] [--pid PID]
          zshell +agent report --json < report.json
          zshell +agent clear
          zshell +agent history [projects | --all | --archived] [--query TEXT]
          zshell +agent resume --id UUID [--focus]
          zshell +agent archive|unarchive|delete --id UUID
          zshell +agent skill <path|print|status|install|uninstall> [options]
          zshell +agent explain

        Supported kinds: codex, claude, gemini, grok, opencode, cursor-agent,
        aider, amp, and pi. Agent start requires an existing available shell and
        never creates layout; it returns after Zshell recognizes the launched process.
        Guarded prompts accept agents in created, working, idle, or done. While
        an agent is working, its CLI decides whether input steers the active
        turn or queues it. Use +pane send only when raw input is intentional.
        Native lifecycle reports take priority over explicit program reports,
        then bounded screen inference and process detection. Screen inference
        never means completion and cannot satisfy `wait`. Report states are
        working, blocked, done, idle, or unknown; running aliases working, and
        approval, input, login, or error alias blocked with that attention reason.
        Reports belong only to the invoking terminal and a live ancestor process
        (the parent process by default). They expire after 120 seconds without
        an update; long jobs should refresh them. At most 32 child tasks and
        10 updates per second are accepted. `clear` removes the caller's report.
        A native idle background agent appears as done until its pane is focused.
        Codex hooks must first be reviewed in its /hooks menu. `skill install`
        explicitly links Zshell's bundled coordination skill into supported
        agents; it never changes user files unless invoked.
        """)
        print(String(localized: "Run `zshell +agent history --help` for persistent conversation history and external-terminal access."))
    }

    private static func printAgentSkillHelp() {
        print("""
        Usage:
          zshell +agent skill path
          zshell +agent skill print
          zshell +agent skill status [--provider PROVIDER] [--json]
          zshell +agent skill install [--provider PROVIDER] [--force] [--json]
          zshell +agent skill uninstall [--provider PROVIDER] [--force] [--json]

        PROVIDER may be all, universal, codex, claude, gemini, grok, cursor,
        opencode, amp, or pi. The default is all. Codex, Gemini, Cursor,
        Grok, OpenCode, Amp, and Pi share ~/.agents/skills; Claude uses
        ~/.claude/skills. Existing local changes are never replaced or removed
        without --force. Installation uses symlinks to Zshell's app bundle, so
        app updates update the skill without reinstalling it. Reload skills or
        restart an already-running agent after first installation or a Zshell
        update.

        path and print expose Zshell's read-only bundled skill without installing
        it. Management commands are human-readable by default; pass --json for
        stable machine-readable output.
        """)
    }

    private static func printAgentContract() {
        print("""
        Zshell agent automation contract

        1. A pane is layout. A terminal is raw I/O. An agent is a recognized
           terminal occupant with semantic state. These IDs are not interchangeable.
        2. Capabilities are scoped to the invoking terminal's project. Guessed
           IDs in other projects and windows are never resolved.
        3. Creation is explicit: split first, then start an agent in that shell.
           Neither start nor prompt silently creates or closes layout.
        4. Background operations default to no focus. Reading output never marks
           a completion seen; focusing its pane does.
        5. Agent prompts require both a live recognized process and an allowed
           lifecycle state. Raw +pane send is a visibly separate escape hatch
           and can interact with any terminal program.
        6. A recognized process Zshell launched is created until its first prompt.
           Native lifecycle takes priority over explicit program reports, then
           bounded screen inference and process detection. Inference is labelled,
           never means completion, cannot satisfy a lifecycle wait, and never
           approves prompts. A program report describes its own terminal and
           expires after 120 seconds or when its owning process exits. It is
           status information, not proof that a command succeeded.
        7. The optional zshell-automation Agent Skill teaches this workflow to
           compatible agents. Enable AI in Settings or install it explicitly
           with `zshell +agent skill install`. The AI setting also manages only
           the provider integrations Zshell can use as lifecycle authorities.
           Both the skill and those integrations link to Zshell's app bundle so
           app updates do not leave stale copies installed.
        """)
    }
}
