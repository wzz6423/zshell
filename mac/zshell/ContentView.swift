//
//  ContentView.swift
//  zshell
//

import Combine
import SwiftUI

/// A sidebar destination for a live tab drag. Dropping on an existing project
/// transfers the tab into it; dropping on a group header or the explicit
/// ungrouped target pulls the tab out into a new project.
enum TabSidebarDropTarget: Equatable {
    case project(UUID)
    case newProject(groupID: UUID?)
}

/// Coordinates a direct tab-strip drag across the mounted pane layout and the
/// project sidebar. A reference object keeps the latest global pointer location
/// and destination frames available synchronously when mouse-up arrives.
@MainActor
final class TabSplitDragCoordinator: ObservableObject {
    struct Drag {
        let sourceTabID: UUID
        let sourceProjectID: UUID
        let location: CGPoint
        let targetTabID: UUID?
        let targetPaneID: UUID?
        let edge: PaneDropEdge?
        let sidebarTarget: TabSidebarDropTarget?
        let title: String
        let systemImage: String
        let fileIconPath: String?
        let paneCount: Int
    }

    @Published private(set) var drag: Drag?

    private weak var project: Project?
    private weak var manager: TerminalManager?
    private var renderedTabID: UUID?
    private var paneFrames: [UUID: CGRect] = [:]
    private var sidebarProjectFrames: [UUID: CGRect] = [:]
    private var sidebarGroupFrames: [UUID: CGRect] = [:]
    private var sidebarUngroupedFrame: CGRect?

    func update(
        sourceTabID: UUID,
        location: CGPoint,
        in project: Project,
        manager: TerminalManager
    ) {
        self.project = project
        self.manager = manager
        drag = resolvedDrag(
            sourceTabID: sourceTabID,
            location: location,
            in: project
        )
    }

    /// Sidebar geometry is reported independently from the tab strip. Re-resolve
    /// an active drag whenever grouping, collapse, scrolling, or resizing moves
    /// one of the destinations under a stationary pointer.
    func updateSidebarFrames(
        projects: [UUID: CGRect],
        groups: [UUID: CGRect],
        ungrouped: CGRect?
    ) {
        let changed = sidebarProjectFrames != projects
            || sidebarGroupFrames != groups
            || sidebarUngroupedFrame != ungrouped
        sidebarProjectFrames = projects
        sidebarGroupFrames = groups
        sidebarUngroupedFrame = ungrouped
        guard changed, let drag, let project else { return }
        self.drag = resolvedDrag(
            sourceTabID: drag.sourceTabID,
            location: drag.location,
            in: project
        )
    }

    /// Pane frames are reported by the currently mounted layout, including a
    /// single full-bleed pane. Re-resolve an active drag because a resize or
    /// newly created split can change the quadrant under a stationary cursor.
    func updatePaneFrames(_ frames: [UUID: CGRect], for tabID: UUID) {
        let changed = renderedTabID != tabID || paneFrames != frames
        renderedTabID = tabID
        paneFrames = frames
        guard changed, let drag, let project else { return }
        self.drag = resolvedDrag(
            sourceTabID: drag.sourceTabID,
            location: drag.location,
            in: project
        )
    }

    func clearPaneFrames(for tabID: UUID) {
        guard renderedTabID == tabID else { return }
        renderedTabID = nil
        paneFrames = [:]
    }

    func commit() {
        guard let drag, let project, let manager else {
            cancel()
            return
        }
        // Resolve once more at release so the operation uses the same frames
        // as the final preview even if the last move and mouse-up are adjacent.
        let resolved = resolvedDrag(
            sourceTabID: drag.sourceTabID,
            location: drag.location,
            in: project
        )
        let result: TerminalManager.TabMoveResult?
        switch resolved.sidebarTarget {
        case .project(let destinationProjectID):
            result = manager.moveTab(
                id: resolved.sourceTabID,
                from: resolved.sourceProjectID,
                to: destinationProjectID,
                in: ObjectIdentifier(manager)
            )
        case .newProject(let groupID):
            result = manager.moveTabToNewProject(
                id: resolved.sourceTabID,
                from: resolved.sourceProjectID,
                in: ProjectGroupStore.shared.group(id: groupID)
            )
        case nil:
            result = nil
            if let targetTabID = resolved.targetTabID,
               let targetPaneID = resolved.targetPaneID,
               let edge = resolved.edge {
                project.moveTab(
                    resolved.sourceTabID,
                    into: targetTabID,
                    toward: edge,
                    beside: targetPaneID
                )
            }
        }
        if let failure = result?.failure {
            presentMoveFailure(failure)
        }
        cancel()
    }

    func cancel() {
        drag = nil
        project = nil
        manager = nil
    }

    private func resolvedDrag(
        sourceTabID: UUID,
        location: CGPoint,
        in project: Project
    ) -> Drag {
        let source = project.tabs.first { $0.id == sourceTabID }
        let sourceContent = source?.focusedContent
        let targetTabID = project.selectedTabID

        var targetPaneID: UUID?
        var edge: PaneDropEdge?
        if let source,
           !source.allContents.contains(where: \.isDiff),
           targetTabID != sourceTabID,
           renderedTabID == targetTabID,
           let targetTab = project.selectedTab,
           source.isPinned == targetTab.isPinned,
           let hit = paneFrames.first(where: { $0.value.contains(location) }),
           let targetPane = targetTab.allPanes.first(where: { $0.id == hit.key }),
           !targetPane.content.isDiff {
            targetPaneID = hit.key
            edge = dropEdge(at: location, in: hit.value)
        }

        let sidebarTarget: TabSidebarDropTarget?
        if let destination = sidebarProjectFrames.first(where: {
            $0.key != project.id && $0.value.contains(location)
        })?.key {
            sidebarTarget = .project(destination)
        } else if let groupID = sidebarGroupFrames.first(where: {
            $0.value.contains(location)
        })?.key {
            sidebarTarget = .newProject(groupID: groupID)
        } else if sidebarUngroupedFrame?.contains(location) == true {
            sidebarTarget = .newProject(groupID: nil)
        } else {
            sidebarTarget = nil
        }

        return Drag(
            sourceTabID: sourceTabID,
            sourceProjectID: project.id,
            location: location,
            targetTabID: sidebarTarget == nil && targetPaneID != nil ? targetTabID : nil,
            targetPaneID: sidebarTarget == nil ? targetPaneID : nil,
            edge: sidebarTarget == nil ? edge : nil,
            sidebarTarget: sidebarTarget,
            title: source?.displayTitle ?? sourceContent?.title ?? String(localized: "Tab"),
            systemImage: sourceContent?.systemImage ?? "terminal",
            fileIconPath: sourceContent?.fileIconPath,
            paneCount: source?.allPanes.count ?? 1
        )
    }

    func presentMoveFailure(_ failure: TerminalManager.TabMoveFailure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t Move Tab")
        alert.informativeText = failure.message
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func dropEdge(at location: CGPoint, in frame: CGRect) -> PaneDropEdge {
        let dx = (location.x - frame.midX) / max(frame.width, 1)
        let dy = (location.y - frame.midY) / max(frame.height, 1)
        if abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .top : .bottom
    }
}

enum BottomToolbarLayout {
    static let idealHeight: CGFloat = 32

    static func height(
        for session: TerminalSession?,
        interfaceScale: CGFloat = 1
    ) -> CGFloat {
        let scaledIdealHeight = idealHeight * interfaceScale
        guard session?.backend == .libghostty,
              let cellHeight = session?.terminalCellSize?.height,
              cellHeight.isFinite, cellHeight > 0 else {
            return scaledIdealHeight
        }
        let rowCount = max(1, (scaledIdealHeight / cellHeight).rounded())
        return rowCount * cellHeight
    }
}

struct ContentView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var tabSwitcher = TabSwitcherController()
    @StateObject private var git = GitStatusModel()
    @StateObject private var tabSplitDrag = TabSplitDragCoordinator()

    /// Every terminal in the selected project can change the same repository.
    /// Watching command completion keeps the toolbar current without polling.
    private var commandCompletionSequences: [UUID: UInt64] {
        Dictionary(uniqueKeysWithValues:
            manager.selectedProject?.sessions.map {
                ($0.id, $0.commandLifecycle.completionSequence)
            } ?? []
        )
    }

    private var bottomToolbarHeight: CGFloat {
        BottomToolbarLayout.height(
            for: manager.selectedSession,
            interfaceScale: CGFloat(settings.interfaceScale)
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if manager.isLeftSidebarVisible {
                SidebarView(
                    manager: manager,
                    tabDrag: tabSplitDrag,
                    bottomBarHeight: bottomToolbarHeight
                )
            }

            VStack(spacing: 0) {
                // Above the pane stack so header tooltips, which hang down
                // into the terminal area, aren't covered by it.
                MainHeaderView(manager: manager, tabSplitDrag: tabSplitDrag)
                    .zIndex(1)

                ZStack {
                    // Diff panes stay mounted after their project has been
                    // visited: removing a project's stack pulls every
                    // NSHostingView out of the window at once, making project
                    // switching block while WebKit tears down and reattaches
                    // the rendered diffs. Unvisited restored projects remain
                    // lazy; inactive stacks sit beneath the active opaque pane.
                    ForEach(manager.projectsWithMountedDiffs) { project in
                        ForEach(project.diffPlacements, id: \.diff.id) { placement in
                            let isSelected = manager.selectedProjectID == project.id
                                && project.selectedTabID == placement.tabID
                            DiffViewerView(
                                diff: placement.diff,
                                isSelected: isSelected
                            )
                            .background(Color(nsColor: Theme.background))
                            .allowsHitTesting(isSelected)
                            .zIndex(isSelected ? 1 : 0)
                        }
                    }
                    Group {
                        if let tab = manager.selectedProject?.selectedTab {
                            PaneLayoutView(
                                manager: manager,
                                tab: tab,
                                tabSplitDrag: tabSplitDrag,
                                onSplit: { manager.split(toward: $0) },
                                onNewBrowserTab: {
                                    manager.newBrowserTab(initialURL: $0)
                                },
                                onNewBrowserPane: {
                                    manager.newBrowserPane(initialURL: $0)
                                },
                                onNewFileTab: {
                                    manager.openFileInNewPinnedTab($0)
                                },
                                onNewFilePane: {
                                    manager.openFileToSide($0)
                                }
                            )
                        } else {
                            emptyState
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Opaque so the pane gaps hide unselected diffs behind,
                    // except while a diff tab or translucent terminal is up.
                    .background(paneLayerIsOpaque ? AnyShapeStyle(Color(nsColor: Theme.background)) : AnyShapeStyle(Color.clear))
                    .zIndex(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if manager.selectedProject != nil
                    && settings.toolbarVisibility != .hide
                    && (git.isRepo || settings.toolbarVisibility == .always) {
                    BottomToolbarView(
                        model: git,
                        height: bottomToolbarHeight,
                        toggleGitPanel: { manager.togglePanel(.git) },
                        hideToolbar: { settings.toolbarVisibility = .hide }
                    )
                }
            }
            .background(
                settings.isTerminalBackgroundTranslucent
                    ? Color.clear
                    : Color(nsColor: Theme.background)
            )

            // Dropping the hidden sidebar also drops its expanded file tree
            // and process snapshot. Git stays window-owned because the toolbar
            // remains visible while this panel is closed.
            if manager.isPanelVisible {
                RightSidebarView(manager: manager, git: git)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            TerminalParkingView(
                sessions: parkedTerminalSessions,
                manager: manager
            )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            if manager.isCommandPaletteVisible {
                CommandPaletteView(manager: manager)
            }
        }
        .overlay {
            if tabSwitcher.isPresented, let project = manager.selectedProject {
                TabSwitcherOverlay(project: project, controller: tabSwitcher)
                    .zIndex(10)
            }
        }
        .background {
            TabSwitcherEventMonitor(manager: manager, controller: tabSwitcher)
                .frame(width: 0, height: 0)
        }
        .background(WindowChromeAccessor {
            manager.attach(to: $0)
        })
        .onAppear { syncGit() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            syncGit()
        }
        .onChange(of: commandCompletionSequences) { syncGit() }
        .onChange(of: manager.selectedProjectID) {
            tabSplitDrag.cancel()
            syncGit()
        }
        .onChange(of: manager.selectedSession?.id) { syncGit() }
        .onChange(of: manager.selectedSession?.workingDirectory) { syncGit() }
        .onChange(of: manager.selectedSession?.foregroundDirectoryPath) { syncGit() }
        .onChange(of: manager.selectedProject?.customDirectory) { syncGit() }
        .onChange(of: colorScheme) {
            manager.refreshAppearance()
        }
    }

    /// Sessions in the visible tab are owned by `TerminalHostView`; every
    /// other session stays window-attached in the invisible parking host.
    private var parkedTerminalSessions: [TerminalSession] {
        let visibleIDs = Set(
            manager.selectedProject?.selectedTab?.sessions.map(\.id) ?? []
        )
        return manager.projects
            .flatMap(\.sessions)
            .filter { !visibleIDs.contains($0.id) }
    }

    /// Pane gaps hide retained diff views unless a diff or an all-terminal tab
    /// needs the window behind this layer to remain visible.
    private var paneLayerIsOpaque: Bool {
        guard let tab = manager.selectedProject?.selectedTab else { return true }
        if !tab.diffs.isEmpty { return false }
        guard !tab.sessions.isEmpty,
              tab.sessions.count == tab.allPanes.count
        else { return true }
        return !settings.isTerminalBackgroundTranslucent
    }

    private func syncGit() {
        guard let project = manager.selectedProject,
              let session = project.selectedSession else {
            git.configureRemote(nil)
            git.sync(root: "")
            return
        }
        if let endpoint = project.remoteEndpoint {
            git.configureRemote(endpoint)
            git.sync(root: project.remoteDirectory ?? "~")
            return
        }
        git.configureRemote(nil)
        let root = project.panelRoot(
            followingSessionAt: session.currentDirectoryPath,
            foregroundAt: session.foregroundDirectoryPath
        ).root
        git.sync(root: root)
    }

    @ViewBuilder
    private var emptyState: some View {
        if manager.selectedProject == nil {
            emptyStatePrompt(
                title: "No open projects",
                buttonTitle: "New Project  ⌘N",
                action: { manager.newProject() }
            )
        } else {
            // A project whose tabs were all closed stays open; offer to reopen
            // a session rather than showing the no-projects prompt.
            emptyStatePrompt(
                title: "No open sessions",
                buttonTitle: "New Session  ⌘T",
                action: { manager.newSession() }
            )
        }
    }

    private func emptyStatePrompt(
        title: LocalizedStringKey,
        buttonTitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(.secondary)
            Button(buttonTitle, action: action)
        }
    }
}

/// Project context for the active workspace. It stays deliberately compact so
/// terminal content remains the center of gravity below the tab strip.
private struct BottomToolbarView: View {
    @ObservedObject var model: GitStatusModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    let height: CGFloat
    let toggleGitPanel: () -> Void
    let hideToolbar: () -> Void

    private var scale: CGFloat { CGFloat(settings.interfaceScale) }

    @State private var isShowingBranches = false
    @State private var branchFilter = ""
    @State private var branchSearchFocusRequest: UInt = 0
    @State private var branchScrollRequest: UInt = 0
    @State private var isBranchButtonHovered = false
    @State private var isChangesButtonHovered = false
    @State private var isNoRepositoryButtonHovered = false
    @State private var hoveredBranch: String?

    private var filteredBranches: [String] {
        let query = branchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        var branches = query.isEmpty ? model.branches : model.branches.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
        if let current = model.branch,
           let index = branches.firstIndex(of: current), index != branches.startIndex {
            branches.remove(at: index)
            branches.insert(current, at: branches.startIndex)
        }
        return branches
    }

    private var changesAccessibilityValue: String {
        guard model.totalChangeCount > 0 else { return String(localized: "Clean") }
        return String(localized: "+\(model.lineAdditions), −\(model.lineDeletions)")
    }

    var body: some View {
        HStack(spacing: 9) {
            if model.isRepo {
                branchButton
                changesButton
            } else {
                noRepositoryButton
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 11 * scale))
        .padding(.horizontal, 10)
        .frame(height: height)
        .contentShape(Rectangle())
        .background {
            ToolbarContextMenuMonitor(hideToolbar: hideToolbar)
        }
        .background(Color(nsColor: Theme.background))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
        }
    }

    private var noRepositoryButton: some View {
        Button(action: toggleGitPanel) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("No Git Repository")
            }
            .padding(.horizontal, 6)
            .frame(height: 24 * scale)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        isNoRepositoryButtonHovered
                            ? Color.primary.opacity(0.08)
                            : Color.clear
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isNoRepositoryButtonHovered = $0 }
    }

    private var branchButton: some View {
        Button {
            toggleBranchPicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.accent))
                Text(verbatim: model.branch ?? "detached HEAD")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .frame(height: 24 * scale)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isBranchButtonHovered ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isBranchButtonHovered = $0 }
        .background {
            InstantPopoverPresenter(
                isPresented: $isShowingBranches,
                preferredEdge: .maxY,
                onPresent: {
                    guard isShowingBranches else { return }
                    branchSearchFocusRequest &+= 1
                    branchScrollRequest &+= 1
                },
                onDismiss: {
                    hoveredBranch = nil
                }
            ) {
                branchPicker
            }
        }
        .disabled(model.isBusy)
        .help("Switch Branch")
        .accessibilityLabel(
            String(localized: "Current branch, \(model.branch ?? String(localized: "detached HEAD"))")
        )
    }

    private var changesButton: some View {
        Button(action: toggleGitPanel) {
            HStack(spacing: 8) {
                if model.totalChangeCount == 0 {
                    Circle()
                        .fill(Color(red: 0.25, green: 0.73, blue: 0.31))
                        .frame(width: 6, height: 6)
                    Text("Clean")
                } else {
                    Text(verbatim: "+\(model.lineAdditions)")
                        .foregroundStyle(Color(red: 0.25, green: 0.73, blue: 0.31))
                        .monospacedDigit()
                    Text(verbatim: "−\(model.lineDeletions)")
                        .foregroundStyle(Color(red: 1.0, green: 0.48, blue: 0.45))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24 * scale)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isChangesButtonHovered ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isChangesButtonHovered = $0 }
        .help("Open Changes")
        .accessibilityLabel("Open Changes")
        .accessibilityValue(changesAccessibilityValue)
    }

    private var branchPicker: some View {
        VStack(spacing: 0) {
            BranchSearchField(
                text: $branchFilter,
                focusRequest: branchSearchFocusRequest
            ) {
                if filteredBranches.count == 1,
                   let branch = filteredBranches.first,
                   branch != model.branch {
                    selectBranch(branch)
                }
            }
            .frame(height: 22)
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filteredBranches.isEmpty {
                            Text("No matches")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(filteredBranches, id: \.self) { branch in
                                let isHovered = hoveredBranch == branch
                                Button {
                                    selectBranch(branch)
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .semibold))
                                            .opacity(branch == model.branch ? 1 : 0)
                                        Text(verbatim: branch)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        if branch == model.defaultBranch {
                                            Text(
                                                "default",
                                                comment: "Badge for the repository's default branch."
                                            )
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(
                                                isHovered
                                                    ? Color.white.opacity(0.85)
                                                    : Color(nsColor: .secondaryLabelColor)
                                            )
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(
                                                Capsule().fill(
                                                    isHovered
                                                        ? Color.white.opacity(0.18)
                                                        : Color.primary.opacity(0.07)
                                                )
                                            )
                                            .fixedSize()
                                        }
                                    }
                                    .foregroundStyle(isHovered ? Color.white : Color.primary)
                                    .padding(.horizontal, 9)
                                    .frame(height: 26)
                                    .background {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(
                                                isHovered
                                                    ? Color(nsColor: .selectedContentBackgroundColor)
                                                    : Color.clear
                                            )
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { isHovered in
                                    if isHovered {
                                        hoveredBranch = branch
                                    } else if hoveredBranch == branch {
                                        hoveredBranch = nil
                                    }
                                }
                                .disabled(branch == model.branch || model.isBusy)
                                .id(branch)
                            }
                        }
                    }
                    .padding(5)
                }
                .onChange(of: branchScrollRequest) {
                    guard let branch = model.branch else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(branch, anchor: .top)
                    }
                }
            }
        }
        .font(.system(size: 11))
        .frame(width: 260, height: 250)
        .background {
            VisualEffectView(material: .popover)
                .ignoresSafeArea()
        }
    }

    private func toggleBranchPicker() {
        if !isShowingBranches { branchFilter = "" }
        isShowingBranches.toggle()
    }

    private func selectBranch(_ branch: String) {
        isShowingBranches = false
        model.switchBranch(to: branch)
    }
}

/// NSSearchField supplies the standard macOS bezel, magnifier, clear button,
/// focus ring, and vibrancy-aware colors inside the native popover.
private struct BranchSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UInt
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.placeholderString = String(localized: "Filter branches")
        field.setAccessibilityLabel(String(localized: "Filter branches"))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
        guard context.coordinator.handledFocusRequest != focusRequest else { return }
        context.coordinator.handledFocusRequest = focusRequest
        context.coordinator.focus(field)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: BranchSearchField
        var handledFocusRequest: UInt?

        init(parent: BranchSearchField) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest == 0 ? 0 : nil
        }

        func focus(_ field: NSSearchField, attemptsRemaining: Int = 6) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                if let window = field.window, window.makeFirstResponder(field) { return }
                guard attemptsRemaining > 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.focus(field, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            parent.text = textView.string
            parent.onSubmit()
            return true
        }
    }
}

/// SwiftUI anchors a context menu to this full-width toolbar view. A local
/// AppKit monitor retains the same hit area while presenting from the actual
/// right-click event, so the menu appears at the pointer instead.
private struct ToolbarContextMenuMonitor: NSViewRepresentable {
    let hideToolbar: () -> Void

    func makeNSView(context: Context) -> ToolbarContextMenuMonitorView {
        let view = ToolbarContextMenuMonitorView()
        view.hideToolbar = hideToolbar
        return view
    }

    func updateNSView(_ nsView: ToolbarContextMenuMonitorView, context: Context) {
        nsView.hideToolbar = hideToolbar
    }

    static func dismantleNSView(
        _ nsView: ToolbarContextMenuMonitorView,
        coordinator: ()
    ) {
        nsView.detach()
    }
}

@MainActor
private final class ToolbarContextMenuMonitorView: NSView {
    var hideToolbar: () -> Void = {}
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
            [weak self, weak window] event in
            let input = ToolbarContextMenuEvent(event)
            let output: ToolbarContextMenuEvent = MainActor.assumeIsolated {
                guard let self,
                      let window,
                      let event = input.value,
                      event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return input }

                let menu = NSMenu()
                let hideItem = NSMenuItem(
                    title: String(localized: "Hide"),
                    action: #selector(self.hideToolbarFromMenu),
                    keyEquivalent: ""
                )
                hideItem.target = self
                menu.addItem(hideItem)
                menu.update()
                var screenPoint = window.convertPoint(toScreen: event.locationInWindow)
                // The toolbar sits at the screen's lower edge. Position the
                // menu upward so its bottom edge, rather than its top edge,
                // meets the pointer without AppKit relocating the whole menu.
                screenPoint.y += menu.size.height
                _ = menu.popUp(positioning: nil, at: screenPoint, in: nil)
                return ToolbarContextMenuEvent(nil)
            }
            return output.value
        }
    }

    @objc private func hideToolbarFromMenu() {
        hideToolbar()
    }

    func detach() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}

/// Local event monitors run synchronously on AppKit's main event thread.
private struct ToolbarContextMenuEvent: @unchecked Sendable {
    let value: NSEvent?

    init(_ value: NSEvent?) {
        self.value = value
    }
}

/// A single AppKit-owned popover avoids SwiftUI's re-entrant presentation path:
/// rapid binding changes reconcile against `isShown`, and generation checks
/// prevent a stale close callback from dismissing a newer presentation.
private struct InstantPopoverPresenter<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let onPresent: () -> Void
    let onDismiss: () -> Void
    let content: () -> PopoverContent

    init(
        isPresented: Binding<Bool>,
        preferredEdge: NSRectEdge,
        onPresent: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) {
        _isPresented = isPresented
        self.preferredEdge = preferredEdge
        self.onPresent = onPresent
        self.onDismiss = onDismiss
        self.content = content
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: InstantPopoverPresenter
        let popover: NSPopover
        let hostingController: NSHostingController<PopoverContent>
        private var presentationGeneration: UInt = 0

        init(parent: InstantPopoverPresenter) {
            self.parent = parent
            popover = NSPopover()
            hostingController = NSHostingController(rootView: parent.content())
            super.init()
            popover.animates = false
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = hostingController
        }

        func reconcile(parent: InstantPopoverPresenter, anchor: NSView) {
            self.parent = parent
            hostingController.rootView = parent.content()
            popover.animates = false

            if parent.isPresented {
                guard !popover.isShown, anchor.window != nil else { return }
                presentationGeneration &+= 1
                hostingController.view.layoutSubtreeIfNeeded()
                let fittingSize = hostingController.view.fittingSize
                if fittingSize.width > 0, fittingSize.height > 0 {
                    popover.contentSize = fittingSize
                }
                popover.show(
                    relativeTo: anchor.bounds,
                    of: anchor,
                    preferredEdge: parent.preferredEdge
                )
            } else if popover.isShown {
                popover.close()
            }
        }

        func popoverWillShow(_ notification: Notification) {
            popover.animates = false
        }

        func popoverDidShow(_ notification: Notification) {
            let generation = presentationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      self.popover.isShown,
                      self.parent.isPresented else { return }
                self.parent.onPresent()
            }
        }

        func popoverWillClose(_ notification: Notification) {
            popover.animates = false
        }

        func popoverDidClose(_ notification: Notification) {
            let generation = presentationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      !self.popover.isShown else { return }
                self.parent.onDismiss()
                if self.parent.isPresented {
                    self.parent.isPresented = false
                }
            }
        }

        func dismantle() {
            popover.delegate = nil
            popover.animates = false
            popover.close()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.reconcile(parent: self, anchor: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismantle()
    }
}
