//
//  AppKitProjectSidebarView.swift
//  zshell
//

import AppKit
import Combine
import SwiftUI

struct ProjectSidebarRepresentable: NSViewRepresentable {
    let manager: TerminalManager
    let tabDrag: TabSplitDragCoordinator
    let bottomBarHeight: CGFloat

    func makeNSView(context: Context) -> ProjectSidebarNSView {
        ProjectSidebarNSView(manager: manager, tabDrag: tabDrag, bottomBarHeight: bottomBarHeight)
    }

    func updateNSView(_ view: ProjectSidebarNSView, context: Context) {
        view.bottomBarHeight = bottomBarHeight
        view.refresh()
    }

    static func dismantleNSView(_ view: ProjectSidebarNSView, coordinator: ()) { view.detach() }
}

private final class ProjectSidebarDocumentView: NSView {
    var onDoubleClick: ((NSEvent) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
        else if event.clickCount == 2 { onDoubleClick?(event) }
    }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
}

private enum ProjectSidebarRow: Hashable {
    case workspace(ProjectSidebarItem)
    case tab(project: UUID, tab: UUID)
    case pane(project: UUID, tab: UUID, content: UUID)

    var projectID: UUID? {
        switch self {
        case .workspace(.project(let id)): id
        case .workspace(.group): nil
        case .tab(let project, _), .pane(let project, _, _): project
        }
    }
}

private final class ProjectSidebarOutlineView: NSView {
    var footerHeight: CGFloat = 0
    var drawsOuterEdge = false
    var dropFrame: NSRect?
    var workspaceDropFrame: NSRect?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: 1).fill()
        if drawsOuterEdge { NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill() }
        if let dropFrame {
            let path = NSBezierPath(roundedRect: dropFrame.insetBy(dx: 4, dy: 4), xRadius: 6, yRadius: 6)
            Theme.accent.setStroke()
            path.lineWidth = 2
            path.setLineDash([5, 4], count: 2, phase: 0)
            path.stroke()
        }
        if let workspaceDropFrame {
            let path = NSBezierPath(
                roundedRect: workspaceDropFrame.insetBy(dx: 4, dy: 4),
                xRadius: 6,
                yRadius: 6
            )
            Theme.accent.withAlphaComponent(0.18).setFill()
            path.fill()
            Theme.accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}

private final class ProjectSidebarScroller: NSScroller {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        drawKnob()
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let thickness: CGFloat = 1
        let rect = NSRect(
            x: knob.midX - thickness / 2,
            y: knob.minY,
            width: thickness,
            height: knob.height
        )
        NSColor.labelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }
}

final class ProjectSidebarNSView: NSView {
    private typealias Item = ProjectSidebarItem
    private let manager: TerminalManager
    private let tabDrag: TabSplitDragCoordinator
    private let groupStore = ProjectGroupStore.shared
    private let material = NSVisualEffectView()
    private let outline = ProjectSidebarOutlineView()
    private let windowDrag = WorkspaceWindowDragView()
    private let scrollView = NSScrollView()
    private let document = ProjectSidebarDocumentView()
    private let sidebarButton = WorkspaceChromeButton(symbol: "sidebar.left", label: AppCommand.toggleLeftSidebar.title)
    private let historyButton = WorkspaceChromeButton(symbol: "clock.arrow.circlepath", label: String(localized: "Agent Conversation History"))
    private let updateButton = WorkspaceChromeButton(symbol: "arrow.down.circle", label: String(localized: "Update Available")) {
        Updater.shared.showAvailableUpdate()
    }
    private let fpsLabel = NSTextField(labelWithString: "")
    private let fpsCounter = FPSCounter()
    private let menuPresenter = AppKitContextMenuMonitorView()
    private var footerButtons: [WorkspaceChromeButton] = []
    private var rows: [Item: WorkspaceItemView] = [:]
    private var order: [Item] = []
    private var contentRows: [UUID: WorkspaceItemView] = [:]
    private var rowOrder: [ProjectSidebarRow] = []
    private var rowFrames: [ProjectSidebarRow: NSRect] = [:]
    private var projectIndex: [UUID: Project] = [:]
    private var reusableRows: [WorkspaceItemView] = []
    private let metadata = ProjectSidebarMetadata()
    private var metadataTimer: AnyCancellable?
    private var lastContentSelection: UUID?
    private var observations: [AnyCancellable] = []
    private var refreshScheduled = false
    private var lastSelection: UUID?
    private var revealSelection = true
    private var draggedItem: Item?
    private var dropItem: Item?
    private var isUngroupedWorkspaceDropTarget = false
    private var isUngroupedFooterDropTarget = false
    private var isFolderDropTarget = false {
        didSet { outline.dropFrame = isFolderDropTarget ? scrollView.frame : nil; outline.needsDisplay = true }
    }
    var bottomBarHeight: CGFloat { didSet { if oldValue != bottomBarHeight { needsLayout = true } } }
    override var isFlipped: Bool { true }
    private var scale: CGFloat { CGFloat(AppSettings.shared.interfaceScale) }
    private var metrics: SidebarLayoutMetrics { SidebarLayoutMetrics(fontSize: AppSettings.shared.sidebarFontSize) }
    private var fontScale: CGFloat { metrics.fontScale * scale }
    private var groupMemberIndent: CGFloat { 18 * scale }

    init(manager: TerminalManager, tabDrag: TabSplitDragCoordinator, bottomBarHeight: CGFloat) {
        self.manager = manager
        self.tabDrag = tabDrag
        self.bottomBarHeight = bottomBarHeight
        super.init(frame: .zero)
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.setAccessibilityElement(false)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller = ProjectSidebarScroller()
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        document.onDoubleClick = { [weak self] event in
            guard let self, AppSettings.shared.sidebarDoubleClickNewSession,
                  self.isBlankSpace(at: event) else { return }
            self.manager.newSession()
        }
        document.onContextMenu = { [weak self] event in
            guard let self, self.isBlankSpace(at: event) else { return }
            self.menuPresenter.popUp(items: self.sidebarMenu(),
                at: self.document.convert(event.locationInWindow, from: nil), in: self.document)
        }
        metadata.onChange = { [weak self] in self?.scheduleRefresh() }
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        fpsLabel.textColor = .secondaryLabelColor
        fpsLabel.isHidden = true
        addSubview(material)
        for view in [windowDrag, scrollView, fpsLabel, historyButton, sidebarButton] { addSubview(view) }
        sidebarButton.onAction = { [weak manager] in manager?.toggleLeftSidebar() }
        historyButton.onAction = { [weak manager] in manager?.showConversationHistory() }
        footerButtons = [
            WorkspaceChromeButton(symbol: "plus", label: AppCommand.newProject.title) { [weak manager] in manager?.newProject() },
            WorkspaceChromeButton(symbol: "folder.badge.plus", label: String(localized: "New Group")) { [weak self] in self?.showNewGroupMenu() },
            WorkspaceChromeButton(symbol: "network", label: String(localized: "Remote Connections")) { [weak self] in self?.showRemoteMenu() },
            WorkspaceChromeButton(symbol: "bolt", label: String(localized: "Quick Launch (⌘O)")) { [weak manager] in manager?.toggleQuickLaunch() },
            WorkspaceChromeButton(symbol: "exclamationmark.bubble", label: String(localized: "Send Feedback")) {
                NSWorkspace.shared.open(URL(string: "https://github.com/wzz6423/zshell/issues/new")!)
            },
            WorkspaceChromeButton(symbol: "gearshape", label: String(localized: "Settings (⌘,)")) { SettingsWindowController.shared.show() },
        ]
        footerButtons.forEach(addSubview)
        addSubview(updateButton)
        addSubview(outline)
        outline.setAccessibilityElement(false)
        for publisher in [manager.objectWillChange.eraseToAnyPublisher(),
                          Updater.shared.objectWillChange.eraseToAnyPublisher(),
                          groupStore.objectWillChange.eraseToAnyPublisher(),
                          AppSettings.shared.objectWillChange.eraseToAnyPublisher(),
                          Theme.changes.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &observations)
        }
        tabDrag.$sidebarDropHighlight.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateDropHighlights() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            .sink { [weak self] _ in
                self?.updateVisibleContentRows()
                self?.publishDropFrames()
                self?.refreshVisibleMetadata()
            }.store(in: &observations)
        fpsCounter.$fps.sink { [weak self] fps in self?.fpsLabel.stringValue = "\(fps) fps" }.store(in: &observations)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        var items: [Item] = []
        for item in manager.sidebarTopLevelItems {
            items.append(item)
            guard case .group(let id) = item,
                  let group = groupStore.group(id: id),
                  !group.isCollapsed else { continue }
            items += manager.projects.filter { $0.groupID == id }.map { .project($0.id) }
        }
        let valid = Set(items)
        for key in rows.keys where !valid.contains(key) { rows.removeValue(forKey: key)?.removeFromSuperview() }
        order = items
        rowOrder = []
        projectIndex = Dictionary(uniqueKeysWithValues: manager.projects.map { ($0.id, $0) })
        let shortcuts = Dictionary(uniqueKeysWithValues: manager.visibleSidebarProjects.prefix(9).enumerated().map {
            ($0.element.id, "⌘\($0.offset + 1)")
        })
        for item in items {
            let row = rows[item] ?? WorkspaceItemView(frame: .zero)
            if rows[item] == nil { rows[item] = row; document.addSubview(row) }
            switch item {
            case .project(let id):
                guard let project = manager.projects.first(where: { $0.id == id }) else { continue }
                configure(row, project: project, shortcut: shortcuts[id])
                rowOrder.append(.workspace(item))
                if AppSettings.shared.showSidebarSessions && project.isSidebarExpanded {
                    for tab in project.tabs {
                        let key = ProjectSidebarRow.tab(project: id, tab: tab.id)
                        rowOrder.append(key)
                        if tab.hasMultiplePanes && tab.isSidebarExpanded {
                            for pane in tab.allPanes {
                                let key = ProjectSidebarRow.pane(project: id, tab: tab.id, content: pane.content.id)
                                rowOrder.append(key)
                            }
                        }
                    }
                }
            case .group(let id):
                guard let group = groupStore.group(id: id) else { continue }
                configure(row, group: group)
                rowOrder.append(.workspace(item))
            }
            row.onDrag = { [weak self] event in self?.updateDrag(item: item, event: event) }
            row.onDragEnded = { [weak self] event in self?.finishDrag(item: item, event: event) }
            row.onDragCancelled = { [weak self] in self?.cancelDrag() }
            row.onNavigate = { [weak self] key in self?.navigate(from: .workspace(item), key: key) }
        }
        if lastSelection != manager.selectedProjectID { lastSelection = manager.selectedProjectID; revealSelection = true }
        let contentSelection = manager.selectedProject?.focusedContent?.id
        if lastContentSelection != contentSelection { lastContentSelection = contentSelection; revealSelection = true }
        updateMetadataTimer()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        material.isHidden = !Theme.isDefault(dark: dark)
        outline.drawsOuterEdge = material.isHidden
        outline.needsDisplay = true
        sidebarButton.configure(symbol: "sidebar.left", command: .toggleLeftSidebar, pointSize: 12 * scale)
        historyButton.configure(symbol: "clock.arrow.circlepath", label: String(localized: "Agent Conversation History"), pointSize: 12 * scale)
        footerButtons[0].configure(symbol: "plus", command: .newProject, pointSize: 12 * scale)
        let footerItems = [
            ("folder.badge.plus", String(localized: "New Group")),
            ("network", String(localized: "Remote Connections")),
            ("bolt", String(localized: "Quick Launch (⌘O)")),
            ("exclamationmark.bubble", String(localized: "Send Feedback")),
            ("gearshape", String(localized: "Settings (⌘,)")),
        ]
        for (button, item) in zip(footerButtons.dropFirst(), footerItems) {
            button.configure(symbol: item.0, label: item.1, pointSize: 12 * scale)
        }
        updateButton.isHidden = Updater.shared.availableUpdateVersion == nil
        let updateLabel = Updater.shared.availableUpdateVersion.map { String(localized: "Update available: \($0)") }
            ?? String(localized: "Update Available")
        updateButton.toolTip = updateLabel
        updateButton.setAccessibilityLabel(updateLabel)
        updateButton.image = NSImage(named: "UpdateAvailable")?.copy() as? NSImage
        updateButton.image?.size = NSSize(width: 16 * scale, height: 16 * scale)
        if manager.isFPSCounterVisible, window != nil { fpsCounter.start() } else { fpsCounter.stop() }
        updateDropHighlights()
        needsLayout = true
        needsDisplay = true
    }

    private func configure(_ row: WorkspaceItemView, project: Project, shortcut: String?) {
        let subtitle: String?
        if project.sharedHost != nil { subtitle = project.selectedSession?.remoteStatus?.label ?? String(localized: "Connecting…") }
        else if project.sessions.count > 1 { subtitle = String(localized: "\(project.sessions.count) sessions") }
        else { subtitle = project.selectedSession?.directoryLabel }
        let groupColor = groupStore.group(id: project.groupID).map {
            $0.markerColor ?? .defaultColor
        }
        let title = project.sharedHost.map { "\(project.name) — \($0.name)" } ?? project.name
        row.apply(title: title, subtitle: subtitle,
                  icon: NSImage(systemSymbolName: project.isRemote ? "network" : "folder", accessibilityDescription: nil),
                  selected: project.id == manager.selectedProjectID, pinned: project.isPinned,
                  marker: groupColor ?? project.markerColor, rollup: project.agentRollup, sidebar: true,
                  compactRow: AppSettings.shared.compactSidebar,
                  expanded: AppSettings.shared.showSidebarSessions && !project.tabs.isEmpty ? project.isSidebarExpanded : nil,
                  disclosureLabel: String(localized: project.isSidebarExpanded ? "Hide Sessions" : "Show Sessions"),
                  indent: project.groupID == nil ? 0 : groupMemberIndent, scale: fontScale, shortcut: shortcut,
                  actionLabel: String(localized: "Close Project"), action: { [weak manager, weak project] in
                      if let project { manager?.close(project) }
                  })
        row.toolTip = [project.name, project.customDirectory ?? subtitle].compactMap { $0 }.joined(separator: "\n")
        row.onSelect = { [weak manager, weak project] in if let project { manager?.selectedProjectID = project.id } }
        row.onDisclosure = { [weak project] in project?.isSidebarExpanded.toggle() }
        row.onRename = { [weak row, weak project] in
            guard let project else { return }
            row?.beginRename(value: project.name) { [weak project] name in project?.customName = Project.normalizedCustomName(name) }
        }
        row.menuItems = { [weak self, weak row, weak project] in
            guard let self, let project else { return [] }
            return self.projectMenu(project, row: row)
        }
    }

    private func configure(_ row: WorkspaceItemView, group: ProjectGroup) {
        let count = manager.projects.filter { $0.groupID == group.id }.count
        row.apply(title: group.name, icon: nil,
                  selected: manager.selectedProject?.groupID == group.id, group: true, collapsed: group.isCollapsed,
                  marker: group.markerColor ?? .defaultColor, count: count, sidebar: true,
                  fillsGroupRow: true, scale: fontScale, groupControlScale: scale)
        row.toolTip = [group.name, group.folderPath].compactMap { $0 }.joined(separator: "\n")
        row.onSelect = { [weak groupStore] in
            guard var current = groupStore?.group(id: group.id) else { return }
            current.isCollapsed.toggle()
            groupStore?.update(current)
        }
        row.onRename = { [weak row, weak groupStore] in
            guard let current = groupStore?.group(id: group.id) else { return }
            row?.beginRename(value: current.name) { [weak groupStore] name in
                guard let name = Project.normalizedCustomName(name),
                      var current = groupStore?.group(id: group.id) else { return }
                current.name = name
                groupStore?.update(current)
            }
        }
        row.menuItems = { [weak self, weak row] in
            guard let self, let current = self.groupStore.group(id: group.id) else { return [] }
            var items: [AppKitContextMenuItem] = [
                .action(title: String(localized: "New Project in Group")) { self.manager.newProject(in: current) },
                .action(title: String(localized: "Rename…")) { row?.onRename?() },
                .action(title: String(localized: current.isCollapsed ? "Expand Group" : "Collapse Group")) { row?.onSelect?() },
            ]
            if current.folderPath != nil {
                items.append(.action(title: String(localized: "Change Folder…")) { [weak self] in self?.changeFolder(group: current) })
            }
            items += [
                .separator,
                .action(title: String(localized: "Set Color Marker…")) {
                    guard let latest = self.groupStore.group(id: group.id) else { return }
                    // The shared color panel can outlive a hidden sidebar.
                    ProjectTabColorPanelController.shared.present(
                        group: latest,
                        apply: { [weak groupStore = self.groupStore] color in
                            guard let groupStore, var updated = groupStore.group(id: group.id) else { return }
                            updated.markerColor = color
                            groupStore.update(updated)
                        },
                        hostWindow: row?.window
                    )
                },
            ]
            if current.markerColor != nil {
                items.append(.action(title: String(localized: "Remove Color Marker")) { [weak self] in
                    guard let self, var updated = self.groupStore.group(id: group.id) else { return }
                    updated.markerColor = nil
                    self.groupStore.update(updated)
                })
            }
            items += [.separator, .action(title: String(localized: "Remove Group")) { self.manager.deleteProjectGroup(current) }]
            return items
        }
    }

    private func configure(_ row: WorkspaceItemView, tab: PaneTab, project: Project) {
        let content = tab.focusedContent
        let expanded = tab.hasMultiplePanes ? tab.isSidebarExpanded : nil
        let groupColor = project.tabGroup(id: tab.tabGroupID)?.markerColor
        let selected = project.id == manager.selectedProjectID && tab.id == project.selectedTabID
        row.apply(title: tab.displayTitle ?? String(localized: "Tab"), subtitle: content.map(metadataLabel),
                  icon: content.flatMap(contentIcon), selected: selected, pinned: tab.isPinned,
                  marker: groupColor ?? tab.markerColor, count: tab.hasMultiplePanes ? tab.allPanes.count : nil,
                  rollup: tab.agentRollup, dirty: content?.isDirty == true, sidebar: true,
                  compactRow: AppSettings.shared.compactSidebar, expanded: expanded,
                  disclosureLabel: String(localized: tab.isSidebarExpanded ? "Hide Panes" : "Show Panes"),
                  indent: (project.groupID == nil ? 0 : groupMemberIndent) + 16 * scale, scale: fontScale,
                  actionLabel: String(localized: "Close Tab"), action: { [weak project, weak tab] in
                      if let tab { project?.close(tab) }
                  })
        row.toolTip = [tab.displayTitle, content.map(metadataLabel), tab.agentRollup?.detail].compactMap { $0 }.joined(separator: "\n")
        row.onSelect = { [weak manager, weak tab] in
            guard let contentID = tab?.focusedContent?.id else { return }
            manager?.revealPane(contentID: contentID)
        }
        row.onDisclosure = { [weak tab] in tab?.isSidebarExpanded.toggle() }
        row.onRename = { [weak row, weak tab] in
            guard let tab else { return }
            row?.beginRename(value: tab.displayTitle ?? "") { [weak tab] in tab?.customName = Project.normalizedCustomName($0) }
        }
        row.menuItems = { [weak self, weak row, weak project, weak tab] in
            guard let self, let project, let tab else { return [] }
            var items: [AppKitContextMenuItem] = [
                .action(title: String(localized: "Focus Pane")) { row?.onSelect?() },
                .action(title: String(localized: "Rename…")) { row?.onRename?() },
                .action(title: String(localized: tab.isPinned ? "Unpin Tab" : "Pin Tab")) { project.setPinned(!tab.isPinned, for: tab) },
            ]
            if tab.hasMultiplePanes {
                items.append(.action(title: String(localized: tab.isSidebarExpanded ? "Hide Panes" : "Show Panes")) { tab.isSidebarExpanded.toggle() })
            }
            if tab.customName != nil { items.append(.action(title: String(localized: "Use Automatic Title")) { tab.customName = nil }) }
            items += [.separator, .action(title: String(localized: "Close Tab")) { project.close(tab) },
                      .separator, .submenu(title: String(localized: "Project Sidebar"), items: self.sidebarMenu())]
            return items
        }
    }

    private func configure(_ row: WorkspaceItemView, pane: Pane, tab: PaneTab, project: Project) {
        let selected = project.id == manager.selectedProjectID && tab.id == project.selectedTabID && pane.id == tab.focusedPaneID
        let rollup: ZshellAgentRollup?
        if case .session(let session) = pane.content { rollup = session.agentRollup }
        else { rollup = nil }
        row.apply(title: pane.content.title, subtitle: metadataLabel(pane.content), icon: contentIcon(pane.content),
                  selected: selected, rollup: rollup, dirty: pane.content.isDirty, sidebar: true,
                  compactRow: AppSettings.shared.compactSidebar,
                  indent: (project.groupID == nil ? 0 : groupMemberIndent) + 32 * scale, scale: fontScale)
        row.toolTip = [pane.content.title, metadataLabel(pane.content), rollup?.detail].compactMap { $0 }.joined(separator: "\n")
        row.onSelect = { [weak manager] in manager?.revealPane(contentID: pane.content.id) }
        row.onRename = nil
        row.onDisclosure = nil
        row.menuItems = { [weak self, weak row, weak project, weak tab] in
            guard let self, let project, let tab,
                  let current = tab.allPanes.first(where: { $0.content.id == pane.content.id }) else { return [] }
            return [
                .action(title: String(localized: "Focus Pane")) { row?.onSelect?() },
                .action(title: String(localized: "Toggle Pane Zoom"), enabled: tab.hasMultiplePanes) { [weak manager = self.manager] in
                    guard manager?.revealPane(contentID: current.content.id) == true else { return }
                    tab.toggleZoom()
                },
                .separator,
                .action(title: String(localized: "Close Pane")) { project.closeContent(current.content) },
            ]
        }
    }

    private func contentIcon(_ content: PaneContent) -> NSImage? {
        if let path = content.fileIconPath { return MaterialFileIcon.image(forPath: path, appearance: effectiveAppearance) }
        if case .browser(let browser) = content, let favicon = browser.favicon { return favicon }
        return NSImage(systemSymbolName: content.systemImage, accessibilityDescription: nil)
    }

    private func metadataLabel(_ content: PaneContent) -> String {
        switch content {
        case .session(let session):
            let entry = metadata.entry(for: session.id)
            let program = session.agentStatus.map { $0.kind == .program ? $0.alias : $0.kind.displayName } ?? entry?.program ?? session.shellName
            let directory = entry?.directory ?? session.remoteConnection?.projectDirectory
                ?? session.workingDirectory.flatMap { URL(string: $0)?.path ?? $0 }
            let tail = directory.map { ($0 as NSString).lastPathComponent }
            let state = session.hasExited ? String(localized: "Exited") : session.remoteStatus?.label
            return [program, entry?.branch.map { "⑂ \($0)" }, tail, state].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .file(let file): return file.path
        case .browser(let browser): return URL(string: browser.urlString)?.host ?? browser.title
        case .diff(let diff): return diff.path
        }
    }

    private func row(for key: ProjectSidebarRow) -> WorkspaceItemView? {
        switch key {
        case .workspace(let item): rows[item]
        case .tab(_, let id), .pane(_, _, let id): contentRows[id]
        }
    }

    private func sidebarMenu() -> [AppKitContextMenuItem] {
        [
            .action(title: AppCommand.newSession.title) { [weak manager] in manager?.newSession() },
            .separator,
            .action(title: String(localized: AppSettings.shared.showSidebarSessions ? "Hide session and pane list" : "Show session and pane list")) {
                AppSettings.shared.showSidebarSessions.toggle()
            },
            .action(title: String(localized: AppSettings.shared.compactSidebar ? "Use regular sidebar" : "Use compact sidebar")) {
                AppSettings.shared.compactSidebar.toggle()
            },
            .action(title: String(localized: "Sidebar Settings…")) { SettingsWindowController.shared.show(category: .appearance) },
        ]
    }

    private func isBlankSpace(at event: NSEvent) -> Bool {
        guard let point = documentPoint(at: event), document.bounds.contains(point),
              draggedItem == nil, !isFolderDropTarget,
              tabDrag.drag == nil, tabDrag.paneDrag == nil,
              tabDrag.projectDrag == nil, tabDrag.groupDrag == nil,
              !rowFrames.values.contains(where: { $0.contains(point) }) else { return false }
        return !order.contains { item in
            guard case .group = item, let frame = rows[item]?.frame else { return false }
            return frame.insetBy(dx: -8, dy: -4).contains(point)
        }
    }

    private func updateMetadataTimer() {
        let active = window != nil && manager.isLeftSidebarVisible && AppSettings.shared.showSidebarSessions
            && rowOrder.contains { if case .workspace = $0 { return false }; return true }
        if active && metadataTimer == nil {
            metadataTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.refreshVisibleMetadata() }
        } else if !active { metadataTimer = nil; metadata.clear() }
    }

    private func refreshVisibleMetadata() {
        guard window != nil, manager.isLeftSidebarVisible, AppSettings.shared.showSidebarSessions else { return }
        var sessions: [(session: TerminalSession, project: Project)] = []
        var seen = Set<UUID>()
        for key in rowOrder {
            guard let row = row(for: key), row.frame.intersects(document.visibleRect),
                  let projectID = key.projectID, let project = projectIndex[projectID] else { continue }
            let content: PaneContent?
            switch key {
            case .tab(_, let id): content = project.tabs.first(where: { $0.id == id })?.focusedContent
            case .pane(_, let tabID, let id): content = project.tabs.first(where: { $0.id == tabID })?.allContents.first(where: { $0.id == id })
            case .workspace: content = nil
            }
            if case .session(let session) = content, seen.insert(session.id).inserted { sessions.append((session, project)) }
        }
        metadata.refresh(sessions: sessions)
    }

    private func updateVisibleContentRows() {
        let viewport = document.visibleRect.insetBy(dx: 0, dy: -80)
        var visible = Set<UUID>()
        for key in rowOrder {
            guard let frame = rowFrames[key],
                  frame.intersects(viewport) || row(for: key)?.isRenaming == true,
                  let projectID = key.projectID,
                  let project = projectIndex[projectID] else { continue }
            let id: UUID
            let tab: PaneTab
            let pane: Pane?
            switch key {
            case .workspace: continue
            case .tab(_, let tabID):
                guard let current = project.tabs.first(where: { $0.id == tabID }) else { continue }
                id = tabID; tab = current; pane = nil
            case .pane(_, let tabID, let contentID):
                guard let current = project.tabs.first(where: { $0.id == tabID }),
                      let currentPane = current.allPanes.first(where: { $0.content.id == contentID }) else { continue }
                id = contentID; tab = current; pane = currentPane
            }
            visible.insert(id)
            let row = contentRows[id] ?? reusableRows.popLast() ?? WorkspaceItemView(frame: .zero)
            if contentRows[id] == nil { contentRows[id] = row; document.addSubview(row) }
            if let pane { configure(row, pane: pane, tab: tab, project: project) }
            else { configure(row, tab: tab, project: project) }
            row.onNavigate = { [weak self] keyCode in self?.navigate(from: key, key: keyCode) }
            row.frame = frame
        }
        for id in contentRows.keys where !visible.contains(id) {
            guard let row = contentRows.removeValue(forKey: id) else { continue }
            row.removeFromSuperview()
            row.onSelect = nil; row.onDisclosure = nil; row.onRename = nil; row.onNavigate = nil; row.menuItems = nil
            if !row.isRenaming && reusableRows.count < 12 { reusableRows.append(row) }
        }
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        outline.frame = bounds
        outline.footerHeight = bottomBarHeight
        outline.needsDisplay = true
        let headerHeight: CGFloat = 38
        let buttonSize = min(34, max(24, 24 * scale))
        sidebarButton.frame = NSRect(x: bounds.width - buttonSize - 8, y: (headerHeight - buttonSize) / 2, width: buttonSize, height: buttonSize)
        historyButton.frame = NSRect(x: sidebarButton.frame.minX - buttonSize - 4, y: sidebarButton.frame.minY, width: buttonSize, height: buttonSize)
        windowDrag.frame = NSRect(x: 0, y: 0, width: historyButton.frame.minX, height: headerHeight)
        fpsLabel.isHidden = !manager.isFPSCounterVisible || bounds.width < 250
        fpsLabel.frame = NSRect(x: historyButton.frame.minX - 55, y: 12, width: 52, height: 16)
        let footerY = max(headerHeight, bounds.height - bottomBarHeight)
        scrollView.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, footerY - headerHeight))
        let side = min(max(24, 26 * scale), max(0, (bounds.width - 16) / (updateButton.isHidden ? 6 : 7)))
        for (index, button) in footerButtons.enumerated() {
            let x = index < 4 ? 8 + CGFloat(index) * side : bounds.width - 8 - CGFloat(6 - index) * side
            button.frame = NSRect(x: x, y: footerY + (bottomBarHeight - side) / 2, width: side, height: side)
        }
        updateButton.frame = NSRect(x: bounds.width - 8 - 3 * side,
                                    y: footerY + (bottomBarHeight - side) / 2, width: side, height: side)
        var y: CGFloat = 7
        let rowWidth = max(0, scrollView.contentSize.width - 16)
        rowFrames.removeAll(keepingCapacity: true)
        for item in rowOrder {
            let height: CGFloat
            let width: CGFloat
            let x: CGFloat
            switch item {
            case .workspace(.project), .tab, .pane:
                height = AppSettings.shared.compactSidebar
                    ? max(28, ceil(16 * fontScale + 8))
                    : max(38, ceil(31 * fontScale + 8))
                width = rowWidth
                x = 8
            case .workspace(.group):
                height = min(30, max(26, ceil(14 * fontScale + 6)))
                width = rowWidth
                x = 8
                y += 5
            }
            let frame = NSRect(x: x, y: y, width: width, height: height)
            rowFrames[item] = frame
            if case .workspace = item { row(for: item)?.frame = frame }
            y += height + 3
        }
        document.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: max(scrollView.contentSize.height, y + 6))
        if revealSelection && draggedItem == nil {
            revealSelection = false
            let selected = manager.selectedProject
            if let selected, let tab = selected.selectedTab {
                let paneKey = tab.focusedContent.map { ProjectSidebarRow.pane(project: selected.id, tab: tab.id, content: $0.id) }
                let tabKey = ProjectSidebarRow.tab(project: selected.id, tab: tab.id)
                if let frame = paneKey.flatMap({ rowFrames[$0] }) ?? rowFrames[tabKey]
                    ?? rowFrames[.workspace(.project(selected.id))] { document.scrollToVisible(frame) }
            } else if let id = manager.selectedProjectID, let frame = rowFrames[.workspace(.project(id))] {
                document.scrollToVisible(frame)
            }
        }
        updateVisibleContentRows()
        publishDropFrames()
        refreshVisibleMetadata()
    }

    override func draw(_ dirtyRect: NSRect) {
        if material.isHidden { Theme.sidebar.setFill(); bounds.fill() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach() } else { refresh() }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    func detach() {
        fpsCounter.stop()
        metadataTimer = nil
        metadata.clear()
        draggedItem = nil
        dropItem = nil
        isUngroupedWorkspaceDropTarget = false
        isUngroupedFooterDropTarget = false
        outline.workspaceDropFrame = nil
        tabDrag.cancelProjectDrag()
        tabDrag.updateSidebarFrames(projects: [:], groups: [:], ungrouped: nil)
    }

    private func publishDropFrames() {
        guard window != nil else { return }
        var projects: [UUID: CGRect] = [:], groups: [UUID: CGRect] = [:]
        for (item, row) in rows {
            switch item {
            case .project(let id):
                let visible = row.bounds.intersection(row.convert(document.visibleRect, from: document))
                guard !visible.isEmpty else { continue }
                projects[id] = row.workspaceGlobalRect(visible)
            case .group(let id):
                let dropTarget = NSRect(
                    x: 0,
                    y: row.frame.minY - 4,
                    width: document.bounds.width,
                    height: row.frame.height + 8
                ).intersection(document.visibleRect)
                guard !dropTarget.isEmpty else { continue }
                groups[id] = document.workspaceGlobalRect(dropTarget)
            }
        }
        let newProjectButton = footerButtons[0]
        tabDrag.updateSidebarFrames(projects: projects, groups: groups,
            ungrouped: scrollView.workspaceGlobalRect(scrollView.bounds),
            ungroupedFooter: newProjectButton.workspaceGlobalRect(newProjectButton.bounds))
    }

    private func updateDropHighlights() {
        let tabDrop = tabDrag.sidebarDropHighlight
        for (item, row) in rows {
            let targeted: Bool
            switch (item, tabDrop) {
            case (.project(let id), .project(let target)): targeted = id == target
            case (.group(let id), .group(let target)): targeted = id == target
            default: targeted = false
            }
            row.isDropTarget = targeted || (item == dropItem && item != draggedItem)
        }
        let tabDropsOnWorkspace = tabDrop == .ungroupedWorkspace
        let tabDropsOnFooter = tabDrop == .ungroupedFooter
        outline.workspaceDropFrame = isUngroupedWorkspaceDropTarget || tabDropsOnWorkspace
            ? scrollView.frame
            : nil
        outline.needsDisplay = true
        footerButtons[0].highlight(isUngroupedFooterDropTarget || tabDropsOnFooter)
    }

    private func documentPoint(at event: NSEvent) -> NSPoint? {
        let point = convert(event.locationInWindow, from: nil)
        guard scrollView.frame.contains(point) else { return nil }
        return document.convert(point, from: self)
    }

    private func item(at event: NSEvent, extendingGroupTargets: Bool = false) -> Item? {
        guard let location = documentPoint(at: event) else { return nil }
        if let item = order.first(where: { rows[$0]?.frame.contains(location) == true }) {
            return item
        }
        guard extendingGroupTargets else { return nil }
        return order.first { item in
            guard case .group = item, let frame = rows[item]?.frame else { return false }
            return NSRect(
                x: 0,
                y: frame.minY - 4,
                width: document.bounds.width,
                height: frame.height + 8
            ).contains(location)
        }
    }

    private func updateDrag(item: Item, event: NSEvent) {
        draggedItem = item
        let candidate = self.item(at: event, extendingGroupTargets: true)
        if case .group = item {
            dropItem = candidate.flatMap(topLevelItem(containing:))
        } else {
            dropItem = candidate
        }
        let point = convert(event.locationInWindow, from: nil)
        isUngroupedWorkspaceDropTarget = false
        isUngroupedFooterDropTarget = false
        if case .project(let id) = item {
            isUngroupedWorkspaceDropTarget = dropItem == nil && scrollView.frame.contains(point)
            isUngroupedFooterDropTarget = footerButtons[0].frame.contains(point)
            tabDrag.updateProjectDrag(
                sourceProjectID: id,
                screenLocation: NSEvent.mouseLocation,
                manager: manager
            )
        } else if case .group(let id) = item {
            tabDrag.updateGroupDrag(
                sourceGroupID: id,
                screenLocation: NSEvent.mouseLocation,
                manager: manager
            )
        }
        updateDropHighlights()
        if scrollView.frame.contains(point) {
            var y = scrollView.contentView.bounds.minY
            if point.y < scrollView.frame.minY + 20 { y -= 12 }
            if point.y > scrollView.frame.maxY - 20 { y += 12 }
            let maximum = max(0, document.bounds.height - scrollView.contentSize.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maximum)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func finishDrag(item: Item, event: NSEvent) {
        let target = self.item(at: event, extendingGroupTargets: true)
        if case .project(let id) = item,
           let project = manager.projects.first(where: { $0.id == id }) {
            var handled = false
            switch target {
            case .group(let groupID):
                manager.moveProject(project, to: groupStore.group(id: groupID))
                handled = true
            case .project(let targetID):
                if targetID != id, let destination = manager.projects.first(where: { $0.id == targetID }) {
                    manager.moveProject(project, to: groupStore.group(id: destination.groupID))
                    if destination.groupID == nil {
                        manager.moveSidebarItem(.project(id), to: .project(targetID))
                    }
                    manager.moveProject(id, to: targetID)
                }
                handled = true
            case nil:
                let point = convert(event.locationInWindow, from: nil)
                if scrollView.frame.contains(point) || footerButtons[0].frame.contains(point) {
                    manager.moveProject(project, to: nil)
                    manager.moveSidebarItem(.project(id), to: nil)
                    handled = true
                }
            }
            if !handled {
                tabDrag.updateProjectDrag(
                    sourceProjectID: id,
                    screenLocation: NSEvent.mouseLocation,
                    manager: manager
                )
                tabDrag.commitProjectDrag()
            }
        } else if case .group(let groupID) = item {
            let point = convert(event.locationInWindow, from: nil)
            if let target = target.flatMap(topLevelItem(containing:)) {
                manager.moveSidebarItem(item, to: target)
            } else if scrollView.frame.contains(point) {
                manager.moveSidebarItem(item, to: nil)
            } else {
                tabDrag.updateGroupDrag(
                    sourceGroupID: groupID,
                    screenLocation: NSEvent.mouseLocation,
                    manager: manager
                )
                tabDrag.commitGroupDrag()
            }
        }
        cancelDrag()
    }

    private func topLevelItem(containing item: Item) -> Item? {
        switch item {
        case .group:
            return item
        case .project(let id):
            guard let project = manager.projects.first(where: { $0.id == id }) else { return nil }
            guard let groupID = project.groupID, groupStore.group(id: groupID) != nil else { return item }
            return .group(groupID)
        }
    }

    private func cancelDrag() {
        draggedItem = nil
        dropItem = nil
        isUngroupedWorkspaceDropTarget = false
        isUngroupedFooterDropTarget = false
        outline.workspaceDropFrame = nil
        tabDrag.cancelProjectDrag()
        updateDropHighlights()
        NSCursor.arrow.set()
    }

    private func navigate(from item: ProjectSidebarRow, key: UInt16) {
        if case .workspace(.group(let id)) = item, key == 123 || key == 124,
           var group = groupStore.group(id: id) {
            group.isCollapsed = key == 123
            groupStore.update(group)
            return
        }
        if AppSettings.shared.showSidebarSessions, key == 123 || key == 124 {
            switch item {
            case .workspace(.project(let id)):
                if let project = manager.projects.first(where: { $0.id == id }) {
                    if key == 123 || !project.isSidebarExpanded {
                        project.isSidebarExpanded = key == 124
                        return
                    }
                    if project.tabs.isEmpty { return }
                }
            case .tab(let projectID, let id):
                guard let project = manager.projects.first(where: { $0.id == projectID }),
                      let tab = project.tabs.first(where: { $0.id == id }) else { return }
                if key == 123 && !tab.isSidebarExpanded {
                    focusRow(.workspace(.project(projectID)))
                } else if tab.hasMultiplePanes {
                    if key == 124 && tab.isSidebarExpanded {
                        if let pane = tab.allPanes.first { focusRow(.pane(project: projectID, tab: id, content: pane.content.id)) }
                    } else { tab.isSidebarExpanded = key == 124 }
                } else if key == 123 { focusRow(.workspace(.project(projectID))) }
                return
            case .pane(let projectID, let tabID, _):
                if key == 123 { focusRow(.tab(project: projectID, tab: tabID)); return }
                return
            case .workspace(.group): break
            }
        }
        guard let index = rowOrder.firstIndex(of: item), !rowOrder.isEmpty else { return }
        let offset = key == 123 || key == 126 ? -1 : 1
        focusRow(rowOrder[(index + offset + rowOrder.count) % rowOrder.count])
    }

    private func focusRow(_ key: ProjectSidebarRow) {
        if let frame = rowFrames[key] { document.scrollToVisible(frame) }
        updateVisibleContentRows()
        if let row = row(for: key) {
            row.scrollToVisible(row.bounds)
            window?.makeFirstResponder(row)
        }
    }

    private func newGroupMenuItems() -> [AppKitContextMenuItem] {
        [
            .action(title: String(localized: "Plain Group")) { [weak self] in self?.createGroup(kind: .plain) },
            .action(title: String(localized: "Folder Group…")) { [weak self] in
                self?.pickFolder { [weak self] path in if let path { self?.createGroup(kind: .folder(path: path)) } }
            },
        ]
    }

    private func showNewGroupMenu() {
        let button = footerButtons[1]
        menuPresenter.popUp(items: newGroupMenuItems(), at: NSPoint(x: 0, y: 0), in: button)
    }

    private func showRemoteMenu() {
        menuPresenter.popUp(items: [
            .action(title: String(localized: "Remote Hosts…")) { [weak manager] in manager?.promptForRemoteHosts() },
            .action(title: String(localized: "New SSH Project")) { [weak manager] in manager?.promptForSSHProject() },
        ], at: NSPoint(x: 0, y: 0), in: footerButtons[2])
    }

    private func createGroup(kind: ProjectGroup.Kind) {
        let name: String
        if case .plain = kind {
            name = groupStore.nextPlainGroupName()
        } else {
            name = ProjectGroup.defaultName(for: kind)
        }
        let group = ProjectGroup(name: name, kind: kind)
        groupStore.add(group)
        refresh()
        layoutSubtreeIfNeeded()
        if let row = rows[.group(group.id)] {
            row.scrollToVisible(row.bounds)
            DispatchQueue.main.async { [weak row] in row?.onRename?() }
        }
    }

    private func changeFolder(group: ProjectGroup) {
        pickFolder(initial: group.folderPath) { [weak self] path in
            guard let self, let path, var current = self.groupStore.group(id: group.id) else { return }
            let oldDefault = ProjectGroup.defaultName(for: current.kind)
            current.kind = .folder(path: path)
            if current.name == oldDefault { current.name = ProjectGroup.defaultName(for: current.kind) }
            self.groupStore.update(current)
        }
    }

    private func projectMenu(_ project: Project, row: WorkspaceItemView?) -> [AppKitContextMenuItem] {
        var groups: [AppKitContextMenuItem] = groupStore.groups.filter { project.groupID != $0.id }.map { group in
            .action(title: group.name) { [weak manager] in manager?.moveProject(project, to: group) }
        }
        if project.groupID != nil {
            if !groups.isEmpty { groups.append(.separator) }
            groups.append(.action(title: String(localized: "Remove from Group")) { [weak manager] in manager?.moveProject(project, to: nil) })
        }
        var items: [AppKitContextMenuItem] = [
            .action(title: AppCommand.newSession.title) { [weak manager] in
                manager?.selectedProjectID = project.id
                manager?.newSession()
            },
            .action(title: String(localized: project.isPinned ? "Unpin Project" : "Pin Project")) { [weak manager] in manager?.setPinned(!project.isPinned, for: project) },
            .action(title: String(localized: "Rename…")) { [weak row] in row?.onRename?() },
        ]
        if AppSettings.shared.showSidebarSessions && !project.tabs.isEmpty {
            items.append(.action(title: String(localized: project.isSidebarExpanded ? "Hide Sessions" : "Show Sessions")) { project.isSidebarExpanded.toggle() })
        }
        items.append(.submenu(title: String(localized: "Project Sidebar"), items: sidebarMenu()))
        if project.sharedHost != nil {
            items += [
                .separator,
                .action(title: String(localized: "Reconnect Remote Host")) { project.sessions.forEach { $0.remoteConnection?.reconnect() } },
                .action(title: String(localized: "Remote Hosts…")) { [weak manager] in manager?.promptForRemoteHosts() },
            ]
            if let session = project.selectedSession, !session.hasExited, let connection = session.remoteConnection {
                items += [
                    .action(title: String(localized: "Take Terminal Control")) { connection.takeControl() },
                    .action(title: String(localized: "Detach Remote Session")) { connection.detach() },
                    .action(title: String(localized: "End Remote Session…")) { [weak row] in RemoteHostsController.endSession(session, relativeTo: row?.window) },
                ]
            }
        }
        if project.customName != nil { items.append(.action(title: String(localized: "Use Automatic Title")) { project.customName = nil }) }
        if !groups.isEmpty { items += [.separator, .submenu(title: String(localized: "Move to Group"), items: groups)] }
        items.append(.separator)
        items.append(.action(title: String(localized: "Set Color Marker…")) {
            ProjectTabColorPanelController.shared.present(project: project, hostWindow: row?.window)
        })
        if project.markerColor != nil { items.append(.action(title: String(localized: "Remove Color Marker")) { project.markerColor = nil }) }
        if !project.isRemote {
            items += [.separator, .action(title: String(localized: "Set Project Directory…")) { [weak self] in
                self?.pickFolder(initial: project.customDirectory ?? project.selectedSession?.currentDirectoryPath) { path in
                    if let path { project.customDirectory = path }
                }
            }]
            if project.customDirectory != nil { items.append(.action(title: String(localized: "Use Automatic Directory")) { project.customDirectory = nil }) }
        }
        items += [.separator, .action(title: String(localized: "Close Project")) { [weak manager] in manager?.close(project) }]
        return items
    }

    private func pickFolder(initial: String? = nil, completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if let initial { panel.directoryURL = URL(fileURLWithPath: initial, isDirectory: true) }
        guard let host = AppWindowPresentation.hostWindow(relativeTo: window) else {
            completion(nil)
            return
        }
        panel.beginSheetModal(for: host) { response in
            completion(response == .OK ? panel.url?.path : nil)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateFolderDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateFolderDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { isFolderDropTarget = false; needsDisplay = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { isFolderDropTarget = false; needsDisplay = true }

    private func updateFolderDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        let inside = scrollView.frame.contains(convert(sender.draggingLocation, from: nil))
        isFolderDropTarget = inside && !ZshellApplicationDelegate.directories(from: sender.draggingPasteboard).isEmpty
        needsDisplay = true
        return isFolderDropTarget ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isFolderDropTarget = false
        needsDisplay = true
        let directories = ZshellApplicationDelegate.directories(from: sender.draggingPasteboard)
        guard !directories.isEmpty else {
            NSSound.beep()
            announce(String(localized: "Only folders can be added as projects."))
            return false
        }
        let count = manager.openOrFocusDirectories(directories)
        announce(count == 0 ? String(localized: "Project already open. Focused it in the sidebar.") : String(localized: "Added folder as a project."))
        return true
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

@MainActor
private final class ProjectSidebarMetadata {
    nonisolated struct Entry: Equatable, Sendable {
        let program: String?
        let directory: String
        let branch: String?
    }

    private nonisolated struct Request: Equatable, Sendable {
        let id: UUID
        let scope: String
        let location: ProjectLocation
        let directory: String
        let foregroundPID: Int32?
        let remoteProgram: String?
    }

    private nonisolated struct BranchEntry: Sendable {
        let branch: String?
        let sampled: Date
    }

    private var entries: [UUID: Entry] = [:]
    private var branches: [String: BranchEntry] = [:]
    private var task: Task<Void, Never>?
    private var worker: Task<([UUID: Entry], [String: BranchEntry]), Never>?
    private var generation: UInt = 0
    private var activeRequests: [Request] = []
    private var pendingRequests: [Request]?
    private var probeOffset = 0
    private var lastRefresh = Date.distantPast
    var onChange: (() -> Void)?

    func entry(for id: UUID) -> Entry? { entries[id] }

    func clear() {
        generation &+= 1
        worker?.cancel()
        pendingRequests = nil
        let hadEntries = !entries.isEmpty
        entries.removeAll()
        branches.removeAll()
        activeRequests.removeAll()
        lastRefresh = .distantPast
        if hadEntries { onChange?() }
    }

    func refresh(sessions: [(session: TerminalSession, project: Project)]) {
        let requests = sessions.prefix(64).map { session, project in
            let directory = session.workingDirectory.flatMap { value in
                if let url = URL(string: value), url.isFileURL { return url.path }
                return value.hasPrefix("/") || project.isRemote ? value : nil
            } ?? session.remoteConnection?.projectDirectory ?? project.remoteDirectory ?? session.initialDirectoryPath
            return Request(id: session.id,
                scope: project.isRemote ? project.conversationHistoryProjectID.uuidString : "local",
                location: project.location, directory: directory,
                foregroundPID: project.isRemote || session.hasExited ? nil : session.surface.foregroundPid,
                remoteProgram: session.remoteStatus?.sessionCommand?.first.map { ($0 as NSString).lastPathComponent })
        }
        let changed = requests != activeRequests
        if changed {
            generation &+= 1
            worker?.cancel()
            let unchanged = Set(requests.filter { activeRequests.contains($0) }.map(\.id))
            let oldEntries = entries
            entries = entries.filter { unchanged.contains($0.key) }
            activeRequests = requests
            lastRefresh = .distantPast
            if entries != oldEntries { onChange?() }
        }
        guard changed || Date().timeIntervalSince(lastRefresh) >= 2 else { return }
        guard worker == nil else {
            if changed { pendingRequests = requests }
            return
        }
        start(requests)
    }

    private func start(_ requests: [Request]) {
        guard !requests.isEmpty else { return }
        lastRefresh = Date()
        let generation = generation, cache = branches
        let offset = probeOffset % requests.count
        let ordered = Array(requests[offset...]) + Array(requests[..<offset])
        probeOffset = (offset + 4) % requests.count
        let worker = Task.detached(priority: .utility) {
            var values: [UUID: Entry] = [:]
            var branches = cache
            var branchProbes = 0
            for request in ordered {
                guard !Task.isCancelled else { break }
                let directory: String
                let program: String?
                if case .local = request.location, let pid = request.foregroundPID {
                    directory = processWorkingDirectory(pid: pid) ?? request.directory
                    program = processExecutablePath(pid: pid).map { ($0 as NSString).lastPathComponent }
                } else {
                    directory = request.directory
                    program = request.remoteProgram
                }
                let key = request.scope + ":" + directory
                let lifetime: TimeInterval = request.scope == "local" ? 5 : 15
                if branchProbes < 4 && (branches[key] == nil || Date().timeIntervalSince(branches[key]!.sampled) >= lifetime) {
                    branchProbes += 1
                    branches[key] = BranchEntry(branch: Self.branch(in: directory, location: request.location), sampled: Date())
                }
                values[request.id] = Entry(program: program, directory: directory, branch: branches[key]?.branch)
            }
            if branches.count > 128 {
                branches = Dictionary(uniqueKeysWithValues: branches.sorted { $0.value.sampled > $1.value.sampled }
                    .prefix(128).map { ($0.key, $0.value) })
            }
            return (values, branches)
        }
        self.worker = worker
        task = Task { [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.task = nil
            self.worker = nil
            if self.generation == generation && self.activeRequests == requests {
                self.branches = result.1
                if self.entries != result.0 { self.entries = result.0; self.onChange?() }
            }
            if let pending = self.pendingRequests {
                self.pendingRequests = nil
                self.start(pending)
            }
        }
    }

    private nonisolated static func branch(in directory: String, location: ProjectLocation) -> String? {
        switch location {
        case .local:
            let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            if case .repository(let snapshot) = GitStatusModel.branchSnapshot(in: directory, commandRunner: { arguments, root in
                let remaining = Double(deadline &- min(deadline, DispatchTime.now().uptimeNanoseconds)) / 1_000_000_000
                guard !Task.isCancelled, remaining > 0 else {
                    return GitCommandDataResult(status: -3, stdout: Data(), stderr: "", truncated: false)
                }
                return GitCommandRunner.runData(arguments, in: root, limit: 4_096, timeout: min(2, remaining))
            }) {
                return snapshot.branch ?? String(localized: "Detached HEAD")
            }
            return nil
        case .ssh(let endpoint, _, let authentication, let credentialID):
            return remoteBranch(endpoint: endpoint, authentication: authentication, credentialID: credentialID, directory: directory)
        case .shared(let host, _):
            let endpoint: SSHEndpoint?
            switch try? host.endpoint() {
            case .ssh(let value): endpoint = value
            case .tailscale(let name, _): endpoint = try? SSHEndpoint(host: name)
            case nil: endpoint = nil
            }
            return endpoint.flatMap { remoteBranch(endpoint: $0, directory: directory) }
        }
    }

    private nonisolated static func remoteBranch(endpoint: SSHEndpoint, authentication: SSHAuthentication = .agent,
                                                credentialID: UUID? = nil, directory: String) -> String? {
        // Query only HEAD: remote rows never inspect a same-named local path.
        let output = try? OpenSSHTransport(timeout: 3, outputLimit: 4_096).run(
            endpoint: endpoint, command: ["/usr/bin/git", "-C", directory, "symbolic-ref", "--quiet", "--short", "HEAD"],
            authentication: authentication, credentialID: credentialID)
        guard let branch = output?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty else { return nil }
        return branch
    }
}
