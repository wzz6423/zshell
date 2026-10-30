//
//  TerminalStartupCommand.swift
//  zshell
//

import Foundation

/// A user-configured argv for new terminal panes. An absent configuration keeps
/// the account's login shell; invalid input is rejected before a pane is built.
struct TerminalStartupCommand: Equatable {
    enum ConfigurationError: Error, Equatable {
        case programNotExecutable
        case invalidArguments
    }

    let program: String
    let arguments: [String]

    var argv: [String] { [program] + arguments }

    static func resolve(
        program rawProgram: String,
        arguments rawArguments: String
    ) -> Result<TerminalStartupCommand?, ConfigurationError> {
        let program = rawProgram.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !program.isEmpty else { return .success(nil) }
        guard program.hasPrefix("/"),
              !program.contains("\0"),
              isExecutableFile(atPath: program)
        else {
            return .failure(.programNotExecutable)
        }
        guard let arguments = parseArguments(rawArguments),
              !arguments.contains(where: { $0.contains("\0") })
        else {
            return .failure(.invalidArguments)
        }
        return .success(TerminalStartupCommand(program: program, arguments: arguments))
    }

    static func resolve(
        program rawProgram: String, arguments: [String], workingDirectory: String? = nil
    ) -> Result<TerminalStartupCommand?, ConfigurationError> {
        let program = rawProgram.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !program.isEmpty else {
            return arguments.isEmpty ? .success(nil) : .failure(.invalidArguments)
        }
        guard !program.contains("\0") else {
            return .failure(.programNotExecutable)
        }
        let executableExists: Bool
        if program.hasPrefix("/") {
            executableExists = isExecutableFile(atPath: program)
        } else if !program.contains("/") {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            let directories = [Bundle.main.executableURL?.deletingLastPathComponent().path].compactMap { $0 }
                + path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            executableExists = directories.contains {
                let directory: String
                if $0.hasPrefix("/") { directory = $0 }
                else if let workingDirectory {
                    directory = ($0.isEmpty ? workingDirectory : (workingDirectory as NSString).appendingPathComponent($0))
                } else { return false }
                return isExecutableFile(atPath: (directory as NSString).appendingPathComponent(program))
            }
        } else if let workingDirectory {
            executableExists = isExecutableFile(atPath: (workingDirectory as NSString).appendingPathComponent(program))
        } else {
            executableExists = false
        }
        guard executableExists else {
            return .failure(.programNotExecutable)
        }
        guard !arguments.contains(where: { $0.contains("\0") }) else {
            return .failure(.invalidArguments)
        }
        return .success(TerminalStartupCommand(program: program, arguments: arguments))
    }

    /// Splits arguments without invoking a shell. Quotes and backslashes only
    /// preserve argument boundaries; variables, globs, and substitutions remain
    /// literal so both terminal backends receive the same argv.
    static func parseArguments(_ input: String) -> [String]? {
        enum Quote {
            case single
            case double
        }

        var arguments: [String] = []
        var current = ""
        var quote: Quote?
        var hasToken = false
        var isEscaped = false

        for character in input {
            if isEscaped {
                current.append(character)
                hasToken = true
                isEscaped = false
                continue
            }

            if character == "\\", quote != .single {
                isEscaped = true
                hasToken = true
                continue
            }

            switch quote {
            case .single:
                if character == "'" {
                    quote = nil
                } else {
                    current.append(character)
                }
            case .double:
                if character == "\"" {
                    quote = nil
                } else {
                    current.append(character)
                }
            case nil:
                if character == "'" {
                    quote = .single
                    hasToken = true
                } else if character == "\"" {
                    quote = .double
                    hasToken = true
                } else if character == " " || character == "\t" || character == "\n" {
                    if hasToken {
                        arguments.append(current)
                        current = ""
                        hasToken = false
                    }
                } else {
                    current.append(character)
                    hasToken = true
                }
            }
        }

        guard quote == nil, !isEscaped else { return nil }
        if hasToken { arguments.append(current) }
        return arguments
    }

    private static func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
