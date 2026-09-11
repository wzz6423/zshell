//
//  TerminalManager.swift
//  zshell
//

import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

/// Panels available in the right sidebar. Raw values are stable names
/// persisted in `SessionSnapshot`.
enum RightPanel: String, Codable {
    case files
    case git
    case info
}

/// One Find menu command, routed from the menu bar to whichever find
/// implementation the focused pane owns: Ghostty's own search in a terminal,
/// `NSTextFinder`'s find bar in a file editor.
enum FindAction {
    case show
    case replace
    case hide
    case next
    case previous
    case useSelection
}

/// One closed terminal session, kept so "Reopen Closed Session" (⇧⌘T) can
/// recreate it as a fresh shell in the same project and directory. Only the
/// identity needed for that is captured — the owning project, the
/// user-assigned tab title, and the working directory at close time.
/// Scrollback and pane layout are deliberately not recorded: a reopened
/// session is an ordinary new session, not a restored one.
struct ClosedSessionRecord: Equatable {
    /// Project the session was closed in. Every session lives in a project
    /// today, so this is always set; optional so the reopen lookup degrades
    /// to the fallback chain if that ever stops holding.
    let projectID: UUID?
    /// User-assigned tab title (`PaneTab.customName`) at close time, if any.
    /// The automatic terminal title is not captured — a fresh shell grows a
    /// fresh one.
    let customTitle: String?
    /// The shell's working directory when the session was closed.
    let workingDirectory: String
    /// When the session was closed.
    let closedAt: Date
}

/// Owns the list of projects and the current selection. Each project holds
/// its own terminal sessions; the "selected session" is the selected
/// project's selected session.
@MainActor
final class TerminalManager: nonisolated ObservableObject {
    @Published var projects: [Project] = []
    @Published var selectedProjectID: UUID? {
        willSet {
            // Diff hosts are expensive WebKit trees. Once a project has put
            // them in this window, keep that project's stack mounted across
            // project switches just as ContentView already does across tab
            // switches. Reattaching every open diff can otherwise block the
            // main thread while AppKit rebuilds the window/view hierarchy.
            if let selectedProjectID, selectedProjectID != newValue {
                retainedDiffProjectIDs.insert(selectedProjectID)
            }
        }
    }
    @Published var isPanelVisible = false
    @Published var panelTab: RightPanel = .files
    /// Visibility of the left project sidebar (⌘B). `isPanelVisible` above is
    /// the separate right panel.
    @Published var isLeftSidebarVisible = true
    /// Debug FPS badge in the sidebar header. Deliberately not persisted:
    /// every launch starts with it hidden.
    @Published var isFPSCounterVisible = false
    @Published private(set) var isCommandPaletteVisible = false

    /// Projects publish their own changes (session list, session selection);
    /// re-publish them so views observing the manager stay current.
    private var projectObservations: [UUID: AnyCancellable] = [:]
    /// Projects whose diff stacks have already been mounted in this window.
    /// Unvisited restored projects stay lazy so launch does not instantiate all
    /// of their WKWebViews at once.
    private var retainedDiffProjectIDs: Set<UUID> = []
    private var projectCounter = 0
    private var settingsObservation: AnyCancellable?
    private var translucencyObservation: AnyCancellable?
    private var accessibilityDisplayObserver: NSObjectProtocol?
    private var autosaveObservation: AnyCancellable?
    private var terminationObservation: AnyCancellable?
    /// The stable terminal/editor responder displaced by the command palette's
    /// search field. AppKit field editors are deliberately excluded because a
    /// SwiftUI TextField can reuse the same responder for the palette itself.
    private weak var commandPalettePreviousResponder: NSResponder?
    private weak var commandPaletteWindow: NSWindow?
    /// Window hosting this manager, once SwiftUI has attached its content.
    /// Finder service requests use it to target the active Zshell window.
    private weak var window: NSWindow?
    /// The untouched project created before the first window appears. A Finder
    /// request arriving during launch replaces it instead of leaving an extra
    /// home-directory project beside the requested folder.
    private var startupProjectID: UUID?

    /// Newest-last stack of sessions the user closed in this window, for
    /// "Reopen Closed Session" (⇧⌘T). In memory only and scoped to the
    /// window: the undo belongs to the window that closed the session, and
    /// persisting it would blur into the restart-restore snapshot, whose
    /// semantics are "restore what the user left open" — not resurrect
    /// things they closed.
    private var closedSessionRecords: [ClosedSessionRecord] = []
    /// FIFO cap for the reopen stack; the oldest entry falls off first.
    private static let closedSessionRecordLimit = 10

    /// Live managers in window-creation order; the persisted snapshot is
    /// one entry per registered manager.
    private static var registry: [TerminalManager] = []
    /// Read-only module access for the authenticated local automation router.
    /// Mutation and window ownership remain private to `TerminalManager`.
    static var automationManagers: [TerminalManager] { registry }
    private struct CLIProjectLaunch {
        let arguments: [String]
        let directory: String
        let path: String?
    }
    /// Folder requests can arrive while macOS is still launching Zshell, before
    /// a WindowGroup has produced a manager/window to receive them.
    private static var pendingDirectories: [String] = []
    /// Captured from SwiftUI's openWindow environment so a Finder request can
    /// reopen Zshell after the user has closed its last window.
    private static var windowOpener: (() -> Void)?
    /// Coalesces launch-time service requests while SwiftUI is still deciding
    /// whether it will create the initial WindowGroup window itself.
    private static var windowRequestScheduled = false
    private static var isOpeningWindow = false
    /// Window snapshots loaded from disk that no window has claimed yet.
    /// Each new manager claims the next; extras beyond the saved count
    /// start fresh.
    private static var pendingRestores: [SessionSnapshot] = []
    /// Terminal scrollback loaded from the sidecar store, keyed by the
    /// `historyKey` each restoring session pane carries. Shared across windows
    /// (keys are unique per pane), so restores read from it without consuming.
    private static var pendingHistories: [String: String] = [:]
    private static var hasLoadedStore = false
    /// Set on app termination so window teardown can't re-save a partial
    /// snapshot over the final full one.
    private static var isQuitting = false
    private static var didReopenWindows = false

    init() {
        if !Self.hasLoadedStore {
            Self.hasLoadedStore = true
            Self.pendingRestores = SessionStore.load()
            Self.pendingHistories = TerminalHistoryStore.load()
        }
        Self.registry.append(self)
        var restored = false
        if !Self.pendingRestores.isEmpty {
            restored = restore(from: Self.pendingRestores.removeFirst())
        }
        // Only a window still claiming a snapshot reads the scrollback blobs,
        // so once the last one is claimed they are dead weight — several
        // hundred lines per restored session, held for the life of the process.
        if Self.pendingRestores.isEmpty, !Self.pendingHistories.isEmpty {
            Self.pendingHistories = [:]
        }
        let queuedDirectories = Self.takePendingDirectories()
        if !restored, queuedDirectories.isEmpty {
            startupProjectID = newProject().id
        }
        for directory in queuedDirectories {
            newProject(directory: directory)
        }
        // Reconfigure live sessions only when font, appearance, theme, or
        // terminal input settings change. Delivery is scheduled onto the main
        // queue because @Published emits in willSet — by then `didSet` has
        // pushed the theme onto NSApp (and the selection into `Theme`), so
        // `refreshAppearance` reads the new state.
        settingsObservation = Publishers.CombineLatest4(
            Publishers.CombineLatest3(
                Publishers.CombineLatest4(
                    AppSettings.shared.$fontFamily.removeDuplicates(),
                    AppSettings.shared.$fontFallbackFamily.removeDuplicates(),
                    AppSettings.shared.$fontSize.removeDuplicates(),
                    AppSettings.shared.$fontThicken.removeDuplicates()
                ),
                Publishers.CombineLatest(
                    AppSettings.shared.$fontThickenStrength.removeDuplicates(),
                    AppSettings.shared.$terminalLineHeight.removeDuplicates()
                ),
                AppSettings.shared.$theme.removeDuplicates()
            ),
            Publishers.CombineLatest(
                AppSettings.shared.$themeDark.removeDuplicates(),
                AppSettings.shared.$themeLight.removeDuplicates()
            ),
            Publishers.CombineLatest(
                AppSettings.shared.$macosOptionAsAlt.removeDuplicates(),
                AppSettings.shared.$shiftEnterNewline.removeDuplicates()
            ),
            Publishers.CombineLatest(
                AppSettings.shared.$cursorShape.removeDuplicates(),
                AppSettings.shared.$cursorBlinking.removeDuplicates()
            )
        )
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAppearance()
            }
        translucencyObservation = Publishers.CombineLatest(
            AppSettings.shared.$terminalBackgroundOpacity.removeDuplicates(),
            AppSettings.shared.$terminalBackgroundBlur.removeDuplicates()
        )
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshTranslucency()
            }
        accessibilityDisplayObserver =
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                let manager = self
                assumeMainActor { manager?.refreshTranslucency() }
            }
        // Every project/tab/selection change re-publishes through the manager,
        // so a debounced sink snapshots layout after mutations settle without
        // reading live terminal contents.
        autosaveObservation = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { _ in
                TerminalManager.saveAll(captureTerminalHistory: false)
            }
        // The debounce can swallow changes made just before quitting;
        // capture a final snapshot while the shells are still alive.
        terminationObservation = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in
                guard !TerminalManager.isQuitting else { return }
                TerminalManager.isQuitting = true
                TerminalManager.saveAll(captureTerminalHistory: true)
            }
    }

    deinit {
        if let accessibilityDisplayObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                accessibilityDisplayObserver
            )
        }
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedSession: TerminalSession? {
        selectedProject?.selectedSession
    }

    /// Diff stacks that should remain in the window hierarchy. The selected
    /// project is included immediately; previously selected projects remain
    /// only when they actually own a diff.
    var projectsWithMountedDiffs: [Project] {
        projects.filter {
            $0.id == selectedProjectID
                || (retainedDiffProjectIDs.contains($0.id) && $0.hasDiffs)
        }
    }

    // MARK: - Projects

    @discardableResult
    func newProject() -> Project {
        let project = makeProject()
        insert(project)
        return project
    }

    /// Creates a project rooted at `directory`, with its first terminal
    /// launched there. Used by Zshell's Finder service.
    private func newProject(directory: String) {
        let project = makeProject(createInitialSession: false)
        project.customName = URL(
            fileURLWithPath: directory,
            isDirectory: true
        ).lastPathComponent
        project.customDirectory = directory
        project.newSession(directory: directory)
        insert(project)
    }

    /// Creates a CLI-requested project. An empty argv
    /// starts the normal login shell; otherwise the terminal directly execs
    /// the preserved argument vector with the caller's PATH.
    private func newProject(cliLaunch: CLIProjectLaunch) {
        let project = makeProject(createInitialSession: false)
        project.newSession(
            directory: cliLaunch.directory,
            commandArguments: cliLaunch.arguments.isEmpty ? nil : cliLaunch.arguments,
            environmentPath: cliLaunch.path
        )
        insert(project)
    }

    private func insert(_ project: Project) {
        // New projects are unpinned. Keep the existing adjacent insertion within
        // that section; a pinned selection starts the regular section instead.
        if let selectedProjectID,
           let index = projects.firstIndex(where: { $0.id == selectedProjectID }),
           !projects[index].isPinned {
            projects.insert(project, at: index + 1)
        } else {
            let destination = projects.firstIndex(where: { !$0.isPinned }) ?? projects.endIndex
            projects.insert(project, at: destination)
        }
        selectedProjectID = project.id
    }

    /// Routes folders from the Finder service into the active Zshell window.
    /// If no window exists yet, the next WindowGroup manager claims them.
    static func openDirectories(_ directories: [String]) {
        guard !directories.isEmpty else { return }
        let manager = registry.first { $0.window === NSApp.keyWindow }
            ?? registry.first { $0.window === NSApp.mainWindow }
            ?? registry.last { $0.window != nil }
        guard let manager else {
            pendingDirectories.append(contentsOf: directories)
            requestWindowForPendingDirectories()
            return
        }

        for directory in directories {
            manager.newProject(directory: directory)
        }
        manager.window?.makeKeyAndOrderFront(nil)
    }

    /// Called as soon as SwiftUI gives this manager an AppKit window. A
    /// launch-time Finder request may have been queued before that happened.
    func attach(to window: NSWindow) {
        self.window = window
        refreshTranslucency()
        Self.isOpeningWindow = false
        let directories = Self.takePendingDirectories()
        if !directories.isEmpty, let startupProjectID,
           let startupProject = projects.first(where: { $0.id == startupProjectID }) {
            startupProject.terminateAll()
            remove(startupProject)
        }
        startupProjectID = nil
        for directory in directories {
            newProject(directory: directory)
        }
        if !directories.isEmpty {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func takePendingDirectories() -> [String] {
        let directories = pendingDirectories
        pendingDirectories = []
        return directories
    }

    /// Creates a fresh project beside the current one for the bundled CLI.
    static func openCLIProject(
        arguments: [String],
        directory: String,
        path: String?
    ) {
        let manager = registry.first { $0.window === NSApp.keyWindow }
            ?? registry.first { $0.window === NSApp.mainWindow }
            ?? registry.last { $0.window != nil }
        guard let manager else { return }
        manager.newProject(
            cliLaunch: CLIProjectLaunch(
                arguments: arguments,
                directory: directory,
                path: path
            )
        )
        manager.window?.makeKeyAndOrderFront(nil)
    }

    /// Installs SwiftUI's WindowGroup opener before any window needs to appear.
    /// Commands are constructed during app launch even when macOS starts Zshell
    /// solely to handle a service request.
    static func registerWindowOpener(_ open: @escaping () -> Void) {
        windowOpener = open
        requestWindowForPendingDirectories()
    }

    private static func requestWindowForPendingDirectories() {
        guard !pendingDirectories.isEmpty,
              !registry.contains(where: { $0.window != nil }),
              !windowRequestScheduled,
              !isOpeningWindow
        else { return }

        windowRequestScheduled = true
        // Give SwiftUI's normal cold-launch window one turn to attach first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            windowRequestScheduled = false
            guard !pendingDirectories.isEmpty,
                  !registry.contains(where: { $0.window != nil }),
                  !isOpeningWindow
            else { return }

            isOpeningWindow = true
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue.hasPrefix("main") == true
            }) {
                window.makeKeyAndOrderFront(nil)
            } else if let windowOpener {
                windowOpener()
            } else {
                isOpeningWindow = false
            }
        }
    }

    private func makeProject(
        isPinned: Bool = false,
        createInitialSession: Bool = true
    ) -> Project {
        projectCounter += 1
        let project = Project(
            fallbackName: "Project \(projectCounter)",
            isPinned: isPinned,
            createInitialSession: createInitialSession
        )
        // Close instrumentation flows from the project (where every close
        // path converges) into this window's reopen stack.
        project.onSessionClosed = { [weak self] record in
            self?.recordClosedSession(record)
        }
        projectObservations[project.id] = project.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return project
    }

    func close(_ project: Project) {
        project.terminateAll()
        remove(project)
    }

    private func remove(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects.remove(at: index)
        projectObservations[project.id] = nil
        if selectedProjectID == project.id {
            let neighbor = min(index, projects.count - 1)
            selectedProjectID = neighbor >= 0 ? projects[neighbor].id : nil
        }
        retainedDiffProjectIDs.remove(project.id)
        // Nothing left to inspect once the last project is gone, so collapse
        // the right sidebar — its panels all track the selected session.
        if projects.isEmpty {
            isPanelVisible = false
        }
    }

    func setPinned(_ pinned: Bool, for project: Project) {
        guard project.isPinned != pinned,
              let index = projects.firstIndex(where: { $0.id == project.id })
        else { return }

        projects.remove(at: index)
        project.isPinned = pinned
        let destination = projects.firstIndex(where: { !$0.isPinned }) ?? projects.endIndex
        projects.insert(project, at: destination)
    }

    /// Moves a dragged project across `targetID` within its pinned or unpinned
    /// section. Selection continues to follow its project ID.
    func moveProject(_ draggedID: UUID, to targetID: UUID) {
        guard draggedID != targetID,
              let draggedIndex = projects.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = projects.firstIndex(where: { $0.id == targetID }),
              projects[draggedIndex].isPinned == projects[targetIndex].isPinned
        else { return }

        var reorderedProjects = projects
        let draggedProject = reorderedProjects.remove(at: draggedIndex)
        reorderedProjects.insert(draggedProject, at: targetIndex)
        projects = reorderedProjects
    }

    func selectProject(index: Int) {
        guard projects.indices.contains(index) else { return }
        selectedProjectID = projects[index].id
    }

    func selectNextProject() {
        shiftProjectSelection(by: 1)
    }

    func selectPreviousProject() {
        shiftProjectSelection(by: -1)
    }

    private func shiftProjectSelection(by offset: Int) {
        guard !projects.isEmpty,
              let current = projects.firstIndex(where: { $0.id == selectedProjectID })
        else { return }
        let next = (current + offset + projects.count) % projects.count
        selectedProjectID = projects[next].id
    }

    // MARK: - Sessions

    /// New session in the current project; creates a project if none exist.
    func newSession(directory: String? = nil) {
        guard let project = selectedProject else {
            if let directory {
                newProject(directory: directory)
            } else {
                newProject()
            }
            return
        }
        project.newSession(directory: directory)
    }

    /// Whether "Reopen Closed Session" (⇧⌘T) has history to act on.
    var canReopenClosedSession: Bool {
        !closedSessionRecords.isEmpty
    }

    /// Reopens the most recently closed session as a fresh shell: in its
    /// original project while that project is still open here, else in the
    /// focused project, else in a new project — the same fallback a plain
    /// new session follows. One call pops one entry, so repeating the
    /// command walks back through the close history.
    func reopenClosedSession() {
        guard let record = closedSessionRecords.popLast() else { return }
        if let project = record.projectID.flatMap({ projectID in
            projects.first { $0.id == projectID }
        }) ?? selectedProject {
            project.newSession(
                directory: record.workingDirectory,
                tabTitle: record.customTitle
            )
        } else {
            // No project left in this window: start one anchored at the
            // recorded directory. The tab title is only carried when a
            // project already exists to open the tab in.
            newSession(directory: record.workingDirectory)
        }
    }

    private func recordClosedSession(_ record: ClosedSessionRecord) {
        closedSessionRecords.append(record)
        // Appends happen one at a time, so at most one entry sits past the
        // cap; the oldest is evicted first.
        if closedSessionRecords.count > Self.closedSessionRecordLimit {
            closedSessionRecords.removeFirst()
        }
    }

    /// Opens a browser tab in the current project. Zshell remains
    /// project-oriented, so invoking it from the no-project state first creates
    /// the normal project shell and places the browser beside it.
    func newBrowserTab(initialURL: String? = nil) {
        let project = selectedProject ?? newProject()
        project.newBrowserTab(
            initialURL: initialURL,
            initialFocus: initialURL == nil ? .addressBar : .webContent
        )
    }

    /// Opens a browser beside the focused pane in the current tab.
    func newBrowserPane(
        toward edge: PaneDropEdge = .right,
        initialURL: String? = nil
    ) {
        selectedProject?.newBrowserPane(
            toward: edge,
            initialURL: initialURL,
            initialFocus: initialURL == nil ? .addressBar : .webContent
        )
    }

    /// Brings `session` to the foreground: selects its project and tab, then
    /// focuses its pane. Backs the command palette's session switcher; a no-op
    /// if the session is no longer open anywhere.
    func revealSession(_ session: TerminalSession) {
        for project in projects {
            for tab in project.tabs {
                guard let paneID = tab.paneID(forContent: session.id) else { continue }
                selectedProjectID = project.id
                project.selectedTabID = tab.id
                tab.focusedPaneID = paneID
                return
            }
        }
    }

    /// Activates Zshell and reveals the session that emitted a desktop
    /// notification. Searches every open window; if the session is gone,
    /// still brings the app forward so the click isn't a dead end.
    static func revealSession(id: UUID) {
        NSApp.activate()
        for manager in registry {
            for project in manager.projects {
                for session in project.sessions where session.id == id {
                    manager.revealSession(session)
                    manager.window?.makeKeyAndOrderFront(nil)
                    return
                }
            }
        }
        // Session closed since the banner was posted — surface any live window.
        if let manager = registry.first(where: { $0.window != nil }) {
            manager.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// "Seen" is a model focus decision, not an API read. A background CLI can
    /// inspect output repeatedly without clearing a finished badge; selecting
    /// the pane through any UI path clears it on the next monitor tick.
    static var automationFocusedSessionID: UUID? {
        guard NSApp.isActive else { return nil }
        for manager in registry where manager.window?.isKeyWindow == true {
            guard let project = manager.selectedProject,
                  let tab = project.selectedTab,
                  let pane = tab.focusedPane,
                  case .session(let session) = pane.content
            else { continue }
            return session.id
        }
        return nil
    }

    static func automationIsSessionFocused(_ id: UUID) -> Bool {
        automationFocusedSessionID == id
    }

    var hasAgentAttention: Bool {
        projects.contains { project in
            project.sessions.contains {
                $0.agentStatus?.phase == .blocked || $0.agentStatus?.phase == .done
            }
        }
    }

    /// Cycles blocked agents first, then unseen completions, preserving project,
    /// tab, and split-tree order within each state. Only an explicit focus
    /// action acknowledges `done`; automation reads never call this path.
    func focusNextAgentAttention() {
        let ordered = projects.flatMap { project in
            project.tabs.flatMap(\.sessions)
        }
        let attention = ordered.filter { $0.agentStatus?.phase == .blocked }
            + ordered.filter { $0.agentStatus?.phase == .done }
        guard !attention.isEmpty else { return }

        let currentID: UUID? = {
            guard let pane = selectedProject?.selectedTab?.focusedPane,
                  case .session(let session) = pane.content else { return nil }
            return session.id
        }()
        let next: TerminalSession
        if let currentID,
           let index = attention.firstIndex(where: { $0.id == currentID }) {
            next = attention[(index + 1) % attention.count]
        } else {
            next = attention[0]
        }
        revealSession(next)
        next.markAutomationAgentSeen()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Clears the terminal in the focused pane. No-op while another content
    /// kind is focused, so ⌘K never wipes an off-screen terminal.
    func clearActiveTerminal() {
        if case .session(let session)? = selectedProject?.focusedContent {
            session.clear()
        }
    }

    /// Context-menu actions resolve their manager at click time so commands
    /// cannot leak into a terminal owned by another window.
    private static var activeWindowManager: TerminalManager? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        return registry.first { $0.window === keyWindow }
    }

    static func insertQuickCommand(_ preset: QuickCommandPreset) {
        activeWindowManager?.sendQuickCommand(preset, appendingReturn: false)
    }

    static func runQuickCommand(_ preset: QuickCommandPreset) {
        activeWindowManager?.sendQuickCommand(preset, appendingReturn: true)
    }

    static func manageQuickCommands() {
        guard let manager = activeWindowManager else { return }
        QuickCommandEditor.show(relativeTo: manager.window)
    }

    /// Routes only to the focused terminal pane. Return is appended solely by
    /// the separately named run action.
    private func sendQuickCommand(
        _ preset: QuickCommandPreset,
        appendingReturn: Bool
    ) {
        guard case .session(let session)? = selectedProject?.focusedContent else { return }
        session.sendCommand(preset.command)
        if appendingReturn { session.sendCommand("\r") }
    }

    /// Whether ⌘K has a terminal on screen to act on right now.
    var canClearActiveTerminal: Bool {
        if case .session? = selectedProject?.focusedContent { return true }
        return false
    }

    /// Routes a Find menu command to the focused pane. Driven off the focused
    /// pane rather than the first responder, so ⌘F and ⌘G keep working while
    /// the find bar's own field holds keyboard focus.
    func performFindAction(_ action: FindAction) {
        switch selectedProject?.focusedContent {
        case .session(let session): session.find.perform(action)
        case .file(let file): file.performFindAction(action)
        case .browser, .diff, .none: break
        }
    }

    /// Swaps the focused markdown file between its rendered form and its
    /// source. The choice is global, like the diff viewer's review/edit mode.
    func toggleMarkdownPreview() {
        guard canToggleMarkdownPreview else { return }
        MarkdownViewPreferences.shared.showsSource.toggle()
    }

    var canToggleMarkdownPreview: Bool {
        guard case .file(let file)? = selectedProject?.focusedContent else { return false }
        return FileViewerContainerView.isMarkdown(file.path)
    }

    /// Whether the Find menu has something searchable on screen right now.
    /// Diffs render their own views rather than a searchable text view.
    var canFind: Bool {
        switch selectedProject?.focusedContent {
        case .session, .file: return true
        case .browser, .diff, .none: return false
        }
    }

    /// Whether Find and Replace has an editable pane to act on: terminal
    /// output and diffs are read-only, so replace is only offered for a file —
    /// and not for rendered markdown.
    var canReplace: Bool {
        guard case .file(let file)? = selectedProject?.focusedContent else { return false }
        return !file.showsRenderedMarkdown
    }

    /// Closes the focused pane (⌘W). When it's the last pane in its tab the
    /// tab closes too — matching the old single-content-tab behavior. Once the
    /// project has no tabs left, ⌘W closes the project itself.
    func closeSelectedTab() {
        guard let project = selectedProject else { return }
        if project.tabs.isEmpty {
            close(project)
        } else {
            project.closeFocusedPane()
        }
    }

    // MARK: - Panes

    func splitRight() { selectedProject?.splitRight() }
    func splitLeft() { selectedProject?.splitLeft() }
    func splitDown() { selectedProject?.splitDown() }
    func splitUp() { selectedProject?.splitUp() }
    func split(toward edge: PaneDropEdge) { selectedProject?.split(toward: edge) }
    func focusPaneLeft() { selectedProject?.focusLeft() }
    func focusPaneRight() { selectedProject?.focusRight() }
    func focusPaneUp() { selectedProject?.focusUp() }
    func focusPaneDown() { selectedProject?.focusDown() }
    func focusNextPane() { selectedProject?.focusNextPane() }
    func focusPreviousPane() { selectedProject?.focusPreviousPane() }

    func togglePaneZoom() { selectedProject?.togglePaneZoom() }
    func equalizePanes() { selectedProject?.equalizePanes() }
    func resizePaneUp() { selectedProject?.resizePaneUp() }
    func resizePaneDown() { selectedProject?.resizePaneDown() }
    func resizePaneLeft() { selectedProject?.resizePaneLeft() }
    func resizePaneRight() { selectedProject?.resizePaneRight() }

    /// Whether the focused pane can be split right now (false for diffs / no
    /// project).
    var canSplit: Bool { selectedProject?.canSplit ?? false }

    /// Whether the selected tab holds more than one pane — gates the zoom,
    /// resize and equalize commands.
    var hasSplitPanes: Bool { selectedProject?.hasSplitPanes ?? false }

    /// Whether the selected tab is showing a zoomed pane — drives the header's
    /// exit-zoom indicator.
    var isPaneZoomed: Bool { selectedProject?.isPaneZoomed ?? false }

    func selectNextTab() {
        selectedProject?.selectNext()
    }

    func selectPreviousTab() {
        selectedProject?.selectPrevious()
    }

    func selectTab(index: Int) {
        selectedProject?.select(index: index)
    }

    // MARK: - Browser

    private var selectedBrowser: BrowserTab? {
        if case .browser(let browser)? = selectedProject?.focusedContent {
            return browser
        }
        return nil
    }

    var hasSelectedBrowser: Bool {
        selectedBrowser != nil
    }

    func focusBrowserAddressBar() {
        selectedBrowser?.requestAddressFocus()
    }

    func reloadSelectedBrowser() {
        selectedBrowser?.reload()
    }

    func stopSelectedBrowser() {
        selectedBrowser?.stopLoading()
    }

    func openSelectedPageInDefaultBrowser() {
        selectedBrowser?.openInDefaultBrowser()
    }

    // MARK: - Files

    /// Opens `path` as a pinned file tab in the current project.
    func openFile(_ path: String) {
        selectedProject?.openFile(path)
    }

    /// Opens `path` using the file tree's replaceable preview tab.
    func previewFile(_ path: String) {
        selectedProject?.openFile(path, behavior: .preview)
    }

    /// Opens `path` in a fresh pinned tab even when that path is already open.
    func openFileInNewPinnedTab(_ path: String) {
        selectedProject?.openFile(path, behavior: .newPinned)
    }

    /// Opens `path` as a pane beside the focused one in the current tab.
    func openFileToSide(_ path: String) {
        selectedProject?.openFileToSide(path)
    }

    /// Opens a git diff tab in the current project.
    func openDiff(
        repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?
    ) {
        selectedProject?.openDiff(
            repoRoot: repoRoot, path: path, staged: staged,
            untracked: untracked, origPath: origPath
        )
    }

    /// Opens the selected path as changed by one historical commit.
    func openCommitDiff(
        repoRoot: String,
        path: String,
        commitHash: String,
        parentHash: String?,
        status: Character,
        origPath: String?
    ) {
        selectedProject?.openCommitDiff(
            repoRoot: repoRoot,
            path: path,
            commitHash: commitHash,
            parentHash: parentHash,
            status: status,
            origPath: origPath
        )
    }

    /// Saves the focused pane if it holds a file or an editable diff.
    func saveSelectedFile() {
        selectedProject?.focusedContent?.save()
    }

    /// Propagates a file-tree rename to every open file tab across all
    /// projects, so tabs for the moved file (or files under a moved
    /// directory) keep pointing at the right place.
    func fileRenamed(from oldPath: String, to newPath: String) {
        for project in projects {
            project.updateFilePaths(from: oldPath, to: newPath)
        }
    }

    // MARK: - Panels & appearance

    func toggleSidebar() {
        isPanelVisible.toggle()
    }

    func toggleLeftSidebar() {
        isLeftSidebarVisible.toggle()
    }

    func toggleFPSCounter() {
        isFPSCounterVisible.toggle()
    }

    func toggleCommandPalette() {
        if isCommandPaletteVisible {
            dismissCommandPalette()
        } else {
            commandPaletteWindow = NSApp.keyWindow
            if let responder = commandPaletteWindow?.firstResponder,
               isStableWorkspaceResponder(responder) {
                commandPalettePreviousResponder = responder
            } else {
                commandPalettePreviousResponder = nil
            }
            isCommandPaletteVisible = true
        }
    }

    func dismissCommandPalette() {
        guard isCommandPaletteVisible else { return }
        isCommandPaletteVisible = false
    }

    /// Called by the palette after SwiftUI has actually removed its focused
    /// search field from the window.
    func restoreFocusAfterCommandPalette() {
        let window = commandPaletteWindow
        let responder = commandPalettePreviousResponder
        commandPaletteWindow = nil
        commandPalettePreviousResponder = nil

        // Let the removal transaction finish before restoring the displaced
        // AppKit responder.
        DispatchQueue.main.async {
            guard let window, let responder else { return }
            // A palette command may already have focused a new terminal or
            // editor. Never let restoration race that newer focus and win.
            if let current = window.firstResponder,
               current !== responder,
               self.isStableWorkspaceResponder(current) {
                return
            }
            window.makeFirstResponder(responder)
        }
    }

    /// Terminal and editor responders are public host views. WebKit instead
    /// makes a private descendant of WKWebView first responder, so walk its
    /// AppKit ancestry before deciding whether palette dismissal can restore
    /// the page's keyboard focus.
    private func isStableWorkspaceResponder(_ responder: NSResponder) -> Bool {
        if responder is any TerminalBackendSurface || responder is FocusReportingTextView {
            return true
        }
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    /// Shows the sidebar on `panel`, or hides it if already showing that panel.
    func togglePanel(_ panel: RightPanel) {
        if isPanelVisible && panelTab == panel {
            isPanelVisible = false
        } else {
            panelTab = panel
            isPanelVisible = true
        }
    }

    /// Applies the effective background alpha to every backend and makes the
    /// host window transparent only while terminal translucency is usable.
    private func refreshTranslucency() {
        let settings = AppSettings.shared
        window?.isOpaque = !settings.isTerminalBackgroundTranslucent
        window?.backgroundColor = settings.isTerminalBackgroundTranslucent
            ? .clear
            : .windowBackgroundColor
        for project in projects {
            for session in project.sessions {
                session.applyTheme()
            }
        }
        objectWillChange.send()
    }

    /// Re-themes every session after a light/dark appearance change.
    func refreshAppearance() {
        for project in projects {
            for session in project.sessions {
                session.applyTheme()
            }
        }
    }

    /// Re-themes every open window for app-wide changes that do not mutate an
    /// `AppSettings` publisher, such as a transient CLI theme preview.
    static func refreshAllAppearances() {
        for manager in registry {
            manager.refreshAppearance()
        }
    }

    /// Flushes the complete multi-window snapshot before Settings starts a
    /// replacement app instance for a language change.
    static func saveForRelaunch() {
        saveAll(captureTerminalHistory: true)
    }

    /// After the first window appears, reopen one window per unclaimed
    /// saved snapshot; each new window's manager claims the next one.
    /// Deferred a runloop tick so windows the system itself restores can
    /// claim theirs first.
    static func openRestoredWindows(_ open: @escaping () -> Void) {
        registerWindowOpener(open)
        guard !didReopenWindows else { return }
        didReopenWindows = true
        DispatchQueue.main.async {
            for _ in 0..<pendingRestores.count {
                open()
            }
        }
    }

    /// Called when this manager's window closes: drop it from the
    /// persisted set — except for the last window, whose snapshot is kept
    /// saved and queued so reopening (or relaunching) restores it — and
    /// kill its shells.
    func windowClosed() {
        guard !Self.isQuitting else { return }
        Self.registry.removeAll { $0 === self }
        if Self.registry.isEmpty {
            // These shells are about to be destroyed, so this is their final
            // capture even though the macOS app may remain open with no window.
            let window = makeWindowSnapshot(captureTerminalHistory: true)
            // Last window: keep its snapshot and scrollback saved and queued so
            // reopening (or relaunching) restores them.
            SessionStore.save([window.snapshot])
            TerminalHistoryStore.save(window.histories)
            Self.pendingRestores = [window.snapshot]
            Self.pendingHistories = window.histories
        } else {
            Self.saveAll(captureTerminalHistory: false)
        }
        for project in projects {
            project.terminateAll()
        }
    }

    // MARK: - Persistence

    private static func saveAll(captureTerminalHistory: Bool) {
        guard !registry.isEmpty else { return }
        var snapshots: [SessionSnapshot] = []
        var histories: [String: String] = [:]
        for manager in registry {
            let window = manager.makeWindowSnapshot(
                captureTerminalHistory: captureTerminalHistory
            )
            snapshots.append(window.snapshot)
            histories.merge(window.histories) { _, new in new }
        }
        SessionStore.save(snapshots)
        TerminalHistoryStore.save(histories)
    }

    /// Builds this window's layout snapshot and, alongside it, the scrollback
    /// to persist for its sessions. Each captured session gets a fresh
    /// `historyKey` stored on both sides so restore can pair them; sessions
    /// with no history (feature off, empty, or unserializable) get no key.
    private func makeWindowSnapshot(
        captureTerminalHistory: Bool
    ) -> (snapshot: SessionSnapshot, histories: [String: String]) {
        typealias ProjectSnapshot = SessionSnapshot.ProjectSnapshot
        var histories: [String: String] = [:]
        let snapshot = SessionSnapshot(
            projects: projects.compactMap { project in
                guard !project.tabs.isEmpty else { return nil }
                let projectSessions = project.sessions
                let tabs = project.tabs.map { tab -> ProjectSnapshot.TabSnapshot in
                    let layout = Self.layoutSnapshot(
                        tab.layout,
                        captureTerminalHistory: captureTerminalHistory,
                        histories: &histories
                    )
                    let focusedPaneIndex = tab.allPanes.firstIndex {
                        $0.id == tab.focusedPaneID
                    } ?? 0
                    return ProjectSnapshot.TabSnapshot(
                        layout: layout,
                        focusedPaneIndex: focusedPaneIndex,
                        customName: tab.customName,
                        isPinned: tab.isPinned,
                        markerColorHex: tab.markerColor?.hex,
                        contextSessionIndex: tab.contextSession.flatMap { context in
                            projectSessions.firstIndex { $0.id == context.id }
                        }
                    )
                }
                return ProjectSnapshot(
                    customName: project.customName,
                    isPinned: project.isPinned,
                    markerColorHex: project.markerColor?.hex,
                    customDirectory: project.customDirectory,
                    tabs: tabs,
                    selectedTabIndex: project.tabs.firstIndex { $0.id == project.selectedTabID }
                )
            },
            selectedProjectIndex: projects.firstIndex { $0.id == selectedProjectID },
            isLeftSidebarVisible: isLeftSidebarVisible,
            isRightPanelVisible: isPanelVisible,
            rightPanelTab: panelTab
        )
        return (snapshot, histories)
    }

    private static func layoutSnapshot(
        _ layout: PaneNode,
        captureTerminalHistory: Bool,
        histories: inout [String: String]
    ) -> SessionSnapshot.ProjectSnapshot.LayoutSnapshot {
        typealias ProjectSnapshot = SessionSnapshot.ProjectSnapshot
        switch layout {
        case .pane(let pane):
            var historyKey: String?
            if case .session(let session) = pane.content,
               let history = session.serializedHistory(
                   captureLive: captureTerminalHistory
               ), !history.isEmpty {
                let key = UUID().uuidString
                histories[key] = history
                historyKey = key
            }
            return .pane(ProjectSnapshot.PaneSnapshot(
                content: contentSnapshot(pane.content),
                weight: 1,
                historyKey: historyKey
            ))
        case .split(let split):
            return .split(
                axis: split.axis,
                fraction: Double(split.fraction),
                first: layoutSnapshot(
                    split.first,
                    captureTerminalHistory: captureTerminalHistory,
                    histories: &histories
                ),
                second: layoutSnapshot(
                    split.second,
                    captureTerminalHistory: captureTerminalHistory,
                    histories: &histories
                )
            )
        }
    }

    private static func contentSnapshot(
        _ content: PaneContent
    ) -> SessionSnapshot.ProjectSnapshot.PaneContentSnapshot {
        switch content {
        case .session(let session):
            return .session(workingDirectory: session.currentDirectoryPath)
        case .file(let file):
            return .file(path: file.path, editorState: file.editorState)
        case .browser(let browser):
            return .browser(url: browser.snapshotURL)
        case .diff(let diff):
            if let commitHash = diff.commitHash {
                return .commitDiff(
                    repoRoot: diff.repoRoot,
                    path: diff.path,
                    commitHash: commitHash,
                    parentHash: diff.commitParentHash,
                    status: diff.commitStatus.map(String.init) ?? "M",
                    origPath: diff.origPath
                )
            }
            return .diff(
                repoRoot: diff.repoRoot, path: diff.path, staged: diff.staged,
                untracked: diff.untracked, origPath: diff.origPath
            )
        }
    }

    /// Rebuilds projects and tabs from a saved window snapshot. Returns
    /// false when the snapshot holds nothing restorable. Sidebar state is
    /// applied even then — the window claimed this snapshot's layout.
    private func restore(from snapshot: SessionSnapshot) -> Bool {
        if let visible = snapshot.isLeftSidebarVisible { isLeftSidebarVisible = visible }
        if let visible = snapshot.isRightPanelVisible { isPanelVisible = visible }
        if let tab = snapshot.rightPanelTab { panelTab = tab }
        for saved in snapshot.projects where !saved.tabs.isEmpty {
            let project = makeProject(
                isPinned: saved.isPinned,
                createInitialSession: false
            )
            project.customName = Project.normalizedCustomName(saved.customName)
            project.markerColor = saved.markerColorHex.flatMap(ProjectTabMarkerColor.init(hex:))
            project.customDirectory = saved.customDirectory
            var restoredContexts: [(tab: PaneTab, sessionIndex: Int)] = []
            for savedTab in saved.tabs {
                guard let tab = project.restoreTab(
                    from: savedTab, histories: Self.pendingHistories
                ) else { continue }
                if let sessionIndex = savedTab.contextSessionIndex {
                    restoredContexts.append((tab, sessionIndex))
                }
            }
            let restoredSessions = project.sessions
            for context in restoredContexts
            where restoredSessions.indices.contains(context.sessionIndex) {
                context.tab.contextSession = restoredSessions[context.sessionIndex]
            }
            guard !project.tabs.isEmpty else {
                projectObservations[project.id] = nil
                continue
            }
            if let index = saved.selectedTabIndex, project.tabs.indices.contains(index) {
                project.selectedTabID = project.tabs[index].id
            }
            project.resetRecency()
            projects.append(project)
        }
        guard !projects.isEmpty else { return false }
        if let index = snapshot.selectedProjectIndex, projects.indices.contains(index) {
            selectedProjectID = projects[index].id
        } else {
            selectedProjectID = projects.first?.id
        }
        return true
    }
}
