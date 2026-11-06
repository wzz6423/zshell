import Combine
import Foundation
import PierreDiffsSwift

nonisolated struct ProjectPullRequestReviewIdentity: Hashable, Sendable {
    let context: ProjectPullRequestContext
    let number: Int
    let repository: GitHubRepository

    init?(_ pr: ProjectPullRequest, context: ProjectPullRequestContext) {
        let parts = pr.url.path.split(separator: "/")
        guard pr.number > 0, pr.url.scheme == "https", pr.url.host == "github.com", pr.url.port == nil,
              pr.url.user == nil, pr.url.password == nil, pr.url.query == nil, pr.url.fragment == nil,
              parts.count == 4, parts[2] == "pull", Int(parts[3]) == pr.number,
              let repository = GitHubRepository("\(parts[0])/\(parts[1])") else { return nil }
        self.context = context
        self.number = pr.number
        self.repository = repository
    }

    var url: String { "https://github.com/\(repository.nameWithOwner)/pull/\(number)" }
}

nonisolated struct ProjectPullRequestReviewComment: Decodable, Equatable, Sendable {
    struct Author: Decodable, Equatable, Sendable { let login: String }
    struct Commit: Decodable, Equatable, Sendable { let oid: String }
    let id: String
    let author: Author?
    let body: String
    let url: String
    let commit: Commit?
    let originalCommit: Commit?
}

nonisolated struct ProjectPullRequestReviewThread: Decodable, Equatable, Sendable {
    enum Side: String, Decodable, Sendable { case left = "LEFT", right = "RIGHT" }
    let id: String
    let path: String
    let line: Int?
    let startLine: Int?
    let diffSide: Side
    let startDiffSide: Side?
    let isResolved: Bool
    let isOutdated: Bool
    let subjectType: String
    var comments: CommentConnection

    struct CommentConnection: Decodable, Equatable, Sendable {
        var nodes: [ProjectPullRequestReviewComment]
        let pageInfo: ProjectPullRequestReviewPageInfo
    }

    var isCurrent: Bool {
        // GitHub supplies the current mapped line separately from originalLine;
        // a discussion remains valid after a later commit when it is not outdated.
        guard !isOutdated, subjectType == "LINE", let line, line > 0,
              !comments.nodes.isEmpty else { return false }
        if let startLine {
            return startLine > 0 && startLine <= line && startDiffSide == diffSide
        }
        return true
    }
}

nonisolated struct ProjectPullRequestReviewPageInfo: Decodable, Equatable, Sendable {
    let hasNextPage: Bool
    let endCursor: String?
}

nonisolated struct ProjectPullRequestReviewFile: Equatable, Sendable {
    let identity: ProjectPullRequestReviewIdentity
    let baseOID: String
    let headOID: String
    let mergeBaseOID: String
    let path: String
    let oldPath: String
    let oldContents: String
    let newContents: String
    let threads: [ProjectPullRequestReviewThread]
    let outdatedThreadCount: Int

    var annotationURLs: [String: URL] {
        Dictionary(threads.flatMap(\.comments.nodes).compactMap { comment in
            guard let url = Self.commentURL(comment.url, identity: identity) else { return nil }
            return (comment.id, url)
        }, uniquingKeysWith: { first, _ in first })
    }

    var annotations: [DiffAnnotation] {
        threads.flatMap { thread in
            thread.comments.nodes.map { comment in
                let author = comment.author?.login ?? String(localized: "Deleted user")
                let range = thread.startLine.map { "\($0)–\(thread.line!)" } ?? "\(thread.line!)"
                let resolved = thread.isResolved ? " · " + String(localized: "Resolved") : ""
                return DiffAnnotation(side: thread.diffSide == .left ? .deletions : .additions,
                    lineNumber: thread.line!, metadata: AnnotationMetadata(id: comment.id, author: author,
                        body: comment.body, subtitle: "\(author) · L\(range)\(resolved)", isReadOnly: true))
            }
        }
    }

    static func commentURL(_ value: String, identity: ProjectPullRequestReviewIdentity) -> URL? {
        guard let components = URLComponents(string: value), components.scheme == "https",
              components.host == "github.com", components.port == nil,
              components.user == nil, components.password == nil,
              components.path.lowercased() == "/\(identity.repository.nameWithOwner)/pull/\(identity.number)" else { return nil }
        return components.url
    }
}

nonisolated enum ProjectPullRequestReviewState: Equatable, Sendable {
    enum Failure: Error, Equatable, Sendable {
        case missingCLI, notSignedIn, unavailable, changed, notInPullRequest, binary, tooLarge

        var message: String {
            switch self {
            case .missingCLI: ProjectPullRequestState.Failure.missingCLI.message
            case .notSignedIn: ProjectPullRequestState.Failure.notSignedIn.message
            case .unavailable: String(localized: "PR comments unavailable")
            case .changed: String(localized: "PR changed. Refresh to view current comments.")
            case .notInPullRequest: String(localized: "File is not part of this pull request.")
            case .binary: String(localized: "Binary file")
            case .tooLarge: String(localized: "File is too large to diff")
            }
        }
    }
    case idle, loading
    case ready(ProjectPullRequestReviewFile)
    case failed(Failure)
}

nonisolated enum GitHubPullRequestReviewWorker {
    typealias Command = GitHubPullRequestWorker.Command
    typealias GitCommand = @Sendable ([String], String, Int, TimeInterval) -> GitCommandDataResult
    private static let outputLimit = 8 << 20
    private static let fileLimit = 5 << 20
    private static let threadLimit = 500
    private static let commentLimit = 2_000
    private static let bodyLimit = 2 << 20

    static func lookup(_ identity: ProjectPullRequestReviewIdentity, path: String) async -> ProjectPullRequestReviewState {
        await withCheckedContinuation { continuation in
            GitHubPullRequestWorker.queue.addOperation {
                continuation.resume(returning: query(identity, path: path))
            }
        }
    }

    static func query(
        _ identity: ProjectPullRequestReviewIdentity, path: String,
        environment: [String: String] = GitProxy.processEnvironment(inheriting: ProcessInfo.processInfo.environment),
        locate: @Sendable ([String: String]) -> URL? = { ProcessRunner.resolveExecutable("gh", environment: $0) },
        command: Command = {
            try BoundedProcessRunner.run(executableURL: $0, arguments: $1, timeout: $2,
                                         outputLimit: outputLimit, environment: $3)
        },
        git: GitCommand = { GitCommandRunner.runData($0, in: $1, limit: $2, timeout: $3) }
    ) -> ProjectPullRequestReviewState {
        let environment = GitHubPullRequestWorker.processEnvironment(environment)
        guard let executable = locate(environment) else { return .failed(.missingCLI) }
        guard validPath(path) else { return .failed(.notInPullRequest) }
        let deadline = Date().addingTimeInterval(20)
        var requests = 0
        func run(_ arguments: [String]) throws -> Data {
            requests += 1
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, requests <= 60 else { throw ProjectPullRequestReviewState.Failure.unavailable }
            let result = try command(executable, arguments, remaining, environment)
            guard !result.timedOut, !result.output.wasTruncated else { throw ProjectPullRequestReviewState.Failure.unavailable }
            if result.terminationStatus == 4 { throw ProjectPullRequestReviewState.Failure.notSignedIn }
            guard result.terminationStatus == 0 else { throw ProjectPullRequestReviewState.Failure.unavailable }
            return Data(result.output.stdout.utf8)
        }
        func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
            guard let result = try? JSONDecoder().decode(type, from: data) else {
                throw ProjectPullRequestReviewState.Failure.unavailable
            }
            return result
        }
        func local(_ arguments: [String], limit: Int = outputLimit) throws -> GitCommandDataResult {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ProjectPullRequestReviewState.Failure.unavailable }
            return git(arguments, identity.context.root, limit, min(remaining, 3))
        }
        func pullRequest(cursor: String? = nil, threads: Bool = true) throws -> PullRequestResponse.PullRequest {
            let parts = identity.repository.nameWithOwner.split(separator: "/")
            var args = ["api", "graphql", "--hostname", "github.com", "-f", "query=" + (threads ? reviewQuery : versionQuery),
                        "-f", "owner=" + parts[0], "-f", "name=" + parts[1], "-F", "number=\(identity.number)"]
            if let cursor { args += ["-f", "cursor=" + cursor] }
            let response = try decode(PullRequestResponse.self, run(args))
            guard response.errors?.isEmpty != false, let pr = response.data?.repository?.pullRequest,
                  pr.number == identity.number, pr.url.lowercased() == identity.url,
                  pr.headRefName == identity.context.headBranch,
                  pr.headRepository.flatMap({ GitHubRepository($0.nameWithOwner) }) == identity.context.headRepository,
                  validOID(pr.headRefOid), validOID(pr.baseRefOid) else {
                throw ProjectPullRequestReviewState.Failure.changed
            }
            return pr
        }
        func nextCursor(_ page: ProjectPullRequestReviewPageInfo, seen: inout Set<String>) throws -> String? {
            guard page.hasNextPage else { return nil }
            guard let cursor = page.endCursor, !cursor.isEmpty, cursor.count <= 512, seen.insert(cursor).inserted else {
                throw ProjectPullRequestReviewState.Failure.unavailable
            }
            return cursor
        }
        do {
            let initial = try pullRequest()
            var pr = initial
            var threads: [ProjectPullRequestReviewThread] = []
            var seenThreadIDs = Set<String>(), seenCursors = Set<String>()
            var totalComments = 0, totalBodyBytes = 0
            func account(_ comments: [ProjectPullRequestReviewComment]) throws {
                totalComments += comments.count
                totalBodyBytes += comments.reduce(0) { $0 + $1.body.utf8.count }
                guard totalComments <= commentLimit, totalBodyBytes <= bodyLimit else {
                    throw ProjectPullRequestReviewState.Failure.unavailable
                }
            }
            for page in 0..<10 {
                guard pr.headRefOid == initial.headRefOid, pr.baseRefOid == initial.baseRefOid,
                      let connection = pr.reviewThreads else { throw ProjectPullRequestReviewState.Failure.changed }
                for var thread in connection.nodes {
                    guard seenThreadIDs.insert(thread.id).inserted, validPath(thread.path), threads.count < threadLimit else {
                        throw ProjectPullRequestReviewState.Failure.unavailable
                    }
                    let initialCommentIDs = thread.comments.nodes.map(\.id)
                    guard initialCommentIDs.allSatisfy({ !$0.isEmpty }),
                          Set(initialCommentIDs).count == initialCommentIDs.count else {
                        throw ProjectPullRequestReviewState.Failure.unavailable
                    }
                    try account(thread.comments.nodes)
                    if thread.path == path, thread.isCurrent {
                        var commentCursors = Set<String>()
                        var info = thread.comments.pageInfo
                        var commentIDs = Set(thread.comments.nodes.map(\.id))
                        while let cursor = try nextCursor(info, seen: &commentCursors) {
                            let response = try decode(ThreadResponse.self, run(["api", "graphql", "--hostname", "github.com",
                                "-f", "query=" + commentsQuery, "-f", "id=" + thread.id, "-f", "cursor=" + cursor]))
                            guard response.errors?.isEmpty != false, let node = response.data?.node,
                                  node.id == thread.id, node.pullRequest.number == initial.number,
                                  node.pullRequest.url == initial.url, node.pullRequest.headRefOid == initial.headRefOid,
                                  node.pullRequest.baseRefOid == initial.baseRefOid else {
                                throw ProjectPullRequestReviewState.Failure.changed
                            }
                            try account(node.comments.nodes)
                            for comment in node.comments.nodes {
                                guard !comment.id.isEmpty, commentIDs.insert(comment.id).inserted else {
                                    throw ProjectPullRequestReviewState.Failure.unavailable
                                }
                            }
                            thread.comments.nodes += node.comments.nodes
                            info = node.comments.pageInfo
                        }
                    }
                    threads.append(thread)
                }
                guard let cursor = try nextCursor(connection.pageInfo, seen: &seenCursors) else { break }
                guard page < 9 else { throw ProjectPullRequestReviewState.Failure.unavailable }
                pr = try pullRequest(cursor: cursor)
            }
            let localBase = try local(["merge-base", "--all", initial.baseRefOid, initial.headRefOid], limit: 1_024)
            var mergeBase = localBase.status == 0 && !localBase.truncated
                ? String(decoding: localBase.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !validOID(mergeBase) {
                let head = identity.repository == identity.context.headRepository ? initial.headRefOid
                    : String(identity.context.headRepository.nameWithOwner.split(separator: "/")[0]) + ":" + initial.headRefOid
                let compare = try decode(CompareResponse.self, run(["api",
                    "repos/\(identity.repository.nameWithOwner)/compare/\(initial.baseRefOid)...\(head)",
                    "--hostname", "github.com", "--method", "GET", "--jq", "{merge_base_commit:{sha:.merge_base_commit.sha}} "]))
                mergeBase = compare.merge_base_commit.sha
                guard validOID(mergeBase) else { throw ProjectPullRequestReviewState.Failure.unavailable }
            }
            let names = try local(["diff", "--name-status", "-z", "-M", mergeBase, initial.headRefOid, "--"], limit: 1 << 20)
            let changed: ChangedFile?
            if names.status == 0 && !names.truncated {
                changed = try changedFiles(names.stdout).first { $0.filename == path }
            } else {
                var selected: ChangedFile?
                for page in 1...30 {
                    let files = try decode([ChangedFile].self, run(["api", "repos/\(identity.repository.nameWithOwner)/pulls/\(identity.number)/files",
                        "--hostname", "github.com", "--method", "GET", "-F", "per_page=100", "-F", "page=\(page)",
                        "--jq", "[.[]|{filename,previous_filename,status}]"]))
                    guard files.allSatisfy({ validPath($0.filename) && ($0.previous_filename.map(validPath) ?? true) }) else {
                        throw ProjectPullRequestReviewState.Failure.unavailable
                    }
                    selected = files.first { $0.filename == path }
                    if selected != nil || files.count < 100 { break }
                    guard page < 30 else { throw ProjectPullRequestReviewState.Failure.unavailable }
                }
                changed = selected
            }
            guard let changed else { throw ProjectPullRequestReviewState.Failure.notInPullRequest }
            let oldPath = changed.previous_filename ?? path
            func content(_ oid: String, path: String, repository: GitHubRepository, absent: Bool) throws -> String {
                if absent { return "" }
                let blob = try local(["cat-file", "blob", "\(oid):\(path)"], limit: fileLimit)
                let data: Data
                if blob.status == 0 {
                    guard !blob.truncated else { throw ProjectPullRequestReviewState.Failure.tooLarge }
                    data = blob.stdout
                } else {
                    let encodedPath = path.split(separator: "/", omittingEmptySubsequences: false)
                        .map { String($0).addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }.joined(separator: "/")
                    let remote = try decode(ContentResponse.self, run(["api", "repos/\(repository.nameWithOwner)/contents/\(encodedPath)",
                        "--hostname", "github.com", "--method", "GET", "-f", "ref=" + oid,
                        "--jq", "{type,size,encoding,content,sha}"]))
                    guard remote.type == "file", remote.size <= fileLimit else {
                        throw remote.size > fileLimit ? ProjectPullRequestReviewState.Failure.tooLarge : .binary
                    }
                    if remote.encoding == "base64", let content = remote.content,
                       let decoded = Data(base64Encoded: content, options: .ignoreUnknownCharacters) {
                        data = decoded
                    } else {
                        guard validOID(remote.sha) else { throw ProjectPullRequestReviewState.Failure.unavailable }
                        let remoteBlob = try decode(BlobResponse.self, run(["api", "repos/\(repository.nameWithOwner)/git/blobs/\(remote.sha)",
                            "--hostname", "github.com", "--jq", "{size,encoding,content}"]))
                        guard remoteBlob.size <= fileLimit, remoteBlob.encoding == "base64",
                              let decoded = Data(base64Encoded: remoteBlob.content, options: .ignoreUnknownCharacters) else {
                            throw ProjectPullRequestReviewState.Failure.tooLarge
                        }
                        data = decoded
                    }
                }
                guard data.count <= fileLimit else { throw ProjectPullRequestReviewState.Failure.tooLarge }
                guard !data.contains(0), let string = String(data: data, encoding: .utf8) else {
                    throw ProjectPullRequestReviewState.Failure.binary
                }
                return string
            }
            let old = try content(mergeBase, path: oldPath, repository: identity.repository, absent: changed.status == "added")
            let new = try content(initial.headRefOid, path: path, repository: identity.context.headRepository, absent: changed.status == "removed")
            let verified = try pullRequest(threads: false)
            guard verified.headRefOid == initial.headRefOid, verified.baseRefOid == initial.baseRefOid else {
                throw ProjectPullRequestReviewState.Failure.changed
            }
            let fileThreads = threads.filter { $0.path == path }
            let visible = fileThreads.filter { thread in
                let contents = thread.diffSide == .left ? old : new
                return thread.isCurrent && thread.line! <= lineCount(contents)
            }
            return .ready(ProjectPullRequestReviewFile(identity: identity, baseOID: initial.baseRefOid,
                headOID: initial.headRefOid, mergeBaseOID: mergeBase, path: path, oldPath: oldPath,
                oldContents: old, newContents: new, threads: visible,
                outdatedThreadCount: fileThreads.filter(\.isOutdated).count))
        } catch let failure as ProjectPullRequestReviewState.Failure { return .failed(failure) }
        catch { return .failed(.unavailable) }
    }

    static func validOID(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && !path.hasPrefix("/")
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }
    static func lineCount(_ contents: String) -> Int {
        guard !contents.isEmpty else { return 0 }
        return contents.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } + (contents.utf8.last == 10 ? 0 : 1)
    }
    private static func changedFiles(_ data: Data) throws -> [ChangedFile] {
        let records = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true)
        var files: [ChangedFile] = [], index = 0
        while index < records.count {
            let status = records[index]
            index += 1
            guard index < records.count, let kind = status.first else { throw ProjectPullRequestReviewState.Failure.unavailable }
            let oldPath = String(records[index]); index += 1
            let path: String
            if kind == "R" || kind == "C" {
                guard index < records.count else { throw ProjectPullRequestReviewState.Failure.unavailable }
                path = String(records[index]); index += 1
            } else { path = oldPath }
            guard validPath(path), validPath(oldPath) else { throw ProjectPullRequestReviewState.Failure.unavailable }
            files.append(ChangedFile(filename: path, previous_filename: kind == "R" || kind == "C" ? oldPath : nil,
                status: kind == "A" ? "added" : kind == "D" ? "removed" : "modified"))
        }
        return files
    }

    private static let commentFields = "id author{login} body url commit{oid} originalCommit{oid}"
    private static let identityFields = "number url headRefName headRepository{nameWithOwner} baseRefOid headRefOid"
    private static let reviewQuery = """
        query($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){
        \(identityFields) reviewThreads(first:50,after:$cursor){pageInfo{hasNextPage endCursor} nodes{
        id path line startLine diffSide startDiffSide isResolved isOutdated subjectType
        comments(first:10){pageInfo{hasNextPage endCursor} nodes{\(commentFields)}}}}}}}
        """
    private static let versionQuery = """
        query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){\(identityFields)}}}
        """
    private static let commentsQuery = """
        query($id:ID!,$cursor:String!){node(id:$id){...on PullRequestReviewThread{id pullRequest{\(identityFields)}
        comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{\(commentFields)}}}}}
        """
    private struct PullRequestResponse: Decodable {
        struct PullRequest: Decodable {
            struct Repository: Decodable { let nameWithOwner: String }
            struct Connection: Decodable {
                let nodes: [ProjectPullRequestReviewThread]
                let pageInfo: ProjectPullRequestReviewPageInfo
            }
            let number: Int
            let url: String
            let headRefName: String
            let headRepository: Repository?
            let baseRefOid: String
            let headRefOid: String
            let reviewThreads: Connection?
        }
        struct Repository: Decodable { let pullRequest: PullRequest? }
        struct Payload: Decodable { let repository: Repository? }
        let data: Payload?
        let errors: [GraphQLFailure]?
    }
    private struct GraphQLFailure: Decodable { let message: String }
    private struct ThreadResponse: Decodable {
        struct Thread: Decodable {
            let id: String
            let pullRequest: PullRequestResponse.PullRequest
            let comments: ProjectPullRequestReviewThread.CommentConnection
        }
        struct Payload: Decodable { let node: Thread? }
        let data: Payload?
        let errors: [GraphQLFailure]?
    }
    private struct CompareResponse: Decodable { struct Commit: Decodable { let sha: String }; let merge_base_commit: Commit }
    private struct ChangedFile: Decodable { let filename: String; let previous_filename: String?; let status: String }
    private struct ContentResponse: Decodable { let type: String; let size: Int; let encoding: String?; let content: String?; let sha: String }
    private struct BlobResponse: Decodable { let size: Int; let encoding: String; let content: String }
}

actor ProjectPullRequestReviewCache {
    static let shared = ProjectPullRequestReviewCache()
    struct Key: Hashable, Sendable { let identity: ProjectPullRequestReviewIdentity; let path: String }
    typealias Lookup = @Sendable (ProjectPullRequestReviewIdentity, String) async -> ProjectPullRequestReviewState
    private struct Entry { let state: ProjectPullRequestReviewState; let expires: Date; var used: Date }
    private struct Pending { let id: UUID; let task: Task<ProjectPullRequestReviewState, Never> }
    private let lookup: Lookup
    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Pending] = [:]
    init(now: @escaping @Sendable () -> Date = { Date() },
         lookup: @escaping Lookup = { await GitHubPullRequestReviewWorker.lookup($0, path: $1) }) {
        self.now = now
        self.lookup = lookup
    }
    func value(for identity: ProjectPullRequestReviewIdentity, path: String, force: Bool = false) async -> ProjectPullRequestReviewState {
        let key = Key(identity: identity, path: path), date = now()
        if force { entries[key] = nil }
        if var entry = entries[key], entry.expires > date {
            entry.used = date; entries[key] = entry
            return entry.state
        }
        let request: Pending
        if let existing = pending[key] { request = existing }
        else {
            guard pending.count < 8 else { return .failed(.unavailable) }
            let lookup = lookup
            request = Pending(id: UUID(), task: Task { await lookup(identity, path) })
            pending[key] = request
        }
        let result = await request.task.value
        if pending[key]?.id == request.id {
            pending[key] = nil
            let lifetime: TimeInterval = if case .failed = result { 10 } else { 60 }
            entries[key] = Entry(state: result, expires: now().addingTimeInterval(lifetime), used: now())
            while entries.count > 8, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key { entries[oldest] = nil }
        }
        return result
    }

    func invalidate(_ identity: ProjectPullRequestReviewIdentity) {
        entries = entries.filter { $0.key.identity.url != identity.url }
        for key in pending.keys.filter({ $0.identity.url == identity.url }) {
            pending.removeValue(forKey: key)?.task.cancel()
        }
    }
}
