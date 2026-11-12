import AppKit
import Darwin
@testable import zshell

private struct IdentityFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct TerminalIdentityTests {
    @MainActor static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        if RemoteSessionRelay.shouldRun { RemoteSessionRelay.run() }
        QuickTerminalOffscreen.install()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated {
                do { try run(); exit(0) }
                catch { fputs("FAIL \(error)\n", stderr); exit(1) }
            }
        }
        app.run()
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        let backend = TerminalBackend(rawValue: CommandLine.arguments[1])!
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let settings = AppSettings.shared
        settings.terminalBackend = backend
        settings.preserveTerminalSessions = false
        settings.terminalStartupProgram = ""
        settings.terminalStartupArguments = ""
        settings.automaticallyApplyTerminalProfiles = false
        var sessions: [TerminalSession] = []
        var windows: [NSWindow] = []
        var checks = 0

        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw IdentityFailure(description: label) }
            checks += 1
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
                guard Date() < deadline else { throw IdentityFailure(description: "Timed out: \(label)") }
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
            pump(0.3)
        }

        func makeSession(environment: [String: String] = [:], restoredID: UUID? = nil) -> TerminalSession {
            let session = TerminalSession(
                initialDirectory: root.path, commandArguments: ["/bin/sh", "-i"],
                restoredSessionID: restoredID,
                launchSettings: .init(environmentVariables: [
                    .init(name: "TERM", value: "untrusted-project"),
                    .init(name: "TERM_PROGRAM", value: "untrusted-program"),
                ]), additionalEnvironment: environment,
                isRestoredSession: restoredID != nil, usesConfiguredStartupCommand: false
            )
            mount(session)
            return session
        }

        func readIdentity(_ session: TerminalSession, _ name: String) throws -> [String] {
            let file = root.appendingPathComponent(name)
            session.surface.sendText("printf '%s\\n' \"$TERM\" \"$TERM_PROGRAM\" \"$ZSHELL_TERM\" \"$$\" > \(TerminalSession.shellQuote(file.path))\n")
            try wait("shell publishes \(name)") {
                ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count == 4
            }
            return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        }

        defer {
            sessions.forEach { $0.terminate() }
            pump(0.8)
            windows.forEach { $0.close() }
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        }

        if CommandLine.arguments.contains("--settings-only") {
            checks += try verifySettingsPane()
            try check(QuickTerminalOffscreen.isSafe(), "settings fixture stays offscreen and does not claim user focus")
            print("TerminalIdentity: \(checks) settings checks passed")
            return
        }

        try check(settings.terminalTerm == "xterm-256color", "missing config preserves the default")
        let original = makeSession()
        let originalIdentity = try readIdentity(original, "default")
        try check(originalIdentity[0] == "xterm-256color" && originalIdentity[1] == "ghostty"
                  && originalIdentity[2] == backend.environmentName, "real PTY reports default TERM and capability/backend identities")

        settings.setTerminalTerm("screen-256color")
        original.surface.applyAppearance()
        let unchanged = try readIdentity(original, "unchanged")
        try check(unchanged == originalIdentity, "settings and appearance updates keep the open PTY's TERM and PID")
        let configured = makeSession()
        try check(try readIdentity(configured, "configured")[0] == "screen-256color", "new real PTY uses the configured TERM")
        let overridden = makeSession(environment: ["TERM": "vt100"])
        try check(try readIdentity(overridden, "override")[0] == "vt100", "valid per-launch TERM keeps its existing precedence")
        let invalidOverride = makeSession(environment: ["TERM": "xterm\nother"])
        try check(try readIdentity(invalidOverride, "invalid-override")[0] == "screen-256color", "invalid per-launch TERM cannot reach the child")

        settings.preserveTerminalSessions = true
        let preserved = makeSession()
        let beforeDetach = try readIdentity(preserved, "persistent")
        let preservedID = preserved.id
        try check(preserved.persistentSessionID == preservedID, "identity probe owns a real persistent PTY")
        preserved.prepareForApplicationQuit(preserve: true)
        pump(0.3)
        settings.setTerminalTerm("xterm")
        settings.terminalBackend = backend == .libghostty ? .alacritty : .libghostty
        let reattached = makeSession(restoredID: preservedID)
        let afterDetach = try readIdentity(reattached, "reattached")
        try check(reattached.reconnectedToPersistentPTY && afterDetach == beforeDetach,
                  "reattach with a different renderer preserves the real PTY's TERM, TERM_PROGRAM, backend identity and PID")
        settings.terminalBackend = backend
        settings.preserveTerminalSessions = false

        let remoteAddress = ProcessInfo.processInfo.environment["ZSHELL_TERM_TEST_REMOTE_ADDRESS"]
        let remoteDirectory = ProcessInfo.processInfo.environment["ZSHELL_TERM_TEST_REMOTE_DIRECTORY"] ?? root.path
        let remoteServer = ProcessInfo.processInfo.environment["ZSHELL_TERM_TEST_REMOTE_SERVER"] ?? "~/.local/bin/zshell-server"
        let host = try RemoteHost(name: "identity fixture", address: remoteAddress ?? "ssh://fixture.invalid", serverPath: remoteServer)
        let connection = try RemoteSessionConnection(host: host, directory: root.path, sessionID: UUID(),
                                                     createIfMissing: true, command: ["/bin/sh", "-i"], launchSettings: .init())
        let request = try JSONDecoder().decode(RemoteRelayConfiguration.self,
                                               from: Data(contentsOf: connection.configurationURL))
        try check(request.environment == ["TERM": "xterm"], "remote relay captures TERM without overriding server capability variables")
        connection.stopMonitoring()

        if remoteAddress != nil {
            var remoteIDs: [UUID] = []
            defer {
                for id in remoteIDs { try? RemoteHostClient.terminate(host: host, directory: remoteDirectory, sessionID: id) }
            }
            func attachRemote(_ id: UUID, create: Bool) throws -> TerminalSession {
                let remote = try RemoteSessionConnection(host: host, directory: remoteDirectory, sessionID: id,
                    createIfMissing: create, command: ["/bin/sh", "-i"], launchSettings: .init())
                let session = TerminalSession(initialDirectory: root.path, commandArguments: remote.launchArguments,
                                               remoteConnection: remote)
                mount(session)
                try wait("shared SSH connection") { session.remoteStatus?.state == .connected }
                return session
            }

            func remoteIdentity(_ session: TerminalSession, name: String) throws -> [String] {
                let file = URL(fileURLWithPath: remoteDirectory).appendingPathComponent(name)
                session.surface.sendText("printf '%s\\n' \"$TERM\" \"$TERM_PROGRAM\" \"$COLORTERM\" \"$$\" > \(TerminalSession.shellQuote(file.path))\n")
                try wait("shared SSH publishes \(name)") {
                    ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count == 4
                }
                return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
            }

            settings.setTerminalTerm("xterm-256color")
            let defaultID = UUID()
            remoteIDs.append(defaultID)
            let remoteDefault = try attachRemote(defaultID, create: true)
            let defaultIdentity = try remoteIdentity(remoteDefault, name: "\(backend.rawValue)-remote-default")
            try check(Array(defaultIdentity.prefix(3)) == ["xterm-256color", "ghostty", "truecolor"],
                      "real shared SSH PTY reports the default TERM and protected capability values")
            settings.setTerminalTerm("screen-256color")
            remoteDefault.surface.applyAppearance()
            let remoteUnchanged = try remoteIdentity(remoteDefault, name: "\(backend.rawValue)-remote-unchanged")
            try check(remoteUnchanged == defaultIdentity, "open shared SSH PTY keeps TERM and PID after settings change")
            let configuredID = UUID()
            remoteIDs.append(configuredID)
            let remoteConfigured = try attachRemote(configuredID, create: true)
            let configuredIdentity = try remoteIdentity(remoteConfigured, name: "\(backend.rawValue)-remote-configured")
            try check(Array(configuredIdentity.prefix(3)) == ["screen-256color", "ghostty", "truecolor"],
                      "new shared SSH PTY receives the configured terminal type")
            remoteConfigured.prepareForApplicationQuit(preserve: false)
            pump(0.3)
            settings.setTerminalTerm("vt100")
            let remoteReattached = try attachRemote(configuredID, create: true)
            let remoteRestored = try remoteIdentity(remoteReattached, name: "\(backend.rawValue)-remote-reattached")
            try check(remoteRestored == configuredIdentity, "shared SSH create replay preserves the existing PTY's TERM and PID")

            let transport = try RemoteHostTransport(host: host)
            defer { transport.close() }
            try transport.handshake()
            for invalid in ["", "xterm\nother", "bad term", "bad/term", "x" + String(repeating: "y", count: 128)] {
                var rejected = false
                do {
                    _ = try transport.exchange(RemoteFrame(kind: "create", project: remoteDirectory,
                        sessionId: UUID().uuidString, command: ["/bin/sh", "-i"], environment: ["TERM": invalid]))
                } catch { rejected = error.localizedDescription.contains("Invalid terminal type") }
                try check(rejected, "SSH server rejects invalid TERM before spawning the PTY")
            }

            let endpoint = try SSHEndpoint(host: "127.0.0.1", user: ProcessInfo.processInfo.environment["ZSHELL_TERM_TEST_SSH_USER"],
                                          port: Int(ProcessInfo.processInfo.environment["ZSHELL_TERM_TEST_SSH_PORT"] ?? ""))
            let sshArguments = try endpoint.terminalArguments(remoteDirectory: nil)
            let directFile = URL(fileURLWithPath: remoteDirectory).appendingPathComponent("\(backend.rawValue)-plain-ssh")
            let command = "printf '%s\\n' \"$TERM\" > \(TerminalSession.shellQuote(directFile.path))"
            let direct = TerminalSession(initialDirectory: root.path, commandArguments: ["/usr/bin/ssh"] + sshArguments + [command],
                                         allowsPersistence: false, resolvesSSHAgent: true)
            mount(direct)
            try wait("OpenSSH PTY request publishes TERM") { FileManager.default.fileExists(atPath: directFile.path) }
            let requestedTerm = try String(contentsOf: directFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try check(requestedTerm == "vt100", "plain OpenSSH PTY request carries the configured TERM without SendEnv")
        }

        checks += try verifySettingsPane()
        try check(QuickTerminalOffscreen.isSafe(), "integration fixture stays offscreen and does not claim user focus")
        print("TerminalIdentity: \(checks) passed on \(backend.rawValue)")
    }

    @MainActor private static func verifySettingsPane() throws -> Int {
        let settings = AppSettings.shared
        settings.applyImported([:])
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw IdentityFailure(description: label) }
            checks += 1
            print("PASS settings: \(label)")
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func hasTermControl(_ view: NSView) -> Bool {
            descendants(view).contains {
                $0.accessibilityLabel() == "TERM" || ($0 as? NSTextField)?.stringValue == "TERM"
            }
        }

        try check(settings.terminalTerm == "xterm-256color" && !settings.terminalTermIsInvalid,
                  "missing advanced configuration preserves the default terminal type")
        let pane = SettingsTerminalPane()
        pane.setCategory(.terminal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        defer { window.close() }
        try check(!hasTermControl(pane.view), "native terminal settings have no TERM row or editor")

        settings.applyImported(TOML.parseStrictly(text: "terminal.term = \"screen-256color\"").values)
        pane.syncFromSettings()
        try check(settings.terminalTerm == "screen-256color" && !settings.terminalTermIsInvalid,
                  "advanced terminal.term configuration still loads")
        let stored = settings.serializedConfig()
        try check(TOML.parseStrictly(text: stored).values["terminal.term"]?.string == "screen-256color",
                  "advanced terminal.term configuration still serializes")
        try check(!hasTermControl(pane.view), "advanced terminal type does not add a settings editor")

        settings.applyImported(["terminal.term": .string("xterm\nother")])
        pane.syncFromSettings()
        try check(settings.terminalTerm == "screen-256color" && settings.terminalTermIsInvalid,
                  "invalid advanced terminal type preserves the previous value")
        settings.applyImported(TOML.parseStrictly(text: stored).values)
        pane.syncFromSettings()
        try check(settings.terminalTerm == "screen-256color" && !settings.terminalTermIsInvalid,
                  "valid advanced configuration clears the terminal type error")
        settings.applyImported([:])
        pane.syncFromSettings()
        try check(settings.terminalTerm == "xterm-256color" && !settings.serializedConfig().contains("terminal.term")
                  && !hasTermControl(pane.view), "default terminal type stays internal after configuration reload")
        return checks
    }
}
