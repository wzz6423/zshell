"""Exercise available-branch filtering and the native repository list actions.

Run: python3 -B mac/tests/test_git_branch_list.py
The AppKit fixture stays offscreen and uses no repository mutations.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
model = (ROOT / "mac/zshell/GitStatusModel.swift").read_text()
start = model.index("    var branchesWithoutWorktrees: [String] {")
available = model[start:model.index("\n    }", start) + len("\n    }")]
fixture = r'''
enum Theme { static let accent = NSColor.systemBlue }
struct AppSettings {
    static let sidebarFontSizeRange = 9.0...24.0
    static let defaultSidebarFontSize = 14.0
    static let interfaceScaleRange = 0.9...1.5
}
struct GitStatusModel {
    struct Worktree: Equatable {
        let path: String
        let headOID: String?
        let branch: String?
        let isBare: Bool
        let isCurrent: Bool
    }
    var branches: [String]
    var worktrees: [Worktree]
    AVAILABLE
}
@main struct GitBranchListRegression {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let model = GitStatusModel(
            branches: ["feature/available", "main", "test1", "test2"],
            worktrees: [
                .init(path: "/fixture/main", headOID: nil, branch: "main", isBare: false, isCurrent: false),
                .init(path: "/fixture/current", headOID: nil, branch: "test2", isBare: false, isCurrent: true),
                .init(path: "/fixture/detached", headOID: nil, branch: nil, isBare: false, isCurrent: false),
            ]
        )
        check(model.branchesWithoutWorktrees == ["feature/available", "test1"],
              "the available list excludes branches checked out by any worktree")
        let view = GitRepositorySectionNSView(frame: NSRect(x: 0, y: 0, width: 180, height: 240))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        var switched: [String] = []
        var createdWorktrees: [String] = []
        var deleted: [String] = []
        var createRequests = 0
        var collapseRequests = 0
        func apply(_ branches: [String], collapsed: Bool = false, busy: Bool = false, repository: String = "first") {
            view.apply(branches: branches, isCollapsed: collapsed, fontScale: 1,
                repositoryID: repository, isBusy: busy, switchBranch: { switched.append($0) },
                createBranch: { createRequests += 1 }, createWorktree: { createdWorktrees.append($0) },
                deleteBranch: { deleted.append($0) }, toggleCollapsed: { collapseRequests += 1 })
            view.layoutSubtreeIfNeeded()
        }
        apply(model.branchesWithoutWorktrees)
        let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
        let table = scroll.documentView as! NSTableView
        func row(_ index: Int) -> NSButton {
            table.layoutSubtreeIfNeeded()
            return table.view(atColumn: 0, row: index, makeIfNecessary: true) as! NSButton
        }
        let controls = view.subviews.compactMap { $0 as? NSButton }
        let header = controls.first { !$0.title.isEmpty }!
        let add = controls.first { $0.title.isEmpty }!
        let count = view.subviews.compactMap { $0 as? NSTextField }.first!
        check(table.numberOfRows == 2 && count.stringValue == "2", "all available branches are counted and rendered")
        check(header.title == String(localized: "Branches"), "the native section has its own branch heading")
        check(count.frame.width >= ceil(count.fittingSize.width) && !count.frame.intersects(add.frame),
              "branch count fits without overlapping the create control")
        check(add.image != nil && add.imagePosition != .noImage,
              "the branch-create control renders its icon")
        let labels = row(0).subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        check(labels.count == 1 && labels[0].stringValue == "feature/available",
              "branch rows show the real branch name without a fabricated checkout path")
        row(0).performClick(nil)
        check(switched == ["feature/available"], "clicking a branch switches that exact branch once")
        let menu = row(1).menu!
        menu.update()
        check(menu.items.count == 2 && menu.items.allSatisfy(\.isEnabled), "available branches expose enabled worktree and delete actions")
        for item in menu.items { NSApplication.shared.sendAction(item.action!, to: item.target, from: item) }
        check(createdWorktrees == ["test1"] && deleted == ["test1"], "context actions keep the selected branch identity")
        add.performClick(nil)
        header.performClick(nil)
        check(createRequests == 1 && collapseRequests == 1, "section controls create a branch and toggle this section")
        apply(model.branchesWithoutWorktrees, busy: true)
        let disabled = row(0)
        let before = switched.count
        disabled.performClick(nil)
        disabled.menu!.update()
        for item in disabled.menu!.items { NSApplication.shared.sendAction(item.action!, to: item.target, from: item) }
        check(!disabled.isEnabled && switched.count == before, "a busy operation cannot switch branches twice")
        check(!add.isEnabled && disabled.menu!.items.allSatisfy { !$0.isEnabled }, "busy branch actions stay disabled after native menu validation")
        check(createdWorktrees == ["test1"] && deleted == ["test1"], "busy context actions cannot mutate the previous target")
        let many = (0..<30).map { "feature/\($0)" }
        apply(many)
        check(table.frame.height > scroll.contentSize.height && scroll.frame.height <= 160,
              "long branch lists use their own bounded scroll viewport")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.bounds.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        apply(["only-match"])
        check(table.numberOfRows == 1 && scroll.contentView.bounds.minY == 0,
              "searching from the bottom does not leave the matching branch outside the viewport")
        row(0).performClick(nil)
        check(switched.last == "only-match", "reused rows activate the refreshed branch")
        apply(many)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        apply(many, repository: "second")
        check(scroll.contentView.bounds.minY == 0, "switching repositories resets the branch scroll position")
        apply(many, collapsed: true)
        check(scroll.isHidden && view.intrinsicContentSize.height == GitRepositorySectionMetrics(fontScale: 1).headerHeight,
              "collapsing branches keeps the section header and count")
        apply([])
        check(table.numberOfRows == 0 && view.intrinsicContentSize.height == 0,
              "empty results cannot retain a previous branch row")
        window.close()
        var presentedFrom: NSWindow?
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: GitBranchesSectionView(
            branches: ["feature/available"], isCollapsed: .constant(false), fontScale: 1,
            repositoryID: "background", isBusy: false, switchBranch: { _ in },
            createBranch: { presentedFrom = $0 }, createWorktree: { _ in }, deleteBranch: { _ in }
        ))
        owner.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let section = descendants(host).compactMap { $0 as? GitRepositorySectionNSView }.first!
        section.subviews.compactMap { $0 as? NSButton }.first { $0.title.isEmpty }!.performClick(nil)
        check(presentedFrom === owner, "the create action keeps its owning window even without a key window")
        owner.close()
        print("Git branch list regression: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
'''.replace("AVAILABLE", available)

with tempfile.TemporaryDirectory(prefix="zshell-git-branches-") as directory:
    helper = Path(directory) / "BranchListRegression.swift"
    helper.write_text((ROOT / "mac/zshell/AppKitWorktreeSectionView.swift").read_text()
                      + (ROOT / "mac/zshell/RowButtonTableView.swift").read_text()
                      + (ROOT / "mac/zshell/SidebarLayoutMetrics.swift").read_text()
                      + fixture)
    binary = Path(directory) / "branch-list-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(helper), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
