import AppKit
import Combine
import Darwin
import UserNotifications
@testable import zshell

private struct RemoteWakeEvent: Decodable {
    let event: String
    let kind: String
    let bridgePID: Int32
    let clientID: String?
    let data: String?
}

@MainActor
private final class RemoteSurfaceNotificationDelivery: TerminalNotificationDelivery {
    func configure(delegate: any UNUserNotificationCenterDelegate) {}
    func settings(_ completion: @escaping @Sendable (TerminalNotificationAuthorization) -> Void) {
        completion(.init(status: .denied))
    }
    func authorize(_ completion: @escaping @Sendable (Bool) -> Void) {
        preconditionFailure("The surface fixture must not request notification permission")
    }
    func deliver(_ record: TerminalNotificationRecord) { preconditionFailure("System notifications are disabled") }
    func remove(ids: [UUID]) {}
}

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
        let host = try RemoteHost(name: "Shared SSH fixture", address: CommandLine.arguments[3],
                                  serverPath: CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : "~/.local/bin/zshell-server")
        let directory = CommandLine.arguments[4]
        let wakeFixture = CommandLine.arguments.count > 6 ? URL(fileURLWithPath: CommandLine.arguments[6]) : nil
        let localDirectory = FileManager.default.homeDirectoryForCurrentUser
        TerminalNotificationService.shared = TerminalNotificationService(
            history: TerminalNotificationHistoryStore(url: localDirectory.appendingPathComponent("notifications.json")),
            delivery: RemoteSurfaceNotificationDelivery())
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        var windows: [NSWindow] = []
        var terminals: [TerminalSession] = []
        var remoteIDs: Set<UUID> = []
        var checks = 0
        var completed = false
        var suspendedProcesses: Set<Int32> = []

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

        func control(_ connection: RemoteSessionConnection) throws -> RemoteRelayControl? {
            let url = connection.directoryURL.appendingPathComponent("control.json")
            guard let bytes = try? Data(contentsOf: url) else { return nil }
            return try JSONDecoder().decode(RemoteRelayControl.self, from: bytes)
        }

        func wake() {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        }

        func sshProcess(_ session: TerminalSession) throws -> Int32? {
            guard let relayPID = session.remoteStatus?.relayPID else { return nil }
            let listing = try BoundedProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,ppid=,comm="], timeout: 2, outputLimit: 1024 * 1024)
            return listing.output.stdout.split(separator: "\n").compactMap { line -> Int32? in
                let columns = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard columns.count == 3, Int32(columns[1]) == relayPID,
                      columns[2] == "ssh" || columns[2].hasSuffix("/ssh") else { return nil }
                return Int32(columns[0])
            }.first
        }

        func suspend(_ pid: Int32) throws {
            guard Darwin.kill(pid, SIGSTOP) == 0 else { throw PTYMuxWire.errnoError("SIGSTOP") }
            suspendedProcesses.insert(pid)
        }

        func resume(_ pid: Int32) {
            _ = Darwin.kill(pid, SIGCONT)
            suspendedProcesses.remove(pid)
        }

        func events(_ session: TerminalSession) -> [RemoteWakeEvent] {
            guard let wakeFixture, let client = session.remoteConnection?.clientID.uuidString.lowercased(),
                  let bytes = try? Data(contentsOf: wakeFixture.appendingPathComponent("events.jsonl")) else { return [] }
            return bytes.split(separator: 10).compactMap { try? JSONDecoder().decode(RemoteWakeEvent.self, from: Data($0)) }
                .filter { $0.clientID == client }
        }

        func fault(_ mode: String?, bridgePID: Int32) throws {
            guard let wakeFixture else { return }
            let url = wakeFixture.appendingPathComponent("fault.json")
            if let mode {
                struct Fault: Encodable { let mode: String; let bridgePID: Int32 }
                try RemoteSessionConnection.writePrivate(Fault(mode: mode, bridgePID: bridgePID), to: url)
            } else { try? FileManager.default.removeItem(at: url) }
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
            suspendedProcesses.forEach { _ = Darwin.kill($0, SIGCONT) }
            if let wakeFixture { try? FileManager.default.removeItem(at: wakeFixture.appendingPathComponent("fault.json")) }
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
        var statusWasOffMainThread = false
        let statusObservation = monitoring.$status.sink { _ in
            if !Thread.isMainThread { statusWasOffMainThread = true }
        }
        try RemoteSessionConnection.writePrivate(RemoteRelayStatus(state: .failed, message: "background sample"), to: monitoring.statusURL)
        try waitUntil("background status sample did not publish") { monitoring.status.state == .failed }
        try RemoteSessionConnection.writePrivate(cached, to: monitoring.statusURL)
        try waitUntil("connected status did not restore") { monitoring.status == cached }
        monitoring.takeControl()
        let pendingClaim = try control(monitoring)!
        wake()
        let wokenClaim = try control(monitoring)!
        try check(wokenClaim.action == "claim" && wokenClaim.sequence == pendingClaim.sequence
                  && wokenClaim.wakeSequence == 1, "wake preserves an unconsumed claim command")
        monitoring.markAgentSeen()
        wake()
        let wokenAgentSeen = try control(monitoring)
        try check(wokenAgentSeen?.action == "agentSeen", "wake preserves an unconsumed agentSeen command")
        monitoring.reconnect()
        let pendingReconnect = try control(monitoring)!
        wake()
        let wokenReconnect = try control(monitoring)
        try check(wokenReconnect?.sequence == pendingReconnect.sequence
                  && wokenReconnect?.action == "reconnect", "wake preserves an unconsumed explicit reconnect")
        monitoring.detach()
        let detachedControl = try control(monitoring)!
        wake()
        let afterDetachedWake = try control(monitoring)
        try check(afterDetachedWake?.wakeSequence == detachedControl.wakeSequence
                  && afterDetachedWake?.action == "detach", "detach before status polling suppresses wake")
        monitoring.stopMonitoring()
        wake()
        let afterStoppedWake = try control(monitoring)
        try check(afterStoppedWake?.wakeSequence == detachedControl.wakeSequence,
                  "stopped monitoring removes its wake observer")
        try RemoteSessionConnection.writePrivate(RemoteRelayStatus(state: .failed, message: "stopped"), to: monitoring.statusURL)
        pump(0.55)
        try check(monitoring.status == cached, "stopped monitoring never publishes a later status")
        try check(!statusWasOffMainThread, "status observations stay on the AppKit main thread")
        withExtendedLifetime(statusObservation) {}
        weak var releasedConnection: RemoteSessionConnection?
        var releasedDirectory: URL?
        do {
            let connection = try RemoteSessionConnection(host: host, directory: directory, sessionID: UUID(),
                createIfMissing: false, command: nil, launchSettings: TerminalLaunchSettings())
            releasedConnection = connection
            releasedDirectory = connection.directoryURL
        }
        wake()
        try check(releasedConnection == nil && !FileManager.default.fileExists(atPath: releasedDirectory!.path),
                  "wake observer does not retain a closed connection or private directory")

        let id = UUID()
        let first = try attach(id, create: true)
        try waitUntil("first production relay did not connect") { first.remoteStatus?.state == .connected }
        let original = try info(id)
        try check(original.running && original.pid > 1, "production app relay starts a real host PTY over SSH")
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
        wake()
        try waitUntil("detach was not reflected in the GUI") { first.remoteStatus?.state == .detached }
        first.surface.sendText(": > detached-surface-sentinel\r")
        pump(0.3)
        try waitUntil("remaining client did not regain control") { second.remoteConnection?.isActiveClient == true }
        wake()
        pump(3.4)
        let detachedInfo = try info(id)
        let detachedSSH = try sshProcess(first)
        try check(first.remoteStatus?.state == .detached && detachedSSH == nil && detachedInfo.clientCount == 1
                  && detachedInfo.pid == original.pid, "wake never revives an explicitly detached shared session")
        first.remoteConnection?.reconnect()
        wake()
        try waitUntil("explicit reconnect failed") { first.remoteStatus?.state == .connected }
        let endpoint: SSHEndpoint
        guard case .ssh(let ssh) = try host.endpoint() else { throw NSError(domain: "ExpectedSSH", code: 1) }
        endpoint = ssh
        _ = try OpenSSHTransport().run(endpoint: endpoint, command: ["test", "!", "-e", directory + "/detached-surface-sentinel"])
        try check(true, "input while detached is discarded before reconnect")
        let afterReconnect = try info(id)
        try check(afterReconnect.pid == original.pid && afterReconnect.clientCount == 2,
                  "reconnect keeps the original PID without duplicate attachments")

        guard let healthySSH = try sshProcess(first), let relayPID = first.remoteStatus?.relayPID else {
            throw NSError(domain: "TransportPIDMissing", code: 1)
        }
        let originalSurface = ObjectIdentifier(first.surface)
        let originalLocalPID = first.shellPid
        let statusTransitions = NSMutableArray()
        let transitionObservation = first.remoteConnection!.$status.sink { status in
            statusTransitions.add(status.state.rawValue)
        }
        var transitionsStart = statusTransitions.count
        let beforeWake = events(first).filter { $0.event == "receive" && $0.kind == "ping" }.count
        wake()
        wake()
        pump(0.5)
        first.sendCommand("printf '\\nWAKE_HEALTHY_%s\\n' \"$$\"\r")
        try waitUntil("healthy wake lost remote input") { text(first).contains("WAKE_HEALTHY_\(original.pid)") }
        pump(3.2)
        let healthyAfter = try info(id)
        let sameSSH = try sshProcess(first)
        let healthyStates = (transitionsStart..<statusTransitions.count).compactMap { statusTransitions[$0] as? String }
        try check(sameSSH == healthySSH && healthyAfter.pid == original.pid && healthyAfter.clientCount == 2
                  && healthyAfter.sessionId == id.uuidString.lowercased()
                  && ObjectIdentifier(first.surface) == originalSurface && first.shellPid == originalLocalPID
                  && !healthyStates.contains(where: { $0 == "connecting" || $0 == "failed" }),
                  "healthy wake preserves the SSH process, local surface and remote PTY")
        print("EVIDENCE \(backend) healthy wake: session=\(id.uuidString.lowercased()) remotePID=\(healthyAfter.pid) sshPID=\(sameSSH!) relayPID=\(relayPID)")
        if wakeFixture != nil {
            try check(events(first).filter { $0.event == "receive" && $0.kind == "ping" }.count > beforeWake,
                      "NSWorkspace wake sends a new ping over the existing authenticated SSH")
        }

        try suspend(relayPID)
        wake()
        pump(4)
        transitionsStart = statusTransitions.count
        resume(relayPID)
        pump(3.7)
        let afterScheduledPause = try sshProcess(first)
        let resumedStates = (transitionsStart..<statusTransitions.count).compactMap { statusTransitions[$0] as? String }
        try check(afterScheduledPause == healthySSH && !resumedStates.contains(where: { $0 == "connecting" || $0 == "failed" }),
                  "a relay scheduling pause probes the old SSH before applying heartbeat timeout")

        try suspend(healthySSH)
        let halfOpenStarted = Date()
        wake()
        var lastWake = Date()
        while Date().timeIntervalSince(halfOpenStarted) < 7, (try sshProcess(first)) == healthySSH {
            pump(0.02)
            if Date().timeIntervalSince(lastWake) >= 0.35 { wake(); lastWake = Date() }
        }
        let halfOpenRecovered = try sshProcess(first)
        resume(healthySSH)
        try waitUntil("half-open SSH did not reconnect after wake", timeout: 8) { first.remoteStatus?.state == .connected }
        first.sendCommand("printf '\\nWAKE_HALF_OPEN_%s\\n' \"$$\"\r")
        try waitUntil("recovered half-open connection did not deliver input") { text(first).contains("WAKE_HALF_OPEN_\(original.pid)") }
        let halfOpenInfo = try info(id)
        try check(halfOpenRecovered != healthySSH && Date().timeIntervalSince(halfOpenStarted) < 10
                  && halfOpenInfo.pid == original.pid && halfOpenInfo.running && halfOpenInfo.clientCount == 2
                  && halfOpenInfo.sessionId == id.uuidString.lowercased()
                  && first.remoteStatus?.relayPID == relayPID && ObjectIdentifier(first.surface) == originalSurface,
                  "repeated wakes recover a half-open SSH promptly without replacing the shared PTY")
        let finalHalfOpenSSH = try sshProcess(first)
        print("EVIDENCE \(backend) half-open wake: session=\(id.uuidString.lowercased()) remotePID=\(halfOpenInfo.pid) sshPID=\(healthySSH)->\(finalHalfOpenSSH!) relayPID=\(relayPID) elapsed=\(Date().timeIntervalSince(halfOpenStarted))s")

        if wakeFixture != nil {
            let bridge = events(first).last(where: { $0.event == "receive" && $0.kind == "attach" })!.bridgePID
            try fault("hold", bridgePID: bridge)
            try waitUntil("fixture did not retain a real pre-wake pong", timeout: 7) {
                events(first).contains { $0.bridgePID == bridge && $0.event == "held" && $0.kind == "pong" }
            }
            let staleSSH = try sshProcess(first)
            try fault("release-old", bridgePID: bridge)
            let staleStarted = Date()
            wake()
            try waitUntil("fixture did not release its old pong") {
                events(first).contains { $0.bridgePID == bridge && $0.event == "released" }
            }
            var recoveredFromStale = false
            try waitUntil("a stale pre-wake pong incorrectly kept the unresponsive SSH", timeout: 7) {
                recoveredFromStale = ((try? sshProcess(first)) ?? staleSSH) != staleSSH
                return recoveredFromStale
            }
            try fault(nil, bridgePID: bridge)
            try waitUntil("replacement SSH after stale pong did not attach") { first.remoteStatus?.state == .connected }
            let staleInfo = try info(id)
            try check(recoveredFromStale && Date().timeIntervalSince(staleStarted) < 9 && staleInfo.pid == original.pid
                      && staleInfo.clientCount == 2 && events(first).contains { $0.bridgePID == bridge && $0.event == "dropped" },
                      "a pre-wake pong cannot satisfy the new probe or hide a half-open connection")

            let currentBridge = events(first).last(where: { $0.event == "receive" && $0.kind == "attach" })!.bridgePID
            try suspend(relayPID)
            second.remoteConnection?.takeControl()
            try waitUntil("second fixture client did not take control") { second.remoteConnection?.isActiveClient == true }
            pump(0.3)
            let secondRelayPID = second.remoteStatus!.relayPID!
            try suspend(secondRelayPID)
            let eventStart = events(first).count
            first.sendCommand("printf '\\nWAKE_ORDERED_%s\\n' \"$$\"\r")
            wake()
            resume(relayPID)
            try waitUntil("wake overwrote the pending claim before real input") {
                text(first).contains("WAKE_ORDERED_\(original.pid)")
            }
            let wire = Array(events(first).dropFirst(eventStart)).filter { $0.bridgePID == currentBridge && $0.event == "receive" }
            let claimIndex = wire.firstIndex(where: { $0.kind == "claim" })
            let inputIndex = wire.firstIndex(where: {
                $0.kind == "input" && $0.data.flatMap { Data(base64Encoded: $0) }.map {
                    String(decoding: $0, as: UTF8.self).contains("WAKE_ORDERED")
                } == true
            })
            resume(secondRelayPID)
            try check(claimIndex != nil && inputIndex != nil && claimIndex! < inputIndex!,
                      "pending claim survives wake and precedes input on the production wire")
        }
        withExtendedLifetime(transitionObservation) {}

        guard let sshPID = try sshProcess(first) else { throw NSError(domain: "TransportPIDMissing", code: 1) }
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

        if wakeFixture != nil {
            var rawArguments = try endpoint.transportArguments(connectTimeout: 3,
                command: ["/usr/bin/env", "HOME=\(directory)", "ZDOTDIR=\(directory)", "/bin/sh", "-i"])
            rawArguments[rawArguments.firstIndex(of: "-T")!] = "-tt"
            let raw = TerminalSession(initialDirectory: localDirectory.path,
                                      commandArguments: ["/usr/bin/ssh"] + rawArguments)
            mount(raw)
            raw.sendCommand("printf '\\nRAW_SSH_READY\\n'\r")
            try waitUntil("raw SSH fixture did not launch") {
                raw.shellPid != nil && text(raw).contains("\nRAW_SSH_READY\n")
            }
            let rawPID = raw.shellPid
            let rawSurface = ObjectIdentifier(raw.surface)
            wake()
            pump(3.4)
            raw.sendCommand("printf '\\nRAW_SSH_AFTER_WAKE\\n'\r")
            try waitUntil("wake affected raw SSH terminal input") { text(raw).contains("\nRAW_SSH_AFTER_WAKE\n") }
            try check(raw.remoteConnection == nil && raw.shellPid == rawPID && !raw.hasExited
                      && ObjectIdentifier(raw.surface) == rawSurface, "wake leaves ordinary raw SSH terminals on their existing process")
        }

        first.prepareForApplicationQuit(preserve: false)
        try waitUntil("local relay did not finish on GUI quit") { first.hasExited }
        let quitControl = try control(first.remoteConnection!)
        wake()
        pump(3.4)
        let afterQuitWake = try control(first.remoteConnection!)
        let afterQuit = try info(id)
        try check(afterQuit.pid == original.pid && afterQuit.running, "GUI quit detaches without signaling the remote job")
        try check(afterQuitWake?.sequence == quitControl?.sequence && afterQuitWake?.wakeSequence == quitControl?.wakeSequence
                  && first.hasExited && afterQuit.clientCount == 1, "wake after GUI quit does not relaunch a stopped relay")
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
        let finishedControl = try control(finishedConnection)
        wake()
        pump(3.4)
        let afterExitWake = try control(finishedConnection)
        let exitedInfo = try info(finishedID)
        try check(finished.hasExited && finished.remoteStatus?.exitCode == 7 && !exitedInfo.running
                  && afterExitWake?.wakeSequence == finishedControl?.wakeSequence,
                  "wake never creates a replacement for an exited remote session")
        completed = true
        print("Remote surface \(backend): \(checks) passed, 0 failed")
    }
}
