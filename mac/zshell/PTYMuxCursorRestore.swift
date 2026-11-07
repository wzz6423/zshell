import Darwin
import Foundation

struct PTYMuxCursorRestore {
    private let shellPID: pid_t?
    private let launchDirectoryURL: URL?
    private var pending = Data()
    private var isPending: Bool

    init(shellPID: pid_t?, foregroundPID: pid_t?, launchDirectoryURL: URL?, restoresDefaultCursor: Bool = false) {
        self.shellPID = shellPID
        self.launchDirectoryURL = launchDirectoryURL
        isPending = !restoresDefaultCursor && shellPID != nil && shellPID == foregroundPID
            && Self.isShellPrompt(shellPID: shellPID, directory: launchDirectoryURL)
    }

    mutating func process(_ bytes: Data) -> Data {
        guard isPending else { return bytes }
        pending.append(bytes)
        if pending.count >= 5 {
            for index in pending.startIndex...(pending.endIndex - 5) {
                guard pending[index] == 0x1b, pending[index + 1] == 0x5b,
                      (0x30...0x36).contains(pending[index + 2]),
                      pending[index + 3] == 0x20, pending[index + 4] == 0x71
                else { continue }
                // A daemon can outlive an app update and still serialize the
                // default prompt cursor as a steady block. Only repair its
                // first snapshot; live programs keep their own cursor styles.
                if pending[index + 2] == 0x32,
                   Self.isShellPrompt(shellPID: shellPID, directory: launchDirectoryURL) {
                    pending[index + 2] = 0x30
                }
                return finish()
            }
        }
        let count = max(pending.count - 4, 0)
        let output = Data(pending.prefix(count))
        pending = Data(pending.suffix(pending.count - count))
        return output
    }

    mutating func finish() -> Data {
        isPending = false
        let output = pending
        pending = Data()
        return output
    }

    private static func isShellPrompt(shellPID: pid_t?, directory: URL?) -> Bool {
        guard let shellPID, shellPID > 1, let directory,
              let value = try? String(contentsOf: directory.appendingPathComponent("prompt-selection.pid"),
                                      encoding: .utf8)
        else { return false }
        return pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) == shellPID
    }
}
