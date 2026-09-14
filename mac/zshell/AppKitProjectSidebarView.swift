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
    override var isFlipped: Bool { true }
}

private final class ProjectSidebarOutlineView: NSView {
    var footerHeight: CGFloat = 0
    var drawsOuterEdge = false
    var dropFrame: NSRect?
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
    }
}

final class ProjectSidebarNSView: NSView {
    private enum Item: Hashable { case ungrouped, project(UUID), group(UUID) }
    private let manager: TerminalManager
    private let tabDrag: TabSplitDragCoordinator
    private let groupStore = ProjectGroupStore.shared
    private let material = NSVisualEffectView()
    private let outline = ProjectSidebarOutlineView()
    private let windowDrag = WorkspaceWindowDragView()
    private let scrollView = NSScrollView()
    private let document = ProjectSidebarDocumentView()
    private let sidebarButton = WorkspaceChromeButton(symbol: "sidebar.left", label: AppCommand.toggleLeftSidebar.title)
    private let fpsLabel = NSTextField(labelWithString: "")
    private let fpsCounter = FPSCounter()
    private let menuPresenter = AppKitContextMenuMonitorView()
    private var footerButtons: [WorkspaceChromeButton] = []
    private var rows: [Item: WorkspaceItemView] = [:]
    private var order: [Item] = []
    private var observations: [AnyCancellable] = []
    private var refreshScheduled = false
    private var lastSelection: UUID?
    private var revealSelection = true
    private var draggedItem: Item?
    private var dropItem: Item?
    private var isFolderDropTarget = false {
        didSet { outline.dropFrame = isFolderDropTarget ? scrollView.frame : nil; outline.needsDisplay = true }
    }
    var bottomBarHeight: CGFloat { didSet { if oldValue != bottomBarHeight { needsLayout = true } } }
    override var isFlipped: Bool { true }
    private var scale: CGFloat { CGFloat(AppSettings.shared.interfaceScale) }
    private var metrics: SidebarLayoutMetrics { SidebarLayoutMetrics(fontSize: AppSettings.shared.sidebarFontSize) }
    private var fontScale: CGFloat { metrics.fontScale * scale }

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
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        fpsLabel.textColor = .secondaryLabelColor
        fpsLabel.isHidden = true
        addSubview(material)
        for view in [windowDrag, scrollView, fpsLabel, sidebarButton] { addSubview(view) }
        sidebarButton.onAction = { [weak manager] in manager?.toggleLeftSidebar() }
        footerButtons = [
            WorkspaceChromeButton(symbol: "plus", label: AppCommand.newProject.title) { [weak manager] in manager?.newProject() },
            WorkspaceChromeButton(symbol: "folder.badge.plus", label: String(localized: "New Group")) { [weak self] in self?.showNewGroupMenu() },
            WorkspaceChromeButton(symbol: "network", label: String(localized: "New SSH Project")) { [weak manager] in manager?.promptForSSHProject() },
            WorkspaceChromeButton(symbol: "bolt", label: String(localized: "Quick Launch (⌘O)")) { [weak manager] in manager?.toggleQuickLaunch() },
            WorkspaceChromeButton(symbol: "exclamationmark.bubble", label: String(localized: "Send Feedback")) {
                NSWorkspace.shared.open(URL(string: "https://github.com/wzz6423/zshell/issues/new")!)
            },
            WorkspaceChromeButton(symbol: "gearshape", label: String(localized: "Settings (⌘,)")) { SettingsWindowController.shared.show() },
        ]
        footerButtons.forEach(addSubview)
        addSubview(outline)
        outline.setAccessibilityElement(false)
        for publisher in [manager.objectWillChange.eraseToAnyPublisher(),
                          groupStore.objectWillChange.eraseToAnyPublisher(),
                          AppSettings.shared.objectWillChange.eraseToAnyPublisher(),
                          Theme.changes.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &observations)
        }
        tabDrag.$drag.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateDropHighlights() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            .sink { [weak self] _ in self?.publishDropFrames() }.store(in: &observations)
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
        let groupIDs = Set(groupStore.groups.map(\.id))
        var items: [Item] = [.ungrouped]
        items += manager.projects.filter { $0.groupID.map { !groupIDs.contains($0) } ?? true }.map { .project($0.id) }
        for group in groupStore.groups {
            items.append(.group(group.id))
            if !group.isCollapsed { items += manager.projects.filter { $0.groupID == group.id }.map { .project($0.id) } }
        }
        let valid = Set(items)
        for key in rows.keys where !valid.contains(key) { rows.removeValue(forKey: key)?.removeFromSuperview() }
        order = items
        let shortcuts = Dictionary(uniqueKeysWithValues: manager.visibleSidebarProjects.prefix(9).enumerated().map {
            ($0.element.id, "⌘\($0.offset + 1)")
        })
        for item in items {
            let row = rows[item] ?? WorkspaceItemView(frame: .zero)
            if rows[item] == nil { rows[item] = row; document.addSubview(row) }
            switch item {
            case .ungrouped:
                row.apply(title: String(localized: "New Ungrouped Project"),
                          icon: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil),
                          selected: false, sidebar: true, scale: fontScale)
                row.onSelect = { [weak manager] in manager?.newProject() }
                row.toolTip = String(localized: "New Ungrouped Project")
                row.menuItems = { [weak self] in self?.newGroupMenuItems() ?? [] }
            case .project(let id):
                guard let project = manager.projects.first(where: { $0.id == id }) else { continue }
                configure(row, project: project, shortcut: shortcuts[id])
            case .group(let id):
                guard let group = groupStore.group(id: id) else { continue }
                configure(row, group: group)
            }
            row.onDrag = { [weak self] event in self?.updateDrag(item: item, event: event) }
            row.onDragEnded = { [weak self] event in self?.finishDrag(item: item, event: event) }
            row.onDragCancelled = { [weak self] in self?.cancelDrag() }
            row.onNavigate = { [weak self] key in self?.navigate(from: item, key: key) }
        }
        if lastSelection != manager.selectedProjectID { lastSelection = manager.selectedProjectID; revealSelection = true }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        material.isHidden = !Theme.isDefault(dark: dark)
        outline.drawsOuterEdge = material.isHidden
        outline.needsDisplay = true
        sidebarButton.configure(symbol: "sidebar.left", command: .toggleLeftSidebar, pointSize: 12 * scale)
        footerButtons[0].configure(symbol: "plus", command: .newProject, pointSize: 12 * scale)
        for (button, symbol) in zip(footerButtons.dropFirst(), ["folder.badge.plus", "network", "bolt", "exclamationmark.bubble", "gearshape"]) {
            button.configure(symbol: symbol, label: button.toolTip ?? "", pointSize: 12 * scale)
        }
        if manager.isFPSCounterVisible, window != nil { fpsCounter.start() } else { fpsCounter.stop() }
        updateDropHighlights()
        needsLayout = true
        needsDisplay = true
    }

    private func configure(_ row: WorkspaceItemView, project: Project, shortcut: String?) {
        let subtitle: String?
        if project.sessions.count > 1 { subtitle = String(localized: "\(project.sessions.count) sessions") }
        else { subtitle = project.selectedSession?.directoryLabel }
        row.apply(title: project.name, subtitle: subtitle,
                  icon: NSImage(systemSymbolName: project.isRemote ? "network" : "folder", accessibilityDescription: nil),
                  selected: project.id == manager.selectedProjectID, pinned: project.isPinned,
                  marker: project.markerColor, rollup: project.agentRollup, sidebar: true,
                  indent: project.groupID == nil ? 0 : 12 * scale, scale: fontScale, shortcut: shortcut,
                  actionLabel: String(localized: "Close Project"), action: { [weak manager, weak project] in
                      if let project { manager?.close(project) }
                  })
        row.toolTip = [project.name, project.customDirectory ?? subtitle].compactMap { $0 }.joined(separator: "\n")
        row.onSelect = { [weak manager, weak project] in if let project { manager?.selectedProjectID = project.id } }
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
        row.apply(title: group.name,
                  icon: NSImage(systemSymbolName: group.folderPath == nil ? "tray.full" : "folder", accessibilityDescription: nil),
                  selected: manager.selectedProject?.groupID == group.id, group: true, collapsed: group.isCollapsed,
                  count: count, sidebar: true, scale: fontScale, actionSymbol: "plus",
                  actionLabel: String(localized: "New Project in Group"), action: { [weak manager, weak groupStore] in
                      guard let current = groupStore?.group(id: group.id) else { return }
                      manager?.newProject(in: current)
                  })
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
            items += [.separator, .action(title: String(localized: "Remove Group")) { self.manager.deleteProjectGroup(current) }]
            return items
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
        windowDrag.frame = NSRect(x: 0, y: 0, width: sidebarButton.frame.minX, height: headerHeight)
        fpsLabel.isHidden = !manager.isFPSCounterVisible || bounds.width < 210
        fpsLabel.frame = NSRect(x: sidebarButton.frame.minX - 55, y: 12, width: 52, height: 16)
        let footerY = max(headerHeight, bounds.height - bottomBarHeight)
        scrollView.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, footerY - headerHeight))
        let side = min(max(24, 26 * scale), max(0, (bounds.width - 16) / 6))
        for (index, button) in footerButtons.enumerated() {
            let x = index < 4 ? 8 + CGFloat(index) * side : bounds.width - 8 - CGFloat(6 - index) * side
            button.frame = NSRect(x: x, y: footerY + (bottomBarHeight - side) / 2, width: side, height: side)
        }
        var y: CGFloat = 7
        let rowWidth = max(0, scrollView.contentSize.width - 16)
        for item in order {
            guard let row = rows[item] else { continue }
            let height: CGFloat
            switch item {
            case .project: height = max(38, ceil(31 * fontScale + 8))
            case .group: height = max(28, ceil(21 * fontScale + 6)); y += 5
            case .ungrouped: height = max(26, ceil(19 * fontScale + 6))
            }
            row.frame = NSRect(x: 8, y: y, width: rowWidth, height: height)
            y += height + 3
        }
        document.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: max(scrollView.contentSize.height, y + 6))
        if revealSelection && draggedItem == nil {
            revealSelection = false
            if let id = manager.selectedProjectID, let row = rows[.project(id)] { row.scrollToVisible(row.bounds) }
        }
        publishDropFrames()
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
        tabDrag.updateSidebarFrames(projects: [:], groups: [:], ungrouped: nil)
    }

    private func publishDropFrames() {
        guard window != nil else { return }
        var projects: [UUID: CGRect] = [:], groups: [UUID: CGRect] = [:]
        var ungrouped: CGRect?
        for (item, row) in rows {
            let visible = row.bounds.intersection(row.convert(document.visibleRect, from: document))
            guard !visible.isEmpty else { continue }
            let frame = row.workspaceGlobalRect(visible)
            switch item {
            case .project(let id): projects[id] = frame
            case .group(let id): groups[id] = frame
            case .ungrouped: ungrouped = frame
            }
        }
        tabDrag.updateSidebarFrames(projects: projects, groups: groups, ungrouped: ungrouped)
    }

    private func updateDropHighlights() {
        for (item, row) in rows {
            let targeted: Bool
            switch (item, tabDrag.drag?.sidebarTarget) {
            case (.project(let id), .project(let target)): targeted = id == target
            case (.group(let id), .newProject(let target)): targeted = id == target
            case (.ungrouped, .newProject(nil)): targeted = true
            default: targeted = false
            }
            row.isDropTarget = targeted || (item == dropItem && item != draggedItem)
        }
    }

    private func item(at event: NSEvent) -> Item? {
        let point = convert(event.locationInWindow, from: nil)
        guard scrollView.frame.contains(point) else { return nil }
        let location = document.convert(event.locationInWindow, from: nil)
        return order.first { rows[$0]?.frame.contains(location) == true }
    }

    private func updateDrag(item: Item, event: NSEvent) {
        guard item != .ungrouped else { return }
        draggedItem = item
        dropItem = self.item(at: event)
        updateDropHighlights()
        let point = convert(event.locationInWindow, from: nil)
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
        let target = self.item(at: event)
        if case .project(let id) = item,
           let project = manager.projects.first(where: { $0.id == id }) {
            switch target {
            case .group(let groupID): manager.moveProject(project, to: groupStore.group(id: groupID))
            case .ungrouped: manager.moveProject(project, to: nil)
            case .project(let targetID):
                if targetID != id, let destination = manager.projects.first(where: { $0.id == targetID }) {
                    manager.moveProject(project, to: groupStore.group(id: destination.groupID))
                    manager.moveProject(id, to: targetID)
                }
            case nil: break
            }
        } else if case .group(let id) = item, case .group(let targetID) = target {
            groupStore.move(id, to: targetID)
        }
        cancelDrag()
    }

    private func cancelDrag() {
        draggedItem = nil
        dropItem = nil
        updateDropHighlights()
        NSCursor.arrow.set()
    }

    private func navigate(from item: Item, key: UInt16) {
        if case .group(let id) = item, key == 123 || key == 124,
           var group = groupStore.group(id: id) {
            group.isCollapsed = key == 123
            groupStore.update(group)
            return
        }
        guard let index = order.firstIndex(of: item), !order.isEmpty else { return }
        let offset = key == 123 || key == 126 ? -1 : 1
        if let row = rows[order[(index + offset + order.count) % order.count]] {
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

    private func createGroup(kind: ProjectGroup.Kind) {
        let group = ProjectGroup(name: ProjectGroup.defaultName(for: kind), kind: kind)
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
        var groups: [AppKitContextMenuItem] = groupStore.groups.map { group in
            .action(title: group.name, enabled: project.groupID != group.id) { [weak manager] in manager?.moveProject(project, to: group) }
        }
        if !groups.isEmpty { groups.append(.separator) }
        groups.append(.action(title: String(localized: "Remove from Group"), enabled: project.groupID != nil) { [weak manager] in manager?.moveProject(project, to: nil) })
        var items: [AppKitContextMenuItem] = [
            .action(title: String(localized: project.isPinned ? "Unpin Project" : "Pin Project")) { [weak manager] in manager?.setPinned(!project.isPinned, for: project) },
            .action(title: String(localized: "Rename…")) { [weak row] in row?.onRename?() },
        ]
        if project.customName != nil { items.append(.action(title: String(localized: "Use Automatic Title")) { project.customName = nil }) }
        items += [.separator, .submenu(title: String(localized: "Move to Group"), items: groups), .separator]
        items.append(.action(title: String(localized: "Set Color Marker…")) { ProjectTabColorPanelController.shared.present(project: project) })
        if project.markerColor != nil { items.append(.action(title: String(localized: "Remove Color Marker")) { project.markerColor = nil }) }
        items += [.separator, .action(title: String(localized: "Set Project Directory…"), enabled: !project.isRemote) { [weak self] in
            self?.pickFolder(initial: project.customDirectory ?? project.selectedSession?.currentDirectoryPath) { path in
                if let path { project.customDirectory = path }
            }
        }]
        if project.customDirectory != nil { items.append(.action(title: String(localized: "Use Automatic Directory")) { project.customDirectory = nil }) }
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
        if let window {
            panel.beginSheetModal(for: window) { response in completion(response == .OK ? panel.url?.path : nil) }
        } else { completion(panel.runModal() == .OK ? panel.url?.path : nil) }
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
