import Darwin
import Foundation

nonisolated enum SettingsConfigFile {
    static let maximumBytes = 1 << 20

    enum Failure: Error {
        case tooManyLinks
        case notRegularFile
        case tooLarge
        case invalidUTF8
        case changedDuringWrite
    }

    /// Resolve each component, including missing link targets and linked
    /// directories. Foundation's resolver can leave a dangling link unresolved.
    static func resolve(_ url: URL, onVisit: (URL) -> Void = { _ in }) throws -> URL {
        var remaining = url.pathComponents.filter { $0 != "/" }
        var directory = URL(fileURLWithPath: "/", isDirectory: true)
        var links = 0
        while !remaining.isEmpty {
            let component = remaining.removeFirst()
            if component == "." { continue }
            if component == ".." {
                directory.deleteLastPathComponent()
                continue
            }
            onVisit(directory)
            let candidate = directory.appendingPathComponent(component)
            var attributes = stat()
            if lstat(candidate.path, &attributes) == 0,
               attributes.st_mode & S_IFMT == S_IFLNK {
                links += 1
                guard links <= 40 else { throw Failure.tooManyLinks }
                onVisit(candidate)
                let destination = try FileManager.default.destinationOfSymbolicLink(
                    atPath: candidate.path
                )
                if destination.hasPrefix("/") {
                    directory = URL(fileURLWithPath: "/", isDirectory: true)
                }
                remaining = destination.split(separator: "/").map(String.init) + remaining
            } else {
                directory = candidate
            }
        }
        onVisit(directory)
        return directory
    }

    static func read(at url: URL) throws -> String {
        let target = try resolve(url)
        // A hand-edited path must not turn a configuration read into a blocking
        // FIFO read, or follow a link swapped in after resolution.
        let descriptor = open(target.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw posixError() }
        guard attributes.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }
        guard attributes.st_size <= maximumBytes else { throw Failure.tooLarge }
        var data = Data()
        while let chunk = try file.read(upToCount: min(64 << 10, maximumBytes + 1 - data.count)),
              !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw Failure.tooLarge }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalidUTF8 }
        return text
    }

    static func write(_ text: String, at url: URL) throws {
        let data = Data(text.utf8)
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let target = try resolve(url)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var attributes = stat()
        let exists = lstat(target.path, &attributes) == 0
        if exists, attributes.st_mode & S_IFMT != S_IFREG {
            throw Failure.notRegularFile
        }
        if !exists, errno != ENOENT { throw posixError() }
        let permissions = exists ? attributes.st_mode & 0o7777 : 0o600
        let template = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).XXXXXX").path
        var buffer = Array(template.utf8CString)
        let descriptor = mkstemp(&buffer)
        guard descriptor >= 0 else { throw posixError() }
        let temporary = String(cString: buffer)
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            unlink(temporary)
        }
        try file.write(contentsOf: data)
        guard fchmod(descriptor, permissions) == 0 else { throw posixError() }
        try file.synchronize()
        guard try resolve(url) == target else { throw Failure.changedDuringWrite }
        guard rename(temporary, target.path) == 0 else { throw posixError() }
    }

    static func backUp(at url: URL) throws {
        let contents = try read(at: url)
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("config.toml.bak")
        var attributes = stat()
        if lstat(backup.path, &attributes) == 0,
           attributes.st_mode & S_IFMT == S_IFLNK {
            // Older imports copied the config link. Replace that backup link
            // so importing cannot overwrite the only copy of the old contents.
            guard unlink(backup.path) == 0 else { throw posixError() }
        }
        try write(contents, at: backup)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// File descriptors and debounce state stay on the queue. The lock only
/// invalidates a queued reload when a newer UI change is waiting to be saved.
nonisolated final class SettingsConfigMonitor: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "sh.zshell.config", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingReload: DispatchWorkItem?
    private var emptySince: Date?
    private var lastText: String?
    private var onChange: (@Sendable (String, UInt64) -> Void)?
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var writePending = false

    init(url: URL) {
        self.url = url
    }

    deinit {
        pendingReload?.cancel()
        sources.forEach { $0.cancel() }
    }

    func start(onChange: @escaping @Sendable (String, UInt64) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onChange = onChange
            self.reload()
        }
    }

    func isCurrent(_ expectedRevision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return expectedRevision == revision && !writePending
    }

    func save(_ text: String) {
        lock.lock()
        revision &+= 1
        let expectedRevision = revision
        writePending = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try SettingsConfigFile.write(text, at: self.url)
                self.lastText = text
                self.emptySince = nil
            } catch {
                NSLog("zshell: failed to write \(self.url.path): \(error)")
            }
            self.lock.lock()
            if self.revision == expectedRevision { self.writePending = false }
            self.lock.unlock()
            self.refreshSources()
        }
    }

    func backUp() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try SettingsConfigFile.backUp(at: self.url)
            } catch {
                NSLog("zshell: failed to back up \(self.url.path): \(error)")
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    private func scheduleReload() {
        // Ancestor directories also report unrelated writes. Coalesce within
        // one interval so activity elsewhere cannot postpone reload forever.
        guard pendingReload == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func reload() {
        pendingReload = nil
        refreshSources()
        lock.lock()
        let readRevision = revision
        let pending = writePending
        lock.unlock()
        guard !pending, let text = try? SettingsConfigFile.read(at: url) else {
            emptySince = nil
            return
        }
        // Editors can truncate before writing. A deliberate empty config is
        // valid, but give it a second stable interval before restoring defaults.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if emptySince == nil { emptySince = Date() }
            if Date().timeIntervalSince(emptySince!) < 0.75 {
                scheduleReload()
                return
            }
        } else {
            emptySince = nil
        }
        guard text != lastText,
              isCurrent(readRevision) else { return }
        lock.lock()
        guard revision == readRevision, !writePending else {
            lock.unlock()
            return
        }
        revision &+= 1
        let expectedRevision = revision
        lock.unlock()
        lastText = text
        onChange?(text, expectedRevision)
    }

    private func refreshSources() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        var paths: Set<URL> = []
        _ = try? SettingsConfigFile.resolve(url) { paths.insert($0) }
        for path in paths {
            var attributes = stat()
            guard lstat(path.path, &attributes) == 0 else { continue }
            let isLink = attributes.st_mode & S_IFMT == S_IFLNK
            let descriptor = open(path.path, O_EVTONLY | O_CLOEXEC | (isLink ? O_SYMLINK : 0))
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke, .link],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.scheduleReload() }
            source.setCancelHandler { close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }
}
