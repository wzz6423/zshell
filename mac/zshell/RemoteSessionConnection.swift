import Combine
import Darwin
import Foundation

nonisolated struct RemoteRelayConfiguration: Codable {
    var host: RemoteHost
    let project: String
    let sessionID: UUID
    let clientID: UUID
    let createIfMissing: Bool
    let command: [String]?
    let environment: [String: String]
    let initializationCommand: String?
}

nonisolated struct RemoteRelayControl: Codable {
    let sequence: UInt64
    let action: String
}

nonisolated struct RemoteRelayStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case connecting, connected, detached, failed, exited }
    var state: State
    var message: String?
    var relayPID: Int32?
    var remotePID: Int32?
    var exitCode: Int32?
    var clients = 0
    var activeClientID: String?
    var agentStatus: RemoteAgentStatus?
    var conversation: ZshellJSONValue?
    var sessionCommand: [String]?

    var connectionState: RemoteConnectionState {
        switch state {
        case .connecting: .checking
        case .connected: .connected
        case .detached: .failed(String(localized: "Remote session detached"))
        case .failed: .failed(message ?? String(localized: "Connection failed"))
        case .exited: .failed(String(localized: "Exited with status \(exitCode ?? 0)"))
        }
    }

    var label: String {
        switch state {
        case .connecting: String(localized: "Connecting…")
        case .connected: String(localized: "Connected")
        case .detached: String(localized: "Detached")
        case .failed: String(localized: "Reconnecting…")
        case .exited: String(localized: "Exited with status \(exitCode ?? 0)")
        }
    }
}

@MainActor
final class RemoteSessionConnection: ObservableObject {
    let sessionID: UUID
    let clientID: UUID
    let directoryURL: URL
    let configurationURL: URL
    let statusURL: URL
    private let controlURL: URL
    private var configuration: RemoteRelayConfiguration
    private var controlSequence: UInt64 = 0
    private var timer: Timer?
    private var statusReadTask: Task<RemoteRelayStatus?, Never>?
    private var monitoringGeneration: UInt64 = 0
    private(set) var pasteGeneration: UInt64 = 0
    @Published private(set) var status = RemoteRelayStatus(state: .connecting)

    var host: RemoteHost { configuration.host }
    var projectDirectory: String { configuration.project }
    var command: [String]? { configuration.command }
    var initializationCommand: String? { configuration.initializationCommand }
    var isActiveClient: Bool { status.activeClientID == clientID.uuidString.lowercased() }
    var launchArguments: [String] {
        [Bundle.main.executableURL?.path ?? CommandLine.arguments[0], RemoteSessionRelay.argument, configurationURL.path]
    }

    init(host: RemoteHost, directory: String, sessionID: UUID, createIfMissing: Bool,
         command: [String]?, launchSettings: TerminalLaunchSettings) throws {
        self.sessionID = sessionID
        clientID = UUID()
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("zshell-remote-\(UUID().uuidString)", isDirectory: true)
        configurationURL = directoryURL.appendingPathComponent("configuration.json")
        statusURL = directoryURL.appendingPathComponent("status.json")
        controlURL = directoryURL.appendingPathComponent("control.json")
        configuration = RemoteRelayConfiguration(
            host: host, project: directory, sessionID: sessionID, clientID: clientID,
            createIfMissing: createIfMissing, command: command,
            environment: launchSettings.environment.filter { !TerminalLaunchSettings.isProtectedEnvironmentVariable($0.key) },
            initializationCommand: command == nil ? launchSettings.initializationCommand : nil
        )
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Self.writePrivate(configuration, to: configurationURL)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            assumeMainActor { self.readStatus() }
        }
    }

    deinit {
        timer?.invalidate()
        statusReadTask?.cancel()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func reconnect() { pasteGeneration &+= 1; sendControl("reconnect") }
    func detach() { pasteGeneration &+= 1; sendControl("detach") }
    func takeControl() { sendControl("claim") }
    func markAgentSeen() { sendControl("agentSeen") }
    func stopMonitoring() {
        pasteGeneration &+= 1
        timer?.invalidate()
        timer = nil
        monitoringGeneration &+= 1
        statusReadTask?.cancel()
        statusReadTask = nil
    }

    func update(host: RemoteHost) throws {
        configuration.host = host
        try Self.writePrivate(configuration, to: configurationURL)
        reconnect()
    }

    private func sendControl(_ action: String) {
        controlSequence &+= 1
        do { try Self.writePrivate(RemoteRelayControl(sequence: controlSequence, action: action), to: controlURL) }
        catch { status = RemoteRelayStatus(state: .failed, message: error.localizedDescription) }
    }

    private func readStatus() {
        guard timer != nil, statusReadTask == nil else { return }
        let url = statusURL
        let generation = monitoringGeneration
        let task = Task.detached(priority: .utility) { Self.readStatus(from: url) }
        statusReadTask = task
        Task { @MainActor [weak self] in
            let current = await task.value
            guard let self, self.timer != nil, self.monitoringGeneration == generation else { return }
            self.statusReadTask = nil
            if let current, current != self.status {
                if current.state != self.status.state || current.activeClientID != self.status.activeClientID {
                    self.pasteGeneration &+= 1
                }
                self.status = current
            }
            if current?.state == .exited { self.stopMonitoring() }
        }
    }

    nonisolated static func readStatus(from url: URL) -> RemoteRelayStatus? {
        let limit = 64 * 1024
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size >= 0, metadata.st_size <= limit, !Task.isCancelled else { return nil }
        // Bound the read as well: the file can grow after fstat.
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let bytes = try? handle.read(upToCount: limit + 1), bytes.count <= limit,
              !Task.isCancelled else { return nil }
        return try? JSONDecoder().decode(RemoteRelayStatus.self, from: bytes)
    }

    nonisolated static func writePrivate<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
