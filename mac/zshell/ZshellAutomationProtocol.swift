//
//  ZshellAutomationProtocol.swift
//  zshell
//

import Darwin
import Foundation

/// JSON values used by the local automation protocol. Keeping the wire model
/// concrete avoids accepting arbitrary Foundation object graphs at the app
/// boundary and lets both the app and bundled CLI share one Codable contract.
nonisolated enum ZshellJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ZshellJSONValue])
    case array([ZshellJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: ZshellJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([ZshellJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value)
    }

    var arrayValue: [ZshellJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: ZshellJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

struct ZshellAutomationRequest: Codable, Sendable {
    let version: Int
    let id: String
    let method: String
    let token: String
    let terminalID: String
    let params: [String: ZshellJSONValue]
    /// Kernel credential, deliberately excluded from the JSON contract.
    var peerProcessID: pid_t? = nil

    private enum CodingKeys: String, CodingKey {
        case version, id, method, token, terminalID, params
    }
}

struct ZshellAutomationErrorPayload: Codable, Sendable {
    let code: String
    let message: String
}

struct ZshellAutomationResponse: Codable, Sendable {
    let version: Int
    let id: String
    let ok: Bool
    let result: ZshellJSONValue?
    let error: ZshellAutomationErrorPayload?

    static func success(id: String, result: ZshellJSONValue) -> Self {
        Self(version: 1, id: id, ok: true, result: result, error: nil)
    }

    static func failure(id: String, code: String, message: String) -> Self {
        Self(
            version: 1,
            id: id,
            ok: false,
            result: nil,
            error: ZshellAutomationErrorPayload(code: code, message: message)
        )
    }
}

enum ZshellAutomationWireError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

/// A versioned NDJSON request/response channel over a private Unix-domain
/// socket. Requests normally carry one response; events.subscribe upgrades to
/// a bounded nonblocking stream after the same capability check.
final class ZshellAutomationSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (
        ZshellAutomationRequest,
        @escaping @Sendable (ZshellAutomationResponse) -> Void
    ) -> Void

    typealias StreamHandler = @Sendable (ZshellAutomationRequest, ZshellAutomationEventConnection) -> Void

    private static let maximumMessageBytes = 1_048_576

    let path: String
    private let listener: Int32
    private let queue = DispatchQueue(label: "sh.zshell.automation.socket")
    private let workers = DispatchQueue(
        label: "sh.zshell.automation.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let handler: Handler
    private let streamHandler: StreamHandler?
    private let clientsLock = NSLock()
    private var pendingClients = 0
    private var streams: [UUID: ZshellAutomationEventConnection] = [:]
    private var source: DispatchSourceRead?

    init(path: String, streamHandler: StreamHandler? = nil, handler: @escaping Handler) throws {
        self.path = path
        self.handler = handler
        self.streamHandler = streamHandler

        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw ZshellAutomationWireError.message("socket: \(String(cString: strerror(errno)))")
        }
        self.listener = listener

        do {
            try Self.configureSocket(listener)
            var address = try Self.address(for: path)
            unlink(path)
            let result = withUnsafePointer(to: &address.value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, address.length)
                }
            }
            guard result == 0 else {
                throw ZshellAutomationWireError.message(
                    "bind: \(String(cString: strerror(errno)))"
                )
            }
            guard Darwin.chmod(path, 0o600) == 0 else {
                throw ZshellAutomationWireError.message(
                    "chmod: \(String(cString: strerror(errno)))"
                )
            }
            guard Darwin.listen(listener, 16) == 0 else {
                throw ZshellAutomationWireError.message(
                    "listen: \(String(cString: strerror(errno)))"
                )
            }
            let flags = fcntl(listener, F_GETFL, 0)
            guard flags >= 0, fcntl(listener, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw ZshellAutomationWireError.message(
                    "fcntl: \(String(cString: strerror(errno)))"
                )
            }
        } catch {
            Darwin.close(listener)
            unlink(path)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAvailableClients() }
        source.setCancelHandler { Darwin.close(listener) }
        self.source = source
        source.resume()
    }

    deinit {
        source?.cancel()
        streams.values.forEach { $0.close() }
        unlink(path)
    }

    private func acceptAvailableClients() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    NSLog("zshell: automation accept failed: %s", strerror(errno))
                }
                return
            }
            do {
                try Self.configureSocket(client)
                // Darwin can propagate O_NONBLOCK from the listening socket
                // to accepted descriptors. Client workers use a bounded,
                // blocking request read; leaving this set races the writer
                // and can close a healthy connection with EAGAIN.
                let flags = fcntl(client, F_GETFL, 0)
                guard flags >= 0,
                      fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0
                else {
                    throw ZshellAutomationWireError.message(
                        "fcntl: \(String(cString: strerror(errno)))"
                    )
                }
            } catch {
                Darwin.close(client)
                continue
            }
            var peerUser: uid_t = 0
            var peerGroup: gid_t = 0
            guard getpeereid(client, &peerUser, &peerGroup) == 0,
                  peerUser == geteuid() else {
                Darwin.close(client)
                continue
            }
            clientsLock.lock()
            let admitted = pendingClients < 64
            if admitted { pendingClients += 1 }
            clientsLock.unlock()
            guard admitted else { Darwin.close(client); continue }
            let peerProcessID = Self.peerProcessID(client)
            workers.async { [weak self] in
                guard let self else {
                    Darwin.close(client)
                    return
                }
                self.readRequest(from: client, peerProcessID: peerProcessID)
            }
        }
    }

    private func readRequest(from client: Int32, peerProcessID: pid_t?) {
        defer {
            clientsLock.lock()
            pendingClients -= 1
            clientsLock.unlock()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)

        while data.count <= Self.maximumMessageBytes {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                if data.contains(0x0A) { break }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                respond(
                    .failure(
                        id: "unknown", code: "transport_error",
                        message: String(cString: strerror(errno))
                    ),
                    to: client
                )
                return
            }
        }

        guard data.count <= Self.maximumMessageBytes else {
            respond(
                .failure(
                    id: "unknown", code: "request_too_large",
                    message: "Automation requests are limited to 1 MiB."
                ),
                to: client
            )
            return
        }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data[..<newline]
        }

        var request: ZshellAutomationRequest
        do {
            request = try JSONDecoder().decode(ZshellAutomationRequest.self, from: data)
            request.peerProcessID = peerProcessID
        } catch {
            respond(
                .failure(
                    id: "unknown", code: "invalid_request",
                    message: "Invalid automation request: \(error.localizedDescription)"
                ),
                to: client
            )
            return
        }

        if request.method == "events.subscribe", let streamHandler {
            let id = UUID()
            let connection = ZshellAutomationEventConnection(descriptor: client) { [weak self] in
                guard let self else { return }
                self.clientsLock.lock()
                self.streams[id] = nil
                self.clientsLock.unlock()
            }
            clientsLock.lock()
            let admitted = streams.count < ZshellAutomationEventConnection.maximumSubscriptions
            if admitted { streams[id] = connection }
            clientsLock.unlock()
            if admitted { streamHandler(request, connection) }
            else {
                connection.finish(.failure(id: request.id, code: "subscription_limit",
                                           message: "Zshell already has 32 event subscriptions."))
            }
            return
        }

        handler(request) { [weak self] response in
            guard let self else {
                Darwin.close(client)
                return
            }
            self.workers.async { self.respond(response, to: client) }
        }
    }

    private static func peerProcessID(_ descriptor: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              length == MemoryLayout<pid_t>.size, pid > 1 else { return nil }
        return pid
    }

    private func respond(_ response: ZshellAutomationResponse, to client: Int32) {
        defer { Darwin.close(client) }
        guard var data = try? JSONEncoder.zshellAutomation.encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    client,
                    raw.baseAddress!.advanced(by: offset),
                    raw.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    static func exchange(
        path: String,
        request: ZshellAutomationRequest,
        timeout: TimeInterval = 5,
        expectedPeerProcessID: pid_t? = nil
    ) throws -> ZshellAutomationResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ZshellAutomationWireError.message(
                "Could not create the automation socket: \(String(cString: strerror(errno)))."
            )
        }
        defer { Darwin.close(descriptor) }
        try configureSocket(descriptor, timeout: timeout)

        var address = try Self.address(for: path)
        let connected = withUnsafePointer(to: &address.value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, address.length)
            }
        }
        guard connected == 0 else {
            throw ZshellAutomationWireError.message(
                "Could not connect to Zshell automation: \(String(cString: strerror(errno)))."
            )
        }

        if let expectedPeerProcessID {
            var peerUser: uid_t = 0
            var peerGroup: gid_t = 0
            guard getpeereid(descriptor, &peerUser, &peerGroup) == 0,
                  peerUser == geteuid(), Self.peerProcessID(descriptor) == expectedPeerProcessID else {
                throw ZshellAutomationWireError.message("The history control socket has an unexpected owner or process.")
            }
        }

        var encoded = try JSONEncoder.zshellAutomation.encode(request)
        encoded.append(0x0A)
        try encoded.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    descriptor,
                    raw.baseAddress!.advanced(by: offset),
                    raw.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw ZshellAutomationWireError.message(
                        "Could not send the automation request: \(String(cString: strerror(errno)))."
                    )
                }
            }
        }
        Darwin.shutdown(descriptor, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while responseData.count <= maximumMessageBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                responseData.append(buffer, count: count)
                if responseData.contains(0x0A) { break }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw ZshellAutomationWireError.message(
                    "Could not read Zshell's automation response: \(String(cString: strerror(errno)))."
                )
            }
        }
        guard responseData.count <= maximumMessageBytes else {
            throw ZshellAutomationWireError.message("Zshell returned an oversized automation response.")
        }
        if let newline = responseData.firstIndex(of: 0x0A) {
            responseData = responseData[..<newline]
        }
        guard !responseData.isEmpty else {
            throw ZshellAutomationWireError.message("Zshell closed the automation connection without a response.")
        }
        return try JSONDecoder().decode(ZshellAutomationResponse.self, from: responseData)
    }

    fileprivate static func configureSocket(
        _ descriptor: Int32,
        timeout: TimeInterval = 2
    ) throws {
        let flags = fcntl(descriptor, F_GETFD, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw ZshellAutomationWireError.message("fcntl: \(String(cString: strerror(errno)))")
        }
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE,
            &enabled, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw ZshellAutomationWireError.message(
                "setsockopt: \(String(cString: strerror(errno)))"
            )
        }

        let wholeSeconds = floor(timeout)
        var value = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((timeout - wholeSeconds) * 1_000_000)
        )
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO,
            &value, socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw ZshellAutomationWireError.message(
                "setsockopt: \(String(cString: strerror(errno)))"
            )
        }
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO,
            &value, socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw ZshellAutomationWireError.message(
                "setsockopt: \(String(cString: strerror(errno)))"
            )
        }
    }

    fileprivate static func address(
        for path: String
    ) throws -> (value: sockaddr_un, length: socklen_t) {
        let bytes = Array(path.utf8CString)
        var value = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: value.sun_path)
        guard bytes.count <= capacity else {
            throw ZshellAutomationWireError.message(
                "Automation socket path is too long for macOS: \(path)"
            )
        }

        let length = MemoryLayout<sa_family_t>.size + bytes.count
        value.sun_len = UInt8(length)
        value.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &value.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in bytes.indices {
                    destination[index] = bytes[index]
                }
            }
        }
        return (value, socklen_t(length))
    }
}

extension JSONEncoder {
    fileprivate static var zshellAutomation: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// A slow reader owns only a bounded queue. All socket I/O stays off MainActor;
/// enqueue schedules at most one drain even when the peer stops reading.
final class ZshellAutomationEventConnection: @unchecked Sendable {
    static let maximumSubscriptions = 32
    static let maximumQueuedFrames = 256
    static let maximumQueuedBytes = 1_048_576
    static let maximumFrameBytes = 65_536

    private let descriptor: Int32
    private let queue = DispatchQueue(label: "sh.zshell.automation.events")
    private let lock = NSLock()
    private var frames: [Data] = []
    private var queuedBytes = 0
    private var offset = 0
    private var scheduled = false
    private var ending = false
    private var closed = false
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var deadline: DispatchWorkItem?
    private var lagFrame: ZshellJSONValue?
    private let onClose: @Sendable () -> Void

    init(descriptor: Int32, onClose: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor
        self.onClose = onClose
        let flags = fcntl(descriptor, F_GETFL, 0)
        let nonblocking = flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { self.receiveCancellation() }
        source.setCancelHandler { Darwin.close(descriptor) }
        readSource = source
        source.resume()
        if !nonblocking { close() }
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed || ending
    }

    func setLagFrame(_ value: ZshellJSONValue) {
        lock.lock()
        lagFrame = value
        lock.unlock()
    }

    func send(_ value: ZshellJSONValue) {
        enqueue(Self.encode(value), sequence: value.objectValue?["sequence"]?.intValue)
    }
    func reply(_ response: ZshellAutomationResponse) { enqueue(Self.encode(response)) }

    func finish(_ response: ZshellAutomationResponse) {
        enqueue(Self.encode(response), finish: true)
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        guard var data = try? JSONEncoder.zshellAutomation.encode(value) else { return nil }
        data.append(0x0A)
        return data
    }

    private func enqueue(_ data: Data?, finish: Bool = false, sequence: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !ending else { return }
        guard let data else { closeLocked(); return }
        if data.count > Self.maximumFrameBytes || frames.count >= Self.maximumQueuedFrames
            || queuedBytes + data.count > Self.maximumQueuedBytes {
            // Keep a partially written line intact; the terminal control frame
            // explains that everything after it requires a fresh subscription.
            let partial = offset > 0 ? frames.first : nil
            frames = partial.map { [$0] } ?? []
            queuedBytes = partial?.count ?? 0
            if var lag = lagFrame?.objectValue {
                if let sequence { lag["sequence"] = .number(Double(sequence)) }
                lag["time"] = .number(Date().timeIntervalSince1970 * 1_000)
                if let frame = Self.encode(ZshellJSONValue.object(lag)) {
                    frames.append(frame)
                    queuedBytes += frame.count
                }
            }
            ending = true
        } else {
            frames.append(data)
            queuedBytes += data.count
            ending = finish
        }
        if !scheduled {
            scheduled = true
            queue.async { [weak self] in self?.drain() }
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        frames.removeAll()
        queuedBytes = 0
        deadline?.cancel()
        writeSource?.cancel()
        writeSource = nil
        Darwin.shutdown(descriptor, SHUT_RDWR)
        readSource?.cancel()
        readSource = nil
        onClose()
    }

    private func receiveCancellation() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        var byte: UInt8 = 0
        let count = Darwin.read(descriptor, &byte, 1)
        if count >= 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            closeLocked()
        }
    }

    private func drain() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        while let frame = frames.first {
            let written = frame.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if written > 0 {
                deadline?.cancel()
                deadline = nil
                offset += written
                if offset == frame.count {
                    frames.removeFirst()
                    queuedBytes -= frame.count
                    offset = 0
                }
            } else if written < 0, errno == EINTR { continue }
            else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                    source.setEventHandler { [weak self] in self?.drain() }
                    writeSource = source
                    source.resume()
                }
                if deadline == nil {
                    let item = DispatchWorkItem { [weak self] in self?.close() }
                    deadline = item
                    queue.asyncAfter(deadline: .now() + 2, execute: item)
                }
                return
            } else { closeLocked(); return }
        }
        deadline?.cancel()
        deadline = nil
        writeSource?.cancel()
        writeSource = nil
        scheduled = false
        if ending { closeLocked() }
    }
}

extension ZshellAutomationSocketServer {
    /// poll sleeps until a real socket event or the caller's deadline; there
    /// are no repeated RPC requests or idle wakeups during a subscription.
    static func followEvents(
        path: String, request: ZshellAutomationRequest, timeoutMS: Int,
        receive: (ZshellJSONValue) throws -> Bool
    ) throws -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ZshellAutomationWireError.message("Could not create the event socket.") }
        defer { Darwin.close(descriptor) }
        try configureSocket(descriptor, timeout: 5)
        var address = try address(for: path)
        let connected = withUnsafePointer(to: &address.value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, address.length) }
        }
        guard connected == 0 else { throw ZshellAutomationWireError.message("Could not connect to Zshell automation.") }
        var encoded = try JSONEncoder.zshellAutomation.encode(request)
        encoded.append(0x0A)
        try encoded.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { throw ZshellAutomationWireError.message("Could not send the event subscription.") }
            }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = timeoutMS > 0 ? started + UInt64(timeoutMS) * 1_000_000 : UInt64.max
        let handshakeDeadline = min(deadline, started + 5_000_000_000)
        var ready = false
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var streamID: String?
        var sequence = 0
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            let until = ready ? deadline : handshakeDeadline
            if now >= until {
                if ready { return false }
                throw ZshellAutomationWireError.message("Zshell did not acknowledge the event subscription.")
            }
            let wait = until == UInt64.max ? -1 : Int32(min(UInt64(Int32.max), (until - now + 999_999) / 1_000_000))
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, wait)
            if result < 0, errno == EINTR { continue }
            if result == 0 { continue }
            guard result > 0 else { throw ZshellAutomationWireError.message("The event socket failed.") }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw ZshellAutomationWireError.message("The event stream disconnected. Subscribe again to continue.")
            }
            pending.append(buffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                guard pending.distance(from: pending.startIndex, to: newline) <= ZshellAutomationEventConnection.maximumFrameBytes else {
                    throw ZshellAutomationWireError.message("Zshell returned an oversized event frame.")
                }
                let line = Data(pending[..<newline])
                pending = Data(pending[pending.index(after: newline)...])
                let value: ZshellJSONValue
                if !ready {
                    let response = try JSONDecoder().decode(ZshellAutomationResponse.self, from: line)
                    guard response.version == 1, response.id == request.id else {
                        throw ZshellAutomationWireError.message("Zshell returned a mismatched event subscription.")
                    }
                    guard response.ok, let result = response.result else {
                        throw ZshellAutomationWireError.message("\(response.error?.code ?? "automation_error"): \(response.error?.message ?? "Event subscription rejected.")")
                    }
                    value = result
                    streamID = value.objectValue?["stream_id"]?.stringValue
                    guard value.objectValue?["event"]?.stringValue == "stream.ready", streamID != nil else {
                        throw ZshellAutomationWireError.message("Zshell returned an invalid event subscription.")
                    }
                    ready = true
                } else { value = try JSONDecoder().decode(ZshellJSONValue.self, from: line) }
                guard let object = value.objectValue, object["version"]?.intValue == 1,
                      object["stream_id"]?.stringValue == streamID,
                      object["sequence"]?.intValue == sequence
                        || object["event"]?.stringValue == "stream.lagged" && (object["sequence"]?.intValue ?? -1) >= sequence else {
                    throw ZshellAutomationWireError.message("The event stream lost its sequence. Subscribe again to continue.")
                }
                if try receive(value) { return true }
                sequence += 1
            }
            guard pending.count <= ZshellAutomationEventConnection.maximumFrameBytes else {
                throw ZshellAutomationWireError.message("Zshell returned an oversized event frame.")
            }
        }
    }
}
