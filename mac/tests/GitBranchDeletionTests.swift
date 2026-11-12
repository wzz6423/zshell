import AppKit
import Foundation
@testable import zshell

@main @MainActor
struct GitBranchDeletionTests {
    private static var checks = 0

    private static func check(_ condition: Bool, _ name: String) {
        checks += 1
        print("\(condition ? "PASS" : "FAIL") \(name)")
        precondition(condition, name)
    }

    private static func wait(_ name: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        precondition(condition(), name)
    }

    private static func git(_ repo: URL, _ args: String...) -> String {
        let result = GitStatusModel.runGit(args, in: repo.path)
        precondition(result.status == 0, result.stderr)
        return result.stdout.trimmingCharacters(in: .newlines)
    }

    private static func write(_ repo: URL, _ path: String, _ text: String) {
        try! text.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private static func repository(_ root: URL, _ name: String) -> URL {
        let repo = root.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = git(repo, "init", "-q", "--initial-branch=main")
        _ = git(repo, "config", "user.name", "Branch Deletion Fixture")
        _ = git(repo, "config", "user.email", "fixture@example.invalid")
        _ = git(repo, "config", "commit.gpgsign", "false")
        _ = git(repo, "config", "core.hooksPath", "/dev/null")
        write(repo, "tracked.txt", "base\n")
        _ = git(repo, "add", ".")
        _ = git(repo, "commit", "-qm", "base")
        return repo
    }

    private static func model(_ repo: URL) -> GitStatusModel {
        let model = GitStatusModel()
        model.sync(root: repo.path)
        wait("repository status loads") { model.hasResolvedStatus && !model.isRefreshing && model.isRepo }
        return model
    }

    private static func refresh(_ model: GitStatusModel) {
        model.refresh()
        wait("repository status refreshes") { !model.isRefreshing }
    }

    private static func delete(_ branch: String, using model: GitStatusModel, succeeds: Bool = true) {
        var result: Bool?
        model.deleteBranch(named: branch) { result = $0 }
        wait("branch deletion completes") { result != nil && !model.isBusy && !model.isRefreshing }
        check(result == succeeds, "\(branch) deletion \(succeeds ? "succeeds" : "is refused")")
    }

    private static func backups(_ repo: URL) -> [String] {
        git(repo, "for-each-ref", "--format=%(refname)", "refs/zshell/deleted-branches/")
            .split(separator: "\n").map(String.init)
    }

    private static func unmergedAndRepeatedDeletion(_ root: URL) {
        let repo = repository(root, "unmerged")
        let branch = "backup/未合并'分支"
        _ = git(repo, "switch", "-qc", branch)
        _ = git(repo, "commit", "--allow-empty", "-qm", "unmerged")
        let firstTip = git(repo, "rev-parse", "HEAD")
        _ = git(repo, "switch", "-q", "main")
        let original = GitStatusModel.runGit(["branch", "-d", branch], in: repo.path)
        check(original.status != 0 && original.stderr.contains("not fully merged"), "fixture reproduces the original Git error")
        let model = model(repo)
        delete(branch, using: model)
        check(!model.branches.contains(branch) && model.branch == "main", "the unmerged branch disappears without switching the checkout")
        check(model.stashCount == 0, "a clean checkout needs no stash")
        let firstBackup = backups(repo).first!
        check(git(repo, "rev-parse", firstBackup) == firstTip, "the deleted branch's unique commit remains reachable")
        check(model.operation!.output.contains("refs/zshell/deleted-branches/"), "the operation transcript exposes the recovery ref")
        _ = git(repo, "branch", "restored", firstBackup)
        check(git(repo, "rev-parse", "restored") == firstTip, "the documented command restores the deleted branch")
        _ = git(repo, "switch", "-qc", branch)
        _ = git(repo, "commit", "--allow-empty", "-qm", "replacement")
        let secondTip = git(repo, "rev-parse", "HEAD")
        _ = git(repo, "switch", "-q", "main")
        refresh(model)
        delete(branch, using: model)
        let saved = backups(repo)
        check(saved.count == 2 && Set(saved).count == 2, "repeated deletion creates independent recovery refs")
        check(git(repo, "rev-parse", firstBackup) == firstTip
              && git(repo, "rev-parse", saved.first { $0 != firstBackup }!) == secondTip,
              "reusing a branch name never overwrites an earlier backup")
        check(!model.branches.contains { $0.hasPrefix("refs/zshell/") }, "recovery refs do not become visible branches")
        _ = git(repo, "gc", "--prune=now")
        check(git(repo, "rev-parse", firstBackup + "^{commit}") == firstTip, "recovery survives Git garbage collection")
        _ = git(repo, "branch", "merged")
        refresh(model)
        delete("merged", using: model)
        check(!model.branches.contains("merged"), "merged branches still delete successfully")
    }

    private static func dirtyAndCurrentDeletion(_ root: URL) {
        for current in [false, true] {
            let repo = repository(root, current ? "current" : "dirty")
            _ = git(repo, "switch", "-qc", "feature")
            _ = git(repo, "commit", "--allow-empty", "-qm", "feature")
            let tip = git(repo, "rev-parse", "HEAD")
            _ = git(repo, "tag", "main")
            _ = git(repo, "tag", "feature")
            if !current { _ = git(repo, "switch", "-q", "main") }
            write(repo, "tracked.txt", "staged\n")
            _ = git(repo, "add", "tracked.txt")
            write(repo, "tracked.txt", "unstaged\n")
            write(repo, "untracked.txt", "untracked\n")
            let model = model(repo)
            delete("feature", using: model)
            check(model.stashCount == 1 && model.totalChangeCount == 0, "local staged, unstaged, and untracked work is saved")
            check(git(repo, "show", "stash@{0}:tracked.txt") == "unstaged"
                  && git(repo, "show", "stash@{0}^2:tracked.txt") == "staged"
                  && git(repo, "show", "stash@{0}^3:untracked.txt") == "untracked",
                  "the stash preserves all three kinds of local content")
            check(git(repo, "rev-parse", backups(repo).first!) == tip, "the branch tip is preserved independently of the stash")
            check(git(repo, "rev-parse", "refs/tags/feature") == tip, "deletion preserves a same-named tag")
            check(model.branch == (current ? "detached HEAD" : "main"), "current-branch deletion detaches; other-branch deletion stays on main")
            if current { check(git(repo, "rev-parse", "HEAD") == tip, "detaching keeps the deleted current branch's commit") }
            _ = git(repo, "stash", "apply", "--index", "stash@{0}")
            check(git(repo, "show", ":tracked.txt") == "staged"
                  && (try! String(contentsOf: repo.appendingPathComponent("tracked.txt"), encoding: .utf8)) == "unstaged\n"
                  && (try! String(contentsOf: repo.appendingPathComponent("untracked.txt"), encoding: .utf8)) == "untracked\n",
                  "the documented stash restore preserves content and staging")
        }
    }

    private static func refusedDeletion(_ root: URL) {
        let repo = repository(root, "refused")
        let worktree = root.appendingPathComponent("protected-worktree")
        _ = git(repo, "worktree", "add", "-q", "-b", "protected", worktree.path)
        write(repo, "tracked.txt", "keep local work\n")
        let model = model(repo)
        delete("protected", using: model, succeeds: false)
        check(backups(repo).isEmpty && model.stashCount == 0 && model.totalChangeCount == 1,
              "a branch in another worktree is rejected before any snapshot or stash")
        check(git(repo, "branch", "--show-current") == "main"
              && git(worktree, "branch", "--show-current") == "protected", "both checked-out branches remain intact")
        _ = git(repo, "branch", "stale")
        refresh(model)
        _ = git(repo, "branch", "-D", "stale")
        delete("stale", using: model, succeeds: false)
        check(backups(repo).isEmpty && model.stashCount == 0 && model.totalChangeCount == 1,
              "a vanished target fails before changing the working tree")
        _ = git(repo, "branch", "backup-failure")
        refresh(model)
        write(repo, ".git/refs/zshell", "block recovery ref creation\n")
        delete("backup-failure", using: model, succeeds: false)
        check(model.branches.contains("backup-failure") && model.stashCount == 0 && model.totalChangeCount == 1,
              "backup failure preserves the branch and local work")

        let conflict = repository(root, "stash-failure")
        _ = git(conflict, "switch", "-qc", "feature")
        write(conflict, "tracked.txt", "feature\n")
        _ = git(conflict, "commit", "-qam", "feature")
        _ = git(conflict, "switch", "-q", "main")
        write(conflict, "tracked.txt", "main\n")
        _ = git(conflict, "commit", "-qam", "main")
        check(GitStatusModel.runGit(["merge", "feature"], in: conflict.path).status != 0, "fixture creates a real conflicted index")
        let status = git(conflict, "status", "--porcelain")
        let conflictingModel = Self.model(conflict)
        delete("feature", using: conflictingModel, succeeds: false)
        check(conflictingModel.branches.contains("feature") && conflictingModel.branch == "main"
              && git(conflict, "status", "--porcelain") == status,
              "stash failure stops deletion and preserves the conflicted checkout")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func confirmation(_ root: URL) {
        let repo = repository(root, "confirmation")
        _ = git(repo, "switch", "-qc", "confirm-me")
        _ = git(repo, "commit", "--allow-empty", "-qm", "unmerged")
        _ = git(repo, "switch", "-q", "main")
        let model = model(repo)
        let panel = GitPanelNSView(frame: NSRect(x: 0, y: 0, width: 360, height: 800))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 360, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("main-branch-deletion-test")
        window.contentView = panel
        panel.configure(model: model, session: nil, isRemote: false, fontScale: 1,
                        openFile: { _ in }, openToSide: { _ in }, openDiff: { _, _ in },
                        openCommitDiff: { _, _ in }, openWorktree: { _ in })
        panel.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        let table = descendants(panel).compactMap { $0 as? NSTableView }.first { table in
            guard table.numberOfRows > 0, let row = table.view(atColumn: 0, row: 0, makeIfNecessary: true) else { return false }
            return descendants(row).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "confirm-me" }
        }!
        let button = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSButton
        let item = button.menu!.item(withTitle: String(localized: "Delete Branch…"))!
        func request() { NSApplication.shared.sendAction(item.action!, to: item.target, from: item) }
        request()
        wait("native deletion confirmation appears") { window.attachedSheet != nil }
        check(model.operation == nil && backups(repo).isEmpty, "opening confirmation never mutates Git")
        window.endSheet(window.attachedSheet!, returnCode: .alertSecondButtonReturn)
        wait("cancel closes the confirmation") { window.attachedSheet == nil }
        check(model.branches.contains("confirm-me") && backups(repo).isEmpty, "cancelling leaves the branch intact")
        request()
        wait("native confirmation reopens") { window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        let controls = descendants(sheet.contentView!).compactMap { $0 as? NSButton }
        let confirm = controls.first { $0.title == String(localized: "Delete Branch") }!
        confirm.performClick(nil)
        wait("confirmed deletion finishes") { model.operation?.isSuccess == true && !model.isRefreshing }
        check(!model.branches.contains("confirm-me") && backups(repo).count == 1,
              "the native branch menu and confirmation execute the real deletion")
        panel.detach()
        window.close()
    }

    static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppSettings.shared.showPullRequestStatus = false
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        unmergedAndRepeatedDeletion(root)
        dirtyAndCurrentDeletion(root)
        refusedDeletion(root)
        confirmation(root)
        print("Git branch deletion: \(checks) passed, 0 failed")
    }
}
