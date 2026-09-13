//
//  TerminalEnvironmentSettings.swift
//  zshell
//

import Foundation

/// One environment entry kept in user order for editing and snapshot stability.
struct TerminalEnvironmentVariable: Codable, Equatable {
    var name: String
    var value: String
}

/// Project-level values inherited by every terminal created in the project.
struct TerminalLaunchSettings: Codable, Equatable {
    var environmentVariables: [TerminalEnvironmentVariable] = []
    var initializationCommand: String?

    var environment: [String: String] {
        environmentVariables.reduce(into: [:]) { result, variable in
            result[variable.name] = variable.value
        }
    }

    func applying(_ override: TerminalLaunchSettingsOverride) -> TerminalLaunchSettings {
        var variables = environmentVariables
        for variable in override.environmentVariables {
            if let index = variables.firstIndex(where: { $0.name == variable.name }) {
                variables[index] = variable
            } else {
                variables.append(variable)
            }
        }

        let command: String?
        switch override.initializationMode {
        case .inherit:
            command = initializationCommand
        case .replace:
            command = override.initializationCommand
        case .disabled:
            command = nil
        }
        return TerminalLaunchSettings(
            environmentVariables: variables,
            initializationCommand: command
        )
    }

    static func isValidEnvironmentVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first)
        else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }

    /// These variables describe the terminal surface or carry per-session
    /// capabilities. Letting persisted user input replace them would break
    /// shell integration or grant one terminal another terminal's authority.
    static func isProtectedEnvironmentVariable(_ name: String) -> Bool {
        name.hasPrefix("ZSHELL_") || [
            "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
        ].contains(name)
    }
}

/// Per-tab additions. Environment entries replace project entries with the same
/// name; the command explicitly inherits, replaces, or disables the project one.
struct TerminalLaunchSettingsOverride: Codable, Equatable {
    enum InitializationMode: String, Codable, CaseIterable {
        case inherit
        case replace
        case disabled
    }

    var environmentVariables: [TerminalEnvironmentVariable] = []
    var initializationMode: InitializationMode = .inherit
    var initializationCommand: String?
}
