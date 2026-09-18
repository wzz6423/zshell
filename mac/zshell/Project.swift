//
//  Project.swift
//  zshell
//

import AppKit
import Combine
import Foundation

/// A project groups tabs and appears as one row in the left sidebar. Each tab
/// is a recursive split layout of terminal, file, browser, and diff panes; see
/// `PaneTab`. It always starts with one session; closing the last tab leaves
/// the project open but empty — only the explicit "Close Project" action (see
/// `TerminalManager.close(_:)`) removes it from the manager.
@MainActor
final class Project: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    let location: ProjectLocation

    /// User-assigned name; when nil the project title follows the
    /// selected session's terminal title.
    @Published var customName: String?
    @Published var isPinned: Bool
    @Published var markerColor: ProjectTabMarkerColor?
    /// User-pinned project directory ("Set Project Directory…" on the
    /// project row). While it exists, the file tree and git panels anchor
    /// here. Nil means automatic, following the terminal's foreground
    /// repository and working directory (see `panelRoot(followingSessionAt:)`).
    @Published var customDirectory: String?
    /// The sidebar group this project sits under, nil when ungrouped. The
    /// group's kind decides where new terminals of the project start: a
    /// folder group starts them in its folder (the group's directory sits
    /// behind an explicit project directory in the chain below).
    @Published var groupID: UUID?
    /// Launch configuration inherited by terminals created after it changes.
    /// Existing PTYs intentionally keep the environment they started with.
    @Published var launchSettings = TerminalLaunchSettings()
    @Published var tabs: [PaneTab] = []
    @Published private(set) var tabGroups: [SessionTabGroup] = []
    private var isRestoringTabs = false
    @Published var selectedTabID: UUID? {
        didSet {
            if !isRestoringTabs { revealSelectedTabGroup() }
            guard selectedTabID != oldValue, let selectedTabID else { return }
            recentTabIDs.removeAll { $0 == selectedTabID }
            recentTabIDs.insert(selectedTabID, at: 0)
        }
    }

    /// Tab IDs newest-used first. Kept here rather than in the switcher
    /// because every way of reaching a tab — strip click, Ctrl-number,
    /// opening a file — counts as a use.
    private var recentTabIDs: [UUID] = []

    private let fallbackName: String
    private weak var manager: TerminalManager?
    /// Sessions publish their own changes (title, directory); re-publish them
    /// so the project name and views observing the project stay current.
    private var sessionObservations: [UUID: AnyCancellable] = [:]
    /// Tabs publish layout changes (splits, focus, resize); re-publish them so
    /// the strip re-renders and autosave fires.
    private var tabObservations: [UUID: AnyCancellable] = [:]
    /// Browser navigation changes the tab's automatic title and persisted URL.
    /// Re-publish it through the project just like a terminal's live title and
    /// working directory.
    private var browserObservations: [UUID: AnyCancellable] = [:]

    /// Set by the owning `TerminalManager`. Invoked when a user action closes
    /// a terminal session — ⌘W, a tab close, Close Others / to the Right /
    /// All — so the manager can offer "Reopen Closed Session". Paths that
    /// tear down a whole project or the app (`TerminalManager.close(_:)`,
    /// window close, quit) terminate sessions without this: there is no
    /// single closed session there for the command to undo.
    var onSessionClosed: ((ClosedSessionRecord) -> Void)?

    /// Pass `createInitialSession: false` when restoring a saved project;
    /// the caller then rebuilds the tabs itself.
    init(
        fallbackName: String,
        manager: TerminalManager,
        location: ProjectLocation = .local,
        isPinned: Bool = false,
        createInitialSession: Bool = true
    ) {
        self.fallbackName = fallbackName
        self.manager = manager
        self.location = location
        self.isPinned = isPinned
        if case .ssh = location {
            remoteConnectionState = .checking
        }
        if createInitialSession {
            newSession()
        }
    }

    var isRemote: Bool { location.isRemote }

    /// The directory the project's sidebar group hands to new terminals
    /// (home for a plain group, its folder for a folder group); nil when the
    /// project is ungrouped or belongs to a group that no longer exists.
    private var groupSessionDirectory: String? {
        manager?.projectGroup(id: groupID)?.sessionDirectory
    }

    /// The declared endpoint for SSH projects, nil for local projects.
    var remoteEndpoint: SSHEndpoint? {
        if case .ssh(let endpoint, _, _, _) = location { return endpoint }
        return nil
    }

    /// The directory sessions start in on the remote host, nil when unset.
    var remoteDirectory: String? {
        if case .ssh(_, let directory, _, _) = location { return directory }
        return nil
    }

    /// Result of the creation-time connectivity probe. Meaningful only for
    /// SSH projects; local projects default to `.connected`.
    @Published private(set) var remoteConnectionState: RemoteConnectionState = .connected

    /// Records the connectivity probe result (see `TerminalManager`).
    func finishRemoteConnectionProbe(_ state: RemoteConnectionState) {
        remoteConnectionState = state
    }

    var name: String {
        if let customName = Self.normalizedCustomName(customName) {
            return customName
        }
        guard let title = selectedSession?.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return fallbackName
        }
        return title
    }

    /// Manual project names are user-authored labels, not terminal protocol
    /// payloads. Normalize only surrounding whitespace.
    static func normalizedCustomName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Every terminal session across every pane in every tab.
    var sessions: [TerminalSession] {
        tabs.flatMap(\.sessions)
    }

    var selectedTab: PaneTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Tabs by recency of use, selected first. Tabs not yet selected this
    /// session trail in strip order, so the sequence covers every tab even
    /// before any switching has happened.
    var tabsByRecency: [PaneTab] {
        var seen = Set<UUID>()
        var ordered: [PaneTab] = []
        func add(_ tab: PaneTab) {
            guard seen.insert(tab.id).inserted else { return }
            ordered.append(tab)
        }
        if let selectedTab { add(selectedTab) }
        for id in recentTabIDs {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            add(tab)
        }
        tabs.forEach(add)
        return ordered
    }

    /// Drops recorded recency, leaving strip order behind the selected tab.
    /// Restoring a window selects each tab as it is rebuilt; without this the
    /// order would just mirror the rebuild.
    func resetRecency() {
        recentTabIDs = selectedTabID.map { [$0] } ?? []
    }

    /// Content of the focused pane in the selected tab.
    var focusedContent: PaneContent? {
        selectedTab?.focusedContent
    }

    var hasFiles: Bool {
        tabs.contains { $0.allContents.contains { $0.isFile } }
    }

    var hasDiffs: Bool {
        tabs.contains { $0.allContents.contains { $0.isDiff } }
    }

    /// Every diff shown anywhere, paired with the id of its containing tab so
    /// the content view can tell which one is currently on screen.
    var diffPlacements: [(diff: DiffTab, tabID: UUID)] {
        tabs.flatMap { tab in tab.diffs.map { (diff: $0, tabID: tab.id) } }
    }

    /// The focused terminal session; while a file, browser, or diff pane is
    /// focused it has no directory of its own, so panels that need a working
    /// directory (file tree, git, info) track a terminal that does: one sharing
    /// the tab (a split), else the session the content was opened from (the
    /// tab's `contextSession`), else the project's first session.
    var selectedSession: TerminalSession? {
        if case .session(let session)? = focusedContent {
            return session
        }
        return selectedTab?.sessions.first
            ?? selectedTab?.contextSession
            ?? sessions.first
    }

    /// Whether the selected tab's focused pane can be split (false for diffs).
    var canSplit: Bool {
        selectedTab?.canSplit ?? false
    }

    // MARK: - Project directory

    /// Which rule produced the panel root, so labels can describe it
    /// truthfully instead of just saying "automatic".
    enum PanelRootSource: Equatable {
        /// The directory pinned on the project row.
        case pinned
        /// The repository the shell itself sits in.
        case shell
        /// The repository the terminal's foreground job sits in — a coding
        /// agent that moved to another checkout of the same project. Whether
        /// that checkout is a linked worktree is resolved here, once per
        /// refresh, so views can label it without touching the disk.
        case foreground(isWorktree: Bool)
    }

    /// Root for the file tree and git panels: the pinned directory when the
    /// user set one (and it still exists on disk), else the repository the
    /// terminal's foreground job moved to (an agent's worktree), else the
    /// closest git repository containing `cwd`, else `cwd` itself — the
    /// follow-the-terminal behavior used before projects had a directory.
    /// Everything but the pin is re-derived on every call, so the panels
    /// track the session in and out of repositories without sticking.
    func panelRoot(
        followingSessionAt cwd: String, foregroundAt foregroundCwd: String? = nil
    ) -> (root: String, source: PanelRootSource) {
        if let pinned = customDirectory, FileManager.default.fileExists(atPath: pinned) {
            return (pinned, .pinned)
        }
        let shellRoot = Self.closestGitRepository(containing: cwd) ?? cwd
        // Only a *different repository* re-roots the panels. A foreground job
        // running in a subdirectory of the shell's own checkout resolves to
        // the same root and is ignored, which keeps the file tree from
        // collapsing its expanded rows every time a command runs.
        if let foregroundCwd,
           let foregroundRoot = Self.closestGitRepository(containing: foregroundCwd),
           foregroundRoot != shellRoot {
            return (foregroundRoot, .foreground(isWorktree: Self.isLinkedWorktree(foregroundRoot)))
        }
        return (shellRoot, .shell)
    }

    /// Whether `root` is a linked worktree rather than a normal checkout: its
    /// `.git` is a file pointing into the main repository's `worktrees`
    /// directory (a submodule's points into `modules` instead).
    private static func isLinkedWorktree(_ root: String) -> Bool {
        let gitPath = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let contents = try? String(contentsOfFile: gitPath, encoding: .utf8)
        else { return false }
        return contents.contains("/worktrees/")
    }

    /// The directory of the nearest enclosing git repository: walks up from
    /// `path` looking for a `.git` entry — a directory in normal checkouts,
    /// a file in worktrees and submodules.
    private static func closestGitRepository(containing path: String) -> String? {
        var dir = (path as NSString).standardizingPath
        guard dir.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { return nil }
            dir = parent
        }
    }

    // MARK: - Sessions

    /// When no directory is given, a local session starts in the pinned
    /// project directory, then the group's default, then the current
    /// session's working directory (home when none is known). A manual
    /// project directory is an explicit choice for future terminals.
    @discardableResult
    func newSession(
        directory: String? = nil,
        commandArguments: [String]? = nil,
        environmentPath: String? = nil,
        tabTitle: String? = nil
    ) -> TerminalSession {
        let session = makeSession(
            directory: directory,
            commandArguments: commandArguments,
            environmentPath: environmentPath,
            launchSettings: launchSettings
        )
        let tab = makeTab(content: .session(session))
        // Only a reopened session carries a title — the user-assigned name
        // of the tab it was closed in; a plain new session has none.
        tab.customName = Project.normalizedCustomName(tabTitle)
        insertNextToSelected(tab)
        selectedTabID = tab.id
        return session
    }

    /// Builds a session wired for exit + change observation, without placing
    /// it in a tab — shared by new tabs and splits. `restoredHistory` seeds the
    /// scrollback when reopening a saved session.
    private func makeSession(
        directory: String? = nil,
        restoredHistory: String? = nil,
        commandArguments: [String]? = nil,
        environmentPath: String? = nil,
        launchSettings: TerminalLaunchSettings? = nil
    ) -> TerminalSession {
        let initialDirectory: String?
        let launchArguments: [String]?
        let additionalEnvironment: [String: String]
        let sshMaterial: SSHAuthenticationMaterial?
        switch location {
        case .local:
            initialDirectory = directory
                ?? customDirectory
                ?? groupSessionDirectory
                ?? selectedSession?.currentDirectoryPath
            launchArguments = commandArguments
            additionalEnvironment = [:]
            sshMaterial = nil
        case let .ssh(endpoint, remoteDirectory, authentication, credentialID):
            initialDirectory = nil
            do {
                let material = try authentication.makeMaterial(credentialID: credentialID)
                launchArguments = ["/usr/bin/ssh"]
                    + endpoint.terminalArguments(
                        remoteDirectory: remoteDirectory,
                        authentication: authentication,
                        identityFile: authentication.identityFile(material: material)
                    )
                var environment = material?.environment ?? [:]
                if authentication == .password {
                    // Saved passwords must use askpass even though an SSH
                    // terminal has a TTY, otherwise OpenSSH prompts instead.
                    environment["SSH_ASKPASS_REQUIRE"] = "force"
                    environment["DISPLAY"] = "zshell"
                }
                additionalEnvironment = environment
                sshMaterial = material
            } catch {
                // Do not let a missing Keychain item silently retry with an
                // unrelated agent identity. The probe reports the same error.
                launchArguments = [
                    "/bin/sh", "-c",
                    "printf '%s\\n' \"$1\" >&2; exit 1",
                    "zshell", error.localizedDescription,
                ]
                additionalEnvironment = [:]
                sshMaterial = nil
            }
        }
        let session = TerminalSession(
            initialDirectory: initialDirectory,
            restoredHistory: restoredHistory,
            commandArguments: launchArguments,
            environmentPath: environmentPath,
            launchSettings: launchSettings ?? self.launchSettings,
            additionalEnvironment: additionalEnvironment
        )
        register(session)
        if let sshMaterial {
            session.retainForSessionLifetime(sshMaterial)
            let existingOnExited = session.onExited
            session.onExited = { exitedSession in
                sshMaterial.cleanup()
                existingOnExited?(exitedSession)
            }
        }
        manager.map { session.transferHost(to: $0) }
        return session
    }

    func terminateAll() {
        for session in sessions {
            session.terminate()
        }
    }

    // MARK: - Splits

    func splitRight() { split(toward: .right) }
    func splitLeft() { split(toward: .left) }
    func splitDown() { split(toward: .bottom) }
    func splitUp() { split(toward: .top) }

    /// Splits the focused pane's rectangle on `edge` with a fresh terminal.
    /// No-op while a diff is focused.
    func split(toward edge: PaneDropEdge) {
        guard let tab = selectedTab, tab.canSplit else { return }
        let session = makeSession(
            launchSettings: launchSettings.applying(tab.launchSettingsOverride)
        )
        tab.split(Pane(content: .session(session)), toward: edge)
    }

    /// Creates a terminal beside an exact pane for the local automation API.
    /// The caller chooses whether focus follows; the safe default at the API
    /// boundary is false so background agents cannot disrupt the user.
    func automationSplitTerminal(
        beside targetPaneID: UUID,
        toward edge: PaneDropEdge,
        directory: String?,
        focus: Bool
    ) -> (tab: PaneTab, pane: Pane, session: TerminalSession)? {
        guard let tab = tabs.first(where: { $0.layout.contains(targetPaneID) }),
              let target = tab.allPanes.first(where: { $0.id == targetPaneID }),
              !target.content.isDiff
        else { return nil }

        let contextDirectory: String? = switch target.content {
        case .session(let session): session.currentDirectoryPath
        default: tab.sessions.first?.currentDirectoryPath
            ?? tab.contextSession?.currentDirectoryPath
        }
        let session = makeSession(
            directory: directory ?? contextDirectory,
            launchSettings: launchSettings.applying(tab.launchSettingsOverride)
        )
        let pane = Pane(content: .session(session))
        tab.split(
            pane,
            toward: edge,
            beside: targetPaneID,
            focusInserted: focus
        )
        if focus { selectedTabID = tab.id }
        return (tab, pane, session)
    }

    func focusLeft() { selectedTab?.focusLeft() }
    func focusRight() { selectedTab?.focusRight() }
    func focusUp() { selectedTab?.focusUp() }
    func focusDown() { selectedTab?.focusDown() }
    func focusNextPane() { selectedTab?.focusNext() }
    func focusPreviousPane() { selectedTab?.focusPrevious() }

    func togglePaneZoom() { selectedTab?.toggleZoom() }
    func equalizePanes() { selectedTab?.equalize() }
    func resizePaneUp() { selectedTab?.resizeUp() }
    func resizePaneDown() { selectedTab?.resizeDown() }
    func resizePaneLeft() { selectedTab?.resizeLeft() }
    func resizePaneRight() { selectedTab?.resizeRight() }

    /// Whether the selected tab is a split layout — gates zoom, resize and
    /// equalize.
    var hasSplitPanes: Bool { selectedTab?.hasMultiplePanes ?? false }

    /// Whether the selected tab is showing a zoomed pane.
    var isPaneZoomed: Bool { selectedTab?.isZoomed ?? false }

    // MARK: - Files

    /// Opens `path` according to the caller's file-tab intent.
    /// `editorState` seeds scroll/cursor state when restoring; a
    /// `revealSelection` request in it also lands on its line when the file
    /// was already open (see `FileTab.revealSelection(at:)`).
    func openFile(
        _ path: String,
        behavior: FileOpenBehavior = .pinned,
        editorState: EditorState? = nil
    ) {
        if behavior != .newPinned,
           let (tab, paneID) = behavior == .pinned
               ? findFilePreviewPane(path: path) ?? findFilePane(path: path)
               : findFilePane(path: path) {
            if behavior == .pinned { tab.pinFilePreview() }
            selectedTabID = tab.id
            tab.focusedPaneID = paneID
            if let location = editorState?.selectionLocation,
               let pane = tab.allPanes.first(where: { $0.id == paneID }),
               case .file(let file) = pane.content {
                file.revealSelection(at: location)
            }
            return
        }

        // Capture the current directory context *before* selection moves to the
        // new tab, so its panels track the tab the file was opened from.
        let context = selectedSession
        let file = FileTab(path: path)
        if let editorState {
            file.editorState = editorState
        }
        if behavior == .preview,
           let tab = tabs.first(where: \.canReplaceFilePreview),
           tab.replaceFilePreview(with: file) {
            tab.contextSession = context
            selectedTabID = tab.id
            return
        }
        let tab = makeTab(
            content: .file(file),
            filePreview: behavior == .preview
        )
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    /// Opens `path` as a new pane beside the focused one in the current tab
    /// ("Open to the Side"). Falls back to a fresh tab when the current tab
    /// can't take a split (e.g. it's a diff) or none is selected.
    func openFileToSide(_ path: String) {
        guard let tab = selectedTab, tab.canSplit else {
            openFile(path, behavior: .pinned)
            return
        }
        if let existing = tab.allPanes.first(where: {
            if case .file(let file) = $0.content { return file.path == path }
            return false
        }) {
            tab.pinFilePreview()
            tab.focusedPaneID = existing.id
            return
        }
        tab.split(Pane(content: .file(FileTab(path: path))), toward: .right)
    }

    private func findFilePreviewPane(path: String) -> (tab: PaneTab, paneID: UUID)? {
        for tab in tabs where tab.canReplaceFilePreview {
            guard let pane = tab.allPanes.first,
                  case .file(let file) = pane.content,
                  file.path == path else { continue }
            return (tab, pane.id)
        }
        return nil
    }

    private func findFilePane(path: String) -> (tab: PaneTab, paneID: UUID)? {
        for tab in tabs {
            if let pane = tab.allPanes.first(where: {
                if case .file(let file) = $0.content { return file.path == path }
                return false
            }) {
                return (tab, pane.id)
            }
        }
        return nil
    }

    // MARK: - Browser

    /// Opens a native browser as a new tab beside the current selection.
    @discardableResult
    func newBrowserTab(
        initialURL: String? = nil,
        initialFocus: BrowserTab.InitialFocus = .addressBar
    ) -> BrowserTab {
        let context = selectedSession
        let browser = makeBrowser(
            initialURL: initialURL,
            initialFocus: initialFocus
        )
        let tab = makeTab(content: .browser(browser))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
        return browser
    }

    /// Opens a native browser to the right of the focused pane in the current
    /// tab. Unlike a normal terminal split, the new pane owns a WKWebView.
    @discardableResult
    func newBrowserPane(
        toward edge: PaneDropEdge = .right,
        initialURL: String? = nil,
        initialFocus: BrowserTab.InitialFocus = .addressBar
    ) -> BrowserTab? {
        guard let tab = selectedTab, tab.canSplit else { return nil }
        let browser = makeBrowser(
            initialURL: initialURL,
            initialFocus: initialFocus
        )
        tab.split(Pane(content: .browser(browser)), toward: edge)
        return browser
    }

    private func makeBrowser(
        initialURL: String?,
        initialFocus: BrowserTab.InitialFocus
    ) -> BrowserTab {
        let browser = BrowserTab(
            initialURL: initialURL,
            initialFocus: initialFocus
        )
        manager.map { browser.transferHost(to: $0) }
        register(browser)
        return browser
    }

    // MARK: - File paths

    /// After a rename on disk, re-points any open file pane at its new path —
    /// the renamed file itself, or any file beneath a renamed directory.
    func updateFilePaths(from oldPath: String, to newPath: String) {
        for tab in tabs {
            for case .file(let file) in tab.allContents {
                if file.path == oldPath {
                    file.updatePath(newPath)
                } else if file.path.hasPrefix(oldPath + "/") {
                    file.updatePath(newPath + String(file.path.dropFirst(oldPath.count)))
                }
            }
        }
    }

    // MARK: - Diffs

    /// Opens a git diff as a new tab, reusing (and reloading) an existing tab
    /// for the same file and stage side.
    func openDiff(
        repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?
    ) {
        if let (tab, pane) = findDiffPane(
            repoRoot: repoRoot, path: path, staged: staged, commitHash: nil
        ),
           case .diff(let diff) = pane.content {
            diff.untracked = untracked
            diff.origPath = origPath
            diff.reload()
            selectedTabID = tab.id
            tab.focusedPaneID = pane.id
            return
        }
        let context = selectedSession
        let diff = DiffTab(
            repoRoot: repoRoot, path: path, staged: staged,
            untracked: untracked, origPath: origPath
        )
        let tab = makeTab(content: .diff(diff))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    /// Opens one file as it changed in a historical commit, comparing the
    /// commit's first parent with the selected commit.
    func openCommitDiff(
        repoRoot: String,
        path: String,
        commitHash: String,
        parentHash: String?,
        status: Character,
        origPath: String?
    ) {
        if let (tab, pane) = findDiffPane(
            repoRoot: repoRoot, path: path, staged: false, commitHash: commitHash
        ), case .diff(let diff) = pane.content {
            diff.origPath = origPath
            diff.reload()
            selectedTabID = tab.id
            tab.focusedPaneID = pane.id
            return
        }
        let context = selectedSession
        let diff = DiffTab(
            repoRoot: repoRoot,
            path: path,
            staged: false,
            untracked: false,
            origPath: origPath,
            commitHash: commitHash,
            commitParentHash: parentHash,
            commitStatus: status
        )
        let tab = makeTab(content: .diff(diff))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    private func findDiffPane(
        repoRoot: String, path: String, staged: Bool, commitHash: String?
    ) -> (tab: PaneTab, pane: Pane)? {
        for tab in tabs {
            if let pane = tab.allPanes.first(where: {
                if case .diff(let diff) = $0.content {
                    return diff.repoRoot == repoRoot
                        && diff.path == path
                        && diff.staged == staged
                        && diff.commitHash == commitHash
                }
                return false
            }) {
                return (tab, pane)
            }
        }
        return nil
    }

    // MARK: - Closing

    /// Closes one piece of content: terminates a session, prompts before
    /// discarding a dirty file, then removes its pane (dropping the tab when
    /// that was its last pane). `terminate` is false when a shell has already
    /// exited on its own.
    func closeContent(_ content: PaneContent, terminate: Bool = true) {
        switch content {
        case .session(let session):
            if terminate {
                // Capture while the shell is still alive. Only closes the
                // user initiated reach the reopen stack; a shell that exits
                // on its own (`terminate: false`) is not an action the
                // command is meant to undo.
                onSessionClosed?(closedSessionRecord(for: session))
                session.terminate()
            }
            removePaneWithContent(content.id)
        case .file(let file):
            guard file.isDirty else {
                removePaneWithContent(content.id)
                return
            }
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            Task { @MainActor in
                _ = await confirmCloseUnsaved(content, in: window)
            }
        case .browser:
            removePaneWithContent(content.id)
        case .diff(let diff):
            guard diff.isDirty else {
                removePaneWithContent(content.id)
                return
            }
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            Task { @MainActor in
                _ = await confirmCloseUnsaved(content, in: window)
            }
        }
    }

    /// Closes the focused pane of the selected tab (⌘W).
    func closeFocusedPane() {
        guard let content = focusedContent else { return }
        closeContent(content)
    }

    func closeSelected() {
        closeFocusedPane()
    }

    /// Closes an entire tab — every pane it holds.
    func close(_ tab: PaneTab) {
        closeBatch(tab.allContents)
    }

    /// Closes every tab except `keep`.
    func closeOthers(_ keep: PaneTab) {
        selectedTabID = keep.id
        closeBatch(tabs.filter { $0.id != keep.id }.flatMap(\.allContents))
    }

    /// Closes every tab positioned to the right of `tab` in the strip.
    func closeToRight(of tab: PaneTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        closeBatch(Array(tabs[(index + 1)...]).flatMap(\.allContents))
    }

    /// Closes every file pane while leaving other content in split tabs open.
    func closeFiles() {
        closeBatch(tabs.flatMap(\.allContents).filter { $0.isFile })
    }

    /// Closes every diff pane while leaving other content in split tabs open.
    func closeDiffs() {
        closeBatch(tabs.flatMap(\.allContents).filter { $0.isDiff })
    }

    /// Closes every tab, leaving the project open but empty. Close All still
    /// records every closed session for reopen — to the user it is a close
    /// like any other — but the reopen stack's cap means a large project is
    /// not guaranteed to come back in full; partial recovery beats none, and
    /// recording is nearly free.
    func closeAll() {
        closeBatch(tabs.flatMap(\.allContents))
    }

    /// The reopen snapshot for one user-closed session, taken while the
    /// shell is still alive. Batch closes record every session they tear
    /// down, so the stack holds individual panes rather than whole tabs.
    private func closedSessionRecord(for session: TerminalSession) -> ClosedSessionRecord {
        ClosedSessionRecord(
            projectID: id,
            customTitle: tabs.first { $0.paneID(forContent: session.id) != nil }?.customName,
            workingDirectory: session.currentDirectoryPath,
            closedAt: Date(),
            tabGroupID: tabs.first { $0.paneID(forContent: session.id) != nil }?.tabGroupID
        )
    }

    /// Asks whether to save before discarding an edited file, matching the
    /// standard macOS Save / Don't Save / Cancel prompt. Presented as a sheet
    /// on the owning Zshell window so it doesn't block the whole app. If no
    /// owning window is available, leave the content open and report a
    /// cancellation. Returns `true` if the user backed out — Cancel, or a save
    /// that failed — so a batch close can stop before tearing down other panes.
    ///
    /// This is `async` on purpose: awaiting the sheet means each prompt in a
    /// batch is presented only after the previous one has fully dismissed.
    @discardableResult
    private func confirmCloseUnsaved(_ content: PaneContent, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Do you want to save the changes you made to \(content.title)?",
            comment: "Unsaved file or diff confirmation. The placeholder is a file name."
        )
        alert.informativeText = String(localized: "Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        let dontSave = alert.addButton(withTitle: String(localized: "Don’t Save"))
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"

        guard let host = AppWindowPresentation.hostWindow(relativeTo: window) else { return true }
        let response = await alert.beginSheetModal(for: host)

        switch response {
        case .alertFirstButtonReturn: // Save
            content.save()
            // Keep the pane open if the write failed; the error bar shows why.
            guard content.saveError == nil else { return true }
            removePaneWithContent(content.id)
            return false
        case .alertSecondButtonReturn: // Don't Save
            removePaneWithContent(content.id)
            return false
        default: // Cancel
            return true
        }
    }

    /// Closes several pieces of content at once. Any unsaved files are
    /// confirmed *first*, one prompt at a time; the remaining (clean) content
    /// is only torn down once every prompt has been answered — so cancelling
    /// out of a save prompt leaves the saved panes open too.
    private func closeBatch(_ targets: [PaneContent]) {
        let dirtyContents = targets.filter(\.isDirty)
        let cleanContents = targets.filter { !$0.isDirty }

        guard !dirtyContents.isEmpty else {
            cleanContents.forEach { closeContent($0) }
            return
        }

        let window = NSApp.keyWindow ?? NSApp.mainWindow
        Task { @MainActor in
            for content in dirtyContents where content.isDirty {
                // Bail the moment the user backs out — the clean panes, and any
                // unsaved panes not yet prompted, stay open.
                if await confirmCloseUnsaved(content, in: window) { return }
            }
            cleanContents.forEach { closeContent($0) }
        }
    }

    // MARK: - Tab groups

    func tabGroup(id: UUID?) -> SessionTabGroup? {
        guard let id else { return nil }
        return tabGroups.first { $0.id == id }
    }

    var visibleTabs: [PaneTab] {
        tabs.filter { tabGroup(id: $0.tabGroupID)?.isCollapsed != true }
    }

    @discardableResult
    func createTabGroup(containing tab: PaneTab? = nil) -> SessionTabGroup {
        createTabGroup(named: String(localized: "New Tab Group"), containing: tab)
    }

    @discardableResult
    func createTabGroup(named name: String, containing tab: PaneTab? = nil) -> SessionTabGroup {
        let group = SessionTabGroup(name: name)
        tabGroups.append(group)
        if let tab { moveTab(tab.id, toGroup: group.id) }
        return group
    }

    func renameTabGroup(_ id: UUID, to name: String) {
        guard let name = Self.normalizedCustomName(name),
              let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        tabGroups[index].name = name
    }

    func setTabGroupColor(_ color: ProjectTabMarkerColor?, id: UUID) {
        guard let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        tabGroups[index].markerColor = color
    }

    func setTabGroupCollapsed(_ collapsed: Bool, id: UUID) {
        guard let index = tabGroups.firstIndex(where: { $0.id == id }),
              tabGroups[index].isCollapsed != collapsed else { return }
        tabGroups[index].isCollapsed = collapsed
    }

    func removeTabGroup(_ id: UUID) {
        for tab in tabs where tab.tabGroupID == id { tab.tabGroupID = nil }
        tabGroups.removeAll { $0.id == id }
        normalizeTabOrder()
    }

    func moveTabGroup(_ id: UUID, to targetID: UUID) {
        guard id != targetID,
              let source = tabGroups.firstIndex(where: { $0.id == id }),
              let target = tabGroups.firstIndex(where: { $0.id == targetID }) else { return }
        let group = tabGroups.remove(at: source)
        tabGroups.insert(group, at: target)
        normalizeTabOrder()
    }

    func moveTab(_ id: UUID, toGroup groupID: UUID?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              groupID == nil || tabGroup(id: groupID) != nil else { return }
        let tab = tabs[index]
        if tab.tabGroupID != groupID || (groupID != nil && tab.isPinned) {
            tabs.remove(at: index)
            if groupID != nil { tab.isPinned = false }
            tab.tabGroupID = groupID
            // A group-header drop appends after its existing members. Using
            // the source's old global position would unexpectedly insert it
            // before tabs already organized in the destination.
            tabs.append(tab)
            normalizeTabOrder()
        }
        if let groupID { setTabGroupCollapsed(false, id: groupID) }
    }

    @discardableResult
    func newSession(inTabGroup groupID: UUID) -> TerminalSession? {
        guard tabGroup(id: groupID) != nil else { return nil }
        let session = makeSession(launchSettings: launchSettings)
        let tab = makeTab(content: .session(session))
        insertNextToSelected(tab)
        // Assign the destination before selection can expand the previous group.
        moveTab(tab.id, toGroup: groupID)
        selectedTabID = tab.id
        return session
    }

    func beginRestoringTabGroups(_ groups: [SessionTabGroup]) {
        isRestoringTabs = true
        var seen = Set<UUID>()
        tabGroups = groups.compactMap { group in
            guard seen.insert(group.id).inserted else { return nil }
            var group = group
            group.name = Self.normalizedCustomName(group.name)
                ?? String(localized: "New Tab Group")
            return group
        }
    }

    func finishRestoringTabGroups() {
        // The saved active tab can belong to a group the user left collapsed.
        normalizeTabOrder()
        isRestoringTabs = false
    }

    private func revealSelectedTabGroup() {
        guard let groupID = selectedTab?.tabGroupID else { return }
        setTabGroupCollapsed(false, id: groupID)
    }

    /// Keep each group contiguous so visual order, keyboard navigation and
    /// "Close Tabs to the Right" all describe the same sequence. Fixed tabs
    /// occupy their own section and leave a group when pinned.
    private func normalizeTabOrder() {
        let positions = Dictionary(uniqueKeysWithValues: tabGroups.enumerated().map {
            ($0.element.id, $0.offset)
        })
        for tab in tabs where tab.isPinned || tab.tabGroupID.map({ positions[$0] == nil }) == true {
            if tab.tabGroupID != nil { tab.tabGroupID = nil }
        }
        func section(_ tab: PaneTab) -> Int {
            if tab.isPinned { return -2 }
            return tab.tabGroupID.flatMap { positions[$0] } ?? -1
        }
        let ordered = tabs.enumerated().sorted {
            let first = section($0.element), second = section($1.element)
            return first == second ? $0.offset < $1.offset : first < second
        }.map(\.element)
        if ordered.map(\.id) != tabs.map(\.id) { tabs = ordered }
    }

    // MARK: - Tab selection

    func setPinned(_ pinned: Bool, for tab: PaneTab) {
        guard tab.isPinned != pinned,
              let index = tabs.firstIndex(where: { $0.id == tab.id })
        else { return }

        tabs.remove(at: index)
        tab.isPinned = pinned
        if pinned { tab.tabGroupID = nil }
        let destination = tabs.firstIndex(where: { !$0.isPinned }) ?? tabs.endIndex
        tabs.insert(tab, at: destination)
        normalizeTabOrder()
    }

    /// Reorders a tab within its pinned or unpinned section. Cross-project
    /// moves go through `TerminalManager.moveTab` so ownership changes as one
    /// transaction; selection continues to follow the dragged tab's ID.
    func moveTab(_ draggedID: UUID, to targetID: UUID) {
        guard draggedID != targetID,
              let draggedIndex = tabs.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetID }),
              tabs[draggedIndex].isPinned == tabs[targetIndex].isPinned
        else { return }

        var reorderedTabs = tabs
        let draggedTab = reorderedTabs.remove(at: draggedIndex)
        draggedTab.tabGroupID = tabs[targetIndex].tabGroupID
        reorderedTabs.insert(draggedTab, at: targetIndex)
        tabs = reorderedTabs
        normalizeTabOrder()
        revealSelectedTabGroup()
    }

    /// Moves a tab into another tab's pane tree at the indicated drop edge.
    /// The source layout is grafted intact, so dragging a tab that already has
    /// splits preserves those panes and their proportions. Diff tabs stay
    /// standalone, matching the same constraint as every other split path.
    @discardableResult
    func moveTab(
        _ draggedID: UUID,
        into targetTabID: UUID,
        toward edge: PaneDropEdge,
        beside targetPaneID: UUID
    ) -> Bool {
        guard draggedID != targetTabID,
              let draggedIndex = tabs.firstIndex(where: { $0.id == draggedID }),
              let draggedTab = tabs.first(where: { $0.id == draggedID }),
              let targetTab = tabs.first(where: { $0.id == targetTabID }),
              draggedTab.isPinned == targetTab.isPinned,
              !draggedTab.allContents.contains(where: \.isDiff),
              let targetPane = targetTab.allPanes.first(where: { $0.id == targetPaneID }),
              !targetPane.content.isDiff
        else { return false }

        targetTab.insert(
            draggedTab.layout,
            focusedPaneID: draggedTab.focusedPaneID,
            toward: edge,
            beside: targetPaneID
        )
        if targetTab.contextSession == nil {
            targetTab.contextSession = draggedTab.contextSession
        }

        // Contents remain alive and keep their project-level observations;
        // only the now-empty source tab's forwarding observation is removed.
        tabObservations[draggedID] = nil
        recentTabIDs.removeAll { $0 == draggedID }
        tabs.remove(at: draggedIndex)
        selectedTabID = targetTabID
        return true
    }

    /// Detaches a tab without closing its contents. Only the manager-level
    /// transfer path may call this, because sessions have to be adopted by the
    /// destination before the main actor yields.
    func detachTabForTransfer(id: UUID) -> PaneTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs[index]
        tab.tabGroupID = nil
        unregisterTransferOwnership(of: tab)
        recentTabIDs.removeAll { $0 == id }
        tabs.remove(at: index)
        if selectedTabID == id {
            let neighbor = min(index, tabs.count - 1)
            selectedTabID = neighbor >= 0 ? tabs[neighbor].id : nil
        }
        return tab
    }

    /// Adopts the same long-lived tab and its content objects, preserving pane
    /// IDs, split geometry, terminal surfaces, browser state, and focus.
    func adoptTransferredTab(_ tab: PaneTab, manager: TerminalManager) {
        self.manager = manager
        let movedSessionIDs = Set(tab.sessions.map(\.id))
        if let context = tab.contextSession, !movedSessionIDs.contains(context.id) {
            tab.contextSession = nil
        }
        tab.sessions.forEach { $0.transferHost(to: manager) }
        tab.browsers.forEach { $0.transferHost(to: manager) }
        tab.tabGroupID = nil
        registerTransferOwnership(of: tab)
        tabs.append(tab)
        normalizeTabOrder()
        selectedTabID = tab.id
    }

    private func registerTransferOwnership(of tab: PaneTab) {
        register(tab)
        tab.sessions.forEach(register)
        tab.browsers.forEach(register)
    }

    private func unregisterTransferOwnership(of tab: PaneTab) {
        tabObservations[tab.id] = nil
        for session in tab.sessions {
            session.onExited = nil
            sessionObservations[session.id] = nil
        }
        for browser in tab.browsers {
            browserObservations[browser.id] = nil
        }
    }

    private func register(_ session: TerminalSession) {
        session.onExited = { [weak self] session in
            // Already dead — just drop its pane, no second terminate.
            self?.closeContent(.session(session), terminate: false)
        }
        sessionObservations[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func register(_ browser: BrowserTab) {
        browserObservations[browser.id] = browser.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }

    func selectNext() {
        shiftSelection(by: 1)
    }

    func selectPrevious() {
        shiftSelection(by: -1)
    }

    private func shiftSelection(by offset: Int) {
        guard !tabs.isEmpty,
              let current = tabs.firstIndex(where: { $0.id == selectedTabID })
        else { return }
        let next = (current + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    // MARK: - Layout mutation plumbing

    private func makeTab(
        content: PaneContent,
        filePreview: Bool = false
    ) -> PaneTab {
        register(PaneTab(content: content, filePreview: filePreview))
    }

    /// Wires a tab's change observation and returns it — used for fresh tabs
    /// and for tabs rebuilt during restore.
    @discardableResult
    func register(_ tab: PaneTab) -> PaneTab {
        tabObservations[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return tab
    }

    /// Rebuilds a saved tab's pane layout — recreating its sessions (wired for
    /// exit + observation), files and diffs — then registers and appends it.
    /// Skips panes whose content can't be rebuilt; a tab with none is dropped.
    @discardableResult
    func restoreTab(
        from snap: SessionSnapshot.ProjectSnapshot.TabSnapshot,
        histories: [String: String] = [:]
    ) -> PaneTab? {
        let effectiveSettings = launchSettings.applying(snap.launchSettingsOverride)
        let layout = restoreLayout(
            from: snap.layout,
            histories: histories,
            launchSettings: effectiveSettings
        )
        let panes = layout.allPanes
        guard !panes.isEmpty else { return nil }
        let focusedIndex = min(max(0, snap.focusedPaneIndex), panes.count - 1)
        let tab = PaneTab(
            layout: layout,
            focusedPaneID: panes[focusedIndex].id,
            isPinned: snap.isPinned
        )
        tab.customName = snap.customName
        tab.tabGroupID = tabGroup(id: snap.tabGroupID)?.id
        tab.markerColor = snap.markerColorHex.flatMap(ProjectTabMarkerColor.init(hex:))
        tab.launchSettingsOverride = snap.launchSettingsOverride
        append(tab)
        return tab
    }

    private func restoreLayout(
        from snap: SessionSnapshot.ProjectSnapshot.LayoutSnapshot,
        histories: [String: String],
        launchSettings: TerminalLaunchSettings
    ) -> PaneNode {
        switch snap {
        case .pane(let pane):
            let restoredHistory = pane.historyKey.flatMap { histories[$0] }
            return .pane(Pane(content: makeContent(
                from: pane.content,
                restoredHistory: restoredHistory,
                launchSettings: launchSettings
            )))
        case .split(let axis, let fraction, let first, let second):
            return .split(PaneSplit(
                axis: axis,
                fraction: CGFloat(fraction),
                first: restoreLayout(
                    from: first,
                    histories: histories,
                    launchSettings: launchSettings
                ),
                second: restoreLayout(
                    from: second,
                    histories: histories,
                    launchSettings: launchSettings
                )
            ))
        }
    }

    private func makeContent(
        from snap: SessionSnapshot.ProjectSnapshot.PaneContentSnapshot,
        restoredHistory: String? = nil,
        launchSettings: TerminalLaunchSettings
    ) -> PaneContent {
        switch snap {
        case .session(let workingDirectory):
            return .session(makeSession(
                directory: workingDirectory,
                restoredHistory: restoredHistory,
                launchSettings: launchSettings
            ))
        case .file(let path, let editorState):
            let file = FileTab(path: path)
            if let editorState { file.editorState = editorState }
            return .file(file)
        case .browser(let url):
            return .browser(makeBrowser(initialURL: url, initialFocus: .none))
        case .diff(let repoRoot, let path, let staged, let untracked, let origPath):
            return .diff(DiffTab(
                repoRoot: repoRoot, path: path, staged: staged,
                untracked: untracked, origPath: origPath
            ))
        case .commitDiff(
            let repoRoot, let path, let commitHash, let parentHash, let status, let origPath
        ):
            return .diff(DiffTab(
                repoRoot: repoRoot,
                path: path,
                staged: false,
                untracked: false,
                origPath: origPath,
                commitHash: commitHash,
                commitParentHash: parentHash,
                commitStatus: status.first
            ))
        }
    }

    /// Inserts a newly created unpinned tab next to the current unpinned
    /// selection. When the current tab is pinned, starts the unpinned section.
    private func insertNextToSelected(_ tab: PaneTab) {
        if let selectedTabID,
           let index = tabs.firstIndex(where: { $0.id == selectedTabID }),
           !tabs[index].isPinned {
            tab.tabGroupID = tabs[index].tabGroupID
            tabs.insert(tab, at: index + 1)
        } else {
            let destination = tabs.firstIndex(where: { !$0.isPinned }) ?? tabs.endIndex
            tabs.insert(tab, at: destination)
        }
    }

    /// Appends a tab and selects it — used while restoring, which builds tabs
    /// in saved order.
    func append(_ tab: PaneTab) {
        register(tab)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Removes the pane holding `contentID` from whichever tab owns it, and
    /// drops the tab if that pane was its last.
    private func removePaneWithContent(_ contentID: UUID) {
        for tab in tabs {
            guard let paneID = tab.paneID(forContent: contentID) else { continue }
            // Keyed by content id; no-ops for the other content kinds.
            sessionObservations[contentID] = nil
            browserObservations[contentID] = nil
            if !tab.removePane(paneID) {
                remove(tabID: tab.id)
            }
            return
        }
    }

    private func remove(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        for session in tab.sessions {
            sessionObservations[session.id] = nil
        }
        for browser in tab.browsers {
            browserObservations[browser.id] = nil
        }
        tabObservations[tabID] = nil
        recentTabIDs.removeAll { $0 == tabID }
        tabs.remove(at: index)
        if selectedTabID == tabID {
            let neighbor = min(index, tabs.count - 1)
            selectedTabID = neighbor >= 0 ? tabs[neighbor].id : nil
        }
        // Emptying the project does not close it — the project row stays in the
        // sidebar until the user explicitly closes it.
    }
}
