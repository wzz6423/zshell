//
//  RemoteSSH.swift
//  zshell
//

import Darwin
import Foundation

struct SSHEndpoint: Codable, Equatable, Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case missingHost
        case invalidHost
        case invalidUser
        case invalidPort

        var errorDescription: String? {
            switch self {
            case .missingHost:
                String(localized: "Enter a host.")
            case .invalidHost:
                String(localized: "The host can’t begin with “-” or contain whitespace.")
            case .invalidUser:
                String(localized: "The user can’t contain “@” or whitespace.")
            case .invalidPort:
                String(localized: "Enter a port from 1 to 65535.")
            }
        }
    }

    let host: String
    let user: String?
    let port: Int?

    init(host: String, user: String? = nil, port: Int? = nil) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw ValidationError.missingHost }
        guard !host.hasPrefix("-"), !host.contains(where: \Character.isWhitespace) else {
            throw ValidationError.invalidHost
        }
        let user = user?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let user, !user.isEmpty,
           user.contains("@") || user.contains(where: \Character.isWhitespace) {
            throw ValidationError.invalidUser
        }
        if let port, !(1...65_535).contains(port) {
            throw ValidationError.invalidPort
        }
        self.host = host
        self.user = user.flatMap { $0.isEmpty ? nil : $0 }
        self.port = port
    }

    var destination: String {
        user.map { "\($0)@\(host)" } ?? host
    }

    func terminalArguments(remoteDirectory: String?) -> [String] {
        var arguments = connectionArguments + [
            "-o", "BatchMode=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "ConnectTimeout=10",
        ]
        arguments.append(contentsOf: ["-t", destination])
        if let remoteDirectory {
            arguments.append(
                "cd -- \(Self.shellWord(remoteDirectory)) && exec \"${SHELL:-/bin/sh}\" -l"
            )
        }
        return arguments
    }

    func transportArguments(connectTimeout: TimeInterval, command: [String]) -> [String] {
        let timeoutSeconds = max(1, Int(connectTimeout.rounded(.up)))
        return connectionArguments + [
            "-o", "BatchMode=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectionAttempts=1",
            "-o", "ConnectTimeout=\(timeoutSeconds)",
            "-T",
            destination,
            command.map(Self.shellWord).joined(separator: " "),
        ]
    }

    private var connectionArguments: [String] {
        guard let port else { return [] }
        return ["-p", String(port)]
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quotes one word of a remote shell command. A leading tilde stays
    /// unquoted so the remote shell still expands `~` and `~user`; the rest
    /// of the word is single-quoted. Paths without a tilde are quoted whole.
    static func shellWord(_ value: String) -> String {
        guard value.hasPrefix("~") else { return shellQuote(value) }
        if value == "~" { return value }
        let tildePrefix: String?
        if value.hasPrefix("~/") {
            tildePrefix = "~/"
        } else if let slash = value.firstIndex(of: "/") {
            let user = value[..<slash]
            // Only a plain user name may stay unquoted; anything odd falls
            // back to a fully quoted, unexpanded word.
            let isPlainName = !user.isEmpty && user.dropFirst().allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
            }
            tildePrefix = isPlainName ? String(user) + "/" : nil
        } else {
            tildePrefix = nil
        }
        guard let tildePrefix else { return shellQuote(value) }
        return tildePrefix + shellQuote(String(value.dropFirst(tildePrefix.count)))
    }

    /// One parsed row of a remote directory listing.
    struct DirectoryEntry: Equatable, Sendable {
        let name: String
        let isDirectory: Bool
    }

    /// Parses `ls -1Ap` output: one entry per line, directories suffixed
    /// with `/`. File names containing newlines are outside this format and
    /// will split; `ls` cannot delimit them portably.
    static func parseDirectoryListing(_ output: String) -> [DirectoryEntry] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            var name = String(line)
            guard !name.isEmpty else { return nil }
            var isDirectory = false
            if name.hasSuffix("/") {
                isDirectory = true
                name.removeLast()
            }
            // The local tree hides `.git` too; a remote listing should read
            // the same way.
            guard name != ".git" else { return nil }
            return DirectoryEntry(name: name, isDirectory: isDirectory)
        }
    }
}

/// Result of the connectivity probe taken when an SSH project is created.
enum RemoteConnectionState: Equatable {
    case checking
    case connected
    case failed(String)
}

enum ProjectLocation: Codable, Equatable, Sendable {
    case local
    case ssh(endpoint: SSHEndpoint, remoteDirectory: String?)

    var isRemote: Bool {
        if case .ssh = self { return true }
        return false
    }
}

struct BoundedProcessOutput: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let wasTruncated: Bool
}

struct BoundedProcessResult: Equatable, Sendable {
    let terminationStatus: Int32
    let timedOut: Bool
    let output: BoundedProcessOutput
}

struct BoundedProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int,
        environment: [String: String]? = nil
    ) throws -> BoundedProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let collector = BoundedOutputCollector(limit: max(0, outputLimit))
        let readers = DispatchGroup()
        let termination = DispatchSemaphore(value: 0)

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = environment
        process.terminationHandler = { _ in termination.signal() }

        try process.run()
        drain(stdoutPipe.fileHandleForReading, stream: .stdout, into: collector, group: readers)
        drain(stderrPipe.fileHandleForReading, stream: .stderr, into: collector, group: readers)

        let deadline = DispatchTime.now() + max(0, timeout)
        let timedOut = termination.wait(timeout: deadline) == .timedOut
        if timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 1)
            }
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + 1)
        }
        if readers.wait(timeout: .now() + 1) == .timedOut {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = readers.wait(timeout: .now() + 0.25)
        }

        return BoundedProcessResult(
            terminationStatus: process.terminationStatus,
            timedOut: timedOut,
            output: collector.output
        )
    }

    private static func drain(
        _ handle: FileHandle,
        stream: BoundedOutputCollector.Stream,
        into collector: BoundedOutputCollector,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while let data = try? handle.read(upToCount: 8_192), !data.isEmpty {
                collector.append(data, to: stream)
            }
        }
    }
}

struct OpenSSHTransport {
    enum TransportError: LocalizedError {
        case timedOut(BoundedProcessOutput)
        case failed(status: Int32, output: BoundedProcessOutput)

        var errorDescription: String? {
            switch self {
            case .timedOut:
                String(localized: "The SSH command timed out.")
            case .failed:
                String(localized: "The SSH command failed.")
            }
        }
    }

    var executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    var timeout: TimeInterval = 10
    var outputLimit = 1_048_576

    func run(
        endpoint: SSHEndpoint,
        command: [String],
        additionalEnvironment: [String: String] = [:]
    ) throws -> BoundedProcessOutput {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        for (key, value) in additionalEnvironment {
            environment[key] = value
        }
        let result = try BoundedProcessRunner.run(
            executableURL: executableURL,
            arguments: endpoint.transportArguments(
                connectTimeout: timeout,
                command: command
            ),
            timeout: timeout,
            outputLimit: outputLimit,
            environment: environment
        )
        if result.timedOut { throw TransportError.timedOut(result.output) }
        guard result.terminationStatus == 0 else {
            throw TransportError.failed(
                status: result.terminationStatus,
                output: result.output
            )
        }
        return result.output
    }

    /// Lists `directory` on the remote host with `ls -1Ap`. GNU ls escapes
    /// or quotes names by default since coreutils 8.25, which would corrupt
    /// the parsed listing, so `QUOTING_STYLE=literal` is requested; BSD and
    /// BusyBox ls already print literal names and ignore the variable.
    func listDirectory(
        endpoint: SSHEndpoint, directory: String
    ) throws -> [SSHEndpoint.DirectoryEntry] {
        let output = try run(
            endpoint: endpoint,
            command: ["ls", "-1Ap", "--", directory],
            additionalEnvironment: ["QUOTING_STYLE": "literal"]
        )
        return SSHEndpoint.parseDirectoryListing(output.stdout)
    }
}

private final class BoundedOutputCollector: @unchecked Sendable {
    enum Stream {
        case stdout
        case stderr
    }

    private let lock = NSLock()
    private var remaining: Int
    private var stdout = Data()
    private var stderr = Data()
    private var truncated = false

    init(limit: Int) {
        remaining = limit
    }

    func append(_ data: Data, to stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        let count = min(remaining, data.count)
        if count < data.count { truncated = true }
        guard count > 0 else { return }
        switch stream {
        case .stdout:
            stdout.append(data.prefix(count))
        case .stderr:
            stderr.append(data.prefix(count))
        }
        remaining -= count
    }

    var output: BoundedProcessOutput {
        lock.lock()
        defer { lock.unlock() }
        return BoundedProcessOutput(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            wasTruncated: truncated
        )
    }
}
