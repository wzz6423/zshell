import AppKit
import Darwin
import Foundation

/// A renderer-independent handle. Foreground polling stays off the main
/// thread; callers only read the last kernel-backed daemon observation.
final class PersistentPTY: @unchecked Sendable {
    let id: UUID
    let shellPID: pid_t
    let bindingToken: String
    let launchDirectoryURL: URL?
    let workingDirectory: String
    private let lock = NSLock()
    private var foreground: pid_t
    private var monitor: DispatchSourceTimer?

    private init?(result: ZshellJSONValue) {
        guard let info = result.objectValue,
              let text = info["id"]?.stringValue, let id = UUID(uuidString: text),
              let pid = info["pid"]?.intValue, pid > 1,
              info["running"]?.boolValue == true else { return nil }
        self.id = id
        shellPID = pid_t(pid)
        foreground = pid_t(info["foregroundPid"]?.intValue ?? pid)
        bindingToken = info["bindingToken"]?.stringValue ?? ""
        launchDirectoryURL = info["launchDirectory"]?.stringValue.map { URL(fileURLWithPath: $0) }
        workingDirectory = info["workingDirectory"]?.stringValue ?? NSHomeDirectory()
    }

    var foregroundPID: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return foreground > 0 ? foreground : nil
    }

    static func reconnect(id: UUID) -> PersistentPTY? {
        guard let response = try? PTYMuxCommandLine.exchange(
            method: "get", params: ["id": .string(id.uuidString)], timeout: 0.2
        ), let result = response.result else { return nil }
        return Self(result: result)
    }

    static func create(id: UUID, launch: TerminalLaunch, launchDirectoryURL: URL?, theme: ZshellTheme) throws -> PersistentPTY {
        try PTYMuxCommandLine.startDaemonIfNeeded()
        var theme = theme
        let encodedTheme = withUnsafeBytes(of: &theme) { Data($0).base64EncodedString() }
        var params: [String: ZshellJSONValue] = [
            "id": .string(id.uuidString),
            "workingDirectory": .string(launch.workingDirectory),
            "command": .array(([launch.program] + launch.arguments).map(ZshellJSONValue.string)),
            "environment": .object(launch.environment.mapValues(ZshellJSONValue.string)),
            "executable": .string(executablePath),
            "theme": .string(encodedTheme),
        ]
        if let launchDirectoryURL { params["launchDirectory"] = .string(launchDirectoryURL.path) }
        let response = try PTYMuxCommandLine.exchange(method: "create", params: params)
        guard let result = response.result, let pty = Self(result: result) else {
            throw PTYMuxError.message("Could not create persistent PTY.")
        }
        return pty
    }

    static var executablePath: String {
        Bundle.main.executableURL?.path
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    func relayLaunch(from launch: TerminalLaunch) -> TerminalLaunch {
        let command = "exec \(TerminalSession.shellQuote(Self.executablePath)) \(PTYMuxCommandLine.relayArgument) \(id.uuidString)"
        return TerminalLaunch(
            program: Self.executablePath, arguments: [PTYMuxCommandLine.relayArgument, id.uuidString],
            commandLine: TerminalSession.ghosttyCommandLine(for: command), interactiveShell: launch.interactiveShell,
            workingDirectory: launch.workingDirectory,
            environment: launch.environment,
            foregroundProcessProvider: { [weak self] in self?.foregroundPID }
        )
    }

    func startMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sh.zshell.pty-mux.foreground.\(id)"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(350), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let response = try? PTYMuxCommandLine.exchange(
                method: "get", params: ["id": .string(self.id.uuidString)], timeout: 0.2
            ), let value = response.result?.objectValue?["foregroundPid"]?.intValue else { return }
            self.lock.lock()
            self.foreground = pid_t(value)
            self.lock.unlock()
        }
        monitor = timer
        timer.resume()
    }

    func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }

    func terminate() {
        stopMonitoring()
        _ = try? PTYMuxCommandLine.exchange(method: "terminate", params: ["id": .string(id.uuidString)])
        PersistentCLIConnection.remove(for: id)
    }

    func updateTheme(_ theme: ZshellTheme) {
        var theme = theme
        let encoded = withUnsafeBytes(of: &theme) { Data($0).base64EncodedString() }
        DispatchQueue.global(qos: .utility).async { [id] in
            _ = try? PTYMuxCommandLine.exchange(method: "theme", params: [
                "id": .string(id.uuidString), "theme": .string(encoded),
            ])
        }
    }

    deinit { monitor?.cancel() }
}
