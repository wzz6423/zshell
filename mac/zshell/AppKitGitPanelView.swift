//
//  AppKitGitPanelView.swift
//  zshell
//

import AppKit
import Combine
import SwiftUI

struct GitPanelView: NSViewRepresentable {
    let model: GitStatusModel
    let session: TerminalSession?
    let isRemote: Bool
    let fontScale: CGFloat
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let openDiff: (GitStatusModel.Entry, Bool) -> Void
    let openCommitDiff: (GitStatusModel.RecentCommit, GitStatusModel.RecentCommit.FileChange) -> Void
    let openWorktree: (String) -> Void

    func makeNSView(context: Context) -> GitPanelNSView { GitPanelNSView() }

    func updateNSView(_ view: GitPanelNSView, context: Context) {
        view.configure(model: model, session: session, isRemote: isRemote, fontScale: fontScale,
                       openFile: openFile, openToSide: openToSide, openDiff: openDiff,
                       openCommitDiff: openCommitDiff, openWorktree: openWorktree)
    }

    static func dismantleNSView(_ view: GitPanelNSView, coordinator: ()) { view.detach() }
}

enum GitPanelEntryKind: Equatable { case merge, staged, unstaged }

final class GitPanelNSView: NSView {
    private enum EntryOperation: Equatable { case stage, unstage, discard }
    private enum OperationTrigger: Equatable {
        case branchMenu, moreMenu, primaryAction, commitMenu, syncButton
        case stageAll, unstageAll, discardAll, initializeRepository, worktree
        case entry(path: String, operation: EntryOperation)
    }
    private struct FileFingerprint: Equatable {
        let exists: Bool
        let size: UInt64
        let modificationDate: Date?
        let fileNumber: UInt64?
        let symbolicLinkDestination: String?
    }
    private struct PendingDiscard {
        let entry: GitStatusModel.Entry
        let fingerprints: [String: FileFingerprint]
        let branch: String?
        let headOID: String?
    }
    private struct PageItem {
        let view: NSView
        let inset: CGFloat
        let gap: CGFloat
        let height: (CGFloat) -> CGFloat
    }

    private let scrollView = NSScrollView()
    private let document = GitPanelDocumentView()
    private let header = GitPanelHeaderView()
    private let tracking = GitPanelTrackingView()
    private let pullRequest = GitPullRequestBarView()
    private let pullRequestContainer = GitPanelDocumentView()
    private let branchSearch = GitPanelSearchField()
    private let branches = GitRepositorySectionNSView()
    private let worktrees = GitRepositorySectionNSView()
    private let failure = GitPanelFailureView()
    private let repositoryOperation = GitPanelMessageView()
    private let repositoryState = GitPanelPlaceholderView()
    private let commitBox = GitPanelCommitView()
    private let reviewSummary = DiffReviewSummaryNSView()
    private let fileFilter = GitPanelSearchField()
    private let cleanState = GitPanelPlaceholderView()
    private let mergeHeader = GitPanelSectionHeaderView()
    private let stagedHeader = GitPanelSectionHeaderView()
    private let changesHeader = GitPanelSectionHeaderView()
    private let historyHeader = GitPanelSectionHeaderView()
    private let mergeList = GitPanelChangesView()
    private let stagedList = GitPanelChangesView()
    private let changesList = GitPanelChangesView()
    private let history = RecentCommitsNSView()
    private var pageItems: [PageItem] = []
    private var boundModel: GitStatusModel?
    private var model: GitStatusModel { boundModel! }
    private weak var session: TerminalSession?
    private var observations: [AnyCancellable] = []
    private var modelObservation: AnyCancellable?
    private var refreshScheduled = false
    private var metrics = SidebarLayoutMetrics(fontScale: 1)
    private var isRemote = false
    private var openFile: ((String) -> Void)?
    private var openToSide: ((String) -> Void)?
    private var openDiff: ((GitStatusModel.Entry, Bool) -> Void)?
    private var openCommitDiff: ((GitStatusModel.RecentCommit, GitStatusModel.RecentCommit.FileChange) -> Void)?
    private var openWorktree: ((String) -> Void)?
    private var repositoryIdentity: String?
    private var rootPath: String?
    private var commitMessage = ""
    private var filterText = ""
    private var worktreeBranchSearch = ""
    private var collapsed: Set<String> = []
    private var expandedCommitIDs: Set<String> = []
    private var operationExpanded = false
    private var operationTrigger: OperationTrigger?
    private var activeSheet: NSWindow?
    private var isPullRequestEnabled = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        addSubview(scrollView)
        pullRequestContainer.addSubview(pullRequest)
        for view in [header, tracking, pullRequestContainer, branchSearch, branches, worktrees,
                     failure, repositoryOperation, repositoryState, commitBox, reviewSummary,
                     fileFilter, cleanState, mergeHeader, stagedHeader, changesHeader,
                     historyHeader, mergeList, stagedList, changesList, history] {
            document.addSubview(view)
        }
        pullRequest.onHeightChanged = { [weak self] in self?.needsLayout = true }
        branchSearch.onChange = { [weak self] text in
            self?.worktreeBranchSearch = text
            self?.refresh()
        }
        fileFilter.onChange = { [weak self] text in
            self?.filterText = text
            self?.refresh()
        }
        commitBox.onChange = { [weak self] text in
            self?.commitMessage = text
            self?.refresh()
        }
        commitBox.onCommit = { [weak self] in self?.performCommit(includeAll: false, trigger: .primaryAction) }
        commitBox.onMenu = { [weak self] button in self?.showCommitMenu(relativeTo: button) }
        commitBox.onSync = { [weak self] in
            guard let self else { return }
            self.performOperation(.syncButton, self.model.syncChanges)
        }
        history.onToggleCommit = { [weak self] id in
            guard let self else { return }
            if self.expandedCommitIDs.contains(id) { self.expandedCommitIDs.remove(id) }
            else { self.expandedCommitIDs.insert(id) }
            self.refresh()
        }
        history.onLoadMore = { [weak self] in self?.boundModel?.loadMoreCommits() ?? false }
        history.onOpenDiff = { [weak self] commit, file in
            guard let self, !self.isRemote else { return }
            self.openCommitDiff?(commit, file)
        }
        for publisher in [AppSettings.shared.objectWillChange.eraseToAnyPublisher(),
                          Theme.changes.objectWillChange.eraseToAnyPublisher(),
                          DiffReviewStore.shared.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &observations)
        }
        NotificationCenter.default.publisher(for: AppLocalization.didChange)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observations)
        setAccessibilityElement(false)
        scrollView.setAccessibilityLabel(String(localized: "Git"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(model: GitStatusModel, session: TerminalSession?, isRemote: Bool, fontScale: CGFloat,
                   openFile: @escaping (String) -> Void, openToSide: @escaping (String) -> Void,
                   openDiff: @escaping (GitStatusModel.Entry, Bool) -> Void,
                   openCommitDiff: @escaping (GitStatusModel.RecentCommit, GitStatusModel.RecentCommit.FileChange) -> Void,
                   openWorktree: @escaping (String) -> Void) {
        if boundModel !== model {
            dismissSheet()
            boundModel = model
            repositoryIdentity = nil
            rootPath = nil
            resetRepositoryDrafts()
            modelObservation = model.objectWillChange.receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleRefresh() }
        }
        self.session = session
        self.isRemote = isRemote
        metrics = SidebarLayoutMetrics(fontScale: fontScale)
        self.openFile = openFile
        self.openToSide = openToSide
        self.openDiff = openDiff
        self.openCommitDiff = openCommitDiff
        self.openWorktree = openWorktree
        refresh()
    }

    func detach() {
        dismissSheet()
        pullRequest.detach()
        isPullRequestEnabled = false
        modelObservation = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            pullRequest.detach()
            isPullRequestEnabled = false
        } else {
            scheduleRefresh()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Published values are stored after their notification; coalesce one
        // native refresh for the completed repository snapshot.
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func addPageItem(_ view: NSView, inset: CGFloat = 0, gap: CGFloat = 0,
                             height: @escaping (CGFloat) -> CGFloat) {
        pageItems.append(PageItem(view: view, inset: inset, gap: gap, height: height))
    }

    private func refresh() {
        guard boundModel != nil else { return }
        if repositoryIdentity != model.repositoryIdentity {
            resetRepositoryDrafts()
            repositoryIdentity = model.repositoryIdentity
        }
        if rootPath != model.rootPath {
            dismissSheet()
            rootPath = model.rootPath
        }
        if !model.isBusy { operationTrigger = nil }
        let scale = metrics.fontScale
        pageItems.removeAll(keepingCapacity: true)
        header.configure(branch: model.isRepo ? model.branch ?? String(localized: "Detached HEAD") : String(localized: "Git"),
                         rootPath: model.rootPath, scale: scale, isRepo: model.isRepo,
                         isRemote: isRemote, isBusy: model.isBusy, isResolving: model.isResolvingInitialStatus,
                         branchLoading: operationIsLoading(.branchMenu), moreLoading: operationIsLoading(.moreMenu))
        header.onBranchMenu = { [weak self] button in self?.showBranchMenu(relativeTo: button) }
        header.onMoreMenu = { [weak self] button in self?.showMoreMenu(relativeTo: button) }
        header.onRefresh = { [weak self] in self?.boundModel?.refresh() }
        addPageItem(header) { [weak header] _ in header?.requiredHeight ?? 0 }
        if let operation = model.operation, case .failed = operation.state {
            failure.configure(operation: operation, isExpanded: operationExpanded, scale: scale)
            failure.onToggle = { [weak self] in self?.operationExpanded.toggle(); self?.refresh() }
            failure.onDismiss = { [weak self] in self?.operationExpanded = false; self?.boundModel?.dismissOperation() }
            addPageItem(failure, inset: 10, gap: 7) { [weak failure] width in failure?.height(for: width) ?? 0 }
        }
        let showPR = AppSettings.shared.showPullRequestStatus && !isRemote && model.isRepo
            && model.statusError == nil && window != nil
        if showPR {
            pullRequest.update(directory: model.rootPath.isEmpty ? nil : model.rootPath, fontScale: scale)
            isPullRequestEnabled = true
        } else if isPullRequestEnabled {
            pullRequest.detach()
            isPullRequestEnabled = false
        }
        if let statusError = model.statusError {
            repositoryState.configure(icon: "exclamationmark.triangle", title: String(localized: "Git Status Unavailable"),
                                      message: statusError, scale: scale, actionTitle: String(localized: "Retry"),
                                      enabled: !model.isBusy && !model.isResolvingInitialStatus, loading: false,
                                      action: { [weak self] in self?.boundModel?.refresh() })
            addRepositoryState()
        } else if !model.isRepo {
            if model.isResolvingInitialStatus {
                repositoryState.configure(icon: "arrow.clockwise", title: String(localized: "Finding repository…"),
                                          message: "", scale: scale)
            } else {
                repositoryState.configure(icon: "arrow.triangle.branch", title: String(localized: "No Git Repository"),
                    message: String(localized: "Initialize the terminal’s current directory to start tracking changes."),
                    scale: scale, actionTitle: isRemote ? nil : String(localized: "Initialize Repository"),
                    enabled: !model.rootPath.isEmpty && !model.isBusy,
                    loading: operationIsLoading(.initializeRepository), action: { [weak self] in
                        guard let self else { return }
                        self.performOperation(.initializeRepository) { self.model.initializeRepository() }
                    })
            }
            addRepositoryState()
        } else {
            if let branch = model.branch {
                tracking.configure(branch: branch, upstream: model.upstream, hasUpstream: model.hasUpstream,
                                   ahead: model.ahead, behind: model.behind, scale: scale)
                addPageItem(tracking, gap: 6) { [weak tracking] _ in tracking?.requiredHeight ?? 0 }
            }
            if !isRemote {
                if showPR {
                    addPageItem(pullRequestContainer) { [weak pullRequest] _ in pullRequest?.intrinsicContentSize.height ?? 0 }
                }
                branchSearch.update(text: worktreeBranchSearch, placeholder: String(localized: "Search worktrees or branches"), fontScale: scale)
                addPageItem(branchSearch, inset: 10, gap: 4) { [weak self] _ in 26 * (self?.metrics.growthScale ?? 1) }
                configureRepositorySections()
            }
            if let operation = model.repositoryOperation {
                repositoryOperation.configure(title: operation,
                    detail: model.mergeEntries.isEmpty ? String(localized: "Finish or abort from the terminal")
                        : String(localized: "Resolve and stage \(model.mergeEntries.count) conflicted files", comment: "Git merge guidance. The placeholder is the number of conflicted files."),
                    scale: scale)
                addPageItem(repositoryOperation, inset: 10, gap: 7) { [weak repositoryOperation] width in repositoryOperation?.height(for: width) ?? 0 }
            }
            if !isRemote {
                commitBox.configure(message: commitMessage, placeholder: commitFieldPlaceholder, scale: scale,
                    commitTitle: commitButtonTitle, canCommit: canCommit(includeAll: false),
                    showCommit: !showSyncButton || canCommit(includeAll: false), commitLoading: operationIsLoading(.primaryAction),
                    menuLoading: operationIsLoading(.commitMenu), showSync: showSyncButton,
                    syncTitle: syncButtonTitle, syncEnabled: !model.isBusy, syncLoading: operationIsLoading(.syncButton))
                addPageItem(commitBox, inset: 10, gap: 8) { [weak commitBox] width in commitBox?.height(for: width) ?? 0 }
                let snapshots = reviewSnapshots
                reviewSummary.update(reviewedCount: DiffReviewStore.shared.reviewedCount(in: snapshots),
                    totalCount: snapshots.count, fontScale: scale, repositoryRoot: model.repositoryIdentity)
                addPageItem(reviewSummary, inset: 10, gap: 4) { [weak self] _ in 25 * (self?.metrics.growthScale ?? 1) }
            }
            fileFilter.update(text: filterText, placeholder: String(localized: "Filter changed files"), fontScale: scale)
            addPageItem(fileFilter, inset: 10, gap: 4) { [weak self] _ in 26 * (self?.metrics.growthScale ?? 1) }
            configureChanges()
        }
        let active = Set(pageItems.map { ObjectIdentifier($0.view) })
        for view in document.subviews { view.isHidden = !active.contains(ObjectIdentifier(view)) }
        needsLayout = true
    }

    private func addRepositoryState() {
        addPageItem(repositoryState, inset: 18) { [weak self, weak repositoryState] width in
            max(repositoryState?.height(for: width) ?? 0, (self?.scrollView.contentSize.height ?? 0) - (self?.header.requiredHeight ?? 0))
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = scrollView.contentSize.width
        var y: CGFloat = 0
        for item in pageItems {
            let itemWidth = max(0, width - 2 * item.inset)
            let height = ceil(item.height(itemWidth))
            item.view.frame = NSRect(x: item.inset, y: y, width: itemWidth, height: height)
            y += height + item.gap
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, y + 8))
        pullRequest.frame = pullRequestContainer.bounds
        // Collapsing or filtering a long section must clamp the page's old offset.
        let maximum = max(0, document.bounds.height - scrollView.contentSize.height)
        let offset = min(max(0, scrollView.contentView.bounds.minY), maximum)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private var worktreeBranchQuery: String { worktreeBranchSearch.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var filteredWorktrees: [GitStatusModel.Worktree] {
        guard !worktreeBranchQuery.isEmpty else { return model.worktrees }
        return model.worktrees.filter { $0.path.localizedCaseInsensitiveContains(worktreeBranchQuery)
            || ($0.branch?.localizedCaseInsensitiveContains(worktreeBranchQuery) ?? false) }
    }
    private var filteredBranches: [String] {
        guard !worktreeBranchQuery.isEmpty else { return model.branchesWithoutWorktrees }
        return model.branchesWithoutWorktrees.filter { $0.localizedCaseInsensitiveContains(worktreeBranchQuery) }
    }

    private func configureRepositorySections() {
        let scale = metrics.fontScale
        if !filteredBranches.isEmpty {
            branches.apply(branches: filteredBranches, isCollapsed: collapsed.contains("branches"), fontScale: scale,
                           repositoryID: model.repositoryIdentity, isBusy: model.isBusy,
                           switchBranch: { [weak self] branch in
                               guard let self else { return }
                               self.performOperation(.branchMenu) { self.model.switchBranch(to: branch) }
                           }, createBranch: { [weak self] in self?.presentCreateBranchDialog() },
                           createWorktree: { [weak self] in self?.presentCreateWorktreeDialog(forBranch: $0) },
                           deleteBranch: { [weak self] in self?.requestDeleteBranch($0) },
                           toggleCollapsed: { [weak self] in self?.toggleSection("branches") })
            addPageItem(branches) { [weak branches] _ in branches?.intrinsicContentSize.height ?? 0 }
        }
        if !filteredWorktrees.isEmpty {
            worktrees.apply(worktrees: filteredWorktrees, isCollapsed: collapsed.contains("worktrees"), fontScale: scale,
                            openWorktree: { [weak self] in self?.openWorktree?($0) },
                            createWorktree: { [weak self] in self?.presentCreateWorktreeDialog() },
                            removeWorktree: { [weak self] in self?.requestRemoveWorktree($0) },
                            deleteBranch: { [weak self] in self?.requestDeleteBranch($0) },
                            toggleCollapsed: { [weak self] in self?.toggleSection("worktrees") }, isBusy: model.isBusy)
            addPageItem(worktrees) { [weak worktrees] _ in worktrees?.intrinsicContentSize.height ?? 0 }
        }
    }

    private func toggleSection(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        refresh()
    }

    private func configureChanges() {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (GitStatusModel.Entry) -> Bool = { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
        let merge = model.mergeEntries.filter(matches)
        let staged = model.stagedEntries.filter(matches)
        let changed = model.changedEntries.filter(matches)
        if model.totalChangeCount == 0 || merge.count + staged.count + changed.count == 0 {
            let isClean = model.totalChangeCount == 0
            let syncPending = model.ahead > 0 || model.behind > 0
            cleanState.configure(icon: isClean ? (syncPending ? "arrow.triangle.2.circlepath" : "checkmark.circle") : "line.3.horizontal.decrease",
                title: isClean ? (syncPending ? String(localized: "Working tree clean, sync is pending") : String(localized: "Working tree clean"))
                    : String(localized: "No changed files match “\(filterText)”"), message: "", scale: metrics.fontScale)
            addPageItem(cleanState, inset: 12) { [weak cleanState] width in cleanState?.height(for: width) ?? 0 }
        }
        configureChangeSection("merge", title: String(localized: "MERGE CHANGES"), entries: merge, kind: .merge,
                               header: mergeHeader, list: mergeList, actions: [])
        let stagedActions: [GitPanelSectionAction] = filterText.isEmpty && !isRemote ? [
            sectionAction("minus", help: String(localized: "Unstage All Changes"), trigger: .unstageAll, action: { [weak self] in self?.boundModel?.unstageAll() })
        ] : []
        configureChangeSection("staged", title: String(localized: "STAGED CHANGES"), entries: staged, kind: .staged,
                               header: stagedHeader, list: stagedList, actions: stagedActions)
        let changedActions: [GitPanelSectionAction] = filterText.isEmpty && !isRemote ? [
            GitPanelSectionAction(symbol: "arrow.uturn.backward", help: String(localized: "Discard All Changes"),
                                  loading: operationIsLoading(.discardAll), enabled: !model.isBusy, action: { [weak self] in self?.requestDiscardAll() }),
            sectionAction("plus", help: String(localized: "Stage All Changes"), trigger: .stageAll, action: { [weak self] in self?.boundModel?.stageAll() })
        ] : []
        configureChangeSection("changes", title: String(localized: "CHANGES"), entries: changed, kind: .unstaged,
                               header: changesHeader, list: changesList, actions: changedActions)
        if filterText.isEmpty, !model.recentCommits.isEmpty {
            historyHeader.configure(title: String(localized: "RECENT COMMITS"), count: model.recentCommits.count,
                                    collapsed: collapsed.contains("history"), scale: metrics.fontScale, actions: [],
                                    toggle: { [weak self] in self?.toggleSection("history") })
            addPageItem(historyHeader, inset: 6) { [weak historyHeader] _ in historyHeader?.requiredHeight ?? 0 }
            if !collapsed.contains("history") {
                history.configure(commits: model.recentCommits, expandedCommitIDs: expandedCommitIDs,
                                  fontScale: metrics.fontScale, hasMoreCommits: model.hasMoreRecentCommits,
                                  isLoadingMore: model.isLoadingMoreCommits)
                addPageItem(history, inset: 6) { [weak history] _ in history?.requiredHeight ?? 0 }
            }
        }
    }

    private func configureChangeSection(_ id: String, title: String, entries: [GitStatusModel.Entry], kind: GitPanelEntryKind,
                                        header: GitPanelSectionHeaderView, list: GitPanelChangesView, actions: [GitPanelSectionAction]) {
        guard !entries.isEmpty else { return }
        header.configure(title: title, count: entries.count, collapsed: collapsed.contains(id), scale: metrics.fontScale,
                         actions: actions, toggle: { [weak self] in self?.toggleSection(id) })
        addPageItem(header, inset: 6) { [weak header] _ in header?.requiredHeight ?? 0 }
        if !collapsed.contains(id) {
            list.configure(entries: entries, kind: kind, scale: metrics.fontScale, repositoryID: model.repositoryIdentity) { [weak self] entry in
                self?.callbacks(for: entry, kind: kind) ?? GitPanelEntryCallbacks()
            }
            addPageItem(list, inset: 6) { [weak list] _ in list?.requiredHeight ?? 0 }
        }
    }

    private func sectionAction(_ symbol: String, help: String, trigger: OperationTrigger, action: @escaping () -> Void) -> GitPanelSectionAction {
        GitPanelSectionAction(symbol: symbol, help: help, loading: operationIsLoading(trigger), enabled: !model.isBusy,
                              action: { [weak self] in self?.performOperation(trigger, action) })
    }

    private func callbacks(for entry: GitStatusModel.Entry, kind: GitPanelEntryKind) -> GitPanelEntryCallbacks {
        let stage = OperationTrigger.entry(path: entry.path, operation: .stage)
        let unstage = OperationTrigger.entry(path: entry.path, operation: .unstage)
        let discard = OperationTrigger.entry(path: entry.path, operation: .discard)
        let snapshot = isRemote ? nil : entry.reviewSnapshot(staged: kind == .staged)
        return GitPanelEntryCallbacks(absolutePath: model.absolutePath(for: entry), isRemote: isRemote, disabled: model.isBusy || isRemote,
            stageLoading: operationIsLoading(stage), unstageLoading: operationIsLoading(unstage), discardLoading: operationIsLoading(discard),
            reviewState: snapshot.map { DiffReviewStore.shared.isReviewed($0) ? .reviewed : .unreviewed },
            openDiff: { [weak self] in
                guard let self, !self.isRemote, self.model.isCurrent(entry) else { return }
                var diffEntry = entry
                if kind == .unstaged && (entry.staged == "R" || entry.staged == "C") { diffEntry.origPath = nil }
                self.openDiff?(diffEntry, kind == .staged)
            }, openFile: { [weak self] in self?.openIfPossible(entry) },
            openToSide: { [weak self] in self?.openIfPossible(entry, toSide: true) },
            stage: { [weak self] in guard let self else { return }; self.performOperation(stage) { self.model.stage(entry) } },
            unstage: { [weak self] in guard let self else { return }; self.performOperation(unstage) { self.model.unstage(entry) } },
            discard: { [weak self] in self?.requestDiscard(entry) },
            toggleReview: {
                guard let snapshot else { return }
                DiffReviewStore.shared.setReviewed(!DiffReviewStore.shared.isReviewed(snapshot), for: snapshot)
            }, insertInTerminal: session == nil ? nil : { [weak self] in
                guard let self, self.model.isCurrent(entry) else { return }
                self.session?.sendCommand(self.shellQuoted(self.model.absolutePath(for: entry)) + " ")
            })
    }

    private func openIfPossible(_ entry: GitStatusModel.Entry, toSide: Bool = false) {
        guard !isRemote, model.isCurrent(entry) else { return }
        let path = model.absolutePath(for: entry)
        guard FileManager.default.fileExists(atPath: path) else { return }
        if toSide { openToSide?(path) } else { openFile?(path) }
    }

    private func performOperation(_ trigger: OperationTrigger, _ action: () -> Void) {
        guard !isRemote, !model.isBusy else { return }
        operationExpanded = false
        operationTrigger = trigger
        action()
        if !model.isBusy { operationTrigger = nil }
        refresh()
    }

    private func operationIsLoading(_ trigger: OperationTrigger) -> Bool { model.isBusy && operationTrigger == trigger }

    private func resetRepositoryDrafts() {
        commitMessage = ""
        filterText = ""
        worktreeBranchSearch = ""
        collapsed.removeAll()
        expandedCommitIDs.removeAll()
        operationExpanded = false
        operationTrigger = nil
        dismissSheet()
        scrollView.contentView.scroll(to: .zero)
        for list in [mergeList, stagedList, changesList] { list.resetSelection() }
    }
}

private final class GitPanelDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private extension GitPanelNSView {
    var reviewSnapshots: [DiffReviewSnapshot] {
        model.mergeEntries.compactMap { $0.reviewSnapshot(staged: false) }
            + model.stagedEntries.compactMap { $0.reviewSnapshot(staged: true) }
            + model.changedEntries.compactMap { $0.reviewSnapshot(staged: false) }
    }

    var commitFieldPlaceholder: String {
        String(localized: "Commit message")
    }

    var showSyncButton: Bool { model.totalChangeCount == 0 && (model.ahead > 0 || model.behind > 0) }
    var syncButtonTitle: String {
        var title = String(localized: "Sync Changes")
        if model.behind > 0 { title += " \(model.behind)↓" }
        if model.ahead > 0 { title += " \(model.ahead)↑" }
        return title
    }
    var commitButtonTitle: String {
        model.stagedEntries.isEmpty ? String(localized: "Commit Staged")
            : String(localized: "Commit \(model.stagedEntries.count) Staged Files", comment: "Commit button title. The placeholder is the number of staged files.")
    }

    func canCommit(includeAll: Bool) -> Bool {
        let eligible = includeAll ? !model.changedEntries.isEmpty || !model.stagedEntries.isEmpty : !model.stagedEntries.isEmpty
        return !isRemote && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && eligible && model.mergeEntries.isEmpty && !model.isBusy
    }

    func canAmend(includeAll: Bool) -> Bool {
        let eligible = !includeAll || !model.changedEntries.isEmpty || !model.stagedEntries.isEmpty
        return !isRemote && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.recentCommits.isEmpty && eligible && model.mergeEntries.isEmpty && !model.isBusy
    }

    private func performCommit(includeAll: Bool, amend: Bool = false, trigger: OperationTrigger) {
        guard amend ? canAmend(includeAll: includeAll) : canCommit(includeAll: includeAll) else { return }
        let submittedMessage = commitMessage
        let submittedModel = model
        let repository = model.repositoryIdentity
        performOperation(trigger) {
            model.commit(message: submittedMessage, includeAll: includeAll, amend: amend) { [weak self] success in
                guard let self, success, self.boundModel === submittedModel,
                      self.model.repositoryIdentity == repository, self.commitMessage == submittedMessage else { return }
                self.commitMessage = ""
                self.refresh()
            }
        }
    }

    func menuItem(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let repository = model.repositoryIdentity
        let root = model.rootPath
        return GitPanelMenuItem(title: title, enabled: enabled) { [weak self] in
            guard let self, self.model.repositoryIdentity == repository, self.model.rootPath == root else { return }
            action()
        }
    }

    func showMenu(_ menu: NSMenu, relativeTo button: NSButton) {
        menu.autoenablesItems = false
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: button)
    }

    func showBranchMenu(relativeTo button: NSButton) {
        guard !isRemote else { return }
        let menu = NSMenu()
        for branch in filteredBranches {
            let item = menuItem(branch, enabled: !model.isBusy && branch != model.branch) { [weak self] in
                guard let self else { return }
                self.performOperation(.branchMenu) { self.model.switchBranch(to: branch) }
            }
            item.state = branch == model.branch ? .on : .off
            menu.addItem(item)
        }
        if !filteredBranches.isEmpty { menu.addItem(.separator()) }
        menu.addItem(menuItem(String(localized: "Create Worktree…"), enabled: !model.isBusy && !filteredBranches.isEmpty) { [weak self] in self?.presentCreateWorktreeDialog() })
        if let branch = model.branch, branch != "detached HEAD" {
            menu.addItem(menuItem(String(localized: "Delete Current Branch…"), enabled: !model.isBusy) { [weak self] in self?.requestDeleteBranch(branch) })
        }
        let delete = NSMenu()
        if filteredBranches.isEmpty {
            delete.addItem(menuItem(String(localized: "No available branches"), enabled: false, action: {}))
        } else {
            for branch in filteredBranches {
                delete.addItem(menuItem(branch, enabled: !model.isBusy) { [weak self] in self?.requestDeleteBranch(branch) })
            }
        }
        let deleteItem = NSMenuItem(title: String(localized: "Delete Branch…"), action: nil, keyEquivalent: "")
        deleteItem.submenu = delete
        menu.addItem(deleteItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Create New Branch…"), enabled: !model.isBusy) { [weak self] in self?.presentCreateBranchDialog() })
        showMenu(menu, relativeTo: button)
    }

    func showMoreMenu(relativeTo button: NSButton) {
        guard !isRemote else { return }
        let menu = NSMenu()
        menu.addItem(menuItem(String(localized: "Fetch"), enabled: !model.isBusy && !model.remotes.isEmpty) { [weak self] in
            guard let self else { return }; self.performOperation(.moreMenu, self.model.fetch)
        })
        menu.addItem(menuItem(String(localized: "Pull (Fast-forward Only)"), enabled: !model.isBusy && model.hasUpstream) { [weak self] in
            guard let self else { return }; self.performOperation(.moreMenu, self.model.pull)
        })
        if model.hasUpstream {
            menu.addItem(menuItem(String(localized: "Push"), enabled: !model.isBusy) { [weak self] in
                guard let self else { return }; self.performOperation(.moreMenu, self.model.push)
            })
        } else if model.remotes.count > 1 {
            let publish = NSMenu()
            for remote in model.remotes {
                publish.addItem(menuItem(remote, enabled: !model.isBusy && model.branch != "detached HEAD") { [weak self] in
                    guard let self else { return }; self.performOperation(.moreMenu) { self.model.publish(to: remote) }
                })
            }
            let item = NSMenuItem(title: String(localized: "Publish Branch to"), action: nil, keyEquivalent: "")
            item.submenu = publish
            menu.addItem(item)
        } else {
            menu.addItem(menuItem(String(localized: "Publish Branch"), enabled: !model.isBusy && !model.remotes.isEmpty && model.branch != "detached HEAD") { [weak self] in
                guard let self else { return }; self.performOperation(.moreMenu, self.model.push)
            })
        }
        menu.addItem(menuItem(String(localized: "Sync Changes"), enabled: !model.isBusy && !model.remotes.isEmpty
            && (model.hasUpstream || model.remotes.count == 1) && model.branch != "detached HEAD") { [weak self] in
            guard let self else { return }; self.performOperation(.moreMenu, self.model.syncChanges)
        })
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Stash All Changes"), enabled: !model.isBusy && model.totalChangeCount > 0) { [weak self] in
            guard let self else { return }; self.performOperation(.moreMenu) { self.model.stash(includeUntracked: true) }
        })
        menu.addItem(menuItem(model.stashCount == 1 ? String(localized: "Pop Stash") : String(localized: "Pop Stash (\(model.stashCount))"),
                              enabled: !model.isBusy && model.stashCount > 0) { [weak self] in
            guard let self else { return }; self.performOperation(.moreMenu, self.model.stashPop)
        })
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Copy Changed Paths"), enabled: model.totalChangeCount > 0) { [weak self] in
            guard let self else { return }
            let paths = Set((self.model.mergeEntries + self.model.stagedEntries + self.model.changedEntries).map(\.path)).sorted()
            Self.copyToPasteboard(paths.joined(separator: "\n"))
        })
        menu.addItem(menuItem(String(localized: "Copy Repository Path")) { [weak self] in
            guard let self else { return }; Self.copyToPasteboard(self.model.repoRoot)
        })
        menu.addItem(menuItem(String(localized: "Reveal Repository in Finder")) { [weak self] in
            guard let self else { return }; NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: self.model.repoRoot)])
        })
        showMenu(menu, relativeTo: button)
    }

    func makeCommitMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(String(localized: "Commit Staged"), enabled: canCommit(includeAll: false)) { [weak self] in self?.performCommit(includeAll: false, trigger: .commitMenu) })
        menu.addItem(menuItem(String(localized: "Stage All & Commit"), enabled: canCommit(includeAll: true)) { [weak self] in self?.performCommit(includeAll: true, trigger: .commitMenu) })
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Amend Last Commit"), enabled: canAmend(includeAll: false)) { [weak self] in self?.performCommit(includeAll: false, amend: true, trigger: .commitMenu) })
        menu.addItem(menuItem(String(localized: "Stage All & Amend"), enabled: canAmend(includeAll: true)) { [weak self] in self?.performCommit(includeAll: true, amend: true, trigger: .commitMenu) })
        return menu
    }

    func showCommitMenu(relativeTo button: NSButton) {
        showMenu(makeCommitMenu(), relativeTo: button)
    }

    func presentAlert(_ alert: NSAlert, response: @escaping (NSApplication.ModalResponse) -> Void) {
        guard activeSheet == nil, let host = AppWindowPresentation.hostWindow(relativeTo: window) else { return }
        let sheet = alert.window
        activeSheet = sheet
        let repository = model.repositoryIdentity
        let root = model.rootPath
        alert.beginSheetModal(for: host) { [weak self] result in
            guard let self, self.activeSheet === sheet else { return }
            self.activeSheet = nil
            guard self.model.repositoryIdentity == repository, self.model.rootPath == root, !self.isRemote else { return }
            response(result)
        }
    }

    func dismissSheet() {
        guard let sheet = activeSheet else { return }
        activeSheet = nil
        sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
    }

    func confirm(title: String, message: String = "", actionTitle: String, action: @escaping () -> Void) {
        guard !model.isBusy, !isRemote else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: actionTitle)
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        presentAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, self?.boundModel?.isBusy == false else { return }
            action()
        }
    }

    func presentCreateBranchDialog() {
        guard !model.isBusy, !isRemote else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Create New Branch")
        alert.informativeText = String(localized: "Enter a name for the new branch.")
        let field = NSTextField(string: "")
        field.placeholderString = String(localized: "Branch name")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        let create = alert.addButton(withTitle: String(localized: "Create"))
        create.keyEquivalent = "\r"
        create.isEnabled = false
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        let validator = GitPanelBranchNameValidator(button: create)
        field.delegate = validator
        alert.window.initialFirstResponder = field
        presentAlert(alert) { [weak self] response in
            _ = validator
            guard let self, response == .alertFirstButtonReturn else { return }
            self.performOperation(.branchMenu) { self.model.createBranch(named: field.stringValue) }
        }
    }

    func presentCreateWorktreeDialog(forBranch preferredBranch: String? = nil) {
        guard !model.isBusy, !isRemote else { return }
        let available = model.branchesWithoutWorktrees
        guard !available.isEmpty else {
            model.lastError = String(localized: "Create a branch before creating a worktree")
            return
        }
        if let preferredBranch, !available.contains(preferredBranch) {
            model.lastError = String(localized: "The selected branch is no longer available")
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Create Worktree")
        alert.informativeText = String(localized: "Choose a local branch, then choose the worktree directory.")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 24), pullsDown: false)
        picker.addItems(withTitles: available)
        if let preferredBranch { picker.selectItem(withTitle: preferredBranch) }
        alert.accessoryView = picker
        alert.addButton(withTitle: String(localized: "Choose Directory"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        presentAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, !self.model.isBusy,
                  let branch = picker.titleOfSelectedItem,
                  let host = AppWindowPresentation.hostWindow(relativeTo: self.window) else { return }
            let panel = NSSavePanel()
            panel.title = String(localized: "Choose Worktree Directory")
            panel.nameFieldStringValue = branch.replacingOccurrences(of: "/", with: "-")
            panel.directoryURL = URL(fileURLWithPath: self.model.repoRoot).deletingLastPathComponent()
            panel.canCreateDirectories = true
            self.activeSheet = panel
            let repository = self.model.repositoryIdentity
            let root = self.model.rootPath
            panel.beginSheetModal(for: host) { [weak self] result in
                guard let self, self.activeSheet === panel else { return }
                self.activeSheet = nil
                guard result == .OK, let url = panel.url, self.model.repositoryIdentity == repository,
                      self.model.rootPath == root else { return }
                self.performOperation(.worktree) { self.model.createWorktree(at: url.path, forBranch: branch) }
            }
        }
    }

    func requestRemoveWorktree(_ worktree: GitStatusModel.Worktree) {
        guard !worktree.isCurrent, !worktree.isBare else { return }
        confirm(title: String(localized: "Remove Worktree?"),
                message: String(localized: "Remove the worktree at \(worktree.path)? Git will keep its branch."),
                actionTitle: String(localized: "Remove Worktree")) { [weak self] in
            guard let self else { return }; self.performOperation(.worktree) { self.model.removeWorktree(worktree) }
        }
    }

    func requestDeleteBranch(_ branch: String) {
        confirm(title: String(localized: "Delete Branch?"),
                message: String(localized: "A stash snapshot including untracked files will be created before deleting \(branch)."),
                actionTitle: String(localized: "Delete Branch")) { [weak self] in
            guard let self else { return }; self.performOperation(.branchMenu) { self.model.deleteBranch(named: branch) }
        }
    }

    func requestDiscard(_ entry: GitStatusModel.Entry) {
        guard model.isCurrent(entry) else { return }
        let pending = makePendingDiscard(entry)
        confirm(title: discardTitle(for: entry), actionTitle: discardActionTitle(for: entry)) { [weak self] in
            guard let self else { return }
            if self.discardSnapshotIsCurrent(pending) {
                self.performOperation(.entry(path: entry.path, operation: .discard)) { self.model.discard(entry) }
            } else { self.model.cancelStaleDiscard() }
        }
    }

    func requestDiscardAll() {
        let pending = model.changedEntries.map(makePendingDiscard)
        guard !pending.isEmpty else { return }
        confirm(title: String(localized: "Discard the \(pending.count) reviewed changes? Untracked and moved files go to the Trash."),
                actionTitle: String(localized: "Discard All Changes")) { [weak self] in
            guard let self else { return }
            if pending.allSatisfy(self.discardSnapshotIsCurrent) {
                self.performOperation(.discardAll) { self.model.discardChanges(pending.map(\.entry)) }
            } else { self.model.cancelStaleDiscard() }
        }
    }

    func discardTitle(for entry: GitStatusModel.Entry) -> String {
        if entry.isUntracked {
            return String(localized: "Delete \(entry.fileName)? Its contents will move to the Trash.", comment: "Discard confirmation. The placeholder is an untracked file name.")
        }
        if entry.isWorktreeRename, let original = entry.origPath {
            return String(localized: "Undo this rename? \(entry.fileName) will move to the Trash and \((original as NSString).lastPathComponent) will be restored.", comment: "Rename discard confirmation. The placeholders are the new and old file names.")
        }
        if entry.isWorktreeCopy {
            return String(localized: "Discard this copy? \(entry.fileName) will move to the Trash.", comment: "Copy discard confirmation. The placeholder is a file name.")
        }
        return String(localized: "Discard changes in \(entry.fileName)?", comment: "Discard confirmation. The placeholder is a file name.")
    }

    func discardActionTitle(for entry: GitStatusModel.Entry) -> String {
        if entry.isUntracked || entry.isWorktreeCopy { return String(localized: "Move to Trash") }
        return entry.isWorktreeRename ? String(localized: "Undo Rename") : String(localized: "Discard Changes")
    }

    private func makePendingDiscard(_ entry: GitStatusModel.Entry) -> PendingDiscard {
        var paths = [entry.path]
        if entry.isWorktreeRename, let original = entry.origPath { paths.append(original) }
        return PendingDiscard(entry: entry, fingerprints: Dictionary(uniqueKeysWithValues: paths.map { path in
            (path, fileFingerprint(at: absolutePath(path, for: entry)))
        }), branch: model.branch, headOID: model.headOID)
    }

    private func discardSnapshotIsCurrent(_ pending: PendingDiscard) -> Bool {
        model.isCurrent(pending.entry) && model.branch == pending.branch && model.headOID == pending.headOID
            && model.changedEntries.contains(pending.entry) && pending.fingerprints.allSatisfy { path, fingerprint in
                fileFingerprint(at: absolutePath(path, for: pending.entry)) == fingerprint
            }
    }

    func absolutePath(_ path: String, for entry: GitStatusModel.Entry) -> String {
        ((entry.repositoryRoot.isEmpty ? model.repoRoot : entry.repositoryRoot) as NSString).appendingPathComponent(path)
    }

    private func fileFingerprint(at path: String) -> FileFingerprint {
        let fm = FileManager.default
        let destination = try? fm.destinationOfSymbolicLink(atPath: path)
        guard destination != nil || fm.fileExists(atPath: path) else {
            return FileFingerprint(exists: false, size: 0, modificationDate: nil, fileNumber: nil, symbolicLinkDestination: nil)
        }
        let attributes = try? fm.attributesOfItem(atPath: path)
        return FileFingerprint(exists: true, size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
                               modificationDate: attributes?[.modificationDate] as? Date,
                               fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
                               symbolicLinkDestination: destination)
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func shellQuoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private final class GitPanelMenuItem: NSMenuItem {
    private let onAction: () -> Void
    init(title: String, enabled: Bool = true, action: @escaping () -> Void) {
        onAction = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { onAction() }
}

private final class GitPanelBranchNameValidator: NSObject, NSTextFieldDelegate {
    private weak var button: NSButton?
    init(button: NSButton) { self.button = button }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        button?.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private final class GitPanelButton: NSButton {
    var onAction: (() -> Void)?
    private let spinner = NSProgressIndicator()
    private var showsProgress = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
        imageScaling = .scaleProportionallyDown
        target = self
        action = #selector(invoke)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String, title: String = "", help: String, scale: CGFloat,
                   enabled: Bool = true, loading: Bool = false, primary: Bool = false) {
        self.title = title
        font = .systemFont(ofSize: 11 * scale, weight: .medium)
        image = loading ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10 * scale, weight: .medium))
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        contentTintColor = primary ? .white : .secondaryLabelColor
        isEnabled = enabled
        toolTip = help
        setAccessibilityLabel(loading ? String(localized: "\(help), in progress") : help)
        showsProgress = loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        wantsLayer = primary
        if primary {
            layer?.cornerRadius = 6
            layer?.backgroundColor = Theme.accent.withAlphaComponent(enabled || loading ? 0.85 : 0.3).cgColor
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = min(16, bounds.height)
        spinner.frame = NSRect(x: title.isEmpty ? (bounds.width - size) / 2 : 7,
                               y: (bounds.height - size) / 2, width: size, height: size)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    @objc private func invoke() { if isEnabled { onAction?() } }
}

private final class GitPanelHeaderView: NSView {
    let branchButton = GitPanelButton()
    private let branchLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let refreshButton = GitPanelButton()
    private let moreButton = GitPanelButton()
    private let resolving = NSProgressIndicator()
    private var metrics = SidebarLayoutMetrics(fontScale: 1)
    var onBranchMenu: ((NSButton) -> Void)?
    var onMoreMenu: ((NSButton) -> Void)?
    var onRefresh: (() -> Void)?
    var requiredHeight: CGFloat {
        metrics.lineHeight(designedFontSize: 12, weight: .semibold, minimum: 16)
            + metrics.lineHeight(designedFontSize: 10, minimum: 13) + 17
    }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [branchLabel, pathLabel] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingHead
            label.setAccessibilityElement(false)
        }
        branchLabel.lineBreakMode = .byTruncatingTail
        branchButton.addSubview(branchLabel)
        branchButton.addSubview(pathLabel)
        resolving.style = .spinning
        resolving.controlSize = .small
        resolving.isDisplayedWhenStopped = false
        resolving.setAccessibilityLabel(String(localized: "Refreshing Git status"))
        for view in [branchButton, refreshButton, moreButton, resolving] { addSubview(view) }
        branchButton.onAction = { [weak self] in guard let self else { return }; self.onBranchMenu?(self.branchButton) }
        moreButton.onAction = { [weak self] in guard let self else { return }; self.onMoreMenu?(self.moreButton) }
        refreshButton.onAction = { [weak self] in self?.onRefresh?() }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(branch: String, rootPath: String, scale: CGFloat, isRepo: Bool, isRemote: Bool,
                   isBusy: Bool, isResolving: Bool, branchLoading: Bool, moreLoading: Bool) {
        metrics = SidebarLayoutMetrics(fontScale: scale)
        branchButton.configure(symbol: "arrow.triangle.branch", help: String(localized: "Switch or Create Branch"), scale: scale,
                               enabled: isRepo && !isRemote && !isBusy, loading: branchLoading)
        branchButton.imagePosition = .imageLeading
        branchButton.alignment = .left
        branchButton.contentTintColor = Theme.accent
        branchButton.setAccessibilityLabel(String(localized: "Current branch, \(branch)"))
        branchLabel.stringValue = branch
        branchLabel.font = .systemFont(ofSize: 12 * scale, weight: .semibold)
        branchLabel.textColor = .labelColor
        pathLabel.stringValue = rootPath
        pathLabel.font = .systemFont(ofSize: 10 * scale)
        pathLabel.textColor = .secondaryLabelColor
        refreshButton.configure(symbol: "arrow.clockwise", help: String(localized: "Refresh Git Status"), scale: scale,
                                enabled: !isBusy && !isResolving)
        moreButton.configure(symbol: "ellipsis", help: String(localized: "More Git Actions"), scale: scale, loading: moreLoading)
        refreshButton.isHidden = !isRepo
        moreButton.isHidden = !isRepo || isRemote
        resolving.isHidden = !isResolving
        if isResolving { resolving.startAnimation(nil) } else { resolving.stopAnimation(nil) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let slot = metrics.slotSize(18)
        var trailing = bounds.width - 12
        for view in [moreButton, refreshButton, resolving] where !view.isHidden {
            view.frame = NSRect(x: trailing - slot, y: (bounds.height - slot) / 2, width: slot, height: slot)
            trailing -= slot + 4
        }
        branchButton.frame = NSRect(x: 12, y: 8, width: max(0, trailing - 16), height: bounds.height - 16)
        let icon = metrics.iconSize(14)
        let titleHeight = metrics.lineHeight(designedFontSize: 12, weight: .semibold, minimum: 16)
        let pathHeight = metrics.lineHeight(designedFontSize: 10, minimum: 13)
        let leading = icon + 6
        branchLabel.frame = NSRect(x: leading, y: pathHeight + 1, width: max(0, branchButton.bounds.width - leading), height: titleHeight)
        pathLabel.frame = NSRect(x: leading, y: 0, width: max(0, branchButton.bounds.width - leading), height: pathHeight)
    }
}

private final class GitPanelTrackingView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let incoming = NSTextField(labelWithString: "")
    private let outgoing = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private var scale: CGFloat = 1
    var requiredHeight: CGFloat { 17 * max(1, scale) }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        for view in [label, incoming, outgoing, imageView] { addSubview(view) }
        imageView.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(branch: String, upstream: String?, hasUpstream: Bool, ahead: Int, behind: Int, scale: CGFloat) {
        self.scale = scale
        imageView.image = NSImage(systemSymbolName: hasUpstream ? "arrow.triangle.2.circlepath" : "icloud.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9 * scale, weight: .medium))
        imageView.contentTintColor = .secondaryLabelColor
        label.stringValue = upstream ?? (branch == "detached HEAD" ? String(localized: "Detached HEAD") : String(localized: "Unpublished branch"))
        label.font = .systemFont(ofSize: 9.5 * scale)
        label.textColor = .secondaryLabelColor
        for badge in [incoming, outgoing] {
            badge.font = .monospacedDigitSystemFont(ofSize: 10 * scale, weight: .medium)
            badge.textColor = .secondaryLabelColor
        }
        incoming.stringValue = "↓\(behind)"
        incoming.isHidden = behind == 0
        incoming.setAccessibilityLabel(String(localized: "\(behind) incoming commits"))
        outgoing.stringValue = "↑\(ahead)"
        outgoing.isHidden = ahead == 0
        outgoing.setAccessibilityLabel(String(localized: "\(ahead) outgoing commits"))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        var trailing = bounds.width - 12
        for badge in [outgoing, incoming] where !badge.isHidden {
            let width = ceil(badge.intrinsicContentSize.width)
            badge.frame = NSRect(x: trailing - width, y: 0, width: width, height: bounds.height)
            trailing -= width + 7
        }
        let icon = ceil(12 * max(1, scale))
        imageView.frame = NSRect(x: 12, y: 0, width: icon, height: bounds.height)
        label.frame = NSRect(x: 17 + icon, y: 0, width: max(0, trailing - icon - 17), height: bounds.height)
    }
}

struct GitPanelSectionAction {
    let symbol: String
    let help: String
    var loading = false
    var enabled = true
    let action: () -> Void
}

final class GitPanelSectionHeaderView: NSView {
    private let toggle = GitPanelButton()
    private let count = NSTextField(labelWithString: "")
    private var buttons: [GitPanelButton] = []
    private var metrics = SidebarLayoutMetrics(fontScale: 1)
    var requiredHeight: CGFloat { metrics.lineHeight(designedFontSize: 9.5, weight: .medium, minimum: 16) + 11 }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toggle.alignment = .left
        count.textColor = .tertiaryLabelColor
        count.alignment = .right
        count.setAccessibilityElement(false)
        addSubview(toggle)
        addSubview(count)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(title: String, count: Int, collapsed: Bool, scale: CGFloat,
                   actions: [GitPanelSectionAction], toggle: @escaping () -> Void) {
        metrics = SidebarLayoutMetrics(fontScale: scale)
        self.toggle.configure(symbol: collapsed ? "chevron.right" : "chevron.down", title: title, help: title, scale: scale)
        self.toggle.font = .systemFont(ofSize: 9.5 * scale, weight: .medium)
        self.toggle.onAction = toggle
        self.toggle.setAccessibilityValue(String(localized: collapsed ? "Collapsed" : "Expanded"))
        self.count.font = .monospacedDigitSystemFont(ofSize: 9 * scale, weight: .medium)
        self.count.stringValue = String(count)
        while buttons.count > actions.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < actions.count { let button = GitPanelButton(); buttons.append(button); addSubview(button) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (button, action) in zip(buttons, actions) {
            button.configure(symbol: action.symbol, help: action.help, scale: scale, enabled: action.enabled, loading: action.loading)
            button.onAction = action.action
            menu.addItem(GitPanelMenuItem(title: action.help, enabled: action.enabled, action: action.action))
        }
        self.menu = actions.isEmpty ? nil : menu
        self.toggle.menu = self.menu
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let height = requiredHeight - 11
        let countWidth = ceil(count.intrinsicContentSize.width)
        let slot = metrics.slotSize(18)
        let toggleWidth = max(0, bounds.width - countWidth - CGFloat(buttons.count) * (slot + 2) - 22)
        toggle.frame = NSRect(x: 8, y: 8, width: toggleWidth, height: height)
        var x = toggle.frame.maxX + 2
        for button in buttons { button.frame = NSRect(x: x, y: 6, width: slot, height: height + 4); x += slot + 2 }
        count.frame = NSRect(x: bounds.width - countWidth - 8, y: 8, width: countWidth, height: height)
    }
}

private final class GitPanelCommitTextView: NSTextView {
    var onCommit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { onCommit?() }
        else { super.keyDown(with: event) }
    }
}

private final class GitPanelPlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class GitPanelCommitView: NSView, NSTextViewDelegate {
    private let textView = GitPanelCommitTextView()
    private let placeholder = GitPanelPlaceholderLabel(labelWithString: "")
    private let commit = GitPanelButton()
    private let options = GitPanelButton()
    private let sync = GitPanelButton()
    private let fieldBackground = NSView()
    private var metrics = SidebarLayoutMetrics(fontScale: 1)
    private var showsCommit = true
    private var showsSync = false
    var onChange: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onMenu: ((NSButton) -> Void)?
    var onSync: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel(String(localized: "Commit message"))
        textView.onCommit = { [weak self] in self?.onCommit?() }
        placeholder.maximumNumberOfLines = 1
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.textColor = .tertiaryLabelColor
        placeholder.setAccessibilityElement(false)
        fieldBackground.wantsLayer = true
        fieldBackground.layer?.cornerRadius = 6
        for view in [fieldBackground, textView, placeholder, commit, options, sync] { addSubview(view) }
        commit.onAction = { [weak self] in self?.onCommit?() }
        options.onAction = { [weak self] in guard let self else { return }; self.onMenu?(self.options) }
        sync.onAction = { [weak self] in self?.onSync?() }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(message: String, placeholder: String, scale: CGFloat, commitTitle: String, canCommit: Bool,
                   showCommit: Bool, commitLoading: Bool, menuLoading: Bool,
                   showSync: Bool, syncTitle: String, syncEnabled: Bool, syncLoading: Bool) {
        metrics = SidebarLayoutMetrics(fontScale: scale)
        if textView.string != message {
            textView.string = message
            textView.setSelectedRange(NSRange(location: message.utf16.count, length: 0))
        }
        textView.font = .systemFont(ofSize: 11.5 * scale)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        self.placeholder.stringValue = placeholder
        self.placeholder.font = textView.font
        self.placeholder.isHidden = !message.isEmpty
        fieldBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        showsCommit = showCommit
        showsSync = showSync
        commit.isHidden = !showCommit
        options.isHidden = !showCommit
        sync.isHidden = !showSync
        commit.configure(symbol: "checkmark", title: commitTitle, help: String(localized: "Commit staged changes (⌘Return)"),
                         scale: scale, enabled: canCommit, loading: commitLoading, primary: true)
        options.configure(symbol: "chevron.down", help: String(localized: "Commit Options"), scale: scale, loading: menuLoading)
        sync.configure(symbol: "arrow.triangle.2.circlepath", title: syncTitle, help: String(localized: "Pull remote commits, then push local ones"),
                       scale: scale, enabled: syncEnabled, loading: syncLoading, primary: true)
        needsLayout = true
    }

    private var buttonHeight: CGFloat { metrics.lineHeight(designedFontSize: 11, weight: .medium, minimum: 14) + 10 }
    private func fieldHeight(for width: CGFloat) -> CGFloat {
        let lineHeight = metrics.lineHeight(designedFontSize: 11.5, minimum: 15)
        textView.textContainer?.containerSize = NSSize(width: max(1, width - 16), height: .greatestFiniteMagnitude)
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            return max(lineHeight, ceil(layoutManager.usedRect(for: container).height)) + 12
        }
        return lineHeight + 12
    }
    func height(for width: CGFloat) -> CGFloat {
        fieldHeight(for: width) + (showsCommit ? buttonHeight + 6 : 0) + (showsSync ? buttonHeight + 6 : 0)
    }
    override func layout() {
        super.layout()
        let height = fieldHeight(for: bounds.width)
        fieldBackground.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        textView.frame = NSRect(x: 8, y: 6, width: max(0, bounds.width - 16), height: height - 12)
        placeholder.frame = NSRect(x: 8, y: 6, width: max(0, bounds.width - 16), height: metrics.lineHeight(designedFontSize: 11.5, minimum: 15))
        var y = height + 6
        if showsCommit {
            let menuWidth = metrics.slotSize(24)
            commit.frame = NSRect(x: 0, y: y, width: max(0, bounds.width - menuWidth - 4), height: buttonHeight)
            options.frame = NSRect(x: max(0, bounds.width - menuWidth), y: y, width: menuWidth, height: buttonHeight)
            y += buttonHeight + 6
        }
        if showsSync { sync.frame = NSRect(x: 0, y: y, width: bounds.width, height: buttonHeight) }
    }
    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        onChange?(textView.string)
    }
}

private func gitPanelTextHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
    ceil((text as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height)
}

private final class GitPanelMessageView: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var scale: CGFloat = 1
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        for label in [title, detail] { addSubview(label) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(title: String, detail: String, scale: CGFloat) {
        self.scale = scale
        self.title.stringValue = title
        self.title.font = .systemFont(ofSize: 10.5 * scale, weight: .medium)
        self.title.textColor = .systemPurple
        self.detail.stringValue = detail
        self.detail.font = .systemFont(ofSize: 9.5 * scale)
        self.detail.textColor = .secondaryLabelColor
        layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.08).cgColor
        needsLayout = true
    }
    func height(for width: CGFloat) -> CGFloat {
        gitPanelTextHeight(title.stringValue, font: title.font!, width: width - 16)
            + gitPanelTextHeight(detail.stringValue, font: detail.font!, width: width - 16) + 14
    }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 16)
        let titleHeight = gitPanelTextHeight(title.stringValue, font: title.font!, width: width)
        title.frame = NSRect(x: 8, y: 6, width: width, height: titleHeight)
        detail.frame = NSRect(x: 8, y: titleHeight + 8, width: width, height: max(0, bounds.height - titleHeight - 14))
    }
}

private final class GitPanelFailureView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let output = NSTextView()
    private let toggle = GitPanelButton()
    private let dismiss = GitPanelButton()
    private var scale: CGFloat = 1
    private var expanded = false
    var onToggle: (() -> Void)?
    var onDismiss: (() -> Void)?
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        output.isEditable = false
        output.isSelectable = true
        output.isRichText = false
        output.drawsBackground = false
        output.textContainerInset = .zero
        output.textContainer?.lineFragmentPadding = 0
        output.textContainer?.widthTracksTextView = true
        output.setAccessibilityLabel(String(localized: "Git Output"))
        toggle.onAction = { [weak self] in self?.onToggle?() }
        dismiss.onAction = { [weak self] in self?.onDismiss?() }
        for view in [title, output, toggle, dismiss] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(operation: GitStatusModel.Operation, isExpanded: Bool, scale: CGFloat) {
        self.scale = scale
        expanded = isExpanded
        title.stringValue = operation.statusLabel
        title.font = .systemFont(ofSize: 10.5 * scale, weight: .medium)
        title.textColor = .systemRed
        output.string = operation.output
        output.font = .monospacedSystemFont(ofSize: 9 * scale, weight: .regular)
        output.textColor = .secondaryLabelColor
        output.isHidden = !isExpanded
        toggle.configure(symbol: isExpanded ? "chevron.down" : "chevron.right",
                         help: isExpanded ? String(localized: "Hide Git Output") : String(localized: "Show Git Output"), scale: scale)
        toggle.isHidden = operation.output.isEmpty
        dismiss.configure(symbol: "xmark", help: String(localized: "Dismiss Git Error"), scale: scale)
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
        needsLayout = true
    }
    private var titleHeight: CGFloat { max(18, ceil(18 * scale)) }
    func height(for width: CGFloat) -> CGFloat {
        titleHeight + 12 + (expanded ? gitPanelTextHeight(output.string, font: output.font!, width: width - 16) + 6 : 0)
    }
    override func layout() {
        super.layout()
        let slot = ceil(18 * max(1, scale))
        dismiss.frame = NSRect(x: bounds.width - slot - 6, y: 6, width: slot, height: titleHeight)
        toggle.frame = NSRect(x: dismiss.frame.minX - slot, y: 6, width: slot, height: titleHeight)
        title.frame = NSRect(x: 8, y: 6, width: max(0, (toggle.isHidden ? dismiss.frame.minX : toggle.frame.minX) - 12), height: titleHeight)
        output.frame = NSRect(x: 8, y: titleHeight + 12, width: max(0, bounds.width - 16), height: max(0, bounds.height - titleHeight - 18))
    }
}

private final class GitPanelPlaceholderView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = GitPanelButton()
    private var scale: CGFloat = 1
    private var hasAction = false
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.alignment = .center
        detail.alignment = .center
        detail.isSelectable = true
        icon.setAccessibilityElement(false)
        for view in [icon, title, detail, button] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(icon: String, title: String, message: String, scale: CGFloat, actionTitle: String? = nil,
                   enabled: Bool = true, loading: Bool = false, action: (() -> Void)? = nil) {
        self.scale = scale
        self.icon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24 * scale, weight: .light))
        self.icon.contentTintColor = .tertiaryLabelColor
        self.title.stringValue = title
        self.title.font = .systemFont(ofSize: 11.5 * scale, weight: .medium)
        self.title.textColor = .secondaryLabelColor
        detail.stringValue = message
        detail.font = .systemFont(ofSize: 10 * scale)
        detail.textColor = .tertiaryLabelColor
        detail.isHidden = message.isEmpty
        hasAction = actionTitle != nil
        button.isHidden = !hasAction
        button.configure(symbol: "", title: actionTitle ?? "", help: actionTitle ?? "", scale: scale,
                         enabled: enabled, loading: loading)
        button.bezelStyle = .rounded
        button.isBordered = true
        button.onAction = action
        needsLayout = true
    }
    func height(for width: CGFloat) -> CGFloat {
        56 * max(1, scale) + gitPanelTextHeight(title.stringValue, font: title.font!, width: width)
            + (detail.isHidden ? 0 : gitPanelTextHeight(detail.stringValue, font: detail.font!, width: width) + 5)
            + (hasAction ? 34 * max(1, scale) : 0)
    }
    override func layout() {
        super.layout()
        let intrinsicHeight = height(for: bounds.width)
        var y = max(16, (bounds.height - intrinsicHeight) / 2 + 16)
        let iconSize = 24 * max(1, scale)
        icon.frame = NSRect(x: (bounds.width - iconSize) / 2, y: y, width: iconSize, height: iconSize)
        y += iconSize + 8
        let titleHeight = gitPanelTextHeight(title.stringValue, font: title.font!, width: bounds.width)
        title.frame = NSRect(x: 0, y: y, width: bounds.width, height: titleHeight)
        y += titleHeight + 5
        if !detail.isHidden {
            let height = gitPanelTextHeight(detail.stringValue, font: detail.font!, width: bounds.width)
            detail.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + 8
        }
        if hasAction {
            let width = min(bounds.width, ceil(button.intrinsicContentSize.width) + 16)
            button.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: 26 * max(1, scale))
        }
    }
}

struct GitPanelEntryCallbacks {
    var absolutePath = ""
    var isRemote = false
    var disabled = false
    var stageLoading = false
    var unstageLoading = false
    var discardLoading = false
    var reviewState: DiffReviewState?
    var openDiff: () -> Void = {}
    var openFile: () -> Void = {}
    var openToSide: () -> Void = {}
    var stage: () -> Void = {}
    var unstage: () -> Void = {}
    var discard: () -> Void = {}
    var toggleReview: () -> Void = {}
    var insertInTerminal: (() -> Void)?
}

final class GitPanelChangesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = RowButtonTableView()
    private var entries: [GitStatusModel.Entry] = []
    private var kind: GitPanelEntryKind = .unstaged
    private var metrics = SidebarLayoutMetrics(fontScale: 1)
    private var repositoryID = ""
    private var callbacks: ((GitStatusModel.Entry) -> GitPanelEntryCallbacks)?
    var requiredHeight: CGFloat { CGFloat(entries.count) * tableView.rowHeight }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.style = .fullWidth
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(activateSelectedRow)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.minWidth = 0
        tableView.addTableColumn(column)
        addSubview(tableView)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(entries: [GitStatusModel.Entry], kind: GitPanelEntryKind, scale: CGFloat, repositoryID: String,
                   callbacks: @escaping (GitStatusModel.Entry) -> GitPanelEntryCallbacks) {
        let metrics = SidebarLayoutMetrics(fontScale: scale)
        let selectedPath = tableView.selectedRow >= 0 && tableView.selectedRow < self.entries.count
            ? self.entries[tableView.selectedRow].path : nil
        let changedRepository = self.repositoryID != repositoryID
        let reload = self.entries != entries || self.kind != kind || self.metrics.fontScale != metrics.fontScale
        self.entries = entries
        self.kind = kind
        self.metrics = metrics
        self.repositoryID = repositoryID
        self.callbacks = callbacks
        tableView.rowHeight = metrics.lineHeight(designedFontSize: 11.5, minimum: 16) + 6
        if reload { tableView.reloadData() }
        let selected = changedRepository ? nil : selectedPath.flatMap { path in entries.firstIndex { $0.path == path } }
        if let selected { tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        else { tableView.deselectAll(nil) }
        updateVisibleRows()
        needsLayout = true
    }
    func resetSelection() { tableView.deselectAll(nil) }
    override func layout() {
        super.layout()
        tableView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: requiredHeight)
        tableView.tableColumns.first?.width = bounds.width
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GitRepositoryTableRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("gitChangeRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? GitPanelEntryRowView ?? GitPanelEntryRowView()
        cell.identifier = identifier
        configure(cell, row: row)
        return cell
    }
    private func configure(_ cell: GitPanelEntryRowView, row: Int) {
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        var callbacks = callbacks?(entry) ?? GitPanelEntryCallbacks()
        let openDiff = callbacks.openDiff
        callbacks.openDiff = { [weak self] in
            self?.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            openDiff()
        }
        cell.configure(entry: entry, kind: kind, scale: metrics.fontScale, callbacks: callbacks)
    }
    private func updateVisibleRows() {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound else { return }
        for index in range.location..<NSMaxRange(range) where index >= 0 && index < entries.count {
            if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? GitPanelEntryRowView { configure(cell, row: index) }
        }
    }
    @objc private func activateSelectedRow() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < entries.count else { return }
        callbacks?(entries[row]).openDiff()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { activateSelectedRow() }
        else { super.keyDown(with: event) }
    }
}

private final class GitPanelEntryRowView: NSView {
    private let open = GitPanelButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let directory = NSTextField(labelWithString: "")
    private let review = DiffReviewIndicatorButton()
    private let stage = GitPanelButton()
    private let discard = GitPanelButton()
    private var metrics = SidebarLayoutMetrics(fontScale: 1)
    private var showsReview = false
    private var showsStage = false
    private var showsDiscard = false
    private var hovered = false
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [statusLabel, name, directory] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityElement(false)
        }
        directory.lineBreakMode = .byTruncatingHead
        for view in [statusLabel, imageView, name, directory] { open.addSubview(view) }
        imageView.setAccessibilityElement(false)
        for view in [open, review, stage, discard] { addSubview(view) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(entry: GitStatusModel.Entry, kind: GitPanelEntryKind, scale: CGFloat, callbacks: GitPanelEntryCallbacks) {
        metrics = SidebarLayoutMetrics(fontScale: scale)
        let status: Character = kind == .merge ? "U" : kind == .staged ? entry.staged : entry.unstaged
        statusLabel.stringValue = String(status)
        statusLabel.font = .monospacedSystemFont(ofSize: 10 * scale, weight: .bold)
        statusLabel.textColor = Self.statusColor(status)
        imageView.image = MaterialFileIcon.image(forPath: callbacks.absolutePath, appearance: effectiveAppearance)
        imageView.alphaValue = status == "D" ? 0.6 : 1
        name.font = .systemFont(ofSize: 11.5 * scale)
        name.textColor = .secondaryLabelColor
        if status == "D" {
            name.attributedStringValue = NSAttributedString(string: entry.fileName, attributes: [
                .font: name.font!, .foregroundColor: NSColor.secondaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue
            ])
        } else { name.stringValue = entry.fileName }
        directory.stringValue = entry.directory
        directory.font = .systemFont(ofSize: 10 * scale)
        directory.textColor = .tertiaryLabelColor
        open.configure(symbol: "", help: entry.fileName + ", " + Self.statusName(status), scale: scale)
        open.onAction = callbacks.openDiff
        open.toolTip = callbacks.absolutePath
        showsReview = callbacks.reviewState != nil
        review.isHidden = !showsReview
        if let state = callbacks.reviewState { review.update(state: state, onToggle: callbacks.toggleReview) }
        let loading = callbacks.stageLoading || callbacks.unstageLoading || callbacks.discardLoading
        showsStage = !callbacks.disabled || loading
        showsDiscard = kind == .unstaged && showsStage
        stage.isHidden = !showsStage
        discard.isHidden = !showsDiscard
        let stageHelp = kind == .staged ? String(localized: "Unstage Changes")
            : kind == .merge ? String(localized: "Mark Resolved (Stage)") : String(localized: "Stage Changes")
        stage.configure(symbol: kind == .staged ? "minus" : "plus", help: stageHelp, scale: scale,
                        enabled: !callbacks.disabled, loading: kind == .staged ? callbacks.unstageLoading : callbacks.stageLoading)
        stage.onAction = kind == .staged ? callbacks.unstage : callbacks.stage
        discard.configure(symbol: "arrow.uturn.backward", help: String(localized: "Discard Changes"), scale: scale,
                          enabled: !callbacks.disabled, loading: callbacks.discardLoading)
        discard.onAction = callbacks.discard
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(GitPanelMenuItem(title: String(localized: "Open Changes"), enabled: !callbacks.isRemote, action: callbacks.openDiff))
        menu.addItem(GitPanelMenuItem(title: kind == .merge ? String(localized: "Open Conflicted File") : String(localized: "Open File"),
                                     enabled: !callbacks.isRemote, action: callbacks.openFile))
        menu.addItem(GitPanelMenuItem(title: String(localized: "Open File to the Side"), enabled: !callbacks.isRemote, action: callbacks.openToSide))
        if !callbacks.isRemote {
            menu.addItem(.separator())
            menu.addItem(GitPanelMenuItem(title: stageHelp, enabled: !callbacks.disabled,
                                         action: kind == .staged ? callbacks.unstage : callbacks.stage))
            if kind == .unstaged {
                let title = entry.isUntracked || entry.isWorktreeCopy ? String(localized: "Move to Trash…")
                    : entry.isWorktreeRename ? String(localized: "Undo Rename…") : String(localized: "Discard Changes…")
                menu.addItem(GitPanelMenuItem(title: title, enabled: !callbacks.disabled, action: callbacks.discard))
            }
            menu.addItem(.separator())
            menu.addItem(GitPanelMenuItem(title: String(localized: "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: callbacks.absolutePath)])
            })
        }
        menu.addItem(GitPanelMenuItem(title: String(localized: "Copy Path")) { GitPanelNSView.copyToPasteboard(callbacks.absolutePath) })
        menu.addItem(GitPanelMenuItem(title: String(localized: "Copy Relative Path")) { GitPanelNSView.copyToPasteboard(entry.path) })
        if let insert = callbacks.insertInTerminal {
            menu.addItem(GitPanelMenuItem(title: String(localized: "Insert Absolute Path in Terminal"), action: insert))
        }
        self.menu = menu
        open.menu = menu
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let slot = metrics.slotSize(18)
        var trailing = bounds.width - 8
        for (view, visible) in [(stage, showsStage), (discard, showsDiscard), (review, showsReview)] where visible {
            view.frame = NSRect(x: trailing - slot, y: (bounds.height - slot) / 2, width: slot, height: slot)
            trailing -= slot + 2
        }
        open.frame = NSRect(x: 8, y: 0, width: max(0, trailing - 8), height: bounds.height)
        let statusWidth = metrics.iconSize(12)
        let iconWidth = metrics.iconSize(13)
        statusLabel.frame = NSRect(x: 0, y: 0, width: statusWidth, height: bounds.height)
        imageView.frame = NSRect(x: statusWidth + 4, y: (bounds.height - iconWidth) / 2, width: iconWidth, height: iconWidth)
        let leading = statusWidth + iconWidth + 11
        let available = max(0, open.bounds.width - leading)
        let nameWidth = hovered ? available : min(available, ceil(name.intrinsicContentSize.width))
        name.frame = NSRect(x: leading, y: 0, width: nameWidth, height: bounds.height)
        directory.frame = NSRect(x: leading + nameWidth + 6, y: 0, width: max(0, available - nameWidth - 6), height: bounds.height)
        directory.isHidden = hovered
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: NSIntersectionRect(bounds, visibleRect),
            options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsLayout = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsLayout = true }
    private static func statusColor(_ status: Character) -> NSColor {
        switch status {
        case "M": .systemYellow
        case "A", "?": .systemGreen
        case "D": .systemRed
        case "R", "C": .systemBlue
        case "U": .systemPurple
        default: .secondaryLabelColor
        }
    }
    private static func statusName(_ status: Character) -> String {
        switch status {
        case "M": String(localized: "Modified")
        case "A": String(localized: "Added")
        case "?": String(localized: "Untracked")
        case "D": String(localized: "Deleted")
        case "R": String(localized: "Renamed")
        case "C": String(localized: "Copied")
        case "U": String(localized: "Conflict")
        default: String(localized: "Changed")
        }
    }
}
