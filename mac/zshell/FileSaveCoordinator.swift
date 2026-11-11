import Darwin
import Foundation

/// The bytes and file identity belong to the same read, including across draft recovery.
nonisolated struct FileSaveSnapshot: Codable, Equatable, Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let type: UInt32
    }

    var destinationPath: String
    let identity: Identity?
    let data: Data?
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    var isMissing: Bool { identity == nil }
    var isRegular: Bool { identity?.type == UInt32(S_IFREG) }
    var canWrite: Bool { isMissing || isRegular }
    var text: String? {
        guard let data, !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func matches(_ other: Self) -> Bool {
        guard destinationPath == other.destinationPath, identity == other.identity else { return false }
        if let data, let otherData = other.data { return data == otherData }
        return data == other.data && size == other.size
            && modificationSeconds == other.modificationSeconds
            && modificationNanoseconds == other.modificationNanoseconds
    }

    func moved(to path: String) -> Self {
        var moved = self
        moved.destinationPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return moved
    }
}

nonisolated enum FileSaveCoordinator {
    static let maxBytes = 5 << 20

    struct Conflict: Sendable {
        let path: String
        let current: FileSaveSnapshot
    }

    enum Result: Sendable {
        case saved(FileSaveSnapshot)
        case conflict(Conflict)
    }

    static func read(path: String, captureBytes: Bool = true) throws -> FileSaveSnapshot {
        let destination = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var entry = stat()
        guard lstat(destination.path, &entry) == 0 else {
            if errno == ENOENT {
                return snapshot(path: destination.path, entry: nil, data: nil)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard captureBytes, entry.st_mode & S_IFMT == S_IFREG else {
            return snapshot(path: destination.path, entry: entry, data: nil)
        }

        let descriptor = open(destination.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(handle.fileDescriptor, &before) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard before.st_mode & S_IFMT == S_IFREG,
              before.st_dev == entry.st_dev, before.st_ino == entry.st_ino else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        guard before.st_size <= maxBytes else {
            return snapshot(path: destination.path, entry: before, data: nil)
        }

        var data = Data()
        data.reserveCapacity(Int(max(0, before.st_size)))
        while data.count <= maxBytes {
            guard let chunk = try handle.read(upToCount: min(64 * 1024, maxBytes + 1 - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // An in-place agent write during the read must not become a mixed baseline.
        guard before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        return snapshot(path: destination.path, entry: after,
                        data: data.count <= maxBytes ? data : nil)
    }

    static func save(
        text: String,
        path: String,
        baseline: FileSaveSnapshot?,
        protectionEnabled: Bool,
        overwrite: FileSaveSnapshot? = nil
    ) throws -> Result {
        var data = Data(text.utf8)
        let utf8BOM = Data([0xEF, 0xBB, 0xBF])
        if baseline?.data?.starts(with: utf8BOM) == true, !data.starts(with: utf8BOM) {
            data.insert(contentsOf: utf8BOM, at: data.startIndex)
        }
        let current = try read(path: path, captureBytes: protectionEnabled)
        if protectionEnabled {
            guard let expected = overwrite ?? baseline, current.matches(expected) else {
                return .conflict(Conflict(path: path, current: current))
            }
        }
        // A dangling/cyclic link or a replacement directory is never a write target.
        guard current.canWrite else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        if current.data == data { return .saved(current) }
        // Recheck immediately before the atomic replacement, including symlink
        // resolution. A process can still write after this check and be overwritten.
        let latest = try read(path: path, captureBytes: protectionEnabled)
        if protectionEnabled, !latest.matches(current) {
            return .conflict(Conflict(path: path, current: latest))
        }
        guard latest.canWrite else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        let destination = URL(fileURLWithPath: latest.destinationPath)
        try data.write(to: destination, options: .atomic)
        // Keep the bytes we wrote even if an agent changes the path immediately after.
        // A subsequent save will still detect that newer content.
        var written = stat()
        let entry = lstat(destination.path, &written) == 0 ? written : nil
        return .saved(snapshot(path: destination.path, entry: entry, data: data))
    }

    private static func snapshot(path: String, entry: stat?, data: Data?) -> FileSaveSnapshot {
        FileSaveSnapshot(
            destinationPath: path,
            identity: entry.map { .init(device: $0.st_dev, inode: $0.st_ino,
                                       type: UInt32($0.st_mode & S_IFMT)) },
            data: data,
            size: entry?.st_size ?? 0,
            modificationSeconds: Int64(entry?.st_mtimespec.tv_sec ?? 0),
            modificationNanoseconds: Int64(entry?.st_mtimespec.tv_nsec ?? 0)
        )
    }
}
