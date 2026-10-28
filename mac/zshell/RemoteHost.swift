import Darwin
import Foundation

nonisolated struct RemoteHost: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var address: String
    var serverPath: String
    enum Platform: String, Codable, Sendable, CaseIterable { case unix, windows, wsl }
    var platform: Platform
    var wslDistribution: String?

    init(id: UUID = UUID(), name: String, address: String, serverPath: String = "~/.local/bin/zshell-server",
         platform: Platform = .unix, wslDistribution: String? = nil) throws {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serverPath = serverPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.platform = platform
        self.wslDistribution = wslDistribution?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.wslDistribution?.isEmpty == true { self.wslDistribution = nil }
        _ = try endpoint()
        guard !self.serverPath.contains("\0"), !self.serverPath.contains(where: \Character.isNewline),
              self.serverPath.hasPrefix("/") || self.serverPath.hasPrefix("~/")
                || platform == .windows && (self.serverPath.hasPrefix("~\\") || Self.isWindowsAbsolute(self.serverPath)) else {
            throw RemoteHostError.message(String(localized: "Use an absolute path or ~/ for the remote server executable."))
        }
        if let distribution = self.wslDistribution, distribution.utf8.count > 256 || distribution.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            throw RemoteHostError.message(String(localized: "Enter a valid WSL distribution name."))
        }
        if platform == .wsl, case .tailscale = try endpoint() {
            throw RemoteHostError.message(String(localized: "Use SSH to select a WSL distribution."))
        }
        if self.name.isEmpty { self.name = self.address }
    }

    private enum CodingKeys: String, CodingKey { case id, name, address, serverPath, platform, wslDistribution }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      address: values.decode(String.self, forKey: .address), serverPath: values.decode(String.self, forKey: .serverPath),
                      platform: values.decodeIfPresent(Platform.self, forKey: .platform) ?? .unix,
                      wslDistribution: values.decodeIfPresent(String.self, forKey: .wslDistribution))
    }

    enum Endpoint: Sendable {
        case ssh(SSHEndpoint)
        case tailscale(host: String, port: Int)
    }

    private static func isWindowsAbsolute(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        return bytes.count >= 3 && ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0]))
            && bytes[1] == 58 && (bytes[2] == 47 || bytes[2] == 92)
    }

    func serverCommand(_ arguments: [String]) -> [String] {
        if platform != .wsl { return [serverPath] + arguments }
        return wslCommand(["/bin/sh", "-c", "exec " + ([serverPath] + arguments).map(SSHEndpoint.shellWord).joined(separator: " ")])
    }

    func wslCommand(_ arguments: [String]) -> [String] {
        ["wsl.exe"] + (wslDistribution.map { ["--distribution", $0] } ?? []) + ["--exec"] + arguments
    }

    func endpoint() throws -> Endpoint {
        let text = address.contains("://") ? address : "ssh://" + address
        guard let url = URLComponents(string: text),
              let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.password == nil, url.path.isEmpty || url.path == "/",
              url.query == nil, url.fragment == nil,
              !host.hasPrefix("-"), Self.validHost(host),
              url.port == nil || (1...65_535).contains(url.port!) else {
            throw RemoteHostError.message(String(localized: "Enter an SSH address or tailscale://host:7373."))
        }
        switch scheme {
        case "ssh":
            if let user = url.user, !user.isEmpty {
                guard !user.hasPrefix("-"), user.utf8.allSatisfy({
                    Self.isASCIIName($0) || $0 == 43
                }) else {
                    throw RemoteHostError.message(String(localized: "Enter an SSH address or tailscale://host:7373."))
                }
            }
            return .ssh(try SSHEndpoint(host: host, user: url.user, port: url.port))
        case "tailscale":
            guard url.user == nil else {
                throw RemoteHostError.message(String(localized: "Enter an SSH address or tailscale://host:7373."))
            }
            return .tailscale(host: host, port: url.port ?? 7373)
        default:
            throw RemoteHostError.message(String(localized: "Enter an SSH address or tailscale://host:7373."))
        }
    }

    private static func validHost(_ text: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let raw = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return inet_pton(AF_INET, raw, &ipv4) == 1 || inet_pton(AF_INET6, raw, &ipv6) == 1
            || raw.utf8.allSatisfy(isASCIIName)
    }

    private static func isASCIIName(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value)
            || value == 45 || value == 46 || value == 95
    }
}

nonisolated enum RemoteHostError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

nonisolated struct RemoteSessionInfo: Codable, Sendable {
    let sessionId: String
    let project: String
    let command: [String]
    let pid: Int32
    let startedAt: Double
    let running: Bool
    let exitCode: Int32?
    let columns: Int
    let rows: Int
    let clientCount: Int
    let activeClientId: String?
    let totalOutputBytes: UInt64
    var agentStatus: RemoteAgentStatus?
    var conversation: ZshellJSONValue?
}

nonisolated struct RemoteProjectListing: Sendable {
    let directory: String
    let sessions: [RemoteSessionInfo]
    var conversations: [RemoteAgentConversation] = []
}

nonisolated struct RemoteAgentStatus: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        let id: String
        let state: String
        let app: String
        let message: String
        let title: String
        let kind: String
        let progress: Int?
        let updatedAt: UInt64
    }
    let phase: String
    let app: String
    let message: String
    let attention: String?
    let progress: Int?
    let records: [Record]
    let generation: UInt64
}

nonisolated struct RemoteAgentConversation: Codable, Sendable {
    let identity: ZshellJSONValue
    let project: String
    let remoteSessionID: String
    let startedAt: Double
    let updatedAt: Double
    let endedAt: Double?
    let title: String?
}

nonisolated struct RemoteFrame: Codable {
    var version = 1
    var kind: String
    var requestId: String?
    var project: String?
    var sessionId: String?
    var clientId: String?
    var command: [String]?
    var environment: [String: String]?
    var initializationCommand: String?
    var columns: Int?
    var rows: Int?
    var data: String?
    var sequence: UInt64?
    var pasteFiles: [RemotePasteFileInfo]?
    var uploadId: String?
    var fileIndex: Int?
    var offset: UInt64?
    var provider: String?
    var conversationId: String?
    var result: ZshellJSONValue?
    var error: String?
    var exitCode: Int32?

    func decodedResult<T: Decodable>(_ type: T.Type) throws -> T {
        guard let result else { throw RemoteHostError.message(String(localized: "The remote server returned an invalid response.")) }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(result))
    }
}

nonisolated final class RemoteHostTransport: @unchecked Sendable {
    let input: Int32
    let output: Int32
    private let process: Process?
    private let handles: [FileHandle]
    private let socket: Int32?
    private let errorLock = NSLock()
    private var errorOutput = Data()
    private var closed = false

    init(host: RemoteHost) throws {
        switch try host.endpoint() {
        case .ssh(let endpoint):
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = try endpoint.transportArguments(connectTimeout: 10, command: host.serverCommand(["bridge"]), windowsShell: host.platform != .unix)
            var environment = SSHAgentEnvironment.shared.resolvedEnvironment()
            environment.removeValue(forKey: "ZSHELL_CLI_STATE")
            environment.removeValue(forKey: "ZSHELL_CLI_TOKEN")
            environment["SSH_ASKPASS_REQUIRE"] = "never"
            process.environment = environment
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            try process.run()
            inputPipe.fileHandleForReading.closeFile()
            outputPipe.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForWriting.closeFile()
            input = inputPipe.fileHandleForWriting.fileDescriptor
            output = outputPipe.fileHandleForReading.fileDescriptor
            self.process = process
            handles = [inputPipe.fileHandleForWriting, outputPipe.fileHandleForReading, errorPipe.fileHandleForReading]
            socket = nil
            DispatchQueue.global(qos: .utility).async { [weak self, handle = errorPipe.fileHandleForReading] in
                while let bytes = try? handle.read(upToCount: 4096), !bytes.isEmpty {
                    guard let self else { return }
                    self.errorLock.lock()
                    if self.errorOutput.count < 16_384 { self.errorOutput.append(bytes.prefix(16_384 - self.errorOutput.count)) }
                    self.errorLock.unlock()
                }
            }
        case .tailscale(let host, let port):
            let descriptor = try Self.connectTailnet(host: host, port: port)
            input = descriptor
            output = descriptor
            socket = descriptor
            process = nil
            handles = []
        }
    }

    deinit { close() }

    func handshake() throws {
        try writeExactly(Data("ZSRM0001".utf8), timeout: 12)
        let response = try readExactly(8, timeout: 12)
        guard response == Data("ZSRM0001".utf8) else {
            throw RemoteHostError.message(String(localized: "The remote server uses an incompatible protocol."))
        }
    }

    func exchange(_ frame: RemoteFrame) throws -> RemoteFrame {
        var frame = frame
        frame.requestId = UUID().uuidString
        let payload = try JSONEncoder().encode(frame)
        guard payload.count <= PTYMuxConstants.maximumFrameBytes else {
            throw RemoteHostError.message(String(localized: "The remote server returned an invalid response."))
        }
        var length = UInt32(payload.count).bigEndian
        var wire = withUnsafeBytes(of: &length) { Data($0) }
        wire.append(payload)
        try writeExactly(wire, timeout: 12)
        let prefix = try readExactly(4, timeout: 12)
        let count = prefix.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard (1...PTYMuxConstants.maximumFrameBytes).contains(count) else {
            throw RemoteHostError.message(String(localized: "The remote server returned an invalid response."))
        }
        let response = try JSONDecoder().decode(RemoteFrame.self, from: readExactly(count, timeout: 12))
        guard response.version == 1, response.requestId == frame.requestId else {
            throw RemoteHostError.message(String(localized: "The remote server returned an invalid response."))
        }
        if let error = response.error { throw RemoteHostError.message(error) }
        return response
    }

    private func readExactly(_ count: Int, timeout: TimeInterval) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeMutableBytes { bytes in
            while offset < count {
                try Task.checkCancellation()
                var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
                let milliseconds = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
                guard milliseconds > 0 else { throw RemoteHostError.message(String(localized: "The remote host did not respond in time.")) }
                let ready = Darwin.poll(&descriptor, 1, min(milliseconds, 250))
                if ready < 0, errno == EINTR { continue }
                if ready == 0 { continue }
                guard ready > 0 else { throw RemoteHostError.message(String(localized: "The remote host did not respond in time.")) }
                let received = Darwin.read(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                if received > 0 { offset += received }
                else if received < 0, errno == EINTR { continue }
                else { throw RemoteHostError.message(diagnostic(fallback: String(localized: "The remote connection closed."))) }
            }
        }
        return data
    }

    private func writeExactly(_ data: Data, timeout: TimeInterval) throws {
        let flags = fcntl(input, F_GETFL, 0)
        guard flags >= 0, fcntl(input, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(input, F_SETNOSIGPIPE, 1) == 0 else { throw PTYMuxWire.errnoError("fcntl") }
        defer { _ = fcntl(input, F_SETFL, flags) }
        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let milliseconds = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
                guard milliseconds > 0 else { throw RemoteHostError.message(String(localized: "The remote host did not respond in time.")) }
                var descriptor = pollfd(fd: input, events: Int16(POLLOUT), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, min(milliseconds, 250))
                if ready == 0 || ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { throw PTYMuxWire.errnoError("poll") }
                let written = Darwin.write(input, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written }
                else if written < 0, errno == EINTR || errno == EAGAIN { continue }
                else { throw RemoteHostError.message(diagnostic(fallback: String(localized: "The remote connection closed."))) }
            }
        }
    }

    func diagnostic(fallback: String) -> String {
        errorLock.lock()
        let data = errorOutput
        errorLock.unlock()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    func close() {
        errorLock.lock()
        guard !closed else { errorLock.unlock(); return }
        closed = true
        errorLock.unlock()
        if let socket { _ = shutdown(socket, SHUT_RDWR); Darwin.close(socket) }
        for handle in handles { try? handle.close() }
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(200)) {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private static func connectTailnet(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var addresses: UnsafeMutablePointer<addrinfo>?
        let hostname = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard getaddrinfo(hostname, String(port), &hints, &addresses) == 0, let addresses else {
            throw RemoteHostError.message(String(localized: "Couldn’t resolve the remote host."))
        }
        defer { freeaddrinfo(addresses) }
        var current: UnsafeMutablePointer<addrinfo>? = addresses
        while let address = current {
            defer { current = address.pointee.ai_next }
            guard isTailnet(address.pointee) else { continue }
            let descriptor = Darwin.socket(address.pointee.ai_family, SOCK_STREAM, IPPROTO_TCP)
            guard descriptor >= 0 else { continue }
            do {
                try PTYMuxWire.configureSocket(descriptor, timeout: 10)
                let flags = fcntl(descriptor, F_GETFL, 0)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw PTYMuxWire.errnoError("fcntl") }
                let result = Darwin.connect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen)
                if result < 0 {
                    guard errno == EINPROGRESS else { throw PTYMuxWire.errnoError("connect") }
                    var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    guard Darwin.poll(&pending, 1, 10_000) > 0 else { throw PTYMuxWire.errnoError("connect") }
                    var error: Int32 = 0
                    var count = socklen_t(MemoryLayout<Int32>.size)
                    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &count) == 0, error == 0 else {
                        throw RemoteHostError.message(String(localized: "Couldn’t connect to the remote host."))
                    }
                }
                guard fcntl(descriptor, F_SETFL, flags) == 0 else { throw PTYMuxWire.errnoError("fcntl") }
                return descriptor
            } catch { Darwin.close(descriptor) }
        }
        throw RemoteHostError.message(String(localized: "The host must resolve to a reachable Tailscale private address."))
    }

    private static func isTailnet(_ address: addrinfo) -> Bool {
        guard let value = address.ai_addr else { return false }
        if address.ai_family == AF_INET {
            return value.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                let bytes = withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { Array($0) }
                return bytes[0] == 100 && (64...127).contains(bytes[1])
            }
        }
        if address.ai_family == AF_INET6 {
            return value.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] }
            }
        }
        return false
    }

    static func isTailnetAddress(_ text: String) -> Bool {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var address: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(text, nil, &hints, &address) == 0, let address else { return false }
        defer { freeaddrinfo(address) }
        return isTailnet(address.pointee)
    }
}

nonisolated enum RemoteHostClient {
    static func catalog(host: RemoteHost) throws -> [RemoteProjectListing] {
        let transport = try RemoteHostTransport(host: host)
        defer { transport.close() }
        try transport.handshake()
        let directories = try transport.exchange(RemoteFrame(kind: "projects")).decodedResult([String].self)
        return try directories.map { directory in
            let sessions = try transport.exchange(RemoteFrame(kind: "list", project: directory)).decodedResult([RemoteSessionInfo].self)
            let conversations = try transport.exchange(RemoteFrame(kind: "agentHistory", project: directory)).decodedResult([RemoteAgentConversation].self)
            return RemoteProjectListing(directory: directory, sessions: sessions, conversations: conversations)
        }
    }

    static func create(host: RemoteHost, directory: String) throws -> RemoteSessionInfo {
        let transport = try RemoteHostTransport(host: host)
        defer { transport.close() }
        try transport.handshake()
        return try transport.exchange(RemoteFrame(kind: "create", project: directory, sessionId: UUID().uuidString)).decodedResult(RemoteSessionInfo.self)
    }

    static func terminate(host: RemoteHost, directory: String, sessionID: UUID) throws {
        let transport = try RemoteHostTransport(host: host)
        defer { transport.close() }
        try transport.handshake()
        _ = try transport.exchange(RemoteFrame(kind: "terminate", project: directory, sessionId: sessionID.uuidString))
    }

    static func resume(host: RemoteHost, identity: AgentConversationIdentity) throws -> RemoteSessionInfo {
        guard identity.remoteHostID == host.id, let project = identity.remoteProjectDirectory else {
            throw AgentConversationHistoryError.differentProject
        }
        let transport = try RemoteHostTransport(host: host)
        defer { transport.close() }
        try transport.handshake()
        return try transport.exchange(RemoteFrame(kind: "agentResume", project: project,
            provider: identity.provider.rawValue, conversationId: identity.sessionID)).decodedResult(RemoteSessionInfo.self)
    }
}
