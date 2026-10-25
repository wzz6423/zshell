import Darwin
import Foundation

enum PTYMuxConstants {
    static let protocolVersion = 2
    static let maximumFrameBytes = 256 * 1024
    static let maximumBacklogBytes = 1024 * 1024
    static let maximumTailBytes = 64 * 1024
    static let maximumSessions = 128
    static let maximumSnapshotBytes = 16 * 1024 * 1024
    static let maximumInputBytes = 256 * 1024
    static let socketTimeout: TimeInterval = 2
}

struct PTYMuxRequest: Codable {
    let version: Int
    let id: String
    let method: String
    let params: [String: ZshellJSONValue]
}

struct PTYMuxErrorPayload: Codable {
    let code: String
    let message: String
}

struct PTYMuxResponse: Codable {
    let version: Int
    let id: String
    let ok: Bool
    let result: ZshellJSONValue?
    let error: PTYMuxErrorPayload?

    static func success(id: String, result: ZshellJSONValue) -> Self {
        Self(
            version: PTYMuxConstants.protocolVersion,
            id: id,
            ok: true,
            result: result,
            error: nil
        )
    }

    static func failure(id: String, code: String, message: String) -> Self {
        Self(
            version: PTYMuxConstants.protocolVersion,
            id: id,
            ok: false,
            result: nil,
            error: PTYMuxErrorPayload(code: code, message: message)
        )
    }
}

enum PTYMuxError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

enum PTYMuxPaths {
    static var directoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["ZSHELL_PTY_MUX_DIRECTORY"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if DEBUG
        let name = "zshell-dev"
        #else
        let name = "zshell"
        #endif
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("pty-mux", isDirectory: true)
    }

    static var socketPath: String {
        directoryURL.appendingPathComponent("control.sock").path
    }

    static var lockPath: String {
        directoryURL.appendingPathComponent("daemon.lock").path
    }

    static func prepareDirectory() throws {
        let manager = FileManager.default
        var existing = stat()
        let existingResult = directoryURL.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &existing) } ?? -1
        }
        if existingResult == 0,
           existing.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) {
            throw PTYMuxError.message(
                "PTY mux state path is not a directory: \(directoryURL.path)"
            )
        }
        if existingResult != 0, errno != ENOENT {
            throw PTYMuxWire.errnoError("lstat")
        }
        try manager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var metadata = stat()
        let result = directoryURL.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &metadata) } ?? -1
        }
        let type = metadata.st_mode & mode_t(S_IFMT)
        let permissions = metadata.st_mode & 0o777
        guard result == 0,
              type == mode_t(S_IFDIR),
              metadata.st_uid == geteuid(),
              permissions == 0o700 else {
            throw PTYMuxError.message(
                "PTY mux state directory must be a private 0700 directory: \(directoryURL.path)"
            )
        }
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}

enum PTYMuxWire {
    static func configureSocket(
        _ descriptor: Int32,
        timeout: TimeInterval = PTYMuxConstants.socketTimeout
    ) throws {
        try markCloseOnExec(descriptor)
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw errnoError("setsockopt")
        }
        let seconds = floor(timeout)
        var value = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((timeout - seconds) * 1_000_000)
        )
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &value,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw errnoError("setsockopt")
        }
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &value,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw errnoError("setsockopt")
        }
    }

    static func address(for path: String) throws -> (sockaddr_un, socklen_t) {
        let bytes = Array(path.utf8CString)
        var value = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: value.sun_path)
        guard bytes.count <= capacity else {
            throw PTYMuxError.message("PTY mux socket path is too long: \(path)")
        }
        let length = MemoryLayout<sa_family_t>.size + bytes.count
        value.sun_len = UInt8(length)
        value.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &value.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in bytes.indices { destination[index] = bytes[index] }
            }
        }
        return (value, socklen_t(length))
    }

    static func markCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw errnoError("fcntl")
        }
    }

    static func errnoError(_ operation: String) -> PTYMuxError {
        .message("\(operation): \(String(cString: strerror(errno)))")
    }

    static func writeFrame<T: Encodable>(_ value: T, to descriptor: Int32) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= PTYMuxConstants.maximumFrameBytes else {
            throw PTYMuxError.message("PTY mux frame exceeds 256 KiB.")
        }
        var frame = Data(capacity: 4 + payload.count)
        frame.appendUInt32(UInt32(payload.count))
        frame.append(payload)
        try writeAll(frame, to: descriptor)
    }

    static func readFrame<T: Decodable>(
        _ type: T.Type,
        from descriptor: Int32
    ) throws -> T {
        let prefix = try readExactly(4, from: descriptor)
        let length = prefix.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        }
        guard length <= UInt32(PTYMuxConstants.maximumFrameBytes) else {
            throw PTYMuxError.message("PTY mux frame exceeds 256 KiB.")
        }
        let payload = try readExactly(Int(length), from: descriptor)
        return try JSONDecoder().decode(type, from: payload)
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    raw.baseAddress!.advanced(by: offset),
                    raw.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw errnoError("write")
                }
            }
        }
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < count {
                let received = Darwin.read(
                    descriptor,
                    raw.baseAddress!.advanced(by: offset),
                    count - offset
                )
                if received > 0 {
                    offset += received
                } else if received == 0 {
                    throw PTYMuxError.message("PTY mux connection closed mid-frame.")
                } else if errno == EINTR {
                    continue
                } else {
                    throw errnoError("read")
                }
            }
        }
        return data
    }
}

private final class PTYMuxDaemon {
    private let store = PTYMuxSessionStore()
    private let listener: Int32
    private let lifetimeLock: Int32
    private let workers = DispatchQueue(
        label: "sh.zshell.pty-mux.clients",
        qos: .utility,
        attributes: .concurrent
    )
    private let shutdownLock = NSLock()
    private var shuttingDown = false
    private var activeClients = 0

    init() throws {
        try PTYMuxPaths.prepareDirectory()
        lifetimeLock = Darwin.open(
            PTYMuxPaths.lockPath,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            0o600
        )
        guard lifetimeLock >= 0 else { throw PTYMuxWire.errnoError("open") }
        var lockMetadata = stat()
        guard fstat(lifetimeLock, &lockMetadata) == 0,
              lockMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              lockMetadata.st_uid == geteuid(),
              lockMetadata.st_nlink == 1 else {
            Darwin.close(lifetimeLock)
            throw PTYMuxError.message("PTY mux lock must be an owner-only regular file.")
        }
        guard flock(lifetimeLock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lifetimeLock)
            throw PTYMuxError.message("PTY mux daemon is already running.")
        }
        guard fchmod(lifetimeLock, 0o600) == 0 else {
            let error = PTYMuxWire.errnoError("fchmod")
            Darwin.close(lifetimeLock)
            throw error
        }

        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            Darwin.close(lifetimeLock)
            throw PTYMuxWire.errnoError("socket")
        }
        do {
            try PTYMuxWire.configureSocket(listener)
            try bindListener()
        } catch {
            // No worker can be blocked in `accept` yet, but shutting the
            // listener down before closing keeps every close site uniform.
            _ = shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
            Darwin.close(lifetimeLock)
            unlink(PTYMuxPaths.socketPath)
            throw error
        }
    }

    deinit {
        // `close` alone does not wake a thread blocked in `accept` on the same
        // descriptor; `shutdown` invalidates the pending accept so the run
        // loop returns an error and exits instead of hanging forever. A -1
        // return (e.g. EBADF when the descriptor is already closed) is fine
        // and must not skip the `close` below.
        _ = shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        Darwin.close(lifetimeLock)
        unlink(PTYMuxPaths.socketPath)
    }

    func run() -> Never {
        while true {
            shutdownLock.lock()
            let shouldStop = shuttingDown
            shutdownLock.unlock()
            if shouldStop { break }
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                // The listener is closed when a `shutdown` request wakes the
                // loop from a worker; any other accept failure also ends the
                // daemon. This path is the single `exit` for the process, so it
                // runs only after the shutdown success response has been written.
                break
            }
            shutdownLock.lock()
            let accepted = activeClients < PTYMuxConstants.maximumSessions + 32
            if accepted { activeClients += 1 }
            shutdownLock.unlock()
            guard accepted else { Darwin.close(client); continue }
            workers.async { [self] in
                handle(client)
                shutdownLock.lock()
                activeClients -= 1
                shutdownLock.unlock()
            }
        }
        store.terminateAll()
        exit(0)
    }

    private func bindListener() throws {
        var address = try PTYMuxWire.address(for: PTYMuxPaths.socketPath)
        unlink(PTYMuxPaths.socketPath)
        let result = withUnsafePointer(to: &address.0) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, address.1)
            }
        }
        guard result == 0 else { throw PTYMuxWire.errnoError("bind") }
        guard Darwin.chmod(PTYMuxPaths.socketPath, 0o600) == 0 else {
            throw PTYMuxWire.errnoError("chmod")
        }
        guard Darwin.listen(listener, 16) == 0 else {
            throw PTYMuxWire.errnoError("listen")
        }
    }

    private func handle(_ client: Int32) {
        defer { Darwin.close(client) }
        do {
            try PTYMuxWire.configureSocket(client)
            var peerUser: uid_t = 0
            var peerGroup: gid_t = 0
            guard getpeereid(client, &peerUser, &peerGroup) == 0,
                  peerUser == geteuid() else {
                try PTYMuxWire.writeFrame(
                    PTYMuxResponse.failure(
                        id: "unknown",
                        code: "unauthorized_peer",
                        message: "PTY mux only accepts clients from its owning user."
                    ),
                    to: client
                )
                return
            }

            let request = try PTYMuxWire.readFrame(PTYMuxRequest.self, from: client)
            if request.method == "attach", request.version == PTYMuxConstants.protocolVersion {
                let session = try requireSession(request)
                let dimensions = try dimensions(request)
                session.resize(columns: dimensions.0, rows: dimensions.1,
                               cellWidth: dimensions.2, cellHeight: dimensions.3)
                let result = session.snapshot(tailBytes: 0)
                let attachment = PTYMuxAttachment(descriptor: client)
                defer { session.detach(attachment); attachment.finish() }
                // Reads live for the attachment; writes remain bounded so a frozen
                // client cannot leave a snapshot writer blocked indefinitely.
                var receiveTimeout = timeval(tv_sec: 0, tv_usec: 0)
                guard setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
                                 socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                    throw PTYMuxWire.errnoError("setsockopt")
                }
                try session.attach(attachment) {
                    try PTYMuxWire.writeFrame(PTYMuxResponse.success(id: request.id, result: result), to: client)
                }
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let count = Darwin.read(client, &buffer, buffer.count)
                    if count > 0 { session.write(Data(buffer.prefix(count)), from: attachment) }
                    else if count < 0 && errno == EINTR { continue }
                    else { return }
                }
            }
            let response = route(request)
            try PTYMuxWire.writeFrame(response, to: client)
            // Only the worker that served a successful `shutdown` wakes the run
            // loop by closing the listener. Other workers never exit on their own,
            // so a concurrent request cannot race this worker to `exit` and
            // truncate the shutdown success response that was just written above.
            if request.method == "shutdown", response.ok {
                shutdownLock.lock()
                let shouldStop = shuttingDown
                shutdownLock.unlock()
                if shouldStop {
                    // The main thread is blocked in `accept` on the listener, and
                    // `close` alone does not wake it — the worker would hang the
                    // daemon forever. `shutdown` first aborts the pending accept
                    // with an error so the run loop can exit cleanly; a -1 return
                    // (e.g. EBADF) is harmless and must not skip the `close`.
                    _ = shutdown(listener, SHUT_RDWR)
                    Darwin.close(listener)
                    unlink(PTYMuxPaths.socketPath)
                }
            }
        } catch {
            try? PTYMuxWire.writeFrame(
                PTYMuxResponse.failure(
                    id: "unknown",
                    code: "invalid_request",
                    message: String(describing: error)
                ),
                to: client
            )
        }
    }

    private func route(_ request: PTYMuxRequest) -> PTYMuxResponse {
        guard request.version == PTYMuxConstants.protocolVersion else {
            return .failure(
                id: request.id,
                code: "unsupported_version",
                message: "PTY mux protocol version \(request.version) is not supported."
            )
        }
        do {
            switch request.method {
            case "create":
                return try create(request)
            case "list":
                return .success(
                    id: request.id,
                    result: .array(store.list().map { $0.snapshot(tailBytes: 0) })
                )
            case "get":
                let session = try requireSession(request)
                let limit = min(
                    max(request.params["tailBytes"]?.intValue ?? 0, 0),
                    PTYMuxConstants.maximumTailBytes
                )
                return .success(id: request.id, result: session.snapshot(tailBytes: limit))
            case "terminate":
                let session = try requireSession(request)
                session.terminate()
                return .success(id: request.id, result: .object(["accepted": .bool(true)]))
            case "resize":
                let session = try requireSession(request)
                let size = try dimensions(request)
                session.resize(columns: size.0, rows: size.1, cellWidth: size.2, cellHeight: size.3)
                return .success(id: request.id, result: .object(["accepted": .bool(true)]))
            case "theme":
                try requireSession(request).setTheme(try theme(request))
                return .success(id: request.id, result: .object(["accepted": .bool(true)]))
            case "terminateAll":
                store.terminateAll()
                return .success(id: request.id, result: .object(["accepted": .bool(true)]))
            case "shutdown":
                guard store.list().allSatisfy({ !$0.isRunning }) else {
                    return .failure(
                        id: request.id,
                        code: "sessions_running",
                        message: "Terminate all PTY sessions before shutting down the daemon."
                    )
                }
                shutdownLock.lock()
                shuttingDown = true
                shutdownLock.unlock()
                return .success(id: request.id, result: .object(["accepted": .bool(true)]))
            default:
                return .failure(
                    id: request.id,
                    code: "unknown_method",
                    message: "Unknown PTY mux method \(request.method)."
                )
            }
        } catch {
            return .failure(
                id: request.id,
                code: "request_failed",
                message: String(describing: error)
            )
        }
    }

    private func create(_ request: PTYMuxRequest) throws -> PTYMuxResponse {
        let workingDirectory = request.params["workingDirectory"]?.stringValue
            ?? FileManager.default.currentDirectoryPath
        let command = request.params["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard command.count == request.params["command"]?.arrayValue?.count ?? command.count else {
            throw PTYMuxError.message("command must be an array of strings.")
        }
        let session = try store.create(
            id: request.params["id"]?.stringValue ?? UUID().uuidString,
            workingDirectory: workingDirectory,
            command: command,
            environment: try environment(request),
            launchDirectoryURL: request.params["launchDirectory"]?.stringValue.map { URL(fileURLWithPath: $0) },
            executable: request.params["executable"]?.stringValue ?? CommandLine.arguments[0],
            theme: try theme(request)
        )
        return .success(id: request.id, result: session.snapshot(tailBytes: 0))
    }

    private func requireSession(_ request: PTYMuxRequest) throws -> PTYMuxSession {
        guard let id = request.params["id"]?.stringValue, !id.isEmpty else {
            throw PTYMuxError.message("A session id is required.")
        }
        guard let session = store.session(id: id) else {
            throw PTYMuxError.message("Unknown PTY mux session \(id).")
        }
        return session
    }

    private func environment(_ request: PTYMuxRequest) throws -> [String: String] {
        guard let values = request.params["environment"]?.objectValue else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in values {
            guard let value = value.stringValue else { throw PTYMuxError.message("Environment values must be strings.") }
            result[key] = value
        }
        return result
    }

    private func theme(_ request: PTYMuxRequest) throws -> ZshellTheme {
        var theme = ZshellTheme()
        theme.foreground = 0xeeeeee
        theme.background = 0x111111
        theme.cursor = 0xeeeeee
        guard let encoded = request.params["theme"]?.stringValue else { return theme }
        guard let data = Data(base64Encoded: encoded), data.count == MemoryLayout<ZshellTheme>.size else {
            throw PTYMuxError.message("Invalid terminal theme.")
        }
        _ = withUnsafeMutableBytes(of: &theme) { data.copyBytes(to: $0) }
        return theme
    }

    private func dimensions(_ request: PTYMuxRequest) throws -> (UInt16, UInt16, UInt16, UInt16) {
        let columns = request.params["columns"]?.intValue ?? 80
        let rows = request.params["rows"]?.intValue ?? 24
        guard (1...512).contains(columns), (1...256).contains(rows), columns * rows <= 65_536 else {
            throw PTYMuxError.message("Invalid terminal dimensions.")
        }
        return (UInt16(columns), UInt16(rows),
                UInt16(clamping: request.params["cellWidth"]?.intValue ?? 8),
                UInt16(clamping: request.params["cellHeight"]?.intValue ?? 16))
    }
}

enum PTYMuxCommandLine {
    static let daemonArgument = "--pty-mux-daemon"
    static let childArgument = "--pty-mux-child"
    static let relayArgument = "--pty-mux-relay"

    static var shouldRunChild: Bool { CommandLine.arguments.dropFirst().first == childArgument }
    static var shouldRunRelay: Bool { CommandLine.arguments.dropFirst().first == relayArgument }

    static func runChild() -> Never {
        guard CommandLine.arguments.count > 2, ioctl(STDIN_FILENO, TIOCSCTTY, 0) == 0 else {
            fputs("zshell pty mux: could not claim controlling terminal.\n", stderr)
            exit(126)
        }
        let command = CommandLine.arguments.dropFirst(2).map { strdup($0) }
        var arguments = command + [nil]
        execve(CommandLine.arguments[2], &arguments, environ)
        fputs("zshell pty mux: could not exec terminal command.\n", stderr)
        exit(127)
    }

    static var shouldRunDaemon: Bool {
        CommandLine.arguments.dropFirst().first == daemonArgument
    }

    static func runDaemon() -> Never {
        do {
            try PTYMuxDaemon().run()
        } catch {
            fputs("zshell pty mux: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw CLIError.message(usage)
        }
        switch command {
        case "start":
            try startDaemonIfNeeded()
            let response = try exchange(method: "list")
            printResult(response)
        case "create":
            try startDaemonIfNeeded()
            let separator = arguments.firstIndex(of: "--")
            let optionEnd = separator ?? arguments.endIndex
            let optionArguments = Array(arguments.dropFirst()[..<optionEnd])
            let commandArguments = separator.map { Array(arguments[arguments.index(after: $0)...]) } ?? []
            var workingDirectory = FileManager.default.currentDirectoryPath
            var index = 0
            while index < optionArguments.count {
                switch optionArguments[index] {
                case "--working-directory":
                    guard index + 1 < optionArguments.count else {
                        throw CLIError.message("--working-directory requires a path.")
                    }
                    workingDirectory = optionArguments[index + 1]
                    index += 2
                default:
                    throw CLIError.message("Unknown PTY mux create option \(optionArguments[index]).")
                }
            }
            let response = try exchange(method: "create", params: [
                "workingDirectory": .string(workingDirectory),
                "command": .array(commandArguments.map(ZshellJSONValue.string)),
            ])
            printResult(response)
        case "list":
            printResult(try exchange(method: "list"))
        case "get":
            guard arguments.count == 2 else { throw CLIError.message(usage) }
            printResult(try exchange(method: "get", params: [
                "id": .string(arguments[1]),
                "tailBytes": .number(Double(PTYMuxConstants.maximumTailBytes)),
            ]))
        case "terminate":
            guard arguments.count == 2 else { throw CLIError.message(usage) }
            printResult(try exchange(method: "terminate", params: ["id": .string(arguments[1])]))
        case "shutdown":
            printResult(try exchange(method: "shutdown"))
        case "--help", "-h":
            print(usage)
        default:
            throw CLIError.message("Unknown PTY mux command \(command).\n\n\(usage)")
        }
    }

    private static let usage = """
    Usage:
      zshell +pty-mux start
      zshell +pty-mux create [--working-directory PATH] [-- COMMAND [ARGUMENT...]]
      zshell +pty-mux list
      zshell +pty-mux get SESSION_ID
      zshell +pty-mux terminate SESSION_ID
      zshell +pty-mux shutdown

    This internal interface inspects the PTYs kept outside the GUI process.
    """

    static func startDaemonIfNeeded() throws {
        if (try? exchange(method: "list", timeout: 0.2)) != nil { return }
        try PTYMuxPaths.prepareDirectory()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw PTYMuxError.message("Could not initialize PTY mux daemon launch actions.")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_addopen(
            &actions, STDIN_FILENO, "/dev/null", O_RDWR, 0
        ) == 0,
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO) == 0 else {
            throw PTYMuxError.message("Could not configure PTY mux daemon descriptors.")
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw PTYMuxError.message("Could not initialize PTY mux daemon launch attributes.")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)
        ) == 0 else {
            throw PTYMuxError.message("Could not configure PTY mux daemon launch attributes.")
        }

        var pid: pid_t = 0
        let result = executable.withCString { path in
            daemonArgument.withCString { argument in
                var arguments: [UnsafeMutablePointer<CChar>?] = [
                    UnsafeMutablePointer(mutating: path),
                    UnsafeMutablePointer(mutating: argument),
                    nil,
                ]
                return posix_spawn(&pid, path, &actions, &attributes, &arguments, environ)
            }
        }
        guard result == 0 else {
            throw PTYMuxError.message("posix_spawn: \(String(cString: strerror(result)))")
        }

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if (try? exchange(method: "list", timeout: 0.2)) != nil { return }
            if waitpid(pid, &status, WNOHANG) == pid {
                throw PTYMuxError.message("PTY mux daemon exited during startup.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw PTYMuxError.message("Timed out starting the PTY mux daemon.")
    }

    static func exchange(
        method: String,
        params: [String: ZshellJSONValue] = [:],
        timeout: TimeInterval = PTYMuxConstants.socketTimeout
    ) throws -> PTYMuxResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PTYMuxWire.errnoError("socket") }
        defer { Darwin.close(descriptor) }
        try PTYMuxWire.configureSocket(descriptor, timeout: timeout)
        var address = try PTYMuxWire.address(for: PTYMuxPaths.socketPath)
        let connected = withUnsafePointer(to: &address.0) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, address.1)
            }
        }
        guard connected == 0 else { throw PTYMuxWire.errnoError("connect") }
        let request = PTYMuxRequest(
            version: PTYMuxConstants.protocolVersion,
            id: UUID().uuidString,
            method: method,
            params: params
        )
        try PTYMuxWire.writeFrame(request, to: descriptor)
        let response = try PTYMuxWire.readFrame(PTYMuxResponse.self, from: descriptor)
        guard response.version == PTYMuxConstants.protocolVersion,
              response.id == request.id else {
            throw PTYMuxError.message("PTY mux returned a mismatched response.")
        }
        guard response.ok else {
            let code = response.error?.code ?? "pty_mux_error"
            let message = response.error?.message ?? "PTY mux request failed."
            throw PTYMuxError.message("\(code): \(message)")
        }
        return response
    }

    private static func printResult(_ response: PTYMuxResponse) {
        let result = response.result ?? .null
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(result), let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }
}
