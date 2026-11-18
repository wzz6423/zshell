import AppKit
import Darwin
@testable import zshell

private struct LifecycleFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct TerminalSessionLifecycleSurfaceTests {
    @MainActor static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        if RemoteSessionRelay.shouldRun { RemoteSessionRelay.run() }
        QuickTerminalOffscreen.install()
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated {
                do { try run(); exit(0) }
                catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
            }
        }
        application.run()
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        let backend = TerminalBackend(rawValue: CommandLine.arguments[1])!
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let mode = CommandLine.arguments[3]
        let settings = AppSettings.shared
        settings.applyImported([:])
        settings.terminalBackend = backend
        settings.preserveTerminalSessions = false
        settings.browserAccessEnabled = false
        try settings.setAIEnabled(false)
        var sessions: [TerminalSession] = []
        var windows: [NSWindow] = []
        var jobs: [ZshellAgentProcessIdentity] = []
        var identities: [String: [String: UInt64]] = [:]

        func record(_ process: ZshellAgentProcessIdentity, scope: pid_t?) throws {
            var value = ["pid": UInt64(process.pid), "seconds": process.startedSeconds, "microseconds": process.startedMicroseconds]
            if let scope { value["session"] = UInt64(scope) }
            identities[String(process.pid)] = value
            try JSONEncoder().encode(Array(identities.values)).write(to: root.appendingPathComponent("process-identities.json"), options: .atomic)
        }

        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw LifecycleFailure(description: label) }
            print("PASS \(backend.rawValue): \(label)")
        }

        func pump(_ duration: TimeInterval) {
            let deadline = Date().addingTimeInterval(duration)
            while Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
        }

        func wait(_ label: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition() {
                guard Date() < deadline else { throw LifecycleFailure(description: "Timed out: \(label)") }
                pump(0.01)
            }
        }

        func mount(_ session: TerminalSession) {
            sessions.append(session)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = session.surface
            window.orderFront(nil)
            session.surface.setSurfaceVisible(true)
            windows.append(window)
        }

        func observe(_ file: URL, scope: pid_t? = nil) throws -> ZshellAgentProcessIdentity {
            try wait("PID at \(file.lastPathComponent)") {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
                return ZshellAgentProcessIdentity(pid: pid) != nil
            }
            let pid = pid_t(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
            let identity = ZshellAgentProcessIdentity(pid: pid)!
            jobs.append(identity)
            try record(identity, scope: scope)
            return identity
        }

        func launch(_ name: String, forks: Bool = false) throws -> (TerminalSession, ZshellAgentProcessIdentity) {
            let pidFile = root.appendingPathComponent("\(name).pid")
            let ready = root.appendingPathComponent("\(name).ready")
            let successor = root.appendingPathComponent("\(name).successor")
            let gate = root.appendingPathComponent("\(name).continue")
            let handler = """
            trap '' HUP
            (trap '' HUP; exec /bin/sleep 60) &
            echo $! > '\(successor.path)'
            while [ ! -f '\(gate.path)' ]; do /bin/sleep 0.005; done
            """.replacingOccurrences(of: "'", with: "'\\''")
            let script = """
            set -m
            \(forks ? "trap '\(handler)' HUP" : "trap '' HUP")
            (trap '' HUP; : > '\(ready.path)'; exec /bin/sleep 60) &
            echo $! > '\(pidFile.path)'
            while :; do read -r line || :; done
            """
            let session = TerminalSession(initialDirectory: root.path, commandArguments: ["/bin/sh", "-c", script])
            mount(session)
            try wait("root PTY identity") { session.shellPid.flatMap(ZshellAgentProcessIdentity.init(pid:)) != nil }
            let shell = ZshellAgentProcessIdentity(pid: session.shellPid!)!
            try record(shell, scope: getsid(shell.pid))
            let job = try observe(pidFile, scope: getsid(shell.pid))
            try wait("HUP-ignoring background job") { FileManager.default.fileExists(atPath: ready.path) }
            try check(getsid(job.pid) == getsid(shell.pid) && getpgid(job.pid) != getpgid(shell.pid),
                      "real surface owns a background job in another process group (shell=\(session.shellPid ?? 0), job=\(job.pid), SID=\(getsid(job.pid)), PGID=\(getpgid(job.pid)))")
            return (session, job)
        }

        defer {
            sessions.forEach { $0.terminate() }
            pump(0.5)
            for job in jobs where job.isAlive { _ = Darwin.kill(job.pid, SIGKILL) }
            windows.forEach { $0.close() }
        }

        if mode.hasPrefix("quit") {
            let manager = TerminalManager()
            guard let project = manager.selectedProject else { throw LifecycleFailure(description: "No project") }
            mount(project.sessions[0])
            try wait("quit shell starts") { project.sessions[0].shellPid.flatMap(ZshellAgentProcessIdentity.init(pid:)) != nil }
            let shell = ZshellAgentProcessIdentity(pid: project.sessions[0].shellPid!)!
            try record(shell, scope: getsid(shell.pid))
            let pidFile = root.appendingPathComponent("quit.pid")
            project.sessions[0].surface.sendText("trap '' HUP; (trap '' HUP; exec /bin/sleep 60) & echo $! > "
                + TerminalSession.shellQuote(pidFile.path) + "\n")
            let job = try observe(pidFile, scope: getsid(shell.pid))
            try check(getsid(job.pid) == getsid(shell.pid) && getpgid(job.pid) != getpgid(shell.pid),
                      "quit fixture owns a separate background group (shell=\(project.sessions[0].shellPid ?? 0), job=\(job.pid), SID=\(getsid(job.pid)), PGID=\(getpgid(job.pid)))")
            let evidence = ["pid": UInt64(job.pid), "seconds": job.startedSeconds, "microseconds": job.startedMicroseconds]
            try JSONEncoder().encode(evidence).write(to: root.appendingPathComponent("quit-identity.json"))
            if mode == "quit-overlay" {
                settings.quickTerminalEnabled = true
                settings.quickTerminalMode = .fresh
                let overlay = GlobalTerminalOverlay.shared
                overlay.toggle()
                guard let quick = overlay.allSessions.first else { throw LifecycleFailure(description: "Quick Terminal did not launch") }
                try wait("fresh overlay shell starts") { quick.shellPid.flatMap(ZshellAgentProcessIdentity.init(pid:)) != nil }
                let quickRoot = ZshellAgentProcessIdentity(pid: quick.shellPid!)!
                try record(quickRoot, scope: getsid(quickRoot.pid))
                let quickJobFile = root.appendingPathComponent("quick.pid")
                quick.surface.sendText("trap '' HUP; (trap '' HUP; exec /bin/sleep 60) & echo $! > "
                    + TerminalSession.shellQuote(quickJobFile.path) + "\n")
                _ = try observe(quickJobFile, scope: getsid(quickRoot.pid))
                try check(QuickTerminalOffscreen.isSafe(), "fresh overlay quit fixture stays offscreen")
            }
            let delegate = ZshellApplicationDelegate()
            NSApp.delegate = delegate
            TerminalManager.requestApplicationQuit(endAll: mode == "quit-all")
            pump(5)
            withExtendedLifetime(delegate) {}
            throw LifecycleFailure(description: "Application did not terminate")
        }

        let (sentinel, sentinelJob) = try launch("sentinel")
        let (local, job) = try launch("local")
        local.terminate()
        local.terminate()
        try wait("explicit local close") { local.hasExited && !job.isAlive }
        try check(sentinelJob.isAlive && !sentinel.hasExited, "closing one real terminal preserves another session")

        let (forking, firstJob) = try launch("fork", forks: true)
        forking.terminate()
        let successor = try observe(root.appendingPathComponent("fork.successor"), scope: forking.shellPid.map(getsid))
        try Data().write(to: root.appendingPathComponent("fork.continue"))
        try wait("HUP successor closes") { forking.hasExited && !firstJob.isAlive && !successor.isAlive }
        try check(!successor.isAlive, "real surface close cleans up a job created by the HUP handler")

        settings.preserveTerminalSessions = true
        let (preserved, preservedJob) = try launch("preserved")
        try check(preserved.persistentSessionID == preserved.id, "preservation fixture uses the daemon-owned PTY")
        preserved.prepareForApplicationQuit(preserve: true)
        pump(0.3)
        try check(preservedJob.isAlive, "application preservation keeps the background group alive")
        let reattached = TerminalSession(initialDirectory: root.path, restoredSessionID: preserved.id)
        mount(reattached)
        try check(reattached.reconnectedToPersistentPTY && reattached.shellPid == preserved.shellPid,
                  "reattach keeps the same persistent shell")
        reattached.terminate()
        try wait("preserved PTY is explicitly stopped") { !preservedJob.isAlive }
        settings.preserveTerminalSessions = false

        let remoteDirectory = ProcessInfo.processInfo.environment["ZSHELL_LIFECYCLE_REMOTE_DIRECTORY"]!
        let host = try RemoteHost(name: "lifecycle fixture", address: ProcessInfo.processInfo.environment["ZSHELL_LIFECYCLE_REMOTE_ADDRESS"]!,
                                  serverPath: ProcessInfo.processInfo.environment["ZSHELL_LIFECYCLE_REMOTE_SERVER"]!)
        let remoteID = UUID()
        defer { try? RemoteHostClient.terminate(host: host, directory: remoteDirectory, sessionID: remoteID) }
        func attachRemote() throws -> TerminalSession {
            let connection = try RemoteSessionConnection(host: host, directory: remoteDirectory, sessionID: remoteID,
                createIfMissing: true, command: ["/bin/sh", "-i"], launchSettings: .init())
            let session = TerminalSession(initialDirectory: root.path, commandArguments: connection.launchArguments,
                                          remoteConnection: connection)
            mount(session)
            try wait("real SSH connection") { session.remoteStatus?.state == .connected }
            return session
        }
        let remote = try attachRemote()
        let remoteJobFile = URL(fileURLWithPath: remoteDirectory).appendingPathComponent("\(backend.rawValue)-remote.pid")
        remote.surface.sendText("trap '' HUP; (trap '' HUP; exec /bin/sleep 60) & echo $! > "
            + TerminalSession.shellQuote(remoteJobFile.path) + "\n")
        let remoteJob = try observe(remoteJobFile)
        remote.prepareForApplicationQuit(preserve: false)
        pump(0.3)
        try check(remoteJob.isAlive, "closing the local SSH relay preserves the server-owned background group")
        let resumed = try attachRemote()
        try check(remoteJob.isAlive && resumed.remoteStatus?.state == .connected, "remote PTY and its background job remain attachable")
        try RemoteHostClient.terminate(host: host, directory: remoteDirectory, sessionID: remoteID)
        try wait("remote fixture is stopped explicitly") { !remoteJob.isAlive }
        try check(QuickTerminalOffscreen.isSafe(), "all surface fixtures stay offscreen without user focus")
        print("TerminalSessionLifecycle: passed on \(backend.rawValue)")
    }
}
