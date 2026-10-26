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
        var command = arguments[0]
        var index = 1
        if command == "state" {
            guard arguments.count > 1, ["save", "load"].contains(arguments[1]) else {
                throw CLIError.message("Use `zshell +browser state save` or `zshell +browser state load`. Run `zshell +browser --help`.")
            }
            command += "." + arguments[1]
            index = 2
        }
        let commands: Set<String> = ["list", "open", "get", "navigate", "back", "forward", "reload", "stop", "snapshot", "click", "fill", "wait", "screenshot", "eval", "state.save", "state.load"]
        guard commands.contains(command) else {
            throw CLIError.message("Unknown +browser command \(command). Run `zshell +browser --help`.")
        }
        var params: [String: ZshellJSONValue] = [:]
        var output: String?
        var input: String?
        var wait = false
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
        case "eval": allowed.insert("--script")
        case "state.save": allowed.formUnion(["--output", "--format"])
        case "state.load": allowed.formUnion(["--input", "--format"])
        default: break
        }
        while index < arguments.count {
            let option = arguments[index]
            if !option.hasPrefix("--"), ["open", "navigate"].contains(command), params["url"] == nil {
                params["url"] = .string(option)
                index += 1
                continue
            }
            if !option.hasPrefix("--"), command == "eval", params["script"] == nil {
                params["script"] = .string(option)
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
                let keys = ["--browser": "browser_id", "--pane": "pane_id", "--url": "url", "--ref": "ref", "--selector": "selector", "--text": "value", "--value": "value", "--state": "state", "--script": "script", "--format": "format"]
                if option == "--output" { output = value }
                else if option == "--input" { input = value }
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
        if command == "eval" {
            guard let script = params["script"]?.stringValue,
                  !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  script.utf8.count <= BrowserAutomation.maximumScriptBytes else {
                throw CLIError.message("eval requires a non-empty --script of at most 64 KiB.")
            }
        }
        if command == "state.save", output == nil { throw CLIError.message("state save requires --output PATH.") }
        if command.hasPrefix("state.") {
            guard BrowserStorageState.Format(rawValue: params["format"]?.stringValue ?? "storage-state") != nil else {
                throw CLIError.message("--format must be storage-state or cookies.")
            }
        }
        if command == "state.load" {
            guard let input else { throw CLIError.message("state load requires --input PATH.") }
            params["data_base64"] = .string(try readState(path: input).base64EncodedString())
        }
        let timeout = params["timeout_ms"]?.intValue ?? 5_000
        guard (100...30_000).contains(timeout) else { throw CLIError.message("Timeout must be between 100 and 30000 milliseconds.") }
        let connection = try AppConnection()
        var result = try connection.automationRequest(method: "browser.\(command)", params: params, timeout: Double(timeout) / 1_000 + 2)
        if wait, let browserID = result.objectValue?["browser_id"]?.stringValue {
            result = try connection.automationRequest(method: "browser.wait", params: ["browser_id": .string(browserID), "timeout_ms": .number(Double(timeout))], timeout: Double(timeout) / 1_000 + 2)
        }
        if let output {
            result = try saveFile(result, path: output,
                                  maximumBytes: command == "screenshot" ? BrowserAutomation.maximumImageBytes : BrowserStorageState.maximumBytes)
        }
        try ZshellAutomationCommandLine.printJSON(result)
    }

    private static func saveFile(_ result: ZshellJSONValue, path: String, maximumBytes: Int) throws -> ZshellJSONValue {
        guard var object = result.objectValue,
              let encoded = object["data_base64"]?.stringValue,
              encoded.utf8.count <= (maximumBytes + 2) / 3 * 4,
              let data = Data(base64Encoded: encoded), data.count <= maximumBytes else {
            throw CLIError.message("Zshell returned an invalid or oversized browser file.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw CLIError.message("Could not create browser file (existing files are preserved): \(String(cString: strerror(errno)))")
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

    private static func readState(path: String) throws -> Data {
        let descriptor = Darwin.open(URL(fileURLWithPath: path).standardizedFileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw CLIError.message("Could not open the private storage-state file.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0,
              metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= BrowserStorageState.maximumBytes,
              let data = try file.read(upToCount: BrowserStorageState.maximumBytes + 1),
              !data.isEmpty, data.count <= BrowserStorageState.maximumBytes else {
            throw CLIError.message("Storage state must be an owner-only regular file of at most 256 KiB (for example, chmod 600 PATH).")
        }
        return data
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
          zshell +browser eval [--browser ID | --pane ID] --script JAVASCRIPT
          zshell +browser state save [--browser ID | --pane ID] --output PATH [--format storage-state|cookies]
          zshell +browser state load [--browser ID | --pane ID] --input PATH [--format storage-state|cookies]

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
        viewport as PNG, up to 512 KiB and 1600 points per side. Unshown panes
        use a 1024 x 768 viewport without selecting a tab or changing focus.
        Output files are private and never overwritten.

        Eval runs a script in the real main-frame page, awaits a returned
        Promise, and returns its JSON value (undefined becomes null). Use an
        async function expression for await. Input is limited to 64 KiB; output
        to 256 KiB, 10000 values, and 64 levels. A timeout stops waiting, not
        page execution; inspect state before retrying. Synchronous endless code
        can stall that page and require closing it. DOM refs expire after eval.
        Single expressions and IIFEs use native global Script injection.
        Multi-statement strings follow page CSP; wrap them in an IIFE if string
        evaluation is blocked. The page's CSP is never relaxed.

        State save/load handles only the current HTTP(S) origin's localStorage
        and cookies applicable to its host (including HttpOnly and parent-domain
        cookies). Unrelated domains, public suffixes, and Secure cookies on HTTP
        are rejected. JSON uses Playwright
        storage-state; cookies uses Netscape cookies.txt without localStorage
        or SameSite. Imports require an owner-only regular file, up to 256 KiB;
        other origins, invalid types, and unsupported fields are rejected before
        changes. Load replaces this origin's localStorage and merges cookies;
        reload afterwards. WebKit site data remains shared across browser panes.
        State files contain credentials: keep them private and out of Git.
        """)
    }
}
