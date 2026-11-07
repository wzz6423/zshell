import Darwin
import Foundation

@main
struct PTYMuxCursorRestoreTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshell-cursor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("prompt-selection.pid")
        let pid = getpid()
        try String(pid).write(to: ready, atomically: true, encoding: .utf8)
        let snapshot = Data("\u{1b}cprompt> \u{1b}[1;9H\u{1b}7\u{1b}[2 q".utf8)
        let expected = Data("\u{1b}cprompt> \u{1b}[1;9H\u{1b}7\u{1b}[0 q".utf8)

        func fixture(foreground: pid_t? = pid, launchDirectory: URL? = directory) -> PTYMuxCursorRestore {
            PTYMuxCursorRestore(shellPID: pid, foregroundPID: foreground, launchDirectoryURL: launchDirectory)
        }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            print("PASS: \(label)")
        }

        for boundary in 0...snapshot.count {
            var restore = fixture()
            var output = restore.process(Data(snapshot.prefix(boundary)))
            output.append(restore.process(Data(snapshot.dropFirst(boundary))))
            output.append(restore.finish())
            check(output == expected, "legacy snapshot split at byte \(boundary)")
        }
        var bytewise = fixture()
        var output = Data()
        for byte in snapshot { output.append(bytewise.process(Data([byte]))) }
        output.append(bytewise.finish())
        check(output == expected, "one-byte reads preserve the snapshot and restore the cursor")

        var restore = fixture()
        let live = Data("\u{1b}[4 qapplication\u{1b}[2 q".utf8)
        check(restore.process(snapshot + live) == expected + live,
              "only the initial snapshot changes when live output shares the read")
        check(restore.process(live) == live, "later application cursor changes pass through")
        let current = Data("\u{1b}cprompt> \u{1b}[0 q".utf8)
        var currentRestore = fixture()
        check(currentRestore.process(current) == current, "current daemon default cursor stays unchanged")
        var currentDaemon = PTYMuxCursorRestore(shellPID: pid, foregroundPID: pid,
                                               launchDirectoryURL: directory, restoresDefaultCursor: true)
        check(currentDaemon.process(snapshot) == snapshot, "current daemons preserve explicit prompt cursor overrides")
        for style in [0, 1, 3, 4, 5, 6] {
            var explicit = fixture()
            let bytes = Data("\u{1b}cprompt> \u{1b}[\(style) q".utf8)
            check(explicit.process(bytes) == bytes, "other initial cursor styles pass through: \(style)")
            check(explicit.process(snapshot) == snapshot, "live block styles stay unchanged after style \(style)")
        }

        var foreground = fixture(foreground: pid + 1)
        check(foreground.process(snapshot) == snapshot, "foreground jobs keep their cursor")
        var missingDirectory = fixture(launchDirectory: nil)
        check(missingDirectory.process(snapshot) == snapshot, "sessions without shell integration pass through")
        try String(pid + 1).write(to: ready, atomically: true, encoding: .utf8)
        var differentShell = fixture()
        check(differentShell.process(snapshot) == snapshot, "another shell's readiness cannot reset the cursor")
        try "".write(to: ready, atomically: true, encoding: .utf8)
        var busyShell = fixture()
        check(busyShell.process(snapshot) == snapshot, "a shell outside its prompt passes through")
        try String(pid).write(to: ready, atomically: true, encoding: .utf8)
        var changed = fixture()
        let prefix = Data(snapshot.dropLast(1))
        var changedOutput = changed.process(prefix)
        try "".write(to: ready, atomically: true, encoding: .utf8)
        changedOutput.append(changed.process(Data(snapshot.suffix(1))))
        check(changedOutput == snapshot, "readiness is rechecked when the style arrives")

        try String(pid).write(to: ready, atomically: true, encoding: .utf8)
        var ended = fixture()
        let incomplete = Data("prompt> \u{1b}[2 ".utf8)
        var endedOutput = ended.process(incomplete)
        endedOutput.append(ended.finish())
        check(endedOutput == incomplete, "closing the stream flushes an incomplete sequence")
        var bounded = fixture()
        let large = Data(repeating: 0x78, count: 1024 * 1024)
        check(bounded.process(large).count == large.count - 4, "only four trailing bytes remain buffered")
        check(bounded.finish().count == 4, "the trailing bytes are released on completion")
    }
}
