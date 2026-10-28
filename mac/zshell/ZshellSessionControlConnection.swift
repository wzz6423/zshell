import Darwin
import Foundation

/// A separate owner-only capability for explicit session control from an
/// external terminal. It never grants pane reads, input, or agent automation.
nonisolated struct ZshellSessionControlConnection: Sendable {
    struct Manifest: Codable, Sendable {
        let version: Int
        let processID: pid_t
        let bundleIdentifier: String
        let socketPath: String
        let token: String
    }

    static let callerID = "external-session-control"
    let manifest: Manifest

    static var defaultBundleIdentifier: String {
        if let identifier = Bundle.main.bundleIdentifier { return identifier }
        #if DEBUG
        return "sh.zshell.dev"
        #else
        return "sh.zshell"
        #endif
    }

    static var directoryURL: URL {
        #if DEBUG
        let configuration = "zshell-dev"
        #else
        let configuration = "zshell"
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/\(configuration)/session-control", isDirectory: true)
            .appendingPathComponent(defaultBundleIdentifier, isDirectory: true)
    }

    static func publish(socketPath: String, token: String) throws -> URL {
        let fm = FileManager.default
        let parent = directoryURL.deletingLastPathComponent()
        let configuration = parent.deletingLastPathComponent()
        try fm.createDirectory(at: configuration, withIntermediateDirectories: true)
        for url in [parent, directoryURL] {
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
            }
            try validate(url.path, type: S_IFDIR, permissions: 0o700)
        }
        let manifest = Manifest(version: 1, processID: getpid(), bundleIdentifier: defaultBundleIdentifier,
                                socketPath: socketPath, token: token)
        let url = directoryURL.appendingPathComponent("connection-\(getpid())-\(UUID().uuidString).json")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw connectionError("Could not publish Zshell session control.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: JSONEncoder().encode(manifest))
            try file.close()
            return url
        } catch {
            try? file.close()
            try? fm.removeItem(at: url)
            throw error
        }
    }

    init(connectionURL: URL? = nil) throws {
        if let connectionURL {
            manifest = try Self.load(connectionURL)
            return
        }
        try Self.validate(Self.directoryURL.path, type: S_IFDIR, permissions: 0o700)
        let urls = try FileManager.default.contentsOfDirectory(at: Self.directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("connection-") && $0.pathExtension == "json" }
        let live = urls.compactMap { try? Self.load($0) }
            .filter { $0.bundleIdentifier == Self.defaultBundleIdentifier }
        guard live.count == 1, let manifest = live.first else {
            throw Self.connectionError(live.isEmpty
                ? "No running Zshell session controller was found. Open Zshell first."
                : "More than one Zshell instance is running. Select its owner-only connection with --connection.")
        }
        self.manifest = manifest
    }

    func request(method: String, params: [String: ZshellJSONValue], timeout: TimeInterval = 60) throws -> ZshellJSONValue {
        guard method.hasPrefix("session.") else { throw Self.connectionError("External control only supports session commands.") }
        try Self.validate(manifest.socketPath, type: S_IFSOCK, permissions: 0o600)
        let request = ZshellAutomationRequest(version: 1, id: UUID().uuidString,
                                            method: method, token: manifest.token,
                                            terminalID: Self.callerID, params: params)
        let response = try ZshellAutomationSocketServer.exchange(path: manifest.socketPath, request: request, timeout: timeout)
        guard response.id == request.id, response.version == 1 else {
            throw Self.connectionError("Zshell returned a mismatched session response.")
        }
        guard response.ok, let result = response.result else {
            throw Self.connectionError("\(response.error?.code ?? "session_error"): \(response.error?.message ?? "Zshell rejected the session request.")")
        }
        return result
    }

    private static func load(_ url: URL) throws -> Manifest {
        try validate(url.deletingLastPathComponent().path, type: S_IFDIR, permissions: 0o700)
        try validate(url.path, type: S_IFREG, permissions: 0o600)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw connectionError("Could not read the Zshell session connection.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: 16_385), data.count <= 16_384,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1, manifest.processID > 1,
              kill(manifest.processID, 0) == 0, manifest.token.utf8.count >= 32 else {
            throw connectionError("The Zshell session connection is invalid or expired.")
        }
        try validate(manifest.socketPath, type: S_IFSOCK, permissions: 0o600)
        return manifest
    }

    private static func validate(_ path: String, type: mode_t, permissions: mode_t) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == type,
              info.st_mode & 0o777 == permissions else {
            throw connectionError("Zshell session control requires owner-only files and directories.")
        }
    }

    private static func connectionError(_ message: String) -> CLIError { .message(message) }
}
