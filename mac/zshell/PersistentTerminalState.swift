import Foundation

/// A renderer-free mirror keeps the screen current while the GUI is absent.
/// Calls belong to its PTY session's serial I/O queue.
final class PersistentTerminalState {
    private let handle: OpaquePointer

    init(columns: UInt16, rows: UInt16, theme: ZshellTheme) throws {
        var theme = theme
        guard let handle = zshell_persistent_terminal_new(columns, rows, &theme) else {
            throw PTYMuxError.message("Could not create persistent terminal state.")
        }
        self.handle = handle
    }

    deinit {
        zshell_persistent_terminal_free(handle)
    }

    func feed(_ bytes: Data, answerQueries: Bool) -> Data {
        bytes.withUnsafeBytes { raw in
            zshell_persistent_terminal_feed(
                handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, answerQueries
            )
        }
        var count = 0
        guard let bytes = zshell_persistent_terminal_replies(handle, &count), count > 0 else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    func snapshot() throws -> Data {
        var count = 0
        guard let bytes = zshell_persistent_terminal_snapshot(handle, &count),
              count <= PTYMuxConstants.maximumSnapshotBytes else {
            throw PTYMuxError.message("Persistent terminal snapshot exceeds its memory limit.")
        }
        return Data(bytes: bytes, count: count)
    }

    func resize(columns: UInt16, rows: UInt16, cellWidth: UInt16, cellHeight: UInt16) {
        zshell_persistent_terminal_resize(handle, columns, rows, cellWidth, cellHeight)
    }

    func setTheme(_ theme: ZshellTheme) {
        var theme = theme
        zshell_persistent_terminal_set_theme(handle, &theme)
    }
}
