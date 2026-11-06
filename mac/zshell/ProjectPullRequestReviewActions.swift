import Foundation

nonisolated struct ProjectPullRequestReviewTarget: Equatable, Sendable {
    let identity: ProjectPullRequestReviewIdentity
    let baseOID: String
    let headOID: String
    let path: String

    init(_ file: ProjectPullRequestReviewFile) {
        identity = file.identity
        baseOID = file.baseOID
        headOID = file.headOID
        path = file.path
    }
}

nonisolated enum ProjectPullRequestReviewAction: Equatable, Sendable {
    enum Review: String, Sendable {
        case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES"

        var title: String {
            switch self {
            case .comment: String(localized: "Comment")
            case .approve: String(localized: "Approve")
            case .requestChanges: String(localized: "Request Changes")
            }
        }
    }

    case reply(threadID: String, body: String)
    case resolve(threadID: String, resolved: Bool)
    case review(Review, body: String)

    var threadID: String? {
        switch self {
        case .reply(let id, _), .resolve(let id, _): id
        case .review: nil
        }
    }
}

nonisolated enum ProjectPullRequestReviewActionError: Error, Equatable, Sendable {
    case missingCLI, notSignedIn, unavailable, changed, forbidden, invalidBody, busy, outcomeUnknown

    var message: String {
        switch self {
        case .missingCLI: ProjectPullRequestState.Failure.missingCLI.message
        case .notSignedIn: ProjectPullRequestState.Failure.notSignedIn.message
        case .unavailable: String(localized: "Could not load review permissions. Refresh and try again.")
        case .changed: ProjectPullRequestReviewState.Failure.changed.message
        case .forbidden: String(localized: "You don’t have permission for this review action.")
        case .invalidBody: String(localized: "Enter a comment of at most 64 KB.")
        case .busy: String(localized: "Another review action is in progress for this pull request.")
        case .outcomeUnknown: String(localized: "GitHub may have received this action. Check the pull request before submitting again.")
        }
    }
}

nonisolated struct ProjectPullRequestReviewAccess: Equatable, Sendable {
    let canReview: Bool
    let canApprove: Bool
    let thread: ProjectPullRequestReviewThread?
    let canReply: Bool
    let canResolve: Bool
    let canUnresolve: Bool
}

/// Every write gets a fresh identity and permission check. GitHub remains the
/// authority for permissions that its schema does not expose, such as reviews.
nonisolated enum GitHubPullRequestReviewActions {
    typealias Command = @Sendable (URL, [String], TimeInterval, [String: String], Data) throws -> BoundedProcessResult
    typealias Probe = @Sendable (ProjectPullRequestContext) -> Bool
    private static let outputLimit = 2 << 20
    private static let bodyLimit = 65_536

    static func load(_ target: ProjectPullRequestReviewTarget, threadID: String?) async
        -> Result<ProjectPullRequestReviewAccess, ProjectPullRequestReviewActionError> {
        await withCheckedContinuation { continuation in
            GitHubPullRequestWorker.queue.addOperation {
                continuation.resume(returning: query(target, threadID: threadID))
            }
        }
    }

    static func perform(_ target: ProjectPullRequestReviewTarget, action: ProjectPullRequestReviewAction) async
        -> Result<Void, ProjectPullRequestReviewActionError> {
        await withCheckedContinuation { continuation in
            GitHubPullRequestWorker.queue.addOperation {
                continuation.resume(returning: execute(target, action: action))
            }
        }
    }

    static func query(
        _ target: ProjectPullRequestReviewTarget, threadID: String?,
        environment: [String: String] = GitProxy.processEnvironment(inheriting: ProcessInfo.processInfo.environment),
        locate: @Sendable ([String: String]) -> URL? = { ProcessRunner.resolveExecutable("gh", environment: $0) },
        command: @escaping Command = productionCommand, probe: @escaping Probe = { currentContext($0) }
    ) -> Result<ProjectPullRequestReviewAccess, ProjectPullRequestReviewActionError> {
        do {
            let request = try Request(target: target, environment: environment, locate: locate, command: command, probe: probe)
            let loaded = try request.load(threadID: threadID, allComments: true)
            return .success(ProjectPullRequestReviewAccess(canReview: loaded.pr.state == "OPEN",
                canApprove: loaded.pr.state == "OPEN" && !loaded.pr.viewerDidAuthor,
                thread: loaded.thread?.thread, canReply: loaded.thread?.viewerCanReply == true && loaded.pr.state == "OPEN",
                canResolve: loaded.thread?.viewerCanResolve == true && loaded.pr.state == "OPEN",
                canUnresolve: loaded.thread?.viewerCanUnresolve == true && loaded.pr.state == "OPEN"))
        } catch let error as ProjectPullRequestReviewActionError { return .failure(error) }
        catch { return .failure(.unavailable) }
    }

    static func execute(
        _ target: ProjectPullRequestReviewTarget, action: ProjectPullRequestReviewAction,
        environment: [String: String] = GitProxy.processEnvironment(inheriting: ProcessInfo.processInfo.environment),
        locate: @Sendable ([String: String]) -> URL? = { ProcessRunner.resolveExecutable("gh", environment: $0) },
        command: @escaping Command = productionCommand, probe: @escaping Probe = { currentContext($0) }
    ) -> Result<Void, ProjectPullRequestReviewActionError> {
        do {
            switch action {
            case .reply(_, let body): guard validBody(body, required: true) else { throw ProjectPullRequestReviewActionError.invalidBody }
            case .review(let event, let body):
                guard validBody(body, required: event != .approve) else { throw ProjectPullRequestReviewActionError.invalidBody }
            case .resolve: break
            }
            let request = try Request(target: target, environment: environment, locate: locate, command: command, probe: probe)
            let loaded = try request.load(threadID: action.threadID, allComments: false)
            guard loaded.pr.state == "OPEN" else { throw ProjectPullRequestReviewActionError.forbidden }
            var input: [String: Any] = ["clientMutationId": UUID().uuidString]
            let query: String, field: String
            switch action {
            case .reply(let id, let body):
                guard loaded.thread?.viewerCanReply == true else { throw ProjectPullRequestReviewActionError.forbidden }
                input["pullRequestReviewThreadId"] = id
                input["body"] = body
                field = "addPullRequestReviewThreadReply"
                query = "mutation($input:AddPullRequestReviewThreadReplyInput!){\(field)(input:$input){comment{id url pullRequest{\(identityFields)}}}}"
            case .resolve(let id, let resolved):
                guard let thread = loaded.thread else { throw ProjectPullRequestReviewActionError.changed }
                if thread.thread.isResolved == resolved { return .success(()) }
                guard resolved ? thread.viewerCanResolve : thread.viewerCanUnresolve else { throw ProjectPullRequestReviewActionError.forbidden }
                input["threadId"] = id
                field = resolved ? "resolveReviewThread" : "unresolveReviewThread"
                let type = resolved ? "ResolveReviewThreadInput" : "UnresolveReviewThreadInput"
                query = "mutation($input:\(type)!){\(field)(input:$input){thread{id path isResolved pullRequest{\(identityFields)}}}}"
            case .review(let event, let body):
                guard event == .comment || !loaded.pr.viewerDidAuthor else { throw ProjectPullRequestReviewActionError.forbidden }
                input["pullRequestId"] = loaded.pr.id
                input["commitOID"] = target.headOID
                input["event"] = event.rawValue
                input["body"] = body
                field = "addPullRequestReview"
                query = "mutation($input:AddPullRequestReviewInput!){\(field)(input:$input){pullRequestReview{id state commit{oid} pullRequest{\(identityFields)}}}}"
            }
            // A branch switch during the network preflight must not send a write.
            guard probe(target.identity.context) else { throw ProjectPullRequestReviewActionError.changed }
            let response = try request.run(query, variables: ["input": input], mutation: true)
            guard let payload = response[field] as? [String: Any] else { throw ProjectPullRequestReviewActionError.outcomeUnknown }
            let result = payload[action.threadID == nil ? "pullRequestReview" : action.isResolution ? "thread" : "comment"] as? [String: Any]
            guard let result, let id = result["id"] as? String, validID(id),
                  let pr = result["pullRequest"], let data = try? JSONSerialization.data(withJSONObject: pr),
                  let verified = try? JSONDecoder().decode(PullRequest.self, from: data), request.matches(verified), verified.id == loaded.pr.id else {
                throw ProjectPullRequestReviewActionError.outcomeUnknown
            }
            switch action {
            case .reply:
                guard let url = result["url"] as? String,
                      ProjectPullRequestReviewFile.commentURL(url, identity: target.identity) != nil else {
                    throw ProjectPullRequestReviewActionError.outcomeUnknown
                }
            case .resolve(let threadID, let resolved):
                guard id == threadID, result["path"] as? String == target.path, result["isResolved"] as? Bool == resolved else {
                    throw ProjectPullRequestReviewActionError.outcomeUnknown
                }
            case .review(let event, _):
                let expected = event == .comment ? "COMMENTED" : event == .approve ? "APPROVED" : "CHANGES_REQUESTED"
                guard result["state"] as? String == expected,
                      (result["commit"] as? [String: Any])?["oid"] as? String == target.headOID else {
                    throw ProjectPullRequestReviewActionError.outcomeUnknown
                }
            }
            return .success(())
        } catch let error as ProjectPullRequestReviewActionError { return .failure(error) }
        catch { return .failure(.unavailable) }
    }

    private static let productionCommand: Command = {
        try BoundedProcessRunner.run(executableURL: $0, arguments: $1, timeout: $2,
            outputLimit: outputLimit, environment: $3, standardInput: $4)
    }

    static func currentContext(_ context: ProjectPullRequestContext) -> Bool {
        guard case .repository(let snapshot) = GitStatusModel.branchSnapshot(in: context.root),
              case .context(let current) = ProjectPullRequestContext.resolve(snapshot) else { return false }
        return current == context
    }

    static func validBody(_ body: String, required: Bool) -> Bool {
        body.utf8.count <= bodyLimit && !body.utf8.contains(0)
            && (!required || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512
            && id.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }

    private final class Request {
        let target: ProjectPullRequestReviewTarget
        let executable: URL
        let environment: [String: String]
        let command: Command
        let probe: Probe
        let deadline = Date().addingTimeInterval(20)
        var requests = 0

        init(target: ProjectPullRequestReviewTarget, environment: [String: String],
             locate: @Sendable ([String: String]) -> URL?, command: @escaping Command, probe: @escaping Probe) throws {
            self.target = target
            self.environment = GitHubPullRequestWorker.processEnvironment(environment)
            guard let executable = locate(self.environment) else { throw ProjectPullRequestReviewActionError.missingCLI }
            self.executable = executable
            self.command = command
            self.probe = probe
            guard GitHubPullRequestReviewWorker.validOID(target.headOID), GitHubPullRequestReviewWorker.validOID(target.baseOID),
                  GitHubPullRequestReviewWorker.validPath(target.path), probe(target.identity.context) else {
                throw ProjectPullRequestReviewActionError.changed
            }
        }

        func matches(_ pr: PullRequest) -> Bool {
            pr.number == target.identity.number && pr.url.lowercased() == target.identity.url
                && pr.headRefName == target.identity.context.headBranch
                && pr.headRepository.flatMap { GitHubRepository($0.nameWithOwner) } == target.identity.context.headRepository
                && pr.headRefOid == target.headOID && pr.baseRefOid == target.baseOID && validID(pr.id)
        }

        func run(_ query: String, variables: [String: Any], mutation: Bool = false) throws -> [String: Any] {
            requests += 1
            let remaining = deadline.timeIntervalSinceNow
            guard requests <= 24, remaining > 0 else { throw ProjectPullRequestReviewActionError.unavailable }
            let input = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
            let result: BoundedProcessResult
            do { result = try command(executable, ["api", "graphql", "--hostname", "github.com", "--input", "-"], remaining, environment, input) }
            catch { throw mutation ? ProjectPullRequestReviewActionError.outcomeUnknown : .unavailable }
            guard !result.timedOut, !result.output.wasTruncated else {
                throw mutation ? ProjectPullRequestReviewActionError.outcomeUnknown : .unavailable
            }
            if result.terminationStatus == 4 { throw ProjectPullRequestReviewActionError.notSignedIn }
            let root = (try? JSONSerialization.jsonObject(with: Data(result.output.stdout.utf8))) as? [String: Any]
            if let errors = root?["errors"] as? [[String: Any]], !errors.isEmpty {
                if errors.allSatisfy({ ["FORBIDDEN", "UNAUTHORIZED"].contains($0["type"] as? String ?? "") }) {
                    let data = root?["data"] as? [String: Any]
                    let partialResult = data?.values.contains { !($0 is NSNull) } == true
                    let nestedError = errors.contains { (($0["path"] as? [Any])?.count ?? 0) > 1 }
                    // A permission error in a returned object's fields may occur
                    // after the mutation succeeded; it must not permit a retry.
                    if mutation && (partialResult || nestedError) { throw ProjectPullRequestReviewActionError.outcomeUnknown }
                    throw ProjectPullRequestReviewActionError.forbidden
                }
                throw mutation ? ProjectPullRequestReviewActionError.outcomeUnknown : .unavailable
            }
            guard result.terminationStatus == 0, let data = root?["data"] as? [String: Any] else {
                throw mutation ? ProjectPullRequestReviewActionError.outcomeUnknown : .unavailable
            }
            return data
        }

        func load(threadID: String?, allComments: Bool) throws -> (pr: PullRequest, thread: Thread?) {
            let parts = target.identity.repository.nameWithOwner.split(separator: "/")
            let response = try run(accessQuery, variables: ["owner": String(parts[0]), "name": String(parts[1]), "number": target.identity.number])
            guard let repository = response["repository"] as? [String: Any], let value = repository["pullRequest"],
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let pr = try? JSONDecoder().decode(PullRequest.self, from: data), matches(pr) else {
                throw ProjectPullRequestReviewActionError.changed
            }
            guard let threadID else { return (pr, nil) }
            guard validID(threadID) else { throw ProjectPullRequestReviewActionError.changed }
            var loaded: Thread?
            var cursor: String?, seenCursors = Set<String>(), seenComments = Set<String>(), bytes = 0
            repeat {
                let response = try run(threadQuery, variables: ["id": threadID, "cursor": cursor as Any? ?? NSNull()])
                guard let value = response["node"], let data = try? JSONSerialization.data(withJSONObject: value),
                      let thread = try? JSONDecoder().decode(Thread.self, from: data), matches(thread.pullRequest), thread.pullRequest.id == pr.id,
                      thread.thread.id == threadID, thread.thread.path == target.path,
                      loaded == nil || loaded!.thread.isResolved == thread.thread.isResolved else {
                    throw ProjectPullRequestReviewActionError.changed
                }
                for comment in thread.thread.comments.nodes {
                    bytes += comment.body.utf8.count
                    guard validID(comment.id), seenComments.insert(comment.id).inserted, seenComments.count <= 2_000,
                          bytes <= outputLimit, ProjectPullRequestReviewFile.commentURL(comment.url, identity: target.identity) != nil else {
                        throw ProjectPullRequestReviewActionError.unavailable
                    }
                }
                if loaded == nil { loaded = thread }
                else { loaded!.thread.comments.nodes += thread.thread.comments.nodes }
                guard allComments, thread.thread.comments.pageInfo.hasNextPage else { break }
                guard let next = thread.thread.comments.pageInfo.endCursor, validID(next), seenCursors.insert(next).inserted else {
                    throw ProjectPullRequestReviewActionError.unavailable
                }
                cursor = next
            } while true
            guard probe(target.identity.context) else { throw ProjectPullRequestReviewActionError.changed }
            return (pr, loaded)
        }
    }

    private struct PullRequest: Decodable {
        struct Repository: Decodable { let nameWithOwner: String }
        let id: String
        let number: Int
        let url: String
        let headRefName: String
        let headRepository: Repository?
        let headRefOid: String
        let baseRefOid: String
        let state: String
        let viewerDidAuthor: Bool
    }

    private struct Thread: Decodable {
        var thread: ProjectPullRequestReviewThread
        let pullRequest: PullRequest
        let viewerCanReply: Bool
        let viewerCanResolve: Bool
        let viewerCanUnresolve: Bool

        init(from decoder: Decoder) throws {
            thread = try ProjectPullRequestReviewThread(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            pullRequest = try values.decode(PullRequest.self, forKey: .pullRequest)
            viewerCanReply = try values.decode(Bool.self, forKey: .viewerCanReply)
            viewerCanResolve = try values.decode(Bool.self, forKey: .viewerCanResolve)
            viewerCanUnresolve = try values.decode(Bool.self, forKey: .viewerCanUnresolve)
        }
        private enum CodingKeys: CodingKey { case pullRequest, viewerCanReply, viewerCanResolve, viewerCanUnresolve }
    }

    private static let identityFields = "id number url headRefName headRepository{nameWithOwner} baseRefOid headRefOid state viewerDidAuthor"
    private static let accessQuery = "query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){\(identityFields)}}}"
    private static let threadQuery = """
        query($id:ID!,$cursor:String){node(id:$id){...on PullRequestReviewThread{
        id path line startLine diffSide startDiffSide isResolved isOutdated subjectType
        viewerCanReply viewerCanResolve viewerCanUnresolve pullRequest{\(identityFields)}
        comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{id author{login} body url commit{oid} originalCommit{oid}}}}}}
        """
}

private extension ProjectPullRequestReviewAction {
    nonisolated var isResolution: Bool { if case .resolve = self { true } else { false } }
}

actor ProjectPullRequestReviewActionCoordinator {
    static let shared = ProjectPullRequestReviewActionCoordinator()
    typealias Perform = @Sendable (ProjectPullRequestReviewTarget, ProjectPullRequestReviewAction) async -> Result<Void, ProjectPullRequestReviewActionError>
    private let execute: Perform
    private var writing = Set<String>()
    private var uncertain = Set<String>()

    init(execute: @escaping Perform = { await GitHubPullRequestReviewActions.perform($0, action: $1) }) {
        self.execute = execute
    }

    func hasUncertainOutcome(_ identity: ProjectPullRequestReviewIdentity) -> Bool { uncertain.contains(identity.url) }
    func acknowledgeCheckedOutcome(_ identity: ProjectPullRequestReviewIdentity) { uncertain.remove(identity.url) }

    func perform(_ target: ProjectPullRequestReviewTarget, action: ProjectPullRequestReviewAction)
        async -> Result<Void, ProjectPullRequestReviewActionError> {
        guard !uncertain.contains(target.identity.url) else { return .failure(.outcomeUnknown) }
        guard writing.insert(target.identity.url).inserted else { return .failure(.busy) }
        defer { writing.remove(target.identity.url) }
        let result = await execute(target, action)
        if case .failure(.outcomeUnknown) = result { uncertain.insert(target.identity.url) }
        // Clear in-flight readers too; an older response cannot repopulate the
        // cache after a reply, resolution, or an uncertain write outcome.
        await ProjectPullRequestReviewCache.shared.invalidate(target.identity)
        return result
    }
}
