//
//  ZshellAutomationProtocol.swift
//  zshell
//

import Darwin
import Foundation

/// JSON values used by the local automation protocol. Keeping the wire model
/// concrete avoids accepting arbitrary Foundation object graphs at the app
/// boundary and lets both the app and bundled CLI share one Codable contract.
enum ZshellJSONValue: Codable, Equatable, Sendable {
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
        guard case .number(let value) = self,
              value.rounded() == value,
              value >= Double(Int.min), value <= Double(Int.max)
        else { return nil }
        return Int(value)
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
/// socket. Each connection carries one request and one response. That keeps
/// failure recovery simple for short-lived CLI processes and bounds memory
/// before any request reaches Zshell's main actor.
final class ZshellAutomationSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (
        ZshellAutomationRequest,
        @escaping @Sendable (ZshellAutomationResponse) -> Void
    ) -> Void

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
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping Handler) throws {
        self.path = path
        self.handler = handler

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
            workers.async { [weak self] in
                guard let self else {
                    Darwin.close(client)
                    return
                }
                self.readRequest(from: client)
            }
        }
    }

    private func readRequest(from client: Int32) {
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

        let request: ZshellAutomationRequest
        do {
            request = try JSONDecoder().decode(ZshellAutomationRequest.self, from: data)
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

        handler(request) { [weak self] response in
            guard let self else {
                Darwin.close(client)
                return
            }
            self.workers.async { self.respond(response, to: client) }
        }
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
        timeout: TimeInterval = 5
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

    private static func configureSocket(
        _ descriptor: Int32,
        timeout: TimeInterval = 2
    ) throws {
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

    private static func address(
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
