import Darwin
import Foundation

nonisolated final class FileTreeImportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastProgress: TimeInterval = 0
    private let onProgress: @Sendable (String) -> Void

    init(onProgress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onProgress = onProgress
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }

    func report(_ name: String, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let report = force || now - lastProgress >= 0.15
        if report { lastProgress = now }
        lock.unlock()
        if report { onProgress(name) }
    }
}

nonisolated enum FileTreeImportService {
    static let maximumEntries = 100_000
    static let maximumDepth = 128

    enum Decision: Sendable { case replace, skip }

    enum Failure: LocalizedError {
        case invalidDestination
        case duplicateName(String)
        case alreadyThere(String)
        case recursiveCopy(String)
        case unsupportedFile(String)
        case limit
        case changed
        case recovery(String)

        var errorDescription: String? {
            switch self {
            case .invalidDestination:
                String(localized: "Choose a local folder inside the current file tree.")
            case .duplicateName(let name):
                String(localized: "More than one selected item is named “\(name)”. Import them separately.")
            case .alreadyThere(let name):
                String(localized: "“\(name)” is already in the destination folder.")
            case .recursiveCopy(let name):
                String(localized: "“\(name)” can’t be copied into itself or one of its subfolders.")
            case .unsupportedFile(let name):
                String(localized: "“\(name)” isn’t a regular file, folder, or symbolic link.")
            case .limit:
                String(localized: "The import is too large. Choose fewer items or a shallower folder.")
            case .changed:
                String(localized: "The source or destination changed during import. Try again.")
            case .recovery(let path):
                String(localized: "The import could not be fully undone because some items changed. Recovery files may be available in “\(path)”.")
            }
        }
    }

    struct Snapshot: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modified: timespec
        let changed: timespec

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            mode = metadata.st_mode
            size = metadata.st_size
            modified = metadata.st_mtimespec
            changed = metadata.st_ctimespec
        }

        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }

        func sameNode(as other: Self) -> Bool {
            device == other.device && inode == other.inode && mode & S_IFMT == other.mode & S_IFMT
        }

        func sameContents(as other: Self) -> Bool {
            sameNode(as: other) && mode == other.mode && size == other.size
                && modified.tv_sec == other.modified.tv_sec && modified.tv_nsec == other.modified.tv_nsec
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.sameContents(as: rhs)
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    struct Entry: Sendable {
        let source: URL
        let name: String
        let sourceSnapshot: Snapshot
        let destinationSnapshot: Snapshot?
        let destinationContents: [String: Snapshot]?
    }

    final class Destination: @unchecked Sendable {
        let root: URL
        let directory: URL
        let originalRoot: URL
        let originalDirectory: URL
        let rootSnapshot: Snapshot
        let directorySnapshot: Snapshot
        let directoryDescriptor: Int32
        init(root: URL, directory: URL, originalRoot: URL, originalDirectory: URL,
             rootSnapshot: Snapshot, directorySnapshot: Snapshot, directoryDescriptor: Int32) {
            self.root = root
            self.directory = directory
            self.originalRoot = originalRoot
            self.originalDirectory = originalDirectory
            self.rootSnapshot = rootSnapshot
            self.directorySnapshot = directorySnapshot
            self.directoryDescriptor = directoryDescriptor
        }

        deinit { close(directoryDescriptor) }

        func validate() throws {
            // F_GETPATH can normalize case; live paths must identify the open node.
            guard try SettingsConfigFile.resolve(originalRoot) == root,
                  try SettingsConfigFile.resolve(originalDirectory) == directory,
                  let liveRoot = try snapshot(root.path), rootSnapshot.sameNode(as: liveRoot),
                  let liveDirectory = try snapshot(directory.path), directorySnapshot.sameNode(as: liveDirectory),
                  directorySnapshot.sameNode(as: try snapshot(descriptor: directoryDescriptor)) else { throw Failure.changed }
        }
    }

    final class Plan: Sendable {
        let destination: Destination
        let entries: [Entry]
        var directory: URL { destination.directory }
        var directoryDescriptor: Int32 { destination.directoryDescriptor }
        var conflicts: [Int] { entries.indices.filter { entries[$0].destinationSnapshot != nil } }

        init(destination: Destination, entries: [Entry]) {
            self.destination = destination
            self.entries = entries
        }

        func validateDestination() throws { try destination.validate() }
    }

    static func destination(root: String, directory: String) throws -> Destination {
        guard root.hasPrefix("/"), directory.hasPrefix("/") else { throw Failure.invalidDestination }
        let originalRoot = URL(fileURLWithPath: root, isDirectory: true)
        let originalDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        let canonicalRoot = try SettingsConfigFile.resolve(originalRoot)
        let canonicalDirectory = try SettingsConfigFile.resolve(originalDirectory)
        guard contains(canonicalDirectory.path, in: canonicalRoot.path),
              let rootSnapshot = try snapshot(canonicalRoot.path), rootSnapshot.isDirectory,
              let directorySnapshot = try snapshot(canonicalDirectory.path), directorySnapshot.isDirectory else {
            throw Failure.invalidDestination
        }
        let descriptor = open(canonicalDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        let destination = Destination(root: canonicalRoot, directory: canonicalDirectory, originalRoot: originalRoot,
                                      originalDirectory: originalDirectory, rootSnapshot: rootSnapshot,
                                      directorySnapshot: directorySnapshot, directoryDescriptor: descriptor)
        try destination.validate()
        return destination
    }

    static func prepare(sources: [URL], root: String, directory: String,
                        operation: FileTreeImportOperation, destination: Destination? = nil) throws -> Plan {
        try operation.checkCancellation()
        guard !sources.isEmpty, sources.count <= maximumEntries else { throw Failure.invalidDestination }
        let destination = try destination ?? Self.destination(root: root, directory: directory)
        guard destination.originalRoot.path == URL(fileURLWithPath: root, isDirectory: true).path,
              destination.originalDirectory.path == URL(fileURLWithPath: directory, isDirectory: true).path else {
            throw Failure.invalidDestination
        }
        try destination.validate()
        let canonicalDirectory = destination.directory
        let descriptor = destination.directoryDescriptor
        let caseSensitive = (try? canonicalDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        var seenPaths: Set<String> = []
        var names: Set<String> = []
        var entries: [Entry] = []
        for source in sources {
            try operation.checkCancellation()
            guard source.isFileURL, source.path.hasPrefix("/"),
                  !source.lastPathComponent.isEmpty, source.lastPathComponent != "/" else {
                throw Failure.unsupportedFile(source.lastPathComponent)
            }
            // Resolve the parent only: Finder aliases and symbolic links are
            // copied as items, without following their leaf targets.
            let parent = try SettingsConfigFile.resolve(source.deletingLastPathComponent())
            let canonicalSource = parent.appendingPathComponent(source.lastPathComponent)
            guard seenPaths.insert(canonicalSource.path).inserted else { continue }
            let name = canonicalSource.lastPathComponent
            let comparison = name.precomposedStringWithCanonicalMapping
            guard names.insert(caseSensitive ? comparison : comparison.lowercased()).inserted else {
                throw Failure.duplicateName(name)
            }
            guard let sourceSnapshot = try snapshot(canonicalSource.path) else { throw Failure.changed }
            let type = sourceSnapshot.mode & S_IFMT
            guard [S_IFREG, S_IFDIR, S_IFLNK].contains(type) else { throw Failure.unsupportedFile(name) }
            let destinationSnapshot = try snapshot(parent: descriptor, name: name)
            if let destinationSnapshot, sourceSnapshot.sameNode(as: destinationSnapshot) {
                throw Failure.alreadyThere(name)
            }
            if sourceSnapshot.isDirectory, contains(canonicalDirectory.path, in: canonicalSource.path) {
                throw Failure.recursiveCopy(name)
            }
            entries.append(Entry(source: canonicalSource, name: name, sourceSnapshot: sourceSnapshot,
                                 destinationSnapshot: destinationSnapshot,
                                 destinationContents: destinationSnapshot?.isDirectory == true
                                    ? try directoryContents(canonicalDirectory.appendingPathComponent(name), operation: operation) : nil))
        }
        let plan = Plan(destination: destination, entries: entries)
        try plan.validateDestination()
        return plan
    }

    private struct InstalledEntry {
        let entry: Entry
        var installed: Snapshot
        let installedContents: [String: Snapshot]?
        var backupDescriptor: Int32?
    }

    static func perform(_ plan: Plan, decisions: [Int: Decision], operation: FileTreeImportOperation) throws -> [String] {
        let entries = plan.entries.enumerated().filter { index, entry in
            entry.destinationSnapshot == nil || decisions[index] != .skip
        }.map(\.element)
        guard !entries.isEmpty else { return [] }
        for index in plan.conflicts {
            guard decisions[index] != nil else { throw Failure.changed }
        }
        try operation.checkCancellation()
        try plan.validateDestination()
        let stageName = ".zshell-import-" + UUID().uuidString
        let parent = plan.directoryDescriptor
        guard mkdirat(parent, stageName, 0o700) == 0 else { throw posixError() }
        let stage = openat(parent, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else {
            unlinkat(parent, stageName, AT_REMOVEDIR)
            throw posixError()
        }
        var preserveStage = false
        defer {
            if !preserveStage {
                if let path = try? descriptorPath(stage) { try? FileManager.default.removeItem(atPath: path) }
            }
            close(stage)
        }
        for name in ["incoming", "originals"] {
            guard mkdirat(stage, name, 0o700) == 0 else { throw posixError() }
        }
        let incoming = openat(stage, "incoming", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let originals = openat(stage, "originals", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard incoming >= 0, originals >= 0 else {
            if incoming >= 0 { close(incoming) }
            if originals >= 0 { close(originals) }
            throw posixError()
        }
        defer { close(incoming); close(originals) }
        var installed: [InstalledEntry] = []
        do {
            var visited = 0
            for entry in entries {
                try operation.checkCancellation()
                try plan.validateDestination()
                guard try snapshot(entry.source.path) == entry.sourceSnapshot else { throw Failure.changed }
                operation.report(entry.name, force: true)
                let context = CopyContext(operation: operation, root: entry.source.path, visited: visited)
                guard let state = copyfile_state_alloc() else { throw posixError() }
                defer { copyfile_state_free(state) }
                let callback: copyfile_callback_t = { what, stage, state, source, _, pointer in
                    guard let pointer, let source else { return COPYFILE_QUIT }
                    return Unmanaged<CopyContext>.fromOpaque(pointer).takeUnretainedValue()
                        .visit(what: what, stage: stage, state: state, path: String(cString: source))
                }
                guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0,
                      copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque()) == 0 else {
                    throw posixError()
                }
                let destination = URL(fileURLWithPath: try descriptorPath(incoming)).appendingPathComponent(entry.name)
                let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL | COPYFILE_CLONE)
                let result = copyfile(entry.source.path, destination.path, state, flags)
                if let failure = context.failure { throw failure }
                guard result == 0 else { throw posixError() }
                visited = max(visited + 1, context.visited)
                guard visited <= maximumEntries else { throw Failure.limit }
                guard try snapshot(entry.source.path) == entry.sourceSnapshot else { throw Failure.changed }
            }
            // No destination entry is published until every source is copied
            // and every replacement decision has been collected.
            for entry in entries {
                try operation.checkCancellation()
                try plan.validateDestination()
                guard try snapshot(parent: parent, name: entry.name) == entry.destinationSnapshot else { throw Failure.changed }
                if let expected = entry.destinationContents,
                   try directoryContents(plan.directory.appendingPathComponent(entry.name), operation: operation) != expected {
                    throw Failure.changed
                }
                guard let staged = try snapshot(parent: incoming, name: entry.name) else { throw Failure.changed }
                let stagedContents = staged.isDirectory
                    ? try directoryContents(URL(fileURLWithPath: try descriptorPath(incoming)).appendingPathComponent(entry.name),
                                            operation: operation) : nil
                let flags = entry.destinationSnapshot == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
                guard renameatx_np(incoming, entry.name, parent, entry.name, flags) == 0 else { throw Failure.changed }
                installed.append(InstalledEntry(entry: entry, installed: staged, installedContents: stagedContents,
                                                backupDescriptor: entry.destinationSnapshot == nil ? nil : incoming))
                guard let current = try snapshot(parent: parent, name: entry.name), current.sameContents(as: staged) else {
                    throw Failure.changed
                }
                installed[installed.count - 1].installed = current
                if let expected = entry.destinationSnapshot {
                    guard let displaced = try snapshot(parent: incoming, name: entry.name),
                          displaced.sameContents(as: expected) else { throw Failure.changed }
                    if let expectedContents = entry.destinationContents,
                       try directoryContents(URL(fileURLWithPath: try descriptorPath(incoming)).appendingPathComponent(entry.name),
                                             operation: operation) != expectedContents { throw Failure.changed }
                    guard renameatx_np(incoming, entry.name, originals, entry.name, UInt32(RENAME_EXCL)) == 0 else {
                        throw posixError()
                    }
                    installed[installed.count - 1].backupDescriptor = originals
                }
            }
            try operation.checkCancellation()
            try plan.validateDestination()
            return entries.map { plan.directory.appendingPathComponent($0.name).path }
        } catch {
            for record in installed.reversed() {
                if !restore(record, parent: parent, incoming: incoming) { preserveStage = true }
            }
            if preserveStage { throw Failure.recovery(try descriptorPath(stage)) }
            throw error
        }
    }

    private static func restore(_ record: InstalledEntry, parent: Int32, incoming: Int32) -> Bool {
        guard let current = try? snapshot(parent: parent, name: record.entry.name),
              current == record.installed else { return false }
        let operation = FileTreeImportOperation()
        if let expected = record.installedContents {
            guard let parentPath = try? descriptorPath(parent),
                  let contents = try? directoryContents(URL(fileURLWithPath: parentPath).appendingPathComponent(record.entry.name),
                                                       operation: operation), contents == expected else { return false }
        }
        let backup = record.backupDescriptor ?? incoming
        let flags = record.backupDescriptor == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
        guard renameatx_np(parent, record.entry.name, backup, record.entry.name, flags) == 0 else { return false }
        let displaced = try? snapshot(parent: backup, name: record.entry.name)
        let displacedContents = record.installedContents.flatMap { _ in
            (try? descriptorPath(backup)).flatMap {
                try? directoryContents(URL(fileURLWithPath: $0).appendingPathComponent(record.entry.name), operation: operation)
            }
        }
        guard displaced?.sameContents(as: record.installed) == true,
              displacedContents == record.installedContents else {
            // A concurrent save after the last check must survive rollback.
            let undoFlags = record.backupDescriptor == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
            _ = renameatx_np(backup, record.entry.name, parent, record.entry.name, undoFlags)
            return false
        }
        return true
    }

    private final class CopyContext {
        let operation: FileTreeImportOperation
        let root: String
        var visited: Int
        var failure: Error?
        private var snapshots: [String: Snapshot] = [:]

        init(operation: FileTreeImportOperation, root: String, visited: Int) {
            self.operation = operation
            self.root = root
            self.visited = visited
        }

        func visit(what: Int32, stage: Int32, state: copyfile_state_t?, path: String) -> Int32 {
            do {
                try operation.checkCancellation()
                if what == COPYFILE_RECURSE_ERROR || stage == COPYFILE_ERR { throw posixError() }
                if stage == COPYFILE_START, what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR {
                    visited += 1
                    guard visited <= maximumEntries, path.dropFirst(root.count).filter({ $0 == "/" }).count <= maximumDepth else {
                        throw Failure.limit
                    }
                    guard let initial = try snapshot(path), [S_IFREG, S_IFDIR, S_IFLNK].contains(initial.mode & S_IFMT) else {
                        throw Failure.unsupportedFile((path as NSString).lastPathComponent)
                    }
                    snapshots[path] = initial
                }
                if stage == COPYFILE_FINISH, what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR_CLEANUP,
                   let initial = snapshots.removeValue(forKey: path), try snapshot(path) != initial {
                    throw Failure.changed
                }
                operation.report((path as NSString).lastPathComponent)
                return COPYFILE_CONTINUE
            } catch {
                failure = error
                return COPYFILE_QUIT
            }
        }
    }

    private static func directoryContents(_ directory: URL, operation: FileTreeImportOperation) throws -> [String: Snapshot] {
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            errorHandler: { _, error in failure = error; return false }) else { throw Failure.changed }
        var result: [String: Snapshot] = [:]
        let prefix = directory.path + "/"
        while let url = enumerator.nextObject() as? URL {
            try operation.checkCancellation()
            guard result.count < maximumEntries, enumerator.level <= maximumDepth,
                  url.path.hasPrefix(prefix), let metadata = try snapshot(url.path) else { throw Failure.limit }
            result[String(url.path.dropFirst(prefix.count))] = metadata
        }
        if let failure { throw failure }
        return result
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func snapshot(_ path: String) throws -> Snapshot? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        return Snapshot(metadata)
    }

    private static func snapshot(parent: Int32, name: String) throws -> Snapshot? {
        var metadata = stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        return Snapshot(metadata)
    }

    private static func snapshot(descriptor: Int32) throws -> Snapshot {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixError() }
        return Snapshot(metadata)
    }

    private static func descriptorPath(_ descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { throw posixError() }
        return String(cString: buffer)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
