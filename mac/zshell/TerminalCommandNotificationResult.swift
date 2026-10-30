import Foundation

/// The original zsh's result, captured before prompt hooks can replace `$?`.
/// The shell's typed notification title keeps consecutive results paired with
/// their messages, even when an entire output burst is replayed on reconnect.
nonisolated struct TerminalCommandNotificationResult {
    let id: UUID
    let sequence: UInt64
    let exitCode: Int

    static func parse(title: String) -> Self? {
        guard title.utf8.count <= 128 else { return nil }
        let fields = title.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "zshell-command", let id = UUID(uuidString: String(fields[1])),
              let sequence = UInt64(fields[2]), sequence > 0,
              let exitCode = Int(fields[3]), (0...255).contains(exitCode) else { return nil }
        return Self(id: id, sequence: sequence, exitCode: exitCode)
    }
}
