import AppKit
import Darwin
@testable import zshell

@MainActor
private final class RemoteTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private func pump(_ duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

@MainActor
private func waitUntil(_ label: String, timeout: TimeInterval = 12, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        pump(0.02)
    }
    throw NSError(domain: "RemoteSurfaceTest", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
}

@main
struct RemoteSessionSurfaceTests {
    @MainActor static func main() {
        if RemoteSessionRelay.shouldRun { RemoteSessionRelay.run() }
        do { try run() }
        catch { fputs("Remote surface failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let backend = CommandLine.arguments[1]
        let executable = CommandLine.arguments[2]
        let host = try RemoteHost(name: "Linux shared fixture", address: CommandLine.arguments[3])
        let directory = CommandLine.arguments[4]
        let localDirectory = FileManager.default.homeDirectoryForCurrentUser
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        var windows: [NSWindow] = []
        var terminals: [TerminalSession] = []
        var remoteIDs: Set<UUID> = []
        var checks = 0
        var completed = false

        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else {
                throw NSError(domain: "RemoteSurfaceTest", code: 2, userInfo: [NSLocalizedDescriptionKey: label])
            }
            checks += 1
            print("PASS \(backend): \(label)")
        }

        func attach(_ id: UUID, create: Bool) throws -> TerminalSession {
            let connection = try RemoteSessionConnection(host: host, directory: directory, sessionID: id,
                                                         createIfMissing: create, command: ["/bin/sh", "-i"],
                                                         launchSettings: TerminalLaunchSettings())
            let session = TerminalSession(initialDirectory: localDirectory.path,
                commandArguments: [executable, RemoteSessionRelay.argument, connection.configurationURL.path],
                remoteConnection: connection)
            mount(session)
            remoteIDs.insert(id)
            return session
        }

        func mount(_ session: TerminalSession) {
            let surface = session.surface
            surface.frame = NSRect(x: 0, y: 0, width: 760, height: 440)
            let window = RemoteTestWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = surface
            surface.onBecomeFirstResponder = { [weak session] in session?.terminalDidBecomeFocused() }
            window.makeFirstResponder(surface)
            surface.setSurfaceVisible(true)
            windows.append(window)
            terminals.append(session)
        }

        func text(_ session: TerminalSession) -> String {
            session.surface.readVisibleText(maxLines: 256, maxColumns: 1000) ?? ""
        }

        func info(_ id: UUID) throws -> RemoteSessionInfo {
            guard let found = try RemoteHostClient.catalog(host: host).flatMap(\.sessions)
                .first(where: { $0.sessionId == id.uuidString.lowercased() }) else {
                throw NSError(domain: "RemoteSessionMissing", code: 1)
            }
            return found
        }

        let frames = [RemoteFrame(kind: "snapshot", data: "5YWx5Lqr"), RemoteFrame(kind: "state"), RemoteFrame(kind: "output", data: "c2hhcmVk")]
        var framed = Data()
        for frame in frames {
            let payload = try JSONEncoder().encode(frame)
            var length = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
            framed.append(payload)
        }
        var partial = Data(framed.prefix(6))
        let incomplete = try RemoteSessionRelay.takeFrame(from: &partial)
        try check(incomplete == nil,
                  "a fragmented protocol frame waits for its remaining bytes")
        partial.append(framed.dropFirst(6))
        for expected in frames {
            let frame = try RemoteSessionRelay.takeFrame(from: &partial)
            try check(frame?.kind == expected.kind && frame?.data == expected.data,
                      "successive frames decode after Data indices advance")
        }
        try check(partial.isEmpty, "protocol decoding consumes every complete frame")

        defer {
            if !completed {
                for session in terminals {
                    print("DIAGNOSTIC \(backend) status=\(String(describing: session.remoteStatus)) text=\(text(session).debugDescription)")
                }
            }
            terminals.forEach { $0.terminate() }
            pump(0.3)
            windows.forEach { $0.contentView = nil }
            for id in remoteIDs { try? RemoteHostClient.terminate(host: host, directory: directory, sessionID: id) }
        }

        let monitoring = try RemoteSessionConnection(host: host, directory: directory, sessionID: UUID(),
            createIfMissing: false, command: nil, launchSettings: TerminalLaunchSettings())
        let cached = RemoteRelayStatus(state: .connected, remotePID: 123, clients: 2)
        let encoded = try JSONEncoder().encode(cached)
        var bounded = encoded
        bounded.append(Data(repeating: 32, count: 64 * 1024 - bounded.count))
        try bounded.write(to: monitoring.statusURL, options: .atomic)
        try check(RemoteSessionConnection.readStatus(from: monitoring.statusURL) == cached,
                  "a valid status at the 64 KiB boundary is accepted")
        bounded.append(32)
        try bounded.write(to: monitoring.statusURL, options: .atomic)
        try check(RemoteSessionConnection.readStatus(from: monitoring.statusURL) == nil,
                  "an oversized status is rejected before decoding")
        let target = monitoring.directoryURL.appendingPathComponent("target.json")
        try encoded.write(to: target)
        try FileManager.default.removeItem(at: monitoring.statusURL)
        try FileManager.default.createSymbolicLink(at: monitoring.statusURL, withDestinationURL: target)
        try check(RemoteSessionConnection.readStatus(from: monitoring.statusURL) == nil,
                  "status reads do not follow symlinks")
        try FileManager.default.removeItem(at: monitoring.statusURL)
        guard mkfifo(monitoring.statusURL.path, 0o600) == 0 else { throw PTYMuxWire.errnoError("mkfifo") }
        let fifoStart = Date()
        try check(RemoteSessionConnection.readStatus(from: monitoring.statusURL) == nil && Date().timeIntervalSince(fifoStart) < 0.2,
                  "a non-regular status path cannot block polling")
        try FileManager.default.removeItem(at: monitoring.statusURL)
        try RemoteSessionConnection.writePrivate(cached, to: monitoring.statusURL)
        try waitUntil("background status polling did not publish") { monitoring.status == cached }
        monitoring.stopMonitoring()
        try RemoteSessionConnection.writePrivate(RemoteRelayStatus(state: .failed, message: "stopped"), to: monitoring.statusURL)
        pump(0.55)
        try check(monitoring.status == cached, "stopped monitoring never publishes a later status")

        let id = UUID()
        let first = try attach(id, create: true)
        try waitUntil("first production relay did not connect") { first.remoteStatus?.state == .connected }
        let original = try info(id)
        try check(original.running && original.pid > 1, "production app relay starts a real Linux PTY over SSH")
        try check(first.id != id && first.remoteConnection?.sessionID == id, "local and remote terminal identities are separate")
        try check(first.currentDirectoryPath == directory && first.foregroundDirectoryPath == nil,
                  "local relay process metadata never replaces the remote directory")
        let permissions = try FileManager.default.attributesOfItem(atPath: first.remoteConnection!.directoryURL.path)[.posixPermissions] as? NSNumber
        let filePermissions = try FileManager.default.attributesOfItem(atPath: first.remoteConnection!.configurationURL.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o700 && filePermissions?.intValue == 0o600, "relay configuration is private")
        first.sendCommand("printf '\\nSURFACE_SHARED_MARK\\n'\r")
        try waitUntil("remote output did not reach the first renderer") { text(first).contains("SURFACE_SHARED_MARK") }
        try check(true, "remote output renders on the real terminal surface")

        let second = try attach(id, create: false)
        try waitUntil("second production relay did not connect") { second.remoteStatus?.state == .connected }
        try waitUntil("history did not reach the second renderer") { text(second).contains("SURFACE_SHARED_MARK") }
        try check(first.id != second.id && second.remoteConnection?.sessionID == id, "two local terminals attach the same remote session")
        try waitUntil("client count did not reach both GUI status models") {
            first.remoteStatus?.clients == 2 && second.remoteStatus?.clients == 2
        }
        try check(true, "both GUI models show the actual client count")
        second.sendCommand("printf '\\nDUAL_OUTPUT_MARK\\n'\r")
        try waitUntil("shared output did not reach both surfaces") {
            text(first).contains("DUAL_OUTPUT_MARK") && text(second).contains("DUAL_OUTPUT_MARK")
        }
        try waitUntil("programmatic sends did not claim control before input") { second.remoteConnection?.isActiveClient == true }
        try check(true, "programmatic input claims control and both renderers receive output")

        let previous = try info(id)
        windows[0].setContentSize(NSSize(width: 540, height: 340))
        pump(0.3)
        let readOnlyResize = try info(id)
        try check(readOnlyResize.columns == previous.columns && readOnlyResize.rows == previous.rows,
                  "an inactive client's resize does not resize the remote PTY")
        windows[0].makeFirstResponder(nil)
        windows[0].makeFirstResponder(first.surface)
        try waitUntil("focusing did not take terminal control") { first.remoteConnection?.isActiveClient == true }
        let focused = try info(id)
        try check(focused.columns != previous.columns || focused.rows != previous.rows,
                  "focus applies the new controller's dimensions")

        first.remoteConnection?.detach()
        try waitUntil("detach was not reflected in the GUI") { first.remoteStatus?.state == .detached }
        first.surface.sendText(": > detached-surface-sentinel\r")
        pump(0.3)
        try waitUntil("remaining client did not regain control") { second.remoteConnection?.isActiveClient == true }
        first.remoteConnection?.reconnect()
        try waitUntil("explicit reconnect failed") { first.remoteStatus?.state == .connected }
        let endpoint: SSHEndpoint
        guard case .ssh(let ssh) = try host.endpoint() else { throw NSError(domain: "ExpectedSSH", code: 1) }
        endpoint = ssh
        _ = try OpenSSHTransport().run(endpoint: endpoint, command: ["test", "!", "-e", directory + "/detached-surface-sentinel"])
        try check(true, "input while detached is discarded before reconnect")
        let afterReconnect = try info(id)
        try check(afterReconnect.pid == original.pid && afterReconnect.clientCount == 2,
                  "reconnect keeps the original PID without duplicate attachments")

        let relayPID = first.remoteStatus!.relayPID!
        let listing = try BoundedProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/ps"),
                                                  arguments: ["-axo", "pid=,ppid=,comm="], timeout: 2, outputLimit: 1024 * 1024)
        let sshPID = listing.output.stdout.split(separator: "\n").compactMap { line -> Int32? in
            let columns = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard columns.count == 3, Int32(columns[1]) == relayPID,
                  columns[2] == "ssh" || columns[2].hasSuffix("/ssh") else { return nil }
            return Int32(columns[0])
        }.first
        guard let sshPID else { throw NSError(domain: "TransportPIDMissing", code: 1) }
        _ = Darwin.kill(sshPID, SIGKILL)
        try waitUntil("transport loss was not shown") { first.remoteStatus?.state == .failed || first.remoteStatus?.state == .connecting }
        try waitUntil("production relay did not automatically reconnect") { first.remoteStatus?.state == .connected }
        let recovered = try info(id)
        try check(recovered.pid == original.pid && recovered.running && recovered.clientCount == 2,
                  "unexpected SSH loss automatically reconnects the same remote PTY")

        let listingResult = try OpenSSHTransport().listDirectory(endpoint: endpoint, directory: directory)
        try check(!listingResult.contains(where: { $0.name == "detached-surface-sentinel" }), "remote Files operations use the same isolated SSH configuration")
        let local = TerminalSession(initialDirectory: localDirectory.path, commandArguments: ["/bin/sh", "-i"],
                                    additionalEnvironment: ["HISTFILE": "/dev/null"])
        mount(local)
        local.sendCommand("printf '\\nLOCAL_COEXIST_MARK\\n'\r")
        try waitUntil("local terminal stopped working") { text(local).contains("LOCAL_COEXIST_MARK") }
        try check(local.remoteConnection == nil && recovered.running, "local and shared remote terminals coexist")

        first.prepareForApplicationQuit(preserve: false)
        try waitUntil("local relay did not finish on GUI quit") { first.hasExited }
        let afterQuit = try info(id)
        try check(afterQuit.pid == original.pid && afterQuit.running, "GUI quit detaches without signaling the remote job")
        let reopened = try attach(id, create: false)
        try waitUntil("saved remote session did not reconnect") { reopened.remoteStatus?.state == .connected }
        try waitUntil("reopened surface did not recover history") { text(reopened).contains("DUAL_OUTPUT_MARK") }
        try check(true, "a fresh local terminal reconnects the saved remote UUID and restores history")

        let finishedID = UUID()
        let finishedConnection = try RemoteSessionConnection(host: host, directory: directory, sessionID: finishedID,
            createIfMissing: true, command: ["/bin/sh", "-c", "printf 'REMOTE_FINAL_OUTPUT\\n'; exit 7"], launchSettings: TerminalLaunchSettings())
        let finished = TerminalSession(initialDirectory: localDirectory.path,
            commandArguments: [executable, RemoteSessionRelay.argument, finishedConnection.configurationURL.path], remoteConnection: finishedConnection)
        mount(finished)
        remoteIDs.insert(finishedID)
        try waitUntil("remote exit did not reach the GUI") { finished.hasExited && finished.remoteStatus?.exitCode == 7 }
        try check(text(finished).contains("REMOTE_FINAL_OUTPUT"), "a remote exit keeps the final rendered screen and exit status")
        try check(!text(finished).contains("Ghostty failed to launch"),
                  "a nonzero remote exit does not become a local renderer launch error")
        completed = true
        print("Remote surface \(backend): \(checks) passed, 0 failed")
    }
}
