import Foundation

/// Codex owns the TOML grammar and edits. Use its configuration API rather than
/// maintaining a second parser, and keep the original bytes for a clean undo.
nonisolated enum CodexTitleConfiguration {
    struct State: Codable, Equatable {
        let originalItems: [String]?
        let installedItems: [String]
        let originalData: Data?
        let installedData: Data
    }

    struct Plan {
        let original: Data?
        let updated: Data?
        let state: State?
    }

    private static let defaults = ["activity", "thread-name", "project-name"]

    static func plan(
        root: URL, previous: State?, installing: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Plan? {
        let config = root.appendingPathComponent("config.toml")
        let original = try readIfPresent(config)
        if let previous, original == previous.installedData {
            return Plan(original: original, updated: installing ? original : previous.originalData,
                        state: installing ? previous : nil)
        }
        if !installing, previous == nil { return nil }
        guard ProcessRunner.resolveExecutable("codex", environment: environment) != nil else { return nil }
        let configuration = try request(
            method: "config/read", params: ["includeLayers": .bool(true)],
            root: root, environment: environment
        )
        let effective = configuration.objectValue?["config"]?.objectValue?["tui"]?.objectValue?["terminal_title"]
        let items = try titleItems(effective)
        let layers = configuration.objectValue?["layers"]?.arrayValue ?? []
        let user = layers.first { $0.objectValue?["name"]?.objectValue?["type"]?.stringValue == "user" }
        let saved = try titleItems(user?.objectValue?["config"]?.objectValue?["tui"]?.objectValue?["terminal_title"])
        if !installing {
            guard let previous, saved == previous.installedItems else {
                // A subsequent user edit owns the item. Never restore an old
                // whole-file snapshot over a newer provider configuration.
                return Plan(original: original, updated: original, state: nil)
            }
            let updated = try edit(previous.originalItems, config: original, environment: environment)
            return Plan(original: original, updated: updated, state: nil)
        }
        if items?.contains("session-id") == true {
            return Plan(original: original, updated: original, state: previous)
        }
        let installed = (items ?? defaults) + ["session-id"]
        let updated = try edit(installed, config: original, environment: environment)
        return Plan(original: original, updated: updated, state: State(
            originalItems: saved, installedItems: installed,
            originalData: original, installedData: updated
        ))
    }

    static func hidesManagedSessionID(configDirectory: String?) -> Bool {
        guard let configDirectory,
              let data = try? Data(contentsOf: URL(fileURLWithPath: configDirectory)
                .appendingPathComponent(".zshell-session-hooks.json")), data.count <= 2_097_152,
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["codexTitle"] != nil else { return false }
        return true
    }

    private static func titleItems(_ value: ZshellJSONValue?) throws -> [String]? {
        guard let value, value != .null else { return nil }
        guard let array = value.arrayValue, array.count <= 64,
              array.allSatisfy({ $0.stringValue != nil }) else {
            throw ZshellAgentSessionHooks.HookError.message(String(localized: "Codex terminal title items must be a string array."))
        }
        return array.compactMap(\.stringValue)
    }

    private static func edit(
        _ items: [String]?, config: Data?, environment: [String: String]
    ) throws -> Data {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshell-codex-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let path = scratch.appendingPathComponent("config.toml")
        if let config { try config.write(to: path, options: .atomic) }
        _ = try request(
            method: "config/value/write",
            params: ["filePath": .string(path.path), "keyPath": .string("tui.terminal_title"),
                     "mergeStrategy": .string("replace"),
                     "value": items.map { .array($0.map(ZshellJSONValue.string)) } ?? .null],
            root: scratch, environment: environment
        )
        return try Data(contentsOf: path)
    }

    private static func request(
        method: String, params: [String: ZshellJSONValue], root: URL,
        environment: [String: String]
    ) throws -> ZshellJSONValue {
        guard let executable = ProcessRunner.resolveExecutable("codex", environment: environment) else {
            throw ZshellAgentSessionHooks.HookError.message(String(localized: "Codex is unavailable for terminal title integration."))
        }
        var environment = environment
        environment["CODEX_HOME"] = root.path
        // Config inspection creates no thread and must not inherit an enclosing
        // agent's identity or workspace request metadata.
        environment.removeValue(forKey: "CODEX_THREAD_ID")
        let initialize: ZshellJSONValue = .object([
            "id": .number(1), "method": .string("initialize"),
            "params": .object(["clientInfo": .object(["name": .string("zshell"), "version": .string("1")])]),
        ])
        let second: ZshellJSONValue = .object([
            "id": .number(2), "method": .string(method), "params": .object(params),
        ])
        let result = ProcessRunner.run(
            executable: executable, arguments: ["app-server", "--listen", "stdio://"],
            initialInput: try JSONEncoder().encode(initialize),
            initializedInput: Data("{\"method\":\"initialized\",\"params\":{}}".utf8),
            secondInput: try JSONEncoder().encode(second), waitForResponseID: 1, secondResponseID: 2,
            timeout: 5, environment: environment, workingDirectory: root
        )
        guard !result.timedOut else {
            throw ZshellAgentSessionHooks.HookError.message(String(localized: "Codex terminal title configuration timed out."))
        }
        for line in result.stdout.split(separator: 0x0A) {
            guard let response = try? JSONDecoder().decode(ZshellJSONValue.self, from: Data(line)),
                  response.objectValue?["id"]?.intValue == 2 else { continue }
            if let value = response.objectValue?["result"] { return value }
            throw ZshellAgentSessionHooks.HookError.message(String(localized: "Codex rejected terminal title configuration."))
        }
        throw ZshellAgentSessionHooks.HookError.message(String(localized: "Codex did not return terminal title configuration."))
    }

    private static func readIfPresent(_ url: URL) throws -> Data? {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else {
                throw ZshellAgentSessionHooks.HookError.message(String(localized: "Codex configuration is too large for terminal title integration."))
            }
            return data
        } catch CocoaError.fileReadNoSuchFile { return nil }
    }
}
