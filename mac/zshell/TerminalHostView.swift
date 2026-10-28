//
//  TerminalHostView.swift
//  zshell
//

import AppKit
import SwiftUI

/// Hosts a session's long-lived terminal surface in SwiftUI, wrapped in a
/// full-bleed container with the session's overlay scrollbar pinned to its
/// trailing edge. Text padding is owned by the terminal backend.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    let manager: TerminalManager
    /// Whether this terminal's pane is the focused one in its tab.
    var isFocused: Bool = true
    /// Called when the terminal takes focus itself (e.g. a click), so the
    /// model's focused pane can follow.
    var onFocused: () -> Void = {}
    /// Splits this pane on the given edge — wired to the context-menu items.
    var onSplit: (PaneDropEdge) -> Void = { _ in }
    var onNewBrowserTab: (String?) -> Void = { _ in }
    var onNewBrowserPane: (String?) -> Void = { _ in }
    var onNewFileTab: (String) -> Void = { _ in }
    var onNewFilePane: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        guard session.belongs(to: manager) else { return container }
        let terminal = session.surface
        let didFocus = onFocused
        container.terminal = terminal
        container.focusOnAppear = isFocused
        terminal.onBecomeFirstResponder = { [weak session] in session?.terminalDidBecomeFocused(); didFocus() }
        terminal.splitTarget.onSplit = onSplit
        terminal.splitTarget.onNewBrowserTab = onNewBrowserTab
        terminal.splitTarget.onNewBrowserPane = onNewBrowserPane
        terminal.splitTarget.onNewFileTab = onNewFileTab
        terminal.splitTarget.onNewFilePane = onNewFilePane
        context.coordinator.isFocused = isFocused
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard session.belongs(to: manager) else {
            (view as? TerminalContainerView)?.releaseTerminal(session.surface)
            return
        }
        // Mount whenever this container is not already hosting the surface.
        // Testing the weak `container.terminal` reference instead would skip
        // the first update: `makeNSView` primes that reference without adding
        // the surface to the hierarchy (mounting owns addSubview), so an
        // `!==` check passes forever and the pane renders blank while the
        // parking host's brief attachment keeps the shell alive. A superview
        // check also self-heals transfers: a surface arriving from another
        // window, a split reparent, or the parking host always remounts.
        if let container = view as? TerminalContainerView,
           session.surface.superview !== container {
            container.mount(session.surface, scrollbar: session.overlayScrollbar,
                            queueBar: session.promptQueueBar)
            // Height changes come from the bar's own model subscriptions; route
            // them into an immediate pane re-layout instead of waiting a frame.
            session.promptQueueBar.onLayoutChange = { [weak container] in
                container?.layoutSubtreeIfNeeded()
            }
        }
        let didFocus = onFocused
        session.surface.onBecomeFirstResponder = { [weak session] in session?.terminalDidBecomeFocused(); didFocus() }
        session.surface.splitTarget.onSplit = onSplit
        session.surface.splitTarget.onNewBrowserTab = onNewBrowserTab
        session.surface.splitTarget.onNewBrowserPane = onNewBrowserPane
        session.surface.splitTarget.onNewFileTab = onNewFileTab
        session.surface.splitTarget.onNewFilePane = onNewFilePane
        let container = view as? TerminalContainerView
        container?.setMaterialActive(AppSettings.shared.isTerminalBackgroundBlurActive)
        container?.activateSurfaceAfterLayout()
        container?.focusOnAppear = isFocused
        // Take focus only on the unfocused→focused edge (keyboard navigation,
        // a split landing here), never on every render — that would fight the
        // user for focus and make sidebar text fields untypable.
        if isFocused, !context.coordinator.isFocused, let container {
            container.requestTerminalFocus()
        }
        context.coordinator.isFocused = isFocused
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        guard let container = view as? TerminalContainerView,
              let terminal = container.terminal as? any TerminalBackendSurface
        else { return }
        // The closures below originate on PaneView and therefore capture its
        // PaneContent, including the same TerminalSession that owns `terminal`.
        // Clear them whenever SwiftUI removes this host so a closed tab cannot
        // leave the session and its renderer in a retain cycle. A parked
        // session gets fresh callbacks when its host is recreated. A transferred
        // terminal, however, may already carry fresh destination callbacks, so
        // only the host that still owns the surface may clear them.
        guard terminal.superview === container else {
            container.releaseTerminal(terminal)
            return
        }
        terminal.onBecomeFirstResponder = nil
        terminal.splitTarget.onSplit = nil
        terminal.splitTarget.onNewBrowserTab = nil
        terminal.splitTarget.onNewBrowserPane = nil
        terminal.splitTarget.onNewFileTab = nil
        terminal.splitTarget.onNewFilePane = nil
        // The queue bar is session-owned; drop the container callback so a
        // dismantled pane cannot be addressed by a later queue update.
        for case let bar as PromptQueueBarView in view.subviews {
            bar.onLayoutChange = nil
        }
        container.releaseTerminal(terminal)
    }

    final class Coordinator {
        var isFocused = false
    }
}

/// Keeps every non-visible terminal attached to the window. A backend may
/// start its shell only after attachment and drain process/title/bell events
/// from its own tick, so parking preserves the eager/background session
/// behavior Zshell had before the backend migration without drawing those panes
/// into the visible layout.
struct TerminalParkingView: NSViewRepresentable {
    let sessions: [TerminalSession]
    let manager: TerminalManager

    func makeNSView(context: Context) -> TerminalParkingContainerView {
        TerminalParkingContainerView(frame: .zero)
    }

    func updateNSView(_ view: TerminalParkingContainerView, context: Context) {
        view.mount(sessions.filter { $0.belongs(to: manager) })
    }

    static func dismantleNSView(
        _ view: TerminalParkingContainerView, coordinator: ()
    ) {
        view.unmountAll()
    }
}

final class TerminalParkingContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mount(_ sessions: [TerminalSession]) {
        let desired = Set(sessions.map { ObjectIdentifier($0.surface) })
        for subview in subviews where !desired.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }

        for session in sessions {
            let terminal = session.surface
            // Parked panes stay attached at full size so the grid survives
            // unparking, but nothing composites them. Marking them occluded
            // lets the backend drop the renderer's pane-sized IOSurfaces
            // (~20 MB each) while its wakeup check — gated on attachment,
            // not visibility — keeps title/bell/exit events draining.
            terminal.setSurfaceVisible(false)
            guard terminal.superview !== self else { continue }
            let parkedSize = terminal.frame.size
            if terminal.window?.firstResponder === terminal {
                terminal.window?.makeFirstResponder(nil)
            }
            terminal.removeFromSuperview()
            terminal.translatesAutoresizingMaskIntoConstraints = true
            let hasUsableSize =
                parkedSize.width.isFinite && parkedSize.height.isFinite
                && parkedSize.width > 0 && parkedSize.height > 0
            terminal.frame = NSRect(
                origin: .zero,
                size: hasUsableSize
                    ? parkedSize
                    : NSSize(width: 800, height: 600)
            )
            addSubview(terminal)
        }
    }

    func unmountAll() {
        for subview in subviews where subview.superview === self {
            subview.removeFromSuperview()
        }
    }
}

/// Focuses the terminal when its pane is the focused one — on first appearance
/// and when navigation moves focus here. `TerminalHostView` drives the edge;
/// this only performs the makeFirstResponder.
final class TerminalContainerView: NSView {
    weak var terminal: NSView?
    private var materialBackground: NSVisualEffectView?
    var focusOnAppear = true {
        didSet {
            if !focusOnAppear { pendingFocusRequest = false }
        }
    }
    private var pendingFocusRequest = false
    private var needsSurfaceActivation = false
    private var surfaceConstraints: [NSLayoutConstraint] = []
    private var pointerTrackingArea: NSTrackingArea?
    private var pointerWasInside = false
    private var lastPointerLocation: NSPoint?
    private var trackedSurfaceFrame = NSRect.zero
    private var activeMenus = Set<ObjectIdentifier>()
    private var activePopovers = Set<ObjectIdentifier>()

    func mount(_ terminal: NSView, scrollbar: NSView, queueBar: NSView? = nil) {
        NSLayoutConstraint.deactivate(surfaceConstraints)
        surfaceConstraints.removeAll()
        self.terminal = terminal
        terminal.translatesAutoresizingMaskIntoConstraints = false
        scrollbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        addSubview(scrollbar, positioned: .above, relativeTo: terminal)
        // Text padding lives inside the backend. Insetting the surface itself
        // exposes a contrasting background strip beside the header and sidebars.
        if let queueBar {
            // The prompt queue bar docks: the terminal's bottom edge rides the
            // bar's top edge, so an open bar claims height from the grid instead
            // of covering the prompt the way a floating overlay would. At the
            // bar's zero closed height this chain is identical to pinning the
            // terminal to the container's bottom edge.
            queueBar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(queueBar, positioned: .above, relativeTo: scrollbar)
            surfaceConstraints = [
                terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
                terminal.topAnchor.constraint(equalTo: topAnchor),
                terminal.bottomAnchor.constraint(equalTo: queueBar.topAnchor),
                queueBar.leadingAnchor.constraint(equalTo: leadingAnchor),
                queueBar.trailingAnchor.constraint(equalTo: trailingAnchor),
                queueBar.bottomAnchor.constraint(equalTo: bottomAnchor),
                scrollbar.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollbar.topAnchor.constraint(equalTo: topAnchor),
                scrollbar.bottomAnchor.constraint(equalTo: bottomAnchor),
                scrollbar.widthAnchor.constraint(equalToConstant: OverlayScrollbarView.stripWidth),
            ]
        } else {
            surfaceConstraints = [
                terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
                terminal.topAnchor.constraint(equalTo: topAnchor),
                terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
                scrollbar.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollbar.topAnchor.constraint(equalTo: topAnchor),
                scrollbar.bottomAnchor.constraint(equalTo: bottomAnchor),
                scrollbar.widthAnchor.constraint(equalToConstant: OverlayScrollbarView.stripWidth),
            ]
        }
        NSLayoutConstraint.activate(surfaceConstraints)
        // A parked Metal surface has discarded its drawable pool. Activate it
        // only after Auto Layout assigns the real pane geometry.
        activateSurfaceAfterLayout()
        synchronizePointerPresence()
    }

    func releaseTerminal(_ requested: NSView) {
        guard terminal === requested else { return }
        NSLayoutConstraint.deactivate(surfaceConstraints)
        surfaceConstraints.removeAll()
        terminal = nil
        synchronizePointerPresence()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMaterialState()
        NotificationCenter.default.removeObserver(self)
        activeMenus.removeAll()
        activePopovers.removeAll()
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(menuTrackingChanged(_:)), name: name, object: nil
                )
            }
            for name in [NSPopover.willShowNotification, NSPopover.didCloseNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(popoverVisibilityChanged(_:)), name: name, object: nil
                )
            }
            if needsSurfaceActivation {
                needsLayout = true
            }
        }
        synchronizePointerPresence()
        guard focusOnAppear else { return }
        requestTerminalFocus()
    }

    func setMaterialActive(_ active: Bool) {
        guard active != (materialBackground != nil) else { return }
        if active {
            guard let terminal, terminal.superview === self else { return }
            let material = NSVisualEffectView()
            material.material = .underWindowBackground
            material.blendingMode = .behindWindow
            material.state = .followsWindowActiveState
            material.translatesAutoresizingMaskIntoConstraints = false
            addSubview(material, positioned: .below, relativeTo: terminal)
            NSLayoutConstraint.activate([
                material.leadingAnchor.constraint(equalTo: leadingAnchor),
                material.trailingAnchor.constraint(equalTo: trailingAnchor),
                material.topAnchor.constraint(equalTo: topAnchor),
                material.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            materialBackground = material
        } else {
            materialBackground?.removeFromSuperview()
            materialBackground = nil
        }
    }

    private func updateMaterialState() {
        setMaterialActive(AppSettings.shared.isTerminalBackgroundBlurActive)
    }

    func activateSurfaceAfterLayout() {
        needsSurfaceActivation = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if trackedSurfaceFrame != terminal?.frame {
            trackedSurfaceFrame = terminal?.frame ?? .zero
            synchronizePointerPresence()
        }
        guard needsSurfaceActivation,
              window != nil,
              bounds.width > 0, bounds.height > 0,
              let terminal = terminal as? any TerminalBackendSurface,
              terminal.window != nil,
              terminal.bounds.width > 0, terminal.bounds.height > 0
        else { return }
        needsSurfaceActivation = false
        terminal.setSurfaceVisible(true)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        synchronizePointerPresence()
        guard focusOnAppear, pendingFocusRequest else { return }
        focusTerminalIfPossible()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        pointerTrackingArea = area
        synchronizePointerPresence()
    }

    override func viewDidHide() {
        super.viewDidHide()
        synchronizePointerPresence()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        synchronizePointerPresence()
    }

    override func mouseExited(with event: NSEvent) {
        pointerWasInside = isPointerInsideTerminal(at: event.locationInWindow)
        lastPointerLocation = event.locationInWindow
    }

    override func mouseMoved(with event: NSEvent) {
        guard event.type == .mouseMoved, let window, event.window === window else { return }
        let location = event.locationInWindow
        let inside = isPointerInsideTerminal(at: location)
        let entered = inside && !pointerWasInside && lastPointerLocation != location
        pointerWasInside = inside
        lastPointerLocation = location
        guard entered,
              AppSettings.shared.focusFollowsMouse,
              window.isKeyWindow, window.isVisible, !window.isMiniaturized,
              NSApp.isActive || window.styleMask.contains(.nonactivatingPanel),
              window.attachedSheet == nil, window.sheetParent == nil, NSApp.modalWindow == nil,
              activeMenus.isEmpty, activePopovers.isEmpty,
              RunLoop.current.currentMode != .eventTracking,
              NSEvent.pressedMouseButtons == 0,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              !TerminalCommandRouting.isBlockingCommands(in: window),
              let terminal, terminal.superview === self, terminal.window === window,
              window.firstResponder !== terminal,
              (window.firstResponder as? NSTextView)?.isEditable != true,
              let root = window.contentView?.superview
        else { return }
        let point = root.superview?.convert(location, from: nil) ?? location
        guard let hit = root.hitTest(point), hit === terminal || hit.isDescendant(of: terminal) else { return }
        if window.makeFirstResponder(terminal) { pendingFocusRequest = false }
    }

    private func isPointerInsideTerminal(at location: NSPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, alphaValue > 0.01,
              let terminal, terminal.superview === self,
              !terminal.isHiddenOrHasHiddenAncestor, terminal.alphaValue > 0.01
        else { return false }
        let point = convert(location, from: nil)
        return NSIntersectionRect(bounds, visibleRect).contains(point) && terminal.frame.contains(point)
    }

    private func synchronizePointerPresence() {
        // 窗格挂载、重新布局和 tracking 重建会产生合成 enter，不能让静止指针切走键盘焦点。
        lastPointerLocation = window?.mouseLocationOutsideOfEventStream
        guard let location = lastPointerLocation, let terminal, terminal.superview === self else {
            pointerWasInside = false
            return
        }
        // AppKit 在更新可见性前调用 viewDidUnhide；此处只记几何位置，事件处理再检查可见性。
        let point = convert(location, from: nil)
        pointerWasInside = bounds.contains(point) && terminal.frame.contains(point)
    }

    @objc private func menuTrackingChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        if notification.name == NSMenu.didBeginTrackingNotification {
            activeMenus.insert(ObjectIdentifier(menu))
        } else {
            activeMenus.remove(ObjectIdentifier(menu))
        }
    }

    @objc private func popoverVisibilityChanged(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        if notification.name == NSPopover.willShowNotification {
            activePopovers.insert(ObjectIdentifier(popover))
        } else {
            activePopovers.remove(ObjectIdentifier(popover))
        }
    }

    func requestTerminalFocus() {
        pendingFocusRequest = true
        focusTerminalIfPossible()
    }

    private func focusTerminalIfPossible() {
        guard NSApp.isActive, let window, window.isKeyWindow, let terminal else {
            return
        }
        DispatchQueue.main.async { [weak self, weak window, weak terminal] in
            guard
                let self,
                let window,
                let terminal,
                self.focusOnAppear,
                NSApp.isActive,
                window.isKeyWindow,
                terminal.window === window
            else { return }
            if window.makeFirstResponder(terminal) {
                self.pendingFocusRequest = false
            }
        }
    }
}
