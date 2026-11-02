import Foundation
import PierreDiffsSwift
@testable import zshell

private nonisolated func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private nonisolated func json(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}

private nonisolated final class ReviewQueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var arguments: [[String]] = []
    func record(_ arguments: [String]) { lock.withLock { self.arguments.append(arguments) } }
    var calls: [[String]] { lock.withLock { arguments } }
}

private nonisolated struct ReviewFixture: Sendable {
    let root: String
    let base: String
    let head: String
    let mergeBase: String
    let previousHead: String

    var identity: ProjectPullRequestReviewIdentity {
        ProjectPullRequestReviewIdentity(ProjectPullRequest(number: 1, status: .draft,
            url: URL(string: "https://github.com/example/base/pull/1")!),
            context: ProjectPullRequestContext(root: root, gitDirectory: root + "/.git",
                localBranch: "feature/review", headBranch: "feature/review",
                headRepository: GitHubRepository("example/fork")!, baseRepository: GitHubRepository("example/base")!))!
    }

    func comment(_ id: String, body: String = "正文 <script>window.reviewInjected=true</script>") -> [String: Any] {
        ["id": id, "author": ["login": "Reviewer"], "body": body,
         "url": "https://github.com/example/base/pull/1#discussion_\(id)",
         "commit": ["oid": previousHead], "originalCommit": ["oid": mergeBase]]
    }

    func connection(_ comments: [[String: Any]], cursor: String? = nil) -> [String: Any] {
        ["nodes": comments, "pageInfo": ["hasNextPage": cursor != nil, "endCursor": cursor as Any? ?? NSNull()]]
    }

    func thread(_ id: String, side: String = "RIGHT", line: Int = 30,
                outdated: Bool = false, subject: String = "LINE", startLine: Int? = nil,
                startSide: String? = nil, cursor: String? = nil) -> [String: Any] {
        ["id": id, "path": "Review.swift", "line": line, "startLine": startLine as Any? ?? NSNull(),
         "diffSide": side, "startDiffSide": startSide as Any? ?? NSNull(), "isResolved": id == "left",
         "isOutdated": outdated, "subjectType": subject, "comments": connection([comment(id)], cursor: cursor)]
    }

    func pullRequest(threads: [[String: Any]]? = nil, cursor: String? = nil,
                     head: String? = nil, base: String? = nil) -> [String: Any] {
        var pr: [String: Any] = ["number": 1, "url": identity.url, "headRefName": "feature/review",
            "headRepository": ["nameWithOwner": "example/fork"], "baseRefOid": base ?? self.base,
            "headRefOid": head ?? self.head]
        if let threads { pr["reviewThreads"] = connection(threads, cursor: cursor) }
        return pr
    }

    func response(_ pr: [String: Any]) -> String { json(["data": ["repository": ["pullRequest": pr]]]) }

    func command(log: ReviewQueryLog, mode: String = "paged") -> GitHubPullRequestReviewWorker.Command {
        { _, arguments, timeout, environment in
            log.record(arguments)
            require(timeout > 0 && timeout <= 20, "查询必须共享20秒总期限")
            require(environment["GH_REPO"] == nil && environment["GH_HOST"] == "github.com",
                    "继承的GH_REPO不得重定向PR查询")
            require(!arguments.contains("POST") && !arguments.contains(where: { $0.contains("mutation") }),
                    "PR评论加载必须只读")
            var output = ""
            if arguments.contains(where: { $0.hasPrefix("query=") && $0.contains("reviewThreads") }) {
                if mode == "duplicate" {
                    var duplicate = thread("right")
                    duplicate["comments"] = connection([comment("right"), comment("right")])
                    output = response(pullRequest(threads: [duplicate]))
                } else if mode == "cursor" {
                    output = response(pullRequest(threads: [thread("right")], cursor: "same"))
                } else if arguments.contains("cursor=threads-next") {
                    output = response(pullRequest(threads: [thread("range", line: 82, startLine: 80, startSide: "RIGHT")]))
                } else {
                    output = response(pullRequest(threads: [thread("left", side: "LEFT", line: 10),
                        thread("right", cursor: "comments-next"), thread("outdated", outdated: true),
                        thread("file", subject: "FILE"), thread("wrong-side", startLine: 28, startSide: "LEFT"),
                        thread("out-of-range", line: 99_999)], cursor: "threads-next"))
                }
            } else if arguments.contains(where: { $0.hasPrefix("query=") && $0.contains("...on PullRequestReviewThread") }) {
                let comments = mode == "reply-duplicate" ? [comment("right")] : [comment(arguments.contains("cursor=comments-next") ? "reply-1" : "reply-2")]
                let next = arguments.contains("cursor=comments-next") ? "comments-last" : nil
                output = json(["data": ["node": ["id": "right", "pullRequest": pullRequest(head: mode == "reply-changed" ? base : nil),
                                                "comments": connection(comments, cursor: next)]]])
            } else if arguments.contains(where: { $0.hasPrefix("query=") }) {
                output = response(pullRequest(head: mode == "changed" ? base : nil))
            } else if arguments.contains(where: { $0.contains("/compare/") }) {
                output = json(["merge_base_commit": ["sha": mergeBase]])
            } else if arguments.contains("repos/example/base/pulls/1/files") {
                output = json([["filename": "Review.swift", "previous_filename": "Before.swift", "status": "renamed"]])
            } else if arguments.contains(where: { $0.contains("/contents/") }) {
                let old = arguments.contains("ref=" + mergeBase)
                let text = String(repeating: "let fixture = 1\n", count: 220)
                output = json(["type": "file", "size": text.utf8.count, "encoding": "base64",
                               "content": Data(text.utf8).base64EncodedString(), "sha": old ? mergeBase : head])
            } else { preconditionFailure("未预期查询：\(arguments)") }
            return BoundedProcessResult(terminationStatus: 0, timedOut: false,
                output: BoundedProcessOutput(stdout: output, stderr: "", wasTruncated: false))
        }
    }

    func query(mode: String = "paged", remote: Bool = false, log: ReviewQueryLog = ReviewQueryLog()) -> ProjectPullRequestReviewState {
        GitHubPullRequestReviewWorker.query(identity, path: "Review.swift",
            environment: ["PATH": "/usr/bin", "GH_REPO": "wrong/repo"],
            locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: command(log: log, mode: mode),
            git: { arguments, root, limit, timeout in
                log.record(["git"] + arguments)
                require(!arguments.contains("fetch") && !arguments.contains("checkout"), "读取评论不得写入Git")
                if remote { return GitCommandDataResult(status: 128, stdout: Data(), stderr: "missing", truncated: false) }
                return GitCommandRunner.runData(arguments, in: root, limit: limit, timeout: timeout)
            })
    }
}

private actor ReviewCacheCounter {
    var calls = 0
    func lookup() async -> ProjectPullRequestReviewState {
        calls += 1
        try? await Task.sleep(nanoseconds: 30_000_000)
        return .failed(.unavailable)
    }
}

@main @MainActor
struct ProjectPullRequestReviewTests {
    static func main() async {
        let fixture = ReviewFixture(root: CommandLine.arguments[1], base: CommandLine.arguments[2],
            head: CommandLine.arguments[3], mergeBase: CommandLine.arguments[4], previousHead: CommandLine.arguments[5])
        let log = ReviewQueryLog()
        guard case .ready(let file) = fixture.query(log: log) else { fatalError("生产PR查询未返回评论") }
        require(file.mergeBaseOID == fixture.mergeBase && file.baseOID == fixture.base && file.headOID == fixture.head,
                "左右内容必须使用精确merge-base/head版本")
        require(file.oldPath == "Before.swift" && file.path == "Review.swift", "重命名必须读取原路径")
        require(!file.oldContents.contains("base branch") && !file.newContents.contains("working tree"),
                "评论不得附着到最新base或本地未提交内容")
        require(file.threads.map(\.id) == ["left", "right", "range"], "有效旧提交讨论必须保留，过时/文件级/越界不得错位展示")
        require(file.outdatedThreadCount == 1, "只有GitHub标为过时的讨论才能称为过时")
        require(file.annotations.count == 5 && file.annotations.allSatisfy { $0.metadata.isReadOnly == true }, "评论和分页回复必须只读")
        require(file.annotations[0].side == .deletions && file.annotations[0].lineNumber == 10,
                "LEFT必须映射到旧版行号")
        require(file.annotations[1].side == .additions && file.annotations[1].lineNumber == 30,
                "RIGHT必须映射到新版行号")
        require(file.threads[1].comments.nodes.map(\.id) == ["right", "reply-1", "reply-2"], "回复必须跨页完整加载且保持顺序")
        require(log.calls.filter { $0.contains(where: { $0.hasPrefix("query=") }) }.count == 5, "线程与回复分页不应重复查询")
        require(fixture.query(mode: "changed") == .failed(.changed), "末次head变化必须拒绝显示")
        require(fixture.query(mode: "reply-changed") == .failed(.changed), "回复分页head变化必须拒绝显示")
        require(fixture.query(mode: "duplicate") == .failed(.unavailable), "初页重复评论ID必须失败")
        require(fixture.query(mode: "reply-duplicate") == .failed(.unavailable), "跨页重复回复必须失败")
        require(fixture.query(mode: "cursor") == .failed(.unavailable), "重复cursor必须终止")
        let remoteLog = ReviewQueryLog()
        guard case .ready(let fallback) = fixture.query(remote: true, log: remoteLog) else { fatalError("缺本地对象时GitHub只读回退失败") }
        require(fallback.oldPath == "Before.swift" && fallback.annotations.count == 5, "回退必须保留重命名及评论")
        require(remoteLog.calls.contains { $0.contains(where: { $0.contains("/compare/") }) }, "回退必须计算真实merge-base")
        require(GitHubPullRequestReviewWorker.lineCount("a\r\nb\r\n") == 2, "CRLF行号必须与GitHub一致")
        require(GitHubPullRequestReviewWorker.lineCount("a\nb") == 2 && GitHubPullRequestReviewWorker.lineCount("") == 0,
                "缺末尾换行和空文件行号")
        require(!GitHubPullRequestReviewWorker.validPath("../outside") && !GitHubPullRequestReviewWorker.validPath("/outside"), "拒绝越界路径")
        require(ProjectPullRequestReviewFile.commentURL("https://github.com.evil.invalid/example/base/pull/1", identity: fixture.identity) == nil,
                "拒绝伪造评论链接")
        let failures: [(Int32, Bool, Bool, ProjectPullRequestReviewState)] = [
            (4, false, false, .failed(.notSignedIn)), (1, false, false, .failed(.unavailable)),
            (0, true, false, .failed(.unavailable)), (0, false, true, .failed(.unavailable))]
        for (status, timeout, truncated, expected) in failures {
            let actual = GitHubPullRequestReviewWorker.query(fixture.identity, path: "Review.swift",
                locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }, command: { _, _, _, _ in
                    BoundedProcessResult(terminationStatus: status, timedOut: timeout,
                        output: BoundedProcessOutput(stdout: "", stderr: "", wasTruncated: truncated))
                })
            require(actual == expected, "认证、超时和截断结果不得展示部分评论")
        }
        let counter = ReviewCacheCounter()
        let cache = ProjectPullRequestReviewCache(lookup: { _, _ in await counter.lookup() })
        async let first = cache.value(for: fixture.identity, path: "Review.swift")
        async let second = cache.value(for: fixture.identity, path: "Review.swift")
        _ = await (first, second)
        let calls = await counter.calls
        require(calls == 1, "同时加载必须共享查询")
        _ = await cache.value(for: fixture.identity, path: "Review.swift", force: true)
        let forced = await counter.calls
        require(forced == 2, "刷新必须重新查询")
        if ProcessInfo.processInfo.environment["ZSHELL_PR_REVIEW_LIVE"] == "1" {
            guard case .repository(let snapshot) = GitStatusModel.branchSnapshot(in: CommandLine.arguments[6]) else {
                fatalError("真实GitHub测试未读取到原worktree")
            }
            guard case .context(let context) = ProjectPullRequestContext.resolve(snapshot) else {
                fatalError("真实GitHub测试无法解析分支远程地址")
            }
            let state = GitHubPullRequestWorker.query(context)
            guard case .pullRequest(let pr) = state,
                  let identity = ProjectPullRequestReviewIdentity(pr, context: context) else {
                fatalError("真实GitHub PR查询失败：\(state)")
            }
            let path = ProcessInfo.processInfo.environment["ZSHELL_PR_REVIEW_LIVE_PATH"] ?? "mac/zshell/ProjectPullRequest.swift"
            let review = GitHubPullRequestReviewWorker.query(identity, path: path)
            guard case .ready(let live) = review else {
                fatalError("真实GitHub评论查询失败：\(review)")
            }
            print("真实GitHub PR #\(live.identity.number)：精确版本文件和评论读取通过，当前\(live.annotations.count)条评论")
        }
        print("PR评论生产查询：merge-base/head、重命名、左右行、旧提交讨论、线程与回复分页、只读回退、失败边界和缓存通过")
    }
}
