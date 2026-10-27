import AppKit
import Carbon.HIToolbox
import Combine

enum QuickTerminalMode: String, CaseIterable {
    case reuse
    case fresh

    static var explanation: String {
        String(localized: "Reuse keeps panes and tasks. New workspaces end when hidden. Mode changes apply on next show; the reusable workspace stays available when switching back. Shell history follows your shell configuration.")
    }

    var title: String {
        switch self {
        case .reuse: String(localized: "Reuse workspace")
        case .fresh: String(localized: "New workspace each time")
        }
    }
}

@MainActor
enum QuickTerminalWorkspaceSnapshot {
    typealias Snapshot = SessionSnapshot.ProjectSnapshot.TabSnapshot
    typealias Layout = SessionSnapshot.ProjectSnapshot.LayoutSnapshot

    static func capture(_ tab: PaneTab) -> Snapshot {
        Snapshot(layout: capture(tab.layout), focusedPaneIndex: tab.allPanes.firstIndex {
            $0.id == tab.focusedPaneID
        } ?? 0)
    }

    private static func capture(_ node: PaneNode) -> Layout {
        switch node {
        case .pane(let pane):
            guard case .session(let session) = pane.content else { preconditionFailure("Quick terminal contains only terminals") }
            return .pane(.init(content: .session(workingDirectory: session.currentDirectoryPath),
                               weight: 1, terminalID: session.id))
        case .split(let split):
            return .split(axis: split.axis, fraction: Double(split.fraction),
                          first: capture(split.first), second: capture(split.second))
        }
    }

    static func restore(_ snapshot: Snapshot) -> PaneTab {
        let layout = restore(snapshot.layout)
        let panes = layout.allPanes
        return PaneTab(layout: layout, focusedPaneID: panes[min(max(snapshot.focusedPaneIndex, 0), panes.count - 1)].id)
    }

    private static func restore(_ node: Layout) -> PaneNode {
        switch node {
        case .pane(let pane):
            let directory: String?
            if case .session(let saved) = pane.content { directory = saved } else { directory = nil }
            return .pane(Pane(content: .session(TerminalSession(
                initialDirectory: directory, restoredSessionID: pane.terminalID, isRestoredSession: true
            ))))
        case .split(let axis, let fraction, let first, let second):
            return .split(PaneSplit(axis: axis, fraction: CGFloat(fraction.isFinite ? min(max(fraction, 0.1), 0.9) : 0.5),
                                    first: restore(first), second: restore(second)))
        }
    }
}

/// AppKit hosts reuse the project pane model and terminal containers. Divider
/// drags update fractions in place; only structural changes rebuild the tree.
@MainActor
final class QuickTerminalWorkspaceView: NSView {
    let tab: PaneTab
    private var root: NSView?
    private var containers: [UUID: TerminalContainerView] = [:]
    private var splits: [UUID: QuickTerminalSplitView] = [:]
    private var structure = ""
    private var observations = Set<AnyCancellable>()
    private var opacity: CGFloat = 1
    private var needsActivation = false
    private let splitAction: (PaneDropEdge) -> Void
    private let closeAction: () -> Void

    init(tab: PaneTab, split: @escaping (PaneDropEdge) -> Void, close: @escaping () -> Void) {
        self.tab = tab
        splitAction = split
        closeAction = close
        super.init(frame: .zero)
        tab.$layout.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateLayout() }.store(in: &observations)
        tab.$focusedPaneID.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateFocus() }.store(in: &observations)
        updateLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reveal() {
        needsActivation = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateFocus()
    }

    func setBackgroundOpacity(_ value: CGFloat) {
        opacity = value
        for session in tab.sessions { session.applyTheme(backgroundOpacity: value) }
    }

    override func layout() {
        super.layout()
        root?.frame = bounds
        guard needsActivation, window?.isVisible == true, bounds.width > 0, bounds.height > 0 else { return }
        needsActivation = false
        for container in containers.values { container.activateSurfaceAfterLayout() }
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard !TerminalCommandRouting.isBlockingCommands(in: window) else { return false }
        let flags = event.modifierFlags.intersection(CommandShortcut.allowedModifiers)
        let character = event.charactersIgnoringModifiers?.lowercased()
        if character == "d", flags == .command || flags == [.command, .shift] {
            splitAction(flags.contains(.shift) ? .bottom : .right)
        } else if CommandShortcut(event: event) == AppSettings.shared.commandShortcut(for: .closePane) {
            closeAction()
        } else if flags == .command, character == "[" || character == "]" {
            if character == "[" { tab.focusPrevious() } else { tab.focusNext() }
        } else if flags == [.command, .option] {
            switch Int(event.keyCode) {
            case kVK_LeftArrow: tab.focusLeft()
            case kVK_RightArrow: tab.focusRight()
            case kVK_UpArrow: tab.focusUp()
            case kVK_DownArrow: tab.focusDown()
            default: return false
            }
        } else if flags == [.command, .control], character == "=" {
            tab.equalize()
        } else { return false }
        return true
    }

    private func updateLayout() {
        func identity(_ node: PaneNode) -> String {
            switch node {
            case .pane(let pane):
                if case .session(let session) = pane.content {
                    return pane.id.uuidString + String(describing: ObjectIdentifier(session.surface))
                }
                return pane.id.uuidString + pane.content.id.uuidString
            case .split(let split): return split.id.uuidString + identity(split.first) + identity(split.second)
            }
        }
        let next = identity(tab.layout)
        if next != structure {
            structure = next
            root?.removeFromSuperview()
            splits.removeAll()
            let ids = Set(tab.allPanes.map(\.id))
            containers = containers.filter { ids.contains($0.key) }
            root = build(tab.layout)
            if let root { root.frame = bounds; root.autoresizingMask = [.width, .height]; addSubview(root) }
        }
        func fractions(_ node: PaneNode) {
            guard case .split(let split) = node else { return }
            splits[split.id]?.applyFraction(split.fraction)
            fractions(split.first)
            fractions(split.second)
        }
        fractions(tab.layout)
        for session in tab.sessions { session.surface.setBackgroundOpacity(opacity) }
        reveal()
    }

    private func build(_ node: PaneNode) -> NSView {
        switch node {
        case .pane(let pane):
            guard case .session(let session) = pane.content else { preconditionFailure("Quick terminal contains only terminals") }
            let paneID = pane.id
            let container = containers[pane.id] ?? TerminalContainerView()
            if container.terminal !== session.surface {
                for child in container.subviews { child.removeFromSuperview() }
                container.mount(session.surface, scrollbar: session.overlayScrollbar, queueBar: session.promptQueueBar)
            }
            container.focusOnAppear = false
            containers[pane.id] = container
            session.surface.onBecomeFirstResponder = { [weak tab] in
                guard let tab, tab.focusedPaneID != paneID else { return }
                tab.focusedPaneID = paneID
            }
            session.surface.splitTarget.onSplit = { [weak self] edge in
                self?.tab.focusedPaneID = paneID
                self?.splitAction(edge)
            }
            return container
        case .split(let split):
            let splitID = split.id
            let view = QuickTerminalSplitView(axis: split.axis, fraction: split.fraction) { [weak self] fraction in
                guard let self, let old = self.tab.layout.fraction(of: splitID), abs(old - fraction) > 0.001 else { return }
                self.tab.layout = self.tab.layout.settingFraction(of: splitID, to: fraction)
            }
            view.addArrangedSubview(build(split.first))
            view.addArrangedSubview(build(split.second))
            splits[split.id] = view
            return view
        }
    }

    private func updateFocus() {
        guard window?.isVisible == true else { return }
        for pane in tab.allPanes {
            let paneID = pane.id
            let selected = pane.id == tab.focusedPaneID
            if let container = containers[pane.id] {
                container.wantsLayer = true
                container.layer?.borderWidth = tab.hasMultiplePanes && selected && AppSettings.shared.showPaneFocusRing ? 1 : 0
                container.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(CGFloat(AppSettings.shared.paneFocusRingOpacity)).cgColor
            }
            if selected, case .session(let session) = pane.content {
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session, let window = self.window, window.isKeyWindow,
                          self.tab.focusedPaneID == paneID,
                          session.surface.window === window else { return }
                    window.makeFirstResponder(session.surface)
                }
            }
        }
    }
}

@MainActor
private final class QuickTerminalSplitView: NSSplitView, NSSplitViewDelegate {
    private var fraction: CGFloat
    private var isApplyingFraction = false
    private var isDraggingDivider = false
    private let changed: (CGFloat) -> Void

    init(axis: PaneSplitAxis, fraction: CGFloat, changed: @escaping (CGFloat) -> Void) {
        self.fraction = fraction
        self.changed = changed
        super.init(frame: .zero)
        isVertical = axis == .horizontal
        dividerStyle = .thin
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func applyFraction(_ value: CGFloat) {
        fraction = min(max(value, 0.1), 0.9)
        guard arrangedSubviews.count == 2 else { return }
        isApplyingFraction = true
        let available = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
        setPosition(available * fraction, ofDividerAt: 0)
        isApplyingFraction = false
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { applyFraction(fraction) }

    override func mouseDown(with event: NSEvent) {
        isDraggingDivider = true
        defer {
            isDraggingDivider = false
            changed(fraction)
        }
        super.mouseDown(with: event)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // AppKit also posts this while resizing nested children. Persist only
        // an actual divider drag; incidental geometry must not rewrite ratios.
        guard isDraggingDivider, !isApplyingFraction, let first = arrangedSubviews.first else { return }
        let available = (isVertical ? bounds.width : bounds.height) - dividerThickness
        guard available > 0 else { return }
        fraction = (isVertical ? first.frame.width : first.frame.height) / available
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let available = (isVertical ? bounds.width : bounds.height) - dividerThickness
        return min(max(proposedPosition, available * 0.1), available * 0.9)
    }
}
