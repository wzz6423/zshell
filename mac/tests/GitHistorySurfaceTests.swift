import AppKit
import Foundation
@testable import zshell

private struct ExpectedHistoryFile: Decodable {
    let status: String
    let path: String
    let original: String?
}

private struct ExpectedHistoryCommit: Decodable {
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let parent: String?
    let files: [ExpectedHistoryFile]
}

@main @MainActor
struct GitHistorySurfaceTests {
    private static var checks = 0

    private static func check(_ condition: Bool, _ label: String) {
        checks += 1
        precondition(condition, label)
    }

    private static func wait(_ label: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        check(condition(), label)
    }

    private static func verify(
        _ commits: [GitStatusModel.RecentCommit], _ expected: [ExpectedHistoryCommit]
    ) {
        check(commits.count == expected.count, "Commit count")
        for (actual, expected) in zip(commits, expected) {
            check(actual.hash == expected.hash, "Hash")
            check(actual.shortHash == expected.shortHash, "Short hash")
            check(actual.subject == expected.subject, "Control-character subject")
            check(actual.author == expected.author, "Control-character author")
            check(actual.parentHash == expected.parent, "Parent")
            check(actual.files.count == expected.files.count, "File count")
            for file in expected.files {
                let actualFile = actual.files.first { $0.path == file.path }
                check(
                    actualFile?.path == file.path && actualFile?.originalPath == file.original
                        && actualFile.map { String($0.status) } == file.status,
                    "Literal path and status"
                )
            }
        }
    }

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let expected = try JSONDecoder().decode(
            [ExpectedHistoryCommit].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        )
        let model = GitStatusModel()
        model.sync(root: CommandLine.arguments[1])
        wait("Initial status") {
            model.hasResolvedStatus && !model.isRefreshing && model.isRepo
        }
        verify(model.recentCommits, Array(expected.prefix(30)))
        check(model.hasMoreRecentCommits, "Pagination available")
        check(model.detailError == nil && model.statusError == nil, "Initial status has no errors")
        check(model.loadMoreCommits(), "Next page requested")
        wait("Next page") {
            !model.isRefreshing && !model.isLoadingMoreCommits
                && model.recentCommits.count == expected.count
        }
        verify(model.recentCommits, expected)
        check(!model.hasMoreRecentCommits && !model.loadMoreCommits(), "Pagination complete")
        model.refresh()
        wait("Refresh keeps expanded history") { !model.isRefreshing }
        verify(model.recentCommits, expected)

        let graph = RecentCommitsNSView()
        graph.configure(
            commits: model.recentCommits,
            expandedCommitIDs: Set(model.recentCommits.map(\.id)), fontScale: 1,
            hasMoreCommits: model.hasMoreRecentCommits, isLoadingMore: false
        )
        check(
            graph.subviews.count == expected.count
                + expected.reduce(0) { $0 + max(1, $1.files.count) },
            "Expanded native graph has every commit and file row"
        )
        check(graph.requiredHeight > 0, "Native graph measured height")
        let rename = model.recentCommits.first { $0.subject == "rename\u{1e}\u{1f}" }!
        graph.configure(
            commits: [rename], expandedCommitIDs: [rename.id], fontScale: 1,
            hasMoreCommits: false, isLoadingMore: false
        )
        var opened: (String, String, String?)?
        graph.onOpenDiff = { commit, file in opened = (commit.hash, file.path, file.originalPath) }
        check(graph.subviews.count == 2, "Renamed file is a native graph row")
        check(graph.subviews.last!.accessibilityPerformPress(), "Native file action")
        check(
            opened?.0 == rename.hash && opened?.1 == "R100\u{1f}renamed\n.txt"
                && opened?.2 == "before\u{1e}after.txt",
            "Diff action receives full rename paths"
        )
        check(model.detailError == nil && model.statusError == nil, "Refreshed status has no errors")
        print("Git history surfaces: \(checks) passed, 0 failed; 35 commits, pagination, signed diagnostics, native graph and rename action")
    }
}
