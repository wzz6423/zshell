import Foundation

/// Provider-owned conversation identity; never a saved shell command.
nonisolated struct AgentConversationIdentity: Codable, Equatable, Sendable {
    enum Provider: String, Codable, CaseIterable, Sendable {
        case claude, codex, pi, opencode

        var displayName: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .pi: "Pi"
            case .opencode: "OpenCode"
            }
        }

        var configurationVariable: String {
            switch self {
            case .claude: "CLAUDE_CONFIG_DIR"
            case .codex: "CODEX_HOME"
            case .pi: "PI_CODING_AGENT_DIR"
            case .opencode: "XDG_CONFIG_HOME"
            }
        }

        var configurationVariables: Set<String> {
            self == .opencode
                ? ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG", "OPENCODE_TUI_CONFIG"]
                : [configurationVariable]
        }

        var forkHelpArguments: [String] {
            self == .codex ? [rawValue, "fork", "--help"] : [rawValue, "--help"]
        }

        func supportsNativeFork(help: String) -> Bool {
            if self == .codex { return help.contains("Usage: codex fork") && help.contains("SESSION_ID") }
            return help.split(whereSeparator: { $0.isWhitespace }).contains(
                self == .claude ? "--fork-session" : "--fork"
            )
        }

        func configurationDirectory(
            homeURL: URL,
            environment: [String: String]
        ) -> URL {
            if let value = environment[configurationVariable], !value.isEmpty {
                return Self.expandedURL(value, homeURL: homeURL)
            }
            let relative: String
            switch self {
            case .claude: relative = ".claude"
            case .codex: relative = ".codex"
            case .pi: relative = ".pi/agent"
            case .opencode: relative = ".config"
            }
            return homeURL.appendingPathComponent(relative, isDirectory: true)
        }

        func installationRoot(homeURL: URL, environment: [String: String]) -> URL {
            let directory = configurationDirectory(homeURL: homeURL, environment: environment)
            return self == .opencode
                ? directory.appendingPathComponent("opencode", isDirectory: true)
                : directory
        }

        func accepts(sessionID: String) -> Bool {
            switch self {
            case .claude, .codex, .pi:
                return sessionID.utf8.count == 36 && UUID(uuidString: sessionID) != nil
            case .opencode:
                return sessionID.hasPrefix("ses_")
                    && (5...128).contains(sessionID.utf8.count)
                    && sessionID.utf8.dropFirst(4).allSatisfy {
                        (48...57).contains($0) || (65...90).contains($0)
                            || (97...122).contains($0) || $0 == 95 || $0 == 45
                    }
            }
        }

        private static func expandedURL(_ path: String, homeURL: URL) -> URL {
            if path == "~" { return homeURL }
            if path.hasPrefix("~/") {
                return homeURL.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
            }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
    }

    let provider: Provider
    let sessionID: String
    let workingDirectory: String
    let configDirectory: String?
    let configurationEnvironment: [String: String]?
    /// Pi can store sessions outside its normal directory via --session-dir.
    let sessionFile: String?
    let alias: String?
    let remoteHostID: UUID?
    let remoteProjectDirectory: String?

    init?(
        provider: Provider,
        sessionID: String,
        workingDirectory: String,
        configDirectory: String? = nil,
        sessionFile: String? = nil,
        alias: String? = nil,
        configurationEnvironment: [String: String]? = nil,
        remoteHostID: UUID? = nil,
        remoteProjectDirectory: String? = nil
    ) {
        let validPath = remoteHostID == nil ? Self.isAbsolutePath : Self.isRemoteAbsolutePath
        guard provider.accepts(sessionID: sessionID),
              validPath(workingDirectory),
              configDirectory.map(validPath) ?? true,
              configurationEnvironment.map({ values in
                  values.allSatisfy { provider.configurationVariables.contains($0.key) && validPath($0.value) }
              }) ?? true,
              sessionFile.map({
                  provider == .pi && validPath($0) && $0.hasSuffix(".jsonl")
              }) ?? true,
              (remoteHostID == nil && remoteProjectDirectory == nil
                || remoteHostID != nil && remoteProjectDirectory.map(validPath) == true),
              alias.map({ !$0.isEmpty && $0.utf8.count <= 128 && !Self.hasControlCharacters($0) }) ?? true
        else { return nil }
        self.provider = provider
        self.sessionID = sessionID
        let normalize: (String) -> String = remoteHostID == nil
            ? { URL(fileURLWithPath: $0).standardizedFileURL.path } : { $0 }
        self.workingDirectory = normalize(workingDirectory)
        self.configDirectory = configDirectory.map(normalize)
        self.configurationEnvironment = configurationEnvironment?.mapValues {
            normalize($0)
        }
        self.sessionFile = sessionFile.map(normalize)
        self.alias = alias
        self.remoteHostID = remoteHostID
        self.remoteProjectDirectory = remoteProjectDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case provider, sessionID, workingDirectory, configDirectory, sessionFile, alias, configurationEnvironment
        case remoteHostID, remoteProjectDirectory
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let identity = Self(
            provider: try container.decode(Provider.self, forKey: .provider),
            sessionID: try container.decode(String.self, forKey: .sessionID),
            workingDirectory: try container.decode(String.self, forKey: .workingDirectory),
            configDirectory: try container.decodeIfPresent(String.self, forKey: .configDirectory),
            sessionFile: try container.decodeIfPresent(String.self, forKey: .sessionFile),
            alias: try container.decodeIfPresent(String.self, forKey: .alias),
            configurationEnvironment: try container.decodeIfPresent([String: String].self, forKey: .configurationEnvironment),
            remoteHostID: try container.decodeIfPresent(UUID.self, forKey: .remoteHostID),
            remoteProjectDirectory: try container.decodeIfPresent(String.self, forKey: .remoteProjectDirectory)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionID,
                in: container,
                debugDescription: "Invalid provider conversation identity"
            )
        }
        self = identity
    }

    struct ResumeLaunch: Equatable, Sendable {
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        let configurationVariables: Set<String>
    }

    func matchesConversation(_ other: Self) -> Bool {
        provider == other.provider && sessionID == other.sessionID
            && remoteHostID == other.remoteHostID && remoteProjectDirectory == other.remoteProjectDirectory
            && workingDirectory == other.workingDirectory && configDirectory == other.configDirectory
            && (configurationEnvironment ?? [:]) == (other.configurationEnvironment ?? [:])
            && sessionFile == other.sessionFile
    }

    /// Called only after the terminal persistence layer cannot reconnect a PTY.
    func resumeLaunch(enabled: Bool, hasLiveTerminal: Bool = false) -> ResumeLaunch? {
        guard enabled, !hasLiveTerminal, remoteHostID == nil else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workingDirectory, isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }

        let arguments: [String]
        switch provider {
        case .claude: arguments = ["claude", "--resume", sessionID]
        case .codex: arguments = ["codex", "resume", sessionID]
        case .opencode: arguments = ["opencode", "--session", sessionID]
        case .pi:
            guard let sessionFile,
                  Self.piSessionFileMatches(
                    path: sessionFile, sessionID: sessionID, directory: workingDirectory
                  ) else { return nil }
            arguments = ["pi", "--session", sessionFile]
        }
        let environment = (configDirectory.map { [provider.configurationVariable: $0] } ?? [:])
            .merging(configurationEnvironment ?? [:], uniquingKeysWith: { _, saved in saved })
        return ResumeLaunch(
            arguments: arguments, workingDirectory: workingDirectory,
            environment: environment, configurationVariables: provider.configurationVariables
        )
    }

    func forkLaunch() -> ResumeLaunch? {
        guard let launch = resumeLaunch(enabled: true) else { return nil }
        let arguments: [String]
        switch provider {
        case .claude: arguments = ["claude", "--resume", sessionID, "--fork-session"]
        case .codex: arguments = ["codex", "fork", sessionID]
        case .opencode: arguments = ["opencode", "--session", sessionID, "--fork"]
        case .pi:
            guard let sessionFile else { return nil }
            arguments = ["pi", "--fork", sessionFile]
        }
        return ResumeLaunch(arguments: arguments, workingDirectory: launch.workingDirectory,
                            environment: launch.environment, configurationVariables: launch.configurationVariables)
    }

    func acceptsFork(_ identity: Self) -> Bool {
        provider == identity.provider
            && (provider == .opencode ? sessionID != identity.sessionID : sessionID.lowercased() != identity.sessionID.lowercased())
            && workingDirectory == identity.workingDirectory
            && (configDirectory == nil || configDirectory == identity.configDirectory)
            && (configurationEnvironment ?? [:]).allSatisfy { identity.configurationEnvironment?[$0.key] == $0.value }
            && remoteHostID == identity.remoteHostID && remoteProjectDirectory == identity.remoteProjectDirectory
            && (provider != .pi || identity.sessionFile != nil && sessionFile != identity.sessionFile)
    }

    static func piSessionFileMatches(path: String, sessionID: String, directory: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384),
              !data.isEmpty,
              let header = try? JSONSerialization.jsonObject(
                with: data.prefix { $0 != 0x0A }
              ) as? [String: Any],
              header["type"] as? String == "session",
              header["id"] as? String == sessionID,
              let cwd = header["cwd"] as? String, Self.isAbsolutePath(cwd)
        else { return false }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path == directory
    }

    static func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4_096 && !hasControlCharacters(path)
    }

    static func isRemoteAbsolutePath(_ path: String) -> Bool {
        guard path.utf8.count <= 4_096, !hasControlCharacters(path) else { return false }
        if path.hasPrefix("/") || path.hasPrefix("\\\\") { return true }
        let bytes = Array(path.utf8.prefix(3))
        return bytes.count == 3 && ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0]))
            && bytes[1] == 58 && (bytes[2] == 92 || bytes[2] == 47)
    }

    static func remote(_ value: ZshellJSONValue, hostID: UUID, project: String) -> Self? {
        guard var fields = value.objectValue else { return nil }
        fields["remoteHostID"] = .string(hostID.uuidString)
        fields["remoteProjectDirectory"] = .string(project)
        guard let bytes = try? JSONEncoder().encode(ZshellJSONValue.object(fields)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: bytes)
    }

    private static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Normalized evidence supplied by a provider hook or a terminal-side plugin.
nonisolated struct AgentConversationSessionEvent: Equatable {
    let identity: AgentConversationIdentity
    let reporterPID: Int32
    let source: String?

    static func sessionStart(
        provider: AgentConversationIdentity.Provider,
        payload: Data,
        environment: [String: String],
        reporterPID: Int32,
        currentDirectory: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self? {
        guard payload.count <= 1_048_576, reporterPID > 1,
              let fields = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              fields["hook_event_name"] as? String == "SessionStart",
              (fields["agent_id"] as? String ?? "").isEmpty,
              (fields["parent_session_id"] as? String ?? "").isEmpty,
              let sessionID = fields["session_id"] as? String
        else { return nil }
        if provider == .codex,
           let threadID = environment["CODEX_THREAD_ID"], !threadID.isEmpty,
           threadID != sessionID { return nil }
        guard let identity = AgentConversationIdentity(
            provider: provider,
            sessionID: sessionID,
            workingDirectory: fields["cwd"] as? String ?? currentDirectory,
            configDirectory: provider.configurationDirectory(
                homeURL: homeURL, environment: environment
            ).path,
            sessionFile: fields["session_file"] as? String,
            configurationEnvironment: environment.filter {
                provider.configurationVariables.contains($0.key) && AgentConversationIdentity.isAbsolutePath($0.value)
            }
        ) else { return nil }
        return Self(identity: identity, reporterPID: reporterPID, source: fields["source"] as? String)
    }
}
