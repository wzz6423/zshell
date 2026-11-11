import CryptoKit
import Darwin
import Foundation
import Network
import Security

nonisolated enum BrowserAccessLimits {
    static let connections = 24
    static let webSockets = 16
    static let socketsPerClient = 4
    static let clients = 32
    static let pendingPairings = 8
    static let headerBytes = 16 * 1024
    static let bodyBytes = 4096
    static let frameBytes = 16 * 1024
    static let outputCredit = 256 * 1024
    static let sendQueueBytes = 1024 * 1024
    static let pairingSeconds: TimeInterval = 120
}

nonisolated enum BrowserAccessError: LocalizedError {
    case message(String)
    case sessionServiceRequired

    var errorDescription: String? {
        switch self {
        case .message(let value): value
        case .sessionServiceRequired: String(localized:
            "Browser access needs the current session service. Choose Quit and End All Sessions, then reopen Zshell.")
        }
    }
}

nonisolated enum BrowserAccessMuxCapability {
    static func prepare() throws {
        if (try? PTYMuxCommandLine.exchange(method: "capabilities", timeout: 0.2))?
            .result?.objectValue?["observe"]?.boolValue == true { return }
        if isAbsent() { return }
        // An app update leaves retained PTYs in the previous daemon. Its
        // shutdown rejects live sessions, so only an empty daemon is replaced.
        guard let response = try? PTYMuxCommandLine.exchange(method: "list", timeout: 0.2),
              let sessions = response.result?.arrayValue,
              !sessions.contains(where: { $0.objectValue?["running"]?.boolValue != false }),
              (try? PTYMuxCommandLine.exchange(method: "shutdown", timeout: 0.2)) != nil else {
            throw BrowserAccessError.sessionServiceRequired
        }
    }

    private static func isAbsent() -> Bool {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { Darwin.close(socket) }
        guard (try? PTYMuxWire.configureSocket(socket, timeout: 0.2)) != nil,
              var address = try? PTYMuxWire.address(for: PTYMuxPaths.socketPath) else { return false }
        let connected = withUnsafePointer(to: &address.0) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, address.1) }
        }
        guard connected < 0, errno == ECONNREFUSED || errno == ENOENT else { return false }
        // A daemon holds this lock before it binds the socket. Refusal alone
        // can also mean that a live daemon is starting or shutting down.
        let descriptor = Darwin.open(PTYMuxPaths.lockPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 { return errno == ENOENT }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == geteuid(),
              metadata.st_nlink == 1 else { return false }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

nonisolated struct BrowserAccessConfiguration: Equatable, Sendable {
    static let defaultPort = 7443
    static let loopbackID = "loopback"
    static func localPorts(for port: Int) -> [UInt16] {
        let port = (1024...65_535).contains(port) ? port : defaultPort
        return (1...8).map { UInt16(1024 + (port - 1024 + $0) % (65_536 - 1024)) }
    }
    let enabled: Bool
    let interfaceID: String
    let port: Int

    init(enabled: Bool, interfaceID: String, port: Int) {
        self.enabled = enabled
        self.interfaceID = interfaceID.isEmpty ? Self.loopbackID : interfaceID
        self.port = (1024...65_535).contains(port) ? port : Self.defaultPort
    }
}

nonisolated struct BrowserAccessInterface: Equatable, Sendable {
    let name: String
    let address: String
    let interface: NWInterface?
    var isLoopback: Bool { address == "127.0.0.1" }
    var isTailscale: Bool { Self.isTailnet(address) }
    var id: String { isLoopback ? BrowserAccessConfiguration.loopbackID : name + "|" + address }

    static let loopback = Self(name: "lo0", address: "127.0.0.1", interface: nil)

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    static func isPrivate(_ address: String) -> Bool {
        guard let ip = IPv4Address(address) else { return false }
        let bytes = Array(ip.rawValue)
        return bytes[0] == 10 || bytes[0] == 172 && (16...31).contains(bytes[1])
            || bytes[0] == 192 && bytes[1] == 168
    }

    static func isTailnet(_ address: String) -> Bool {
        guard let ip = IPv4Address(address) else { return false }
        let bytes = Array(ip.rawValue)
        return bytes[0] == 100 && (64...127).contains(bytes[1])
    }

    static func available(on interfaces: [NWInterface]) -> [Self] {
        var result = [Self.loopback]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let record = entry.pointee
            guard record.ifa_flags & UInt32(IFF_UP) != 0,
                  record.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let raw = record.ifa_addr, raw.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: record.ifa_name)
            var value = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &value, &text, socklen_t(text.count)) != nil else { continue }
            let address = String(cString: text)
            guard Self.isPrivate(address) || Self.isTailnet(address)
                    && (name.hasPrefix("utun") || name.hasPrefix("tailscale")) else { continue }
            // NetworkExtension tunnel interfaces may be absent from the default
            // path. Their exact local address still gives the listener its scope.
            let interface = interfaces.first(where: { $0.name == name })
            result.append(Self(name: name, address: address, interface: interface))
        }
        return [result[0]] + result.dropFirst().sorted { $0.id < $1.id }
    }
}

nonisolated struct BrowserAccessScope: Equatable, Sendable {
    let address: String
    let port: UInt16
    let usesTLS: Bool
    var host: String { address + ":" + String(port) }
    var origin: String { (usesTLS ? "https://" : "http://") + host }
    var url: URL { URL(string: origin + "/")! }

    func permitsPeer(_ address: String) -> Bool {
        guard let ip = IPv4Address(address) else { return false }
        if !usesTLS { return ip.isLoopback }
        return ip.isLoopback || BrowserAccessInterface.isPrivate(address) || BrowserAccessInterface.isTailnet(address)
    }
}

nonisolated enum BrowserAccessSecret {
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BrowserAccessError.message(String(localized: "Browser access could not create a secure credential."))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

nonisolated struct BrowserAccessHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func next(in buffer: Data, scope: BrowserAccessScope) throws -> (Self, Int)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > BrowserAccessLimits.headerBytes { throw invalid }
            return nil
        }
        guard end.upperBound <= BrowserAccessLimits.headerBytes,
              let text = String(data: buffer.prefix(end.lowerBound), encoding: .utf8) else { throw invalid }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1", ["GET", "POST"].contains(request[0]),
              request[1].hasPrefix("/"), request[1].utf8.allSatisfy({ (33...126).contains($0) }),
              !request[1].contains("?"), !request[1].contains("#"), !request[1].contains("%"),
              !request[1].contains("\\"), !request[1].contains(".."), lines.count <= 40 else { throw invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"), separator != line.startIndex else { throw invalid }
            let key = String(line[..<separator]).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !value.utf8.contains(where: { $0 < 32 || $0 == 127 }), value.utf8.count <= 2048,
                  headers[key] == nil else { throw invalid }
            headers[key] = value
        }
        guard headers["host"] == scope.host, headers["transfer-encoding"] == nil,
              headers["origin"].map({ $0 == scope.origin }) ?? (request[0] == "GET"),
              headers["sec-fetch-site"] != "cross-site" else { throw invalid }
        let count: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(raw),
                  parsed <= BrowserAccessLimits.bodyBytes else { throw invalid }
            count = parsed
        } else { count = 0 }
        guard request[0] == "POST" || count == 0,
              request[0] != "POST" || headers["content-type"] == "application/json" else { throw invalid }
        guard buffer.count >= end.upperBound + count else { return nil }
        return (Self(method: String(request[0]), path: String(request[1]), headers: headers,
                     body: buffer.subdata(in: end.upperBound..<(end.upperBound + count))), end.upperBound + count)
    }

    static var invalid: BrowserAccessError { .message("Invalid browser access request.") }

    func webSocketAccept() throws -> String {
        guard method == "GET", path == "/terminal", body.isEmpty,
              headers["origin"] != nil, headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true,
              headers["sec-websocket-version"] == "13",
              headers["sec-websocket-protocol"] == nil, let key = headers["sec-websocket-key"],
              Data(base64Encoded: key)?.count == 16 else { throw Self.invalid }
        return Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
    }
}

nonisolated enum BrowserAccessWebSocketFrame {
    struct Frame { let opcode: UInt8; let payload: Data; let consumed: Int }

    static func next(in buffer: Data) throws -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        let opcode = first & 15
        guard first & 0xf0 == 0x80, second & 0x80 != 0, [1, 2, 8, 9, 10].contains(opcode) else {
            throw BrowserAccessHTTPRequest.invalid
        }
        var head = 2
        var length = Int(second & 127)
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[buffer.startIndex + 2]) * 256 + Int(buffer[buffer.startIndex + 3])
            guard length >= 126 else { throw BrowserAccessHTTPRequest.invalid }
            head = 4
        } else if length == 127 { throw BrowserAccessHTTPRequest.invalid }
        guard length <= BrowserAccessLimits.frameBytes, opcode < 8 || length <= 125,
              opcode != 8 || length != 1 else { throw BrowserAccessHTTPRequest.invalid }
        guard buffer.count >= head + 4 + length else { return nil }
        let mask = Array(buffer.dropFirst(head).prefix(4))
        let bytes = buffer.dropFirst(head + 4).prefix(length).enumerated().map { $0.element ^ mask[$0.offset % 4] }
        let payload = Data(bytes)
        guard opcode != 1 || String(data: payload, encoding: .utf8) != nil else {
            throw BrowserAccessHTTPRequest.invalid
        }
        return Frame(opcode: opcode, payload: payload, consumed: head + 4 + length)
    }

    static func encode(opcode: UInt8, payload: Data) -> Data {
        var result = Data([0x80 | opcode])
        if payload.count < 126 { result.append(UInt8(payload.count)) }
        else { result.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 255)]) }
        result.append(payload)
        return result
    }
}
