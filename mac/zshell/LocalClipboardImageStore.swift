import Darwin
import Foundation

nonisolated enum LocalClipboardImageStore {
    static func save(_ bytes: Data, in temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let png = try RemotePasteInput.pngData(from: bytes)
        try Task.checkCancellation()
        var template = Array(temporaryDirectory.appendingPathComponent("zshell-clipboard-XXXXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw PTYMuxWire.errnoError("mkdtemp") }
        let directory = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PTYMuxWire.errnoError("open") }
        defer { close(parent) }
        var metadata = stat()
        guard fstat(parent, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, fchmod(parent, 0o700) == 0 else {
            throw PTYMuxWire.errnoError("fstat")
        }
        let name = "clipboard-\(UUID().uuidString.lowercased()).png"
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PTYMuxWire.errnoError("openat") }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw PTYMuxWire.errnoError("fchmod") }
        for offset in stride(from: 0, to: png.count, by: 64 << 10) {
            try Task.checkCancellation()
            try PTYMuxWire.writeAll(png.subdata(in: offset..<min(offset + (64 << 10), png.count)), to: descriptor)
        }
        try Task.checkCancellation()
        complete = true
        // Keep a pasted path available for agents that read it after the
        // terminal closes. The system owns successful temporary-file cleanup.
        return directory.appendingPathComponent(name)
    }

    static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
