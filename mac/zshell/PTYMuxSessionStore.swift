import Darwin
import Foundation

final class PTYMuxSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: PTYMuxSession] = [:]
    private var reservations = Set<String>()

    func create(
        id: String = UUID().uuidString,
        workingDirectory: String, command: [String],
        environment: [String: String] = [:],
        launchDirectoryURL: URL? = nil,
        executable: String = CommandLine.arguments[0],
        columns: UInt16 = 80, rows: UInt16 = 24,
        theme: ZshellTheme
    ) throws -> PTYMuxSession {
        guard let uuid = UUID(uuidString: id) else { throw PTYMuxError.message("Invalid PTY session id.") }
        let id = uuid.uuidString
        lock.lock()
        sessions = sessions.filter { $0.value.isRunning }
        guard sessions[id] == nil, !reservations.contains(id) else {
            lock.unlock()
            throw PTYMuxError.message("PTY session id is already in use.")
        }
        guard sessions.count + reservations.count < PTYMuxConstants.maximumSessions else {
            lock.unlock()
            throw PTYMuxError.message("PTY mux session limit reached.")
        }
        reservations.insert(id)
        lock.unlock()
        defer { lock.lock(); reservations.remove(id); lock.unlock() }

        let command = command.isEmpty
            ? [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", "-l"] : command
        guard command.count <= 128, command.first?.hasPrefix("/") == true,
              command.allSatisfy({ $0.utf8.count <= 64 * 1024 && !$0.contains("\0") }),
              environment.count <= 512,
              environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") })
        else { throw PTYMuxError.message("Invalid PTY command or environment.") }
        let directory = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PTYMuxError.message("Working directory does not exist: \(workingDirectory)")
        }
        if let launchDirectoryURL,
           launchDirectoryURL.standardizedFileURL.path != PersistentCLIConnection.launchDirectory(for: uuid).standardizedFileURL.path {
            throw PTYMuxError.message("Invalid persistent launch directory.")
        }
        let state = try PersistentTerminalState(columns: columns, rows: rows, theme: theme)
        let spawned = try spawn(
            command: command, environment: environment, workingDirectory: directory,
            executable: executable, columns: columns, rows: rows
        )
        let session = PTYMuxSession(
            id: id, pid: spawned.pid, master: spawned.master,
            workingDirectory: directory, command: command,
            bindingToken: environment["ZSHELL_PERSISTENT_TOKEN"] ?? "",
            launchDirectoryURL: launchDirectoryURL, state: state
        )
        lock.lock()
        sessions[id] = session
        lock.unlock()
        return session
    }

    func list() -> [PTYMuxSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.sorted { $0.startedAt < $1.startedAt }
    }

    func session(id: String) -> PTYMuxSession? {
        guard let id = UUID(uuidString: id)?.uuidString else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    func terminateAll() { for session in list() { session.terminate() } }

    /// Spawn avoids running Swift or Foundation in a forked multithreaded
    /// daemon. A fresh executable claims the controlling TTY before exec.
    private func spawn(
        command: [String], environment: [String: String], workingDirectory: String,
        executable: String, columns: UInt16, rows: UInt16
    ) throws -> (pid: pid_t, master: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw PTYMuxWire.errnoError("openpty")
        }
        defer { Darwin.close(slave) }
        do {
            try PTYMuxWire.markCloseOnExec(master)
            let flags = fcntl(master, F_GETFL, 0)
            guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw PTYMuxWire.errnoError("fcntl")
            }
            var actions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else {
                throw PTYMuxError.message("Could not initialize PTY spawn actions.")
            }
            defer { posix_spawn_file_actions_destroy(&actions) }
            for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
                guard posix_spawn_file_actions_adddup2(&actions, slave, descriptor) == 0 else {
                    throw PTYMuxError.message("Could not configure PTY descriptors.")
                }
            }
            guard posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) == 0 else {
                throw PTYMuxError.message("Could not configure PTY working directory.")
            }
            var attributes: posix_spawnattr_t?
            guard posix_spawnattr_init(&attributes) == 0 else {
                throw PTYMuxError.message("Could not initialize PTY spawn attributes.")
            }
            defer { posix_spawnattr_destroy(&attributes) }
            guard posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)
            ) == 0 else { throw PTYMuxError.message("Could not configure PTY session.") }
            var inherited = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ZSHELL_") }
            inherited.merge(environment, uniquingKeysWith: { _, value in value })
            inherited["TERM"] = inherited["TERM"] ?? "xterm-256color"
            let argv = ([executable, PTYMuxCommandLine.childArgument] + command).map { strdup($0) }
            let env = inherited.map { strdup("\($0.key)=\($0.value)") }
            defer { for pointer in argv + env { free(pointer) } }
            var arguments = argv + [nil]
            var variables = env + [nil]
            var pid: pid_t = 0
            let result = posix_spawn(&pid, executable, &actions, &attributes, &arguments, &variables)
            guard result == 0 else {
                throw PTYMuxError.message("posix_spawn: \(String(cString: strerror(result)))")
            }
            return (pid, master)
        } catch {
            Darwin.close(master)
            throw error
        }
    }
}
