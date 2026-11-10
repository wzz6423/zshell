//
//  FileTreeModel.swift
//  zshell
//

import AppKit
import Combine
import Darwin
import Foundation

/// Flattened, lazily-expanded view of a directory tree.
@MainActor
final class FileTreeModel: nonisolated ObservableObject {
    nonisolated struct Item: Identifiable, Equatable, Sendable {
        var id: String { path }
        let name: String
        let path: String
        let isDirectory: Bool
        let depth: Int
        /// True for the transient inline "new file/folder" input row, which
        /// has no backing file yet.
        var isDraft = false
    }

    /// A pending inline "new file/folder": an input row shown inside
    /// `parentDir` until the user names it (Enter) or cancels (Escape/blur).
    nonisolated struct Draft: Equatable, Sendable {
        let parentDir: String
        let isDirectory: Bool
    }

    @Published private(set) var rootPath = ""
    @Published private(set) var items: [Item] = []
    /// Path of the row currently being renamed inline, if any.
    @Published private(set) var renamingPath: String?
    /// The pending new-file/folder input row, if any.
    @Published private(set) var draft: Draft?
    private var expanded: Set<String> = []
    private var localListings: [String: LocalListing] = [:]
    private var localRefreshTask: Task<Void, Never>?
    private var localRefreshPending = false
    private var localGeneration = 0
    private var localRevision = 0
    private var localInvalidatedDirectories: Set<String> = []

    deinit { localRefreshTask?.cancel() }

    var rootName: String {
        (rootPath as NSString).lastPathComponent
    }

    func isExpanded(_ item: Item) -> Bool {
        expanded.contains(item.path)
    }

    // MARK: - Remote projects

    /// When set, listings are read by running `ls` over SSH on the remote
    /// host instead of the local filesystem, and mutating operations are
    /// disabled: there is no local file behind any row.
    private var remoteEndpoint: SSHEndpoint?
    /// Entries per remote directory, keyed by absolute remote path. Built
    /// lazily like the local tree expands directories.
    private var remoteListings: [String: [SSHEndpoint.DirectoryEntry]] = [:]
    private var remoteLastAttempt: [String: TimeInterval] = [:]
    /// A forced retry survives waiting for a free connection; syncs coalesce
    /// into one pending entry per visible directory.
    private var remotePending: [String: Bool] = [:]
    /// Old generations keep their connection slots until they finish, so
    /// switching projects cannot pile up SSH processes.
    private var remoteInFlight: [String: Int] = [:]
    private var remoteErrors: [String: String] = [:]
    private static let remoteRefreshInterval: TimeInterval = 5
    private static let remoteConcurrencyLimit = 2
    private let remoteListing: @Sendable (SSHEndpoint, String) throws -> [SSHEndpoint.DirectoryEntry]
    private let remoteNow: () -> TimeInterval
    /// Invalidates in-flight listings after the endpoint or root changes.
    private var remoteGeneration = 0
    @Published private(set) var remoteError: String?
    @Published private(set) var isRemoteLoading = false

    init(
        remoteListing: @escaping @Sendable (SSHEndpoint, String) throws -> [SSHEndpoint.DirectoryEntry] = {
            try OpenSSHTransport().listDirectory(endpoint: $0, directory: $1)
        },
        remoteNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.remoteListing = remoteListing
        self.remoteNow = remoteNow
    }

    var isRemote: Bool { remoteEndpoint != nil }

    /// Panel header subtitle. Remote paths carry the endpoint so the header
    /// states which host the tree shows.
    var rootSubtitle: String {
        guard let endpoint = remoteEndpoint else { return rootPath }
        return endpoint.destination + ":" + rootPath
    }

    func configureRemote(_ endpoint: SSHEndpoint?) {
        guard endpoint != remoteEndpoint else { return }
        invalidateLocalRefresh()
        remoteEndpoint = endpoint
        remoteGeneration &+= 1
        remoteListings = [:]
        remoteLastAttempt = [:]
        remotePending = [:]
        remoteErrors = [:]
        remoteError = nil
        isRemoteLoading = false
        expanded = []
        renamingPath = nil
        draft = nil
        items = []
    }

    /// Retries the root and failed visible directories without waiting for
    /// the next throttled refresh.
    func retryRemoteRoot() {
        refreshRemoteListings(force: true)
    }

    private var visibleRemoteDirectories: Set<String> {
        guard remoteEndpoint != nil, !rootPath.isEmpty else { return [] }
        var directories: Set<String> = [rootPath]
        for item in items where item.isDirectory && item.depth < 31 && expanded.contains(item.path) {
            directories.insert(item.path)
        }
        return directories
    }

    private func refreshRemoteListings(force: Bool = false) {
        let now = remoteNow()
        for directory in visibleRemoteDirectories {
            guard remoteInFlight[directory] != remoteGeneration || remoteLastAttempt[directory] == nil else { continue }
            let forced = force && (directory == rootPath || remoteErrors[directory] != nil)
            if let last = remoteLastAttempt[directory], !forced, now - last < Self.remoteRefreshInterval {
                continue
            }
            remotePending[directory] = (remotePending[directory] ?? false) || forced
            if forced { remoteErrors.removeValue(forKey: directory) }
        }
        startRemoteListings()
    }

    private func startRemoteListings() {
        let visible = visibleRemoteDirectories
        remotePending = remotePending.filter { visible.contains($0.key) }
        remoteErrors = remoteErrors.filter { visible.contains($0.key) }
        if let endpoint = remoteEndpoint {
            while remoteInFlight.count < Self.remoteConcurrencyLimit {
                let directory = remotePending.keys.filter { remoteInFlight[$0] == nil }.min { a, b in
                    if remotePending[a] != remotePending[b] { return remotePending[a] == true }
                    let first = remoteLastAttempt[a] ?? -.infinity
                    let second = remoteLastAttempt[b] ?? -.infinity
                    if first != second { return first < second }
                    if (a == rootPath) != (b == rootPath) { return a == rootPath }
                    return a < b
                }
                guard let directory else { break }
                remotePending.removeValue(forKey: directory)
                remoteLastAttempt[directory] = remoteNow()
                let generation = remoteGeneration
                remoteInFlight[directory] = generation
                let remoteListing = remoteListing
                Task.detached(priority: .userInitiated) { [weak self] in
                    let listing = Result { try remoteListing(endpoint, directory) }
                    await MainActor.run { [weak self] in
                        self?.finishRemoteListing(directory, listing, generation: generation)
                    }
                }
            }
        }
        let loading = !remotePending.isEmpty || remoteInFlight.contains {
            $0.value == remoteGeneration && visible.contains($0.key)
        }
        if isRemoteLoading != loading { isRemoteLoading = loading }
        let error = remoteErrors[rootPath] ?? remoteErrors.keys.sorted().first.flatMap { remoteErrors[$0] }
        if remoteError != error { remoteError = error }
    }

    private func finishRemoteListing(
        _ directory: String,
        _ result: Result<[SSHEndpoint.DirectoryEntry], Error>,
        generation: Int
    ) {
        guard remoteInFlight[directory] == generation else { return }
        remoteInFlight.removeValue(forKey: directory)
        guard generation == remoteGeneration, remoteLastAttempt[directory] != nil,
              visibleRemoteDirectories.contains(directory) else {
            startRemoteListings()
            return
        }
        switch result {
        case .success(let entries):
            remoteErrors.removeValue(forKey: directory)
            invalidateRemovedRemoteDirectories(in: directory, entries: entries)
            remoteListings[directory] = entries.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .failure(let error):
            remoteErrors[directory] = error.localizedDescription
        }
        rebuild()
        startRemoteListings()
    }

    private func invalidateRemovedRemoteDirectories(in directory: String, entries: [SSHEndpoint.DirectoryEntry]) {
        let previous = Set((remoteListings[directory] ?? []).filter(\.isDirectory).map(\.name))
        let removed = previous.subtracting(entries.filter(\.isDirectory).map(\.name))
        guard !removed.isEmpty else { return }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        func keep(_ path: String) -> Bool {
            guard path.hasPrefix(prefix),
                  let child = path.dropFirst(prefix.count).split(separator: "/").first else { return true }
            return !removed.contains(String(child))
        }
        remoteListings = remoteListings.filter { keep($0.key) }
        // Clearing the attempt also rejects a removed directory's in-flight
        // result if a replacement appears at the same path before it finishes.
        remoteLastAttempt = remoteLastAttempt.filter { keep($0.key) }
        remotePending = remotePending.filter { keep($0.key) }
        remoteErrors = remoteErrors.filter { keep($0.key) }
    }

    /// Points the tree at `root` (collapsing everything if it moved) and
    /// re-reads visible directories. Cheap when nothing changed. Remote
    /// trees fetch their listings over SSH instead.
    func sync(root: String) {
        if root != rootPath {
            invalidateLocalRefresh()
            rootPath = root
            expanded = []
            // Any in-progress inline edit belonged to the old tree.
            renamingPath = nil
            draft = nil
            if !items.isEmpty { items = [] }
            if remoteEndpoint != nil {
                remoteGeneration &+= 1
                remoteListings = [:]
                remoteLastAttempt = [:]
                remotePending = [:]
                remoteErrors = [:]
                remoteError = nil
                isRemoteLoading = false
            }
        }
        guard remoteEndpoint == nil else {
            guard !rootPath.isEmpty else {
                items = []
                return
            }
            rebuild()
            refreshRemoteListings()
            return
        }
        refreshLocal()
    }

    func toggle(_ item: Item) {
        guard item.isDirectory else { return }
        if !expanded.insert(item.path).inserted {
            expanded.remove(item.path)
        }
        rebuild()
        if remoteEndpoint != nil {
            if expanded.contains(item.path) {
                refreshRemoteListings()
            } else {
                startRemoteListings()
            }
        }
    }

    /// Moves `item` to the Trash, then rebuilds so it drops out of the tree.
    func moveToTrash(_ item: Item) {
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: item.path), resultingItemURL: nil
            )
            expanded.remove(item.path)
            localInvalidatedDirectories.insert((item.path as NSString).deletingLastPathComponent)
        } catch {
            presentError(
                String(
                    localized: "Couldn’t move “\(item.name)” to the Trash.",
                    comment: "File operation error. The placeholder is a file or folder name."
                ),
                error.localizedDescription
            )
        }
        rebuild()
    }

    // MARK: - Rename

    func beginRename(_ item: Item) {
        renamingPath = item.path
    }

    func cancelRename() {
        renamingPath = nil
    }

    /// Renames `item` in place. No-ops on an empty or unchanged name; shows an
    /// alert if the name collides or the filesystem move fails. Returns the new
    /// absolute path when the file actually moved, so callers can follow it
    /// (e.g. re-point open tabs).
    @discardableResult
    func rename(_ item: Item, to newName: String) -> String? {
        renamingPath = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return nil }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError(
                String(localized: "Couldn’t rename to “\(trimmed)”."),
                String(localized: "A name can’t contain “/” or be “.” or “..”.")
            )
            return nil
        }
        let dir = (item.path as NSString).deletingLastPathComponent
        let dest = (dir as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        // A case-only rename ("foo"→"Foo") maps to the same file on a
        // case-insensitive volume, so don't treat that as a collision.
        let caseOnlyChange = trimmed.lowercased() == item.name.lowercased()
        guard caseOnlyChange || !fm.fileExists(atPath: dest) else {
            presentError(
                String(localized: "Couldn’t rename to “\(trimmed)”."),
                String(localized: "An item named “\(trimmed)” already exists here.")
            )
            return nil
        }
        do {
            try fm.moveItem(atPath: item.path, toPath: dest)
            remapExpanded(from: item.path, to: dest)
            localInvalidatedDirectories.insert(dir)
        } catch {
            presentError(String(localized: "Couldn’t rename to “\(trimmed)”."), error.localizedDescription)
            return nil
        }
        rebuild()
        return dest
    }

    /// Keeps expansion state after a directory rename by rewriting the old
    /// path prefix (for the folder itself and any expanded descendants).
    private func remapExpanded(from oldPath: String, to newPath: String) {
        guard expanded.contains(where: { $0 == oldPath || $0.hasPrefix(oldPath + "/") })
        else { return }
        expanded = Set(expanded.map { path in
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") {
                return newPath + String(path.dropFirst(oldPath.count))
            }
            return path
        })
    }

    // MARK: - Create (inline draft)

    /// Opens an inline input row for a new file inside `directory`.
    func beginNewFile(in directory: String) {
        startDraft(in: directory, isDirectory: false)
    }

    /// Opens an inline input row for a new folder inside `directory`.
    func beginNewFolder(in directory: String) {
        startDraft(in: directory, isDirectory: true)
    }

    private func startDraft(in directory: String, isDirectory: Bool) {
        renamingPath = nil
        draft = Draft(parentDir: directory, isDirectory: isDirectory)
        // Reveal the folder's contents so the input row is visible.
        expanded.insert(directory)
        if remoteEndpoint == nil { showDraftRow() }
        rebuild()
    }

    func cancelDraft() {
        guard draft != nil else { return }
        draft = nil
        if remoteEndpoint == nil { removeDraftRow() }
        rebuild()
    }

    /// Commits the pending draft, creating the file or folder. An empty name
    /// cancels (matching VS Code). Returns the new file's path — for files
    /// only — so the caller can open it.
    @discardableResult
    func commitDraft(name: String) -> String? {
        guard let draft else { return nil }
        self.draft = nil
        if remoteEndpoint == nil { removeDraftRow() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { rebuild(); return nil }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError(
                String(localized: "Couldn’t create “\(trimmed)”."),
                String(localized: "A name can’t contain “/” or be “.” or “..”.")
            )
            rebuild()
            return nil
        }
        let dest = (draft.parentDir as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest) else {
            presentError(
                String(localized: "Couldn’t create “\(trimmed)”."),
                String(localized: "An item named “\(trimmed)” already exists here.")
            )
            rebuild()
            return nil
        }
        var createdFile: String?
        if draft.isDirectory {
            do {
                try fm.createDirectory(atPath: dest, withIntermediateDirectories: false)
            } catch {
                presentError(String(localized: "Couldn’t create the folder."), error.localizedDescription)
            }
        } else {
            // The existence check misses dangling symlinks and can race with other writers.
            let descriptor = Darwin.open(dest, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
            if descriptor >= 0 {
                Darwin.close(descriptor)
                createdFile = dest
            } else if errno == EEXIST {
                presentError(
                    String(localized: "Couldn’t create “\(trimmed)”."),
                    String(localized: "An item named “\(trimmed)” already exists here.")
                )
            } else {
                presentError(
                    String(localized: "Couldn’t create the file."),
                    String(localized: "It could not be written to disk.")
                )
            }
        }
        localInvalidatedDirectories.insert(draft.parentDir)
        rebuild()
        return createdFile
    }

    private func presentError(_ messageText: String, _ informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        guard let window = AppWindowPresentation.hostWindow() else { return }
        alert.beginSheetModal(for: window)
    }

    private func rebuild() {
        guard !rootPath.isEmpty else { return }
        guard remoteEndpoint != nil else {
            localRevision &+= 1
            localRefreshTask?.cancel()
            refreshLocal()
            return
        }
        var out: [Item] = []
        appendRemoteChildren(of: rootPath, depth: 0, into: &out)
        if out != items {
            items = out
        }
    }

    /// Builds the visible rows from cached remote listings. A directory
    /// without a listing yet renders as an empty, expandable row; its
    /// contents arrive when its listing completes.
    private func appendRemoteChildren(of dir: String, depth: Int, into out: inout [Item]) {
        // Guard against runaway recursion through symlink cycles.
        guard depth < 32 else { return }
        guard let listing = remoteListings[dir] else { return }
        for entry in listing {
            let path = (dir as NSString).appendingPathComponent(entry.name)
            let item = Item(
                name: entry.name, path: path,
                isDirectory: entry.isDirectory, depth: depth
            )
            out.append(item)
            if item.isDirectory, expanded.contains(item.path) {
                appendRemoteChildren(of: item.path, depth: depth + 1, into: &out)
            }
        }
    }

    private func showDraftRow() {
        removeDraftRow()
        guard let draft else { return }
        let index: Int
        let depth: Int
        if draft.parentDir == rootPath {
            index = 0
            depth = 0
        } else if let parent = items.firstIndex(where: { $0.path == draft.parentDir }) {
            index = parent + 1
            depth = items[parent].depth + 1
        } else {
            return
        }
        items.insert(Item(name: "", path: draft.parentDir + "/\u{1}draft",
                          isDirectory: draft.isDirectory, depth: depth, isDraft: true), at: index)
    }

    private func removeDraftRow() {
        if let index = items.firstIndex(where: \.isDraft) { items.remove(at: index) }
    }

    // MARK: - Local background refresh

    private func invalidateLocalRefresh() {
        localGeneration &+= 1
        localRefreshTask?.cancel()
        localRefreshPending = false
        localListings = [:]
        localInvalidatedDirectories = []
    }

    private func refreshLocal() {
        guard remoteEndpoint == nil, !rootPath.isEmpty else { return }
        guard localRefreshTask == nil else {
            localRefreshPending = true
            return
        }
        localRefreshPending = false
        let root = rootPath
        let generation = localGeneration
        let revision = localRevision
        let expanded = expanded
        let draft = draft
        let listings = localListings
        let invalidated = localInvalidatedDirectories
        let previousItems = items
        localRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let result = Self.buildLocalTree(root: root, expanded: expanded, draft: draft,
                                            listings: listings, invalidated: invalidated,
                                            previousItems: previousItems)
            await MainActor.run { [weak self] in
                self?.finishLocalRefresh(result, root: root, generation: generation, revision: revision)
            }
        }
    }

    private func finishLocalRefresh(_ result: LocalTreeResult, root: String, generation: Int, revision: Int) {
        localRefreshTask = nil
        if generation == localGeneration, root == rootPath, remoteEndpoint == nil {
            localListings = result.listings
            if revision == localRevision, result.isComplete {
                localInvalidatedDirectories = []
                if let rows = result.items { items = rows }
            }
        }
        if localRefreshPending {
            localRefreshPending = false
            refreshLocal()
        }
    }

    private nonisolated struct LocalEntry: Sendable {
        let name: String
        let path: String
        var isDirectory: Bool
        let needsTypeCheck: Bool
    }

    private nonisolated struct DirectoryStamp: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let modifiedSeconds: time_t
        let modifiedNanoseconds: Int
        let changedSeconds: time_t
        let changedNanoseconds: Int

        init?(_ path: String) {
            var metadata = stat()
            guard stat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return nil }
            device = metadata.st_dev
            inode = metadata.st_ino
            modifiedSeconds = metadata.st_mtimespec.tv_sec
            modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
            changedSeconds = metadata.st_ctimespec.tv_sec
            changedNanoseconds = metadata.st_ctimespec.tv_nsec
        }
    }

    private nonisolated struct LocalListing: Sendable {
        let stamp: DirectoryStamp?
        let children: [LocalEntry]
    }

    private nonisolated struct LocalTreeResult: Sendable {
        let listings: [String: LocalListing]
        let items: [Item]?
        let isComplete: Bool
    }

    private nonisolated static func buildLocalTree(
        root: String, expanded: Set<String>, draft: Draft?, listings: [String: LocalListing],
        invalidated: Set<String>, previousItems: [Item]
    ) -> LocalTreeResult {
        var nextListings: [String: LocalListing] = [:]
        var rows: [Item] = []
        let complete = appendLocalChildren(of: root, depth: 0, expanded: expanded, draft: draft,
                                           listings: listings, invalidated: invalidated,
                                           nextListings: &nextListings, into: &rows)
            && !Task.isCancelled
        return LocalTreeResult(listings: nextListings,
                               items: complete && rows != previousItems ? rows : nil, isComplete: complete)
    }

    private nonisolated static func appendLocalChildren(
        of dir: String, depth: Int, expanded: Set<String>, draft: Draft?,
        listings: [String: LocalListing], invalidated: Set<String>,
        nextListings: inout [String: LocalListing], into out: inout [Item]
    ) -> Bool {
        // Guard against runaway recursion through symlink cycles.
        guard depth < 32 else { return true }
        guard !Task.isCancelled else { return false }
        // Show the inline new-file/folder input at the top of its folder.
        if let draft, draft.parentDir == dir {
            out.append(
                Item(
                    name: "", path: dir + "/\u{1}draft",
                    isDirectory: draft.isDirectory, depth: depth, isDraft: true
                )
            )
        }
        guard let listing = readLocalListing(dir, cached: invalidated.contains(dir) ? nil : listings[dir])
        else { return false }
        nextListings[dir] = listing
        for entry in listing.children {
            guard !Task.isCancelled else { return false }
            let child = Item(name: entry.name, path: entry.path, isDirectory: entry.isDirectory, depth: depth)
            out.append(child)
            if child.isDirectory, expanded.contains(child.path) {
                guard appendLocalChildren(of: child.path, depth: depth + 1, expanded: expanded, draft: draft,
                                          listings: listings, invalidated: invalidated,
                                          nextListings: &nextListings, into: &out) else { return false }
            }
        }
        return true
    }

    private nonisolated static func readLocalListing(_ dir: String, cached: LocalListing?) -> LocalListing? {
        guard !Task.isCancelled else { return nil }
        guard let stamp = DirectoryStamp(dir) else { return LocalListing(stamp: nil, children: []) }
        let fm = FileManager.default
        if let cached, cached.stamp == stamp {
            var children = cached.children
            var changed = false
            // A symlink's target can change type without changing its parent directory.
            for index in children.indices where children[index].needsTypeCheck {
                guard !Task.isCancelled else { return nil }
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: children[index].path, isDirectory: &isDirectory)
                if children[index].isDirectory != isDirectory.boolValue {
                    children[index].isDirectory = isDirectory.boolValue
                    changed = true
                }
            }
            if changed { sortLocalEntries(&children) }
            return LocalListing(stamp: DirectoryStamp(dir) == stamp ? stamp : nil, children: children)
        }
        guard let directory = opendir(dir) else { return LocalListing(stamp: nil, children: []) }
        defer { closedir(directory) }
        var children: [LocalEntry] = []
        while true {
            guard !Task.isCancelled else { return nil }
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { return LocalListing(stamp: nil, children: []) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    fm.string(withFileSystemRepresentation: $0, length: Int(entry.pointee.d_namlen))
                }
            }
            guard name != ".", name != "..", name != ".git" else { continue }
            let path = (dir as NSString).appendingPathComponent(name)
            let type = Int32(entry.pointee.d_type)
            var isDirectory = type == DT_DIR
            if type == DT_LNK || type == DT_UNKNOWN {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDir)
                isDirectory = isDir.boolValue
            }
            children.append(LocalEntry(name: name, path: path, isDirectory: isDirectory,
                                       needsTypeCheck: type == DT_LNK || type == DT_UNKNOWN))
        }
        guard !Task.isCancelled else { return nil }
        sortLocalEntries(&children)
        // Never reuse a listing if the directory changed while it was being scanned.
        return LocalListing(stamp: DirectoryStamp(dir) == stamp ? stamp : nil, children: children)
    }

    private nonisolated static func sortLocalEntries(_ entries: inout [LocalEntry]) {
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
