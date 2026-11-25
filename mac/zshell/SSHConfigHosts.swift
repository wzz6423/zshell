import Darwin
import Foundation

nonisolated struct SSHConfigHosts: Sendable {
    struct Limits: Sendable {
        var fileBytes = 1_048_576
        var totalBytes = 4_194_304
        var files = 128
        var depth = 16
        var hosts = 4_096
        var directoryEntries = 16_384
    }

    enum Error: LocalizedError, Equatable {
        case unreadableConfiguration
        case limitExceeded

        var errorDescription: String? {
            switch self {
            case .unreadableConfiguration:
                String(localized: "Couldn’t read the SSH configuration.")
            case .limitExceeded:
                String(localized: "The SSH configuration exceeds the discovery limit.")
            }
        }
    }

    let configurationURL: URL
    let sshDirectory: URL
    var limits = Limits()
    private let requiresConfiguration: Bool

    init(configurationURL: URL, sshDirectory: URL, limits: Limits = Limits(), requiresConfiguration: Bool = true) {
        self.configurationURL = configurationURL
        self.sshDirectory = sshDirectory
        self.limits = limits
        self.requiresConfiguration = requiresConfiguration
    }

    static func configured(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Self {
        if environment["ZSHELL_SSH_CONFIG_FILE"] == "" { throw SSHEndpoint.ValidationError.invalidConfiguration }
        let arguments = try SSHEndpoint.configurationArguments(environment: environment)
        let sshDirectory = homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        if arguments.count == 2 {
            return Self(configurationURL: URL(fileURLWithPath: arguments[1]), sshDirectory: sshDirectory)
        }
        return Self(
            configurationURL: sshDirectory.appendingPathComponent("config"),
            sshDirectory: sshDirectory,
            requiresConfiguration: false
        )
    }

    func read() throws -> [String] {
        var reader = Reader(source: self)
        try reader.read(configurationURL, depth: 0, required: requiresConfiguration)
        return reader.hosts
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Reader {
        let source: SSHConfigHosts
        var hosts: [String] = []
        var seenHosts = Set<String>()
        var seenFiles = Set<FileIdentity>()
        var seenPaths = Set<String>()
        var totalBytes = 0
        var directoryEntries = 0

        mutating func read(_ url: URL, depth: Int, required: Bool = false) throws {
            try Task.checkCancellation()
            let path = url.standardizedFileURL.path
            guard !seenPaths.contains(path) else { return }
            guard depth <= source.limits.depth, seenPaths.count < source.limits.files else { throw Error.limitExceeded }
            seenPaths.insert(path)
            // Include globs may also match OpenSSH's host-key database.
            guard !["known_hosts", "known_hosts2"].contains(url.lastPathComponent) else { return }
            let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
            guard descriptor >= 0 else {
                if required { throw Error.unreadableConfiguration }
                return
            }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                if required { throw Error.unreadableConfiguration }
                return
            }
            let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
            guard !seenFiles.contains(identity) else { return }
            guard seenFiles.count < source.limits.files,
                info.st_size >= 0, info.st_size <= source.limits.fileBytes,
                let byteCount = Int(exactly: info.st_size), byteCount <= source.limits.totalBytes - totalBytes
            else { throw Error.limitExceeded }
            seenFiles.insert(identity)
            totalBytes += byteCount

            var data = Data()
            // Never read a complete private key accidentally matched by Include.
            let prefix = try readBytes(descriptor, count: min(byteCount, 512))
            let header = String(decoding: prefix, as: UTF8.self)
            if header.contains("PRIVATE KEY-----") || prefix.starts(with: Data("openssh-key-v1\0".utf8)) { return }
            data.append(prefix)
            if byteCount > prefix.count { data.append(try readBytes(descriptor, count: byteCount - prefix.count)) }
            guard let contents = String(data: data, encoding: .utf8), !contents.contains("\0") else {
                if required { throw Error.unreadableConfiguration }
                return
            }
            for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if index % 128 == 0 { try Task.checkCancellation() }
                guard let directive = Self.directive(line) else { continue }
                switch directive.keyword {
                case "host":
                    let excluded = directive.arguments.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
                    for host in directive.arguments where Self.isAlias(host) {
                        guard !excluded.contains(where: { Self.hostMatches(host, pattern: $0) }),
                            seenHosts.insert(host.lowercased()).inserted
                        else { continue }
                        guard hosts.count < source.limits.hosts else { throw Error.limitExceeded }
                        hosts.append(host)
                    }
                case "include":
                    for path in directive.arguments {
                        for includedURL in try expand(path) {
                            try read(includedURL, depth: depth + 1)
                        }
                    }
                default:
                    // Match criteria and connection options remain OpenSSH's responsibility.
                    break
                }
            }
        }

        private func readBytes(_ descriptor: Int32, count: Int) throws -> Data {
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { bytes in
                var filled = 0
                while filled < count {
                    try Task.checkCancellation()
                    let size = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: filled), min(count - filled, 65_536))
                    if size < 0, errno == EINTR { continue }
                    guard size > 0 else { throw Error.unreadableConfiguration }
                    filled += size
                }
            }
            return data
        }

        private mutating func expand(_ value: String) throws -> [URL] {
            guard !value.isEmpty, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                !value.contains("${"), !value.contains("%")
            else { return [] }
            let path: String
            if value == "~" {
                path = source.sshDirectory.deletingLastPathComponent().path
            } else if value.hasPrefix("~/") {
                path = source.sshDirectory.deletingLastPathComponent().path + "/" + value.dropFirst(2)
            } else if value.hasPrefix("~") {
                // Named homes and runtime-dependent expansions are left to OpenSSH.
                return []
            } else if value.hasPrefix("/") {
                path = value
            } else {
                // OpenSSH anchors relative includes in ~/.ssh, even with -F.
                path = source.sshDirectory.path + "/" + value
            }
            let components = path.split(separator: "/").map(String.init)
            guard components.count <= 64 else { throw Error.limitExceeded }
            var paths = ["/"]
            for component in components {
                try Task.checkCancellation()
                if !component.contains(where: { "*?[\\".contains($0) }) {
                    paths = paths.map { ($0 as NSString).appendingPathComponent(component) }
                    continue
                }
                var matches: [String] = []
                for directory in paths {
                    guard let handle = directory.withCString({ opendir($0) }) else { continue }
                    defer { closedir(handle) }
                    while let item = readdir(handle) {
                        try Task.checkCancellation()
                        directoryEntries += 1
                        guard directoryEntries <= source.limits.directoryEntries else { throw Error.limitExceeded }
                        let name = withUnsafePointer(to: &item.pointee.d_name) {
                            $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                        }
                        guard name != ".", name != "..",
                            component.withCString({ pattern in
                                name.withCString { fnmatch(pattern, $0, FNM_PERIOD) == 0 }
                            })
                        else { continue }
                        guard matches.count < source.limits.files else { throw Error.limitExceeded }
                        matches.append((directory as NSString).appendingPathComponent(name))
                    }
                }
                paths = matches.sorted()
            }
            return paths.map { URL(fileURLWithPath: $0) }
        }

        private static func isAlias(_ value: String) -> Bool {
            !value.isEmpty && !value.hasPrefix("-")
                && value.utf8.allSatisfy {
                    (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0)
                        || $0 == 45 || $0 == 46 || $0 == 95
                }
        }

        private static func hostMatches(_ host: String, pattern: String) -> Bool {
            // Host patterns support only '*' and '?', unlike file Include globs.
            let value = host.lowercased()
            let pattern = pattern.lowercased()
            var position = value.startIndex
            var patternPosition = pattern.startIndex
            var wildcard: String.Index?
            var retry = position
            while position < value.endIndex {
                if patternPosition < pattern.endIndex,
                    pattern[patternPosition] == "?" || pattern[patternPosition] == value[position]
                {
                    position = value.index(after: position)
                    patternPosition = pattern.index(after: patternPosition)
                } else if patternPosition < pattern.endIndex, pattern[patternPosition] == "*" {
                    wildcard = patternPosition
                    patternPosition = pattern.index(after: patternPosition)
                    retry = position
                } else if let wildcard {
                    retry = value.index(after: retry)
                    position = retry
                    patternPosition = pattern.index(after: wildcard)
                } else {
                    return false
                }
            }
            while patternPosition < pattern.endIndex, pattern[patternPosition] == "*" {
                patternPosition = pattern.index(after: patternPosition)
            }
            return patternPosition == pattern.endIndex
        }

        private static func directive(_ line: Substring) -> (keyword: String, arguments: [String])? {
            let bytes = Array(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            guard !bytes.isEmpty, bytes[0] != 35 else { return nil }
            var index = 0
            while index < bytes.count, ![9, 32, 61].contains(bytes[index]) { index += 1 }
            let keyword = String(decoding: bytes[..<index], as: UTF8.self).lowercased()
            guard keyword == "host" || keyword == "include" else { return nil }
            while index < bytes.count, bytes[index] == 9 || bytes[index] == 32 { index += 1 }
            if index < bytes.count, bytes[index] == 61 { index += 1 }
            var arguments: [String] = []
            while index < bytes.count {
                while index < bytes.count, bytes[index] == 9 || bytes[index] == 32 { index += 1 }
                guard index < bytes.count, bytes[index] != 35 else { break }
                var token: [UInt8] = []
                var quote: UInt8?
                while index < bytes.count {
                    let byte = bytes[index]
                    if byte == 92, index + 1 < bytes.count,
                        [34, 39, 92].contains(bytes[index + 1]) || (quote == nil && bytes[index + 1] == 32)
                    {
                        index += 1
                        token.append(bytes[index])
                    } else if quote == nil, byte == 9 || byte == 32 {
                        break
                    } else if quote == nil, byte == 34 || byte == 39 {
                        quote = byte
                    } else if quote == byte {
                        quote = nil
                    } else {
                        token.append(byte)
                    }
                    index += 1
                }
                guard quote == nil else { return nil }
                arguments.append(String(decoding: token, as: UTF8.self))
            }
            return (keyword, arguments)
        }
    }
}
