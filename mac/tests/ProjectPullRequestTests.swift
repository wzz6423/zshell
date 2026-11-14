import Combine
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

private func checkBranchTagCollisions(_ repo: String, worktree: String) {
    let first = snapshot(repo), second = snapshot(worktree)
    for branch in ["feature/one", "feature/two"] {
        require(GitCommandRunner.runData(["tag", branch], in: repo).status == 0, "same-named tag is created")
    }
    require(snapshot(repo) == first && snapshot(worktree) == second,
            "same-named tags must not change local or linked-worktree branch identity")
    require(context(snapshot(repo)) == context(first) && context(snapshot(worktree)) == context(second),
            "same-named tags must not change the PR query context")
    let branch = "heads/feature"
    require(GitCommandRunner.runData(["switch", "-c", branch], in: repo).status == 0,
            "a branch whose real name starts with heads/ is created")
    require(GitCommandRunner.runData(["tag", branch], in: repo).status == 0, "the prefixed branch also has a same-named tag")
    let prefixed = snapshot(repo)
    require(prefixed.branch == branch && context(prefixed).localBranch == branch && context(prefixed).headBranch == branch,
            "a real heads/ prefix must be retained in branch and PR identity")
    require(GitCommandRunner.runData(["switch", "--detach", "HEAD"], in: repo).status == 0,
            "the fixture enters detached HEAD")
    require(snapshot(repo).branch == nil, "detached HEAD must remain branchless")
    guard case .hidden = ProjectPullRequestContext.resolve(snapshot(repo)) else {
        fatalError("detached HEAD must not query a branch PR")
    }
    require(GitCommandRunner.runData(["switch", "feature/one"], in: repo).status == 0,
            "the original fixture branch is restored")
    let headReads = QueryLog()
    let raced = GitStatusModel.branchSnapshot(in: repo, commandRunner: { arguments, directory in
        if arguments.first == "symbolic-ref", arguments.last == "HEAD" {
            headReads.append(arguments)
            if headReads.calls().count == 2 {
                require(GitCommandRunner.runData(["switch", branch], in: directory).status == 0,
                        "the fixture switches branches during the probe")
            }
        }
        return GitCommandRunner.runData(arguments, in: directory, limit: 65_536, timeout: 3)
    })
    guard case .unavailable = raced else { fatalError("a concurrent branch switch must invalidate the probe") }
    require(GitCommandRunner.runData(["switch", "feature/one"], in: repo).status == 0,
            "the original branch is restored after the race")
    let unborn = URL(fileURLWithPath: repo).deletingLastPathComponent().appendingPathComponent("unborn")
    try! FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: false)
    require(GitCommandRunner.runData(["init", "-q", "--initial-branch=heads/unborn"], in: unborn.path).status == 0,
            "an unborn fixture branch is initialized")
    require(snapshot(unborn.path).branch == "heads/unborn", "unborn branches must retain their exact local name")
    print("Branch/tag collisions: local, worktree, PR context, heads/ prefix, detached and unborn passed")
}

private nonisolated func response(_ nodes: [[String: Any]], hasNext: Bool = false) -> String {
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

private nonisolated func filteredResponse(_ nodes: [[String: Any]]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: nodes), as: UTF8.self)
}

private nonisolated final class QueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []
    func append(_ value: [String]) { lock.withLock { stored.append(value) } }
    func calls() -> [[String]] { lock.withLock { stored } }
}

private func checkFilteredLookup(_ context: ProjectPullRequestContext) {
    let crowded = response((1...50).map { node($0, repo: "other/fork") }, hasNext: true)
    let firstPage = filteredResponse((1...50).map { node($0, repo: "example/another-fork") })
    let secondPage = filteredResponse([node(87), node(88)])
    let log = QueryLog()
    let paged = GitHubPullRequestWorker.query(context,
        locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: { _, arguments, timeout, _ in
            log.append(arguments)
            require(timeout > 0 && timeout <= 12, "all query stages must share the total deadline")
            let output: String
            if arguments.contains("repos/example/base/pulls") {
                require(arguments.contains("head=example:feature/one") && arguments.contains("GET"),
                        "large connections must filter the head owner on the server")
                require(arguments.contains("state=open"), "an open PR must take priority over a closed PR")
                output = arguments.contains("page=1") ? firstPage : secondPage
            } else { output = arguments.contains("name=base") ? crowded : response([]) }
            return BoundedProcessResult(terminationStatus: 0, timedOut: false,
                output: BoundedProcessOutput(stdout: output, stderr: "", wasTruncated: false))
        })
    guard case .pullRequest(let pr) = paged, pr.number == 88, pr.status == .open else {
        fatalError("owner-filtered paging must find the exact fork on later pages and break timestamp ties")
    }
    require(log.calls().filter { $0.contains("repos/example/base/pulls") }.count == 2,
            "lookup must stop once the best exact-fork match is known")

    for state in ["MERGED", "CLOSED"] {
        let closed = filteredResponse([node(90, state: state)])
        let result = GitHubPullRequestWorker.query(context,
            locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: { _, arguments, _, _ in
                let output: String
                if arguments.contains("repos/example/base/pulls") {
                    output = arguments.contains("state=open") ? filteredResponse([]) : closed
                } else { output = arguments.contains("name=base") ? crowded : response([]) }
                return BoundedProcessResult(terminationStatus: 0, timedOut: false,
                    output: BoundedProcessOutput(stdout: output, stderr: "", wasTruncated: false))
            })
        guard case .pullRequest(let pr) = result, pr.number == 90, pr.status.rawValue == state else {
            fatalError("filtered lookup must retain \(state) state when no open PR exists")
        }
    }

    let empty = GitHubPullRequestWorker.query(context,
        locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: { _, arguments, _, _ in
            let output = arguments.contains("repos/example/base/pulls") ? filteredResponse([])
                : arguments.contains("name=base") ? crowded : response([])
            return BoundedProcessResult(terminationStatus: 0, timedOut: false,
                output: BoundedProcessOutput(stdout: output, stderr: "", wasTruncated: false))
        })
    require(empty == .none, "a crowded branch with no exact-fork PR must report no PR")

    let withoutUpstream = ProjectPullRequestContext(root: context.root, gitDirectory: context.gitDirectory,
        localBranch: context.localBranch, headBranch: context.headBranch,
        headRepository: context.headRepository, baseRepository: nil)
    let forkResponse = "{\"data\":{\"repository\":{\"parent\":{\"nameWithOwner\":\"example/base\"},\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}"
    let parent = GitHubPullRequestWorker.query(withoutUpstream,
        locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: { _, arguments, _, _ in
            let output = arguments.contains("repos/example/base/pulls") ? secondPage
                : arguments.contains("name=base") ? crowded : forkResponse
            return BoundedProcessResult(terminationStatus: 0, timedOut: false,
                output: BoundedProcessOutput(stdout: output, stderr: "", wasTruncated: false))
        })
    guard case .pullRequest(let parentPR) = parent, parentPR.number == 88 else {
        fatalError("a fork without an upstream remote must also filter crowded parent PR connections")
    }

    let boundedLog = QueryLog()
    let bounded = GitHubPullRequestWorker.query(context,
        locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: { _, arguments, _, _ in
            boundedLog.append(arguments)
            let output = arguments.contains("graphql") ? crowded : firstPage
            return BoundedProcessResult(terminationStatus: 0, timedOut: false,
                output: BoundedProcessOutput(stdout: output, stderr: "", wasTruncated: false))
        })
    require(bounded == .failed(.unavailable) && boundedLog.calls().count == 11,
            "ambiguous owner-filtered pages must be bounded and cannot claim no PR")

    for (status, timedOut, truncated, expected) in [(Int32(4), false, false, ProjectPullRequestState.failed(.notSignedIn)),
                                                    (0, true, false, .failed(.unavailable)),
                                                    (0, false, true, .failed(.unavailable))] {
        let failed = GitHubPullRequestWorker.query(context,
            locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: { _, arguments, _, _ in
                let filtering = !arguments.contains("graphql")
                return BoundedProcessResult(terminationStatus: filtering ? status : 0,
                    timedOut: filtering && timedOut,
                    output: BoundedProcessOutput(stdout: crowded, stderr: "", wasTruncated: filtering && truncated))
            })
        require(failed == expected, "filtered requests must preserve authentication, timeout and output failures")
    }
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

private actor LookupGate {
    var started = false
    var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
        finished = true
    }

    func release() { continuation?.resume(); continuation = nil }
}

private func waitForPR(_ number: Int, in model: ProjectPullRequestModel) async {
    for _ in 0..<150 {
        if case .pullRequest(let pr) = model.state, pr.number == number { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    fatalError("Expected PR #\(number), got \(model.state)")
}

private func checkWatchedGitNoise(_ repo: String) async {
    let expected = snapshot(repo)
    let queries = Counter()
    let probes = QueryLog()
    let pr = ProjectPullRequest(number: 71, status: .open,
        url: URL(string: "https://github.com/example/base/pull/71")!)
    let cache = ProjectPullRequestCache(lookup: { _ in await queries.increment(); return .pullRequest(pr) })
    let model = ProjectPullRequestModel(cache: cache, probe: { directory in
        let result = GitStatusModel.branchSnapshot(in: directory)
        let unchanged: Bool
        if case .repository(let current) = result { unchanged = current == expected }
        else { unchanged = false }
        probes.append([directory, "unchanged=\(unchanged)"])
        return result
    })
    model.sync(directory: repo)
    await waitForPR(pr.number, in: model)
    try? await Task.sleep(nanoseconds: 100_000_000)
    var states: [ProjectPullRequestState] = []
    let observation = model.$state.dropFirst().sink { states.append($0) }
    let initialProbes = probes.calls().count
    let lock = URL(fileURLWithPath: expected.gitDirectory).appendingPathComponent("index.lock")
    try! Data().write(to: lock)
    try? await Task.sleep(nanoseconds: 2_400_000_000)
    let unchanged = snapshot(repo) == expected
    let newProbes = probes.calls().count - initialProbes
    require(unchanged, "index.lock activity must not change the branch snapshot")
    require(probes.calls().allSatisfy { $0.last == "unchanged=true" }, "all probes must see the same repository context")
    require(newProbes == 1, "one unrelated metadata event must trigger one branch probe")
    require(states.allSatisfy { $0 == .pullRequest(pr) },
            "index.lock events must not hide the PR row or show Checking PR again")
    let queryCount = await queries.calls
    require(queryCount == 1, "unrelated Git metadata must not request another PR lookup")
    states.removeAll()
    let burstStart = probes.calls().count
    try! FileManager.default.removeItem(at: lock)
    let gitDirectory = URL(fileURLWithPath: expected.gitDirectory)
    let scratch = gitDirectory.appendingPathComponent("fixture-noise")
    for iteration in 0..<60 {
        if iteration % 20 == 0 {
            require(GitCommandRunner.runData(["read-tree", "HEAD"], in: repo).status == 0,
                    "fixture index rewrite failed")
        }
        try! Data().write(to: lock)
        try! FileManager.default.removeItem(at: lock)
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        try! FileManager.default.removeItem(at: scratch)
        try? await Task.sleep(nanoseconds: 40_000_000)
    }
    try? await Task.sleep(nanoseconds: 2_400_000_000)
    let burstProbes = probes.calls().count - burstStart
    require(burstProbes > 0 && burstProbes <= 3, "continuous metadata events must be coalesced into bounded probes")
    require(states.allSatisfy { $0 == .pullRequest(pr) }, "continuous Git events must preserve the visible PR state")
    let burstQueries = await queries.calls
    require(burstQueries == 1, "continuous Git events must reuse the existing PR lookup")
    require(snapshot(repo) == expected, "noise events must leave the PR context unchanged")
    observation.cancel()
    model.detach()
    print("Git watcher noise: unchanged snapshot, stable PR, one lock probe and \(burstProbes) continuous-event probes passed")
}

private func writeInPlace(_ data: Data, to url: URL) {
    let handle = try! FileHandle(forWritingTo: url)
    try! handle.truncate(atOffset: 0)
    try! handle.write(contentsOf: data)
    try! handle.close()
}

private func checkWatchedContextChanges(_ repo: String) async {
    let branch = "feature/watched"
    let created = GitCommandRunner.runData(["branch", branch, "refs/heads/feature/one"], in: repo)
    require(created.status == 0, "fixture branch creation failed: \(created.stderr)")
    let initial = snapshot(repo), probes = QueryLog(), queries = QueryLog()
    let cache = ProjectPullRequestCache(lookup: { item in
        queries.append([item.localBranch, item.headRepository.nameWithOwner])
        let number = item.headRepository.nameWithOwner == "example/fork"
            ? (item.localBranch == "feature/one" ? 72 : 73) : (item.localBranch == "feature/one" ? 75 : 74)
        return .pullRequest(ProjectPullRequest(number: number, status: .open,
            url: URL(string: "https://github.com/example/base/pull/\(number)")!))
    })
    let model = ProjectPullRequestModel(cache: cache, probe: { directory in
        probes.append([directory])
        return GitStatusModel.branchSnapshot(in: directory)
    })
    model.sync(directory: repo)
    await waitForPR(72, in: model)
    let head = URL(fileURLWithPath: initial.gitDirectory).appendingPathComponent("HEAD")
    let config = URL(fileURLWithPath: initial.commonGitDirectory).appendingPathComponent("config")
    let originalHead = try! Data(contentsOf: head), originalConfig = try! Data(contentsOf: config)
    let count = probes.calls().count
    try! originalHead.write(to: head, options: .atomic)
    try! originalConfig.write(to: config, options: .atomic)
    for _ in 0..<150 {
        if probes.calls().count > count { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    require(probes.calls().count > count, "same-content atomic replacements must be probed")
    try? await Task.sleep(nanoseconds: 100_000_000)
    require(snapshot(repo) == initial, "same-content replacements must keep the PR context")
    // In-place writes produce no directory replacement event. They must reach
    // the reattached HEAD/config sources after their old inodes were replaced.
    writeInPlace(Data("ref: refs/heads/\(branch)\n".utf8), to: head)
    await waitForPR(73, in: model)
    let changedConfig = String(decoding: originalConfig, as: UTF8.self)
        .replacingOccurrences(of: "git@github.com:example/fork.git", with: "git@github.com:another/fork.git")
    writeInPlace(Data(changedConfig.utf8), to: config)
    await waitForPR(74, in: model)
    require(model.context?.headRepository.nameWithOwner == "another/fork", "remote config change was not resolved")
    require(GitCommandRunner.runData(["switch", "feature/one"], in: repo).status == 0, "real branch switch failed")
    await waitForPR(75, in: model)
    require(GitCommandRunner.runData(["remote", "set-url", "origin", "git@github.com:example/fork.git"], in: repo).status == 0,
            "remote config restoration failed")
    await waitForPR(72, in: model)
    require(queries.calls() == [["feature/one", "example/fork"], [branch, "example/fork"],
                               [branch, "another/fork"], ["feature/one", "another/fork"]],
            "context changes must query the new branch/repository and reuse fresh results")
    require(snapshot(repo) == initial, "fixture context must be restored")
    model.detach()
    print("Git watcher identity: atomic replacement, reattached HEAD/config, real branch switch and remote changes passed")
}

private func checkWatchedLookupRace(_ repo: String) async {
    let gate = LookupGate()
    let cache = ProjectPullRequestCache(lookup: { item in
        if item.localBranch == "feature/one" { await gate.wait() }
        let number = item.localBranch == "feature/one" ? 76 : 77
        return .pullRequest(ProjectPullRequest(number: number, status: .open,
            url: URL(string: "https://github.com/example/base/pull/\(number)")!))
    })
    let model = ProjectPullRequestModel(cache: cache)
    model.sync(directory: repo)
    for _ in 0..<150 {
        if await gate.started { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    let started = await gate.started
    require(started, "the old branch lookup must be pending before switching")
    require(GitCommandRunner.runData(["switch", "feature/watched"], in: repo).status == 0,
            "fixture branch switch during pending lookup failed")
    await waitForPR(77, in: model)
    var states: [ProjectPullRequestState] = []
    let observation = model.$state.dropFirst().sink { states.append($0) }
    await gate.release()
    for _ in 0..<150 {
        if await gate.finished { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    try? await Task.sleep(nanoseconds: 400_000_000)
    require(states.allSatisfy {
        if case .pullRequest(let pr) = $0 { return pr.number == 77 }
        return false
    }, "an old asynchronous result must not replace or invalidate the current PR")
    require(model.context?.localBranch == "feature/watched", "late old lookup changed the current branch context")
    await waitForPR(77, in: model)
    observation.cancel()
    model.detach()
    require(GitCommandRunner.runData(["switch", "feature/one"], in: repo).status == 0, "fixture branch restoration failed")
    print("Git watcher race: pending old lookup cannot overwrite the new real branch PR passed")
}

/// Runs real Git with the environments Zshell builds, so the proxy is checked
/// the way Git resolves it rather than by inspecting dictionary keys.
private func gitProxy(_ environment: [String: String], in directory: String) -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["config", "--get-all", "http.proxy"]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    process.environment = environment
    process.standardOutput = pipe
    try! process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func checkGitProxy(_ repo: String) {
    let base = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    for valid in ["http://127.0.0.1:7897", " socks5h://user:pass@proxy.example:1080 ", "https://[::1]:8443",
                  "http://proxy.example", "socks5://proxy.example:1", "https://proxy.example:65535"] {
        require(GitProxy.normalized(valid) == valid.trimmingCharacters(in: .whitespaces), "valid proxy \(valid)")
    }
    for invalid in ["", "127.0.0.1:7897", "ftp://127.0.0.1:21", "http://", "http://a b:1", "http://h:1/?x=1", "http://h\n:1",
                    "socks4://127.0.0.1:1080", "SOCKS4A://127.0.0.1:1080", "http://127.0.0.1:0",
                    "http://127.0.0.1:65536", "https://[::1]:99999"] {
        require(GitProxy.normalized(invalid) == nil, "invalid proxy \(invalid.debugDescription)")
    }
    require(GitProxy.defaultEnabled == false && GitProxy.defaultAddress == "http://127.0.0.1:7897", "proxy defaults")
    GitProxy.update(enabled: false, address: GitProxy.defaultAddress)
    require(GitProxy.processEnvironment(inheriting: base) == base, "a disabled proxy must not touch app processes")
    require(GitProxy.terminalEnvironment(inheriting: base).isEmpty, "a disabled proxy must not touch terminals")
    GitProxy.update(enabled: true, address: "not a proxy")
    require(GitProxy.address == nil, "an invalid address must disable the proxy")
    GitProxy.update(enabled: true, address: " http://127.0.0.1:7897 ")
    let app = GitProxy.processEnvironment(inheriting: base)
    require(app["HTTPS_PROXY"] == "http://127.0.0.1:7897" && app["https_proxy"] == "http://127.0.0.1:7897"
            && app["all_proxy"] == "http://127.0.0.1:7897", "gh must see the proxy")
    require(gitProxy(app, in: repo) == "http://127.0.0.1:7897", "app Git must use the proxy")
    let runner = GitCommandRunner.processEnvironment()
    require(runner["GIT_TERMINAL_PROMPT"] == "0" && runner["HTTPS_PROXY"] == "http://127.0.0.1:7897", "runner environment")
    let terminal = GitProxy.terminalEnvironment(inheriting: base)
    require(Set(terminal.keys) == ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"],
            "terminals must get only Git configuration")
    require(gitProxy(base.merging(terminal) { $1 }, in: repo) == "http://127.0.0.1:7897", "terminal Git must use the proxy")
    let existing = base.merging(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.pager", "GIT_CONFIG_VALUE_0": "cat"]) { $1 }
    let appended = existing.merging(GitProxy.terminalEnvironment(inheriting: existing)) { $1 }
    require(appended["GIT_CONFIG_COUNT"] == "2" && appended["GIT_CONFIG_KEY_0"] == "core.pager"
            && gitProxy(appended, in: repo) == "http://127.0.0.1:7897", "existing GIT_CONFIG entries must be kept")
    // A reused PTY daemon applies the overrides to an environment without the
    // GUI's inherited entries, so the overrides alone must stay complete.
    let staleDaemon = base.merging(GitProxy.terminalEnvironment(inheriting: existing)) { $1 }
    require(staleDaemon["GIT_CONFIG_KEY_0"] == "core.pager" && staleDaemon["GIT_CONFIG_VALUE_0"] == "cat"
            && gitProxy(staleDaemon, in: repo) == "http://127.0.0.1:7897", "terminal overrides must carry inherited entries")
    GitProxy.update(enabled: false, address: GitProxy.defaultAddress)
}

@main
struct ProjectPullRequestTests {
    @MainActor static func main() async {
        let repo = CommandLine.arguments[1], worktree = CommandLine.arguments[2]
        checkGitProxy(repo)
        let first = snapshot(repo), second = snapshot(worktree)
        require(first.branch == "feature/one", "main checkout branch")
        require(second.branch == "feature/two", "linked worktree branch")
        require(first.gitDirectory != second.gitDirectory && first.commonGitDirectory == second.commonGitDirectory,
                "linked worktree must use its own HEAD and shared config")
        let firstContext = context(first), secondContext = context(second)
        require(firstContext.headRepository.nameWithOwner == "example/fork", "head repository")
        require(firstContext.baseRepository?.nameWithOwner == "example/base", "upstream repository")
        require(secondContext.headBranch == "feature/two", "worktree branch resolution")
        checkBranchTagCollisions(repo, worktree: worktree)
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
        checkFilteredLookup(firstContext)
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

        await checkWatchedGitNoise(repo)
        await checkWatchedContextChanges(repo)
        await checkWatchedLookupRace(repo)

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
        print("Project PR status: Git worktrees, four states, filtered pagination, remote safety, errors, cache and branch race passed")
    }
}
