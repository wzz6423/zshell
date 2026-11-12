//
//  RightSidebarView.swift
//  zshell
//

import AppKit
import SwiftUI

/// Right sidebar: hidden by default, toggled from the terminal's corner
/// button or ⇧⌘B. Files/Git switch via tabs along its top, otty-style.
struct RightSidebarView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var git: GitStatusModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    private var fileTree: FileTreeModel { manager.fileTree }
    @StateObject private var info = SessionInfoModel()
    @State private var applicationIsActive = NSApp.isActive
    /// Which rule produced the current panel root; drives the Files badge.
    @State private var rootSource = Project.PanelRootSource.shell
    @AppStorage("rightSidebarWidth") private var width: Double = 240

    private var sidebarWidthRange: ClosedRange<Double> {
        (180 * settings.interfaceScale)...(500 * settings.interfaceScale)
    }

    private var defaultSidebarWidth: Double {
        240 * settings.interfaceScale
    }

    private var pollsSelectedPanel: Bool {
        manager.isPanelVisible
            && applicationIsActive
            && manager.panelTab != .git
    }

    /// Whether the selected project lives on a remote host; panels use it to
    /// hide repository-mutation and local-disk affordances.
    private var isProjectRemote: Bool {
        manager.selectedProject?.isRemote == true
    }

    /// Every terminal in the selected project can change the same repository.
    /// Watching only these counters avoids reacting to prompt/input lifecycle
    /// updates while still catching commands completed in an unfocused pane.
    private var commandCompletionSequences: [UUID: UInt64] {
        Dictionary(uniqueKeysWithValues:
            manager.selectedProject?.sessions.map {
                ($0.id, $0.commandLifecycle.completionSequence)
            } ?? []
        )
    }

    /// Path of the file in the focused pane, so the tree can highlight it.
    /// Reactive: focus/selection is published up through the project to `manager`.
    private var openFilePath: String? {
        if case .file(let file)? = manager.selectedProject?.focusedContent {
            return file.path
        }
        return nil
    }

    /// The panel matching the selected tab. Split out of `body` so the type
    /// checker handles three small expressions instead of one ViewBuilder
    /// holding every panel's full argument list.
    @ViewBuilder
    private var activePanel: some View {
        switch manager.panelTab {
        case .files:
            filesPanel
        case .git:
            gitPanel
        case .info:
            infoPanel
        }
    }

    private var filesPanel: some View {
        FileTreePanelView(
            manager: manager,
            git: git,
            rootBadge: rootBadge,
            currentFilePath: openFilePath,
            fontScale: CGFloat(settings.sidebarFontSize / AppSettings.defaultSidebarFontSize
                * settings.interfaceScale),
            openSearchResult: { openSearchResult($0) }
        )
    }

    private var gitPanel: some View {
        GitPanelView(
            model: git,
            session: manager.selectedSession,
            isRemote: isProjectRemote,
            fontScale: CGFloat(settings.sidebarFontSize / AppSettings.defaultSidebarFontSize
                * settings.interfaceScale),
            openFile: { manager.openFile($0) },
            openToSide: { manager.openFileToSide($0) },
            openDiff: { entry, staged in
                manager.openDiff(
                    repoRoot: git.repoRoot,
                    path: entry.path,
                    staged: staged,
                    untracked: entry.isUntracked,
                    origPath: entry.origPath
                )
            },
            openCommitDiff: { commit, file in
                manager.openCommitDiff(
                    repoRoot: git.repoRoot,
                    path: file.path,
                    commitHash: commit.hash,
                    parentHash: commit.parentHash,
                    status: file.status,
                    origPath: file.originalPath
                )
            },
            openWorktree: { manager.openWorktreeSession(at: $0) }
        )
    }

    private var infoPanel: some View {
        SessionInfoPanel(
            model: info,
            session: manager.selectedSession,
            remoteProject: isProjectRemote ? manager.selectedProject : nil,
            externalEditor: settings.externalEditor,
            showsVimHints: settings.vimCommandHints,
            fontScale: CGFloat(settings.sidebarFontSize / AppSettings.defaultSidebarFontSize
                * settings.interfaceScale)
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if manager.isPanelVisible {
                RightSidebarDivider(backgroundColor: Theme.sidebar, dividerColor: Theme.divider)
                    .frame(width: 1)

                VStack(spacing: 0) {
                    tabBar
                    activePanel
                }
                .frame(width: width)
                .background(Color(nsColor: Theme.sidebar))
            }
        }
        .overlay(alignment: .leading) {
            if manager.isPanelVisible {
                SidebarResizeHandle(
                    edge: .leading,
                    width: $width,
                    range: sidebarWidthRange,
                    defaultWidth: defaultSidebarWidth,
                    fontSize: settings.sidebarFontSize
                )
            }
        }
        .onAppear { syncModels() }
        // Files and process information remain live while visible. Git is
        // event-driven: terminal/Git command completion and app activation
        // refresh it without a repeating main-run-loop source.
        .task(id: pollsSelectedPanel) {
            guard pollsSelectedPanel else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                syncModels()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            applicationIsActive = true
            syncModels()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification
        )) { _ in
            applicationIsActive = false
        }
        .onChange(of: commandCompletionSequences) {
            syncModels()
        }
        .onChange(of: manager.isPanelVisible) { syncModels() }
        .onChange(of: manager.panelTab) { syncModels() }
        .onChange(of: manager.selectedSession?.id) { syncModels() }
        // A `cd` in the terminal publishes the new cwd immediately (OSC 7 →
        // session.workingDirectory); resync at once so automatically rooted
        // panels follow the terminal without waiting for another event.
        .onChange(of: manager.selectedSession?.workingDirectory) { syncModels() }
        // Same for pinning/unpinning the project directory.
        .onChange(of: manager.selectedProject?.customDirectory) { syncModels() }
        .environment(
            \.sidebarFontScale,
            CGFloat(
                settings.sidebarFontSize / AppSettings.defaultSidebarFontSize
                    * settings.interfaceScale
            )
        )
        // Native button and control labels without a designed hierarchy use
        // the configured base size directly.
        .environment(\.font, .system(size: CGFloat(settings.sidebarFontSize * settings.interfaceScale)))
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(
                .info,
                systemImage: "info.circle",
                title: String(localized: "Info"),
                help: String(localized: "Info (⇧⌘I)")
            )
            tabButton(
                .files,
                systemImage: "folder",
                title: String(localized: "Files"),
                help: String(localized: "Files (⇧⌘E)")
            )
            tabButton(
                .git,
                systemImage: "arrow.triangle.branch",
                title: String(localized: "Git"),
                help: String(localized: "Git (⇧⌘G)")
            )
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func tabButton(_ panel: RightPanel, systemImage: String, title: String, help: String) -> some View {
        let isActive = manager.panelTab == panel
        return Button {
            manager.panelTab = panel
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .sidebarFont(size: 10, weight: .medium)
                Text(title)
                    .sidebarFont(size: 11, weight: .regular)
            }
            .foregroundStyle(isActive ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.primary.opacity(0.12) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "Selected" : "Not selected")
    }

    private func panelTitle(_ panel: RightPanel) -> String {
        switch panel {
        case .files: String(localized: "Files")
        case .git: String(localized: "Git")
        case .info: String(localized: "Info")
        }
    }

    private func syncModels() {
        guard manager.isPanelVisible else {
            if manager.fileTree.rootPath.isEmpty == false { manager.syncFileTree() }
            return
        }
        guard let project = manager.selectedProject,
              let session = project.selectedSession
        else {
            fileTree.configureRemote(nil)
            fileTree.sync(root: "")
            // An empty project has no shell to describe; drop whatever the
            // previous selection left behind, so a remote host's PIDs never
            // show up as signalable local rows.
            info.sync(root: "", projectRoot: "", projectRootSource: .shell,
                      shellName: "", shellPid: nil)
            return
        }
        guard !project.isRemote else {
            // Remote projects: the file tree runs `ls` over SSH against the
            // declared endpoint, rooted at the project's remote directory.
            // Git is driven solely by ContentView.syncGit, which already
            // configured the endpoint and remote root — syncing git here
            // with a local root would clobber that.
            fileTree.configureRemote(project.remoteEndpoint)
            fileTree.sync(root: project.remoteEndpoint == nil ? "" : project.remoteDirectory ?? "~")
            // A shared session's processes live on its host; a plain SSH
            // terminal only runs the local ssh client, so it has none to list.
            let remote = session.remoteConnection.map {
                SessionInfoModel.RemoteSource(host: $0.host, directory: $0.projectDirectory, sessionID: $0.sessionID)
            }
            info.sync(
                root: "", projectRoot: "",
                projectRootSource: .shell,
                shellName: "", shellPid: nil,
                remote: manager.panelTab == .info ? remote : nil
            )
            return
        }
        fileTree.configureRemote(nil)
        let cwd = session.currentDirectoryPath
        // Files and Git anchor to the project directory — pinned when the
        // user set one, else the repository the session is working in — so
        // they don't re-root as the terminal cds around a repo; Info
        // describes the shell itself, showing its live cwd next to that root.
        // An agent that moves to its own worktree changes only its own
        // process directory, so the foreground job's cwd is passed in too.
        let (root, source) = project.panelRoot(
            followingSessionAt: cwd, foregroundAt: session.foregroundDirectoryPath
        )
        if rootSource != source { rootSource = source }
        // The content search anchors to the same panel root as the tree; a
        // root change cancels a running grep and drops results that belong
        // to the old root.
        manager.fileContentSearch.sync(root: root)
        switch manager.panelTab {
        case .files:
            fileTree.sync(root: root)
        case .git:
            break
        case .info:
            info.sync(
                root: cwd, projectRoot: root, projectRootSource: source,
                shellName: session.shellName, shellPid: session.shellPid
            )
        }
    }

    /// Text badge for the Files header while the panels follow the foreground
    /// job instead of the shell — the agent's worktree in the common case, a
    /// plain "job" when it moved somewhere that isn't a linked worktree.
    /// The label and its spoken description travel together so neither is
    /// assembled from translated fragments.
    private var rootBadge: (text: String, description: String)? {
        guard case .foreground(let isWorktree) = rootSource else { return nil }
        if isWorktree {
            return (
                String(
                    localized: "worktree",
                    comment: "Files header badge: the panels follow a Git worktree the terminal’s foreground job moved to."
                ),
                String(localized: "Following the terminal job’s worktree")
            )
        }
        return (
            String(
                localized: "job",
                comment: "Files header badge: the panels follow a directory the terminal’s foreground job moved to, outside any worktree of the shell’s repository."
            ),
            String(localized: "Following the terminal job’s directory")
        )
    }

    /// Opens a search hit through the same `Project.openFile` path the file
    /// tree uses, revealing the matched line: the grep line number maps to a
    /// caret offset off the main thread first. A hit whose line can't be
    /// mapped (unreadable or oversized file) still opens the file.
    private func openSearchResult(_ match: FileContentSearchModel.Match) {
        guard let project = manager.selectedProject,
              !manager.fileContentSearch.rootPath.isEmpty
        else { return }
        let root = manager.fileContentSearch.rootPath
        let path = (root as NSString).appendingPathComponent(match.path)
        Task { @MainActor in
            let location = await FileContentSearchModel.lineStartLocation(
                line: match.line, filePath: path
            )
            if let location {
                var state = EditorState()
                state.selectionLocation = location
                state.selectionLength = 0
                state.revealSelection = true
                project.openFile(path, editorState: state)
            } else {
                project.openFile(path)
            }
        }
    }
}

// MARK: - Shared panel chrome

private struct RightSidebarDivider: NSViewRepresentable {
    let backgroundColor: NSColor
    let dividerColor: NSColor

    func makeNSView(context: Context) -> RightSidebarDividerNSView {
        RightSidebarDividerNSView(frame: .zero)
    }

    func updateNSView(_ view: RightSidebarDividerNSView, context: Context) {
        view.backgroundColor = backgroundColor
        view.dividerColor = dividerColor
        view.needsDisplay = true
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: RightSidebarDividerNSView,
        context: Context
    ) -> CGSize? {
        CGSize(width: 1, height: proposal.height ?? 0)
    }
}

private final class RightSidebarDividerNSView: NSView {
    var backgroundColor = Theme.sidebar
    var dividerColor = Theme.divider
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 默认分隔色是半透明的，先铺侧栏底色，避免透明窗口在交界处露出桌面。
        backgroundColor.setFill()
        bounds.fill()
        dividerColor.setFill()
        bounds.fill(using: .sourceOver)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
