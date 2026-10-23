//
//  AgentTurnReview.swift
//  zshell
//

import Combine
import CryptoKit
import Darwin
import Foundation

nonisolated enum AgentReviewError: Error, LocalizedError {
    case git(String)
    case limit
    case unsafePath
    case stale
    case unavailable
    case active
    case overlapping
    case missingParent
    case concurrent(String)

    var errorDescription: String? {
        switch self {
        case .git(let message): message
        case .limit: String(localized: "Review snapshot exceeded its size or time limit.")
        case .unsafePath: String(localized: "This file cannot be safely reviewed or reverted.")
        case .stale: String(localized: "The file changed after this review snapshot. Revert was cancelled.")
        case .unavailable: String(localized: "No completed turn snapshot is available for this agent.")
        case .active: String(localized: "Wait for all agents in this repository to finish before reverting.")
        case .overlapping: String(localized: "Concurrent agent turns share this snapshot. Revert is unavailable.")
        case .missingParent: String(localized: "This file cannot be safely reviewed or reverted.")
        case .concurrent(let path): String(
            localized: "Concurrent edits were preserved at \(path). Inspect them before retrying.",
            comment: "The placeholder is the path holding a concurrent edit that could not be restored safely."
        )
        }
    }
}

nonisolated struct AgentWorkspaceSnapshot: Sendable {
    let root: String
    let tree: String
    let head: String?
    let branch: String?
    let excluded: Set<String>
}

nonisolated struct AgentReviewFile: Identifiable, Sendable {
    let path: String
    let status: String
    let beforeMode: String
    let afterMode: String
    let beforeBlob: String?
    let afterBlob: String?
    var excluded = false
    var id: String { path }
    var supportsHunks: Bool {
        !excluded && [beforeMode, afterMode].allSatisfy {
            $0 == "000000" || $0 == "100644" || $0 == "100755"
        }
    }
}

nonisolated struct AgentReviewHunk: Identifiable, Sendable {
    let id: String
    let header: String
    let oldStart: Int
    let newStart: Int
    let before: [String]
    let after: [String]
}

nonisolated struct AgentReviewFileContents: Sendable {
    let before: Data?
    let after: Data?
    let hunks: [AgentReviewHunk]
}

/// Snapshot trees live in Git's object store, but never enter the user's index,
/// refs, or reflog. Only dirty and untracked paths need to be read and hashed.
nonisolated enum AgentReviewGit {
    static let maxFileBytes = 5 << 20
    static let maxSnapshotBytes = 25 << 20
    static let maxPaths = 2_048

    static func command(
        _ args: [String], in root: String,
        environment: [String: String] = [:], input: Data? = nil,
        limit: Int = 10 << 20
    ) throws -> Data {
        let result = GitCommandRunner.runData(
            ["-c", "core.fsmonitor=false", "--literal-pathspecs"] + args,
            in: root, environment: environment, input: input, limit: limit
        )
        guard !result.truncated else { throw AgentReviewError.limit }
        guard result.status == 0 else { throw AgentReviewError.git(result.stderr) }
        return result.stdout
    }

    static func string(_ args: [String], in root: String) throws -> String {
        let data = try command(args, in: root)
        return String(decoding: data.last == 10 ? data.dropLast() : data[...], as: UTF8.self)
    }

    static func capture(
        in directory: String, deadline: Date = Date().addingTimeInterval(10)
    ) throws -> AgentWorkspaceSnapshot {
        let root = try string(["rev-parse", "--show-toplevel"], in: directory)
        let canonicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let head = try? string(["rev-parse", "--verify", "HEAD"], in: canonicalRoot)
        let branch = try? string(["symbolic-ref", "--quiet", "--short", "HEAD"], in: canonicalRoot)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshell-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let environment = ["GIT_INDEX_FILE": temporary.appendingPathComponent("index").path]
        _ = try command(["read-tree", head ?? "--empty"], in: canonicalRoot, environment: environment)

        let tracked = try command(
            head == nil ? ["ls-files", "--cached", "-z"]
                : ["diff", "--name-only", "--no-renames", "--no-ext-diff", "--no-textconv", "-z", head!, "--"],
            in: canonicalRoot
        )
        let untracked = try command(["ls-files", "--others", "--exclude-standard", "-z"], in: canonicalRoot)
        guard let pathsText = String(data: tracked + untracked, encoding: .utf8) else {
            throw AgentReviewError.unsafePath
        }
        let paths = Set(pathsText.split(separator: "\0").map(String.init))
        guard paths.count <= maxPaths, Date() < deadline else { throw AgentReviewError.limit }
        let emptyBlob = try string(["hash-object", "--stdin"], in: canonicalRoot)
        var updates = Data()
        var excluded = Set<String>()
        var bytes = 0
        for path in paths.sorted() {
            guard Date() < deadline else { throw AgentReviewError.limit }
            let content: WorktreeFile?
            do {
                content = try readFile(root: canonicalRoot, path: path)
            } catch AgentReviewError.limit {
                excluded.insert(path)
                continue
            } catch AgentReviewError.unsafePath {
                excluded.insert(path)
                continue
            }
            if let content {
                bytes += content.data.count
                guard bytes <= maxSnapshotBytes else { throw AgentReviewError.limit }
                let hash = try command(
                    ["hash-object", "-w", "--stdin"], in: canonicalRoot, input: content.data
                )
                let oid = String(decoding: hash, as: UTF8.self).trimmingCharacters(in: .newlines)
                updates.append(Data("\(content.mode) \(oid)\t\(path)\0".utf8))
            } else {
                updates.append(Data("0 \(emptyBlob)\t\(path)\0".utf8))
            }
        }
        _ = try command(
            ["update-index", "-z", "--index-info"], in: canonicalRoot,
            environment: environment, input: updates
        )
        let treeData = try command(["write-tree"], in: canonicalRoot, environment: environment)
        let currentHead = try? string(["rev-parse", "--verify", "HEAD"], in: canonicalRoot)
        guard head == currentHead else { throw AgentReviewError.stale }
        guard Date() < deadline else { throw AgentReviewError.limit }
        return AgentWorkspaceSnapshot(
            root: canonicalRoot,
            tree: String(decoding: treeData, as: UTF8.self).trimmingCharacters(in: .newlines),
            head: head, branch: branch, excluded: excluded
        )
    }

    static func files(
        from before: AgentWorkspaceSnapshot, to after: AgentWorkspaceSnapshot
    ) throws -> [AgentReviewFile] {
        guard before.root == after.root else { throw AgentReviewError.stale }
        let raw = try command([
            "diff", "--raw", "--no-abbrev", "--no-renames", "--no-ext-diff", "-z",
            before.tree, after.tree, "--",
        ], in: after.root)
        guard let text = String(data: raw, encoding: .utf8) else { throw AgentReviewError.unsafePath }
        let records = text.split(separator: "\0", omittingEmptySubsequences: true)
        var entries: [AgentReviewFile] = []
        let excluded = before.excluded.union(after.excluded)
        var index = 0
        while index + 1 < records.count {
            let fields = records[index].split(separator: " ")
            guard fields.count == 5, fields[0].first == ":" else { throw AgentReviewError.unsafePath }
            let path = String(records[index + 1])
            if !excluded.contains(path) {
                entries.append(AgentReviewFile(
                    path: path, status: String(fields[4]),
                    beforeMode: String(fields[0].dropFirst()), afterMode: String(fields[1]),
                    beforeBlob: fields[2].allSatisfy({ $0 == "0" }) ? nil : String(fields[2]),
                    afterBlob: fields[3].allSatisfy({ $0 == "0" }) ? nil : String(fields[3])
                ))
            }
            index += 2
        }
        entries += excluded.map {
            AgentReviewFile(
                path: $0, status: "!", beforeMode: "000000", afterMode: "000000",
                beforeBlob: nil, afterBlob: nil, excluded: true
            )
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func comparisonBase(
        in root: String, branch: Bool, reference: String? = nil
    ) throws -> AgentWorkspaceSnapshot {
        var base = try? string(["rev-parse", "--verify", "HEAD^{tree}"], in: root)
        let head = try? string(["rev-parse", "--verify", "HEAD"], in: root)
        let currentBranch = try? string(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
        if branch {
            let remoteHead = try? string(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], in: root)
            let candidates = [reference, remoteHead, "refs/heads/main", "refs/heads/master"].compactMap { $0 }
            guard let reference = candidates.first(where: {
                (try? string(["rev-parse", "--verify", $0], in: root)) != nil
            }) else { throw AgentReviewError.unavailable }
            base = try string(["merge-base", "HEAD", reference], in: root)
        }
        if base == nil {
            base = String(decoding: try command(["mktree"], in: root, input: Data()), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
        }
        return AgentWorkspaceSnapshot(root: root, tree: base!, head: head, branch: currentBranch, excluded: [])
    }

    static func contents(
        for file: AgentReviewFile, before: AgentWorkspaceSnapshot, after: AgentWorkspaceSnapshot
    ) throws -> AgentReviewFileContents {
        guard !file.excluded else { throw AgentReviewError.limit }
        func blob(_ oid: String?) throws -> Data? {
            guard let oid else { return nil }
            guard let size = Int(try string(["cat-file", "-s", oid], in: after.root)),
                  size <= maxFileBytes else { throw AgentReviewError.limit }
            return try command(["cat-file", "blob", oid], in: after.root, limit: maxFileBytes)
        }
        let old = try blob(file.beforeBlob)
        let new = try blob(file.afterBlob)
        guard file.supportsHunks,
              [old, new].allSatisfy({ $0 == nil || (!$0!.contains(0) && String(data: $0!, encoding: .utf8) != nil) })
        else { return AgentReviewFileContents(before: old, after: new, hunks: []) }
        let patch = try command([
            "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--unified=3",
            before.tree, after.tree, "--", file.path,
        ], in: after.root)
        return AgentReviewFileContents(before: old, after: new, hunks: try parseHunks(patch))
    }

    static func lines(_ data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { throw AgentReviewError.unsafePath }
        let parts = text.components(separatedBy: "\n")
        return parts.enumerated().compactMap { index, line in
            let last = index == parts.count - 1
            return last ? (line.isEmpty ? nil : line) : line + "\n"
        }
    }

    static func parseHunks(_ patch: Data) throws -> [AgentReviewHunk] {
        let regex = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        var hunks: [AgentReviewHunk] = []
        var header: String?
        var oldStart = 0
        var newStart = 0
        var before: [String] = []
        var after: [String] = []
        var lastPrefix: Character?
        func finish() {
            guard let header else { return }
            let fingerprint = SHA256.hash(data: Data((header + before.joined() + "\0" + after.joined()).utf8))
                .map { String(format: "%02x", $0) }.joined()
            hunks.append(AgentReviewHunk(
                id: fingerprint, header: header, oldStart: oldStart, newStart: newStart,
                before: before, after: after
            ))
        }
        for line in try lines(patch) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range) {
                finish()
                header = line.trimmingCharacters(in: .newlines)
                func number(_ group: Int) -> Int {
                    guard let range = Range(match.range(at: group), in: line) else { return 0 }
                    return Int(line[range]) ?? 0
                }
                oldStart = number(1)
                newStart = number(3)
                before = []; after = []; lastPrefix = nil
            } else if header != nil, let prefix = line.first {
                let content = String(line.dropFirst())
                switch prefix {
                case " ": before.append(content); after.append(content)
                case "-": before.append(content)
                case "+": after.append(content)
                case "\\":
                    if lastPrefix == " " || lastPrefix == "-", before.last?.hasSuffix("\n") == true {
                        before[before.count - 1].removeLast()
                    }
                    if lastPrefix == " " || lastPrefix == "+", after.last?.hasSuffix("\n") == true {
                        after[after.count - 1].removeLast()
                    }
                default: throw AgentReviewError.unsafePath
                }
                if prefix != "\\" { lastPrefix = prefix }
            }
        }
        finish()
        guard hunks.count <= maxPaths else { throw AgentReviewError.limit }
        return hunks
    }

    /// Rebuild the expected current file from the immutable end snapshot and
    /// previous decisions. Any later edit, even outside this hunk, rejects a write.
    static func revertedContents(
        _ contents: AgentReviewFileContents, revertedIDs: Set<String>
    ) throws -> Data {
        var result = try lines(contents.after ?? Data())
        for hunk in contents.hunks.reversed() where revertedIDs.contains(hunk.id) {
            let start = max(0, hunk.newStart - 1)
            guard start <= result.count, start + hunk.after.count <= result.count,
                  Array(result[start..<(start + hunk.after.count)]) == hunk.after
            else { throw AgentReviewError.stale }
            result.replaceSubrange(start..<(start + hunk.after.count), with: hunk.before)
        }
        return Data(result.joined().utf8)
    }

    static func revert(
        file: AgentReviewFile, contents: AgentReviewFileContents,
        hunk: AgentReviewHunk, revertedIDs: Set<String>,
        before: AgentWorkspaceSnapshot, after: AgentWorkspaceSnapshot
    ) throws {
        guard file.supportsHunks, contents.hunks.contains(where: { $0.id == hunk.id }),
              !revertedIDs.contains(hunk.id)
        else { throw AgentReviewError.unsafePath }
        let head = try? string(["rev-parse", "--verify", "HEAD"], in: after.root)
        let branch = try? string(["symbolic-ref", "--quiet", "--short", "HEAD"], in: after.root)
        guard head == after.head, branch == after.branch else { throw AgentReviewError.stale }
        let expected = try revertedContents(contents, revertedIDs: revertedIDs)
        let updated = try revertedContents(contents, revertedIDs: revertedIDs.union([hunk.id]))
        let wasDeleted = file.afterBlob == nil && revertedIDs.isEmpty
        let expectedMode = wasDeleted ? nil : (file.afterBlob == nil ? file.beforeMode : file.afterMode)
        let remove = file.beforeBlob == nil && updated.isEmpty
        try withParent(root: after.root, path: file.path) { parent, name in
            func verify() throws -> mode_t? {
                let live = try readFile(parent: parent, name: name)
                guard live?.data == (wasDeleted ? nil : expected), live?.mode == expectedMode else {
                    throw AgentReviewError.stale
                }
                return live?.permissions
            }
            let permissions = try verify()
            let temporary = ".zshell-review-\(UUID().uuidString)"
            let parentPath = (file.path as NSString).deletingLastPathComponent
            let recoveryPath = parentPath.isEmpty ? temporary : parentPath + "/" + temporary
            let recoveryError = AgentReviewError.concurrent(
                URL(fileURLWithPath: after.root).appendingPathComponent(recoveryPath).path
            )
            if remove {
                // Move first, then check the displaced file. A final read
                // followed by unlink alone could delete a concurrent save.
                guard renameatx_np(parent, name, parent, temporary, UInt32(RENAME_EXCL)) == 0 else {
                    throw AgentReviewError.stale
                }
                let displaced = try? readFile(parent: parent, name: temporary)
                guard displaced?.data == expected, displaced?.permissions == permissions else {
                    guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                        throw recoveryError
                    }
                    throw AgentReviewError.stale
                }
                guard unlinkat(parent, temporary, 0) == 0 else { throw recoveryError }
                return
            }
            let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            var removeTemporary = true
            defer {
                close(descriptor)
                if removeTemporary { unlinkat(parent, temporary, 0) }
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try handle.write(contentsOf: updated)
            if !wasDeleted {
                let original = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard original >= 0 else { throw AgentReviewError.stale }
                defer { close(original) }
                guard fcopyfile(original, descriptor, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL)) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
            let mode = file.afterBlob == nil ? file.beforeMode : file.afterMode
            guard fchmod(descriptor, permissions ?? (mode == "100755" ? 0o755 : 0o644)) == 0,
                  fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            guard try verify() == permissions else { throw AgentReviewError.stale }
            let flags = wasDeleted ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
            guard renameatx_np(parent, temporary, parent, name, flags) == 0 else {
                throw AgentReviewError.stale
            }
            if !wasDeleted {
                removeTemporary = false
                let displaced = try? readFile(parent: parent, name: temporary)
                guard displaced?.data == expected, displaced?.permissions == permissions else {
                    guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_SWAP)) == 0 else {
                        throw recoveryError
                    }
                    let replacement = try? readFile(parent: parent, name: temporary)
                    guard replacement?.data == updated, replacement?.permissions == permissions else {
                        throw recoveryError
                    }
                    removeTemporary = true
                    throw AgentReviewError.stale
                }
                removeTemporary = true
            }
        }
    }

    struct WorktreeFile {
        let data: Data
        let mode: String
        let permissions: mode_t
    }

    static func readFile(root: String, path: String) throws -> WorktreeFile? {
        do {
            return try withParent(root: root, path: path) { try readFile(parent: $0, name: $1) }
        } catch AgentReviewError.missingParent {
            return nil
        }
    }

    private static func readFile(parent: Int32, name: String) throws -> WorktreeFile? {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AgentReviewError.unsafePath
        }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG else {
            throw AgentReviewError.unsafePath
        }
        guard initial.st_size <= maxFileBytes else { throw AgentReviewError.limit }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while data.count <= maxFileBytes {
            guard let chunk = try handle.read(upToCount: min(64 << 10, maxFileBytes + 1 - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maxFileBytes else { throw AgentReviewError.limit }
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              initial.st_size == final.st_size,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              data.count == initial.st_size else { throw AgentReviewError.stale }
        return WorktreeFile(
            data: data, mode: initial.st_mode & 0o111 == 0 ? "100644" : "100755",
            permissions: initial.st_mode & 0o7777
        )
    }

    private static func withParent<T>(
        root: String, path: String, body: (Int32, String) throws -> T
    ) throws -> T {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let name = components.last else { throw AgentReviewError.unsafePath }
        var descriptor = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentReviewError.unsafePath }
        defer { close(descriptor) }
        for component in components.dropLast() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else {
                // Missing ancestors mean a tracked file was deleted with its directory.
                if errno == ENOENT { throw AgentReviewError.missingParent }
                throw AgentReviewError.unsafePath
            }
            close(descriptor)
            descriptor = next
        }
        return try body(descriptor, name)
    }
}

struct AgentReviewTurn: Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let alias: String
    let directory: String
    let startedAt: Date
    var before: AgentWorkspaceSnapshot?
    var after: AgentWorkspaceSnapshot?
    var isActive = true
    var overlapped = false
    var failure: String?
    var kept: Set<String> = []
    var reverted: Set<String> = []
}

@MainActor
final class AgentTurnReviewStore: ObservableObject {
    static let shared = AgentTurnReviewStore()
    @Published private(set) var revision: UInt = 0
    private var turns: [UUID: AgentReviewTurn] = [:]
    private var starts: [UUID: Task<AgentWorkspaceSnapshot, Error>] = [:]
    private var finishes: [UUID: Task<Void, Never>] = [:]
    private var mutations: Set<String> = []
    var activeAgentCheck: ((String) -> Bool)?

    func records(in root: String) -> [AgentReviewTurn] {
        turns.values.filter { belongs($0, to: root) }.sorted { $0.startedAt > $1.startedAt }
    }

    private func belongs(_ turn: AgentReviewTurn, to root: String) -> Bool {
        if let snapshot = turn.before { return snapshot.root == root }
        let directory = URL(fileURLWithPath: turn.directory).resolvingSymlinksInPath().path
        return directory == root || directory.hasPrefix(root + "/")
    }

    func hasActiveTurn(in root: String) -> Bool {
        turns.values.contains { $0.isActive && belongs($0, to: root) }
            || (activeAgentCheck?(root) ?? false)
    }

    func begin(sessionID: UUID, alias: String, directory: String) async {
        let deadline = Date().addingTimeInterval(10)
        if let finishing = finishes[sessionID] { await finishing.value }
        if turns[sessionID]?.isActive == true {
            _ = try? await starts[sessionID]?.value
            return
        }
        // A revert owns this short interval. Let it finish before releasing a
        // new agent prompt or native turn-start hook back to the provider.
        let canonicalDirectory = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        while mutations.contains(where: { canonicalDirectory == $0 || canonicalDirectory.hasPrefix($0 + "/") }) {
            try? await Task.sleep(for: .milliseconds(10))
            await Task.yield()
        }
        let turn = AgentReviewTurn(
            id: UUID(), sessionID: sessionID, alias: alias,
            directory: canonicalDirectory, startedAt: Date()
        )
        if turns.count >= 64,
           let oldest = turns.values.filter({ !$0.isActive }).min(by: { $0.startedAt < $1.startedAt }) {
            turns.removeValue(forKey: oldest.sessionID)
        }
        turns[sessionID] = turn
        revision &+= 1
        let task = Task.detached(priority: .userInitiated) {
            try AgentReviewGit.capture(in: directory, deadline: deadline)
        }
        starts[sessionID] = task
        do {
            let snapshot = try await task.value
            guard turns[sessionID]?.id == turn.id else { return }
            turns[sessionID]?.before = snapshot
            let concurrent = turns.values.filter {
                $0.sessionID != sessionID && $0.isActive && belongs($0, to: snapshot.root)
            }
            if !concurrent.isEmpty {
                turns[sessionID]?.overlapped = true
                for other in concurrent { turns[other.sessionID]?.overlapped = true }
            }
        } catch {
            if turns[sessionID]?.id == turn.id { turns[sessionID]?.failure = error.localizedDescription }
        }
        revision &+= 1
    }

    func finish(sessionID: UUID) async {
        if let finishing = finishes[sessionID] { await finishing.value; return }
        guard let turn = turns[sessionID], turn.isActive else { return }
        let task = Task { [weak self] in
            await self?.finishTurn(sessionID: sessionID, turn: turn)
            self?.finishes.removeValue(forKey: sessionID)
        }
        finishes[sessionID] = task
        await task.value
    }

    private func finishTurn(sessionID: UUID, turn: AgentReviewTurn) async {
        if let baseline = try? await starts[sessionID]?.value,
           turns[sessionID]?.id == turn.id, turns[sessionID]?.before == nil {
            turns[sessionID]?.before = baseline
        }
        if let before = turns[sessionID]?.before {
            do {
                let after = try await Task.detached(priority: .userInitiated) {
                    try AgentReviewGit.capture(in: before.root)
                }.value
                guard turns[sessionID]?.id == turn.id, turns[sessionID]?.isActive == true else { return }
                turns[sessionID]?.after = after
            } catch {
                if turns[sessionID]?.id == turn.id { turns[sessionID]?.failure = error.localizedDescription }
            }
        }
        guard turns[sessionID]?.id == turn.id, turns[sessionID]?.isActive == true else { return }
        turns[sessionID]?.isActive = false
        starts.removeValue(forKey: sessionID)
        revision &+= 1
    }

    func abort(sessionID: UUID) {
        guard turns[sessionID]?.isActive == true else { return }
        turns[sessionID]?.isActive = false
        turns[sessionID]?.failure = String(localized: "The agent exited before its turn completed.")
        starts.removeValue(forKey: sessionID)
        revision &+= 1
    }

    static func decisionKey(file: AgentReviewFile, hunk: AgentReviewHunk) -> String {
        file.path + "\0" + hunk.id
    }

    func keep(turn: AgentReviewTurn, file: AgentReviewFile, hunk: AgentReviewHunk) throws {
        guard let current = turns[turn.sessionID], current.id == turn.id, !current.isActive else {
            throw AgentReviewError.unavailable
        }
        let key = Self.decisionKey(file: file, hunk: hunk)
        guard !current.reverted.contains(key) else { throw AgentReviewError.stale }
        turns[turn.sessionID]?.kept.insert(key)
        revision &+= 1
    }

    func revert(
        turn: AgentReviewTurn, file: AgentReviewFile,
        contents: AgentReviewFileContents, hunk: AgentReviewHunk
    ) async throws {
        guard let current = turns[turn.sessionID], current.id == turn.id,
              !current.isActive, let before = current.before, let after = current.after else {
            throw AgentReviewError.unavailable
        }
        guard !hasActiveTurn(in: after.root), !mutations.contains(after.root) else { throw AgentReviewError.active }
        guard !current.overlapped else { throw AgentReviewError.overlapping }
        let key = Self.decisionKey(file: file, hunk: hunk)
        let reverted = Set(contents.hunks.filter {
            current.reverted.contains(Self.decisionKey(file: file, hunk: $0))
        }.map(\.id))
        mutations.insert(after.root)
        defer { mutations.remove(after.root) }
        try await Task.detached(priority: .userInitiated) {
            try AgentReviewGit.revert(
                file: file, contents: contents, hunk: hunk,
                revertedIDs: reverted, before: before, after: after
            )
        }.value
        turns[turn.sessionID]?.reverted.insert(key)
        turns[turn.sessionID]?.kept.remove(key)
        revision &+= 1
    }
}
