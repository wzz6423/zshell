import AppKit
import Darwin
import Foundation
@testable import zshell

private struct BashPersistentFailure: Error, CustomStringConvertible { let description: String }

@main
@MainActor
struct TerminalBashPersistentInputTests {
    static var checks = 0

    static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        do { try run() } catch { fputs("FAIL Bash persistent input: \(error)\n", stderr); exit(1) }
    }

    static func run() throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard home.path.contains("zshell-bash-surface-tests-") else { throw BashPersistentFailure(description: "disposable HOME required") }
        try "HISTFILE=/dev/null\nPS1='PERSISTENT_BASH> '\n".write(
            to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        let id = UUID()
        let launchDirectory = PersistentCLIConnection.launchDirectory(for: id)
        try PersistentCLIConnection.prepare(for: id)
        try FileManager.default.createDirectory(
            at: launchDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try TerminalBashShellIntegration.makeArtifacts(in: launchDirectory)
        let script = TerminalBashShellIntegration.bootstrap(in: launchDirectory, initialization: nil) + "; exec /bin/bash -il"
        let pty = try PersistentPTY.create(
            id: id,
            launch: .init(
                program: "/bin/sh", arguments: ["-c", script], commandLine: "", interactiveShell: "/bin/bash",
                workingDirectory: root.path,
                environment: ["HOME": home.path, "HISTFILE": "/dev/null", "BASH_SILENCE_DEPRECATION_WARNING": "1"]),
            launchDirectoryURL: launchDirectory, theme: .init())
        defer {
            pty.terminate()
            pump(0.4)
            _ = try? PTYMuxCommandLine.exchange(method: "shutdown", timeout: 0.5)
        }
        let pid = pty.shellPID
        func sequence() -> UInt64? { TerminalBashShellIntegration.readPromptSequence(shellPID: pid, directory: launchDirectory) }
        func clean() -> Bool {
            guard let sequence = sequence() else { return false }
            return TerminalBashShellIntegration.persistentInputIsClean(shellPID: pid, directory: launchDirectory, promptSequence: sequence)
        }
        try wait("daemon-owned Bash reaches its original prompt") { sequence() == 1 }
        try check(clean(), "original persistent Bash starts with a clean prompt")
        var bridge: BrowserAccessMuxBridge?
        let callback = DispatchQueue(label: "sh.zshell.bash-input-test.frames")
        func observe() -> BrowserAccessMuxBridge {
            let current = BrowserAccessMuxBridge(sessionID: id)
            current.start(
                queue: callback,
                frame: { [weak current] kind, data in
                    if kind == .output { _ = current?.acknowledge(data.count) }
                }, ended: { _ in })
            return current
        }
        bridge = observe()
        defer { bridge?.close() }
        func write(_ text: String) throws {
            let deadline = Date().addingTimeInterval(5)
            while !bridge!.write(Data(text.utf8), completed: { _ in }) {
                guard Date() < deadline else { throw BashPersistentFailure(description: "browser observer input rejected") }
                pump(0.01)
            }
        }
        try write("printf BROWSER_DRAFT")
        try wait("browser input dirties the daemon-owned prompt") { !clean() }
        try check(sequence() == 1, "browser draft does not execute before Enter")
        bridge?.close()
        pump(0.15)
        bridge = observe()
        pump(0.15)
        try check(!clean(), "browser detach and reattach retain the existing draft gate")
        try check(PersistentPTY.reconnect(id: id)?.shellPID == pid, "adopting a persistent pane keeps the same root Bash process")
        try check(!clean(), "persistent pane adoption cannot erase the browser draft gate")
        try write("\u{15}")
        pump(0.12)
        try check(!clean(), "browser erasing a draft stays conservative before Enter")
        try write("\r")
        try wait("empty browser line returns to a trusted prompt") { (sequence() ?? 0) > 1 && clean() }
        let taskID = UUID()
        let tasks = launchDirectory.appendingPathComponent("command-tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try write(
            (["_zshell_command_task", taskID.uuidString, "/bin/sh", "-c", "printf BROWSER_TASK; exit 7"])
                .map(TerminalSession.shellQuote).joined(separator: " ") + "\r")
        try wait("browser-submitted finite command retains its result") {
            TerminalCommandTaskShellResult.read(taskID: taskID, shellPID: pid, directory: tasks) != nil
        }
        try check(
            TerminalCommandTaskShellResult.read(taskID: taskID, shellPID: pid, directory: tasks)?.exitCode == 7,
            "real browser observer and daemon preserve finite command exit status")
        try wait("completed browser task returns to a clean original prompt") { clean() }
        let busyTask = UUID()
        try write(
            (["_zshell_command_task", busyTask.uuidString, "/bin/sleep", ".5"])
                .map(TerminalSession.shellQuote).joined(separator: " ") + "\r")
        try wait("browser task occupies the original Bash foreground") { pty.fetchForegroundPID() != pid }
        try write("printf BROWSER_TYPED_AHEAD")
        try wait("busy browser task retains its own result") {
            TerminalCommandTaskShellResult.read(taskID: busyTask, shellPID: pid, directory: tasks) != nil
        }
        pump(0.1)
        try check(!clean(), "browser typed-ahead draft stays unavailable after a busy command finishes")
        try write("\u{15}\r")
        try wait("browser typed-ahead cancellation returns to a clean original prompt") { clean() }
        let received = root.appendingPathComponent("failure-received")
        let inputMarker = launchDirectory.appendingPathComponent("command-task-input.pid")
        try FileManager.default.removeItem(at: inputMarker)
        try FileManager.default.createDirectory(at: inputMarker, withIntermediateDirectories: false)
        try "sentinel".write(to: inputMarker.appendingPathComponent("entry"), atomically: true, encoding: .utf8)
        try write("printf RECEIVED > \(TerminalSession.shellQuote(received.path))\r")
        try wait("marker failure still delivers the browser input") { FileManager.default.fileExists(atPath: received.path) }
        try check(try String(contentsOf: received, encoding: .utf8) == "RECEIVED", "dirty-marker storage failure does not drop user input")
        try check(!clean(), "dirty-marker storage failure rejects command result admission")
        print("BashPersistentInput: \(checks) checks passed")
    }

    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw BashPersistentFailure(description: label) }
        checks += 1
        print("PASS persistent Bash: \(label)")
    }

    static func wait(_ label: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw BashPersistentFailure(description: "Timed out: " + label) }
            pump(0.01)
        }
    }

    static func pump(_ interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }
}
