//
//  ZshellBrowserAutomationCommandLine.swift
//  zshell
//

import Darwin
import Foundation

enum ZshellBrowserAutomationCommandLine {
    static func run(arguments: [String]) throws {
        if arguments.isEmpty || ["help", "--help", "-h"].contains(arguments[0]) {
            printHelp()
            return
        }
        let command = arguments[0]
        let commands: Set<String> = ["list", "open", "get", "navigate", "back", "forward", "reload", "stop", "snapshot", "click", "fill", "wait", "screenshot"]
        guard commands.contains(command) else {
            throw CLIError.message("Unknown +browser command \(command). Run `zshell +browser --help`.")
        }
        var params: [String: ZshellJSONValue] = [:]
        var output: String?
        var wait = false
        var index = 1
        var used = Set<String>()
        let targetOptions: Set<String> = ["--browser", "--pane"]
        let elementOptions: Set<String> = ["--ref", "--selector"]
        var allowed: Set<String> = command == "list" ? [] : targetOptions.union(["--timeout"])
        switch command {
        case "open": allowed = ["--pane", "--url", "--tab", "--left", "--right", "--up", "--down", "--focus", "--wait", "--timeout"]
        case "navigate": allowed.formUnion(["--url", "--wait"])
        case "snapshot": allowed.formUnion(["--max-elements", "--max-text"])
        case "click": allowed.formUnion(elementOptions)
        case "fill": allowed.formUnion(elementOptions.union(["--text", "--value"]))
        case "wait": allowed.formUnion(elementOptions.union(["--state"]))
        case "screenshot": allowed.formUnion(["--output", "--width"])
        default: break
        }
        while index < arguments.count {
            let option = arguments[index]
            if !option.hasPrefix("--"), ["open", "navigate"].contains(command), params["url"] == nil {
                params["url"] = .string(option)
                index += 1
                continue
            }
            guard allowed.contains(option), used.insert(option).inserted else {
                throw CLIError.message("Unknown or duplicate option \(option) for `zshell +browser \(command)`. Run `zshell +browser --help`.")
            }
            switch option {
            case "--tab": params["tab"] = .bool(true)
            case "--focus": params["focus"] = .bool(true)
            case "--wait": wait = true
            case "--left", "--right", "--up", "--down":
                guard params["edge"] == nil else { throw CLIError.message("Choose one split direction.") }
                let edges = ["--left": "left", "--right": "right", "--up": "top", "--down": "bottom"]
                params["edge"] = .string(edges[option]!)
            case "--timeout", "--max-elements", "--max-text", "--width":
                let value = try ZshellAutomationCommandLine.integerValue(after: &index, in: arguments, option: option)
                let keys = ["--timeout": "timeout_ms", "--max-elements": "max_elements", "--max-text": "max_text", "--width": "width"]
                params[keys[option]!] = .number(Double(value))
            default:
                let value = try ZshellAutomationCommandLine.value(after: &index, in: arguments, option: option)
                let keys = ["--browser": "browser_id", "--pane": "pane_id", "--url": "url", "--ref": "ref", "--selector": "selector", "--text": "value", "--value": "value", "--state": "state"]
                if option == "--output" { output = value }
                else if let key = keys[option] {
                    guard params[key] == nil else { throw CLIError.message("Pass \(key) once.") }
                    params[key] = .string(value)
                }
            }
            index += 1
        }
        guard params["browser_id"] == nil || params["pane_id"] == nil else {
            throw CLIError.message("Choose --browser or --pane.")
        }
        if command == "open", params["tab"] != nil, (params["edge"] != nil || params["pane_id"] != nil) {
            throw CLIError.message("--tab cannot be combined with --pane or a split direction.")
        }
        if command == "navigate", params["url"] == nil { throw CLIError.message("navigate requires a URL.") }
        if ["click", "fill"].contains(command), (params["ref"] == nil) == (params["selector"] == nil) {
            throw CLIError.message("Choose exactly one --ref or --selector.")
        }
        if command == "fill", params["value"] == nil { throw CLIError.message("fill requires --text.") }
        if command == "screenshot", output == nil { throw CLIError.message("screenshot requires --output PATH.") }
        let timeout = params["timeout_ms"]?.intValue ?? 5_000
        guard (100...30_000).contains(timeout) else { throw CLIError.message("Timeout must be between 100 and 30000 milliseconds.") }
        let connection = try AppConnection()
        var result = try connection.automationRequest(method: "browser.\(command)", params: params, timeout: Double(timeout) / 1_000 + 2)
        if wait, let browserID = result.objectValue?["browser_id"]?.stringValue {
            result = try connection.automationRequest(method: "browser.wait", params: ["browser_id": .string(browserID), "timeout_ms": .number(Double(timeout))], timeout: Double(timeout) / 1_000 + 2)
        }
        if let output { result = try saveScreenshot(result, path: output) }
        try ZshellAutomationCommandLine.printJSON(result)
    }

    private static func saveScreenshot(_ result: ZshellJSONValue, path: String) throws -> ZshellJSONValue {
        guard var object = result.objectValue,
              let encoded = object["data_base64"]?.stringValue,
              let data = Data(base64Encoded: encoded), data.count <= 524_288 else {
            throw CLIError.message("Zshell returned an invalid or oversized screenshot.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw CLIError.message("Could not create screenshot file (existing files are preserved): \(String(cString: strerror(errno)))")
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            try file.close()
        } catch {
            try? file.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        object.removeValue(forKey: "data_base64")
        object["path"] = .string(url.path)
        return .object(object)
    }

    private static func printHelp() {
        print("""
        Usage:
          zshell +browser list
          zshell +browser open [URL] [--tab | --left|--right|--up|--down] [--pane ID] [--focus] [--wait]
          zshell +browser get [--browser ID | --pane ID]
          zshell +browser navigate URL [--browser ID | --pane ID] [--wait]
          zshell +browser <back|forward|reload|stop> [--browser ID | --pane ID]
          zshell +browser snapshot [--browser ID | --pane ID] [--max-elements N] [--max-text N]
          zshell +browser click [--browser ID | --pane ID] <--ref REF | --selector CSS>
          zshell +browser fill [--browser ID | --pane ID] <--ref REF | --selector CSS> --text TEXT
          zshell +browser wait [--browser ID | --pane ID] [--selector CSS | --ref REF] [--state visible|attached]
          zshell +browser screenshot [--browser ID | --pane ID] --output PATH [--width N]

        Commands run inside a Zshell terminal and return JSON. Targets stay in
        that terminal's project and window. Omit the target only when exactly
        one browser exists. Open defaults to a right split beside the caller;
        --tab creates a background tab. Focus changes only with --focus.

        Use an explicit http:// or https:// URL, or about:blank. After an agent
        operates a page, its navigation stays restricted to those protocols
        until you navigate manually with the address bar or browser toolbar.
        External protocols, downloads, and file pickers require user interaction.
        DOM operations cover the main frame. References expire after any DOM
        mutation, navigation, action, or newer snapshot; take a fresh snapshot.
        CSS selectors must match exactly one element. Click uses DOM events;
        sites that require trusted hardware input need direct user interaction.

        --timeout MS applies to one request (100–30000, default 5000). Wait
        without a selector waits for page readiness. Snapshots contain up to
        200 elements and 32768 text characters, with a 256 KiB response limit.
        Password and file input values are omitted. Screenshots capture the
        viewport as PNG, up to 512 KiB and 1600 points per side; show the pane
        once before capturing it. Output files are private and never overwritten.
        """)
    }
}
