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
    @StateObject private var fileTree = FileTreeModel()
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
        FileTreePanel(
            model: fileTree,
            search: manager.fileContentSearch,
            git: git,
            session: manager.selectedSession,
            isRemote: isProjectRemote,
            rootBadge: rootBadge,
            externalEditor: settings.externalEditor,
            currentFilePath: openFilePath,
            previewFile: { manager.previewFile($0) },
            openFile: { manager.openFile($0) },
            openToSide: { manager.openFileToSide($0) },
            onRename: { manager.fileRenamed(from: $0, to: $1) },
            refreshGitStatus: { git.refresh() },
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
        guard manager.isPanelVisible else { return }
        guard let project = manager.selectedProject,
              let session = project.selectedSession
        else {
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

private struct PanelHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .sidebarFont(size: 12, weight: .semibold)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .sidebarFont(size: 10)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - File tree

private struct FileTreePanel: View {
    @ObservedObject var model: FileTreeModel
    /// Owns the file-content search state and outlives this panel; the tree
    /// is hidden while a search row is active.
    @ObservedObject var search: FileContentSearchModel
    @ObservedObject var git: GitStatusModel
    let session: TerminalSession?
    let isRemote: Bool
    /// Set while the tree follows the terminal's foreground job into another
    /// checkout, so the header says why the root moved.
    let rootBadge: (text: String, description: String)?
    let externalEditor: ExternalEditor
    let currentFilePath: String?
    let previewFile: (String) -> Void
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void
    let refreshGitStatus: () -> Void
    let openSearchResult: (FileContentSearchModel.Match) -> Void

    @Environment(\.sidebarFontScale) private var fontScale

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PanelHeader(title: model.rootName, subtitle: model.rootSubtitle)
                if let rootBadge {
                    Text(verbatim: rootBadge.text)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.09))
                        )
                        .accessibilityLabel(rootBadge.description)
                }
                if !model.isRemote {
                    Button {
                        search.toggle()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .sidebarFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Search File Contents"))
                    .accessibilityLabel(String(localized: "Search File Contents"))
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.rootPath)])
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .sidebarFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            if search.isActive {
                FileContentSearchPanelView(
                    model: search,
                    fontScale: fontScale,
                    openResult: openSearchResult
                )
            } else {
                if model.isRemote, let remoteError = model.remoteError {
                    remoteErrorBanner(remoteError)
                }

                ScrollView {
                    LazyVStack(spacing: 1) {
                        if model.isRemote, model.isRemoteLoading, model.items.isEmpty {
                            Text(String(localized: "Loading remote directory…"))
                                .sidebarFont(size: 11)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 6)
                                .padding(.top, 4)
                        }
                        ForEach(model.items) { item in
                            FileTreeRow(
                                model: model, git: git, item: item, session: session,
                                isRemote: isRemote,
                                externalEditor: externalEditor,
                                currentFilePath: currentFilePath,
                                previewFile: previewFile, openFile: openFile,
                                openToSide: openToSide, onRename: onRename,
                                refreshGitStatus: refreshGitStatus
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// Why a remote listing is missing or stale: SSH failed, the directory
    /// doesn't exist, or the host is unreachable. Offers a retry for the root.
    private func remoteErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .sidebarFont(size: 10)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(verbatim: message)
                .sidebarFont(size: 10.5)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Button(String(localized: "Retry")) {
                model.retryRemoteRoot()
            }
            .buttonStyle(.plain)
            .sidebarFont(size: 10.5, weight: .medium)
            .foregroundStyle(Color(nsColor: Theme.accent))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct FileTreeRow: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var git: GitStatusModel
    @ObservedObject private var themeChanges = Theme.changes
    let item: FileTreeModel.Item
    let session: TerminalSession?
    let isRemote: Bool
    let externalEditor: ExternalEditor
    let currentFilePath: String?
    let previewFile: (String) -> Void
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void
    let refreshGitStatus: () -> Void

    @State private var isHovering = false
    @State private var editingName = ""
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { model.renamingPath == item.path }

    /// The file open in the active tab, so it reads as selected in the tree.
    private var isCurrent: Bool { !item.isDirectory && item.path == currentFilePath }

    private var gitDecoration: GitStatusModel.FileDecoration? {
        git.fileDecoration(for: item.path, isDirectory: item.isDirectory)
    }

    var body: some View {
        if item.isDraft {
            // The transient new-file/folder input row: no hover/menu, no
            // backing file to act on.
            draftRow
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isCurrent ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.05) : .clear))
                )
                .onHover { isHovering = $0 }
                .contextMenu { rowMenu }
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        if model.isRemote {
            // No local file backs a remote row: only navigation and the path
            // itself make sense. Editing comes in a later slice.
            if item.isDirectory {
                Button("cd Here") {
                    session?.sendCommand("cd " + shellQuote(item.path) + "\n")
                }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        } else {
            if !item.isDirectory {
                Button("Open") {
                    openFile(item.path)
                }
                Button("Open to the Side") {
                    openToSide(item.path)
                }
            }
            Button(externalEditor.openTitle) {
                externalEditor.open(URL(fileURLWithPath: item.path))
            }
            .disabled(!externalEditor.isAvailable)
            Button("Open in Default App") {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
            if item.isDirectory {
                Button("cd Here") {
                    session?.sendCommand("cd " + shellQuote(item.path) + "\n")
                }
                Divider()
                Button("New File…") {
                    model.beginNewFile(in: item.path)
                }
                Button("New Folder…") {
                    model.beginNewFolder(in: item.path)
                }
            }
            Divider()
            Button("Rename") {
                model.beginRename(item)
            }
            Button("Move to Trash", role: .destructive) {
                model.moveToTrash(item)
                refreshGitStatus()
            }
        }
    }

    /// Commits an inline rename and, when the file actually moved, tells the
    /// app to follow it in any open tabs. Guarded by `isRenaming` so the
    /// commit-on-blur that fires right after Enter/Escape is a no-op.
    private func commitRename() {
        guard isRenaming else { return }
        let oldPath = item.path
        if let newPath = model.rename(item, to: editingName) {
            onRename(oldPath, newPath)
            refreshGitStatus()
        }
    }

    /// Commits the inline new-file/folder input, opening a newly created file.
    /// Guarded so the commit-on-blur after Enter/Escape is a no-op.
    private func commitDraft() {
        guard item.isDraft, model.draft != nil else { return }
        if let created = model.commitDraft(name: editingName) {
            openFile(created)
        }
        refreshGitStatus()
    }

    @ViewBuilder
    private var content: some View {
        if isRenaming {
            renameRow
        } else {
            rowButton
        }
    }

    @ViewBuilder
    private var rowButton: some View {
        // Remote rows have no local file URL to drag out.
        if model.isRemote {
            rowLabel
                .buttonStyle(.plain)
                .accessibilityLabel(fileAccessibilityLabel)
        } else {
            rowLabel
                .buttonStyle(.plain)
                .accessibilityLabel(fileAccessibilityLabel)
                // Drag a row out as a file URL: onto the terminal (which
                // inserts its path) or into Finder and other apps. A click
                // still opens/toggles; the drag only begins once the pointer
                // moves.
                .onDrag {
                    NSItemProvider(object: URL(fileURLWithPath: item.path) as NSURL)
                }
        }
    }

    private var rowLabel: some View {
        Button {
            if !item.isDirectory && isCommandClick {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            } else if item.isDirectory {
                model.toggle(item)
            } else {
                previewFile(item.path)
            }
        } label: {
            HStack(spacing: 5) {
                leadingGlyphs
                Text(item.name)
                    .sidebarFont(size: 11.5)
                    .foregroundStyle(fileNameColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let gitDecoration {
                    Text(gitDecoration.badge)
                        .sidebarFont(size: 9, weight: .semibold, design: .monospaced)
                        .foregroundStyle(gitDecoration.color)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, CGFloat(item.depth) * 12 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var isCommandClick: Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp else { return false }
        return event.modifierFlags.contains(.command)
    }

    private var fileNameColor: Color {
        if let gitDecoration { return gitDecoration.color }
        return item.name.hasPrefix(".") ? Color.secondary.opacity(0.55) : .secondary
    }

    private var fileAccessibilityLabel: String {
        guard let gitDecoration else { return item.name }
        return item.name + ", " + gitDecoration.accessibilityName
    }

    private var renameRow: some View {
        HStack(spacing: 5) {
            leadingGlyphs
            nameField(String(localized: "Name"))
                .onSubmit { commitRename() }
                .onKeyPress(.escape) { model.cancelRename(); return .handled }
                .onChange(of: fieldFocused) {
                    // Commit on blur (Finder-style); unchanged names no-op.
                    if !fieldFocused { commitRename() }
                }
        }
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .onAppear {
            editingName = item.name
            focusField()
        }
    }

    private var draftRow: some View {
        HStack(spacing: 5) {
            leadingGlyphs
            nameField(item.isDirectory
                ? String(localized: "Folder name")
                : String(localized: "File name"))
                .onSubmit { commitDraft() }
                .onKeyPress(.escape) { model.cancelDraft(); return .handled }
                .onChange(of: fieldFocused) {
                    // Blur commits a typed name, cancels an empty one (VS Code).
                    if !fieldFocused { commitDraft() }
                }
        }
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .onAppear {
            editingName = ""
            focusField()
        }
    }

    private func nameField(_ placeholder: String) -> some View {
        TextField(placeholder, text: $editingName)
            .textFieldStyle(.plain)
            .sidebarFont(size: 11.5)
            .foregroundStyle(.primary)
            .focused($fieldFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: Theme.background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(nsColor: Theme.accent).opacity(0.7), lineWidth: 1)
            )
    }

    /// Grab focus on the next runloop tick — a context menu is still
    /// dismissing when the input row appears, and a synchronous focus can be
    /// stolen back as it tears down.
    private func focusField() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var leadingGlyphs: some View {
        Group {
            if item.isDirectory && !item.isDraft {
                Image(systemName: "chevron.right")
                    .sidebarFont(size: 8, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(model.isExpanded(item) ? 90 : 0))
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            if item.isDirectory {
                Image(systemName: "folder.fill")
                    .sidebarFont(size: 10)
                    .foregroundStyle(Color(nsColor: Theme.accent).opacity(0.8))
                    .frame(width: 14)
            } else {
                MaterialFileIconView(path: item.path, size: 14)
                    .frame(width: 14)
            }
        }
    }
}

private extension GitStatusModel.FileDecoration {
    var badge: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .untracked: "U"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .conflict: "!"
        case .ignored: "I"
        }
    }

    var accessibilityName: String {
        switch self {
        case .modified: String(localized: "Modified")
        case .added: String(localized: "Added")
        case .untracked: String(localized: "Untracked")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .copied: String(localized: "Copied")
        case .conflict: String(localized: "Conflict")
        case .ignored: String(localized: "Ignored")
        }
    }

    var color: Color {
        switch self {
        case .modified: Color(red: 0.82, green: 0.60, blue: 0.13)
        case .added, .untracked: Color(red: 0.25, green: 0.73, blue: 0.31)
        case .deleted: Color(red: 1.0, green: 0.48, blue: 0.45)
        case .renamed, .copied: Color(red: 0.35, green: 0.65, blue: 1.0)
        case .conflict: Color(red: 0.74, green: 0.55, blue: 1.0)
        case .ignored: Color.secondary.opacity(0.55)
        }
    }
}

// MARK: - Git panel

private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
