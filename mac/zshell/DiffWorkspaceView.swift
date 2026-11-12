import AppKit
import Combine
import SwiftUI

@MainActor
final class DiffWorkspaceLayout {
    weak var host: DiffWorkspaceNSView?
    private struct Anchor { weak var view: DiffPaneAnchorNSView? }
    private var anchors: [UUID: Anchor] = [:]

    func attach(_ view: DiffPaneAnchorNSView) {
        anchors[view.diffID] = Anchor(view: view)
        host?.needsLayout = true
    }

    func detach(_ view: DiffPaneAnchorNSView) {
        guard anchors[view.diffID]?.view === view else { return }
        anchors.removeValue(forKey: view.diffID)
        host?.needsLayout = true
    }

    func frame(for id: UUID, in host: NSView) -> NSRect? {
        guard let view = anchors[id]?.view, view.window != nil,
              view.window === host.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return view.convert(view.bounds, to: host)
    }
}

/// Native anchors report the actual pane content rectangle, including live
/// divider drags and zoom, without copying SwiftUI's geometry or header sizes.
@MainActor
final class DiffPaneAnchorNSView: NSView {
    let diffID: UUID
    private let placement: DiffWorkspaceLayout

    init(diffID: UUID, layout: DiffWorkspaceLayout) {
        self.diffID = diffID
        placement = layout
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { placement.detach(self) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { placement.detach(self) }
        else { placement.attach(self) }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        if window != nil { placement.attach(self) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if window != nil { placement.attach(self) }
    }

    override func layout() {
        super.layout()
        if window != nil { placement.attach(self) }
    }
}

@MainActor
final class DiffWorkspaceNSView: NSView {
    private let manager: TerminalManager
    private var views: [UUID: DiffViewerNSView] = [:]
    private var observation: AnyCancellable?
    private var updateScheduled = false
    private var clickMonitor: Any?

    init(manager: TerminalManager) {
        self.manager = manager
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        manager.diffWorkspaceLayout.host = self
        observation = manager.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window,
                  let tab = self.manager.selectedProject?.selectedTab,
                  let root = self.window?.contentView?.superview else { return event }
            let hitPoint = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            guard let hit = root.hitTest(hitPoint) else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if let pane = tab.allPanes.first(where: { pane in
                if case .diff(let diff) = pane.content, let view = self.views[diff.id] {
                    return !view.isHiddenOrHasHiddenAncestor && view.frame.contains(point)
                        && (hit === view || hit.isDescendant(of: view))
                }
                return false
            }) { tab.focusPane(pane.id) }
            return event
        }
        updateViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    isolated deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if manager.diffWorkspaceLayout.host === self { manager.diffWorkspaceLayout.host = nil }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), let hit = super.hitTest(point), hit !== self else { return nil }
        return hit
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let tab = manager.selectedProject?.selectedTab
        let visible = Set(tab?.allPanes.compactMap { pane -> UUID? in
            guard !((tab?.isZoomed ?? false) && tab?.focusedPaneID != pane.id),
                  case .diff(let diff) = pane.content else { return nil }
            return diff.id
        } ?? [])
        for (id, view) in views {
            let frame = visible.contains(id) ? manager.diffWorkspaceLayout.frame(for: id, in: self) : nil
            let shown = frame.map { !$0.isEmpty && bounds.intersects($0) } ?? false
            if view.isHidden == shown { view.isHidden = !shown }
            if let frame, shown, view.frame != frame { view.frame = frame }
            view.setSelected(shown)
        }
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.updateViews()
        }
    }

    private func updateViews() {
        let diffs = manager.projectsWithMountedDiffs.flatMap { $0.diffPlacements.map(\.diff) }
        let ids = Set(diffs.map(\.id))
        for id in views.keys where !ids.contains(id) { views.removeValue(forKey: id)?.removeFromSuperview() }
        for diff in diffs where views[diff.id] == nil {
            let view = DiffViewerNSView(diff: diff)
            view.isHidden = true
            views[diff.id] = view
            addSubview(view)
        }
        needsLayout = true
    }
}

struct DiffWorkspaceView: NSViewRepresentable {
    let manager: TerminalManager
    func makeNSView(context: Context) -> DiffWorkspaceNSView { DiffWorkspaceNSView(manager: manager) }
    func updateNSView(_ view: DiffWorkspaceNSView, context: Context) { view.needsLayout = true }
}

struct DiffPaneAnchorView: NSViewRepresentable {
    let diff: DiffTab
    let manager: TerminalManager
    func makeNSView(context: Context) -> DiffPaneAnchorNSView {
        DiffPaneAnchorNSView(diffID: diff.id, layout: manager.diffWorkspaceLayout)
    }
    func updateNSView(_ view: DiffPaneAnchorNSView, context: Context) { view.needsLayout = true }
}
