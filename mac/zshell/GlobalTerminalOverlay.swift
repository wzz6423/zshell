//
//  GlobalTerminalOverlay.swift
//  zshell
//

import AppKit
import Carbon.HIToolbox
import Combine

struct QuickTerminalShortcut: Equatable {
    static let defaultValue = QuickTerminalShortcut(
        keyCode: UInt32(kVK_ANSI_I),
        modifiers: UInt32(cmdKey)
    )

    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.supportedModifiers
    }

    init?(persistedValue: String?) {
        guard let persistedValue else { return nil }
        let components = persistedValue.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let keyCode = UInt32(components[0]),
              let modifiers = UInt32(components[1]),
              Self.isValid(modifiers: modifiers)
        else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    init?(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard Self.isValid(modifiers: modifiers) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    var persistedValue: String { "\(keyCode):\(modifiers)" }

    static func keyCode(for character: Character) -> UInt32? {
        keyLabels.first { $0.value == character.uppercased() }?.key
    }

    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (Self.keyLabels[keyCode] ?? "Key \(keyCode)")
    }

    private static let supportedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    private static let requiredModifiers = UInt32(cmdKey | optionKey | controlKey)

    private static func isValid(modifiers: UInt32) -> Bool {
        modifiers & requiredModifiers != 0
    }

    private static let keyLabels: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab", UInt32(kVK_Delete): "Delete",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
    ]
}

/// The independent quick terminal keeps its session while its window is hidden.
@MainActor
final class GlobalTerminalOverlay: NSObject {
    static let shared = GlobalTerminalOverlay()

    private static let hotkeySignature = OSType(0x4B45524F)
    private static let hotkeyIdentifier: UInt32 = 1
    private static let hotkeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }

        var receivedIdentifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedIdentifier
        )
        guard status == noErr,
              receivedIdentifier.signature == hotkeySignature,
              receivedIdentifier.id == hotkeyIdentifier
        else {
            return noErr
        }

        let overlay = Unmanaged<GlobalTerminalOverlay>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in overlay.toggle() }
        return noErr
    }

    private var hotkey: EventHotKeyRef?
    private var hotkeyHandlerRef: EventHandlerRef?
    private(set) var workspace: PaneTab?
    private var reusableWorkspace: PaneTab?
    private var reusableWindow: GlobalTerminalOverlayWindow?
    private var workspaceMode = QuickTerminalMode.reuse
    private var workspaceObservation: AnyCancellable?
    private var terminalWindow: GlobalTerminalOverlayWindow?
    private var backdropWindow: GlobalTerminalBackdropWindow?
    private var previousApplication: NSRunningApplication?
    private var isPinned = false
    private var isRecordingHotkey = false
    private var hotkeyRefreshScheduled = false
    private var pendingSnapshot: QuickTerminalWorkspaceSnapshot.Snapshot?
    private var isQuitting = false

    func start() {
        guard hotkeyHandlerRef == nil else { return }
        pendingSnapshot = SessionStore.loadQuickTerminalWorkspace()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotkeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard handlerStatus == noErr else {
            NSLog("zshell: could not install global terminal hotkey handler (\(handlerStatus))")
            return
        }
        hotkeyHandlerRef = handler

        refreshHotkeyRegistration()
    }

    func stop() {
        dismiss(restorePreviousApplication: false)
        unregisterHotkey()
        if let hotkeyHandlerRef { RemoveEventHandler(hotkeyHandlerRef) }
        hotkeyHandlerRef = nil
        backdropWindow?.close()
        terminalWindow?.close()
        reusableWindow?.close()
        if !isQuitting {
            for session in allSessions { session.terminate() }
        }
        workspaceObservation = nil
        backdropWindow = nil
        terminalWindow = nil
        reusableWindow = nil
        workspace = nil
        reusableWorkspace = nil
    }

    private var allSessions: [TerminalSession] {
        var seen = Set<UUID>()
        return ((workspace?.sessions ?? []) + (reusableWorkspace?.sessions ?? [])).filter { seen.insert($0.id).inserted }
    }

    func prepareForApplicationQuit(preserve: Bool, endAll: Bool = false) {
        guard !isQuitting else { return }
        isQuitting = true
        dismiss(restorePreviousApplication: false)
        if endAll {
            SessionStore.saveQuickTerminalWorkspace(nil)
        } else if let reusableWorkspace {
            SessionStore.saveQuickTerminalWorkspace(QuickTerminalWorkspaceSnapshot.capture(reusableWorkspace))
        } else {
            SessionStore.saveQuickTerminalWorkspace(pendingSnapshot)
        }
        for session in allSessions {
            let reusable = reusableWorkspace?.sessions.contains(where: { $0 === session }) == true
            session.prepareForApplicationQuit(preserve: preserve && reusable)
        }
    }

    func beginHotkeyRecording() {
        isRecordingHotkey = true
        unregisterHotkey()
    }

    func endHotkeyRecording() {
        isRecordingHotkey = false
        refreshHotkeyRegistration()
    }

    func reloadHotkey() {
        guard hotkeyHandlerRef != nil else { return }
        unregisterHotkey()
        refreshHotkeyRegistration()
    }

    /// First-responder and key-window callbacks arrive before AppKit has
    /// completed the focus change; coalesce them and read the settled state.
    func scheduleHotkeyRegistrationRefresh() {
        guard hotkeyHandlerRef != nil, !hotkeyRefreshScheduled else { return }
        hotkeyRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hotkeyRefreshScheduled = false
            self.refreshHotkeyRegistration()
        }
    }

    func refreshHotkeyRegistration() {
        guard hotkeyHandlerRef != nil else { return }
        // Carbon hotkeys are consumed before AppKit's local event monitors.
        // Unregister while the focused pane blocks commands so the original
        // key-down, repeats, and key-up reach its terminal input path.
        if isRecordingHotkey || (
            NSApp.keyWindow?.isKeyWindow == true
                && TerminalCommandRouting.isBlockingCommands(in: NSApp.keyWindow)
        ) {
            unregisterHotkey()
        } else {
            _ = registerHotkey(AppSettings.shared.quickTerminalShortcut)
        }
    }

    func setHotkey(_ shortcut: QuickTerminalShortcut) -> Bool {
        guard hotkeyHandlerRef != nil else {
            AppSettings.shared.quickTerminalShortcut = shortcut
            return true
        }
        defer { refreshHotkeyRegistration() }

        unregisterHotkey()
        guard registerHotkey(shortcut) else {
            _ = registerHotkey(AppSettings.shared.quickTerminalShortcut)
            return false
        }
        AppSettings.shared.quickTerminalShortcut = shortcut
        return true
    }

    private func registerHotkey(_ shortcut: QuickTerminalShortcut) -> Bool {
        guard hotkey == nil else { return true }

        var registeredHotkey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: Self.hotkeySignature, id: Self.hotkeyIdentifier),
            GetApplicationEventTarget(),
            0,
            &registeredHotkey
        )
        guard status == noErr else {
            NSLog("zshell: could not register global terminal hotkey \(shortcut.displayString) (\(status))")
            return false
        }
        hotkey = registeredHotkey
        return true
    }

    private func unregisterHotkey() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
    }

    func toggle() {
        if terminalWindow?.isVisible == true {
            dismiss()
        } else {
            show()
        }
    }

    func notificationPane(for sessionID: UUID) -> (tab: PaneTab, pane: Pane, session: TerminalSession)? {
        for tab in [workspace, reusableWorkspace].compactMap({ $0 }) {
            for pane in tab.allPanes {
                guard case .session(let session) = pane.content,
                      session.id == sessionID, !session.hasExited else { continue }
                return (tab, pane, session)
            }
        }
        return nil
    }

    func canRevealNotification(sessionID: UUID) -> Bool {
        guard let match = notificationPane(for: sessionID) else { return false }
        return terminalWindow?.isVisible != true || workspace === match.tab
    }

    @discardableResult
    func revealNotification(sessionID: UUID) -> Bool {
        guard let match = notificationPane(for: sessionID),
              canRevealNotification(sessionID: sessionID) else { return false }
        match.tab.focusedPaneID = match.pane.id
        if terminalWindow?.isVisible != true {
            show(modeOverride: match.tab === reusableWorkspace ? .reuse : workspaceMode)
        }
        guard workspace === match.tab, terminalWindow?.isVisible == true else { return false }
        terminalWindow?.makeKey()
        terminalWindow?.revealTerminal()
        match.session.markAutomationAgentSeen()
        return true
    }

    private func show(modeOverride: QuickTerminalMode? = nil) {
        guard !isQuitting, let screen = screenAtPointer() else { return }
        let mode = modeOverride ?? AppSettings.shared.quickTerminalMode
        if mode != workspaceMode {
            workspace = nil
            terminalWindow = nil
        }
        workspaceMode = mode
        if workspace == nil {
            if mode == .reuse {
                if reusableWorkspace == nil {
                    let tab = pendingSnapshot.map(QuickTerminalWorkspaceSnapshot.restore)
                        ?? PaneTab(content: .session(TerminalSession()))
                    pendingSnapshot = nil
                    reusableWorkspace = tab
                    workspaceObservation = Publishers.CombineLatest(tab.$layout, tab.$focusedPaneID)
                        .receive(on: DispatchQueue.main).sink { [weak self, weak tab] _ in
                            guard let self, let tab, !self.isQuitting, self.reusableWorkspace === tab else { return }
                            SessionStore.saveQuickTerminalWorkspace(QuickTerminalWorkspaceSnapshot.capture(tab))
                        }
                    configureSessions(in: tab)
                }
                workspace = reusableWorkspace
                terminalWindow = reusableWindow
            } else {
                let tab = PaneTab(content: .session(TerminalSession(allowsPersistence: false)))
                workspace = tab
                configureSessions(in: tab)
            }
        }
        guard let workspace else { return }
        let focusedPaneID = workspace.focusedPaneID
        repairExitedSessions(in: workspace)
        if terminalWindow == nil {
            let window = GlobalTerminalOverlayWindow(
                tab: workspace,
                defaultSize: AppSettings.shared.quickTerminalSize,
                defaultOpacity: AppSettings.shared.quickTerminalOpacity,
                onPinChanged: { [weak self] pinned in self?.setPinned(pinned) },
                split: { [weak self] edge in self?.split(toward: edge) },
                close: { [weak self] in self?.closeFocusedPane() }
            )
            window.delegate = self
            terminalWindow = window
            if mode == .reuse { reusableWindow = window }
        }
        guard let terminalWindow else { return }
        isPinned = terminalWindow.isPinned

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
            ? nil
            : frontmostApplication

        terminalWindow.prepareForPresentation(on: screen)
        for session in workspace.sessions { session.applyTheme(backgroundOpacity: terminalWindow.backgroundOpacity) }
        terminalWindow.orderFrontRegardless()
        terminalWindow.makeKey()
        // AppKit can select an initial responder while presenting the panel.
        // Restore the workspace's chosen pane before queuing terminal focus.
        if workspace.layout.contains(focusedPaneID), workspace.focusedPaneID != focusedPaneID {
            workspace.focusedPaneID = focusedPaneID
        }
        terminalWindow.revealTerminal()
        updateBackdrop(on: screen)
    }

    private func dismiss(restorePreviousApplication: Bool = true) {
        guard let terminalWindow, terminalWindow.isVisible else { return }

        backdropWindow?.orderOut(nil)
        terminalWindow.hideSettings()
        for session in workspace?.sessions ?? [] { session.surface.setSurfaceVisible(false) }
        terminalWindow.orderOut(nil)

        let application = previousApplication
        previousApplication = nil
        if workspaceMode == .fresh {
            for session in workspace?.sessions ?? [] { session.terminate() }
            terminalWindow.close()
            self.terminalWindow = nil
            workspace = nil
            isPinned = false
        }
        guard restorePreviousApplication,
              NSApp.isActive,
              let application,
              !application.isTerminated
        else { return }
        DispatchQueue.main.async {
            application.activate(options: [])
        }
    }

    func split(toward edge: PaneDropEdge) {
        guard let workspace, terminalWindow?.isVisible == true else { return }
        let directory: String?
        if case .session(let session)? = workspace.focusedContent { directory = session.currentDirectoryPath }
        else { directory = nil }
        let session = TerminalSession(initialDirectory: directory, allowsPersistence: workspaceMode == .reuse)
        workspace.split(Pane(content: .session(session)), toward: edge)
        configureSessions(in: workspace)
    }

    func closeFocusedPane() {
        guard let workspace, let pane = workspace.focusedPane,
              case .session(let session) = pane.content else { return }
        session.terminate()
        removeSession(session, from: workspace)
    }

    private func configureSessions(in tab: PaneTab) {
        for session in tab.sessions {
            session.onExited = { [weak self, weak tab] exited in
                guard let self, let tab else { return }
                self.removeSession(exited, from: tab)
            }
        }
    }

    private func removeSession(_ session: TerminalSession, from tab: PaneTab) {
        guard let pane = tab.allPanes.first(where: {
            if case .session(let current) = $0.content { return current === session }
            return false
        }) else { return }
        if tab.removePane(pane.id) { return }
        if workspace === tab {
            dismiss()
            terminalWindow?.close()
            terminalWindow = nil
            workspace = nil
            isPinned = false
        }
        if reusableWorkspace === tab {
            reusableWindow?.close()
            reusableWindow = nil
            reusableWorkspace = nil
            workspaceObservation = nil
            SessionStore.saveQuickTerminalWorkspace(nil)
        }
    }

    private func repairExitedSessions(in tab: PaneTab) {
        func repair(_ node: PaneNode) -> PaneNode {
            switch node {
            case .pane(var pane):
                if case .session(let session) = pane.content, session.hasExited {
                    pane.content = .session(TerminalSession(initialDirectory: session.currentDirectoryPath,
                                                           restoredSessionID: session.persistentSessionID,
                                                           isRestoredSession: true,
                                                           allowsPersistence: workspaceMode == .reuse))
                }
                return .pane(pane)
            case .split(var split):
                split.first = repair(split.first)
                split.second = repair(split.second)
                return .split(split)
            }
        }
        if tab.sessions.contains(where: \.hasExited) {
            tab.layout = repair(tab.layout)
            configureSessions(in: tab)
        }
    }

    private func setPinned(_ pinned: Bool) {
        isPinned = pinned
        guard let terminalWindow, terminalWindow.isVisible,
              let screen = screenForWindow(terminalWindow)
        else { return }
        updateBackdrop(on: screen)
    }

    private func updateBackdrop(on screen: NSScreen) {
        guard !isPinned, let terminalWindow, terminalWindow.isVisible else {
            backdropWindow?.orderOut(nil)
            return
        }
        if backdropWindow == nil {
            backdropWindow = GlobalTerminalBackdropWindow { [weak self] in
                self?.dismiss()
            }
        }
        guard let backdropWindow else { return }
        backdropWindow.setFrame(screen.frame, display: false)
        backdropWindow.orderFront(nil)
        backdropWindow.order(.below, relativeTo: terminalWindow.windowNumber)
    }

    func dismissFromWindow() {
        dismiss()
    }

    private func screenAtPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    private func screenForWindow(_ window: NSWindow) -> NSScreen? {
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }
}

extension GlobalTerminalOverlay: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard !isPinned, let resignedWindow = notification.object as? NSWindow,
              resignedWindow === terminalWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.terminalWindow,
                  window === resignedWindow,
                  window.isVisible,
                  !window.isKeyWindow,
                  !window.isShowingSettings
            else { return }
            self.dismiss()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let terminalWindow,
              terminalWindow.isVisible,
              let screen = screenForWindow(terminalWindow)
        else { return }
        updateBackdrop(on: screen)
    }
}

@MainActor
private final class GlobalTerminalOverlayWindow: NSPanel {
    private var content: GlobalTerminalContentView!
    private let defaultSize: CGFloat
    private var areaFraction: CGFloat
    private var resizeStartFrame: NSRect?
    private var resizeStartMouse: NSPoint?
    private var settingsPopover: NSPopover?
    private(set) var isPinned = false
    var backgroundOpacity: CGFloat { content.backgroundOpacity }
    private var hasConfiguredFrame = false

    init(
        tab: PaneTab,
        defaultSize: Double,
        defaultOpacity: Double,
        onPinChanged: @escaping (Bool) -> Void,
        split: @escaping (PaneDropEdge) -> Void,
        close: @escaping () -> Void
    ) {
        self.defaultSize = CGFloat(defaultSize)
        areaFraction = CGFloat(defaultSize)
        self.onPinChanged = onPinChanged
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = true
        isMovableByWindowBackground = false
        minSize = NSSize(width: 420, height: 260)

        content = GlobalTerminalContentView(
            tab: tab,
            opacity: CGFloat(defaultOpacity),
            isPinned: false,
            split: split,
            close: close,
            togglePinned: { [weak self] in
                guard let self else { return }
                self.setPinned(!self.isPinned)
            },
            showSettings: { [weak self] button in self?.showSettings(from: button) },
            beginResize: { [weak self] event in self?.beginResize(with: event) },
            resize: { [weak self] event in self?.resize(with: event) },
            endResize: { [weak self] in self?.endResize() }
        )
        contentView = content
        content.setBackgroundOpacity(CGFloat(defaultOpacity))
        content.setPinState(false)
    }

    private let onPinChanged: (Bool) -> Void

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if content.handleKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, content.handleKeyEquivalent(event) { return }
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape),
           !TerminalCommandRouting.isBlockingCommands(in: self),
           !TerminalHintMode.isPresented(in: self) {
            GlobalTerminalOverlay.shared.dismissFromWindow()
            return
        }
        super.sendEvent(event)
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        content.setPinState(pinned)
        onPinChanged(pinned)
    }

    func prepareForPresentation(on screen: NSScreen) {
        if !hasConfiguredFrame {
            let visibleFrame = screen.visibleFrame
            let scale = sqrt(max(defaultSize, 0.01))
            let size = NSSize(
                width: visibleFrame.width * scale,
                height: visibleFrame.height * scale
            )
            setFrame(
                NSRect(
                    x: visibleFrame.midX - size.width / 2,
                    y: visibleFrame.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                display: false
            )
            hasConfiguredFrame = true
        } else if !screen.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) {
            let visibleFrame = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.midY - frame.height / 2
            ))
            resizeForAreaFraction(areaFraction)
        }
    }

    func revealTerminal() {
        content.revealTerminal()
    }

    var isShowingSettings: Bool {
        settingsPopover?.isShown == true
    }

    func hideSettings() {
        settingsPopover?.close()
    }

    private func showSettings(from button: NSButton) {
        let popover = settingsPopover ?? NSPopover()
        popover.behavior = .transient
        popover.contentViewController = GlobalTerminalAdjustmentsViewController(
            size: { [weak self] in self?.currentAreaFraction ?? self?.areaFraction ?? 0.75 },
            setSize: { [weak self] value in self?.resizeForAreaFraction(value) },
            opacity: { [weak self] in self?.content.backgroundOpacity ?? 0.5 },
            setOpacity: { [weak self] value in self?.content.setBackgroundOpacity(value) }
        )
        settingsPopover = popover
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .maxY
        )
    }

    private var currentAreaFraction: CGFloat {
        guard let screen = screenContainingCenter else {
            return areaFraction
        }
        let visible = screen.visibleFrame
        return min(
            max((frame.width * frame.height) / (visible.width * visible.height),
                CGFloat(AppSettings.quickTerminalSizeRange.lowerBound)),
            CGFloat(AppSettings.quickTerminalSizeRange.upperBound)
        )
    }

    private func resizeForAreaFraction(_ value: CGFloat) {
        let fraction = min(
            max(value, CGFloat(AppSettings.quickTerminalSizeRange.lowerBound)),
            CGFloat(AppSettings.quickTerminalSizeRange.upperBound)
        )
        areaFraction = fraction
        guard let screen = screenContainingCenter else {
            return
        }
        let visible = screen.visibleFrame
        let aspect = max(frame.width / max(frame.height, 1), 0.5)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let maxWidth = max(minSize.width, 2 * min(center.x - visible.minX, visible.maxX - center.x))
        let maxHeight = max(minSize.height, 2 * min(center.y - visible.minY, visible.maxY - center.y))
        let height = sqrt(visible.width * visible.height * fraction / aspect)
        let scale = min(1, maxWidth / (height * aspect), maxHeight / height)
        let size = NSSize(width: height * aspect * scale, height: height * scale)
        setFrame(
            NSRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    private func beginResize(with event: NSEvent) {
        resizeStartFrame = frame
        resizeStartMouse = NSEvent.mouseLocation
    }

    private func resize(with event: NSEvent) {
        guard let startFrame = resizeStartFrame,
              let startMouse = resizeStartMouse,
              let screen = screenContaining(center: NSPoint(
                  x: startFrame.midX,
                  y: startFrame.midY
              ))
        else { return }
        let mouse = NSEvent.mouseLocation
        let visible = screen.visibleFrame
        let center = NSPoint(x: startFrame.midX, y: startFrame.midY)
        let maxWidth = max(minSize.width, 2 * min(center.x - visible.minX, visible.maxX - center.x))
        let maxHeight = max(minSize.height, 2 * min(center.y - visible.minY, visible.maxY - center.y))
        let width = min(
            max(minSize.width, startFrame.width + 2 * (mouse.x - startMouse.x)),
            maxWidth
        )
        let height = min(
            max(minSize.height, startFrame.height + 2 * (startMouse.y - mouse.y)),
            maxHeight
        )
        setFrame(
            NSRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            ),
            display: true
        )
        areaFraction = currentAreaFraction
    }

    private func endResize() {
        resizeStartFrame = nil
        resizeStartMouse = nil
    }

    private var screenContainingCenter: NSScreen? {
        screenContaining(center: NSPoint(x: frame.midX, y: frame.midY))
    }

    private func screenContaining(center: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }
}

@MainActor
private final class GlobalTerminalContentView: NSView {
    private let terminal: QuickTerminalWorkspaceView
    private let materialBackground: NSVisualEffectView
    private let titlebar: GlobalTerminalTitlebarView
    private let resizeHandle: GlobalTerminalResizeHandle
    private var shouldActivateTerminal = false
    private(set) var backgroundOpacity: CGFloat

    init(
        tab: PaneTab,
        opacity: CGFloat,
        isPinned: Bool,
        split: @escaping (PaneDropEdge) -> Void,
        close: @escaping () -> Void,
        togglePinned: @escaping () -> Void,
        showSettings: @escaping (NSButton) -> Void,
        beginResize: @escaping (NSEvent) -> Void,
        resize: @escaping (NSEvent) -> Void,
        endResize: @escaping () -> Void
    ) {
        terminal = QuickTerminalWorkspaceView(tab: tab, split: split, close: close)
        materialBackground = NSVisualEffectView()
        backgroundOpacity = opacity
        titlebar = GlobalTerminalTitlebarView(
            isPinned: isPinned,
            split: split,
            close: close,
            togglePinned: togglePinned,
            showSettings: showSettings
        )
        resizeHandle = GlobalTerminalResizeHandle(
            beginResize: beginResize,
            resize: resize,
            endResize: endResize
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateAppearanceColors()

        materialBackground.material = .hudWindow
        materialBackground.blendingMode = .behindWindow
        materialBackground.state = .active
        materialBackground.alphaValue = 1
        materialBackground.translatesAutoresizingMaskIntoConstraints = false
        titlebar.translatesAutoresizingMaskIntoConstraints = false
        terminal.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        terminal.setBackgroundOpacity(backgroundOpacity)
        addSubview(materialBackground)
        addSubview(titlebar)
        addSubview(terminal)
        addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            materialBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialBackground.topAnchor.constraint(equalTo: topAnchor),
            materialBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            titlebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titlebar.topAnchor.constraint(equalTo: topAnchor),
            titlebar.heightAnchor.constraint(equalToConstant: 32),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            terminal.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            resizeHandle.widthAnchor.constraint(equalToConstant: 16),
            resizeHandle.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        }
    }

    func setPinState(_ pinned: Bool) {
        titlebar.setPinState(pinned)
    }

    func setBackgroundOpacity(_ opacity: CGFloat) {
        backgroundOpacity = min(
            max(opacity, CGFloat(AppSettings.quickTerminalOpacityRange.lowerBound)),
            CGFloat(AppSettings.quickTerminalOpacityRange.upperBound)
        )
        terminal.setBackgroundOpacity(backgroundOpacity)
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool { terminal.handleKeyEquivalent(event) }

    func revealTerminal() {
        shouldActivateTerminal = true
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard shouldActivateTerminal,
              let window,
              terminal.window === window,
              terminal.bounds.width > 0,
              terminal.bounds.height > 0
        else { return }

        shouldActivateTerminal = false
        terminal.reveal()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow,
                  self.terminal.window === window
            else { return }
            self.terminal.reveal()
        }
    }
}

@MainActor
private final class GlobalTerminalTitlebarView: NSView {
    private let pinButton = NSButton()
    private let settingsButton = NSButton()
    private let splitRightButton = NSButton()
    private let splitDownButton = NSButton()
    private let closeButton = NSButton()
    private let togglePinned: () -> Void
    private let showSettings: (NSButton) -> Void
    private let split: (PaneDropEdge) -> Void
    private let closePane: () -> Void

    init(
        isPinned: Bool,
        split: @escaping (PaneDropEdge) -> Void,
        close: @escaping () -> Void,
        togglePinned: @escaping () -> Void,
        showSettings: @escaping (NSButton) -> Void
    ) {
        self.togglePinned = togglePinned
        self.showSettings = showSettings
        self.split = split
        closePane = close
        super.init(frame: .zero)

        configure(
            pinButton,
            imageName: isPinned ? "pin.fill" : "pin",
            label: String(localized: "Pin quick terminal"),
            tooltip: String(localized: "Pin quick terminal")
        )
        configure(
            settingsButton,
            imageName: "gearshape",
            label: String(localized: "Temporary terminal settings"),
            tooltip: String(localized: "Temporary terminal settings")
        )
        pinButton.target = self
        pinButton.action = #selector(pinPressed)
        settingsButton.target = self
        settingsButton.action = #selector(settingsPressed)
        for (button, symbol, title, action) in [
            (splitRightButton, "rectangle.split.2x1", String(localized: "Split Right"), #selector(splitRightPressed)),
            (splitDownButton, "rectangle.split.1x2", String(localized: "Split Down"), #selector(splitDownPressed)),
            (closeButton, "xmark", String(localized: "Close Pane"), #selector(closePressed)),
        ] {
            configure(button, imageName: symbol, label: title, tooltip: title)
            button.target = self
            button.action = action
        }

        pinButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pinButton)
        addSubview(settingsButton)
        NSLayoutConstraint.activate([
            pinButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 24),
            pinButton.heightAnchor.constraint(equalToConstant: 24),
            settingsButton.leadingAnchor.constraint(equalTo: pinButton.trailingAnchor, constant: 2),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 24),
            settingsButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        var previous = settingsButton
        for button in [splitRightButton, splitDownButton, closeButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 2),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
            previous = button
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPinState(_ pinned: Bool) {
        pinButton.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: nil
        )
        pinButton.toolTip = String(localized: pinned ? "Unpin quick terminal" : "Pin quick terminal")
        pinButton.setAccessibilityLabel(
            String(localized: pinned ? "Unpin quick terminal" : "Pin quick terminal")
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    @objc private func pinPressed() {
        togglePinned()
    }

    @objc private func settingsPressed() {
        showSettings(settingsButton)
    }

    @objc private func splitRightPressed() { split(.right) }
    @objc private func splitDownPressed() { split(.bottom) }
    @objc private func closePressed() { closePane() }

    private func configure(
        _ button: NSButton,
        imageName: String,
        label: String,
        tooltip: String
    ) {
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        button.isBordered = false
        button.bezelStyle = .recessed
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.focusRingType = .none
        button.toolTip = tooltip
        button.setAccessibilityLabel(label)
    }
}

@MainActor
private final class GlobalTerminalResizeHandle: NSView {
    private let beginResize: (NSEvent) -> Void
    private let resize: (NSEvent) -> Void
    private let endResize: () -> Void

    init(
        beginResize: @escaping (NSEvent) -> Void,
        resize: @escaping (NSEvent) -> Void,
        endResize: @escaping () -> Void
    ) {
        self.beginResize = beginResize
        self.resize = resize
        self.endResize = endResize
        super.init(frame: .zero)
        toolTip = String(localized: "Resize quick terminal")
        setAccessibilityLabel(String(localized: "Resize quick terminal"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        beginResize(event)
    }

    override func mouseDragged(with event: NSEvent) {
        resize(event)
    }

    override func mouseUp(with event: NSEvent) {
        endResize()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1
        for offset in stride(from: 5, through: 11, by: 3) {
            path.move(to: NSPoint(x: offset, y: 2))
            path.line(to: NSPoint(x: 14, y: 14 - offset + 2))
        }
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
        path.stroke()
    }
}

@MainActor
private final class GlobalTerminalBackdropWindow: NSPanel {
    init(dismiss: @escaping () -> Void) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        contentView = GlobalTerminalBackdropView(dismiss: dismiss)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class GlobalTerminalBackdropView: NSView {
    private let dismissAction: () -> Void

    init(dismiss: @escaping () -> Void) {
        dismissAction = dismiss
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) { dismissAction() }
    override func rightMouseDown(with event: NSEvent) { dismissAction() }
    override func otherMouseDown(with event: NSEvent) { dismissAction() }
}

@MainActor
private final class GlobalTerminalAdjustmentsViewController: NSViewController {
    private let readSize: () -> CGFloat
    private let setSize: (CGFloat) -> Void
    private let readOpacity: () -> CGFloat
    private let setOpacity: (CGFloat) -> Void
    private let sizeSlider = NSSlider()
    private let opacitySlider = NSSlider()
    private let sizeValue = NSTextField(labelWithString: "")
    private let opacityValue = NSTextField(labelWithString: "")
    private let modePopup = SettingsPopUpButton<QuickTerminalMode>(
        items: QuickTerminalMode.allCases.map { .value($0.title, $0) },
        onChange: { AppSettings.shared.quickTerminalMode = $0 }
    )

    init(
        size: @escaping () -> CGFloat,
        setSize: @escaping (CGFloat) -> Void,
        opacity: @escaping () -> CGFloat,
        setOpacity: @escaping (CGFloat) -> Void
    ) {
        readSize = size
        self.setSize = setSize
        readOpacity = opacity
        self.setOpacity = setOpacity
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        modePopup.select(AppSettings.shared.quickTerminalMode)
        sizeSlider.minValue = AppSettings.quickTerminalSizeRange.lowerBound
        sizeSlider.maxValue = AppSettings.quickTerminalSizeRange.upperBound
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.setAccessibilityLabel(String(localized: "Temporary terminal size"))

        opacitySlider.minValue = AppSettings.quickTerminalOpacityRange.lowerBound
        opacitySlider.maxValue = AppSettings.quickTerminalOpacityRange.upperBound
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.setAccessibilityLabel(String(localized: "Temporary terminal opacity"))

        [sizeValue, opacityValue].forEach {
            $0.alignment = .right
            $0.font = .monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .regular
            )
            $0.textColor = .secondaryLabelColor
            $0.widthAnchor.constraint(equalToConstant: 42).isActive = true
        }

        let modeLabel = NSTextField(labelWithString: String(localized: "Session behavior"))
        let modeRow = NSStackView(views: [modeLabel, modePopup])
        modeRow.orientation = .horizontal
        modeRow.spacing = 7
        let hint = NSTextField(wrappingLabelWithString: QuickTerminalMode.explanation)
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 332).isActive = true
        let stack = NSStackView(views: [
            modeRow,
            hint,
            row(title: String(localized: "Size"), slider: sizeSlider, value: sizeValue),
            row(title: String(localized: "Opacity"), slider: opacitySlider, value: opacityValue),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 230))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
        updateValues()
    }

    @objc private func sizeChanged() {
        setSize(sizeSlider.cgFloatValue)
        updateValues()
    }

    @objc private func opacityChanged() {
        setOpacity(opacitySlider.cgFloatValue)
        updateValues()
    }

    private func updateValues() {
        sizeSlider.doubleValue = Double(readSize())
        opacitySlider.doubleValue = Double(readOpacity())
        sizeValue.stringValue = "\(Int((sizeSlider.doubleValue * 100).rounded()))%"
        opacityValue.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
    }

    private func row(
        title: String,
        slider: NSSlider,
        value: NSTextField
    ) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 58).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 145).isActive = true
        let row = NSStackView(views: [label, slider, value])
        row.orientation = .horizontal
        row.spacing = 7
        return row
    }
}

private extension NSSlider {
    var cgFloatValue: CGFloat { CGFloat(doubleValue) }
}
