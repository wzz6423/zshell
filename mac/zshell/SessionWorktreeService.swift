import Darwin
import Foundation

nonisolated struct SessionWorktree: Codable, Equatable, Sendable {
    struct FileIdentity: Codable, Equatable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    let path: String
    let repositoryRoot: String
    let commonGitDirectory: String
    let gitDirectory: String
    let branch: String?
    let baseReference: String?
    let createdBranch: Bool
    let initialHead: String
    var gitDirectoryIdentity: FileIdentity? = nil
}

nonisolated struct SessionWorktreeError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// The Git panel and session lifecycle share one path for worktree mutations.
/// Cleanup never forces removal or deletes a branch.
nonisolated struct SessionWorktreeService: Sendable {
    struct Record: Equatable, Sendable {
        let path: String
        let headOID: String?
        let branch: String?
        let isBare: Bool
        let isLocked: Bool
        let isPrunable: Bool
    }

    struct Repository: Sendable {
        let root: String
        let commonGitDirectory: String
        let head: String
        let branches: [String]
        let defaultReference: String?
        let worktrees: [Record]
    }

    enum Base: Equatable, Sendable {
        case repositoryDefault
        case currentHead
        case reference(String)
    }

    struct Inspection: Equatable, Sendable {
        let head: String
        let branch: String?
        let changedPaths: Int
        let unmergedCommits: Int?
        let isLocked: Bool

        var canRemove: Bool {
            changedPaths == 0 && unmergedCommits == 0 && !isLocked
        }

        var refusal: String? {
            if isLocked { return String(localized: "The worktree is locked. Unlock it in Git before removing it.") }
            if changedPaths > 0 {
                return String(localized: "The worktree contains changed, untracked, or ignored files. Keep it and commit or remove those files first.")
            }
            if unmergedCommits == nil {
                return String(localized: "The merge baseline is unavailable. Keep the worktree and review its branch in Git.")
            }
            if unmergedCommits != 0 {
                return String(localized: "The worktree has commits that are not merged into its baseline. Keep it and merge the branch first.")
            }
            return nil
        }
    }

    let runner: any GitCommandRunning

    init(runner: any GitCommandRunning = GitCommandRunner()) {
        self.runner = runner
    }

    func repository(at directory: String) async throws -> Repository {
        let directory = try Self.absoluteDirectory(directory)
        let bare = await runner.run(["rev-parse", "--is-bare-repository"], in: directory)
        guard bare.status == 0 else {
            throw SessionWorktreeError(message: String(localized: "Choose a directory inside a Git repository."))
        }
        guard Self.line(bare.stdout) == "false" else {
            throw SessionWorktreeError(message: String(localized: "Bare repositories cannot start worktree sessions. Open a normal checkout first."))
        }
        let root = Self.canonical(try await command(["rev-parse", "--show-toplevel"], in: directory))
        let common = Self.canonical(try await command([
            "rev-parse", "--path-format=absolute", "--git-common-dir",
        ], in: root))
        let head = try await command(["rev-parse", "--verify", "HEAD^{commit}"], in: root)
        let branches = try await command([
            "for-each-ref", "--format=%(refname:strip=2)", "refs/heads/",
        ], in: root).split(separator: "\n").map(String.init)
        let worktrees = try await records(in: root)
        let defaultReference = try await defaultReference(in: root, branches: branches)
        return Repository(root: root, commonGitDirectory: common, head: head,
                          branches: branches, defaultReference: defaultReference, worktrees: worktrees)
    }

    func create(
        in directory: String, branch: String, at destination: String? = nil,
        base: Base = .repositoryDefault, expectedHead: String? = nil,
        requiresExistingBranch: Bool = false
    ) async throws -> SessionWorktree {
        let repository = try await repository(at: directory)
        if let expectedHead, repository.head != expectedHead {
            throw SessionWorktreeError(message: String(localized: "Repository HEAD changed. Review the baseline and try again."))
        }
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let checked = await runner.run(["check-ref-format", "--branch", name], in: repository.root)
        guard !name.isEmpty, checked.status == 0, Self.line(checked.stdout) == name else {
            throw SessionWorktreeError(message: String(localized: "Enter a valid local Git branch name."))
        }
        let exists = repository.branches.contains(name)
        guard !requiresExistingBranch || exists else {
            throw SessionWorktreeError(message: String(localized: "The selected branch is no longer available"))
        }
        guard !repository.worktrees.contains(where: { $0.branch == name }) else {
            throw SessionWorktreeError(message: String(localized: "That branch is already checked out in a worktree"))
        }
        let baseReference: String?
        switch base {
        case .repositoryDefault: baseReference = repository.defaultReference
        case .currentHead:
            let symbolic = await runner.run(["symbolic-ref", "--quiet", "HEAD"], in: repository.root)
            baseReference = symbolic.status == 0 ? Self.line(symbolic.stdout) : repository.head
        case .reference(let reference): baseReference = reference
        }
        guard exists || baseReference != nil else {
            throw SessionWorktreeError(message: String(localized: "No default branch was found. Choose Current HEAD or an explicit baseline."))
        }
        let initialHead = exists
            ? try await command(["rev-parse", "--verify", "refs/heads/\(name)^{commit}"], in: repository.root)
            : try await command(["rev-parse", "--verify", "--end-of-options", "\(baseReference!)^{commit}"], in: repository.root)
        let requested = destination ?? Self.defaultPath(repositoryRoot: repository.root, branch: name)
        guard requested.hasPrefix("/"), !requested.contains("\0") else {
            throw SessionWorktreeError(message: String(localized: "Choose an absolute directory for the worktree."))
        }
        let path = Self.canonical(requested)
        guard !Self.entryExists(requested), !Self.entryExists(path) else {
            throw SessionWorktreeError(message: String(localized: "The worktree directory already exists. Choose a new directory."))
        }
        var createdParents: [(path: String, identity: FileIdentity)] = []
        var reservedIdentity: FileIdentity?
        var ownsBranch = false
        do {
            try Self.createParents(of: path, created: &createdParents)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            reservedIdentity = Self.fileIdentity(path)
            if !exists {
                _ = try await command(["branch", "--no-track", "--", name, initialHead], in: repository.root)
                ownsBranch = true
            }
            let args = ["worktree", "add", "--", path, name]
            let run = await runner.run(args, in: repository.root)
            guard run.status == 0 else { throw Self.failure(run) }
            let association = try await association(at: path, repository: repository,
                                                    baseReference: baseReference, createdBranch: ownsBranch,
                                                    initialHead: initialHead)
            guard association.branch == name else {
                throw SessionWorktreeError(message: String(localized: "The worktree changed before the session could start."))
            }
            return association
        } catch {
            await rollbackFailedCreation(path: path, identity: reservedIdentity, repository: repository,
                                         branch: name, initialHead: initialHead, createdBranch: ownsBranch)
            Self.removeEmptyParents(createdParents)
            throw error
        }
    }

    func association(at path: String, sourceDirectory: String) async throws -> SessionWorktree {
        let repository = try await repository(at: sourceDirectory)
        return try await association(at: path, repository: repository,
                                     baseReference: repository.defaultReference, createdBranch: false,
                                     initialHead: nil)
    }

    func inspect(_ worktree: SessionWorktree) async throws -> Inspection {
        let record = try await validatedRecord(worktree)
        let status = try await command([
            "status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=matching",
        ], in: worktree.path, stripLineEnding: false)
        let paths = status.split(separator: "\0").filter {
            $0.hasPrefix("1 ") || $0.hasPrefix("2 ") || $0.hasPrefix("u ") || $0.hasPrefix("? ") || $0.hasPrefix("! ")
        }.count
        var unmerged: Int?
        if let baseReference = worktree.baseReference,
           let baseHead = try? await command([
               "rev-parse", "--verify", "--end-of-options", "\(baseReference)^{commit}",
           ], in: worktree.path), let head = record.headOID,
           let count = try? await command(["rev-list", "--count", "\(baseHead)..\(head)"], in: worktree.path) {
            unmerged = Int(count)
        }
        return Inspection(head: record.headOID ?? "", branch: record.branch, changedPaths: paths,
                          unmergedCommits: unmerged, isLocked: record.isLocked)
    }

    func remove(
        _ worktree: SessionWorktree, expected: Inspection? = nil,
        requireMerged: Bool = true,
        isInUse: @Sendable () async -> Bool = { false }
    ) async throws {
        let current = try await inspect(worktree)
        if let expected, current != expected {
            throw SessionWorktreeError(message: String(localized: "The worktree changed. Review it before removing it."))
        }
        guard current.changedPaths == 0, !current.isLocked,
              !requireMerged || current.unmergedCommits == 0 else {
            throw SessionWorktreeError(message: current.refusal ?? String(localized: "The worktree cannot be removed safely."))
        }
        guard !(await isInUse()) else {
            throw SessionWorktreeError(message: String(localized: "Other open sessions still use this worktree. Close them before removing it."))
        }
        _ = try await command(["worktree", "remove", "--", worktree.path], in: worktree.commonGitDirectory)
    }

    /// Startup failures only roll back the exact empty checkout this call made.
    /// A changed checkout remains available for inspection instead of losing data.
    func rollback(_ worktree: SessionWorktree, isInUse: @Sendable () async -> Bool = { false }) async -> Bool {
        guard let inspection = try? await inspect(worktree), inspection.head == worktree.initialHead,
              inspection.changedPaths == 0, !inspection.isLocked else { return false }
        do {
            try await remove(worktree, expected: inspection, requireMerged: false, isInUse: isInUse)
            if worktree.createdBranch {
                await removeCreatedBranch(worktree.branch, expectedHead: worktree.initialHead,
                                          in: worktree.commonGitDirectory)
            }
            return true
        } catch { return false }
    }

    static func defaultPath(repositoryRoot: String, branch: String) -> String {
        let root = URL(fileURLWithPath: repositoryRoot, isDirectory: true)
        let name = branch.replacingOccurrences(of: "/", with: "-")
        return root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + ".worktrees", isDirectory: true)
            .appendingPathComponent(name.isEmpty ? "new-session" : name, isDirectory: true).path
    }

    static func contains(_ directory: String, in worktreePath: String) -> Bool {
        let directory = canonical(directory)
        let root = canonical(worktreePath)
        return directory == root || directory.hasPrefix(root + "/")
    }

    static func parseWorktrees(_ output: String) -> [Record] {
        let records = output.contains("\0")
            ? output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            : output.components(separatedBy: "\n")
        var result: [Record] = []
        var path: String?
        var head: String?
        var branch: String?
        var bare = false
        var locked = false
        var prunable = false
        func append() {
            if let path { result.append(Record(path: canonical(path), headOID: head, branch: branch,
                                              isBare: bare, isLocked: locked, isPrunable: prunable)) }
            path = nil; head = nil; branch = nil; bare = false; locked = false; prunable = false
        }
        for record in records {
            if record.isEmpty { append() }
            else if record.hasPrefix("worktree ") {
                if path != nil { append() }
                path = String(record.dropFirst(9))
            } else if record.hasPrefix("HEAD ") { head = String(record.dropFirst(5)) }
            else if record.hasPrefix("branch refs/heads/") { branch = String(record.dropFirst(18)) }
            else if record == "bare" { bare = true }
            else if record == "locked" || record.hasPrefix("locked ") { locked = true }
            else if record == "prunable" || record.hasPrefix("prunable ") { prunable = true }
        }
        append()
        return result
    }

    private func defaultReference(in root: String, branches: [String]) async throws -> String? {
        let remotes = try await command(["remote"], in: root).split(separator: "\n").map(String.init)
        let ordered = remotes.sorted { $0 == "origin" && $1 != "origin" }
        for remote in ordered {
            let run = await runner.run(["symbolic-ref", "--quiet", "refs/remotes/\(remote)/HEAD"], in: root)
            let reference = Self.line(run.stdout)
            let prefix = "refs/remotes/\(remote)/"
            if run.status == 0, reference.hasPrefix(prefix) {
                let name = String(reference.dropFirst(prefix.count))
                return branches.contains(name) ? "refs/heads/\(name)" : reference
            }
        }
        return ["main", "master"].first(where: branches.contains).map { "refs/heads/\($0)" }
    }

    private func records(in root: String) async throws -> [Record] {
        Self.parseWorktrees(try await command(["worktree", "list", "--porcelain", "-z"], in: root, stripLineEnding: false))
    }

    private func association(
        at path: String, repository: Repository, baseReference: String?,
        createdBranch: Bool, initialHead: String?
    ) async throws -> SessionWorktree {
        let path = Self.canonical(path)
        guard let record = try await records(in: repository.root).first(where: { $0.path == path }),
              !record.isBare, !record.isPrunable, let head = record.headOID else {
            throw SessionWorktreeError(message: String(localized: "The selected worktree is no longer available"))
        }
        let gitDirectory = Self.canonical(try await command(["rev-parse", "--absolute-git-dir"], in: path))
        guard gitDirectory.hasPrefix(repository.commonGitDirectory + "/worktrees/"),
              let identity = Self.fileIdentity(gitDirectory) else {
            throw SessionWorktreeError(message: String(localized: "The main checkout cannot be removed with a session."))
        }
        let primaryRoot = repository.worktrees.first(where: { !$0.isBare })?.path ?? repository.root
        return SessionWorktree(path: path, repositoryRoot: primaryRoot,
                               commonGitDirectory: repository.commonGitDirectory, gitDirectory: gitDirectory,
                               branch: record.branch, baseReference: baseReference, createdBranch: createdBranch,
                               initialHead: initialHead ?? head, gitDirectoryIdentity: identity)
    }

    private func validatedRecord(_ worktree: SessionWorktree) async throws -> Record {
        guard Self.entryExists(worktree.path), let record = try await records(in: worktree.commonGitDirectory)
            .first(where: { $0.path == worktree.path }), !record.isBare, !record.isPrunable else {
            throw SessionWorktreeError(message: String(localized: "The selected worktree is no longer available"))
        }
        let actualGit = Self.canonical(try await command(["rev-parse", "--absolute-git-dir"], in: worktree.path))
        let actualCommon = Self.canonical(try await command([
            "rev-parse", "--path-format=absolute", "--git-common-dir",
        ], in: worktree.path))
        guard actualGit == worktree.gitDirectory, actualCommon == worktree.commonGitDirectory,
              actualGit.hasPrefix(actualCommon + "/worktrees/"), record.branch == worktree.branch,
              let identity = worktree.gitDirectoryIdentity, Self.fileIdentity(actualGit) == identity else {
            throw SessionWorktreeError(message: String(localized: "The worktree changed before the session could start."))
        }
        return record
    }

    private func rollbackFailedCreation(
        path: String, identity: FileIdentity?, repository: Repository,
        branch: String, initialHead: String, createdBranch: Bool
    ) async {
        guard let identity else { return }
        if !Self.entryExists(path) {
            if createdBranch { await removeCreatedBranch(branch, expectedHead: initialHead, in: repository.commonGitDirectory) }
            return
        }
        guard Self.fileIdentity(path) == identity else { return }
        if let association = try? await association(at: path, repository: repository,
                                                   baseReference: nil, createdBranch: createdBranch,
                                                   initialHead: initialHead), association.branch == branch {
            _ = await rollback(association)
        } else if (try? FileManager.default.contentsOfDirectory(atPath: path).isEmpty) == true {
            if rmdir(path) == 0, createdBranch {
                await removeCreatedBranch(branch, expectedHead: initialHead, in: repository.commonGitDirectory)
            }
        }
    }

    private func removeCreatedBranch(_ branch: String?, expectedHead: String, in directory: String) async {
        guard let branch, let records = try? await records(in: directory),
              !records.contains(where: { $0.branch == branch }) else { return }
        _ = await runner.run(["update-ref", "-d", "refs/heads/\(branch)", expectedHead], in: directory)
    }

    private func command(_ args: [String], in directory: String, stripLineEnding: Bool = true) async throws -> String {
        let result = await runner.run(args, in: directory)
        guard result.status == 0 else { throw Self.failure(result) }
        return stripLineEnding ? Self.line(result.stdout) : result.stdout
    }

    private static func failure(_ result: GitCommandResult) -> SessionWorktreeError {
        let message = [result.stderr, result.stdout].map(line).first { !$0.isEmpty }
        return SessionWorktreeError(message: message ?? String(localized: "Git command failed"))
    }

    private static func line(_ string: String) -> String {
        var string = string
        if string.hasSuffix("\n") { string.removeLast() }
        if string.hasSuffix("\r") { string.removeLast() }
        return string
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func absoluteDirectory(_ directory: String) throws -> String {
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            throw SessionWorktreeError(message: String(localized: "Choose an absolute directory inside a Git repository."))
        }
        let path = canonical(directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SessionWorktreeError(message: String(localized: "The selected directory is no longer available."))
        }
        return path
    }

    private typealias FileIdentity = SessionWorktree.FileIdentity

    private static func fileIdentity(_ path: String) -> FileIdentity? {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { return nil }
        return FileIdentity(device: value.st_dev, inode: value.st_ino)
    }

    private static func entryExists(_ path: String) -> Bool {
        var value = stat()
        return lstat(path, &value) == 0 || errno != ENOENT
    }

    private static func createParents(of path: String, created: inout [(path: String, identity: FileIdentity)]) throws {
        var parent = (path as NSString).deletingLastPathComponent
        var missing: [String] = []
        while !entryExists(parent) {
            missing.append(parent)
            let next = (parent as NSString).deletingLastPathComponent
            guard next != parent else { break }
            parent = next
        }
        for directory in missing.reversed() {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            if let identity = fileIdentity(directory) { created.append((directory, identity)) }
        }
    }

    private static func removeEmptyParents(_ paths: [(path: String, identity: FileIdentity)]) {
        for (path, identity) in paths.reversed() where fileIdentity(path) == identity {
            _ = rmdir(path)
        }
    }
}
