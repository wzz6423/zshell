import CryptoKit
import Foundation

nonisolated struct RemoteServerVersion: Codable, Equatable, Sendable {
    let version: String
    let protocolVersion: Int
    let platform: String
    let architecture: String
    static let supportedVersion = "0.1.0"
}

nonisolated struct RemoteServerTarget: Equatable, Sendable {
    let platform: String
    let architecture: String
    let installed: RemoteServerVersion?

    var description: String { "\(platform) \(architecture)" }
}

nonisolated enum RemoteServerInstaller {
    static let maximumBinaryBytes = 128 * 1024 * 1024

    static var bundledExecutable: URL? {
        guard let url = Bundle.main.url(forResource: "zshell-server", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    static func inspect(host: RemoteHost) throws -> RemoteServerTarget {
        let output = try run(host: host, script: """
            printf 'ZSHELL_TARGET:%s\\n' "$(uname -s)"
            printf 'ZSHELL_ARCH:%s\\n' "$(uname -m)"
            if [ -x \(SSHEndpoint.shellWord(host.serverPath)) ]; then \(SSHEndpoint.shellWord(host.serverPath)) --version --json; fi
            exit 0
            """).stdout
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let rawPlatform = lines.first(where: { $0.hasPrefix("ZSHELL_TARGET:") })?.dropFirst(14),
              let rawArchitecture = lines.first(where: { $0.hasPrefix("ZSHELL_ARCH:") })?.dropFirst(12),
              let platform = normalizePlatform(String(rawPlatform)), let architecture = normalizeArchitecture(String(rawArchitecture)) else {
            throw RemoteHostError.message(String(localized: "The host returned an unsupported server platform."))
        }
        let installed = lines.compactMap { try? JSONDecoder().decode(RemoteServerVersion.self, from: Data($0.utf8)) }.last
        return RemoteServerTarget(platform: platform, architecture: architecture, installed: installed)
    }

    static func bundledExecutable(for target: RemoteServerTarget) -> URL? {
        guard target.platform == "macos", let url = bundledExecutable else { return nil }
        guard let result = try? BoundedProcessRunner.run(executableURL: url, arguments: ["--version", "--json"],
            timeout: 5, outputLimit: 4096), result.terminationStatus == 0, !result.timedOut,
              let version = try? JSONDecoder().decode(RemoteServerVersion.self, from: Data(result.output.stdout.utf8)),
              version.architecture == target.architecture else { return nil }
        return url
    }

    static func install(host: RemoteHost, target: RemoteServerTarget, executable: URL) throws -> RemoteServerVersion {
        let metadata = try executable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              let size = metadata.fileSize, (1...maximumBinaryBytes).contains(size) else {
            throw RemoteHostError.message(String(localized: "Choose a regular server executable smaller than 128 MiB."))
        }
        let bytes = try Data(contentsOf: executable, options: .mappedIfSafe)
        guard bytes.count == size, bytes.count <= maximumBinaryBytes else {
            throw RemoteHostError.message(String(localized: "The server executable changed while reading it."))
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let temporaryPath = host.serverPath + ".upload-" + UUID().uuidString.lowercased()
        var encoded = Data()
        for offset in stride(from: 0, to: bytes.count, by: 48 * 1024) {
            encoded.append(bytes.subdata(in: offset..<min(bytes.count, offset + 48 * 1024)).base64EncodedData())
            encoded.append(10)
        }
        defer { _ = try? run(host: host, script: cleanup(host: host, path: temporaryPath)) }
        let uploaded = try run(host: host, script: upload(host: host, temporaryPath: temporaryPath, digest: digest), input: encoded)
        guard let version = uploaded.stdout.split(whereSeparator: \.isNewline).compactMap({
            try? JSONDecoder().decode(RemoteServerVersion.self, from: Data($0.utf8))
        }).last, version.platform == target.platform, version.architecture == target.architecture,
              version.protocolVersion == 1, version.version == RemoteServerVersion.supportedVersion else {
            throw RemoteHostError.message(String(localized: "The server executable has an incompatible platform, architecture, version, or protocol."))
        }
        _ = try run(host: host, script: replace(host: host, temporaryPath: temporaryPath, digest: digest))
        return version
    }

    static func installAgentHooks(host: RemoteHost) throws {
        guard case .ssh(let endpoint) = try host.endpoint() else {
            throw RemoteHostError.message(String(localized: "Use SSH to install remote agent integrations."))
        }
        do {
            _ = try OpenSSHTransport(timeout: 30, outputLimit: 64 * 1024).run(endpoint: endpoint,
                command: host.serverCommand(["agent-hooks", "install"]))
        } catch OpenSSHTransport.TransportError.failed(_, let output) {
            let text = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteHostError.message(text.isEmpty ? String(localized: "Remote agent setup failed.") : text)
        }
    }

    private static func run(host: RemoteHost, script: String, input: Data? = nil) throws -> BoundedProcessOutput {
        guard case .ssh(let endpoint) = try host.endpoint() else {
            throw RemoteHostError.message(String(localized: "Use SSH to install or update the remote server."))
        }
        let command = ["/bin/sh", "-c", script]
        do {
            return try OpenSSHTransport(timeout: 60, outputLimit: 64 * 1024).run(
                endpoint: endpoint, command: command, standardInput: input)
        } catch OpenSSHTransport.TransportError.failed(_, let output) {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteHostError.message(message.isEmpty ? String(localized: "The remote server installation failed.") : message)
        }
    }

    private static func upload(host: RemoteHost, temporaryPath: String, digest: String) -> String {
        let path = SSHEndpoint.shellWord(temporaryPath)
        return """
            set -eu
            umask 077
            path=\(path)
            destination=\(SSHEndpoint.shellWord(host.serverPath))
            mkdir -p -- "$(dirname -- "$path")"
            [ ! -L "$destination" ] || { printf '%s\\n' 'The destination must not be a symlink.' >&2; exit 1; }
            [ ! -e "$destination" ] || [ -f "$destination" ] || { printf '%s\\n' 'The destination must be a regular file.' >&2; exit 1; }
            (set -C; : > "$path")
            while IFS= read -r line; do
                [ "${#line}" -le 65536 ] || exit 1
                if [ "$(uname -s)" = Darwin ]; then printf '%s' "$line" | base64 -D >> "$path"; else printf '%s' "$line" | base64 -d >> "$path"; fi
            done
            \(unixDigestCheck(path: "$path", digest: digest))
            chmod 700 "$path"
            "$path" --version --json
            """
    }

    private static func replace(host: RemoteHost, temporaryPath: String, digest: String) -> String {
        return """
            set -eu
            path=\(SSHEndpoint.shellWord(temporaryPath))
            destination=\(SSHEndpoint.shellWord(host.serverPath))
            [ ! -L "$destination" ]
            [ ! -e "$destination" ] || [ -f "$destination" ]
            \(unixDigestCheck(path: "$path", digest: digest))
            mv -f -- "$path" "$destination"
            """
    }

    private static func cleanup(host: RemoteHost, path: String) -> String {
        return "rm -f -- " + SSHEndpoint.shellWord(path)
    }

    private static func unixDigestCheck(path: String, digest: String) -> String {
        "if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum \"\(path)\" | cut -d ' ' -f 1); else actual=$(shasum -a 256 \"\(path)\" | cut -d ' ' -f 1); fi\n[ \"$actual\" = '\(digest)' ] || { printf '%s\\n' 'Server SHA256 mismatch.' >&2; exit 1; }"
    }

    static func normalizePlatform(_ value: String) -> String? {
        switch value.lowercased() { case "darwin", "macos": "macos"; case "linux": "linux"; default: nil }
    }

    static func normalizeArchitecture(_ value: String) -> String? {
        switch value.lowercased() { case "x86_64", "amd64": "x86_64"; case "arm64", "aarch64": "aarch64"; default: nil }
    }
}
