import Foundation

/// Adds only Zshell-owned handlers to provider settings. Hook code remains a
/// link to the bundle; unrelated settings and handlers are never replaced.
enum ZshellAgentLifecycleHooks {
    enum Provider: String, Codable {
        case codex
        case claude

        func installationRoot(homeURL: URL, environment: [String: String]) -> URL {
            let variable = self == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
            if let configured = environment[variable], !configured.isEmpty {
                if configured == "~" { return homeURL }
                if configured.hasPrefix("~/") { return homeURL.appendingPathComponent(String(configured.dropFirst(2))) }
                return URL(fileURLWithPath: configured)
            }
            return homeURL.appendingPathComponent(self == .codex ? ".codex" : ".claude")
        }
    }

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

        init(event: String, action: String = "_lifecycle", matcher: String? = nil) {
            self.event = event
            self.action = action
            self.matcher = matcher
        }
    }

    private static let resourceName = "zshell-lifecycle-hook"
    private static let manifestName = ".zshell-lifecycle-hooks.json"

    private struct Manifest: Codable {
        let version: Int
        let provider: Provider
        let commands: [String: String]
        let configFile: String?
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
    }

    static func preflightInstallAvailable(
        bundle: Bundle = .main,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hooks: [Hook]? = nil
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
        hooks: [Hook]? = nil
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
        hooks: [Hook]?
    ) throws -> [Plan] {
        return try [Provider.claude, .codex].compactMap { provider in
            let root = provider.installationRoot(homeURL: homeURL, environment: environment)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory),
                  directory.boolValue else { return nil }
            return try plan(
                provider: provider, root: root,
                sourceURL: try installing ? sourceURL(bundle: bundle ?? .main) : nil,
                installing: installing, hooks: hooks ?? lifecycleHooks(provider: provider)
            )
        }
    }

    private static func plan(
        provider: Provider,
        root: URL,
        sourceURL: URL?,
        installing: Bool,
        hooks requested: [Hook]
    ) throws -> Plan? {
        let config = root.appendingPathComponent(provider == .claude ? "settings.json" : "hooks.json")
        let link = root.appendingPathComponent("hooks/\(resourceName).sh")
        let manifestURL = root.appendingPathComponent(manifestName)
        let manifest = try readManifest(at: manifestURL, provider: provider)
        if !installing, manifest == nil { return nil }
        if itemExists(link), !isManagedLink(link, sourceURL: sourceURL) {
            throw HookError.message(("Zshell's integration at \(link.path) has local changes."))
        }
        let original = try readFileIfPresent(config)
        var settings = try object(from: original, path: config.path)
        var events = try object(from: settings["hooks"], path: "\(config.path): hooks")
        let previous = manifest?.commands ?? [:]
        let command = "/bin/sh \(shellQuote(link.path)) \(provider.rawValue) _lifecycle"
        guard previous.values.allSatisfy({ $0 == command }),
              Set(previous.keys).isSubset(of: Set(lifecycleHooks(provider: provider).map(\.event))) else {
            throw HookError.message("Zshell's hook manifest at \(manifestURL.path) has local changes.")
        }
        var next: [String: String] = [:]
        var changed = false

        for event in Set(previous.keys).union(requested.map(\.event)).sorted() {
            let eventPath = "\(config.path): hooks.\(event)"
            var groups: [[String: Any]] = []
            if let value = events[event] {
                guard let parsed = value as? [[String: Any]] else {
                    throw HookError.message(("Invalid provider hooks at \(eventPath)."))
                }
                groups = parsed
            }
            var kept: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw HookError.message(("Invalid provider hooks at \(eventPath)."))
                }
                var remaining: [[String: Any]] = []
                for handler in handlers {
                    if let command = handler["command"] as? String,
                       command == previous[event] {
                        let expected: [String: Any] = ["type": "command", "command": command, "timeout": 5]
                        guard NSDictionary(dictionary: handler).isEqual(to: expected) else {
                            throw HookError.message(("Zshell's integration at \(eventPath) has local changes."))
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
                    throw HookError.message(("Invalid provider hooks at \(eventPath)."))
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
        let manifestData = installing
            ? try JSONEncoder().encode(Manifest(version: 1, provider: provider, commands: next, configFile: nil))
            : nil
        return Plan(
            configURL: config, original: original, updated: updated,
            linkURL: link, sourceURL: sourceURL,
            manifestURL: manifestURL, originalManifest: try readFileIfPresent(manifestURL),
            manifestData: manifestData
        )
    }

    private static func lifecycleHooks(provider: Provider) -> [Hook] {
        var events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest",
                      "SubagentStart", "SubagentStop", "Stop", "SessionEnd"]
        if provider == .codex { events.append("Interrupt") }
        else { events += ["StopFailure", "Elicitation", "ElicitationResult"] }
        var hooks = events.map { Hook(event: $0) }
        hooks.append(Hook(event: "PreToolUse", matcher: "AskUserQuestion|request_user_input"))
        if provider == .claude {
            hooks.append(Hook(event: "Notification", matcher: "permission_prompt|elicitation_dialog|agent_needs_input|auth_success"))
        }
        return hooks
    }

    private static func apply(_ plan: Plan, installing: Bool) throws {
        // Never overwrite a settings edit made since the multi-provider preflight.
        guard try readFileIfPresent(plan.configURL) == plan.original,
              try readFileIfPresent(plan.manifestURL) == plan.originalManifest else {
            throw HookError.message(("\(plan.configURL.path) changed while Zshell was updating hooks."))
        }
        if installing, let source = plan.sourceURL {
            try replaceLink(at: plan.linkURL, sourceURL: source)
        }
        if let updated = plan.updated, updated != plan.original {
            try writeAtomic(updated, to: plan.configURL)
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
        marker: String = "ZSHELL_LIFECYCLE_HOOK_VERSION=1"
    ) throws -> URL {
        for subdirectory in directories {
            if let url = bundle.url(forResource: name, withExtension: suffix, subdirectory: subdirectory),
               let data = try? Data(contentsOf: url),
               String(decoding: data, as: UTF8.self).contains(marker) {
                return url.standardizedFileURL
            }
        }
        throw HookError.message(("Zshell's bundled lifecycle hook is missing."))
    }

    private static func readManifest(at url: URL, provider: Provider) throws -> Manifest? {
        guard let data = try readFileIfPresent(url) else { return nil }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1, manifest.provider == provider else {
            throw HookError.message(("Zshell's hook manifest at \(url.path) has local changes."))
        }
        return manifest
    }

    private static func object(from data: Data?, path: String) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard data.count <= 1_048_576,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.message(("\(path) must be a JSON object."))
        }
        return value
    }

    private static func object(from value: Any?, path: String) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let value = value as? [String: Any] else {
            throw HookError.message(("\(path) must be a JSON object."))
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
        return url.lastPathComponent == "\(resourceName).sh"
            && target.lastPathComponent == url.lastPathComponent
            && target.path.contains(".app/Contents/Resources/")
    }

    private static func replaceLink(at url: URL, sourceURL: URL) throws {
        if itemExists(url), !isManagedLink(url, sourceURL: sourceURL) {
            throw HookError.message(("Zshell's integration at \(url.path) has local changes."))
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".zshell-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createSymbolicLink(atPath: staging.path, withDestinationPath: sourceURL.path)
        if rename(staging.path, url.path) != 0 {
            throw HookError.message(("Could not link Zshell's hook at \(url.path)."))
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
            throw HookError.message(("Could not save provider hooks at \(url.path)."))
        }
    }

    private static func itemExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}
