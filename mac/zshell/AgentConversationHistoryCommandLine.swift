import Foundation

enum AgentConversationHistoryCommandLine {
    struct Options {
        var method = "list"
        var query = ""
        var filter = "recent"
        var id: UUID?
        var projectID: UUID?
        var windowID: UUID?
        var connectionURL: URL?
        var focus = false

        var params: [String: ZshellJSONValue] {
            var values: [String: ZshellJSONValue] = [:]
            if let id { values["id"] = .string(id.uuidString) }
            if let projectID { values["project_id"] = .string(projectID.uuidString) }
            if let windowID { values["window_id"] = .string(windowID.uuidString) }
            if method == "list" {
                values["query"] = .string(query)
                values["filter"] = .string(filter)
            }
            if method == "resume" || method == "fork" { values["focus"] = .bool(focus) }
            return values
        }
    }

    static func isPaneInvocation(_ environment: [String: String]) -> Bool {
        ["ZSHELL_CLI_STATE", "ZSHELL_CLI_TOKEN", "ZSHELL_AUTOMATION_SOCKET", "ZSHELL_AUTOMATION_TOKEN",
         "ZSHELL_TERMINAL_ID", "ZSHELL_PERSISTENT_CONNECTION"].contains { environment[$0] != nil }
    }

    static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if arguments.isEmpty || arguments.dropFirst().contains("--help") || arguments.dropFirst().contains("-h") {
            printHelp()
            return
        }
        let options = try parse(arguments)
        let result: ZshellJSONValue
        if isPaneInvocation(environment) {
            guard options.projectID == nil, options.windowID == nil, options.connectionURL == nil else {
                throw CLIError.message("History operations inside a Zshell pane use only that pane’s project. Remove --project, --window, and --connection.")
            }
            let connection = try AppConnection(environment: environment)
            result = try connection.automationRequest(method: "agent.history.\(options.method)", params: options.params,
                timeout: options.method == "fork" ? 45 : 5)
        } else {
            guard options.method == "projects" || options.projectID != nil else {
                throw CLIError.message("External history operations require --project UUID. Run `zshell +agent history projects` first.")
            }
            let connection = try options.connectionURL.map { try AgentConversationHistoryConnection.load(from: $0) }
                ?? AgentConversationHistoryConnection.discover()
            result = try connection.request(method: "history.\(options.method)", params: options.params,
                timeout: options.method == "fork" ? 45 : 5)
        }
        try ZshellAutomationCommandLine.printJSON(result)
    }

    static func parse(_ arguments: [String]) throws -> Options {
        guard let command = arguments.first,
              ["history", "resume", "fork", "archive", "unarchive", "delete"].contains(command) else {
            throw CLIError.message("Unknown conversation history command.")
        }
        var result = Options()
        result.method = command == "history" ? "list" : command
        var index = 1
        if command == "history", arguments.dropFirst().first == "projects" {
            result.method = "projects"
            index += 1
        }
        var seen = Set<String>()
        while index < arguments.count {
            let option = arguments[index]
            guard seen.insert(option).inserted else { throw CLIError.message("Duplicate history option \(option).") }
            switch option {
            case "--id" where result.method != "list" && result.method != "projects":
                result.id = try uuid(after: &index, in: arguments, option: option)
            case "--project" where result.method != "projects":
                result.projectID = try uuid(after: &index, in: arguments, option: option)
            case "--window" where result.method == "resume" || result.method == "fork":
                result.windowID = try uuid(after: &index, in: arguments, option: option)
            case "--connection":
                let path = try ZshellAutomationCommandLine.value(after: &index, in: arguments, option: option)
                guard AgentConversationIdentity.isAbsolutePath(path) else { throw CLIError.message("--connection requires an absolute path.") }
                result.connectionURL = URL(fileURLWithPath: path)
            case "--query" where result.method == "list":
                result.query = try ZshellAutomationCommandLine.value(after: &index, in: arguments, option: option)
                guard result.query.utf8.count <= 1_024,
                      !result.query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw CLIError.message("History search must be control-free and at most 1024 UTF-8 bytes.")
                }
            case "--all" where result.method == "list", "--archived" where result.method == "list":
                guard result.filter == "recent" else { throw CLIError.message("Choose only one of --all and --archived.") }
                result.filter = option == "--all" ? "all" : "archived"
            case "--focus" where result.method == "resume" || result.method == "fork": result.focus = true
            default: throw CLIError.message("Unknown option \(option) for conversation history. Run `zshell +agent history --help`.")
            }
            index += 1
        }
        if result.method != "list" && result.method != "projects", result.id == nil {
            throw CLIError.message("Conversation history mutations require --id UUID from history results.")
        }
        return result
    }

    private static func uuid(after index: inout Int, in arguments: [String], option: String) throws -> UUID {
        let value = try ZshellAutomationCommandLine.value(after: &index, in: arguments, option: option)
        guard let id = UUID(uuidString: value) else { throw CLIError.message("\(option) requires a UUID.") }
        return id
    }

    private static func printHelp() {
        print("""
        Usage inside Zshell:
          zshell +agent history [--all | --archived] [--query TEXT]
          zshell +agent history projects
          zshell +agent resume --id UUID [--focus]
          zshell +agent fork --id UUID [--focus]
          zshell +agent archive --id UUID
          zshell +agent unarchive --id UUID
          zshell +agent delete --id UUID

        Usage from an external terminal:
          zshell +agent history projects [--connection PATH]
          zshell +agent history --project UUID [--all | --archived] [--query TEXT] [--connection PATH]
          zshell +agent resume --project UUID --id UUID [--window UUID] [--focus] [--connection PATH]
          zshell +agent fork --project UUID --id UUID [--window UUID] [--focus] [--connection PATH]
          zshell +agent archive|unarchive|delete --project UUID --id UUID [--connection PATH]
        """)
        print(String(localized: "History keeps the last 200 verified conversations; Recent shows 20 matches. All includes archived records. Deleting a record keeps the provider’s conversation files."))
        print(String(localized: "Resume shows an open conversation or reconnects its live terminal before starting the provider’s exact resume command. New terminals stay in the background unless --focus is supplied."))
        print(String(localized: "External access requires a running Zshell app and its owner-only connection. Pane processes keep their original project scope, even after clearing their environment."))
    }
}
