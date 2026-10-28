import Foundation

enum ZshellEventsCommandLine {
    static func run(arguments: [String]) throws -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            print(String(localized: "Stream live events from this terminal's project as NDJSON. Use --pane UUID, --event NAME, --once, and --timeout MS (0 waits indefinitely)."))
            print("zshell +events [--pane UUID] [--event NAME] [--once] [--timeout MS]")
            print(ZshellAutomationEventHub.eventNames.sorted().joined(separator: ", "))
            return 0
        }
        var params: [String: ZshellJSONValue] = [:]
        var events: [ZshellJSONValue] = []
        var once = false
        var timeoutMS = 0
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane":
                let pane = try ZshellAutomationCommandLine.value(after: &index, in: arguments, option: "--pane")
                guard UUID(uuidString: pane) != nil else {
                    throw CLIError.message(String(localized: "Event filters require a pane UUID and known event names."))
                }
                params["pane_id"] = .string(pane)
            case "--event":
                let name = try ZshellAutomationCommandLine.value(after: &index, in: arguments, option: "--event")
                guard ZshellAutomationEventHub.eventNames.contains(name), !events.contains(.string(name)) else {
                    throw CLIError.message(String(localized: "Event filters require a pane UUID and known event names."))
                }
                events.append(.string(name))
            case "--once": once = true
            case "--timeout":
                timeoutMS = try ZshellAutomationCommandLine.integerValue(after: &index, in: arguments, option: "--timeout")
                guard (0...86_400_000).contains(timeoutMS) else {
                    throw CLIError.message(String(localized: "Event timeouts must be between 0 and 86400000 milliseconds."))
                }
            default:
                throw CLIError.message(String(localized: "Unknown event option. Run `zshell +events --help`."))
            }
            index += 1
        }
        if !events.isEmpty { params["events"] = .array(events) }
        return try AppConnection().automationEvents(params: params, timeoutMS: timeoutMS, once: once)
    }
}
