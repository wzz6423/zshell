import Darwin
import Foundation

/// A running shell cannot replace its inherited environment when the GUI
/// restarts. Its private descriptor supplies the new app-scoped capability.
struct PersistentCLIConnection: Codable {
    let version: Int
    let terminalID: UUID
    let bindingToken: String
    let environment: [String: String]

    static func sessionDirectory(for id: UUID) -> URL {
        PTYMuxPaths.directoryURL.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func connectionURL(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("connection.json")
    }

    static func launchDirectory(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("launch", isDirectory: true)
    }

    static func prepare(for id: UUID) throws {
        try PTYMuxPaths.prepareDirectory()
        try preparePrivateDirectory(PTYMuxPaths.directoryURL.appendingPathComponent("sessions", isDirectory: true))
        try preparePrivateDirectory(sessionDirectory(for: id))
    }

    static func save(id: UUID, bindingToken: String, environment: [String: String]) throws {
        try prepare(for: id)
        let connection = Self(version: 1, terminalID: id, bindingToken: bindingToken, environment: environment)
        try writePrivate(try JSONEncoder().encode(connection), to: connectionURL(for: id))
    }

    static func resolvedEnvironment(_ inherited: [String: String]) throws -> [String: String] {
        guard let path = inherited["ZSHELL_PERSISTENT_CONNECTION"] else { return inherited }
        guard let idText = inherited["ZSHELL_TERMINAL_ID"], let id = UUID(uuidString: idText),
              path == connectionURL(for: id).path,
              let token = inherited["ZSHELL_PERSISTENT_TOKEN"], !token.isEmpty else {
            throw CLIError.message("Invalid persistent terminal connection.")
        }
        try verifyPrivateDirectory(PTYMuxPaths.directoryURL)
        try verifyPrivateDirectory(sessionDirectory(for: id).deletingLastPathComponent())
        try verifyPrivateDirectory(sessionDirectory(for: id))
        let data = try readPrivate(connectionURL(for: id))
        let connection = try JSONDecoder().decode(Self.self, from: data)
        guard connection.version == 1, connection.terminalID == id,
              connection.bindingToken == token,
              connection.environment["ZSHELL_TERMINAL_ID"] == id.uuidString else {
            throw CLIError.message("Persistent terminal connection is invalid or expired.")
        }
        return inherited.merging(connection.environment, uniquingKeysWith: { _, current in current })
    }

    static func updateLauncher(executable: String) throws -> String {
        try PTYMuxPaths.prepareDirectory()
        let directory = PTYMuxPaths.directoryURL.appendingPathComponent("bin", isDirectory: true)
        try preparePrivateDirectory(directory)
        let launcher = directory.appendingPathComponent("zshell")
        let script = """
        #!/bin/sh
        zshell_cli_bin=$(/usr/bin/dirname -- "$0")
        IFS= read -r zshell_cli_executable < "$zshell_cli_bin/current-executable" || exit 1
        if [ ! -x "$zshell_cli_executable" ]; then
          /usr/bin/printf '%s\\n' 'Zshell CLI is unavailable. Reopen Zshell to reconnect this terminal.' >&2
          exit 1
        fi
        exec "$zshell_cli_executable" "$@"

        """
        try writePrivate(Data(script.utf8), to: launcher, mode: 0o700)
        try writePrivate(Data((executable + "\n").utf8), to: directory.appendingPathComponent("current-executable"))
        return directory.path
    }

    static func remove(for id: UUID) {
        try? FileManager.default.removeItem(at: connectionURL(for: id))
    }

    static func preparePrivateDirectory(_ url: URL) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT, mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
                throw PTYMuxWire.errnoError("mkdir")
            }
        }
        try verifyPrivateDirectory(url)
    }

    static func verifyPrivateDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o700 else {
            throw CLIError.message("Persistent terminal state must be an owner-only directory.")
        }
    }

    static func readPrivate(_ url: URL, maximumBytes: Int = PTYMuxConstants.maximumFrameBytes) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw PTYMuxWire.errnoError("open") }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & 0o777 == 0o600, metadata.st_uid == geteuid(),
              metadata.st_nlink == 1, metadata.st_size > 0,
              metadata.st_size <= maximumBytes else {
            throw CLIError.message("Persistent terminal connection must be a private 0600 file.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { return data }
            else if errno != EINTR { throw PTYMuxWire.errnoError("read") }
        }
        throw CLIError.message("Persistent terminal connection exceeds its size limit.")
    }

    static func writePrivate(_ data: Data, to url: URL, mode: mode_t = 0o600, durable: Bool = false) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw PTYMuxWire.errnoError("open") }
        defer { Darwin.close(descriptor); unlink(temporary.path) }
        try PTYMuxWire.writeAll(data, to: descriptor)
        if durable, fsync(descriptor) != 0 { throw PTYMuxWire.errnoError("fsync") }
        guard fchmod(descriptor, mode) == 0, rename(temporary.path, url.path) == 0 else {
            throw PTYMuxWire.errnoError("rename")
        }
    }
}
