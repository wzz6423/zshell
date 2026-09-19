//
//  RemoteSSH.swift
//  zshell
//

import Darwin
import Foundation
import Security

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

    func terminalArguments(
        remoteDirectory: String?,
        authentication: SSHAuthentication = .agent,
        identityFile: String? = nil
    ) -> [String] {
        var arguments = connectionArguments + authentication.arguments(identityFile: identityFile) + [
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

    func transportArguments(
        connectTimeout: TimeInterval,
        command: [String],
        authentication: SSHAuthentication = .agent,
        identityFile: String? = nil
    ) -> [String] {
        let timeoutSeconds = max(1, Int(connectTimeout.rounded(.up)))
        return connectionArguments + authentication.arguments(identityFile: identityFile) + [
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

/// Metadata for one SSH authentication method. Passwords and pasted private
/// keys are deliberately absent: they are stored in the user's Keychain under
/// the saved project's UUID instead of in project or session JSON.
enum SSHAuthentication: Equatable, Sendable {
    case agent
    case password
    case privateKeyPath(String)
    case privateKeyContent

    enum Error: LocalizedError {
        case missingCredential

        var errorDescription: String? {
            switch self {
            case .missingCredential:
                String(localized: "The saved SSH credential is unavailable.")
            }
        }
    }

    private enum Kind: String, Codable {
        case agent, password, privateKeyPath, privateKeyContent
    }

    private enum CodingKeys: String, CodingKey {
        case kind, path
    }

    var requiresCredential: Bool {
        switch self {
        case .password, .privateKeyContent:
            true
        case .agent, .privateKeyPath:
            false
        }
    }

    private var configuredIdentityFile: String? {
        if case .privateKeyPath(let path) = self { return path }
        return nil
    }

    /// SSH options specific to authentication. A typed key is passed as an
    /// explicit identity and disables default identities, so a missing saved
    /// key cannot silently fall back to an unrelated SSH agent identity.
    fileprivate func arguments(identityFile: String?) -> [String] {
        switch self {
        case .agent:
            return [
                "-o", "BatchMode=yes",
                "-o", "NumberOfPasswordPrompts=0",
            ]
        case .password:
            return [
                "-o", "BatchMode=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "PasswordAuthentication=yes",
                "-o", "KbdInteractiveAuthentication=yes",
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
            ]
        case .privateKeyPath, .privateKeyContent:
            var arguments = [
                "-o", "BatchMode=yes",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "IdentitiesOnly=yes",
                "-o", "IdentityFile=none",
            ]
            if let identityFile {
                arguments.append(contentsOf: ["-i", identityFile])
            }
            return arguments
        }
    }

    func makeMaterial(
        credentialID: UUID?,
        credentialStore: SSHCredentialStore = .shared
    ) throws -> SSHAuthenticationMaterial? {
        switch self {
        case .agent, .privateKeyPath:
            return nil
        case .password:
            guard let credentialID,
                  let secret = try credentialStore.load(credentialID)
            else { throw Error.missingCredential }
            return try SSHAuthenticationMaterial(password: secret)
        case .privateKeyContent:
            guard let credentialID,
                  let secret = try credentialStore.load(credentialID)
            else { throw Error.missingCredential }
            return try SSHAuthenticationMaterial(privateKey: secret)
        }
    }

    func identityFile(material: SSHAuthenticationMaterial?) -> String? {
        material?.identityFile ?? configuredIdentityFile
    }
}

extension SSHAuthentication: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .agent:
            self = .agent
        case .password:
            self = .password
        case .privateKeyPath:
            self = .privateKeyPath(try container.decode(String.self, forKey: .path))
        case .privateKeyContent:
            self = .privateKeyContent
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .agent:
            try container.encode(Kind.agent, forKey: .kind)
        case .password:
            try container.encode(Kind.password, forKey: .kind)
        case .privateKeyPath(let path):
            try container.encode(Kind.privateKeyPath, forKey: .kind)
            try container.encode(path, forKey: .path)
        case .privateKeyContent:
            try container.encode(Kind.privateKeyContent, forKey: .kind)
        }
    }
}

/// Small Keychain wrapper for sensitive saved SSH credentials. The account is
/// an opaque project UUID, never an endpoint or a secret-derived identifier.
struct SSHCredentialStore {
    static let shared = SSHCredentialStore(
        service: (Bundle.main.bundleIdentifier ?? "sh.zshell") + ".ssh-project-authentication"
    )

    enum Error: LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            String(localized: "Couldn’t save the SSH credential in Keychain.")
        }
    }

    private let service: String

    init(service: String) {
        self.service = service
    }

    func save(_ value: String, for id: UUID) throws {
        let query = baseQuery(for: id)
        let data = Data(value.utf8)
        let addQuery = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else { throw Error.keychain(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw Error.keychain(status) }
    }

    func load(_ id: UUID) throws -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw Error.keychain(status) }
        return value
    }

    func remove(_ id: UUID) {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return }
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }
}

/// Ephemeral OpenSSH material. The owner removes its 0700 directory after the
/// command or terminal session ends; nothing here is persisted or logged.
final class SSHAuthenticationMaterial {
    let identityFile: String?
    let environment: [String: String]

    let temporaryDirectoryURL: URL
    private let lock = NSLock()
    private var isCleanedUp = false

    init(password: String) throws {
        let directory = try Self.makeDirectory()
        do {
            let passwordFile = directory.appendingPathComponent("password")
            let askpassFile = directory.appendingPathComponent("askpass")
            try Self.write(password, to: passwordFile, permissions: 0o600)
            try Self.write(
                "#!/bin/sh\nexec /bin/cat \"\(passwordFile.path)\"\n",
                to: askpassFile,
                permissions: 0o700
            )
            temporaryDirectoryURL = directory
            identityFile = nil
            environment = ["SSH_ASKPASS": askpassFile.path]
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    init(privateKey: String) throws {
        let directory = try Self.makeDirectory()
        do {
            let keyFile = directory.appendingPathComponent("identity")
            try Self.write(privateKey, to: keyFile, permissions: 0o600)
            temporaryDirectoryURL = directory
            identityFile = keyFile.path
            environment = [:]
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        lock.lock()
        defer { lock.unlock() }
        guard !isCleanedUp else { return }
        isCleanedUp = true
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshell-ssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func write(_ value: String, to file: URL, permissions: Int16) throws {
        try Data(value.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: file.path
        )
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
    case ssh(
        endpoint: SSHEndpoint,
        remoteDirectory: String?,
        authentication: SSHAuthentication = .agent,
        credentialID: UUID? = nil
    )

    var isRemote: Bool {
        if case .ssh = self { return true }
        return false
    }
}

extension ProjectLocation {
    private enum CodingKeys: String, CodingKey {
        case local, ssh
    }

    private enum SSHCodingKeys: String, CodingKey {
        case endpoint, remoteDirectory, authentication, credentialID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.local) {
            self = .local
            return
        }
        let ssh = try container.nestedContainer(keyedBy: SSHCodingKeys.self, forKey: .ssh)
        self = .ssh(
            endpoint: try ssh.decode(SSHEndpoint.self, forKey: .endpoint),
            remoteDirectory: try ssh.decodeIfPresent(String.self, forKey: .remoteDirectory),
            authentication: try ssh.decodeIfPresent(SSHAuthentication.self, forKey: .authentication)
                ?? .agent,
            credentialID: try ssh.decodeIfPresent(UUID.self, forKey: .credentialID)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .local)
        case let .ssh(endpoint, remoteDirectory, authentication, credentialID):
            var ssh = container.nestedContainer(keyedBy: SSHCodingKeys.self, forKey: .ssh)
            try ssh.encode(endpoint, forKey: .endpoint)
            try ssh.encodeIfPresent(remoteDirectory, forKey: .remoteDirectory)
            if authentication != .agent {
                try ssh.encode(authentication, forKey: .authentication)
            }
            try ssh.encodeIfPresent(credentialID, forKey: .credentialID)
        }
    }

    private enum EmptyCodingKeys: CodingKey {}
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
        authentication: SSHAuthentication = .agent,
        credentialID: UUID? = nil,
        additionalEnvironment: [String: String] = [:]
    ) throws -> BoundedProcessOutput {
        let material = try authentication.makeMaterial(credentialID: credentialID)
        defer { material?.cleanup() }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(material?.environment ?? [:], uniquingKeysWith: { _, materialValue in
            materialValue
        })
        for (key, value) in additionalEnvironment {
            environment[key] = value
        }
        if authentication == .password {
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "zshell"
        } else {
            environment["SSH_ASKPASS_REQUIRE"] = "never"
        }
        let result = try BoundedProcessRunner.run(
            executableURL: executableURL,
            arguments: endpoint.transportArguments(
                connectTimeout: timeout,
                command: command,
                authentication: authentication,
                identityFile: authentication.identityFile(material: material)
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
