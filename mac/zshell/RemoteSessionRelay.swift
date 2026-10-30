import Darwin
import Foundation

nonisolated(unsafe) private var remoteRelayWindowChanged = false

nonisolated enum RemoteSessionRelay {
    static let argument = "+remote-session-relay"
    static var shouldRun: Bool { CommandLine.arguments.dropFirst().first == argument }

    private struct Controls {
        var sequence: UInt64 = 0
        var paused = false
        var reconnect = false
        var claim = false
        var agentSeen = false
    }

    static func run() -> Never {
        do {
            guard let path = CommandLine.arguments.dropFirst(2).first else {
                throw RemoteHostError.message("A private relay configuration is required.")
            }
            let url = URL(fileURLWithPath: path)
            try validateConfiguration(url)
            signal(SIGPIPE, SIG_IGN)
            signal(SIGWINCH) { _ in remoteRelayWindowChanged = true }
            let result = try run(configurationURL: url)
            exit(result)
        } catch {
            fputs("zshell remote relay: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func validateConfiguration(_ url: URL) throws {
        for (path, type, permissions) in [(url.path, mode_t(S_IFREG), mode_t(0o600)),
                                           (url.deletingLastPathComponent().path, mode_t(S_IFDIR), mode_t(0o700))] {
            var metadata = stat()
            guard lstat(path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == type,
                  metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == permissions else {
                throw RemoteHostError.message("Remote relay configuration must be private and owned by this user.")
            }
        }
    }

    private static func readConfiguration(_ url: URL) throws -> RemoteRelayConfiguration {
        try validateConfiguration(url)
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 256 * 1024 else { throw RemoteHostError.message("Remote relay configuration exceeds 256 KiB.") }
        let configuration = try JSONDecoder().decode(RemoteRelayConfiguration.self, from: bytes)
        _ = try configuration.host.endpoint()
        return configuration
    }

    private static func run(configurationURL: URL) throws -> Int32 {
        let directory = configurationURL.deletingLastPathComponent()
        let statusURL = directory.appendingPathComponent("status.json")
        let controlURL = directory.appendingPathComponent("control.json")
        var status = RemoteRelayStatus(state: .connecting, relayPID: getpid())
        var controls = Controls()
        var shouldCreate = try readConfiguration(configurationURL).createIfMissing
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw PTYMuxWire.errnoError("tcgetattr") }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { throw PTYMuxWire.errnoError("tcsetattr") }
        defer { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO] { try nonblocking(descriptor) }
        var output = Data()
        var failures = 0
        while true {
            readControls(controlURL, into: &controls)
            controls.reconnect = false
            if controls.paused {
                status.state = .detached
                try writeStatus(status, to: statusURL)
                guard try idle(until: Date().addingTimeInterval(0.2), output: &output,
                               controlURL: controlURL, controls: &controls) else { return 0 }
                continue
            }
            status.state = .connecting
            try writeStatus(status, to: statusURL)
            var transport: RemoteHostTransport?
            do {
                let configuration = try readConfiguration(configurationURL)
                let connection = try RemoteHostTransport(host: configuration.host)
                transport = connection
                try connection.handshake()
                if shouldCreate {
                    _ = try connection.exchange(RemoteFrame(
                        kind: "create", project: configuration.project,
                        sessionId: configuration.sessionID.uuidString,
                        command: configuration.command, environment: configuration.environment,
                        initializationCommand: configuration.initializationCommand,
                        shellCompletions: configuration.shellCompletions
                    )).decodedResult(RemoteSessionInfo.self)
                    shouldCreate = false
                }
                let size = dimensions()
                let attached = try connection.exchange(RemoteFrame(
                    kind: "attach", project: configuration.project,
                    sessionId: configuration.sessionID.uuidString,
                    clientId: configuration.clientID.uuidString.lowercased(),
                    columns: size.columns, rows: size.rows
                ))
                status = updatedStatus(status, from: try attached.decodedResult(RemoteSessionInfo.self))
                try writeStatus(status, to: statusURL)
                failures = 0
                try nonblocking(connection.input)
                if connection.input != connection.output { try nonblocking(connection.output) }
                let result = try pump(connection, output: &output, status: &status, statusURL: statusURL,
                                      controlURL: controlURL, controls: &controls)
                connection.close()
                transport = nil
                if let result {
                    try writeStatus(status, to: statusURL)
                    return result
                }
            } catch {
                status.state = controls.paused ? .detached : .failed
                status.message = transport?.diagnostic(fallback: error.localizedDescription) ?? error.localizedDescription
                transport?.close()
                try writeStatus(status, to: statusURL)
                failures = min(failures + 1, 4)
                let delay = controls.reconnect ? 0.0 : min(15.0, pow(2, Double(failures - 1)))
                guard try idle(until: Date().addingTimeInterval(delay), output: &output,
                               controlURL: controlURL, controls: &controls) else { return 0 }
            }
        }
    }

    private static func pump(_ transport: RemoteHostTransport, output: inout Data, status: inout RemoteRelayStatus,
                             statusURL: URL, controlURL: URL, controls: inout Controls) throws -> Int32? {
        var incoming = Data()
        var outgoing = Data()
        var exited: Int32?
        var lastIncoming = Date()
        var lastHeartbeat = Date.distantPast
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while exited == nil || !output.isEmpty {
            readControls(controlURL, into: &controls)
            if controls.paused || controls.reconnect {
                status.state = controls.paused ? .detached : .connecting
                return nil
            }
            if controls.claim {
                try enqueue(RemoteFrame(kind: "claim"), into: &outgoing)
                controls.claim = false
            }
            if controls.agentSeen {
                try enqueue(RemoteFrame(kind: "agentSeen"), into: &outgoing)
                controls.agentSeen = false
            }
            if remoteRelayWindowChanged {
                remoteRelayWindowChanged = false
                let size = dimensions()
                try enqueue(RemoteFrame(kind: "resize", columns: size.columns, rows: size.rows), into: &outgoing)
            }
            if exited == nil, Date().timeIntervalSince(lastHeartbeat) >= 5 {
                try enqueue(RemoteFrame(kind: "ping"), into: &outgoing)
                lastHeartbeat = Date()
            }
            if exited == nil, Date().timeIntervalSince(lastIncoming) > 20 {
                throw RemoteHostError.message(String(localized: "The remote host did not respond in time."))
            }
            var descriptors = [
                pollfd(fd: transport.output, events: Int16(exited == nil && output.count < PTYMuxConstants.maximumSnapshotBytes ? POLLIN : 0), revents: 0),
                pollfd(fd: transport.input, events: Int16(!outgoing.isEmpty ? POLLOUT : 0), revents: 0),
                pollfd(fd: STDIN_FILENO, events: Int16(exited == nil && outgoing.count < PTYMuxConstants.maximumBacklogBytes ? POLLIN : 0), revents: 0),
                pollfd(fd: STDOUT_FILENO, events: Int16(!output.isEmpty ? POLLOUT : 0), revents: 0),
            ]
            let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), 100)
            if ready < 0 { if errno == EINTR { continue }; throw PTYMuxWire.errnoError("poll") }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0, exited == nil {
                let count = Darwin.read(transport.output, &buffer, buffer.count)
                if count > 0 {
                    incoming.append(contentsOf: buffer.prefix(count))
                    lastIncoming = Date()
                    while let frame = try takeFrame(from: &incoming) {
                        if let error = frame.error { throw RemoteHostError.message(error) }
                        if frame.kind == "snapshot" || frame.kind == "output" {
                            guard let text = frame.data, let bytes = Data(base64Encoded: text),
                                  output.count + bytes.count <= PTYMuxConstants.maximumSnapshotBytes + PTYMuxConstants.maximumBacklogBytes else {
                                throw RemoteHostError.message("Remote terminal output exceeds its memory limit.")
                            }
                            output.append(bytes)
                        }
                        if frame.kind == "state" || frame.kind == "pong" {
                            let next = updatedStatus(status, from: try frame.decodedResult(RemoteSessionInfo.self))
                            if next != status { status = next; try writeStatus(status, to: statusURL) }
                        }
                        if frame.kind == "exited" {
                            if frame.result != nil { status = updatedStatus(status, from: try frame.decodedResult(RemoteSessionInfo.self)) }
                            exited = frame.exitCode ?? 1
                            status.state = .exited
                            status.exitCode = exited
                            try writeStatus(status, to: statusURL)
                        }
                    }
                } else if count == 0 { throw RemoteHostError.message(String(localized: "The remote connection closed.")) }
                else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { throw PTYMuxWire.errnoError("read") }
            }
            if descriptors[2].revents & Int16(POLLIN | POLLHUP) != 0, exited == nil {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                guard count != 0 else { status.state = .detached; return 0 }
                if count > 0 {
                    // GUI focus and programmatic sends write this command before
                    // bytes reach the PTY; preserve that order on the wire.
                    readControls(controlURL, into: &controls)
                    if controls.claim { try enqueue(RemoteFrame(kind: "claim"), into: &outgoing); controls.claim = false }
                    if !controls.paused && !controls.reconnect {
                        try enqueue(RemoteFrame(kind: "input", data: Data(buffer.prefix(count)).base64EncodedString()), into: &outgoing)
                    }
                } else if errno != EINTR && errno != EAGAIN { status.state = .detached; return 0 }
            }
            if descriptors[1].revents & Int16(POLLOUT) != 0 { try flush(&outgoing, to: transport.input) }
            if descriptors[3].revents & Int16(POLLOUT) != 0 { try flush(&output, to: STDOUT_FILENO) }
            if descriptors[0].revents & Int16(POLLERR | POLLNVAL) != 0
                || descriptors[1].revents & Int16(POLLERR | POLLNVAL) != 0 {
                throw RemoteHostError.message(String(localized: "The remote connection closed."))
            }
            if descriptors[2].revents & Int16(POLLERR | POLLNVAL) != 0
                || descriptors[3].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { status.state = .detached; return 0 }
        }
        return exited
    }

    private static func idle(until deadline: Date, output: inout Data, controlURL: URL, controls: inout Controls) throws -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        repeat {
            readControls(controlURL, into: &controls)
            if controls.reconnect { return true }
            var descriptors = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: STDOUT_FILENO, events: Int16(!output.isEmpty ? POLLOUT : 0), revents: 0)]
            let ready = Darwin.poll(&descriptors, 2, 100)
            if ready < 0, errno != EINTR { throw PTYMuxWire.errnoError("poll") }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count == 0 { return false }
                // Disconnected input is discarded instead of executing later
                // against a prompt the user has not seen.
                if count < 0, errno != EINTR && errno != EAGAIN { return false }
            }
            if descriptors[1].revents & Int16(POLLOUT) != 0 { try flush(&output, to: STDOUT_FILENO) }
            if descriptors[0].revents & Int16(POLLERR | POLLNVAL) != 0
                || descriptors[1].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return false }
        } while Date() < deadline
        return true
    }

    private static func readControls(_ url: URL, into controls: inout Controls) {
        guard let bytes = try? Data(contentsOf: url), bytes.count < 8192,
              let command = try? JSONDecoder().decode(RemoteRelayControl.self, from: bytes), command.sequence > controls.sequence else { return }
        controls.sequence = command.sequence
        switch command.action {
        case "detach": controls.paused = true
        case "reconnect": controls.paused = false; controls.reconnect = true
        case "claim": controls.claim = true
        case "agentSeen": controls.agentSeen = true
        default: break
        }
    }

    private static func updatedStatus(_ previous: RemoteRelayStatus, from info: RemoteSessionInfo) -> RemoteRelayStatus {
        RemoteRelayStatus(state: info.running ? .connected : .exited, relayPID: previous.relayPID,
                          remotePID: info.pid, exitCode: info.exitCode,
                          clients: info.clientCount, activeClientID: info.activeClientId,
                          agentStatus: info.agentStatus, conversation: info.conversation,
                          sessionCommand: info.command, profileContext: info.profileContext)
    }

    private static func writeStatus(_ status: RemoteRelayStatus, to url: URL) throws {
        try RemoteSessionConnection.writePrivate(status, to: url)
    }

    private static func dimensions() -> (columns: Int, rows: Int) {
        var size = winsize()
        _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)
        let columns = min(max(Int(size.ws_col), 1), 512)
        return (columns, min(max(Int(size.ws_row), 1), min(256, 65_536 / columns)))
    }

    private static func nonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw PTYMuxWire.errnoError("fcntl") }
    }

    private static func enqueue(_ frame: RemoteFrame, into data: inout Data) throws {
        let bytes = try JSONEncoder().encode(frame)
        guard bytes.count <= PTYMuxConstants.maximumFrameBytes,
              data.count + bytes.count + 4 <= PTYMuxConstants.maximumBacklogBytes else {
            throw RemoteHostError.message("Remote terminal input exceeds its memory limit.")
        }
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }

    static func takeFrame(from data: inout Data) throws -> RemoteFrame? {
        guard data.count >= 4 else { return nil }
        let count = data.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard count > 0, count <= PTYMuxConstants.maximumFrameBytes else { throw RemoteHostError.message("Remote frame exceeds 256 KiB.") }
        guard data.count >= 4 + count else { return nil }
        let frame = try JSONDecoder().decode(RemoteFrame.self, from: Data(data.dropFirst(4).prefix(count)))
        guard frame.version == 1 else { throw RemoteHostError.message(String(localized: "The remote server uses an incompatible protocol.")) }
        data.removeFirst(4 + count)
        return frame
    }

    private static func flush(_ data: inout Data, to descriptor: Int32) throws {
        guard !data.isEmpty else { return }
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if count > 0 { data.removeFirst(count) }
        else if count < 0, errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { throw PTYMuxWire.errnoError("write") }
    }
}
