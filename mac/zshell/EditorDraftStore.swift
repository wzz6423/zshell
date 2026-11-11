import Combine
import Darwin
import Foundation
import PierreDiffsSwift

nonisolated struct EditorDraftRecord: Codable, Sendable {
    enum Source: Codable, Equatable, Sendable {
        case file(path: String)
        case diff(repoRoot: String, path: String, untracked: Bool, originalPath: String?)
    }

    struct DiffState: Codable, Sendable {
        var oldText: String
        var style: String
        var editing: Bool
        var editor: PierreEditorState?
    }

    let version: Int
    let id: UUID
    let updatedAt: Date
    var source: Source
    let text: String
    let baseline: FileSaveSnapshot
    let editorState: EditorState?
    let diffState: DiffState?
    let previousPaths: [String]?

    init(id: UUID, source: Source, text: String, baseline: FileSaveSnapshot,
         editorState: EditorState? = nil, diffState: DiffState? = nil, previousPaths: [String]? = nil) {
        version = 1
        self.id = id
        updatedAt = Date()
        self.source = source
        self.text = text
        self.baseline = baseline
        self.editorState = editorState
        self.diffState = diffState
        self.previousPaths = previousPaths
    }

    var path: String {
        switch source {
        case .file(let path): return path
        case .diff(let root, let path, _, _):
            return URL(fileURLWithPath: root).appendingPathComponent(path).path
        }
    }

    var isValid: Bool {
        guard version == 1, updatedAt.timeIntervalSince1970.isFinite,
              updatedAt <= Date().addingTimeInterval(300),
              Self.absolutePath(baseline.destinationPath), baseline.isRegular,
              let data = baseline.data, data.count <= FileSaveCoordinator.maxBytes,
              baseline.text != nil, !text.contains("\0"),
              text.utf8.count <= FileSaveCoordinator.maxBytes,
              text != baseline.text, (previousPaths?.count ?? 0) <= 8,
              previousPaths?.allSatisfy(Self.absolutePath) != false else { return false }
        switch source {
        case .file(let path): return Self.absolutePath(path) && diffState == nil
        case .diff(let root, let path, _, let original):
            return Self.absolutePath(root) && Self.relativePath(path)
                && original.map(Self.relativePath) != false
                && diffState.map { $0.oldText.utf8.count <= FileSaveCoordinator.maxBytes
                    && $0.editor?.isValid != false && ["split", "unified"].contains($0.style) } == true
        }
    }

    private static func absolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 8192
    }

    func sanitizedEditorState() -> EditorState? {
        guard var state = editorState else { return nil }
        let length = text.utf16.count
        if let location = state.selectionLocation {
            state.selectionLocation = min(max(0, location), length)
            state.selectionLength = min(max(0, state.selectionLength ?? 0), length - (state.selectionLocation ?? 0))
        }
        for value in [state.scrollX, state.scrollY].compactMap({ $0 }) {
            if !value.isFinite || value < 0 || value > 1e9 { state.scrollX = nil; state.scrollY = nil }
        }
        state.revealSelection = nil
        return state
    }

    private static func relativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && path.utf8.count <= 8192
            && !path.split(separator: "/").contains("..")
    }
}

/// A private descriptor-relative archive: a substituted link or FIFO can
/// neither expose draft text nor block the background writer.
nonisolated final class EditorDraftArchive: @unchecked Sendable {
    static let maximumEntries = 32
    static let maximumRecordBytes = 80 << 20
    static let maximumTotalBytes = 128 << 20
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    enum Failure: Error { case unsafeDirectory, unsafeFile, tooLarge, invalidRecord, expiredRecord }
    private let directory: URL
    private let queue = DispatchQueue(label: "sh.zshell.editor-drafts", qos: .utility)
    private var enabled: Bool
    private var cleanupTimer: DispatchSourceTimer?

    init(directory: URL, enabled: Bool) {
        // Standardization can turn a resolved /private/tmp back into the
        // /tmp symlink once it exists, which O_NOFOLLOW must reject.
        self.directory = directory
        self.enabled = enabled
    }

    deinit { cleanupTimer?.cancel() }

    func startExpiryCleanup(interval: TimeInterval = 60 * 60) {
        queue.async {
            guard self.cleanupTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in try? self?.cleanupExpired() }
            self.cleanupTimer = timer
            timer.resume()
        }
    }

    func setEnabled(_ value: Bool) {
        // Draining the writer before returning makes disabling a privacy
        // boundary, including writes already queued by the last keystroke.
        queue.sync { enabled = value }
    }

    func write(_ records: [EditorDraftRecord], completion: @escaping @Sendable (Error?) -> Void) {
        queue.async {
            do { try self.writeNow(records); completion(nil) }
            catch { completion(error) }
        }
    }

    func flush(_ records: [EditorDraftRecord] = []) throws {
        try queue.sync { try writeNow(records) }
    }

    func remove(_ id: UUID) {
        queue.async {
            guard let descriptor = try? self.openDirectory(create: false), descriptor >= 0 else { return }
            defer { close(descriptor) }
            _ = unlinkat(descriptor, "\(id.uuidString.lowercased()).json", 0)
            _ = fsync(descriptor)
        }
    }

    func load(_ id: UUID) async throws -> EditorDraftRecord? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let descriptor = try self.openDirectory(create: false)
                    guard descriptor >= 0 else { continuation.resume(returning: nil); return }
                    defer { close(descriptor) }
                    var restored: EditorDraftRecord?
                    try self.prune(in: descriptor) { if $0.id == id { restored = $0 } }
                    _ = fsync(descriptor)
                    guard let record = restored ?? (try? self.read(id, in: descriptor)) else {
                        continuation.resume(returning: nil); return
                    }
                    // A save may have reached disk just before the process
                    // exited. Never resurrect an already-saved stale backup.
                    if let current = try? FileSaveCoordinator.read(path: record.path),
                       current.text == record.text {
                        continuation.resume(returning: nil)
                    } else { continuation.resume(returning: record) }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func records() async throws -> [EditorDraftRecord] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let descriptor = try self.openDirectory(create: false)
                    guard descriptor >= 0 else { continuation.resume(returning: []); return }
                    defer { close(descriptor) }
                    var result: [EditorDraftRecord] = []
                    try self.prune(in: descriptor) { result.append($0) }
                    _ = fsync(descriptor)
                    continuation.resume(returning: result.sorted { $0.updatedAt > $1.updatedAt })
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func writeNow(_ records: [EditorDraftRecord]) throws {
        guard enabled, !records.isEmpty else { return }
        let descriptor = try openDirectory(create: true)
        defer { close(descriptor) }
        var failure: Error?
        var written: [UUID: Date] = [:]
        for record in records.prefix(Self.maximumEntries) {
            do {
                guard record.isValid else { throw Failure.invalidRecord }
                let data = try JSONEncoder().encode(record)
                guard data.count <= Self.maximumRecordBytes else { throw Failure.tooLarge }
                try replace(data, id: record.id, in: descriptor)
                written[record.id] = record.updatedAt
            } catch { failure = error }
        }
        try prune(in: descriptor, written: written, validatingRecords: false)
        _ = fsync(descriptor)
        if let failure { throw failure }
    }

    private func cleanupExpired() throws {
        let descriptor = try openDirectory(create: false)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        try prune(in: descriptor)
        _ = fsync(descriptor)
    }

    private func prune(in descriptor: Int32, written: [UUID: Date] = [:],
                       validatingRecords: Bool = true,
                       onRead: ((EditorDraftRecord) -> Void)? = nil) throws {
        let entries = try entries(in: descriptor, removingTemporary: true).sorted { $0.modified > $1.modified }
        // Healthy keystroke backups need only metadata cleanup. Decode before
        // quota eviction, or when recovery and scheduled cleanup require it.
        let validate = validatingRecords || entries.count > Self.maximumEntries
            || entries.reduce(0, { $0 + min($1.bytes, Self.maximumRecordBytes) }) > Self.maximumTotalBytes
        let cutoff = Date().addingTimeInterval(-Self.retention)
        var count = 0, bytes = 0
        for entry in entries {
            if entry.modified < cutoff || entry.bytes > Self.maximumRecordBytes
                || written[entry.id].map({ $0 < cutoff }) == true
                || count >= Self.maximumEntries || bytes + entry.bytes > Self.maximumTotalBytes {
                _ = unlinkat(descriptor, entry.name, 0)
            } else {
                // Only validated candidates may displace recoverable drafts;
                // this batch's atomic writes already validated their payloads.
                if validate, written[entry.id] == nil {
                    guard let record = try? read(entry.id, in: descriptor) else {
                        _ = unlinkat(descriptor, entry.name, 0)
                        continue
                    }
                    onRead?(record)
                }
                count += 1
                bytes += entry.bytes
            }
        }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        do {
            for component in directory.pathComponents.dropFirst() {
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    guard create else { close(descriptor); return -1 }
                    guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else { throw posixError() }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Failure.unsafeDirectory }
                close(descriptor)
                descriptor = next
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
                  info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeDirectory }
            if create {
                guard fchmod(descriptor, 0o700) == 0 else { throw posixError() }
            } else {
                guard info.st_mode & 0o077 == 0 else { throw Failure.unsafeDirectory }
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private struct Entry {
        let id: UUID
        let name: String
        let bytes: Int
        let modified: Date
    }

    private func entries(in descriptor: Int32, removingTemporary: Bool = false) throws -> [Entry] {
        let listing = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard listing >= 0 else { throw posixError() }
        guard let stream = fdopendir(listing) else { close(listing); throw posixError() }
        defer { closedir(stream) }
        var result: [Entry] = []
        var scanned = 0
        while let entry = readdir(stream), scanned < 512 {
            scanned += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if removingTemporary, name.hasPrefix("."), name.hasSuffix(".tmp"),
               UUID(uuidString: String(name.dropFirst().dropLast(4))) != nil {
                // A crash between fsync and rename leaves only an unpublished
                // private temporary file. It must not accumulate across restarts.
                _ = unlinkat(descriptor, name, 0)
                continue
            }
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                  info.st_nlink == 1, info.st_size >= 0 else { continue }
            result.append(Entry(id: id, name: name, bytes: Int(info.st_size),
                                modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))))
        }
        return result
    }

    private func read(_ id: UUID, in parent: Int32) throws -> EditorDraftRecord {
        let descriptor = openat(parent, "\(id.uuidString.lowercased()).json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o077 == 0 else { throw Failure.unsafeFile }
        guard before.st_mtimespec.tv_sec >= Int(Date().addingTimeInterval(-Self.retention).timeIntervalSince1970) else {
            _ = unlinkat(parent, "\(id.uuidString.lowercased()).json", 0)
            _ = fsync(parent)
            throw Failure.expiredRecord
        }
        guard before.st_size >= 0, before.st_size <= Self.maximumRecordBytes else { throw Failure.tooLarge }
        var data = Data()
        while let chunk = try file.read(upToCount: min(64 << 10, Self.maximumRecordBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= Self.maximumRecordBytes else { throw Failure.tooLarge }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.unsafeFile }
        let record = try JSONDecoder().decode(EditorDraftRecord.self, from: data)
        guard record.id == id, record.isValid else { throw Failure.invalidRecord }
        guard record.updatedAt >= Date().addingTimeInterval(-Self.retention) else {
            // A refreshed mtime must not leave an expired payload on disk.
            _ = unlinkat(parent, "\(id.uuidString.lowercased()).json", 0)
            _ = fsync(parent)
            throw Failure.expiredRecord
        }
        return record
    }

    private func replace(_ data: Data, id: UUID, in parent: Int32) throws {
        let temporary = ".\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor); _ = unlinkat(parent, temporary, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }
        let name = "\(id.uuidString.lowercased()).json"
        var target = stat()
        if fstatat(parent, name, &target, AT_SYMLINK_NOFOLLOW) == 0 {
            guard target.st_mode & S_IFMT == S_IFREG, target.st_uid == geteuid(), target.st_nlink == 1 else { throw Failure.unsafeFile }
        } else if errno != ENOENT { throw posixError() }
        guard renameat(parent, temporary, parent, name) == 0 else { throw posixError() }
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

@MainActor
final class EditorDraftStore: ObservableObject {
    static let shared = EditorDraftStore()
    @Published private(set) var lastError: String?
    let archive: EditorDraftArchive
    private struct Client {
        let owner: UUID
        let snapshot: () -> EditorDraftRecord?
    }
    private var clients: [UUID: Client] = [:]
    private var suppressedText: [UUID: String] = [:]
    private var pending = Set<UUID>()
    private var timer: Timer?
    private var writing = false
    private var settingsObservation: AnyCancellable?

    private init() {
        #if DEBUG
        let name = "zshell-dev"
        #else
        let name = "zshell"
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Resolve an existing prefix even when this fresh home's Library is
        // absent; Foundation leaves /tmp unresolved in that case.
        let base = ((try? SettingsConfigFile.resolve(support)) ?? support)
            .appendingPathComponent(name, isDirectory: true)
        archive = EditorDraftArchive(directory: base.appendingPathComponent("editor-drafts", isDirectory: true),
                                     enabled: AppSettings.shared.recoverEditorDrafts)
        settingsObservation = AppSettings.shared.$recoverEditorDrafts.removeDuplicates().dropFirst()
            .sink { [weak self] enabled in
                self?.archive.setEnabled(enabled)
                self?.timer?.invalidate()
                self?.timer = nil
                self?.pending.removeAll()
                if enabled, let self {
                    self.pending.formUnion(self.clients.keys)
                    self.startTimer()
                }
            }
    }

    func register(_ id: UUID, owner: UUID, snapshot: @escaping () -> EditorDraftRecord?) -> UUID {
        // Duplicate saved panes must keep independent live buffers rather than
        // replace the original owner's backup registration.
        let claimed = clients[id].map { $0.owner == owner ? id : UUID() } ?? id
        clients[claimed] = Client(owner: owner, snapshot: snapshot)
        return claimed
    }

    func unregister(_ id: UUID, owner: UUID) {
        guard clients[id]?.owner == owner else { return }
        clients.removeValue(forKey: id)
        suppressedText.removeValue(forKey: id)
        pending.remove(id)
    }

    func schedule(_ id: UUID) {
        guard AppSettings.shared.recoverEditorDrafts else { return }
        pending.insert(id)
        startTimer()
    }

    func remove(_ id: UUID) {
        pending.remove(id)
        archive.remove(id)
    }

    func discard(_ id: UUID) {
        suppressedText[id] = clients[id]?.snapshot()?.text
        remove(id)
    }

    func prepareListing() {
        timer?.invalidate()
        pending.formUnion(clients.keys)
        writePending()
    }

    func flush() {
        timer?.invalidate()
        timer = nil
        let snapshots = AppSettings.shared.recoverEditorDrafts ? clients.keys.compactMap(snapshot) : []
        pending.removeAll()
        do { try archive.flush(snapshots) }
        catch { report(error) }
    }

    private func startTimer() {
        guard timer == nil, !pending.isEmpty else { return }
        // A fixed window also backs up continuous typing; debounce alone can
        // leave a long editing session with no durable draft at all.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.writePending() }
        }
    }

    private func writePending() {
        timer = nil
        guard !writing, !pending.isEmpty else { return }
        let records = pending.compactMap(snapshot)
        pending.removeAll()
        guard !records.isEmpty else { return }
        writing = true
        archive.write(records) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.writing = false
                if let error { self?.report(error) }
                else { self?.lastError = nil }
                self?.startTimer()
            }
        }
    }

    private func snapshot(_ id: UUID) -> EditorDraftRecord? {
        guard let record = clients[id]?.snapshot(), record.text != suppressedText[id] else { return nil }
        return record
    }

    private func report(_ error: Error) {
        lastError = String(localized: "Could not back up editor drafts.")
        NSLog("zshell: editor draft backup failed: %@", String(describing: error))
    }
}
