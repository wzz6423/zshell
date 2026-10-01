//
//  ZshellTerminalView.swift
//  zshell
//

import AppKit
import Darwin
import GhosttyTerminal

/// Zshell's libghostty backend: Ghostty's Metal-backed terminal surface plus
/// Zshell's pane focus, context menu, effective application focus, and
/// Finder/file-tree drop behavior.
///
/// This is the only type in Zshell that knows libghostty exists. It owns the
/// `TerminalController`, renders Zshell's settings into Ghostty's config, and
/// translates Ghostty's delegate callbacks into ``TerminalBackendEvents`` —
/// see `ZshellTerminalView+Ghostty.swift`.
final class ZshellTerminalView: AppTerminalView, TerminalBackendSurface {
    /// The session listening to this surface. Weak: the session owns the view.
    weak var events: (any TerminalBackendEvents)?

    /// Fired whenever direct interaction makes this pane the active one.
    var onBecomeFirstResponder: (() -> Void)?
    let splitTarget = SplitMenuTarget()
    let commandRouting = TerminalCommandRouting()

    /// Held strongly for the surface's lifetime; ``detach()`` drops it.
    var ghosttyController: TerminalController?
    /// The `/bin/sh -c …` line this surface launched, kept so a live
    /// re-configure can restate it rather than start a second shell.
    var launchCommand = ""
    /// The final login shell behind Zshell's `/bin/sh -c` launch shim.
    var launchShellIntegration = "none"
    var supportsInputSelection = false
    var nativeCursorClickToMove = true
    private var inputSelectionDragActive = false
    private var promptInputStart: (row: UInt64, column: Int)?
    private var promptSelectionAnchor: (row: Int, column: Int)?
    private var inputSelectionMouseEvent: NSEvent?
    private var suppressPointerEventsUntilMouseDown = false
    private var pendingPromptSelectionActivation = false
    private var pointerSelectionDragged = false
    private var aiInputPointerActive = false
    private var isForwardingRightMouseButton = false
    private var selectionAutoscrollTimer: Timer?
    private var selectionAutoscrollModifierFlags: NSEvent.ModifierFlags = []
    private lazy var aiInputEditor = TerminalAIInputEditor(
        readSnapshot: { [weak self] in self?.aiInputContext()?.snapshot },
        sendControl: { [weak self] in self?.sendAIInputControl($0) },
        clearHighlight: {}
    )
    /// Latest scroll report, so a scrollbar drag can be mapped back onto a row.
    var lastScroll: TerminalScrollPosition?
    /// Ghostty reports the recognized link under the pointer as hover state.
    /// The Command-right-click menu uses it to seed a new browser.
    var hoveredLink: String?

    private let progressBar = ZshellTerminalProgressBarView(frame: .zero)
    private var isCapturingHistoryExport = false
    private var capturedHistoryExportPath: String?
    private var isSurfaceVisible = false
    /// Process metadata keeps local shells in sync until their OSC 7 support
    /// reports a directory, which is required for remote sessions.
    private var directoryTimer: Timer?
    private var lastReportedDirectory: String?
    private var usesOSCWorkingDirectory = false
    private(set) var backgroundOpacity = 1.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        installProgressBar()
        registerForDraggedTypes([.fileURL])
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(effectiveFocusChanged(_:)),
                name: name,
                object: nil
            )
        }
    }

    /// Entry point for `TerminalBackend.makeSurface(launch:)`. Starts the
    /// emulator immediately; libghostty only spawns the shell once the view is
    /// attached to a window, which `TerminalHostView` guarantees.
    convenience init(launch: TerminalLaunch) {
        self.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        start(launch: launch)
    }

    deinit {
        directoryTimer?.invalidate()
        selectionAutoscrollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - TerminalBackendSurface

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func setSurfaceVisible(_ visible: Bool) {
        if !visible { stopSelectionAutoscroll() }
        isSurfaceVisible = visible
        super.setSurfaceVisible(visible)
        updateDirectoryPolling()
    }

    @objc private func effectiveFocusChanged(_ notification: Notification) {
        updateDirectoryPolling()
        GlobalTerminalOverlay.shared.scheduleHotkeyRegistrationRefresh()
    }

    private func updateDirectoryPolling() {
        let shouldPoll = !usesOSCWorkingDirectory
            && isSurfaceVisible
            && window?.isKeyWindow == true
        guard shouldPoll else {
            directoryTimer?.invalidate()
            directoryTimer = nil
            return
        }
        reportWorkingDirectory()
        guard directoryTimer == nil else { return }
        directoryTimer = Timer.scheduledTimer(
            withTimeInterval: 1, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportWorkingDirectory() }
        }
    }

    private func reportWorkingDirectory() {
        guard !usesOSCWorkingDirectory,
              let pid = foregroundPid,
              let path = processWorkingDirectory(pid: pid),
              path != lastReportedDirectory
        else { return }
        lastReportedDirectory = path
        events?.terminalDidChangeWorkingDirectory(path)
    }

    func stopDirectoryPollingForOSC() {
        usesOSCWorkingDirectory = true
        directoryTimer?.invalidate()
        directoryTimer = nil
    }

    func setBackgroundOpacity(_ opacity: CGFloat) {
        backgroundOpacity = min(max(Double(opacity), 0), 1)
        applyAppearance()
    }

    func sendEnter() {
        performBindingAction("text:\\x0d")
    }

    func clearScreen() {
        performBindingAction("clear_screen")
        // Ask the foreground shell to repaint its prompt at the top.
        performBindingAction("text:\\x0c")
    }

    func scroll(toFraction fraction: Double) {
        guard let lastScroll else { return }
        scrollToRow(UInt(clamping: lastScroll.row(atDragFraction: fraction)))
    }

    func beginFind(_ needle: String) { search(needle) }

    func endFind() { endSearch() }

    func stepFind(forward: Bool) { navigateSearch(forward: forward) }

    func findSelection() { searchSelection() }

    func readVisibleText(maxLines: Int, maxColumns: Int) -> String? {
        readViewportText(maxLines: maxLines, maxColumns: maxColumns)
    }

    func sendApplicationScroll(lines: Int) -> Bool {
        guard lines != 0,
              let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: Int32(clamping: lines),
                wheel2: 0,
                wheel3: 0
              ),
              let event = NSEvent(cgEvent: cgEvent)
        else { return false }
        super.scrollWheel(with: event)
        return true
    }

    func exportScreenFile() -> String? {
        captureHistoryExportPath(action: "write_screen_file:open,vt")
    }

    func exportScrollbackFile() -> String? {
        captureHistoryExportPath(action: "write_scrollback_file:open,vt")
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 2
        progressBar.frame = CGRect(
            x: 0, y: bounds.height - height,
            width: bounds.width, height: height
        )
    }

    private func installProgressBar() {
        progressBar.isHidden = true
        addSubview(progressBar)
    }

    /// Mirrors Zshell's OSC 9;4 indicator: a two-point bar
    /// at the top of the terminal, with error/pause colors and a 15-second
    /// stale-report timeout.
    func applyProgressReport(state: TerminalProgressState, percent: Int?) {
        progressBar.applyReport(state: state, percent: percent)
    }

    /// Uses Ghostty's `open` export action as a synchronous host callback. The
    /// delegate consumes that one URL into this slot instead of opening it.
    private func captureHistoryExportPath(action: String) -> String? {
        guard !isCapturingHistoryExport else { return nil }
        isCapturingHistoryExport = true
        capturedHistoryExportPath = nil
        defer {
            isCapturingHistoryExport = false
            capturedHistoryExportPath = nil
        }
        guard performBindingAction(action) else { return nil }
        return capturedHistoryExportPath
    }

    func consumeHistoryExportURL(_ url: String, kind: TerminalOpenURLKind) -> Bool {
        guard isCapturingHistoryExport else { return false }
        guard case .text = kind else { return false }
        capturedHistoryExportPath = url
        return true
    }

    /// The quick-terminal panel can be key without activating Zshell.
    var hasEffectiveTerminalFocus: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }

    override func isAccessibilityElement() -> Bool { isSurfaceVisible }

    override func isAccessibilityEnabled() -> Bool { isSurfaceVisible }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityRoleDescription() -> String? {
        NSAccessibility.Role.description(for: self)
    }

    override func accessibilityLabel() -> String? {
        String(localized: "Terminal")
    }

    override func accessibilityHelp() -> String? {
        String(localized: "Type to enter terminal text.")
    }

    override func accessibilityValue() -> Any? { "" }

    override func accessibilityNumberOfCharacters() -> Int { 0 }

    override func accessibilitySelectedText() -> String? { "" }

    override func setAccessibilitySelectedText(_ text: String?) {
        insertAccessibilityText(text)
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    override func isAccessibilityFocused() -> Bool {
        hasEffectiveTerminalFocus
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        if !focused, window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        } else if focused, isSurfaceVisible {
            window?.makeFirstResponder(self)
        }
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        // AXValue replaces a document and must be readable after a write.
        // Advertising it on a terminal makes dictation retry, then paste again.
        if selector == #selector(setAccessibilityValue(_:)) { return false }
        if selector == #selector(setAccessibilitySelectedText(_:)) {
            // Keep the setter discoverable while Zshell is inactive, but never
            // advertise a parked or otherwise unfocused terminal as writable.
            return isSurfaceVisible && window?.firstResponder === self
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    /// AXSelectedText inserts at the live caret without replacing a document.
    private func insertAccessibilityText(_ value: Any?) {
        let text = (value as? String) ?? (value as? NSAttributedString)?.string ?? ""
        guard isSurfaceVisible, hasEffectiveTerminalFocus else { return }
        guard !text.isEmpty else { return }
        finalizePointerSelectionBeforeInput()
        recordPromptInputStart()
        if aiInputEditor.deferWhileBusy({ [weak self] in self?.insertAccessibilityText(text) })
            || aiInputEditor.replaceSelection(then: { [weak self] in self?.sendText(text) }) {
            return
        }
        activatePendingPromptSelection()
        sendText(text)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            recordPromptInputStart()
            onBecomeFirstResponder?()
            GlobalTerminalOverlay.shared.scheduleHotkeyRegistrationRefresh()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        if let event = inputSelectionMouseEvent {
            super.mouseUp(with: localInputSelectionEvent(event, type: .leftMouseUp))
            suppressPointerEventsUntilMouseDown = true
        }
        aiInputEditor.cancel()
        stopSelectionAutoscroll()
        inputSelectionDragActive = false
        promptSelectionAnchor = nil
        inputSelectionMouseEvent = nil
        pointerSelectionDragged = false
        pendingPromptSelectionActivation = false
        aiInputPointerActive = false
        GlobalTerminalOverlay.shared.scheduleHotkeyRegistrationRefresh()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopSelectionAutoscroll()
        // This view is long-lived and reparented as panes split. Resign while
        // the old window still owns us so Ghostty receives FocusOut and draws
        // an inactive cursor instead of retaining stale focus state.
        if newWindow == nil, let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        stopSelectionAutoscroll()
        selectionAutoscrollModifierFlags = []
        inputSelectionDragActive = false
        promptSelectionAnchor = nil
        inputSelectionMouseEvent = nil
        suppressPointerEventsUntilMouseDown = false
        pendingPromptSelectionActivation = false
        pointerSelectionDragged = false
        aiInputPointerActive = false
        focusForInteraction()
        updateCursorClickToMove()
        recordPromptInputStart()
        if canEditPromptSelection { performBindingAction("text:\\x1b[27;2;27~") }
        let aiContext = event.clickCount == 1 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            ? aiInputContext(for: event) : nil
        aiInputPointerActive = aiContext?.caret != nil
        aiInputEditor.beginPointer(at: aiContext?.caret, in: aiContext?.snapshot)
        super.mouseDown(with: localInputSelectionEvent(event))
        promptSelectionAnchor = promptCaret(for: event)
        if promptSelectionAnchor != nil || aiInputPointerActive { inputSelectionMouseEvent = event }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !suppressPointerEventsUntilMouseDown else { return }
        pointerSelectionDragged = true
        selectionAutoscrollModifierFlags = event.modifierFlags
        if promptSelectionAnchor != nil, canEditPromptSelection {
            inputSelectionDragActive = true
        }
        super.mouseDragged(with: localInputSelectionEvent(event))
        if inputSelectionMouseEvent != nil { inputSelectionMouseEvent = event }
        if isMouseCaptured {
            stopSelectionAutoscroll()
        } else {
            updateSelectionAutoscroll(at: convert(event.locationInWindow, from: nil))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !suppressPointerEventsUntilMouseDown else { return }
        finishPointerSelection(with: event, copyOnSelect: true)
    }

    private func finishPointerSelection(with event: NSEvent, copyOnSelect: Bool) {
        stopSelectionAutoscroll()
        let hadInputSelection = inputSelectionDragActive
        super.mouseUp(with: localInputSelectionEvent(event, type: .leftMouseUp))
        if copyOnSelect, pointerSelectionDragged, !isMouseCaptured, AppSettings.shared.copyOnSelect {
            copySelectedTextToPasteboard()
        }
        let aiContext = aiInputContext(for: event, clampingDrag: pointerSelectionDragged)
        aiInputEditor.endPointer(
            at: aiContext?.caret, in: aiContext?.snapshot, dragged: pointerSelectionDragged
        )
        if hadInputSelection, let anchor = promptSelectionAnchor,
           let endpoint = promptCaret(for: event, allowZeroClick: true),
           let snapshot = readViewportTextSnapshot(),
           let toAnchor = promptCursorMovement(
                from: (snapshot.cursorRow, snapshot.cursorColumn), to: anchor
           ), let toEndpoint = promptCursorMovement(from: anchor, to: endpoint) {
            performBindingAction("text:" + toAnchor + "\\x1f" + toEndpoint + "\\x1e")
            pendingPromptSelectionActivation = true
        }
        inputSelectionDragActive = false
        promptSelectionAnchor = nil
        inputSelectionMouseEvent = nil
        pointerSelectionDragged = false
        aiInputPointerActive = false
    }

    private func localInputSelectionEvent(_ event: NSEvent, type: NSEvent.EventType? = nil) -> NSEvent {
        let bypassCapture = aiInputPointerActive && isMouseCaptured
        let type = type ?? event.type
        guard bypassCapture || type != event.type else { return event }
        return NSEvent.mouseEvent(
            with: type, location: event.locationInWindow,
            modifierFlags: bypassCapture ? event.modifierFlags.union(.shift) : event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
            clickCount: event.clickCount, pressure: event.pressure
        ) ?? event
    }

    private func updateSelectionAutoscroll(at location: NSPoint) {
        guard TerminalSelectionAutoscrollDirection(
            locationY: location.y, bounds: bounds
        ) != nil else {
            stopSelectionAutoscroll()
            return
        }
        guard selectionAutoscrollTimer == nil else { return }

        // Common modes keep the timer firing while AppKit tracks a mouse drag.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollSelection() }
        }
        RunLoop.main.add(timer, forMode: .common)
        selectionAutoscrollTimer = timer
    }

    private func autoscrollSelection() {
        guard pointerSelectionDragged,
              isSurfaceVisible,
              !isMouseCaptured,
              let window,
              window.isKeyWindow,
              window.firstResponder === self,
              let lastScroll
        else {
            stopSelectionAutoscroll()
            return
        }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard let direction = TerminalSelectionAutoscrollDirection(
            locationY: location.y, bounds: bounds
        ) else {
            stopSelectionAutoscroll()
            return
        }

        let lastTopRow = lastScroll.totalRows > lastScroll.viewportRows
            ? lastScroll.totalRows - lastScroll.viewportRows : 0
        let targetRow: UInt64
        switch direction {
        case .towardTop:
            guard lastScroll.topRow > 0 else {
                stopSelectionAutoscroll()
                return
            }
            targetRow = lastScroll.topRow - 1
        case .towardBottom:
            guard lastScroll.topRow < lastTopRow else {
                stopSelectionAutoscroll()
                return
            }
            targetRow = lastScroll.topRow + 1
        }
        guard scrollToRow(UInt(clamping: targetRow)),
              let dragEvent = NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: window.mouseLocationOutsideOfEventStream,
                modifierFlags: selectionAutoscrollModifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
              )
        else {
            stopSelectionAutoscroll()
            return
        }
        super.mouseDragged(with: dragEvent)
    }

    func stopSelectionAutoscroll() {
        selectionAutoscrollTimer?.invalidate()
        selectionAutoscrollTimer = nil
    }

    override func keyDown(with event: NSEvent) {
        finalizePointerSelectionBeforeInput()
        recordPromptInputStart()
        if !hasMarkedText(),
           aiInputEditor.handleKeyDown(event, replay: { [weak self] in self?.keyDown(with: event) }) { return }
        activatePendingPromptSelection(for: event)
        if ([36, 76].contains(Int(event.keyCode)) && !event.modifierFlags.contains(.shift))
            || (event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "c") {
            promptInputStart = nil
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange range: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if !text.isEmpty { finalizePointerSelectionBeforeInput() }
        recordPromptInputStart()
        if !text.isEmpty, aiInputEditor.isBusy || aiInputEditor.hasSelection {
            unmarkText()
            // Ghostty's IME handler needs the current NSEvent, which may be
            // gone by the time cursor movement acknowledges this commit.
            if aiInputEditor.deferWhileBusy({ [weak self] in self?.pasteAIInput(text) })
                || aiInputEditor.replaceSelection(then: { [weak self] in self?.sendText(text) }) { return }
        }
        activatePendingPromptSelection()
        super.insertText(string, replacementRange: range)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        finalizePointerSelectionBeforeInput()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        finalizePointerSelectionBeforeInput()
        recordPromptInputStart()
        if aiInputEditor.deferWhileBusy({ [weak self] in self?.paste(sender) }) { return }
        if aiInputEditor.hasSelection, let text = NSPasteboard.general.string(forType: .string) {
            if text.contains("\n") || text.contains("\r") {
                events?.terminalDidRequestClipboardConfirmation(
                    TerminalClipboardRequest(kind: .unsafePaste, contents: text) { [weak self] approved in
                        guard approved else { return }
                        self?.pasteAIInput(text)
                    }
                )
            } else {
                pasteAIInput(text)
            }
            return
        }
        activatePendingPromptSelection()
        super.paste(sender)
    }

    private func pasteAIInput(_ text: String) {
        if !aiInputEditor.replaceSelection(then: { [weak self] in self?.sendText(text) }) {
            sendText(text)
        }
    }

    private func sendAIInputControl(_ text: String) {
        var remaining = text[...]
        if remaining.hasPrefix("\u{1b}[3~"), let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: "\u{f728}", charactersIgnoringModifiers: "\u{f728}",
            isARepeat: false, keyCode: 117
        ) {
            // Raw PTY writes leave Ghostty's highlight intact. Deliver the first
            // Delete as a key so editing clears it without touching the clipboard.
            super.keyDown(with: event)
            remaining = remaining.dropFirst(4)
        }
        guard !remaining.isEmpty else { return }
        let escaped = remaining.utf8.map { String(format: "\\x%02x", $0) }.joined()
        performBindingAction("text:" + escaped)
    }

    private func aiInputContext(for event: NSEvent? = nil, clampingDrag: Bool = false) -> (
        snapshot: TerminalAIInputSnapshot, caret: TerminalAIInputCaret?
    )? {
        guard !hasMarkedText(), hasEffectiveTerminalFocus,
              lastScroll?.position ?? 1 >= 1,
              let foregroundPid, ZshellAgentKind.recognize(processID: foregroundPid) == .claude,
              let viewport = readViewportTextSnapshot(), viewport.cursorColumn >= 2,
              let cursorPrefix = readViewportText(
                row: viewport.cursorRow, columns: 0..<viewport.cursorColumn,
                preservingTrailingSpaces: true
              )?.text,
              let snapshot = TerminalAIInputSnapshot(
                processID: foregroundPid, columns: viewport.columns, lines: viewport.lines,
                cursorRow: viewport.cursorRow, cursorPrefix: cursorPrefix
              )
        else { return nil }
        guard let event else { return (snapshot, nil) }
        let point = convert(event.locationInWindow, from: nil)
        let row = Int(((bounds.height - point.y - viewport.origin.y) / viewport.cellSize.height).rounded(.down))
        let rawColumn = Int(((point.x - viewport.origin.x) / viewport.cellSize.width).rounded())
        guard row >= 0, row < viewport.lines.count,
              clampingDrag || (rawColumn >= 0 && rawColumn <= viewport.columns)
        else { return (snapshot, nil) }
        let column = min(viewport.columns, max(clampingDrag ? 2 : 0, rawColumn))
        guard let prefix = readViewportText(row: row, columns: 0..<column, preservingTrailingSpaces: true)?.text
        else { return (snapshot, nil) }
        return (snapshot, snapshot.caret(viewportRow: row, prefix: prefix))
    }

    private func finalizePointerSelectionBeforeInput() {
        guard pointerSelectionDragged, let event = inputSelectionMouseEvent else { return }
        // AppKit can deliver input before mouse-up. Release the native selector
        // before editing, then discard the remaining events from that gesture.
        suppressPointerEventsUntilMouseDown = true
        finishPointerSelection(with: event, copyOnSelect: false)
    }

    private func activatePendingPromptSelection(for event: NSEvent? = nil) {
        guard pendingPromptSelectionActivation else { return }
        if let event, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c" { return }
        if let event,
           !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                || [115, 116, 119, 121, 123, 124, 125, 126].contains(Int(event.keyCode)) {
            pendingPromptSelectionActivation = false
            if canEditPromptSelection { performBindingAction("text:\\x1b[27;2;27~") }
            return
        }
        pendingPromptSelectionActivation = false
        if canEditPromptSelection { performBindingAction("text:\\x1e") }
    }

    func recordPromptInputStart() {
        guard promptInputStart == nil, canEditPromptSelection, events?.terminalPromptQueueIsReady == true,
              let snapshot = readViewportTextSnapshot() else { return }
        let top = (lastScroll?.totalRows ?? 0) - min(
            lastScroll?.totalRows ?? 0, lastScroll?.viewportRows ?? 0
        )
        promptInputStart = (top + UInt64(snapshot.cursorRow), snapshot.cursorColumn)
    }

    func resetPromptInputStart() {
        promptInputStart = nil
    }

    private func promptCaret(
        for event: NSEvent, allowZeroClick: Bool = false
    ) -> (row: Int, column: Int)? {
        guard canEditPromptSelection,
              event.clickCount == 1 || (allowZeroClick && event.clickCount == 0),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let start = promptInputStart, let snapshot = readViewportTextSnapshot()
        else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let row = Int(((bounds.height - point.y - snapshot.origin.y) / snapshot.cellSize.height).rounded(.down))
        let column = Int(((point.x - snapshot.origin.x) / snapshot.cellSize.width).rounded())
        let top = (lastScroll?.totalRows ?? 0) - min(
            lastScroll?.totalRows ?? 0, lastScroll?.viewportRows ?? 0
        )
        let lastInputRow = max(
            snapshot.cursorRow,
            snapshot.lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? 0
        )
        guard snapshot.lines.indices.contains(row), column >= 0, column <= snapshot.columns,
              row <= lastInputRow,
              (top + UInt64(row), column) >= (start.row, start.column)
        else { return nil }
        return (row, column)
    }

    private func promptCursorMovement(
        from origin: (row: Int, column: Int), to target: (row: Int, column: Int)
    ) -> String? {
        let forward = (target.row, target.column) > (origin.row, origin.column)
        let start = forward ? origin : target
        let end = forward ? target : origin
        guard let text = readViewportText(
            fromRow: start.row, column: start.column, toRow: end.row, column: end.column
        ) else { return nil }
        let distance = text.unicodeScalars.filter { $0.value != 0x0d }.count
        guard distance <= TerminalAIInputEditor.maxCursorSteps else { return nil }
        return String(repeating: forward ? "\\x1b[C" : "\\x1b[D", count: distance)
    }

    private func focusForInteraction() {
        if window?.firstResponder === self {
            onBecomeFirstResponder?()
        } else {
            window?.makeFirstResponder(self)
        }
    }

    private var canEditPromptSelection: Bool {
        guard supportsInputSelection, events?.terminalPromptSelectionIsReady == true,
              !isMouseCaptured,
              lastScroll?.position ?? 1 >= 1,
              let foregroundPid else { return false }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(foregroundPid, &name, UInt32(name.count)) > 0 else { return false }
        return String(cString: name) == "zsh"
    }

    // MARK: - Context menu

    /// Mouse-reporting applications own an unmodified right-click. Shift keeps
    /// Zshell's menu reachable for selection, and Command preserves its link and
    /// pane actions.
    override func rightMouseDown(with event: NSEvent) {
        focusForInteraction()
        if shouldForwardRightMouse(event) {
            isForwardingRightMouseButton = true
            super.rightMouseDown(with: event)
            return
        }
        isForwardingRightMouseButton = false
        NSMenu.popUpContextMenu(
            contextMenu(linkTarget: linkTarget(for: event)),
            with: event,
            for: self
        )
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isForwardingRightMouseButton else { return }
        isForwardingRightMouseButton = false
        super.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isForwardingRightMouseButton else { return }
        super.rightMouseDragged(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !shouldForwardRightMouse(event) else { return nil }
        focusForInteraction()
        return contextMenu(linkTarget: linkTarget(for: event))
    }

    private func shouldForwardRightMouse(_ event: NSEvent) -> Bool {
        !commandRouting.blocksCommands
            && isMouseCaptured
            && event.modifierFlags.intersection([.shift, .command]).isEmpty
    }

    private func linkTarget(for event: NSEvent) -> TerminalLinkTarget? {
        guard event.modifierFlags.contains(.command) else { return nil }
        let text = contextText(for: event)
        if let hoveredLink, let target = events?.terminalLinkTarget(for: hoveredLink) {
            return target
        }
        return text.flatMap { events?.terminalLinkTarget(for: $0) }
    }

    private func contextMenu(linkTarget: TerminalLinkTarget?) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(contextItem(String(localized: "Copy"), #selector(copy(_:))))
        menu.addItem(contextItem(String(localized: "Paste"), #selector(NSText.paste(_:))))
        menu.addItem(.separator())
        menu.addItem(contextItem(String(localized: "Select All"), #selector(selectAll(_:))))
        menu.addItem(.separator())
        menu.addItem(commandRouting.contextMenuItem())
        menu.addItem(.separator())
        menu.addItem(splitTarget.quickCommandMenuItem())
        if let linkTarget {
            menu.addItem(.separator())
            switch linkTarget {
            case .url(let url):
                for item in splitTarget.browserMenuItems(initialURL: url.absoluteString) {
                    menu.addItem(item)
                }
            case .file(let url):
                for item in splitTarget.fileMenuItems(path: url.path) {
                    menu.addItem(item)
                }
            }
        }
        menu.addItem(.separator())
        for item in splitTarget.menuItems() { menu.addItem(item) }
        return menu
    }

    private func contextItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadFileURLs(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadFileURLs(sender) ? .copy : []
    }

    /// Inserts dropped absolute paths, shell-escaped and space-separated, at
    /// the active prompt exactly as a paste would.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(sender), !urls.isEmpty else { return false }
        focusForInteraction()
        let text = urls.map { Self.shellToken(for: $0.path) }.joined(separator: " ")
        sendText(text + " ")
        return true
    }

    private func canReadFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    private static func shellToken(for path: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")
        if !path.isEmpty, path.allSatisfy({ safe.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Layer-backed progress indicator used for OSC 9;4 reports. It deliberately
/// ignores hit testing so terminal selection and clicks pass through it.
final class ZshellTerminalProgressBarView: NSView {
    private let trackLayer = CALayer()
    private let barLayer = CALayer()
    private let indeterminateAnimationKey = "zshellTerminalProgressIndeterminate"

    private var state: TerminalProgressState = .remove
    private var progress: Int?
    private var lastProgressValue: Int?
    private var reportTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.masksToBounds = true
        trackLayer.isHidden = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(barLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        reportTimer?.invalidate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateForCurrentState(animated: false)
    }

    func applyReport(state: TerminalProgressState, percent: Int?) {
        if case .remove = state {
            clearReport()
            return
        }

        let resolved: Int?
        switch state {
        case .remove:
            resolved = nil
        case .set:
            resolved = percent ?? 0
        case .error:
            resolved = percent ?? lastProgressValue
        case .indeterminate:
            resolved = nil
        case .pause:
            resolved = percent ?? lastProgressValue ?? 100
        }
        let clamped = resolved.map { min(max($0, 0), 100) }
        if let clamped {
            lastProgressValue = clamped
        }

        let displayProgress: Int?
        if case .indeterminate = state {
            displayProgress = nil
        } else {
            displayProgress = clamped
        }
        apply(state: state, progress: displayProgress)
        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(
            withTimeInterval: 15, repeats: false
        ) { [weak self] _ in
            self?.clearReport()
        }
    }

    private func clearReport() {
        reportTimer?.invalidate()
        reportTimer = nil
        lastProgressValue = nil
        apply(state: .remove, progress: nil)
    }

    private func apply(state: TerminalProgressState, progress: Int?) {
        self.state = state
        self.progress = progress

        if case .remove = state {
            isHidden = true
            stopIndeterminateAnimation()
            return
        }

        isHidden = false
        let color: NSColor
        switch state {
        case .error:
            color = .systemRed
        case .pause:
            color = .systemOrange
        default:
            color = .controlAccentColor
        }
        barLayer.backgroundColor = color.cgColor
        trackLayer.backgroundColor = color.withAlphaComponent(0.3).cgColor
        updateForCurrentState(animated: true)
    }

    private func updateForCurrentState(animated: Bool) {
        guard !isHidden else { return }
        trackLayer.frame = bounds
        if let progress {
            updateDeterminate(progress: progress, animated: animated)
        } else {
            updateIndeterminate()
        }
    }

    private func updateDeterminate(progress: Int, animated: Bool) {
        trackLayer.isHidden = true
        stopIndeterminateAnimation()
        let width = bounds.width * CGFloat(progress) / 100
        let target = CGRect(x: 0, y: 0, width: width, height: bounds.height)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut)
            )
        } else {
            CATransaction.setDisableActions(true)
        }
        barLayer.frame = target
        CATransaction.commit()
    }

    private func updateIndeterminate() {
        trackLayer.isHidden = false
        let width = bounds.width * 0.25
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()

        guard width > 0, bounds.width > width else {
            stopIndeterminateAnimation()
            return
        }

        stopIndeterminateAnimation()
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = width / 2
        animation.toValue = bounds.width - width / 2
        animation.duration = 1.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        barLayer.add(animation, forKey: indeterminateAnimationKey)
    }

    private func stopIndeterminateAnimation() {
        barLayer.removeAnimation(forKey: indeterminateAnimationKey)
    }
}

/// Target for pane-split context-menu items, kept separate from terminal menu
/// validation so these actions remain enabled even when there is no selection.
final class SplitMenuTarget: NSObject {
    var onSplit: ((PaneDropEdge) -> Void)?
    var onNewBrowserTab: ((String?) -> Void)?
    var onNewBrowserPane: ((String?) -> Void)?
    var onNewFileTab: ((String) -> Void)?
    var onNewFilePane: ((String) -> Void)?
    var onInsertQuickCommand: ((QuickCommandPreset) -> Void)?
    var onRunQuickCommand: ((QuickCommandPreset) -> Void)?
    var onManageQuickCommands: (() -> Void)?
    private let quickCommandTarget = QuickCommandMenuTarget()

    func browserMenuItems(initialURL: String) -> [NSMenuItem] {
        let tabItem = item(
            String(localized: "New Browser Tab"),
            #selector(newBrowserTab(_:))
        )
        tabItem.representedObject = initialURL
        let paneItem = item(
            String(localized: "New Browser Pane"),
            #selector(newBrowserPane(_:))
        )
        paneItem.representedObject = initialURL
        return [tabItem, paneItem]
    }

    func fileMenuItems(path: String) -> [NSMenuItem] {
        let tabItem = item(
            String(localized: "New File Tab"),
            #selector(newFileTab(_:))
        )
        tabItem.representedObject = path
        let paneItem = item(
            String(localized: "New File Pane"),
            #selector(newFilePane(_:))
        )
        paneItem.representedObject = path
        return [tabItem, paneItem]
    }

    func quickCommandMenuItem() -> NSMenuItem {
        quickCommandTarget.onInsertPreset = onInsertQuickCommand
        quickCommandTarget.onRunPreset = onRunQuickCommand
        quickCommandTarget.onManagePresets = onManageQuickCommands
        let parent = NSMenuItem(
            title: String(localized: "Quick Commands"),
            action: nil,
            keyEquivalent: ""
        )
        let menu = NSMenu(title: parent.title)
        quickCommandTarget.menuItems().forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    func menuItems() -> [NSMenuItem] {
        [
            item(String(localized: "Split Right"), #selector(splitRight)),
            item(String(localized: "Split Left"), #selector(splitLeft)),
            item(String(localized: "Split Up"), #selector(splitUp)),
            item(String(localized: "Split Down"), #selector(splitDown)),
        ]
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func splitRight() { onSplit?(.right) }
    @objc private func splitLeft() { onSplit?(.left) }
    @objc private func splitUp() { onSplit?(.top) }
    @objc private func splitDown() { onSplit?(.bottom) }
    @objc private func newBrowserTab(_ sender: NSMenuItem) {
        onNewBrowserTab?(sender.representedObject as? String)
    }

    @objc private func newBrowserPane(_ sender: NSMenuItem) {
        onNewBrowserPane?(sender.representedObject as? String)
    }

    @objc private func newFileTab(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onNewFileTab?(path)
    }

    @objc private func newFilePane(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onNewFilePane?(path)
    }
}
