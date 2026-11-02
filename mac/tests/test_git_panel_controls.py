"""Exercise the native Git page, including long-list scrolling and file actions.

Run: python3 mac/tests/test_git_panel_controls.py
All probe binaries and module caches live in a temporary directory.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text()


model = source("mac/zshell/GitStatusModel.swift")
types = model[model.index("    nonisolated struct Entry:"):model.index("    @Published private(set) var rootPath")]
review = source("mac/zshell/DiffReview.swift")
review_types = review[review.index("enum DiffReviewLayer:"):review.index("enum DiffReviewFingerprint")]
indicator = review[review.index("@MainActor\nfinal class DiffReviewIndicatorButton"):
                   review.index("/// Native summary")]
summary = review[review.index("final class DiffReviewSummaryNSView:"):]
chrome = source("mac/zshell/WorkspaceChromeViews.swift")
chrome = chrome[chrome.index("final class WorkspaceChromeButton:"):chrome.index("final class WorkspaceWindowDragView:")]
# The command-shortcut overload is unrelated to the Git panel fixture.
start = chrome.index("    func configure(symbol: String, command:")
end = chrome.index("    override func updateTrackingAreas", start)
chrome = chrome[:start] + chrome[end:]

support = r'''
import AppKit
import Combine
import CryptoKit
import SwiftUI
final class FixtureChanges: ObservableObject {}
enum Theme {
    static let accent = NSColor.systemBlue
    static let changes = FixtureChanges()
}
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let sidebarFontSizeRange = 9.0...24.0
    static let defaultSidebarFontSize = 14.0
    static let interfaceScaleRange = 0.9...1.5
    @Published var showPullRequestStatus = true
}
enum AppLocalization {
    static let didChange = Notification.Name("fixture-language")
    static let current = Locale(identifier: "en")
}
enum DiffReviewState { case reviewed, unreviewed }
final class DiffReviewStore: ObservableObject {
    static let shared = DiffReviewStore()
    @Published var revision = 0
    var reviewed: Set<DiffReviewSnapshot> = []
    func isReviewed(_ value: DiffReviewSnapshot) -> Bool { reviewed.contains(value) }
    func reviewedCount(in values: [DiffReviewSnapshot]) -> Int { values.filter(isReviewed).count }
    func setReviewed(_ value: Bool, for snapshot: DiffReviewSnapshot) {
        if value { reviewed.insert(snapshot) } else { reviewed.remove(snapshot) }
        revision += 1
    }
}
enum AgentReviewWindowController { static func show(repositoryRoot: String) {} }
enum MaterialFileIcon {
    static func image(forPath: String, appearance: NSAppearance? = nil) -> NSImage { NSImage(size: NSSize(width: 13, height: 13)) }
}
final class TerminalSession {
    var commands: [String] = []
    func sendCommand(_ command: String) { commands.append(command) }
}
enum AppWindowPresentation {
    static func hostWindow(relativeTo window: NSWindow? = nil) -> NSWindow? { window ?? NSApp.windows.first }
}
final class ProjectPullRequestModel: ObservableObject {
    enum State: Equatable {
        case hidden, loading, pullRequest, failed, none
        var label: String { "PR fixture" }
        var help: String { "Pull request" }
    }
    @Published var state: State = .hidden
    static var queriedDirectories: [String] = []
    static var detachCount = 0
    func sync(directory: String?) {
        guard let directory else { state = .hidden; return }
        if state != .none { state = .none }
        Self.queriedDirectories.append(directory)
    }
    func refresh() {}
    func detach() { state = .hidden; Self.detachCount += 1 }
    func open(_ action: (URL) -> Void) {}
}
@MainActor final class GitStatusModel: ObservableObject {
    MODEL_TYPES
    @Published var rootPath = "/fixture/repo"
    @Published var repositoryIdentity = "/fixture/repo"
    @Published var isRepo = true
    @Published var branch: String? = "main"
    @Published var headOID: String? = "head"
    @Published var upstream: String? = "origin/main"
    @Published var ahead = 0
    @Published var behind = 0
    @Published var hasUpstream = true
    @Published var mergeEntries: [Entry] = []
    @Published var stagedEntries: [Entry] = []
    @Published var changedEntries: [Entry] = []
    @Published var branches: [String] = []
    @Published var worktrees: [Worktree] = []
    @Published var remotes: [String] = ["origin"]
    @Published var recentCommits: [RecentCommit] = []
    @Published var hasMoreRecentCommits = false
    @Published var isLoadingMoreCommits = false
    @Published var repositoryOperation: String?
    @Published var stashCount = 0
    @Published var isResolvingInitialStatus = false
    @Published var statusError: String?
    @Published var isBusy = false
    @Published var operation: Operation?
    var lastError: String?
    var calls: [String] = []
    var loadMoreCount = 0
    var commitCompletion: ((Bool) -> Void)?
    var lastCommit: (message: String, includeAll: Bool, amend: Bool)?
    var branchesWithoutWorktrees: [String] { branches.filter { branch in !worktrees.contains { $0.branch == branch } } }
    var totalChangeCount: Int { mergeEntries.count + stagedEntries.count + changedEntries.count }
    var repoRoot: String { repositoryIdentity }
    func absolutePath(for entry: Entry) -> String { (repoRoot as NSString).appendingPathComponent(entry.path) }
    func isCurrent(_ entry: Entry) -> Bool { entry.repositoryRoot.isEmpty || entry.repositoryRoot == repoRoot }
    func refresh() { calls.append("refresh") }
    func loadMoreCommits() -> Bool { loadMoreCount += 1; return true }
    func dismissOperation() { operation = nil }
    func stage(_ entry: Entry) { calls.append("stage:" + entry.path) }
    func unstage(_ entry: Entry) { calls.append("unstage:" + entry.path) }
    func stageAll() { calls.append("stageAll") }
    func unstageAll() { calls.append("unstageAll") }
    func discard(_ entry: Entry) { calls.append("discard:" + entry.path) }
    func discardChanges(_ entries: [Entry]) { calls.append("discardAll") }
    func cancelStaleDiscard() { calls.append("staleDiscard") }
    func commit(message: String, includeAll: Bool, amend: Bool = false, completion: ((Bool) -> Void)? = nil) {
        lastCommit = (message, includeAll, amend)
        calls.append("commit:" + message); commitCompletion = completion; isBusy = true
    }
    func fetch() { calls.append("fetch") }
    func pull() { calls.append("pull") }
    func push() { calls.append("push") }
    func publish(to remote: String) { calls.append("publish:" + remote) }
    func syncChanges() { calls.append("sync") }
    func switchBranch(to branch: String) { calls.append("switch:" + branch) }
    func createBranch(named branch: String) { calls.append("branch:" + branch) }
    func createWorktree(at path: String, forBranch branch: String) { calls.append("worktree:" + branch) }
    func removeWorktree(_ tree: Worktree) { calls.append("removeWorktree") }
    func deleteBranch(named branch: String) { calls.append("delete:" + branch) }
    func stash(includeUntracked: Bool) { calls.append("stash") }
    func stashPop() { calls.append("stashPop") }
    func initializeRepository() { calls.append("init") }
}
'''
probe = r'''
import AppKit
@main struct GitPanelRegression {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL " + name) }
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func pump(_ panel: NSView) {
            panel.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
            panel.layoutSubtreeIfNeeded()
        }
        let model = GitStatusModel()
        model.branches = (0..<128).map { "feature/\($0)" }
        model.worktrees = (0..<128).map {
            GitStatusModel.Worktree(path: "/fixture/worktree/\($0)", headOID: nil, branch: "tree/\($0)", isBare: false, isCurrent: $0 == 0)
        }
        model.changedEntries = (0..<2000).map {
            GitStatusModel.Entry(path: "src/file-\($0).swift", staged: ".", unstaged: "M", worktreeReviewFingerprint: "worktree-\($0)", repositoryRoot: model.repoRoot)
        }
        model.stagedEntries = [GitStatusModel.Entry(path: "staged.swift", staged: "M", unstaged: ".", repositoryRoot: model.repoRoot)]
        let session = TerminalSession()
        var diffs: [(GitStatusModel.Entry, Bool)] = []
        let panel = GitPanelNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 500))
        let window = NSWindow(contentRect: panel.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        window.orderFront(nil)
        func configure(scale: CGFloat = 1, remote: Bool = false) {
            panel.configure(model: model, session: session, isRemote: remote, fontScale: scale,
                openFile: { _ in }, openToSide: { _ in }, openDiff: { diffs.append(($0, $1)) },
                openCommitDiff: { _, _ in }, openWorktree: { _ in })
            pump(panel)
        }
        configure()
        let scrolls = descendants(panel).compactMap { $0 as? NSScrollView }
        check(scrolls.count == 1, "one native scroll view owns the complete Git page")
        let scroll = scrolls[0]
        let tables = descendants(panel).compactMap { $0 as? NSTableView }
        let changeTable = tables.first { $0.numberOfRows == 2000 }!
        check(tables.count == 5, "native branch, worktree and three change lists are mounted")
        let branchTable = tables.first { $0.numberOfRows == 128 }!
        check(branchTable.enclosingScrollView === scroll, "branch rows share page scrolling")
        check(branchTable.bounds.height >= CGFloat(128) * branchTable.rowHeight, "long branch list keeps its complete page height")
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -160, wheel2: 0, wheel3: 0)!
        branchTable.scrollWheel(with: NSEvent(cgEvent: cg)!)
        pump(panel)
        check(scroll.contentView.bounds.minY > 0, "wheel over branches scrolls the complete page")
        let fields = descendants(panel).compactMap { $0 as? GitPanelSearchField }
        let branchSearch = fields.first { $0.placeholderString == String(localized: "Search worktrees or branches") }!
        let fileFilter = fields.first { $0.placeholderString == String(localized: "Filter changed files") }!
        check(fields.count == 2 && fileFilter.sendsSearchStringImmediately, "both native searches are available with immediate edits")
        branchSearch.stringValue = "feature/127"
        branchSearch.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: branchSearch))
        pump(panel)
        check(branchTable.numberOfRows == 1, "branch search filters existing native rows")
        branchSearch.stringValue = ""
        branchSearch.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: branchSearch))
        fileFilter.stringValue = "file-1999"
        fileFilter.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fileFilter))
        pump(panel)
        check(changeTable.numberOfRows == 1, "file search filters the native change list")
        let row = changeTable.view(atColumn: 0, row: 0, makeIfNecessary: true)!
        let stageButton = descendants(row).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == String(localized: "Stage Changes") }!
        stageButton.performClick(nil)
        check(model.calls.last == "stage:src/file-1999.swift", "native row action stages the selected path")
        let diffButton = descendants(row).compactMap { $0 as? NSButton }.first { $0.toolTip?.hasSuffix("file-1999.swift") == true }!
        let fileLabel = diffButton.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "file-1999.swift" }!
        row.layoutSubtreeIfNeeded()
        let labelHit = diffButton.hitTest(fileLabel.convert(NSPoint(x: 2, y: 2), to: diffButton.superview))
        check(labelHit === diffButton, "file name clicks hit the native diff button")
        diffButton.performClick(nil)
        check(diffs.last?.0.path == "src/file-1999.swift" && diffs.last?.1 == false, "native row opens its worktree diff")
        check(changeTable.selectedRow == 0, "opening a file row preserves native selection")
        check(changeTable.validateProposedFirstResponder(stageButton, for: NSEvent.mouseEvent(with: .leftMouseDown,
            location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)), "table lets embedded action buttons receive native clicks")
        let menu = row.menu!
        check(menu.items.contains { $0.title == String(localized: "Open File to the Side") } &&
              menu.items.contains { $0.title == String(localized: "Copy Relative Path") }, "file context menu retains side-open and path actions")
        fileFilter.stringValue = ""
        fileFilter.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fileFilter))
        pump(panel)
        check(changeTable.numberOfRows == 2000, "clearing the file filter restores every changed path")
        let tableRect = changeTable.convert(changeTable.bounds, to: scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: tableRect.minY + 800))
        scroll.reflectScrolledClipView(scroll.contentView)
        pump(panel)
        let visibleCells = descendants(changeTable).filter { $0.identifier?.rawValue == "gitChangeRow" }
        check(visibleCells.count < 150, "long file lists instantiate only a bounded number of native cells")
        for scale in [0.9, 1.0, 1.5, 2.0, 24.0 / 14.0 * 1.5] {
            for width in [162.0, 180.0, 240.0, 500.0] {
                window.setContentSize(NSSize(width: width, height: 500))
                configure(scale: scale)
                for section in descendants(panel).compactMap({ $0 as? GitRepositorySectionNSView }) where !section.isHidden {
                    let label = section.subviews.compactMap { $0 as? NSTextField }.first!
                    let add = section.subviews.compactMap { $0 as? NSButton }.first { $0.title.isEmpty }!
                    check(label.frame.width >= ceil(label.cell!.cellSize.width) && label.frame.height >= ceil(label.cell!.cellSize.height), "repository count fits at \(scale), \(width)")
                    check(section.bounds.contains(label.frame) && !label.frame.intersects(add.frame), "repository count and add never overlap")
                }
                for heading in descendants(panel).compactMap({ $0 as? GitPanelSectionHeaderView }) where !heading.isHidden {
                    let label = heading.subviews.compactMap { $0 as? NSTextField }.first!
                    check(heading.bounds.contains(label.frame), "change count stays inside narrow panels")
                }
            }
        }
        let queryCount = ProjectPullRequestModel.queriedDirectories.count
        AppSettings.shared.showPullRequestStatus = false
        pump(panel)
        check(ProjectPullRequestModel.detachCount > 0, "disabling PR status detaches its lookup")
        check(ProjectPullRequestModel.queriedDirectories.count == queryCount, "disabled PR status schedules no new lookup")
        AppSettings.shared.showPullRequestStatus = true
        configure(remote: true)
        check(descendants(panel).compactMap { $0 as? GitRepositorySectionNSView }.allSatisfy(\.isHidden), "remote Git hides branch and worktree controls")
        check(descendants(changeTable).compactMap { $0 as? NSButton }.allSatisfy { $0.accessibilityLabel() != String(localized: "Stage Changes") || $0.isHidden }, "remote Git hides local write actions")
        check(ProjectPullRequestModel.queriedDirectories.count == queryCount, "remote Git does not request local PR status")
        let remoteRow = changeTable.view(atColumn: 0, row: 0, makeIfNecessary: true)!
        let remoteInsert = remoteRow.menu!.items.first { $0.title == String(localized: "Insert Absolute Path in Terminal") }!
        check(remoteInsert.isEnabled, "remote file paths can be inserted into their terminal")
        NSApp.sendAction(remoteInsert.action!, to: remoteInsert.target, from: remoteInsert)
        check(session.commands.last == "'/fixture/repo/src/file-0.swift' ", "remote path insertion reaches the existing terminal session")
        let insertionCount = session.commands.count
        model.repositoryIdentity = "/fixture/switched"
        pump(panel)
        NSApp.sendAction(remoteInsert.action!, to: remoteInsert.target, from: remoteInsert)
        check(session.commands.count == insertionCount, "an old remote path menu cannot insert into a different repository")
        model.repositoryIdentity = "/fixture/repo"
        configure()
        window.setContentSize(NSSize(width: 240, height: 500))
        func clickMenuItem(_ item: NSMenuItem) {
            if let action = item.action, let target = item.target {
                NSApp.sendAction(action, to: target, from: item)
            }
        }
        let unstageRow = tables.first { $0.numberOfRows == 1 && $0 !== branchTable && $0 !== changeTable }!
            .view(atColumn: 0, row: 0, makeIfNecessary: true)!
        let unstage = descendants(unstageRow).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == String(localized: "Unstage Changes") }!
        unstage.performClick(nil)
        check(model.calls.last == "unstage:staged.swift", "native staged row retains unstage callback")
        model.branches = []
        model.worktrees = []
        model.changedEntries = [GitStatusModel.Entry(path: "rename-destination.swift", staged: "R", unstaged: "M", origPath: "rename-original.swift", repositoryRoot: model.repoRoot)]
        pump(panel)
        let renameRow = changeTable.view(atColumn: 0, row: 0, makeIfNecessary: true)!
        let renameButton = descendants(renameRow).compactMap { $0 as? NSButton }.first { $0.toolTip?.hasSuffix("rename-destination.swift") == true }!
        renameButton.performClick(nil)
        check(diffs.last?.0.origPath == nil, "staged rename worktree diff compares the destination path")
        let commitText = descendants(panel).compactMap { $0 as? NSTextView }.first { $0.isEditable }!
        let commitRect = commitText.convert(commitText.bounds, to: scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, commitRect.minY - 40)))
        scroll.reflectScrolledClipView(scroll.contentView)
        pump(panel)
        let commitHit = panel.hitTest(commitText.convert(NSPoint(x: 4, y: 4), to: panel.superview))
        check(commitHit === commitText, "empty commit placeholder lets clicks focus its native text editor")
        func editCommit(_ text: String) {
            commitText.string = text
            commitText.didChangeText()
            pump(panel)
        }
        editCommit("first draft")
        let commandReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\\r", charactersIgnoringModifiers: "\\r", isARepeat: false, keyCode: 36)!
        commitText.keyDown(with: commandReturn)
        check(model.lastCommit?.message == "first draft" && model.lastCommit?.includeAll == false && model.lastCommit?.amend == false,
              "command-return commits staged changes without implicit stage-all")
        editCommit("next draft")
        let firstCompletion = model.commitCompletion
        model.isBusy = false
        firstCompletion?(true)
        pump(panel)
        check(commitText.string == "next draft", "completed commit preserves a subsequently edited draft")
        commitText.keyDown(with: commandReturn)
        model.isBusy = false
        model.commitCompletion?(true)
        pump(panel)
        check(commitText.string.isEmpty, "successful commit clears its unchanged draft")
        model.recentCommits = [GitStatusModel.RecentCommit(hash: "commit", shortHash: "commit", subject: "fixture", author: "Test", date: Date(), parentHash: nil, references: [], files: [])]
        pump(panel)
        editCommit("amend draft")
        let nativeCommitMenu = panel.makeCommitMenu()
        clickMenuItem(nativeCommitMenu.items.first { $0.title == String(localized: "Amend Last Commit") }!)
        check(model.lastCommit?.amend == true && model.lastCommit?.includeAll == false, "amend keeps stage-all explicit")
        model.isBusy = false
        pump(panel)
        clickMenuItem(panel.makeCommitMenu().items.first { $0.title == String(localized: "Stage All & Amend") }!)
        check(model.lastCommit?.amend == true && model.lastCommit?.includeAll == true, "stage-all amend retains its explicit scope")
        model.isBusy = false
        model.stagedEntries = []
        model.changedEntries = []
        model.ahead = 2
        pump(panel)
        let sync = descendants(panel).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == String(localized: "Pull remote commits, then push local ones") }!
        sync.performClick(nil)
        check(model.calls.last == "sync", "clean outgoing branch retains sync action")
        model.ahead = 0
        let temporaryRoot = URL(fileURLWithPath: CommandLine.arguments[1])
        let discardFile = temporaryRoot.appendingPathComponent("discard.swift")
        try! "before".write(to: discardFile, atomically: true, encoding: .utf8)
        model.repositoryIdentity = temporaryRoot.path
        model.rootPath = temporaryRoot.path
        model.changedEntries = [GitStatusModel.Entry(path: "discard.swift", staged: ".", unstaged: "M", repositoryRoot: model.repoRoot)]
        pump(panel)
        func requestDiscard() {
            let row = changeTable.view(atColumn: 0, row: 0, makeIfNecessary: true)!
            clickMenuItem(row.menu!.items.first { $0.title == String(localized: "Discard Changes…") }!)
            pump(panel)
        }
        func acceptSheet() {
            let sheet = window.attachedSheet!
            let accept = descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Discard Changes") }!
            accept.performClick(nil)
            pump(panel)
        }
        requestDiscard()
        check(window.attachedSheet != nil, "discard presents a real native confirmation sheet")
        try! "edited during confirmation".write(to: discardFile, atomically: true, encoding: .utf8)
        acceptSheet()
        check(model.calls.last == "staleDiscard", "discard rejects file contents changed during confirmation")
        requestDiscard()
        model.headOID = "new-head"
        pump(panel)
        acceptSheet()
        check(model.calls.last == "staleDiscard", "discard rejects HEAD changes during confirmation")
        requestDiscard()
        acceptSheet()
        check(model.calls.last == "discard:discard.swift", "unchanged discard snapshot reaches the Git model")
        requestDiscard()
        model.rootPath = temporaryRoot.appendingPathComponent("subdirectory").path
        pump(panel)
        check(window.attachedSheet == nil, "directory changes dismiss an outstanding destructive confirmation")
        editCommit("repository draft")
        model.repositoryIdentity = "/fixture/final"
        model.rootPath = "/fixture/final"
        pump(panel)
        check(commitText.string.isEmpty, "repository switches clear the native commit draft")
        model.changedEntries = []
        model.hasMoreRecentCommits = true
        model.loadMoreCount = 0
        pump(panel)
        let history = descendants(panel).compactMap { $0 as? RecentCommitsNSView }.first!
        let historyRect = history.convert(history.bounds, to: scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: historyRect.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        pump(panel)
        check(model.loadMoreCount > 0, "shared page scroll still requests the next history page")
        fileFilter.stringValue = "never-matches"
        fileFilter.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fileFilter))
        pump(panel)
        model.repositoryIdentity = "/fixture/other"
        model.rootPath = "/fixture/other"
        pump(panel)
        check(fileFilter.stringValue.isEmpty && branchSearch.stringValue.isEmpty, "repository switches reset both search drafts")
        check(scroll.contentView.bounds.minY == 0, "repository switches reset complete page scrolling")
        panel.detach()
        window.close()
        print("Git panel native regression: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix="zshell-git-panel-controls-") as directory:
    temporary = Path(directory)
    support_file = temporary / "Support.swift"
    support_file.write_text(support.replace("MODEL_TYPES", types) + review_types + indicator + summary + chrome)
    probe_file = temporary / "Probe.swift"
    probe_file.write_text(source("mac/zshell/AppKitGitPanelView.swift") + probe)
    executable = temporary / "git-panel-controls-tests"
    files = ["AppKitWorktreeSectionView.swift", "AppKitGitFilterView.swift",
             "AppKitGitPullRequestView.swift", "RecentCommitsView.swift", "RowButtonTableView.swift", "SidebarLayoutMetrics.swift"]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
                    "-module-cache-path", str(temporary / "modules"), str(support_file), str(probe_file),
                    *[str(ROOT / "mac/zshell" / file) for file in files], "-o", str(executable)], check=True, cwd=ROOT)
    subprocess.run([str(executable), str(temporary)], check=True, cwd=ROOT, timeout=45)
