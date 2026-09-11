//
//  WorkspaceSplitViewController.swift
//  zshell
//

import AppKit
import Combine
import SwiftUI

/// AppKit owns the outer workspace geometry. The legacy SwiftUI views hosted in
/// each item own their content only; they never size or drag the outer columns.
@MainActor
final class WorkspaceSplitViewController: NSSplitViewController, NSSplitViewDelegate {
    private enum Layout {
        static let panelDefaultsKey = "rightSidebarWidth"
        static let projectDefaultsKey = "leftSidebarWidth"
        static let panelDefaultWidth: CGFloat = 240
        static let projectDefaultWidth: CGFloat = 220
        static let panelWidthRange: ClosedRange<CGFloat> = 180...500
        static let projectWidthRange: ClosedRange<CGFloat> = 160...400
    }

    private let manager: TerminalManager
    private let git: GitStatusModel
    private let tabSplitDrag: TabSplitDragCoordinator
    private let panelHost: NSHostingController<AnyView>
    private let workspaceHost: NSHostingController<AnyView>
    private let projectHost: NSHostingController<AnyView>
    private let panelItem: NSSplitViewItem
    private let workspaceItem: NSSplitViewItem
    private let projectItem: NSSplitViewItem
    private var managerObservation: AnyCancellable?
    private var defaultsObservation: NSObjectProtocol?
    private var panelWidth: CGFloat
    private var projectWidth: CGFloat
    private var applyingExternalWidths = false

    init(
        manager: TerminalManager,
        git: GitStatusModel,
        tabSplitDrag: TabSplitDragCoordinator
    ) {
        self.manager = manager
        self.git = git
        self.tabSplitDrag = tabSplitDrag
        let defaults = UserDefaults.standard
        panelWidth = Self.storedWidth(
            forKey: Layout.panelDefaultsKey,
            fallback: Layout.panelDefaultWidth,
            range: Layout.panelWidthRange,
            defaults: defaults
        )
        projectWidth = Self.storedWidth(
            forKey: Layout.projectDefaultsKey,
            fallback: Layout.projectDefaultWidth,
            range: Layout.projectWidthRange,
            defaults: defaults
        )
        panelHost = NSHostingController(rootView: AnyView(EmptyView()))
        workspaceHost = NSHostingController(rootView: AnyView(
            MainWorkspaceView(manager: manager, git: git, tabSplitDrag: tabSplitDrag)
        ))
        projectHost = NSHostingController(rootView: AnyView(
            SidebarView(manager: manager)
        ))
        panelItem = NSSplitViewItem(sidebarWithViewController: panelHost)
        workspaceItem = NSSplitViewItem(viewController: workspaceHost)
        projectItem = NSSplitViewItem(sidebarWithViewController: projectHost)
        super.init(nibName: nil, bundle: nil)

        splitView = WorkspaceSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        (splitView as? WorkspaceSplitView)?.onDoubleClickDivider = { [weak self] index in
            self?.restoreDefaultWidth(at: index)
        }

        panelItem.minimumThickness = Layout.panelWidthRange.lowerBound
        panelItem.maximumThickness = Layout.panelWidthRange.upperBound
        panelItem.canCollapse = true
        panelItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        projectItem.minimumThickness = Layout.projectWidthRange.lowerBound
        projectItem.maximumThickness = Layout.projectWidthRange.upperBound
        projectItem.canCollapse = true
        projectItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        workspaceItem.minimumThickness = 320

        addSplitViewItem(panelItem)
        addSplitViewItem(workspaceItem)
        addSplitViewItem(projectItem)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 2)

        updatePanelVisibility(manager.isPanelVisible)
        projectItem.isCollapsed = !manager.isLeftSidebarVisible
        observeState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        restoreWidths()
    }

    deinit {
        if let defaultsObservation {
            NotificationCenter.default.removeObserver(defaultsObservation)
        }
    }

    private func observeState() {
        managerObservation = manager.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updatePanelVisibility(self.manager.isPanelVisible)
                self.setCollapsed(
                    !self.manager.isLeftSidebarVisible,
                    item: self.projectItem,
                    restoredWidth: self.projectWidth,
                    subviewIndex: 2
                )
            }
        }
        defaultsObservation = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyStoredWidths()
            }
        }
    }

    private func updatePanelVisibility(_ visible: Bool) {
        if visible, panelItem.isCollapsed {
            panelHost.rootView = AnyView(RightSidebarView(manager: manager, git: git))
        }
        setCollapsed(!visible, item: panelItem, restoredWidth: panelWidth, subviewIndex: 0)
        if !visible, !panelItem.isCollapsed {
            panelHost.rootView = AnyView(EmptyView())
        }
    }

    private func setCollapsed(
        _ collapsed: Bool,
        item: NSSplitViewItem,
        restoredWidth: CGFloat,
        subviewIndex: Int
    ) {
        guard item.isCollapsed != collapsed else { return }
        let previousResponder = view.window?.firstResponder
        let responderWasInItem = previousResponder
            .flatMap { $0 as? NSView }
            .map { $0.isDescendant(of: item.viewController.view) } ?? false
        item.animator().isCollapsed = collapsed
        if !collapsed {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setThickness(restoredWidth, forSubviewAt: subviewIndex)
            }
        } else if responderWasInItem {
            restoreWorkspaceFocus()
        }
    }

    private func restoreWorkspaceFocus() {
        guard let window = view.window else { return }
        switch manager.selectedProject?.focusedContent {
        case .session(let session):
            window.makeFirstResponder(session.surface)
        case .file(let file):
            if let editor = (file.editorView as? NSScrollView)?.documentView {
                window.makeFirstResponder(editor)
            }
        case .browser(let browser):
            window.makeFirstResponder(browser.webView)
        case .diff, nil:
            window.makeFirstResponder(workspaceHost.view)
        }
    }

    private func restoreWidths() {
        setThickness(panelWidth, forSubviewAt: 0)
        setThickness(projectWidth, forSubviewAt: 2)
    }

    private func setThickness(_ thickness: CGFloat, forSubviewAt index: Int) {
        guard splitView.subviews.indices.contains(index) else { return }
        var frame = splitView.subviews[index].frame
        frame.size.width = thickness
        splitView.subviews[index].frame = frame
        splitView.adjustSubviews()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applyingExternalWidths, splitView.subviews.count == 3 else { return }
        if !panelItem.isCollapsed {
            panelWidth = Self.clamped(splitView.subviews[0].frame.width, to: Layout.panelWidthRange)
            persist(panelWidth, key: Layout.panelDefaultsKey)
        }
        if !projectItem.isCollapsed {
            projectWidth = Self.clamped(splitView.subviews[2].frame.width, to: Layout.projectWidthRange)
            persist(projectWidth, key: Layout.projectDefaultsKey)
        }
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        switch dividerIndex {
        case 0:
            return Layout.panelWidthRange.lowerBound
        case 1:
            return splitView.bounds.width - Layout.projectWidthRange.upperBound
        default:
            return proposedMinimumPosition
        }
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        switch dividerIndex {
        case 0:
            return Layout.panelWidthRange.upperBound
        case 1:
            return splitView.bounds.width - Layout.projectWidthRange.lowerBound
        default:
            return proposedMaximumPosition
        }
    }

    private func restoreDefaultWidth(at dividerIndex: Int) {
        switch dividerIndex {
        case 0:
            panelWidth = Layout.panelDefaultWidth
            persist(panelWidth, key: Layout.panelDefaultsKey)
            setThickness(panelWidth, forSubviewAt: 0)
        case 1:
            projectWidth = Layout.projectDefaultWidth
            persist(projectWidth, key: Layout.projectDefaultsKey)
            setThickness(projectWidth, forSubviewAt: 2)
        default:
            break
        }
    }

    private func applyStoredWidths() {
        let defaults = UserDefaults.standard
        let newPanelWidth = Self.storedWidth(
            forKey: Layout.panelDefaultsKey,
            fallback: Layout.panelDefaultWidth,
            range: Layout.panelWidthRange,
            defaults: defaults
        )
        let newProjectWidth = Self.storedWidth(
            forKey: Layout.projectDefaultsKey,
            fallback: Layout.projectDefaultWidth,
            range: Layout.projectWidthRange,
            defaults: defaults
        )
        guard newPanelWidth != panelWidth || newProjectWidth != projectWidth else { return }
        applyingExternalWidths = true
        panelWidth = newPanelWidth
        projectWidth = newProjectWidth
        if !panelItem.isCollapsed { setThickness(panelWidth, forSubviewAt: 0) }
        if !projectItem.isCollapsed { setThickness(projectWidth, forSubviewAt: 2) }
        applyingExternalWidths = false
    }

    private func persist(_ width: CGFloat, key: String) {
        let defaults = UserDefaults.standard
        guard abs(defaults.double(forKey: key) - width) > 0.5 else { return }
        defaults.set(Double(width), forKey: key)
    }

    private static func storedWidth(
        forKey key: String,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>,
        defaults: UserDefaults
    ) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return clamped(CGFloat(defaults.double(forKey: key)), to: range)
    }

    private static func clamped(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private final class WorkspaceSplitView: NSSplitView {
    var onDoubleClickDivider: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let dividerIndex = dividerIndex(at: convert(event.locationInWindow, from: nil)) {
            onDoubleClickDivider?(dividerIndex)
            return
        }
        super.mouseDown(with: event)
    }

    private func dividerIndex(at point: NSPoint) -> Int? {
        guard subviews.count > 1 else { return nil }
        for index in 0..<(subviews.count - 1) {
            let dividerRect = NSRect(
                x: subviews[index].frame.maxX,
                y: bounds.minY,
                width: dividerThickness,
                height: bounds.height
            )
            if dividerRect.insetBy(dx: -3, dy: 0).contains(point) {
                return index
            }
        }
        return nil
    }
}

struct WorkspaceSplitViewRepresentable: NSViewControllerRepresentable {
    let manager: TerminalManager
    let git: GitStatusModel
    let tabSplitDrag: TabSplitDragCoordinator

    func makeNSViewController(context: Context) -> WorkspaceSplitViewController {
        WorkspaceSplitViewController(
            manager: manager,
            git: git,
            tabSplitDrag: tabSplitDrag
        )
    }

    func updateNSViewController(
        _ viewController: WorkspaceSplitViewController,
        context: Context
    ) {}
}
