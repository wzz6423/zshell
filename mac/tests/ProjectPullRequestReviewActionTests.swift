import Foundation

private nonisolated func require(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

private actor DelayedReviewFixture {
    var calls = 0
    let state: ProjectPullRequestReviewState
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    init(state: ProjectPullRequestReviewState = .failed(.unavailable)) { self.state = state }

    func waitForStart() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    private func run() async {
        calls += 1
        let first = calls == 1
        started?.resume()
        started = nil
        if first { await withCheckedContinuation { release = $0 } }
    }

    func complete() { release?.resume(); release = nil }
    func lookup() async -> ProjectPullRequestReviewState {
        await run()
        return state
    }
    func write() async -> Result<Void, ProjectPullRequestReviewActionError> {
        await run()
        return .success(())
    }
}

private nonisolated final class ActionFixture: @unchecked Sendable {
    let target: ProjectPullRequestReviewTarget
    let lock = NSLock()
    var mutations: [[String: Any]] = []
    var reads = 0
    var mode = ""

    init(root: String) {
        guard case .repository(let snapshot) = GitStatusModel.branchSnapshot(in: root),
              case .context(let context) = ProjectPullRequestContext.resolve(snapshot) else { fatalError("Fixture repository missing") }
        let identity = ProjectPullRequestReviewIdentity(ProjectPullRequest(number: 1, status: .open,
            url: URL(string: "https://github.com/example/base/pull/1")!), context: context)!
        target = ProjectPullRequestReviewTarget(ProjectPullRequestReviewFile(identity: identity,
            baseOID: String(repeating: "a", count: 40), headOID: String(repeating: "b", count: 40),
            mergeBaseOID: String(repeating: "c", count: 40), path: "Review.swift", oldPath: "Review.swift",
            oldContents: "before", newContents: "after", threads: [], outdatedThreadCount: 0))
    }

    func pr() -> [String: Any] {
        ["id": "PR_1", "number": 1, "url": target.identity.url, "headRefName": "feature/review",
         "headRepository": ["nameWithOwner": mode == "wrong-fork" ? "other/fork" : "example/fork"],
         "baseRefOid": target.baseOID, "headRefOid": mode == "changed" ? target.baseOID : target.headOID,
         "state": mode == "closed" ? "CLOSED" : "OPEN", "viewerDidAuthor": mode == "author"]
    }

    func comment(_ id: String) -> [String: Any] {
        ["id": id, "author": ["login": "reviewer"], "body": "正文 <script>bad()</script>",
         "url": target.identity.url + "#discussion_" + id,
         "commit": ["oid": target.headOID], "originalCommit": ["oid": target.headOID]]
    }

    func command() -> GitHubPullRequestReviewActions.Command {
        { _, arguments, timeout, environment, input in
            require(arguments == ["api", "graphql", "--hostname", "github.com", "--input", "-"], "Only structured GitHub GraphQL calls")
            require(timeout > 0 && timeout <= 20, "Shared bounded timeout")
            require(environment["GH_REPO"] == nil && environment["GH_DEBUG"] == nil && environment["GH_HOST"] == "github.com", "Inherited overrides must be stripped")
            let payload = try JSONSerialization.jsonObject(with: input) as! [String: Any]
            let query = payload["query"] as! String
            require(query.filter { $0 == "{" }.count == query.filter { $0 == "}" }.count,
                    "Production GraphQL selection sets must be balanced")
            let variables = payload["variables"] as! [String: Any]
            let mutation = query.hasPrefix("mutation")
            if mutation { self.lock.withLock { self.mutations.append(payload) } }
            else { self.lock.withLock { self.reads += 1 } }
            var data: [String: Any]
            if mutation {
                if self.mode == "timeout" { return BoundedProcessResult(terminationStatus: 0, timedOut: true, output: .init(stdout: "", stderr: "", wasTruncated: false)) }
                if self.mode == "denied" {
                    return .init(terminationStatus: 1, timedOut: false, output: .init(stdout: "{\"errors\":[{\"type\":\"FORBIDDEN\"}]}", stderr: "secret", wasTruncated: false))
                }
                if self.mode == "partial-denied" || self.mode == "nested-denied" {
                    let value: Any = self.mode == "partial-denied" ? ["comment": ["id": "NEW_COMMENT"]] as [String: Any] : NSNull()
                    let response: [String: Any] = ["data": ["addPullRequestReviewThreadReply": value],
                        "errors": [["type": "FORBIDDEN", "path": ["addPullRequestReviewThreadReply", "comment", "pullRequest"]]]]
                    return .init(terminationStatus: 1, timedOut: false, output: .init(
                        stdout: String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self), stderr: "", wasTruncated: false))
                }
                let values = variables["input"] as! [String: Any]
                require(values["clientMutationId"] is String, "Each explicit submission has an identifier")
                if query.contains("addPullRequestReviewThreadReply") {
                    require(values["pullRequestReviewThreadId"] as? String == "THREAD_1", "Exact thread target")
                    data = ["addPullRequestReviewThreadReply": ["comment": ["id": "NEW_COMMENT", "url": self.target.identity.url + "#discussion_new", "pullRequest": self.pr()]]]
                } else if query.contains("unresolveReviewThread") {
                    data = ["unresolveReviewThread": ["thread": ["id": "THREAD_1", "path": "Review.swift", "isResolved": false, "pullRequest": self.pr()]]]
                } else if query.contains("resolveReviewThread") {
                    data = ["resolveReviewThread": ["thread": ["id": "THREAD_1", "path": "Review.swift", "isResolved": true, "pullRequest": self.pr()]]]
                } else {
                    require(values["pullRequestId"] as? String == "PR_1" && values["commitOID"] as? String == self.target.headOID, "Review must attach to displayed head commit")
                    let event = values["event"] as! String
                    let state = event == "APPROVE" ? "APPROVED" : event == "COMMENT" ? "COMMENTED" : "CHANGES_REQUESTED"
                    data = ["addPullRequestReview": ["pullRequestReview": ["id": "REVIEW_1", "state": state,
                        "commit": ["oid": self.target.headOID], "pullRequest": self.pr()]]]
                }
                if self.mode == "malformed" { data = [:] }
            } else if query.contains("PullRequestReviewThread") {
                let second = variables["cursor"] as? String != nil
                var thread: [String: Any] = ["id": self.mode == "wrong-id" ? "OTHER" : "THREAD_1",
                    "path": self.mode == "wrong-path" ? "Other.swift" : "Review.swift", "line": 1, "startLine": NSNull(),
                    "diffSide": "RIGHT", "startDiffSide": NSNull(), "isResolved": self.mode == "resolved",
                    "isOutdated": false, "subjectType": "LINE", "viewerCanReply": self.mode != "no-reply",
                    "viewerCanResolve": self.mode != "no-resolve", "viewerCanUnresolve": self.mode != "no-unresolve", "pullRequest": self.pr()]
                let id = self.mode == "duplicate" ? "C1" : second ? "C2" : "C1"
                let more = self.mode == "cursor" || !second
                thread["comments"] = ["nodes": [self.comment(id)], "pageInfo": ["hasNextPage": more, "endCursor": more ? "next" as Any : NSNull()]]
                data = ["node": thread]
            } else { data = ["repository": ["pullRequest": self.pr()]] }
            let output = String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self)
            return .init(terminationStatus: 0, timedOut: false, output: .init(stdout: output, stderr: "", wasTruncated: false))
        }
    }

    func execute(_ action: ProjectPullRequestReviewAction, probe: GitHubPullRequestReviewActions.Probe? = nil)
        -> Result<Void, ProjectPullRequestReviewActionError> {
        GitHubPullRequestReviewActions.execute(target, action: action,
            environment: ["PATH": "/usr/bin", "GH_REPO": "wrong/repo", "GH_DEBUG": "api"],
            locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: command(),
            probe: probe ?? { GitHubPullRequestReviewActions.currentContext($0) })
    }
}

@main
struct ProjectPullRequestReviewActionTests {
    static func main() async {
        let root = CommandLine.arguments[1]
        let fixture = ActionFixture(root: root)
        let body = "Quoted \"reply\"\n`code` $HOME $(safe) 你好"
        func mappedThread(startLine: Int, startSide: ProjectPullRequestReviewThread.Side?) -> ProjectPullRequestReviewThread {
            ProjectPullRequestReviewThread(id: "THREAD_1", path: fixture.target.path, line: 2, startLine: startLine,
                diffSide: .right, startDiffSide: startSide, isResolved: false, isOutdated: false, subjectType: "LINE",
                comments: .init(nodes: [.init(id: "C1", author: nil, body: body,
                    url: fixture.target.identity.url + "#discussion_r1", commit: nil, originalCommit: nil)],
                    pageInfo: .init(hasNextPage: false, endCursor: nil)))
        }
        require(mappedThread(startLine: 2, startSide: nil).isCurrent,
                "GitHub single-line comments may include the same startLine without startDiffSide")
        require(mappedThread(startLine: 1, startSide: .right).isCurrent,
                "A multi-line comment must match the displayed side")
        require(!mappedThread(startLine: 1, startSide: nil).isCurrent
            && !mappedThread(startLine: 2, startSide: .left).isCurrent,
                "Missing multi-line sides and mismatched explicit sides stay rejected")
        require(GitHubPullRequestReviewActions.currentContext(fixture.target.identity.context), "Actual Git context resolves")
        let loaded = GitHubPullRequestReviewActions.query(fixture.target, threadID: "THREAD_1", environment: [:],
            locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: fixture.command())
        guard case .success(let access) = loaded else { fatalError("Discussion load failed") }
        require(access.thread?.comments.nodes.map(\.id) == ["C1", "C2"] && access.canReply && access.canResolve,
                "Full paginated discussion and permissions")
        require(fixture.mutations.isEmpty, "Viewing a discussion must never write")
        for action in [ProjectPullRequestReviewAction.reply(threadID: "THREAD_1", body: body),
            .resolve(threadID: "THREAD_1", resolved: true), .review(.comment, body: body),
            .review(.approve, body: ""), .review(.requestChanges, body: body)] {
            if case .failure(let error) = fixture.execute(action) { fatalError("Action failed: \(error)") }
        }
        require((fixture.mutations.first?["variables"] as? [String: Any])?["input"] is [String: Any], "Mutation payload is structured JSON")
        let input = (fixture.mutations.first!["variables"] as! [String: Any])["input"] as! [String: Any]
        require(input["body"] as? String == body, "Multiline Unicode and shell-like content stays literal")
        fixture.mode = "resolved"
        if case .failure = fixture.execute(.resolve(threadID: "THREAD_1", resolved: false)) { fatalError("Unresolve failed") }
        let count = fixture.mutations.count
        if case .failure = fixture.execute(.resolve(threadID: "THREAD_1", resolved: true)) { fatalError("Already resolved should succeed") }
        require(fixture.mutations.count == count, "An already-resolved discussion does not send a duplicate mutation")
        for (mode, action, failure) in [
            ("changed", ProjectPullRequestReviewAction.reply(threadID: "THREAD_1", body: body), ProjectPullRequestReviewActionError.changed),
            ("wrong-fork", .review(.approve, body: ""), .changed),
            ("wrong-id", .reply(threadID: "THREAD_1", body: body), .changed),
            ("wrong-path", .reply(threadID: "THREAD_1", body: body), .changed),
            ("closed", .review(.comment, body: body), .forbidden),
            ("author", .review(.approve, body: ""), .forbidden),
            ("no-reply", .reply(threadID: "THREAD_1", body: body), .forbidden),
            ("no-resolve", .resolve(threadID: "THREAD_1", resolved: true), .forbidden)] {
            fixture.mode = mode
            let count = fixture.mutations.count
            require(fixture.execute(action).failure == failure, "Preflight rejects \(mode)")
            require(fixture.mutations.count == count, "Rejected \(mode) must not write")
        }
        fixture.mode = ""
        let countBefore = fixture.mutations.count
        require(fixture.execute(.reply(threadID: "THREAD_1", body: " \n")).failure == .invalidBody, "Empty reply rejected")
        require(fixture.execute(.review(.comment, body: String(repeating: "x", count: 65_537))).failure == .invalidBody, "Oversized comment rejected")
        require(fixture.execute(.review(.approve, body: ""), probe: { _ in false }).failure == .changed, "Changed local branch rejected")
        fixture.reads = 0
        require(fixture.execute(.review(.approve, body: ""), probe: { _ in fixture.reads == 0 }).failure == .changed, "Branch switch during preflight rejected")
        require(fixture.mutations.count == countBefore, "Invalid body and branch switch never write")
        for mode in ["timeout", "malformed", "partial-denied", "nested-denied"] {
            fixture.mode = mode
            let count = fixture.mutations.count
            require(fixture.execute(.reply(threadID: "THREAD_1", body: body)).failure == .outcomeUnknown, "Uncertain write reported")
            require(fixture.mutations.count == count + 1, "Uncertain write never automatically retries")
        }
        fixture.mode = "denied"
        require(fixture.execute(.review(.comment, body: body)).failure == .forbidden, "Server permission denial handled")
        for mode in ["duplicate", "cursor"] {
            fixture.mode = mode
            let loaded = GitHubPullRequestReviewActions.query(fixture.target, threadID: "THREAD_1", environment: [:],
                locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: fixture.command())
            require(loaded.failure == .unavailable, "Discussion rejects \(mode)")
        }
        actor Counter {
            var calls = 0
            func unknown() -> Result<Void, ProjectPullRequestReviewActionError> { calls += 1; return .failure(.outcomeUnknown) }
        }
        let counter = Counter()
        let coordinator = ProjectPullRequestReviewActionCoordinator(execute: { _, _ in await counter.unknown() })
        let first = await coordinator.perform(fixture.target, action: .review(.approve, body: ""))
        let second = await coordinator.perform(fixture.target, action: .reply(threadID: "THREAD_1", body: body))
        let firstCalls = await counter.calls
        require(first.failure == .outcomeUnknown, "Coordinator records uncertain writes")
        require(second.failure == .outcomeUnknown, "Another panel cannot retry an uncertain PR write")
        require(firstCalls == 1, "Uncertain PR write blocked before the worker")
        await coordinator.acknowledgeCheckedOutcome(fixture.target.identity)
        _ = await coordinator.perform(fixture.target, action: .review(.approve, body: ""))
        let secondCalls = await counter.calls
        require(secondCalls == 2, "Only explicit outcome acknowledgment permits another submission")
        let otherContext = ProjectPullRequestContext(root: root + "/other-worktree", gitDirectory: root + "/other-worktree/.git",
            localBranch: fixture.target.identity.context.localBranch, headBranch: fixture.target.identity.context.headBranch,
            headRepository: fixture.target.identity.context.headRepository, baseRepository: fixture.target.identity.context.baseRepository)
        let otherIdentity = ProjectPullRequestReviewIdentity(ProjectPullRequest(number: 1, status: .open,
            url: URL(string: fixture.target.identity.url)!), context: otherContext)!
        let otherTarget = ProjectPullRequestReviewTarget(ProjectPullRequestReviewFile(identity: otherIdentity,
            baseOID: fixture.target.baseOID, headOID: fixture.target.headOID, mergeBaseOID: fixture.target.baseOID,
            path: fixture.target.path, oldPath: fixture.target.path, oldContents: "", newContents: "", threads: [], outdatedThreadCount: 0))
        let delayedWrite = DelayedReviewFixture()
        let exclusive = ProjectPullRequestReviewActionCoordinator(execute: { _, _ in await delayedWrite.write() })
        let pendingWrite = Task { await exclusive.perform(fixture.target, action: .review(.approve, body: "")) }
        await delayedWrite.waitForStart()
        let blocked = await exclusive.perform(otherTarget, action: .reply(threadID: "THREAD_1", body: body))
        require(blocked.failure == .busy, "The same PR in another worktree must share the write lock")
        await delayedWrite.complete()
        let finished = await pendingWrite.value
        require(finished.failure == nil, "First explicit submission completes")
        let accepted = await exclusive.perform(otherTarget, action: .review(.approve, body: ""))
        require(accepted.failure == nil, "Completing a write releases the shared PR lock")

        let oldFile = ProjectPullRequestReviewFile(identity: otherIdentity,
            baseOID: fixture.target.baseOID, headOID: fixture.target.headOID, mergeBaseOID: fixture.target.baseOID,
            path: fixture.target.path, oldPath: fixture.target.path, oldContents: "old", newContents: "old",
            threads: [], outdatedThreadCount: 0)
        let delayedRead = DelayedReviewFixture(state: .ready(oldFile))
        let cache = ProjectPullRequestReviewCache(lookup: { _, _ in await delayedRead.lookup() })
        let pendingRead = Task { await cache.value(for: otherIdentity, path: fixture.target.path) }
        let sharedRead = Task { await cache.value(for: otherIdentity, path: fixture.target.path) }
        await delayedRead.waitForStart()
        try? await Task.sleep(nanoseconds: 20_000_000)
        await cache.invalidate(fixture.target.identity)
        await delayedRead.complete()
        let staleResult = await pendingRead.value
        let sharedStaleResult = await sharedRead.value
        require(staleResult == .failed(.changed) && sharedStaleResult == .failed(.changed),
                "All in-flight readers reject old ready snapshots after a write in another worktree")
        _ = await cache.value(for: otherIdentity, path: fixture.target.path)
        let reloaded = await delayedRead.calls
        require(reloaded == 2, "An invalidated in-flight read cannot repopulate another worktree’s cache")
        await cache.invalidate(fixture.target.identity)
        _ = await cache.value(for: otherIdentity, path: fixture.target.path)
        let invalidated = await delayedRead.calls
        require(invalidated == 3, "Completed caches for the same PR are invalidated across worktrees")

        let sharedFixture = DelayedReviewFixture(state: .ready(oldFile))
        let sharedCache = ProjectPullRequestReviewCache(lookup: { _, _ in await sharedFixture.lookup() })
        let firstReader = Task { await sharedCache.value(for: otherIdentity, path: fixture.target.path) }
        let secondReader = Task { await sharedCache.value(for: otherIdentity, path: fixture.target.path) }
        await sharedFixture.waitForStart()
        try? await Task.sleep(nanoseconds: 20_000_000)
        await sharedFixture.complete()
        let firstResult = await firstReader.value, secondResult = await secondReader.value
        let sharedCalls = await sharedFixture.calls
        require(firstResult == .ready(oldFile) && secondResult == .ready(oldFile) && sharedCalls == 1,
                "Both callers of one valid pending lookup receive its ready result")
        print("PR review actions: full discussion, literal JSON reply, resolve/unresolve, three review decisions, permissions, exact revision, branch races, uncertain writes and cross-worktree coordination passed")
    }
}

private extension Result where Failure == ProjectPullRequestReviewActionError {
    var failure: Failure? { if case .failure(let error) = self { error } else { nil } }
}
