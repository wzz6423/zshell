import Foundation

private nonisolated func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private func snapshot(_ directory: String) -> GitStatusModel.BranchSnapshot {
    guard case .repository(let result) = GitStatusModel.branchSnapshot(in: directory) else {
        fatalError("Expected Git repository at \(directory)")
    }
    return result
}

private func context(_ snapshot: GitStatusModel.BranchSnapshot) -> ProjectPullRequestContext {
    guard case .context(let result) = ProjectPullRequestContext.resolve(snapshot) else {
        fatalError("Expected a GitHub context")
    }
    return result
}

private func response(_ nodes: [[String: Any]], hasNext: Bool = false) -> String {
    let payload: [String: Any] = ["data": ["repository": [
        "parent": NSNull(),
        "pullRequests": ["pageInfo": ["hasNextPage": hasNext], "nodes": nodes],
    ]]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
}

private func node(_ number: Int, branch: String = "feature/one", repo: String = "example/fork",
                  state: String = "OPEN", draft: Bool = false, url: String? = nil) -> [String: Any] {
    ["number": number, "url": url ?? "https://github.com/example/base/pull/\(number)",
     "state": state, "isDraft": draft, "headRefName": branch,
     "headRepository": ["nameWithOwner": repo], "updatedAt": "2026-01-01T00:00:00Z"]
}

private func query(_ context: ProjectPullRequestContext, output: String, status: Int32 = 0,
                   timedOut: Bool = false, truncated: Bool = false) -> ProjectPullRequestState {
    GitHubPullRequestWorker.query(context, environment: ["PATH": "/usr/bin", "GH_REPO": "wrong/repo"],
        locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: { _, _, _, environment in
            require(environment["GH_REPO"] == nil, "GH_REPO must not redirect the query")
            return BoundedProcessResult(terminationStatus: status, timedOut: timedOut,
                output: BoundedProcessOutput(stdout: output, stderr: "", wasTruncated: truncated))
        })
}

private nonisolated final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GitStatusModel.BranchSnapshot
    init(_ value: GitStatusModel.BranchSnapshot) { stored = value }
    func get() -> GitStatusModel.BranchSnapshot { lock.withLock { stored } }
    func set(_ value: GitStatusModel.BranchSnapshot) { lock.withLock { stored = value } }
}

private actor Counter {
    var calls = 0
    func increment() { calls += 1 }
}

@main
struct ProjectPullRequestTests {
    @MainActor static func main() async {
        let repo = CommandLine.arguments[1], worktree = CommandLine.arguments[2]
        let first = snapshot(repo), second = snapshot(worktree)
        require(first.branch == "feature/one", "main checkout branch")
        require(second.branch == "feature/two", "linked worktree branch")
        require(first.gitDirectory != second.gitDirectory && first.commonGitDirectory == second.commonGitDirectory,
                "linked worktree must use its own HEAD and shared config")
        let firstContext = context(first), secondContext = context(second)
        require(firstContext.headRepository.nameWithOwner == "example/fork", "head repository")
        require(firstContext.baseRepository?.nameWithOwner == "example/base", "upstream repository")
        require(secondContext.headBranch == "feature/two", "worktree branch resolution")
        let ambiguous = GitStatusModel.BranchSnapshot(root: first.root, gitDirectory: first.gitDirectory,
            commonGitDirectory: first.commonGitDirectory, branch: first.branch,
            configuration: ["remote.a.url": ["git@github.com:example/a.git"],
                            "remote.b.url": ["git@github.com:example/b.git"]])
        guard case .ambiguous = ProjectPullRequestContext.resolve(ambiguous) else {
            fatalError("Multiple unrelated remotes must not be guessed")
        }
        let nonGitHub = GitStatusModel.BranchSnapshot(root: first.root, gitDirectory: first.gitDirectory,
            commonGitDirectory: first.commonGitDirectory, branch: first.branch,
            configuration: ["remote.origin.url": ["https://example.com/a/b.git"]])
        guard case .hidden = ProjectPullRequestContext.resolve(nonGitHub) else {
            fatalError("A non-GitHub remote must not be queried")
        }
        require(GitHubRepository.remote("https://example.com/a/b.git") == nil, "non-GitHub remote")
        require(GitHubRepository.remote("git@github.com:Example/Fork.git")?.nameWithOwner == "example/fork",
                "SSH remote resolution")
        require(GitHubRepository.remote("https://github.com.evil.invalid/a/b") == nil, "spoofed host")
        guard case .notRepository = GitStatusModel.branchSnapshot(in: CommandLine.arguments[3]) else {
            fatalError("Plain directory must not be treated as a repository")
        }

        for (state, draft, expected) in [("OPEN", false, ProjectPullRequest.Status.open),
                                         ("OPEN", true, .draft), ("MERGED", false, .merged),
                                         ("CLOSED", false, .closed)] {
            let actual = query(firstContext, output: response([node(42, state: state, draft: draft)]))
            guard case .pullRequest(let pr) = actual else { fatalError("missing \(expected) PR") }
            require(pr.number == 42 && pr.status == expected, "incorrect PR status")
        }
        require(query(firstContext, output: response([node(9, repo: "other/fork")])) == .none,
                "same branch in a different fork must not match")
        require(query(firstContext, output: response([node(9, branch: "feature/two")])) == .none,
                "other branch must not match")
        require(query(firstContext, output: response([node(9, url: "https://evil.invalid/pull/9")])) == .none,
                "unexpected PR URL must not be opened")
        let ownPR = response([node(45, url: "https://github.com/example/fork/pull/45")])
        let empty = response([])
        let ownResult = GitHubPullRequestWorker.query(firstContext,
            locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: { _, arguments, _, _ in
                BoundedProcessResult(terminationStatus: 0, timedOut: false,
                    output: BoundedProcessOutput(stdout: arguments.contains("name=fork") ? ownPR : empty,
                                                 stderr: "", wasTruncated: false))
            })
        guard case .pullRequest(let own) = ownResult, own.number == 45 else {
            fatalError("an upstream remote must not hide a PR targeting the head repository")
        }
        require(query(firstContext, output: response([], hasNext: true)) == .failed(.unavailable),
                "incomplete results must not claim no PR")
        require(query(firstContext, output: "", status: 4) == .failed(.notSignedIn), "authentication error")
        require(query(firstContext, output: "", timedOut: true) == .failed(.unavailable), "timeout")
        require(query(firstContext, output: "", truncated: true) == .failed(.unavailable), "truncated output")
        require(GitHubPullRequestWorker.query(firstContext, locate: { _ in nil }) == .failed(.missingCLI),
                "missing gh")

        let counter = Counter()
        let cache = ProjectPullRequestCache(lookup: { _ in await counter.increment(); return .none })
        _ = await cache.value(for: firstContext)
        _ = await cache.value(for: firstContext)
        let cachedCalls = await counter.calls
        require(cachedCalls == 1, "cache should reuse a fresh result")
        _ = await cache.value(for: firstContext, force: true)
        let forcedCalls = await counter.calls
        require(forcedCalls == 2, "force refresh should requery")

        let box = SnapshotBox(first)
        let switchingCache = ProjectPullRequestCache(lookup: { item in
            if item.localBranch == "feature/one" { try? await Task.sleep(nanoseconds: 600_000_000) }
            let number = item.localBranch == "feature/one" ? 1 : 2
            return .pullRequest(ProjectPullRequest(number: number, status: .open,
                url: URL(string: "https://github.com/example/base/pull/\(number)")!))
        })
        let model = ProjectPullRequestModel(cache: switchingCache, probe: { _ in .repository(box.get()) })
        model.sync(directory: repo)
        try? await Task.sleep(nanoseconds: 100_000_000)
        box.set(second)
        model.sync(directory: repo, force: true)
        for _ in 0..<100 {
            if case .pullRequest(let pr) = model.state, pr.number == 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard case .pullRequest(let pr) = model.state, pr.number == 2 else {
            fatalError("late result for the old branch replaced the current branch")
        }
        box.set(first)
        var opened = false
        model.open { _ in opened = true }
        try? await Task.sleep(nanoseconds: 200_000_000)
        require(!opened, "a click after a branch switch must not open the previous PR")
        model.detach()
        require(model.state == .hidden, "detached model must hide its result")
        if let liveBranch = ProcessInfo.processInfo.environment["ZSHELL_PR_LIVE_BRANCH"],
           let liveRepository = ProcessInfo.processInfo.environment["ZSHELL_PR_LIVE_REPOSITORY"].flatMap(GitHubRepository.init),
           let expected = ProcessInfo.processInfo.environment["ZSHELL_PR_LIVE_NUMBER"].flatMap(Int.init) {
            let liveContext = ProjectPullRequestContext(root: repo, gitDirectory: first.gitDirectory,
                localBranch: liveBranch, headBranch: liveBranch, headRepository: liveRepository, baseRepository: nil)
            guard case .pullRequest(let livePR) = GitHubPullRequestWorker.query(liveContext), livePR.number == expected else {
                fatalError("live GitHub lookup did not match the expected pull request")
            }
            print("Live GitHub PR lookup passed")
        }
        print("Project PR status: Git worktrees, four states, remote safety, errors, cache and branch race passed")
    }
}
