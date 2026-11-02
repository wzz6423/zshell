import Foundation

nonisolated struct TerminalProfileContext: Codable, Equatable, Sendable {
    var host: String?
    var user: String?
    var directory: String?
    var program: String?
    var hostAlias: String?

    func matches(_ profile: TerminalProfile) -> Bool {
        (profile.host.isEmpty || [host, hostAlias].compactMap { $0 }.contains {
            TerminalProfileGlob.matches(profile.host.lowercased(), $0.lowercased())
        })
            && matches(profile.user, user)
            && matches(profile.directory, directory)
            && (profile.program.isEmpty || program.map {
                TerminalProfileGlob.matches(profile.program, $0)
                    || TerminalProfileGlob.matches(profile.program, ($0 as NSString).lastPathComponent)
            } == true)
    }

    private func matches(_ pattern: String, _ value: String?) -> Bool {
        pattern.isEmpty || value.map { TerminalProfileGlob.matches(pattern, $0) } == true
    }
}

/// These overrides can be applied without replacing a pane's process or PTY.
nonisolated struct TerminalProfileAppearance: Codable, Equatable {
    var themeDark: String?
    var themeLight: String?
    var fontFamily: String?
    var fontSize: Double?
    var cursorShape: String?
    var cursorBlinking: Bool?
}

nonisolated struct TerminalProfile: Equatable, Identifiable {
    static let maximumCount = 64
    static let maximumPatternBytes = 256

    var id = UUID()
    var name: String
    var enabled = true
    var host = ""
    var user = ""
    var directory = ""
    var program = ""
    var appearance = TerminalProfileAppearance()
    var launchSettings = TerminalLaunchSettings()
    var startupProgram = ""
    var startupArguments = ""

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.utf8.count <= 128
            && name.rangeOfCharacter(from: .controlCharacters) == nil
            && [host, user, directory, program].allSatisfy {
                $0.utf8.count <= Self.maximumPatternBytes
                    && $0.rangeOfCharacter(from: .controlCharacters) == nil
            }
            && appearance.fontSize.map { $0.isFinite && (8...32).contains($0) } != false
            && appearance.cursorShape.map { ["block", "bar", "underline"].contains($0) } != false
            && [appearance.themeDark, appearance.themeLight, appearance.fontFamily].compactMap { $0 }.allSatisfy {
                $0.utf8.count <= 128 && $0.rangeOfCharacter(from: .controlCharacters) == nil
            }
            && launchSettings.environmentVariables.count <= 128
            && Set(launchSettings.environmentVariables.map(\.name)).count == launchSettings.environmentVariables.count
            && launchSettings.environmentVariables.allSatisfy {
                TerminalLaunchSettings.isValidEnvironmentVariableName($0.name)
                    && !TerminalLaunchSettings.isProtectedEnvironmentVariable($0.name)
                    && $0.value.utf8.count <= 4096 && !$0.value.contains("\0")
            }
            && (launchSettings.initializationCommand?.utf8.count ?? 0) <= 4096
            && launchSettings.initializationCommand?.contains("\0") != true
            && startupProgram.utf8.count <= 4096 && !startupProgram.contains("\0")
            && startupArguments.utf8.count <= 4096 && !startupArguments.contains("\0")
    }

    func applyingLaunchSettings(
        to base: TerminalLaunchSettings, usesConfiguredInitializationCommand: Bool = true
    ) -> TerminalLaunchSettings {
        base.applying(TerminalLaunchSettingsOverride(
            environmentVariables: launchSettings.environmentVariables,
            initializationMode: usesConfiguredInitializationCommand && launchSettings.initializationCommand != nil ? .replace : .inherit,
            initializationCommand: launchSettings.initializationCommand
        ))
    }

    static func firstMatch(in profiles: [TerminalProfile], context: TerminalProfileContext) -> TerminalProfile? {
        profiles.prefix(maximumCount).first { $0.enabled && $0.isValid && context.matches($0) }
    }

    static func read(_ values: [String: TOML.Value]) -> [TerminalProfile] {
        var profiles: [TerminalProfile] = []
        var seen = Set<UUID>()
        for index in 0..<maximumCount {
            let prefix = "terminal.profiles.\(index)."
            guard let rawID = values[prefix + "id"]?.string, let id = UUID(uuidString: rawID),
                  let name = values[prefix + "name"]?.string, seen.insert(id).inserted else { continue }
            var profile = TerminalProfile(id: id, name: name)
            profile.enabled = values[prefix + "enabled"]?.bool ?? true
            profile.host = values[prefix + "host"]?.string ?? ""
            profile.user = values[prefix + "user"]?.string ?? ""
            profile.directory = values[prefix + "directory"]?.string ?? ""
            profile.program = values[prefix + "program"]?.string ?? ""
            profile.appearance = TerminalProfileAppearance(
                themeDark: values[prefix + "theme-dark"]?.string,
                themeLight: values[prefix + "theme-light"]?.string,
                fontFamily: values[prefix + "font-family"]?.string,
                fontSize: values[prefix + "font-size"]?.double,
                cursorShape: values[prefix + "cursor-shape"]?.string,
                cursorBlinking: values[prefix + "cursor-blinking"]?.bool
            )
            profile.startupProgram = values[prefix + "startup-program"]?.string ?? ""
            profile.startupArguments = values[prefix + "startup-arguments"]?.string ?? ""
            profile.launchSettings.initializationCommand = values[prefix + "initialization-command"]?.string
            let environmentPrefix = prefix + "environment."
            profile.launchSettings.environmentVariables = values.keys.filter {
                $0.hasPrefix(environmentPrefix)
            }.sorted().compactMap { key in
                values[key]?.string.map {
                    TerminalEnvironmentVariable(name: String(key.dropFirst(environmentPrefix.count)), value: $0)
                }
            }
            if profile.isValid { profiles.append(profile) }
        }
        return profiles
    }

    static func configLines(_ profiles: [TerminalProfile]) -> [String] {
        var lines: [String] = []
        for (index, profile) in profiles.prefix(maximumCount).enumerated() {
            let prefix = "terminal.profiles.\(index)."
            func string(_ key: String, _ value: String?) {
                if let value { lines.append(prefix + key + " = " + TOML.quote(value)) }
            }
            string("id", profile.id.uuidString)
            string("name", profile.name)
            if !profile.enabled { lines.append(prefix + "enabled = false") }
            for (key, value) in [("host", profile.host), ("user", profile.user),
                                 ("directory", profile.directory), ("program", profile.program)] where !value.isEmpty {
                string(key, value)
            }
            string("theme-dark", profile.appearance.themeDark)
            string("theme-light", profile.appearance.themeLight)
            string("font-family", profile.appearance.fontFamily)
            if let size = profile.appearance.fontSize { lines.append(prefix + "font-size = " + TOML.number(size)) }
            string("cursor-shape", profile.appearance.cursorShape)
            if let blinking = profile.appearance.cursorBlinking { lines.append(prefix + "cursor-blinking = \(blinking)") }
            if !profile.startupProgram.isEmpty { string("startup-program", profile.startupProgram) }
            if !profile.startupArguments.isEmpty { string("startup-arguments", profile.startupArguments) }
            string("initialization-command", profile.launchSettings.initializationCommand)
            for variable in profile.launchSettings.environmentVariables {
                string("environment." + variable.name, variable.value)
            }
        }
        return lines
    }
}

/// An iterative glob avoids regex compilation and recursive backtracking on
/// the session monitor. Both pattern and process metadata have fixed limits.
nonisolated enum TerminalProfileGlob {
    static func matches(_ pattern: String, _ value: String) -> Bool {
        guard pattern.utf8.count <= TerminalProfile.maximumPatternBytes,
              value.utf8.count <= 4096, !value.contains("\0") else { return false }
        let pattern = Array(pattern.unicodeScalars)
        let value = Array(value.unicodeScalars)
        var p = 0
        var v = 0
        var star: Int?
        var retry = 0
        var comparisons = 0
        while v < value.count {
            comparisons += 1
            guard comparisons <= 32_768 else { return false }
            if p < pattern.count, pattern[p] == "?" || pattern[p] == value[v] {
                p += 1
                v += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                p += 1
                retry = v
            } else if let star {
                retry += 1
                v = retry
                p = star + 1
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
