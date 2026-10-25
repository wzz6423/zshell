import Darwin
import Foundation

private var relayWindowChanged = false

enum PTYMuxRelay {
    static func run() -> Never {
        do {
            guard let text = CommandLine.arguments.dropFirst(2).first,
                  let id = UUID(uuidString: text) else {
                throw PTYMuxError.message("A terminal id is required for the PTY relay.")
            }
            try pump(id: id)
            exit(0)
        } catch {
            fputs("zshell pty relay: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func dimensions(id: UUID) -> [String: ZshellJSONValue] {
        var size = winsize()
        _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)
        let columns = min(max(Int(size.ws_col), 1), 512)
        let rows = min(max(Int(size.ws_row), 1), min(256, 65_536 / columns))
        return [
            "id": .string(id.uuidString),
            "columns": .number(Double(columns)), "rows": .number(Double(rows)),
            "cellWidth": .number(Double(size.ws_xpixel) / Double(columns)),
            "cellHeight": .number(Double(size.ws_ypixel) / Double(rows)),
        ]
    }

    private static func pump(id: UUID) throws {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw PTYMuxWire.errnoError("socket") }
        defer { Darwin.close(socket) }
        try PTYMuxWire.configureSocket(socket)
        var address = try PTYMuxWire.address(for: PTYMuxPaths.socketPath)
        let connected = withUnsafePointer(to: &address.0) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, address.1)
            }
        }
        guard connected == 0 else { throw PTYMuxWire.errnoError("connect") }
        let request = PTYMuxRequest(
            version: PTYMuxConstants.protocolVersion, id: UUID().uuidString,
            method: "attach", params: dimensions(id: id)
        )
        try PTYMuxWire.writeFrame(request, to: socket)
        let response = try PTYMuxWire.readFrame(PTYMuxResponse.self, from: socket)
        guard response.ok, response.id == request.id, response.version == request.version else {
            throw PTYMuxError.message(response.error?.message ?? "Could not attach the PTY relay.")
        }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw PTYMuxWire.errnoError("tcgetattr") }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { throw PTYMuxWire.errnoError("tcsetattr") }
        defer { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        signal(SIGPIPE, SIG_IGN)
        signal(SIGWINCH) { _ in relayWindowChanged = true }
        for descriptor in [socket, STDIN_FILENO, STDOUT_FILENO] {
            let flags = fcntl(descriptor, F_GETFL, 0)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw PTYMuxWire.errnoError("fcntl")
            }
        }
        var output = Data()
        var input = Data()
        var ended = false
        let maximum = PTYMuxConstants.maximumBacklogBytes
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !ended || !output.isEmpty {
            if relayWindowChanged {
                relayWindowChanged = false
                _ = try? PTYMuxCommandLine.exchange(method: "resize", params: dimensions(id: id))
            }
            var descriptors = [
                pollfd(fd: socket, events: Int16((!ended && output.count < maximum ? POLLIN : 0)
                    | (!input.isEmpty ? POLLOUT : 0)), revents: 0),
                pollfd(fd: STDIN_FILENO, events: Int16(!ended && input.count < maximum ? POLLIN : 0), revents: 0),
                pollfd(fd: STDOUT_FILENO, events: Int16(!output.isEmpty ? POLLOUT : 0), revents: 0),
            ]
            let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), 100)
            if ready < 0 { if errno == EINTR { continue }; throw PTYMuxWire.errnoError("poll") }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 && !ended && output.count < maximum {
                let count = Darwin.read(socket, &buffer, buffer.count)
                if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
                else if count == 0 { ended = true }
                else if errno != EINTR && errno != EAGAIN { throw PTYMuxWire.errnoError("read") }
            }
            if descriptors[1].revents & Int16(POLLIN | POLLHUP) != 0 && !ended {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 { input.append(contentsOf: buffer.prefix(count)) }
                else if count == 0 { return }
                else if errno != EINTR && errno != EAGAIN { return }
            }
            if descriptors[0].revents & Int16(POLLOUT) != 0 { try flush(&input, to: socket) }
            if descriptors[2].revents & Int16(POLLOUT) != 0 { try flush(&output, to: STDOUT_FILENO) }
            if descriptors[0].revents & Int16(POLLERR | POLLNVAL) != 0 { ended = true }
            if descriptors[1].revents & Int16(POLLERR | POLLNVAL) != 0
                || descriptors[2].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return }
        }
    }

    private static func flush(_ data: inout Data, to descriptor: Int32) throws {
        guard !data.isEmpty else { return }
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if count > 0 { data.removeFirst(count) }
        else if count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
            throw PTYMuxWire.errnoError("write")
        }
    }
}
