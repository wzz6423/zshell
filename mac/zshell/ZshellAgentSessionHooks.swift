import Foundation

/// Adds only Zshell-owned handlers to provider settings. Hook code remains a
/// link to the bundle; unrelated settings and handlers are never replaced.
enum ZshellAgentSessionHooks {
    enum HookError: Error, LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let message): message }
        }
    }

    struct Hook: Equatable {
        let event: String
        let action: String
        let matcher: String?

        init(event: String, action: String = "_session-start", matcher: String? = nil) {
            self.event = event
            self.action = action
            self.matcher = matcher
        }
    }

    private static let resourceName = "zshell-session-hook"
    private static let manifestName = ".zshell-session-hooks.json"

    private struct Manifest: Codable {
        let version: Int
        let provider: AgentConversationIdentity.Provider
        let commands: [String: String]
        let configFile: String?
        var codexTitle: CodexTitleConfiguration.State? = nil
    }

    private struct Plan {
        let configURL: URL
        let original: Data?
        let updated: Data?
        let linkURL: URL
        let sourceURL: URL?
        let manifestURL: URL
        let originalManifest: Data?
        let manifestData: Data?
        var codexTitle: CodexTitleConfiguration.Plan? = nil
    }

    static func preflightInstallAvailable(
        bundle: Bundle = .main,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hooks: [Hook] = [.init(event: "SessionStart")]
    ) throws {
        _ = try plans(
            installing: true, bundle: bundle, homeURL: homeURL,
            environment: environment, hooks: hooks
        )
    }

    static func installAvailable(
        bundle: Bundle = .main,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hooks: [Hook] = [.init(event: "SessionStart")]
    ) throws {
        for plan in try plans(
            installing: true, bundle: bundle, homeURL: homeURL,
            environment: environment, hooks: hooks
        ) { try apply(plan, installing: true) }
    }

    static func preflightUninstallManaged(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        _ = try plans(
            installing: false, bundle: nil, homeURL: homeURL,
            environment: environment, hooks: []
        )
    }

    static func uninstallManaged(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        for plan in try plans(
            installing: false, bundle: nil, homeURL: homeURL,
            environment: environment, hooks: []
        ) { try apply(plan, installing: false) }
    }

    private static func plans(
        installing: Bool,
        bundle: Bundle?,
        homeURL: URL,
        environment: [String: String],
        hooks: [Hook]
    ) throws -> [Plan] {
        return try [AgentConversationIdentity.Provider.claude, .codex, .opencode].compactMap { provider in
            let root = provider.installationRoot(homeURL: homeURL, environment: environment)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory),
                  directory.boolValue else { return nil }
            if provider == .opencode {
                return try openCodePlan(root: root, bundle: bundle, installing: installing)
            }
            return try plan(
                provider: provider, root: root,
                sourceURL: try installing ? sourceURL(bundle: bundle ?? .main) : nil,
                installing: installing, hooks: hooks, environment: environment
            )
        }
    }

    private static func plan(
        provider: AgentConversationIdentity.Provider,
        root: URL,
        sourceURL: URL?,
        installing: Bool,
        hooks requested: [Hook],
        environment: [String: String]
    ) throws -> Plan? {
        let config = root.appendingPathComponent(provider == .claude ? "settings.json" : "hooks.json")
        let link = root.appendingPathComponent("hooks/\(resourceName).sh")
        let manifestURL = root.appendingPathComponent(manifestName)
        let manifest = try readManifest(at: manifestURL, provider: provider)
        if !installing, manifest == nil { return nil }
        if itemExists(link), !isManagedLink(link, sourceURL: sourceURL) {
            throw HookError.message(String(localized: "Zshell's integration at \(link.path) has local changes."))
        }
        let original = try readFileIfPresent(config)
        var settings = try object(from: original, path: config.path)
        var events = try object(from: settings["hooks"], path: "\(config.path): hooks")
        let previous = manifest?.commands ?? [:]
        var next: [String: String] = [:]
        var changed = false

        for event in Set(previous.keys).union(requested.map(\.event)).sorted() {
            let eventPath = "\(config.path): hooks.\(event)"
            var groups: [[String: Any]] = []
            if let value = events[event] {
                guard let parsed = value as? [[String: Any]] else {
                    throw HookError.message(String(localized: "Invalid provider hooks at \(eventPath)."))
                }
                groups = parsed
            }
            var kept: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw HookError.message(String(localized: "Invalid provider hooks at \(eventPath)."))
                }
                var remaining: [[String: Any]] = []
                for handler in handlers {
                    if let command = handler["command"] as? String,
                       command == previous[event] {
                        let expected: [String: Any] = ["type": "command", "command": command, "timeout": 5]
                        guard NSDictionary(dictionary: handler).isEqual(to: expected) else {
                            throw HookError.message(String(localized: "Zshell's integration at \(eventPath) has local changes."))
                        }
                        changed = true
                    } else {
                        remaining.append(handler)
                    }
                }
                if remaining.count == handlers.count {
                    kept.append(group)
                } else if !remaining.isEmpty {
                    group["hooks"] = remaining
                    kept.append(group)
                }
            }
            if installing, let hook = requested.first(where: { $0.event == event }) {
                guard hook.action.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                    throw HookError.message(String(localized: "Invalid provider hooks at \(eventPath)."))
                }
                let command = "/bin/sh \(shellQuote(link.path)) \(provider.rawValue) \(hook.action)"
                let handler: [String: Any] = ["type": "command", "command": command, "timeout": 5]
                var group: [String: Any] = ["hooks": [handler]]
                if let matcher = hook.matcher { group["matcher"] = matcher }
                kept.append(group)
                next[event] = command
                changed = true
            }
            if kept.isEmpty { events.removeValue(forKey: event) }
            else { events[event] = kept }
        }
        if events.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = events }

        let updated: Data?
        if changed {
            var serialized = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            serialized.append(0x0A)
            if let original,
               NSDictionary(dictionary: try object(from: original, path: config.path)).isEqual(to: settings) {
                updated = original
            } else { updated = serialized }
        } else { updated = original }
        let title = provider == .codex
            ? try CodexTitleConfiguration.plan(root: root, previous: manifest?.codexTitle,
                                              installing: installing, environment: environment) : nil
        let manifestData = installing
            ? try JSONEncoder().encode(Manifest(version: 1, provider: provider, commands: next, configFile: nil,
                                               codexTitle: title?.state))
            : nil
        return Plan(
            configURL: config, original: original, updated: updated,
            linkURL: link, sourceURL: sourceURL,
            manifestURL: manifestURL, originalManifest: try readFileIfPresent(manifestURL),
            manifestData: manifestData, codexTitle: title
        )
    }

    private static func openCodePlan(root: URL, bundle: Bundle?, installing: Bool) throws -> Plan? {
        let link = root.appendingPathComponent("zshell/zshell-conversation-tui.js")
        let manifestURL = root.appendingPathComponent(".zshell-conversation-tui.json")
        let manifest = try readManifest(at: manifestURL, provider: .opencode)
        if !installing, manifest == nil { return nil }
        let source: URL?
        if installing {
            source = try sourceURL(
                bundle: bundle ?? .main, name: "zshell-conversation-tui", extension: "js",
                directories: ["AgentIntegrations/opencode", "opencode", nil],
                marker: "ZSHELL_INTEGRATION_ID=opencode-conversation"
            )
        } else { source = nil }
        if itemExists(link), !isManagedLink(link, sourceURL: source) {
            throw HookError.message(String(localized: "Zshell's integration at \(link.path) has local changes."))
        }
        let candidates = ["tui.jsonc", "tui.json"].map { root.appendingPathComponent($0) }
        let config: URL
        if let saved = manifest?.configFile {
            guard let match = candidates.first(where: { $0.path == saved }) else {
                throw HookError.message(String(localized: "Zshell's hook manifest at \(manifestURL.path) has local changes."))
            }
            config = match
        } else { config = candidates.first { itemExists($0) } ?? candidates[1] }
        let spec = link.absoluteString
        if let manifest, manifest.commands != ["plugin": spec] {
            throw HookError.message(String(localized: "Zshell's hook manifest at \(manifestURL.path) has local changes."))
        }
        let original = try readFileIfPresent(config)
        let updated = try JSONCPluginList.updating(
            original ?? Data("{}\n".utf8), spec: spec, installing: installing, path: config.path
        )
        let manifestData = installing ? try JSONEncoder().encode(Manifest(
            version: 1, provider: .opencode, commands: ["plugin": spec], configFile: config.path
        )) : nil
        return Plan(
            configURL: config, original: original, updated: original == nil && !installing ? nil : updated,
            linkURL: link, sourceURL: source,
            manifestURL: manifestURL, originalManifest: try readFileIfPresent(manifestURL),
            manifestData: manifestData
        )
    }

    private static func apply(_ plan: Plan, installing: Bool) throws {
        // Never overwrite a settings edit made since the multi-provider preflight.
        guard try readFileIfPresent(plan.configURL) == plan.original,
              try readFileIfPresent(plan.manifestURL) == plan.originalManifest else {
            throw HookError.message(String(localized: "\(plan.configURL.path) changed while Zshell was updating hooks."))
        }
        let titleURL = plan.configURL.deletingLastPathComponent().appendingPathComponent("config.toml")
        if let title = plan.codexTitle,
           try readFileIfPresent(titleURL) != title.original {
            throw HookError.message(String(localized: "\(titleURL.path) changed while Zshell was updating hooks."))
        }
        if installing, let source = plan.sourceURL {
            try replaceLink(at: plan.linkURL, sourceURL: source)
        }
        if let updated = plan.updated, updated != plan.original {
            try writeAtomic(updated, to: plan.configURL)
        }
        if let title = plan.codexTitle, title.updated != title.original {
            if let updated = title.updated { try writeAtomic(updated, to: titleURL) }
            else if itemExists(titleURL) { try FileManager.default.removeItem(at: titleURL) }
        }
        if let data = plan.manifestData {
            try writeAtomic(data, to: plan.manifestURL, permissions: 0o600)
        } else {
            if itemExists(plan.linkURL) { try FileManager.default.removeItem(at: plan.linkURL) }
            if itemExists(plan.manifestURL) { try FileManager.default.removeItem(at: plan.manifestURL) }
        }
    }

    private static func sourceURL(
        bundle: Bundle,
        name: String = resourceName,
        extension suffix: String = "sh",
        directories: [String?] = ["AgentIntegrations", nil],
        marker: String = "ZSHELL_SESSION_HOOK_VERSION=1"
    ) throws -> URL {
        for subdirectory in directories {
            if let url = bundle.url(forResource: name, withExtension: suffix, subdirectory: subdirectory),
               let data = try? Data(contentsOf: url),
               String(decoding: data, as: UTF8.self).contains(marker) {
                return url.standardizedFileURL
            }
        }
        throw HookError.message(String(localized: "Zshell's bundled conversation hook is missing."))
    }

    private static func readManifest(at url: URL, provider: AgentConversationIdentity.Provider) throws -> Manifest? {
        guard let data = try readFileIfPresent(url) else { return nil }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1, manifest.provider == provider else {
            throw HookError.message(String(localized: "Zshell's hook manifest at \(url.path) has local changes."))
        }
        return manifest
    }

    private static func object(from data: Data?, path: String) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard data.count <= 1_048_576,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.message(String(localized: "\(path) must be a JSON object."))
        }
        return value
    }

    private static func object(from value: Any?, path: String) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let value = value as? [String: Any] else {
            throw HookError.message(String(localized: "\(path) must be a JSON object."))
        }
        return value
    }

    private static func readFileIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch { throw error }
    }

    private static func isManagedLink(_ url: URL, sourceURL: URL?) -> Bool {
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return false }
        let target = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : url.deletingLastPathComponent().appendingPathComponent(path)
        if target.standardizedFileURL == sourceURL?.standardizedFileURL { return true }
        return ["\(resourceName).sh", "zshell-conversation-tui.js"].contains(url.lastPathComponent)
            && target.lastPathComponent == url.lastPathComponent
            && target.path.contains(".app/Contents/Resources/")
    }

    private static func replaceLink(at url: URL, sourceURL: URL) throws {
        if itemExists(url), !isManagedLink(url, sourceURL: sourceURL) {
            throw HookError.message(String(localized: "Zshell's integration at \(url.path) has local changes."))
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".zshell-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createSymbolicLink(atPath: staging.path, withDestinationPath: sourceURL.path)
        if rename(staging.path, url.path) != 0 {
            throw HookError.message(String(localized: "Could not link Zshell's hook at \(url.path)."))
        }
    }

    private static func writeAtomic(_ data: Data, to url: URL, permissions: Int? = nil) throws {
        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let mode = permissions ?? (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
        let staging = parent.appendingPathComponent(".zshell-hook-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try data.write(to: staging, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: staging.path)
        if rename(staging.path, url.path) != 0 {
            throw HookError.message(String(localized: "Could not save provider hooks at \(url.path)."))
        }
    }

    private static func itemExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Edits only the managed plugin's tokens, keeping JSONC comments and
    /// unrelated values byte-for-byte instead of serializing user settings.
    private struct JSONCPluginList {
        struct Token {
            let kind: UInt8
            let range: Range<Int>
        }

        let bytes: [UInt8]
        let tokens: [Token]
        let settings: [String: Any]
        let path: String

        init(_ data: Data, path: String) throws {
            self.path = path
            bytes = Array(data)
            var parsed = bytes
            var list: [Token] = []
            var index = 0
            func invalid() -> HookError {
                .message(String(localized: "\(path) must be a JSON object."))
            }
            guard data.count <= 1_048_576 else { throw invalid() }
            while index < bytes.count {
                let byte = bytes[index]
                if [9, 10, 13, 32].contains(byte) { index += 1; continue }
                let start = index
                if byte == 47, index + 1 < bytes.count {
                    if bytes[index + 1] == 47 {
                        index += 2
                        while index < bytes.count, bytes[index] != 10 { index += 1 }
                    } else if bytes[index + 1] == 42 {
                        index += 2
                        while index + 1 < bytes.count,
                              !(bytes[index] == 42 && bytes[index + 1] == 47) { index += 1 }
                        guard index + 1 < bytes.count else { throw invalid() }
                        index += 2
                    } else { throw invalid() }
                    for offset in start..<index where bytes[offset] != 10 && bytes[offset] != 13 {
                        parsed[offset] = 32
                    }
                    continue
                }
                if byte == 34 {
                    index += 1
                    while index < bytes.count, bytes[index] != 34 {
                        index += bytes[index] == 92 ? 2 : 1
                    }
                    guard index < bytes.count else { throw invalid() }
                    index += 1
                } else if [44, 58, 91, 93, 123, 125].contains(byte) {
                    index += 1
                } else {
                    while index < bytes.count,
                          ![9, 10, 13, 32, 44, 58, 91, 93, 123, 125, 47].contains(bytes[index]) {
                        index += 1
                    }
                    guard index > start else { throw invalid() }
                }
                list.append(Token(kind: byte, range: start..<index))
            }
            for position in list.indices.dropLast() where list[position].kind == 44 {
                if [93, 125].contains(list[position + 1].kind) {
                    parsed[list[position].range.lowerBound] = 32
                }
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(parsed)) as? [String: Any],
                  list.first?.kind == 123, list.last?.kind == 125 else { throw invalid() }
            settings = object
            tokens = list
        }

        func endOfValue(_ start: Int) -> Int {
            guard [91, 123].contains(tokens[start].kind) else { return start + 1 }
            var depth = 0
            for index in start..<tokens.count {
                if [91, 123].contains(tokens[index].kind) { depth += 1 }
                else if [93, 125].contains(tokens[index].kind) { depth -= 1 }
                if depth == 0 { return index + 1 }
            }
            return tokens.count
        }

        func properties(at start: Int) throws -> [String: Int] {
            var properties: [String: Int] = [:]
            var index = start + 1
            while tokens[index].kind != 125 {
                let name = try JSONSerialization.jsonObject(
                    with: Data(bytes[tokens[index].range]), options: .fragmentsAllowed
                ) as! String
                guard properties[name] == nil else {
                    throw HookError.message(String(localized: "\(path) must be a JSON object."))
                }
                properties[name] = index + 2
                index = endOfValue(index + 2)
                if tokens[index].kind == 44 { index += 1 }
            }
            return properties
        }

        static func updating(_ data: Data, spec: String, installing: Bool, path: String) throws -> Data {
            let document = try Self(data, path: path)
            var objectStart = 0
            var object = document.settings
            var properties = try document.properties(at: 0)
            if properties["plugin"] == nil,
               let nested = properties["tui"], document.tokens[nested].kind == 123,
               let settings = object["tui"] as? [String: Any] {
                objectStart = nested
                object = settings
                properties = try document.properties(at: nested)
            }
            let encoded = Array(try JSONSerialization.data(withJSONObject: spec, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            guard let arrayStart = properties["plugin"] else {
                guard installing else { return data }
                let close = document.endOfValue(objectStart) - 1
                let comma = !properties.isEmpty && document.tokens[close - 1].kind != 44 ? "," : ""
                var bytes = document.bytes
                bytes.insert(contentsOf: Array("\(comma)\n  \"plugin\": [".utf8) + encoded + Array("]\n".utf8),
                             at: document.tokens[close].range.lowerBound)
                return Data(bytes)
            }
            guard let plugins = object["plugin"] as? [Any], document.tokens[arrayStart].kind == 91 else {
                throw HookError.message(String(localized: "\(path): plugin must be an array."))
            }
            var items: [Range<Int>] = []
            var commas: [Int: Int] = [:]
            var index = arrayStart + 1
            while document.tokens[index].kind != 93 {
                let end = document.endOfValue(index)
                items.append(index..<end)
                index = end
                if document.tokens[index].kind == 44 {
                    commas[items.count - 1] = index
                    index += 1
                }
            }
            let managed = Set(plugins.indices.filter { item in
                if plugins[item] as? String == spec { return true }
                return (plugins[item] as? [Any])?.first as? String == spec
            })
            for item in managed where plugins[item] as? String != spec {
                throw HookError.message(String(localized: "Zshell's integration at \(path) has local changes."))
            }
            if installing {
                guard managed.isEmpty else { return data }
                let comma = !items.isEmpty && commas[items.count - 1] == nil ? "," : ""
                var bytes = document.bytes
                bytes.insert(contentsOf: Array("\(comma)\n    ".utf8) + encoded + Array("\n".utf8),
                             at: document.tokens[index].range.lowerBound)
                return Data(bytes)
            }
            guard !managed.isEmpty else { return data }
            var removed = Set<Int>()
            for item in managed {
                let range = document.tokens[items[item].lowerBound].range.lowerBound..<document.tokens[items[item].upperBound - 1].range.upperBound
                removed.formUnion(range)
            }
            let kept = plugins.indices.filter { !managed.contains($0) }
            let trailingComma = !items.isEmpty && commas[items.count - 1] != nil
            for (item, comma) in commas where managed.contains(item)
                || (!trailingComma && item == kept.last) {
                removed.formUnion(document.tokens[comma].range)
            }
            return Data(document.bytes.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element })
        }
    }
}
