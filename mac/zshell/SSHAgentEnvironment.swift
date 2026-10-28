import Darwin
import Foundation

/// Dock launches inherit launchd's agent instead of the agent selected by
/// interactive dotfiles. Only that socket is imported from the login shell.
nonisolated final class SSHAgentEnvironment: @unchecked Sendable {
    static let shared = SSHAgentEnvironment()
    static let resolvedVariable = "ZSHELL_SSH_AGENT_RESOLVED"
    static let timeout: TimeInterval = 3
    static let waitLimit: TimeInterval = 6
    static let outputLimit = 32_768

    private let environment: [String: String]
    private let shellPath: String
    private let probeTimeout: TimeInterval
    private let condition = NSCondition()
    private var started = false
    private var finished = false
    private var socketPath: String?
    private var cacheURL: URL?
    private var stopped = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         shellPath: String = SSHAgentEnvironment.loginShell(),
         timeout: TimeInterval = SSHAgentEnvironment.timeout) {
        self.environment = environment
        self.shellPath = shellPath
        probeTimeout = timeout
    }

    func warmUp() {
        condition.lock()
        defer { condition.unlock() }
        guard !started, !stopped else { return }
        started = true
        let inherited = Self.validSocket(environment["SSH_AUTH_SOCK"])
        if environment[Self.resolvedVariable] == "1"
            || (environment["TERM"].flatMap { $0.isEmpty ? nil : $0 } != nil && inherited != nil) {
            socketPath = inherited
            finished = true
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshell-ssh-agent-\(UUID().uuidString)", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])) != nil {
            cacheURL = directory.appendingPathComponent("socket")
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            let resolved = Self.probe(shellPath: shellPath, environment: environment,
                                      timeout: probeTimeout) ?? inherited
            condition.lock()
            defer { condition.unlock() }
            socketPath = resolved
            if !stopped, let cacheURL {
                do {
                    // An empty, atomically published record also completes a
                    // failed probe so reconnects never rerun startup files.
                    try Data(((resolved ?? "") + "\n").utf8).write(to: cacheURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
                } catch {
                    try? FileManager.default.removeItem(at: cacheURL)
                }
            }
            finished = true
            condition.broadcast()
        }
    }

    /// Call from the existing background SSH operations or a relay process.
    func resolvedEnvironment(_ inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        warmUp()
        condition.lock()
        let deadline = Date().addingTimeInterval(Self.waitLimit)
        while !finished, !stopped, condition.wait(until: deadline) {}
        let resolved = Self.validSocket(socketPath)
        condition.unlock()
        var result = inherited
        if let resolved { result["SSH_AUTH_SOCK"] = resolved }
        else if Self.validSocket(result["SSH_AUTH_SOCK"]) == nil { result.removeValue(forKey: "SSH_AUTH_SOCK") }
        result[Self.resolvedVariable] = "1"
        return result
    }

    /// Surface creation remains synchronous. A PTY child can wait briefly for
    /// the same result without holding the app's main thread during dotfiles.
    func terminalLaunchScript(_ script: String) -> String {
        warmUp()
        condition.lock()
        let finished = self.finished
        let socket = Self.validSocket(socketPath)
        let cache = cacheURL
        condition.unlock()
        var setup: [String] = []
        if finished {
            if let socket { setup.append("export SSH_AUTH_SOCK=\(SSHEndpoint.shellWord(socket))") }
        } else if let cache {
            let path = SSHEndpoint.shellWord(cache.path)
            setup.append("ZSHELL_AGENT_WAIT=0; while [ ! -f \(path) ] && [ \"$ZSHELL_AGENT_WAIT\" -lt 60 ]; do /bin/sleep 0.1; ZSHELL_AGENT_WAIT=$((ZSHELL_AGENT_WAIT + 1)); done")
            setup.append("if [ -f \(path) ] && IFS= read -r ZSHELL_AGENT_SOCKET < \(path) && [ -S \"$ZSHELL_AGENT_SOCKET\" ]; then export SSH_AUTH_SOCK=\"$ZSHELL_AGENT_SOCKET\"; fi")
        }
        setup.append("if [ -n \"${SSH_AUTH_SOCK:-}\" ] && [ ! -S \"$SSH_AUTH_SOCK\" ]; then unset SSH_AUTH_SOCK; fi")
        setup.append("unset ZSHELL_AGENT_WAIT ZSHELL_AGENT_SOCKET; export \(Self.resolvedVariable)=1")
        return setup.joined(separator: "; ") + "; " + script
    }

    func cleanup() {
        condition.lock()
        defer { condition.unlock() }
        stopped = true
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        cacheURL = nil
        condition.broadcast()
    }

    deinit { cleanup() }

    static func validSocket(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        var metadata = stat()
        guard stat(path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { return nil }
        return path
    }

    static func loginShell() -> String {
        var user = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let path = buffer.withUnsafeMutableBufferPointer { storage -> String? in
            guard getpwuid_r(getuid(), &user, storage.baseAddress, storage.count, &result) == 0,
                  result != nil, let shell = user.pw_shell else { return nil }
            return String(cString: shell)
        }
        if let path, !path.isEmpty { return path }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static func probe(shellPath: String, environment: [String: String], timeout: TimeInterval) -> String? {
        let shell = (shellPath as NSString).lastPathComponent
        guard ["sh", "bash", "zsh", "ksh", "dash", "fish"].contains(shell),
              shellPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shellPath) else { return nil }
        let marker = "ZSHELL_AGENT_\(UUID().uuidString)"
        let command: String
        if shell == "fish" {
            command = "if set -q SSH_AUTH_SOCK; printf '\\000%s\\000%s\\000' '\(marker)' \"$SSH_AUTH_SOCK\"; "
                + "else; printf '\\000%s\\000%s\\000' '\(marker)' ''; end"
        } else {
            command = "printf '\\000%s\\000%s\\000' '\(marker)' \"${SSH_AUTH_SOCK:-}\""
        }
        var probeEnvironment = environment
        probeEnvironment.removeValue(forKey: "ZSHELL_CLI_STATE")
        probeEnvironment.removeValue(forKey: "ZSHELL_CLI_TOKEN")
        guard let result = try? BoundedProcessRunner.run(executableURL: URL(fileURLWithPath: shellPath),
                                                        arguments: ["-l", "-i", "-c", command],
                                                        timeout: timeout, outputLimit: outputLimit,
                                                        environment: probeEnvironment),
              !result.timedOut, result.terminationStatus == 0, !result.output.wasTruncated else { return nil }
        let fields = result.output.stdout.components(separatedBy: "\0")
        guard let index = fields.firstIndex(of: marker), index + 1 < fields.count else { return nil }
        return validSocket(fields[index + 1])
    }
}
