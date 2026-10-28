import Foundation

enum ZshellSessionCommandLine {
    struct Options {
        let command: String
        var projectID: String?
        var sessionID: String?
        var directory: String?
        var branch: String?
        var worktreePath: String?
        var base: String?
        var focus = false
        var removeWorktree = false
        var connectionURL: URL?
        var arguments: [String]?

        var parameters: [String: ZshellJSONValue] {
            var values: [String: ZshellJSONValue] = [:]
            if let projectID { values["project_id"] = .string(projectID) }
            if let sessionID { values["session_id"] = .string(sessionID) }
            if let directory { values["cwd"] = .string(directory) }
            if let branch { values["branch"] = .string(branch) }
            if let worktreePath { values["worktree_path"] = .string(worktreePath) }
            if let base { values["base"] = .string(base) }
            if command == "new" {
                values["focus"] = .bool(focus)
                if let arguments { values["argv"] = .array(arguments.map(ZshellJSONValue.string)) }
                values["path"] = .string(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            }
            if command == "close" { values["remove_worktree"] = .bool(removeWorktree) }
            return values
        }
    }

    static func parse(_ arguments: [String], cwd: String = FileManager.default.currentDirectoryPath) throws -> Options {
        guard let command = arguments.first, ["projects", "new", "list", "check", "close"].contains(command) else {
            throw CLIError.message("Choose projects, new, list, check, or close. Run `zshell +session --help`.")
        }
        var options = Options(command: command)
        var seen = Set<String>()
        var index = 1
        func value(_ option: String) throws -> String {
            guard index + 1 < arguments.count, arguments[index + 1] != "--", !arguments[index + 1].contains("\0") else {
                throw CLIError.message("\(option) requires a value.")
            }
            index += 1
            return arguments[index]
        }
        func absolute(_ path: String) -> String {
            URL(fileURLWithPath: path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path))
                .standardizedFileURL.path
        }
        while index < arguments.count {
            let option = arguments[index]
            if option == "--", command == "new" {
                let tail = Array(arguments.dropFirst(index + 1))
                guard !tail.isEmpty else { throw CLIError.message(String(localized: "No command was provided after `--`.")) }
                options.arguments = tail
                break
            }
            guard seen.insert(option).inserted else { throw CLIError.message("\(option) was provided more than once.") }
            switch option {
            case "--project":
                let id = try value(option)
                guard let uuid = UUID(uuidString: id) else { throw CLIError.message("--project requires a project UUID.") }
                options.projectID = uuid.uuidString
            case "--session":
                guard command == "check" || command == "close" else { throw CLIError.message("--session is only valid for check or close.") }
                let id = try value(option)
                guard let uuid = UUID(uuidString: id) else { throw CLIError.message("--session requires a terminal UUID.") }
                options.sessionID = uuid.uuidString
            case "--cwd": options.directory = absolute(try value(option))
            case "--branch": options.branch = try value(option)
            case "--worktree": options.worktreePath = absolute(try value(option))
            case "--base": options.base = try value(option)
            case "--focus": options.focus = true
            case "--no-focus": options.focus = false
            case "--remove-worktree": options.removeWorktree = true
            case "--keep-worktree": options.removeWorktree = false
            case "--connection": options.connectionURL = URL(fileURLWithPath: absolute(try value(option)))
            default: throw CLIError.message("Unknown +session option \(option).")
            }
            index += 1
        }
        if seen.contains("--focus") && seen.contains("--no-focus") {
            throw CLIError.message("Choose only one of --focus and --no-focus.")
        }
        if seen.contains("--keep-worktree") && seen.contains("--remove-worktree") {
            throw CLIError.message("Choose only one worktree close action.")
        }
        let newOptions: Set<String> = ["--cwd", "--branch", "--worktree", "--base", "--focus", "--no-focus"]
        guard command == "new" || seen.isDisjoint(with: newOptions) else {
            throw CLIError.message("Creation options are only valid for +session new.")
        }
        guard command == "close" || seen.isDisjoint(with: ["--remove-worktree", "--keep-worktree"]) else {
            throw CLIError.message("Worktree close actions are only valid for +session close.")
        }
        guard command != "projects" || options.projectID == nil else {
            throw CLIError.message("projects lists the available project IDs.")
        }
        guard options.branch != nil || (options.worktreePath == nil && options.base == nil) else {
            throw CLIError.message("--worktree and --base require --branch.")
        }
        if command == "check" || command == "close", options.sessionID == nil {
            throw CLIError.message("\(command) requires --session.")
        }
        return options
    }

    static func run(arguments: [String]) throws {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
            printHelp()
            return
        }
        let options = try parse(arguments)
        let environment = try PersistentCLIConnection.resolvedEnvironment(ProcessInfo.processInfo.environment)
        let inTerminal = environment["ZSHELL_CLI_STATE"]?.isEmpty == false && environment["ZSHELL_CLI_TOKEN"]?.isEmpty == false
        let result: ZshellJSONValue
        if inTerminal && options.connectionURL == nil {
            result = try AppConnection(environment: environment).automationRequest(
                method: "session.\(options.command)", params: options.parameters, timeout: 60
            )
        } else {
            guard options.command == "projects" || options.projectID != nil else {
                throw CLIError.message("External session commands require --project. Run `zshell +session projects` to list IDs.")
            }
            result = try ZshellSessionControlConnection(connectionURL: options.connectionURL)
                .request(method: "session.\(options.command)", params: options.parameters)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }

    private static func printHelp() {
        print("""
        Usage: zshell +session COMMAND [options]

          projects                                      List open project IDs
          list [--project ID]                           List terminal sessions
          new [--project ID] [--cwd DIR] [--focus] [-- command [arguments...]]
          new [--project ID] --branch BRANCH [--worktree NEW_DIR]
              [--base default|HEAD|REF] [--cwd REPO] [--focus] [-- command [arguments...]]
          check [--project ID] --session ID              Inspect worktree cleanup safety
          close [--project ID] --session ID [--keep-worktree|--remove-worktree]

        External terminals require --project for every command except projects.
        --connection FILE selects a particular running instance's owner-only connection.
        Inside Zshell, commands stay scoped to the invoking terminal's project,
        including programs that clear the bridge environment variables.
        New branches start from the repository default branch; HEAD is an explicit opt-in.
        Existing branches keep their current commit. Existing directories are refused.
        Closing keeps the worktree by default. Cleanup refuses dirty, unmerged,
        locked, changed, or shared worktrees and always preserves the Git branch.
        """)
    }
}
