import AppKit
import CryptoKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

nonisolated struct RemotePasteFileInfo: Codable, Sendable {
    let name: String
    let size: UInt64
}

nonisolated enum RemotePasteTarget: Equatable, Sendable {
    case ssh(endpoint: SSHEndpoint, authentication: SSHAuthentication, credentialID: UUID?)
    case unavailable
}

nonisolated enum RemotePasteInput: Sendable {
    case files([URL])
    case image(Data)

    @MainActor static func capture(_ pasteboard: NSPasteboard) throws -> Self? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            guard urls.count <= RemotePasteUpload.maximumFiles else { throw RemotePasteUpload.sizeError() }
            return .files(urls)
        }
        if pasteboard.types?.contains(.fileURL) == true { throw RemoteHostError.message(String(localized: "The clipboard files couldn’t be read.")) }
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return nil }
        guard let bytes = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return nil }
        guard bytes.count <= RemotePasteUpload.maximumFileBytes else { throw RemotePasteUpload.sizeError() }
        return .image(bytes)
    }

    static func pngData(from bytes: Data) throws -> Data {
        try Task.checkCancellation()
        guard !bytes.isEmpty, bytes.count <= RemotePasteUpload.maximumFileBytes,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 16 * 1024 * 1024 else {
            throw RemotePasteUpload.sizeError()
        }
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw RemoteHostError.message(String(localized: "The clipboard image couldn’t be read."))
        }
        try Task.checkCancellation()
        if CGImageSourceGetType(source) == UTType.png.identifier as CFString { return bytes }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw RemoteHostError.message(String(localized: "The clipboard image couldn’t be read."))
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), png.length <= RemotePasteUpload.maximumFileBytes else { throw RemotePasteUpload.sizeError() }
        try Task.checkCancellation()
        return png as Data
    }
}

nonisolated enum RemotePasteUpload {
    static let maximumFileBytes = 32 * 1024 * 1024
    static let maximumBatchBytes = 64 * 1024 * 1024
    static let maximumFiles = 32
    private static let chunkBytes = 64 * 1024

    private struct Source {
        let info: RemotePasteFileInfo
        let handle: FileHandle?
        let image: Data?
    }

    static func upload(_ input: RemotePasteInput, host: RemoteHost, project: String, sessionID: UUID, clientID: UUID) throws -> [String] {
        let sources = try readSources(input)
        defer { for source in sources { try? source.handle?.close() } }
        try Task.checkCancellation()
        let transport = try RemoteHostTransport(host: host)
        defer { transport.close() }
        try transport.handshake()
        func frame(_ kind: String, uploadID: String? = nil) -> RemoteFrame {
            RemoteFrame(kind: kind, project: project, sessionId: sessionID.uuidString.lowercased(),
                        clientId: clientID.uuidString.lowercased(), uploadId: uploadID)
        }
        struct Start: Decodable { let uploadId: String }
        struct Chunk: Decodable { let offset: UInt64 }
        struct Commit: Decodable { let paths: [String] }
        var start = frame("pasteStart")
        start.pasteFiles = sources.map(\.info)
        let started = try transport.exchange(start).decodedResult(Start.self)
        guard UUID(uuidString: started.uploadId) != nil else { throw invalidResponse() }
        for (index, source) in sources.enumerated() {
            var offset: UInt64 = 0
            while offset < source.info.size {
                try Task.checkCancellation()
                let bytes = try read(source, at: offset)
                var chunk = frame("pasteChunk", uploadID: started.uploadId)
                chunk.fileIndex = index
                chunk.offset = offset
                chunk.data = bytes.base64EncodedString()
                let reply = try transport.exchange(chunk).decodedResult(Chunk.self)
                offset += UInt64(bytes.count)
                guard reply.offset == offset else { throw invalidResponse() }
            }
            try checkComplete(source)
        }
        try Task.checkCancellation()
        let committed = try transport.exchange(frame("pasteCommit", uploadID: started.uploadId)).decodedResult(Commit.self)
        guard committed.paths.count == sources.count,
              committed.paths.allSatisfy(validPath) else { throw invalidResponse() }
        return committed.paths
    }

    static func uploadSSH(_ input: RemotePasteInput, endpoint: SSHEndpoint, authentication: SSHAuthentication,
                          credentialID: UUID?) throws -> [String] {
        let sources = try readSources(input)
        defer { for source in sources { try? source.handle?.close() } }
        try Task.checkCancellation()
        let token = UUID().uuidString.lowercased()
        let transport = OpenSSHTransport(timeout: 60, outputLimit: 16_384)
        func run(_ command: [String], input: Data? = nil) throws -> BoundedProcessOutput {
            try transport.run(endpoint: endpoint, command: command, authentication: authentication,
                              credentialID: credentialID, standardInput: input)
        }
        let created = try run(["/bin/sh", "-c", "umask 077; mktemp -d \"${TMPDIR:-/tmp}/zshell-paste-\(token)-XXXXXXXX\""], input: Data())
        let directory = created.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !created.wasTruncated, validPath(directory), directory.contains("/zshell-paste-\(token)-"),
              !directory.contains("/../"), !directory.contains("/./") else { throw invalidResponse() }
        var complete = false
        defer {
            if !complete {
                _ = try? OpenSSHTransport(timeout: 10, outputLimit: 1024).run(endpoint: endpoint,
                    command: ["/bin/rm", "-rf", "--", directory], authentication: authentication, credentialID: credentialID)
            }
        }
        var paths: [String] = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            var bytes = Data(capacity: Int(source.info.size))
            while bytes.count < source.info.size {
                try Task.checkCancellation()
                bytes.append(try read(source, at: UInt64(bytes.count)))
            }
            try checkComplete(source)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let name = String(format: "%02d-", index) + source.info.name
            let uploaded = try run(["/bin/sh", "-c", sshUploadScript, "zshell-paste", directory, name, String(bytes.count), digest],
                                   input: bytes.base64EncodedData())
            guard !uploaded.wasTruncated, uploaded.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "OK \(bytes.count) \(digest)" else { throw invalidResponse() }
            paths.append(directory + "/" + name)
        }
        try Task.checkCancellation()
        complete = true
        return paths
    }

    private static let sshUploadScript = """
    set -eu
    umask 077
    test -d "$1" && test ! -L "$1"
    file="$1/$2"
    trap 'rm -f -- "$file"' EXIT HUP INT TERM
    set -C
    if base64 --decode </dev/null >/dev/null 2>&1; then
      base64 --decode > "$file"
    elif base64 -D </dev/null >/dev/null 2>&1; then
      base64 -D > "$file"
    else
      base64 -d > "$file"
    fi
    test "$(wc -c < "$file" | tr -d '[:space:]')" = "$3"
    if command -v sha256sum >/dev/null 2>&1; then
      digest=$(sha256sum -- "$file"); digest=${digest%% *}
    elif command -v shasum >/dev/null 2>&1; then
      digest=$(shasum -a 256 -- "$file"); digest=${digest%% *}
    else
      digest=$(openssl dgst -sha256 "$file"); digest=${digest##* }
    fi
    test "$digest" = "$4"
    trap - EXIT HUP INT TERM
    printf 'OK %s %s\n' "$3" "$digest"
    """

    private static func readSources(_ input: RemotePasteInput) throws -> [Source] {
        var sources: [Source] = []
        var ready = false
        defer { if !ready { for source in sources { try? source.handle?.close() } } }
        switch input {
        case .files(let urls):
            guard !urls.isEmpty, urls.count <= maximumFiles else { throw sizeError() }
            for url in urls {
                try Task.checkCancellation()
                let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { throw PTYMuxWire.errnoError("open") }
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      metadata.st_size >= 0, metadata.st_size <= maximumFileBytes else {
                    Darwin.close(descriptor)
                    throw RemoteHostError.message(String(localized: "Paste regular files up to 32 MiB each. Folders and symbolic links aren’t supported."))
                }
                sources.append(Source(info: RemotePasteFileInfo(name: safeName(url.lastPathComponent), size: UInt64(metadata.st_size)),
                                      handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), image: nil))
            }
        case .image(let bytes):
            let png = try RemotePasteInput.pngData(from: bytes)
            sources = [Source(info: RemotePasteFileInfo(name: "clipboard-\(UUID().uuidString.lowercased()).png", size: UInt64(png.count)), handle: nil, image: png)]
        }
        guard sources.reduce(UInt64(0), { $0 + $1.info.size }) <= maximumBatchBytes else { throw sizeError() }
        ready = true
        return sources
    }

    private static func read(_ source: Source, at offset: UInt64) throws -> Data {
        let wanted = min(chunkBytes, Int(source.info.size - offset))
        let bytes: Data
        if let image = source.image { bytes = image.subdata(in: Int(offset)..<Int(offset) + wanted) }
        else { bytes = try source.handle?.read(upToCount: wanted) ?? Data() }
        guard !bytes.isEmpty, bytes.count <= wanted else { throw changedFile() }
        return bytes
    }

    private static func checkComplete(_ source: Source) throws {
        if let handle = source.handle, try handle.read(upToCount: 1)?.isEmpty == false { throw changedFile() }
    }

    private static func changedFile() -> RemoteHostError {
        .message(String(localized: "A clipboard file changed while it was being uploaded."))
    }

    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 16_384
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func quotePath(_ path: String) throws -> String {
        guard validPath(path) else { throw invalidResponse() }
        return SSHEndpoint.shellWord(path)
    }

    static func sizeError() -> RemoteHostError {
        .message(String(localized: "Paste up to 32 files, with a maximum of 32 MiB per file and 64 MiB in total."))
    }

    private static func invalidResponse() -> RemoteHostError {
        .message(String(localized: "The remote server returned an invalid response."))
    }

    private static func safeName(_ name: String) -> String {
        var result = ""
        for character in name {
            let text = String(character)
            let part = text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) || text == "\\" || text == "/" ? "_" : text
            if result.utf8.count + part.utf8.count > 220 { break }
            result += part
        }
        return result.isEmpty || result == "." || result == ".." ? "file" : result
    }
}
