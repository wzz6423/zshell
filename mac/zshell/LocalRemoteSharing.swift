import Combine
import Darwin
import Foundation

nonisolated struct LocalRemoteSharingEndpoint: Sendable {
    let address: String
    let port: Int
}

@MainActor
final class LocalRemoteSharing: ObservableObject {
    static let shared = LocalRemoteSharing()
    @Published private(set) var endpoint: LocalRemoteSharingEndpoint?
    @Published private(set) var message: String?
    private var process: Process?
    private var logHandle: FileHandle?
    private var generation: UUID?
    private let stateURL: URL
    var isRunning: Bool { process != nil || generation != nil }

    init(stateURL: URL? = nil) {
        self.stateURL = stateURL ?? AppSettings.configURL.deletingLastPathComponent().appendingPathComponent("shared-host", isDirectory: true)
    }

    func start(port: Int, allowedUsers: [String], executable: URL? = RemoteServerInstaller.bundledExecutable) async throws {
        guard process == nil, generation == nil else { return }
        guard (1...65_535).contains(port), let executable else {
            throw RemoteHostError.message(String(localized: "The bundled remote server is unavailable."))
        }
        guard allowedUsers.allSatisfy({ !$0.isEmpty && $0 != "*" && !$0.contains(where: \.isWhitespace) }) else {
            throw RemoteHostError.message(String(localized: "Allow users by their exact Tailscale login."))
        }
        let token = UUID()
        generation = token
        message = nil
        do {
            let (address, environment) = try await Task.detached(priority: .userInitiated) {
                let address = try Self.tailscaleAddress()
                let environment = SSHAgentEnvironment.shared.resolvedEnvironment().filter { !$0.key.hasPrefix("ZSHELL_") }
                return (address, environment)
            }.value
            guard generation == token else { return }
            try Self.prepareState(stateURL)
            let logURL = stateURL.appendingPathComponent("sharing.log")
            let descriptor = Darwin.open(logURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw PTYMuxWire.errnoError("open sharing.log") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_mode & 0o777 == 0o600 else {
                throw RemoteHostError.message(String(localized: "The sharing log must be a private regular file."))
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["serve", "--state", stateURL.path, "--listen", "tailscale://:\(port)"]
                + allowedUsers.flatMap { ["--allow-user", $0] }
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = handle
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.process === process else { return }
                    self.process = nil
                    self.endpoint = nil
                    self.generation = nil
                    self.logHandle = nil
                    self.message = String(localized: "Sharing stopped. Status: \(process.terminationStatus).")
                }
            }
            try process.run()
            self.process = process
            logHandle = handle
            let state = stateURL
            let processID = process.processIdentifier
            let result = try await Task.detached(priority: .utility) {
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    let result = try BoundedProcessRunner.run(executableURL: executable,
                        arguments: ["status", "--state", state.path], timeout: 1, outputLimit: 4096)
                    if result.terminationStatus == 0, !result.timedOut,
                       let status = try? JSONSerialization.jsonObject(with: Data(result.output.stdout.utf8)) as? [String: Any],
                       (status["daemonPID"] as? NSNumber)?.int32Value == processID { return true }
                    try await Task.sleep(for: .milliseconds(50))
                }
                return false
            }.value
            guard generation == token, process.isRunning, result else {
                throw RemoteHostError.message(String(localized: "Sharing could not start. Check the sharing log and Tailscale connection."))
            }
            endpoint = LocalRemoteSharingEndpoint(address: address, port: port)
        } catch {
            stop()
            message = error.localizedDescription
            throw error
        }
    }

    @discardableResult func stop() -> Task<Void, Never>? {
        generation = nil
        endpoint = nil
        guard let process else { return nil }
        self.process = nil
        logHandle = nil
        let state = stateURL
        let executable = process.executableURL
        let processID = process.processIdentifier
        return Task.detached(priority: .utility) {
            if let executable {
                let status = try? BoundedProcessRunner.run(executableURL: executable, arguments: ["status", "--state", state.path], timeout: 1, outputLimit: 4096)
                if let status, status.terminationStatus == 0,
                   let value = try? JSONSerialization.jsonObject(with: Data(status.output.stdout.utf8)) as? [String: Any],
                   (value["daemonPID"] as? NSNumber)?.int32Value == processID {
                    _ = try? BoundedProcessRunner.run(executableURL: executable, arguments: ["stop", "--state", state.path], timeout: 2, outputLimit: 4096)
                }
            }
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    private nonisolated static func prepareState(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700 else {
            throw RemoteHostError.message(String(localized: "Sharing requires a private state directory."))
        }
    }

    private nonisolated static func tailscaleAddress() throws -> String {
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/tailscale" }
            + ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw RemoteHostError.message(String(localized: "Install and connect Tailscale to share this Mac."))
        }
        let result = try BoundedProcessRunner.run(executableURL: URL(fileURLWithPath: path), arguments: ["status", "--json"],
            timeout: 5, outputLimit: 2 * 1024 * 1024, environment: ["TAILSCALE_BE_CLI": "1"])
        guard !result.timedOut, result.terminationStatus == 0, !result.output.wasTruncated,
              let status = try JSONSerialization.jsonObject(with: Data(result.output.stdout.utf8)) as? [String: Any],
              status["BackendState"] as? String == "Running", let own = status["Self"] as? [String: Any],
              let address = (own["TailscaleIPs"] as? [String])?.first(where: RemoteHostTransport.isTailnetAddress) else {
            throw RemoteHostError.message(String(localized: "Tailscale is not connected."))
        }
        return address
    }
}
