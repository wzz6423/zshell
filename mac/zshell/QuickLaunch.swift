//
//  QuickLaunch.swift
//  zshell
//

import AppKit
import Combine
import Foundation

/// One saved Quick Launch entry: either a shell command or an SSH connection.
/// Both launch the same way — a fresh project gets one terminal session that
/// runs the entry, then drops back to a normal shell prompt, so a finished
/// command or a closed connection never silently removes its pane.
struct QuickLaunchEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A shell command run before the configured terminal startup argv;
        /// `directory` pins where it starts, or nil follows the project default
        /// like any other new terminal.
        case command(command: String, directory: String?)
        /// An SSH connection. `user` nil lets ssh pick the current account;
        /// `port` nil means the default 22; `extraArguments` is free-form
        /// ssh command-line text (keys, forwarding) the shell word-splits.
        case ssh(user: String?, host: String, port: Int?, extraArguments: String?)
    }

    let id: UUID
    var name: String
    /// Free-form section label; entries sharing one label are grouped in the
    /// launcher list. nil keeps the entry ungrouped.
    var group: String?
    var kind: Kind

    init(name: String, kind: Kind, group: String? = nil) {
        self.id = UUID()
        self.name = name
        self.group = group
        self.kind = kind
    }

    init(id: UUID, name: String, kind: Kind, group: String? = nil) {
        self.id = id
        self.name = name
        self.group = group
        self.kind = kind
    }

    /// The command or `user@host` the entry runs, shown after its name in the
    /// launcher list.
    var detail: String? {
        switch kind {
        case .command(let command, _):
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed.replacingOccurrences(of: "\n", with: " · ")
        case .ssh(let user, let host, let port, _):
            var target = user.map { "\($0)@\(host)" } ?? host
            if let port { target += ":\(port)" }
            return target
        }
    }

    var symbolName: String {
        switch kind {
        case .command: "terminal"
        case .ssh: "network"
        }
    }

    /// The argv a new terminal session execs for this entry. A configured
    /// shell evaluates the action with its existing arguments; any other
    /// program starts only after a POSIX shell has run the action, because an
    /// arbitrary executable has no portable `-c` convention. In both cases the
    /// configured argv is then exec'd unchanged. Going through the launch argv
    /// instead of typing into the shell keeps both terminal backends race-free
    /// -- no bytes are written before the PTY exists.
    func launchArguments(startupCommand: [String]) -> [String] {
        let script: String
        switch kind {
        case .command(let command, _):
            script = command + "\n" + Self.startupCommandTail(startupCommand)
        case .ssh(let user, let host, let port, let extraArguments):
            var action = "ssh"
            if let port, port != 22 { action += " -p \(port)" }
            action += " " + TerminalSession.shellQuote(
                user.map { "\($0)@\(host)" } ?? host
            )
            let extra = extraArguments?.trimmingCharacters(in: .whitespaces) ?? ""
            if !extra.isEmpty { action += " " + extra }
            script = action + "\n" + Self.startupCommandTail(startupCommand)
        }
        return Self.commandRunner(for: startupCommand, script: script)
    }

    private static func startupCommandTail(_ startupCommand: [String]) -> String {
        "exec " + startupCommand.map(TerminalSession.shellQuote).joined(separator: " ")
    }

    private static func commandRunner(for startupCommand: [String], script: String) -> [String] {
        guard let program = startupCommand.first else { return [] }
        switch (program as NSString).lastPathComponent {
        case "bash", "dash", "fish", "ksh", "mksh", "sh", "zsh":
            return startupCommand + ["-i", "-c", script]
        default:
            return ["/bin/sh", "-l", "-c", script]
        }
    }
}

extension QuickLaunchEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, group
        case command, directory
        case user, host, port, extraArguments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `group` is optional for files written before grouping existed.
        try self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: try Self.decodeKind(from: container),
            group: try container.decodeIfPresent(String.self, forKey: .group)
        )
    }

    private static func decodeKind(from container: KeyedDecodingContainer<CodingKeys>) throws -> Kind {
        switch try container.decode(String.self, forKey: .kind) {
        case "ssh":
            return .ssh(
                user: try container.decodeIfPresent(String.self, forKey: .user),
                host: try container.decode(String.self, forKey: .host),
                port: try container.decodeIfPresent(Int.self, forKey: .port),
                extraArguments: try container.decodeIfPresent(
                    String.self, forKey: .extraArguments
                )
            )
        default:
            return .command(
                command: try container.decode(String.self, forKey: .command),
                directory: try container.decodeIfPresent(String.self, forKey: .directory)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(group, forKey: .group)
        switch kind {
        case .command(let command, let directory):
            try container.encode("command", forKey: .kind)
            try container.encode(command, forKey: .command)
            try container.encodeIfPresent(directory, forKey: .directory)
        case .ssh(let user, let host, let port, let extraArguments):
            try container.encode("ssh", forKey: .kind)
            try container.encodeIfPresent(user, forKey: .user)
            try container.encode(host, forKey: .host)
            try container.encodeIfPresent(port, forKey: .port)
            try container.encodeIfPresent(extraArguments, forKey: .extraArguments)
        }
    }
}

/// The saved Quick Launch entries, persisted next to `config.toml` as JSON.
/// User-authored launch data doesn't fit the settings file's flat key-value
/// TOML, so it lives in its own file under the same Debug/Release-separated
/// directory (`~/.config/zshell/` vs `~/.config/zshell-dev/`).
@MainActor
final class QuickLaunchStore: nonisolated ObservableObject {
    static let shared = QuickLaunchStore()

    @Published private(set) var entries: [QuickLaunchEntry] = []

    static var fileURL: URL {
        AppSettings.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("quick-launch.json")
    }

    private init() {
        entries = Self.load()
    }

    func add(_ entry: QuickLaunchEntry) {
        entries.append(entry)
        save()
    }

    func update(_ entry: QuickLaunchEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func remove(_ entry: QuickLaunchEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func save() {
        let url = Self.fileURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("zshell: failed to write \(url.path): \(error)")
        }
    }

    private static func load() -> [QuickLaunchEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([QuickLaunchEntry].self, from: data)
        } catch {
            // A hand-edited or outdated file degrades to an empty list rather
            // than blocking the launcher; the next save overwrites it.
            NSLog("zshell: failed to read \(fileURL.path): \(error)")
            return []
        }
    }
}
