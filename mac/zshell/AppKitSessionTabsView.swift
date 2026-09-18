//
//  AppKitSessionTabsView.swift
//  zshell
//

import AppKit
import Combine
import SwiftUI

/// The existing workspace mounts one native header; AppKit owns all of its
/// controls, scrolling, hit testing, editing, and tab/group presentation.
struct MainHeaderView: NSViewRepresentable {
    let manager: TerminalManager
    let tabSplitDrag: TabSplitDragCoordinator

    func makeNSView(context: Context) -> MainHeaderNSView {
        MainHeaderNSView(manager: manager, tabDrag: tabSplitDrag)
    }

    func updateNSView(_ view: MainHeaderNSView, context: Context) { view.refresh() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MainHeaderNSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 500, height: MainHeaderNSView.height)
    }
}

final class MainHeaderNSView: NSView {
    static let height: CGFloat = 38

    private let manager: TerminalManager
    private let tabDrag: TabSplitDragCoordinator
    private let strip = SessionTabsNSView(frame: .zero)
    private let windowDrag = WorkspaceWindowDragView()
    private let leftButton = WorkspaceChromeButton(symbol: "sidebar.left", label: AppCommand.toggleLeftSidebar.title)
    private let rightButton = WorkspaceChromeButton(symbol: "sidebar.right", label: AppCommand.toggleRightSidebar.title)
    private let zoomButton = WorkspaceChromeButton(symbol: "arrow.down.forward.and.arrow.up.backward", label: String(localized: "Exit Pane Zoom (⇧⌘↩)"))
    private var observations: [AnyCancellable] = []
    private var refreshScheduled = false
    private let presentsWindowOverlay: Bool
    private weak var overlayHeader: MainHeaderNSView?
    private var overlayObservers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    init(manager: TerminalManager, tabDrag: TabSplitDragCoordinator, presentsWindowOverlay: Bool = true) {
        self.manager = manager
        self.tabDrag = tabDrag
        self.presentsWindowOverlay = presentsWindowOverlay
        super.init(frame: .zero)
        addSubview(windowDrag)
        for view in [strip, leftButton, rightButton, zoomButton] { addSubview(view) }
        leftButton.onAction = { [weak manager] in manager?.toggleLeftSidebar() }
        rightButton.onAction = { [weak manager] in manager?.toggleSidebar() }
        zoomButton.onAction = { [weak manager] in manager?.togglePaneZoom() }
        strip.onWidthChange = { [weak self] in self?.needsLayout = true }
        for publisher in [manager.objectWillChange.eraseToAnyPublisher(),
                          AppSettings.shared.objectWillChange.eraseToAnyPublisher(),
                          Theme.changes.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &observations)
        }
        setAccessibilityElement(false)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        raiseHostAboveTerminal()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        raiseHostAboveTerminal()
        installWindowOverlay()
    }

    private func raiseHostAboveTerminal() {
        guard presentsWindowOverlay else { return }
        guard let host = superview, let parent = host.superview,
              parent.subviews.last !== host else { return }
        parent.addSubview(host, positioned: .above, relativeTo: nil)
    }

    private func installWindowOverlay() {
        guard presentsWindowOverlay,
              let window,
              let contentView = window.contentView,
              overlayHeader == nil
        else { return }

        let header = MainHeaderNSView(
            manager: manager,
            tabDrag: tabDrag,
            presentsWindowOverlay: false
        )
        header.windowDrag.dragWindow = window
        // A view overlay cannot be left behind on another Space or display.
        contentView.addSubview(header, positioned: .above, relativeTo: nil)
        overlayHeader = header

        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        for name in names {
            overlayObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.syncWindowOverlay()
                    }
                }
            })
        }
        syncWindowOverlay()
    }

    private func syncWindowOverlay() {
        guard presentsWindowOverlay,
              let window,
              let header = overlayHeader,
              let host = superview,
              let contentView = window.contentView
        else { return }

        let frame = host.convert(host.bounds, to: contentView)
        guard frame.width > 0, frame.height > 0 else { return }
        if header.superview !== contentView {
            contentView.addSubview(header, positioned: .above, relativeTo: nil)
        }
        header.frame = frame
    }

    private func removeWindowOverlay() {
        overlayObservers.forEach(NotificationCenter.default.removeObserver)
        overlayObservers.removeAll()
        overlayHeader?.removeFromSuperview()
        overlayHeader = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if presentsWindowOverlay, newWindow !== window { removeWindowOverlay() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        raiseHostAboveTerminal()
        let scale = CGFloat(AppSettings.shared.interfaceScale)
        leftButton.isHidden = manager.isLeftSidebarVisible
        rightButton.isHidden = manager.selectedProject == nil
        zoomButton.isHidden = !manager.isPaneZoomed
        leftButton.configure(symbol: "sidebar.left", command: .toggleLeftSidebar, pointSize: 12 * scale)
        rightButton.configure(symbol: "sidebar.right", command: .toggleRightSidebar, pointSize: 12 * scale)
        zoomButton.configure(symbol: "arrow.down.forward.and.arrow.up.backward", label: String(localized: "Exit Pane Zoom (⇧⌘↩)"), pointSize: 12 * scale)
        zoomButton.contentTintColor = Theme.accent
        strip.configure(manager: manager, project: manager.selectedProject, tabDrag: tabDrag)
        strip.isHidden = manager.selectedProject == nil
        needsLayout = true
        needsDisplay = true
        DispatchQueue.main.async { [weak self] in
            self?.raiseHostAboveTerminal()
            self?.syncWindowOverlay()
        }
    }

    override func layout() {
        super.layout()
        let scale = CGFloat(AppSettings.shared.interfaceScale)
        let buttonSide = min(bounds.height - 4, max(24, 24 * scale))
        let y = (bounds.height - buttonSide) / 2
        var left: CGFloat = manager.isLeftSidebarVisible ? 8 : 78
        if !leftButton.isHidden {
            leftButton.frame = NSRect(x: left, y: y, width: buttonSide, height: buttonSide)
            left += buttonSide + 6
        }
        var right = bounds.width - 8
        for button in [rightButton, zoomButton] where !button.isHidden {
            right -= buttonSide
            button.frame = NSRect(x: right, y: y, width: buttonSide, height: buttonSide)
            right -= 6
        }
        let available = max(0, right - left - 32)
        let stripWidth = min(strip.preferredWidth, available)
        strip.frame = NSRect(x: left, y: 2, width: stripWidth, height: max(0, bounds.height - 4))
        windowDrag.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        Theme.divider.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    deinit { removeWindowOverlay() }
}

private final class SessionStripScrollView: NSScrollView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let documentView else { return super.hitTest(point) }
        let clipPoint = contentView.convert(point, from: self)
        guard contentView.bounds.contains(clipPoint) else { return super.hitTest(point) }
        let documentPoint = documentView.convert(clipPoint, from: contentView)
        return documentView.hitTest(documentPoint) ?? super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let maximum = max(0, (documentView?.bounds.width ?? 0) - contentSize.width)
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        contentView.scroll(to: NSPoint(x: min(max(0, contentView.bounds.minX - delta), maximum), y: 0))
        reflectScrolledClipView(contentView)
    }
}

private final class SessionStripDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SessionStripProjectDropTargetView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        Theme.accent.withAlphaComponent(0.18).setFill()
        path.fill()
        Theme.accent.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

final class SessionTabsNSView: NSView {
    private enum Item: Hashable { case tab(UUID), group(UUID) }
    private weak var manager: TerminalManager?
    private weak var project: Project?
    private weak var tabDrag: TabSplitDragCoordinator?
    private let scrollView = SessionStripScrollView()
    private let document = SessionStripDocumentView()
    private let addButton = WorkspaceChromeButton(symbol: "plus", label: AppCommand.newSession.title)
    private let groupButton = WorkspaceChromeButton(symbol: "rectangle.3.group", label: String(localized: "New Tab Group"))
    private let leftButton = WorkspaceChromeButton(symbol: "chevron.left", label: String(localized: "Scroll Tabs Left"))
    private let rightButton = WorkspaceChromeButton(symbol: "chevron.right", label: String(localized: "Scroll Tabs Right"))
    private let projectDropTarget = SessionStripProjectDropTargetView(frame: .zero)
    private var rows: [Item: WorkspaceItemView] = [:]
    private var order: [Item] = []
    private var contentObservations: [UUID: AnyCancellable] = [:]
    private var scrollObservation: AnyCancellable?
    private var projectDragObservation: AnyCancellable?
    private var refreshScheduled = false
    private var contentWidth: CGFloat = 0
    private var lastViewportWidth: CGFloat = 0
    private var lastSelection: UUID?
    private var revealSelection = true
    private var draggedItem: Item?
    private var dropItem: Item?
    var onWidthChange: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = document
        for view in [scrollView, addButton, groupButton, leftButton, rightButton] { addSubview(view) }
        projectDropTarget.isHidden = true
        addSubview(projectDropTarget)
        addButton.onAction = { [weak self] in self?.project?.newSession() }
        groupButton.onAction = { [weak self] in self?.createGroup() }
        leftButton.onAction = { [weak self] in self?.scroll(by: -160) }
        rightButton.onAction = { [weak self] in self?.scroll(by: 160) }
        scrollObservation = NotificationCenter.default.publisher(
            for: NSView.boundsDidChangeNotification, object: scrollView.contentView
        ).sink { [weak self] _ in self?.updateScrollButtons() }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var preferredWidth: CGFloat { contentWidth + controlWidth * 2 + 8 }
    private var scale: CGFloat { CGFloat(AppSettings.shared.interfaceScale) }
    private var controlWidth: CGFloat { min(34, max(24, 24 * scale)) }
    // Keep an ungrouped release target reachable when the tab strip overflows.
    private var trailingDropWidth: CGFloat {
        guard let draggedItem,
              case .tab(let id) = draggedItem,
              project?.tabs.first(where: { $0.id == id })?.tabGroupID != nil
        else { return 0 }
        return 28 * scale
    }

    func configure(manager: TerminalManager, project: Project?, tabDrag: TabSplitDragCoordinator) {
        if self.project !== project {
            cancelDrag()
            rows.values.forEach { $0.removeFromSuperview() }
            rows = [:]
            order = []
            contentObservations = [:]
            lastSelection = nil
            scrollView.contentView.scroll(to: .zero)
        }
        self.manager = manager
        self.project = project
        if self.tabDrag !== tabDrag {
            self.tabDrag = tabDrag
            projectDragObservation = tabDrag.$projectDrag
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateProjectDropTarget() }
        }
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        guard let project else { contentWidth = 0; return }
        var items = project.tabs.filter { $0.tabGroupID == nil }.map { Item.tab($0.id) }
        for group in project.tabGroups {
            items.append(.group(group.id))
            if !group.isCollapsed {
                items += project.tabs.filter { $0.tabGroupID == group.id }.map { .tab($0.id) }
            }
        }
        let current = Set(items)
        for key in rows.keys where !current.contains(key) { rows.removeValue(forKey: key)?.removeFromSuperview() }
        if order != items { revealSelection = true }
        order = items
        var width: CGFloat = 0
        for item in items {
            let row = rows[item] ?? WorkspaceItemView(frame: .zero)
            if rows[item] == nil { rows[item] = row; document.addSubview(row) }
            switch item {
            case .tab(let id):
                guard let tab = project.tabs.first(where: { $0.id == id }) else { continue }
                configure(row, tab: tab, project: project)
            case .group(let id):
                guard let group = project.tabGroup(id: id) else { continue }
                configure(row, group: group, project: project)
            }
            row.onDrag = { [weak self] event in self?.updateDrag(item: item, event: event) }
            row.onDragEnded = { [weak self] event in self?.finishDrag(item: item, event: event) }
            row.onDragCancelled = { [weak self] in self?.cancelDrag() }
            row.onNavigate = { [weak self] key in self?.navigate(from: item, key: key) }
            row.frame = NSRect(x: width, y: 0, width: row.preferredWidth, height: bounds.height)
            width += row.preferredWidth + 3
        }
        width = max(0, width - 3)
        if width != contentWidth { contentWidth = width; revealSelection = true; onWidthChange?() }
        if lastSelection != project.selectedTabID { lastSelection = project.selectedTabID; revealSelection = true }
        observeContent(in: project)
        addButton.configure(symbol: "plus", command: .newSession, pointSize: 11 * scale)
        groupButton.configure(symbol: "rectangle.3.group", label: String(localized: "New Tab Group"), pointSize: 11 * scale)
        needsLayout = true
    }

    private func configure(_ row: WorkspaceItemView, tab: PaneTab, project: Project) {
        let content = tab.focusedContent
        let image: NSImage?
        if let path = content?.fileIconPath {
            image = MaterialFileIcon.image(forPath: path, appearance: effectiveAppearance)
        } else if case .browser(let browser) = content, let favicon = browser.favicon {
            image = favicon
        } else {
            image = NSImage(systemSymbolName: content?.systemImage ?? "terminal", accessibilityDescription: nil)
        }
        let groupColor = project.tabGroup(id: tab.tabGroupID).map {
            $0.markerColor ?? .defaultColor
        }
        row.apply(title: tab.displayTitle ?? String(localized: "Tab"), icon: image,
                  selected: tab.id == project.selectedTabID, grouped: tab.tabGroupID != nil,
                  pinned: tab.isPinned, marker: groupColor ?? tab.markerColor,
                  count: tab.allPanes.count > 1 ? tab.allPanes.count : nil,
                  rollup: tab.agentRollup, dirty: content?.isDirty == true, scale: scale,
                  action: { [weak project, weak tab] in if let tab { project?.close(tab) } })
        row.toolTip = content?.fileIconPath ?? tab.displayTitle
        row.onSelect = { [weak project, weak tab] in if let tab { project?.selectedTabID = tab.id } }
        row.onRename = { [weak row, weak tab] in
            guard let tab else { return }
            row?.beginRename(value: tab.displayTitle ?? "") { [weak tab] name in
                tab?.customName = Project.normalizedCustomName(name)
            }
        }
        row.menuItems = { [weak self, weak tab] in
            guard let tab else { return [] }
            return self?.tabMenu(tab) ?? []
        }
    }

    private func configure(_ row: WorkspaceItemView, group: SessionTabGroup, project: Project) {
        row.apply(title: group.name, icon: nil,
                  selected: project.selectedTab?.tabGroupID == group.id,
                  group: true, collapsed: group.isCollapsed, grouped: true,
                  marker: group.markerColor ?? .defaultColor, compactGroup: true,
                  showsGroupTitle: AppSettings.shared.showTabGroupNames, scale: scale)
        row.toolTip = group.name
        row.onSelect = { [weak project] in
            guard let current = project?.tabGroup(id: group.id) else { return }
            project?.setTabGroupCollapsed(!current.isCollapsed, id: group.id)
        }
        row.onRename = { [weak self, weak row, weak project] in
            guard let project, let current = project.tabGroup(id: group.id) else { return }
            row?.beginRename(value: current.name) { [weak self, weak project] name in
                project?.renameTabGroup(group.id, to: name)
                self?.scheduleRefresh()
            }
        }
        row.menuItems = { [weak self, weak row, weak project] in
            guard let project, let current = project.tabGroup(id: group.id) else { return [] }
            var items: [AppKitContextMenuItem] = [
                .action(title: String(localized: "New Session in Group")) { project.newSession(inTabGroup: group.id) },
                .action(title: String(localized: "Rename…")) { row?.onRename?() },
                .action(title: String(localized: current.isCollapsed ? "Expand Group" : "Collapse Group")) {
                    project.setTabGroupCollapsed(!current.isCollapsed, id: group.id)
                },
            ]
            items += [
                .separator,
                .action(title: String(localized: "Set Color Marker…")) { [weak project] in
                    guard let project, let latest = project.tabGroup(id: group.id) else { return }
                    ProjectTabColorPanelController.shared.present(
                        tabGroup: latest,
                        apply: { [weak project] color in
                            project?.setTabGroupColor(color, id: group.id)
                        },
                        hostWindow: row?.window
                    )
                },
            ]
            if current.markerColor != nil {
                items.append(.action(title: String(localized: "Remove Color Marker")) {
                    project.setTabGroupColor(nil, id: group.id)
                })
            }
            items += [
                .separator,
                .action(title: String(localized: "Remove Group")) { [weak self, weak project] in
                    project?.removeTabGroup(group.id)
                    self?.scheduleRefresh()
                },
            ]
            return items
        }
    }

    private func observeContent(in project: Project) {
        let contents = project.tabs.flatMap(\.allContents)
        let ids = Set(contents.map(\.id))
        for id in contentObservations.keys where !ids.contains(id) { contentObservations[id] = nil }
        for content in contents where contentObservations[content.id] == nil {
            let publisher: ObservableObjectPublisher
            switch content {
            case .session(let session): publisher = session.objectWillChange
            case .file(let file): publisher = file.objectWillChange
            case .browser(let browser): publisher = browser.objectWillChange
            case .diff(let diff): publisher = diff.objectWillChange
            }
            contentObservations[content.id] = publisher.receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleRefresh() }
        }
    }

    override func layout() {
        super.layout()
        let controls = controlWidth * 2 + 8
        let available = max(0, bounds.width - controls)
        let overflow = contentWidth + trailingDropWidth > available + 0.5
        let arrowWidth: CGFloat = overflow ? 20 : 0
        leftButton.isHidden = !overflow
        rightButton.isHidden = !overflow
        leftButton.frame = NSRect(x: 0, y: 0, width: arrowWidth, height: bounds.height)
        let viewportWidth = max(0, available - arrowWidth * 2)
        scrollView.frame = NSRect(x: arrowWidth, y: 0, width: viewportWidth, height: bounds.height)
        rightButton.frame = NSRect(x: arrowWidth + viewportWidth, y: 0, width: arrowWidth, height: bounds.height)
        addButton.frame = NSRect(x: available + 4, y: 0, width: controlWidth, height: bounds.height)
        groupButton.frame = NSRect(x: available + 4 + controlWidth, y: 0, width: controlWidth, height: bounds.height)
        document.frame = NSRect(
            x: 0,
            y: 0,
            width: max(viewportWidth, contentWidth + trailingDropWidth),
            height: bounds.height
        )
        projectDropTarget.frame = scrollView.frame
        let projectDropBounds = scrollView.frame
            .insetBy(dx: overflow ? 0 : -4 * scale, dy: -2 * scale)
            .intersection(bounds)
        let projectDropScreenFrame = project == nil
            ? nil
            : workspaceScreenRect(projectDropBounds)
        tabDrag?.updateTabStripFrame(projectID: project?.id, screenFrame: projectDropScreenFrame)
        updateProjectDropTarget()
        for row in rows.values { row.setFrameSize(NSSize(width: row.frame.width, height: bounds.height)) }
        if lastViewportWidth != viewportWidth { lastViewportWidth = viewportWidth; revealSelection = true }
        scroll(by: 0)
        if revealSelection && draggedItem == nil {
            revealSelection = false
            revealSelectedRow()
        }
        updateScrollButtons()
    }

    private func revealSelectedRow() {
        guard let project, let tab = project.selectedTab else { return }
        let item: Item = project.tabGroup(id: tab.tabGroupID)?.isCollapsed == true
            ? .group(tab.tabGroupID!) : .tab(tab.id)
        guard let row = rows[item] else { return }
        row.scrollToVisible(row.bounds.insetBy(dx: -3, dy: 0))
    }

    private func scroll(by delta: CGFloat) {
        let maximum = max(0, document.bounds.width - scrollView.contentSize.width)
        let x = min(max(0, scrollView.contentView.bounds.minX + delta), maximum)
        scrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func updateScrollButtons() {
        leftButton.isEnabled = scrollView.contentView.bounds.minX > 0.5
        rightButton.isEnabled = scrollView.contentView.bounds.maxX < document.bounds.width - 0.5
    }

    private func updateProjectDropTarget() {
        let isTarget = project.map {
            tabDrag?.projectDrag?.targetProjectID == $0.id
        } ?? false
        guard projectDropTarget.isHidden == !isTarget else { return }
        projectDropTarget.isHidden = !isTarget
    }

    private func createGroup() {
        guard let project else { return }
        let group = project.createTabGroup(containing: project.selectedTab)
        refresh()
        layoutSubtreeIfNeeded()
        rows[.group(group.id)]?.onRename?()
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
            return frame.insetBy(dx: -5 * scale, dy: 0).contains(location)
        }
    }

    private func updateDrag(item: Item, event: NSEvent) {
        guard let project, let manager, let tabDrag else { return }
        if draggedItem != item {
            draggedItem = item
            needsLayout = true
        }
        dropItem = self.item(at: event, extendingGroupTargets: true)
        for (key, row) in rows { row.isDropTarget = key == dropItem && key != item }
        if case .tab(let id) = item {
            tabDrag.update(sourceTabID: id, location: workspaceGlobalPoint(event), in: project, manager: manager)
        }
        let point = convert(event.locationInWindow, from: nil)
        if scrollView.frame.contains(point) {
            if point.x < scrollView.frame.minX + 18 { scroll(by: -12) }
            if point.x > scrollView.frame.maxX - 18 { scroll(by: 12) }
        }
    }

    private func finishDrag(item: Item, event: NSEvent) {
        guard let project else { cancelDrag(); return }
        let target = self.item(at: event, extendingGroupTargets: true)
        switch (item, target) {
        case (.group(let source), .group(let destination)):
            project.moveTabGroup(source, to: destination)
        case (.tab(let source), .group(let destination)):
            project.moveTab(source, toGroup: destination)
        case (.tab(let source), .tab(let destination)):
            let sourceTab = project.tabs.first { $0.id == source }
            let destinationTab = project.tabs.first { $0.id == destination }
            if sourceTab?.isPinned != destinationTab?.isPinned,
               let groupID = destinationTab?.tabGroupID {
                project.moveTab(source, toGroup: groupID)
            } else {
                project.moveTab(source, to: destination)
            }
        case (.tab(let source), nil):
            if documentPoint(at: event) != nil {
                project.moveTab(source, toGroup: nil)
            } else {
                if let manager {
                    tabDrag?.update(sourceTabID: source, location: workspaceGlobalPoint(event), in: project, manager: manager)
                }
                tabDrag?.commit()
            }
        default: break
        }
        cancelDrag()
        refresh()
    }

    private func cancelDrag() {
        draggedItem = nil
        dropItem = nil
        tabDrag?.cancel()
        rows.values.forEach { $0.isDropTarget = false }
        needsLayout = true
        NSCursor.arrow.set()
    }

    private func navigate(from item: Item, key: UInt16) {
        guard let index = order.firstIndex(of: item), !order.isEmpty else { return }
        let offset = key == 123 || key == 126 ? -1 : 1
        let next = order[(index + offset + order.count) % order.count]
        guard let row = rows[next] else { return }
        row.scrollToVisible(row.bounds)
        window?.makeFirstResponder(row)
    }

    private func tabMenu(_ tab: PaneTab) -> [AppKitContextMenuItem] {
        guard let project, let manager else { return [] }
        var items: [AppKitContextMenuItem] = [
            .action(title: String(localized: tab.isPinned ? "Unpin Tab" : "Pin Tab")) { project.setPinned(!tab.isPinned, for: tab) },
            .action(title: String(localized: "Rename…")) { [weak self] in self?.rows[.tab(tab.id)]?.onRename?() },
        ]
        if tab.customName != nil { items.append(.action(title: String(localized: "Use Automatic Title")) { tab.customName = nil }) }
        var groupItems: [AppKitContextMenuItem] = [
            .action(title: String(localized: "New Tab Group")) { [weak self] in
                let group = project.createTabGroup(containing: tab)
                self?.refresh()
                DispatchQueue.main.async { [weak self] in self?.rows[.group(group.id)]?.onRename?() }
            },
        ]
        if !project.tabGroups.isEmpty { groupItems.append(.separator) }
        groupItems += project.tabGroups.map { group in
            .action(title: group.name, enabled: tab.tabGroupID != group.id) { project.moveTab(tab.id, toGroup: group.id) }
        }
        if tab.tabGroupID != nil {
            groupItems.append(.separator)
            groupItems.append(.action(title: String(localized: "Remove from Group")) { project.moveTab(tab.id, toGroup: nil) })
        }
        items += [.separator, .submenu(title: String(localized: "Move to Group"), items: groupItems), .separator]
        items.append(.action(title: String(localized: "Set Color Marker…")) {
            ProjectTabColorPanelController.shared.present(
                tab: tab,
                hostWindow: self.rows[.tab(tab.id)]?.window
            )
        })
        if tab.markerColor != nil { items.append(.action(title: String(localized: "Remove Color Marker")) { tab.markerColor = nil }) }
        if case .file(let file) = tab.focusedContent {
            items.append(.action(title: String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) })
            items.append(.action(title: String(localized: "Copy Absolute Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            })
        }
        if case .browser(let browser) = tab.focusedContent, !browser.urlString.isEmpty {
            items.append(.action(title: String(localized: "Open in Default Browser"), enabled: browser.shareURL != nil) { browser.openInDefaultBrowser() })
            items.append(.action(title: String(localized: "Copy Address")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(browser.urlString, forType: .string)
            })
        }
        let destinations = manager.tabMoveDestinations(for: tab.id, in: project.id)
        var moveItems: [AppKitContextMenuItem] = [
            .action(title: String(localized: "New Ungrouped Project"), enabled: tab.diffs.isEmpty) { [weak self] in
                let result = manager.moveTabToNewProject(id: tab.id, from: project.id, in: nil)
                if let failure = result.failure { self?.tabDrag?.presentMoveFailure(failure) }
            },
        ]
        if !destinations.isEmpty { moveItems.append(.separator) }
        moveItems += destinations.map { destination in
            let title = destination.windowTitle.map { "\(destination.title) — \($0)" } ?? destination.title
            return .action(title: title, enabled: destination.isEnabled) { [weak self] in
                let result = manager.moveTab(id: tab.id, from: project.id, to: destination.projectID, in: destination.managerID)
                if let failure = result.failure { self?.tabDrag?.presentMoveFailure(failure) }
            }
        }
        items += [.separator, .submenu(title: String(localized: "Move Tab to Project"), items: moveItems), .separator]
        items += [
            .action(title: String(localized: "Close")) { project.close(tab) },
            .action(title: String(localized: "Close Others"), enabled: project.tabs.count > 1) { project.closeOthers(tab) },
            .action(title: String(localized: "Close Tabs to the Right"), enabled: project.tabs.last?.id != tab.id) { project.closeToRight(of: tab) },
            .separator,
            .action(title: String(localized: "Close Files"), enabled: project.hasFiles) { project.closeFiles() },
            .action(title: String(localized: "Close Diffs"), enabled: project.hasDiffs) { project.closeDiffs() },
            .separator,
            .action(title: String(localized: "Close All")) { project.closeAll() },
        ]
        return items
    }
}
