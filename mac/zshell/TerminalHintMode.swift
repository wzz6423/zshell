import AppKit

@MainActor
final class TerminalHintMode: NSObject {
    enum Action { case copy, open }
    private(set) var isPresented = false
    private(set) var action: Action = .copy
    private(set) var prefix = ""
    private(set) var hints: [TerminalHint] = []
    private(set) var snapshot: TerminalViewportSnapshot?
    private weak var surface: (any TerminalBackendSurface)?
    private let pasteboard: NSPasteboard
    private lazy var overlay = TerminalHintOverlay(mode: self)
    private var refreshTimer: Timer?
    private var inputMonitor: Any?
    private var suppressedKeyUps: Set<UInt16> = []
    private var scanGeneration = 0
    private var scanning = false
    private var statusOverride: String?

    init(surface: any TerminalBackendSurface, pasteboard: NSPasteboard = .general) {
        self.surface = surface
        self.pasteboard = pasteboard
        super.init()
    }

    deinit {
        refreshTimer?.invalidate()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    var matchingHints: [TerminalHint] { hints.filter { $0.label.hasPrefix(prefix) } }

    static func isPresented(in window: NSWindow?) -> Bool {
        window?.firstResponder is TerminalHintOverlay
    }

    func consumesKeyDown(_ event: NSEvent) -> Bool {
        if isPresented { handleKeyDown(event); return true }
        if !event.isARepeat {
            suppressedKeyUps.remove(event.keyCode)
            removeInputMonitorIfIdle()
        }
        return event.isARepeat && suppressedKeyUps.contains(event.keyCode)
    }

    func present(action: Action, triggeredBy event: NSEvent? = nil) {
        guard AppSettings.shared.terminalTextHints, let surface, let window = surface.window else { return }
        dismiss(restoringFocus: false)
        self.action = action
        prefix = ""
        hints = []
        snapshot = nil
        statusOverride = nil
        isPresented = true
        if let event { suppressedKeyUps.insert(event.keyCode) }
        surface.inputContext?.discardMarkedText()
        (surface as? any NSTextInputClient)?.unmarkText()
        overlay.frame = surface.bounds
        surface.addSubview(overlay, positioned: .above, relativeTo: nil)
        window.makeFirstResponder(overlay)
        installInputMonitor()
        NotificationCenter.default.addObserver(self, selector: #selector(localize), name: AppLocalization.didChange, object: nil)
        refreshSnapshot()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSnapshot() }
        }
    }

    func dismiss(restoringFocus: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        scanGeneration &+= 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        NotificationCenter.default.removeObserver(self)
        let window = overlay.window
        if window?.firstResponder === overlay {
            window?.makeFirstResponder(restoringFocus ? surface : nil)
        }
        overlay.removeFromSuperview()
        hints = []
        snapshot = nil
        prefix = ""
        removeInputMonitorIfIdle()
    }

    @objc private func localize() { overlay.needsDisplay = true }

    func refreshSnapshot() {
        guard AppSettings.shared.terminalTextHints else {
            dismiss()
            return
        }
        guard isPresented, let surface, surface.window != nil,
              surface.window?.firstResponder === overlay else {
            dismiss(restoringFocus: false)
            return
        }
        guard let fresh = surface.readVisibleSnapshot() else {
            scanGeneration &+= 1
            scanning = false
            snapshot = nil
            hints = []
            statusOverride = String(localized: "Terminal hints are unavailable at this size.")
            overlay.needsDisplay = true
            return
        }
        guard fresh != snapshot else { return }
        scanGeneration &+= 1
        let generation = scanGeneration
        snapshot = fresh
        prefix = ""
        hints = []
        statusOverride = nil
        scanning = true
        overlay.needsDisplay = true
        // The owned viewport is the only terminal data crossing this queue.
        // Regular expressions never lock or traverse the PTY's scrollback.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let matches = TerminalHintMatcher.matches(in: fresh)
            DispatchQueue.main.async { [weak self] in
                guard let self, isPresented, scanGeneration == generation else { return }
                hints = matches
                scanning = false
                overlay.needsDisplay = true
                NSAccessibility.post(element: overlay, notification: .layoutChanged)
            }
        }
    }

    func handleKeyDown(_ event: NSEvent) {
        guard isPresented else { return }
        suppressedKeyUps.insert(event.keyCode)
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 || (flags == .control && event.charactersIgnoringModifiers == "c") {
            dismiss()
            return
        }
        if surface?.readVisibleSnapshot() != snapshot { refreshSnapshot(); return }
        if event.keyCode == 48 {
            action = action == .copy ? .open : .copy
            statusOverride = nil
        } else if event.keyCode == 51 || event.keyCode == 117 {
            if !prefix.isEmpty { prefix.removeLast() }
            statusOverride = nil
        } else if flags == .control, event.charactersIgnoringModifiers == "u" {
            prefix = ""
            statusOverride = nil
        } else if event.keyCode == 36 || event.keyCode == 76 {
            if matchingHints.count == 1 { select(matchingHints[0]) }
        } else if flags.isSubset(of: [.shift]),
                  let letter = event.charactersIgnoringModifiers?.lowercased(),
                  letter.count == 1, TerminalHintMatcher.alphabet.contains(letter) {
            let next = prefix + letter
            guard hints.contains(where: { $0.label.hasPrefix(next) }) else { return }
            prefix = next
            statusOverride = nil
            if let hint = hints.first(where: { $0.label == next }) { select(hint) }
        }
        overlay.needsDisplay = true
    }

    func handleKeyUp(_ event: NSEvent) -> Bool {
        let suppressed = suppressedKeyUps.remove(event.keyCode) != nil
        removeInputMonitorIfIdle()
        return isPresented || suppressed
    }

    private func select(_ hint: TerminalHint) {
        guard let surface, let fresh = surface.readVisibleSnapshot(), fresh == snapshot else {
            refreshSnapshot()
            return
        }
        if action == .open {
            guard surface.events?.terminalLinkTarget(for: hint.value) != nil else {
                prefix = ""
                statusOverride = String(localized: "This value cannot be opened. Press Tab to copy it.")
                return
            }
            dismiss()
            surface.events?.terminalDidRequestOpenURL(hint.value)
        } else {
            pasteboard.clearContents()
            pasteboard.setString(hint.value, forType: .string)
            dismiss()
        }
    }

    var status: String {
        if let statusOverride { return statusOverride }
        if scanning { return String(localized: "Finding visible terminal hints…") }
        if hints.isEmpty { return String(localized: "No terminal hints on this screen. Esc cancels.") }
        return action == .copy
            ? String(localized: "Type a label to copy. Tab opens. Esc cancels.")
            : String(localized: "Type a label to open. Tab copies. Esc cancels.")
    }

    private func installInputMonitor() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            assumeMainActor { [weak self] in
                guard let self, (event.window ?? NSApp.keyWindow) === surface?.window else { return event }
                if event.type == .keyUp { return handleKeyUp(event) ? nil : event }
                guard isPresented else { return consumesKeyDown(event) ? nil : event }
                guard overlay.window?.firstResponder === overlay else {
                    dismiss(restoringFocus: false)
                    return event
                }
                handleKeyDown(event)
                return nil
            }
        }
    }

    private func removeInputMonitorIfIdle() {
        guard !isPresented, suppressedKeyUps.isEmpty, let inputMonitor else { return }
        NSEvent.removeMonitor(inputMonitor)
        self.inputMonitor = nil
    }
}

@MainActor
private final class TerminalHintOverlay: NSView {
    private weak var mode: TerminalHintMode?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(mode: TerminalHintMode) {
        self.mode = mode
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func keyDown(with event: NSEvent) { mode?.handleKeyDown(event) }
    override func keyUp(with event: NSEvent) { _ = mode?.handleKeyUp(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        mode?.handleKeyDown(event)
        return true
    }
    override func mouseDown(with event: NSEvent) { mode?.dismiss() }
    override func scrollWheel(with event: NSEvent) {}
    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self, window?.firstResponder !== self else { return }
            mode?.dismiss(restoringFocus: false)
        }
        return super.resignFirstResponder()
    }
    override func layout() {
        super.layout()
        mode?.refreshSnapshot()
    }
    override func accessibilityLabel() -> String? { String(localized: "Terminal Hints") }
    override func accessibilityHelp() -> String? { mode?.status }
    override func accessibilityValue() -> Any? {
        mode?.matchingHints.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let mode else { return }
        NSColor.black.withAlphaComponent(0.18).setFill()
        dirtyRect.fill()
        let font = NSFont.monospacedSystemFont(ofSize: min(max(mode.snapshot?.cellSize.height ?? 14, 12), 18) * 0.8, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textBackgroundColor]
        if let snapshot = mode.snapshot {
            for hint in mode.matchingHints {
                for fragment in hint.fragments {
                    NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                    snapshot.rect(row: fragment.row, columns: fragment.columns).fill()
                }
                guard let first = hint.fragments.first else { continue }
                let cell = snapshot.rect(row: first.row, columns: first.columns)
                let label = hint.label.uppercased() as NSString
                let size = label.size(withAttributes: attributes)
                let width = max(size.width + 6, CGFloat(hint.label.count) * snapshot.cellSize.width)
                let rect = CGRect(x: min(max(cell.minX, 0), max(0, bounds.width - width)), y: cell.minY,
                                  width: width, height: max(cell.height, size.height + 2))
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        }
        let status = mode.status as NSString
        let statusAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let height: CGFloat = 40
        let statusRect = CGRect(x: 6, y: max(0, bounds.height - height - 6), width: max(0, bounds.width - 12), height: height)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: statusRect, xRadius: 5, yRadius: 5).fill()
        status.draw(with: statusRect.insetBy(dx: 8, dy: 5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: statusAttributes)
    }
}
