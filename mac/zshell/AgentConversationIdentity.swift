import Foundation

/// Provider-owned conversation identity; never a saved shell command.
nonisolated struct AgentConversationIdentity: Codable, Equatable, Sendable {
    enum Provider: String, Codable, CaseIterable, Sendable {
        case claude, codex, pi, opencode

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

    init?(
        provider: Provider,
        sessionID: String,
        workingDirectory: String,
        configDirectory: String? = nil,
        sessionFile: String? = nil,
        alias: String? = nil,
        configurationEnvironment: [String: String]? = nil
    ) {
        guard provider.accepts(sessionID: sessionID),
              Self.isAbsolutePath(workingDirectory),
              configDirectory.map(Self.isAbsolutePath) ?? true,
              configurationEnvironment.map({ values in
                  values.allSatisfy { provider.configurationVariables.contains($0.key) && Self.isAbsolutePath($0.value) }
              }) ?? true,
              sessionFile.map({
                  provider == .pi && Self.isAbsolutePath($0) && $0.hasSuffix(".jsonl")
              }) ?? true,
              alias.map({ !$0.isEmpty && $0.utf8.count <= 128 && !Self.hasControlCharacters($0) }) ?? true
        else { return nil }
        self.provider = provider
        self.sessionID = sessionID
        self.workingDirectory = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        self.configDirectory = configDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.configurationEnvironment = configurationEnvironment?.mapValues {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        self.sessionFile = sessionFile.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.alias = alias
    }

    private enum CodingKeys: String, CodingKey {
        case provider, sessionID, workingDirectory, configDirectory, sessionFile, alias, configurationEnvironment
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
            configurationEnvironment: try container.decodeIfPresent([String: String].self, forKey: .configurationEnvironment)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionID,
                in: container,
                debugDescription: "Invalid provider conversation identity"
            )
        }
        self = identity
    }

    struct ResumeLaunch: Equatable {
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        let configurationVariables: Set<String>
    }

    /// Called only after the terminal persistence layer cannot reconnect a PTY.
    func resumeLaunch(enabled: Bool, hasLiveTerminal: Bool = false) -> ResumeLaunch? {
        guard enabled, !hasLiveTerminal else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workingDirectory, isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }

        let arguments: [String]
        switch provider {
        case .claude: arguments = ["claude", "--resume", sessionID]
        // A shared app-server cannot report which terminal owns a hook. Keep
        // resumed Codex threads embedded so later hooks retain this pane's PID.
        case .codex: arguments = ["codex", "resume", "--no-daemon", sessionID]
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
