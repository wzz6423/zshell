//
//  QuickTerminalShortcutRecorder.swift
//  zshell
//

import AppKit
import Carbon.HIToolbox

/// Records the Quick Terminal's global hotkey: click to arm, then press the
/// chord. Recording suspends the live hotkey so the chord reaches this button
/// instead of summoning the overlay.
final class QuickTerminalShortcutRecorder: NSButton {
    var onShortcutChanged: ((QuickTerminalShortcut) -> Bool)?

    private var shortcut = AppSettings.defaultQuickTerminalShortcut
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .small
        font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        target = self
        action = #selector(startRecording)
        setAccessibilityLabel(String(localized: "Quick Terminal shortcut"))
        toolTip = String(localized: "Quick Terminal shortcut")
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        guard !isRecording else { return true }
        isRecording = true
        title = String(localized: "Press shortcut")
        GlobalTerminalOverlay.shared.beginHotkeyRecording()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        guard isRecording else { return true }
        isRecording = false
        GlobalTerminalOverlay.shared.endHotkeyRecording()
        updateTitle()
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }
        guard let shortcut = QuickTerminalShortcut(event: event) else {
            NSSound.beep()
            return
        }
        guard onShortcutChanged?(shortcut) ?? true else {
            NSSound.beep()
            return
        }
        self.shortcut = shortcut
        window?.makeFirstResponder(nil)
    }

    func setShortcut(_ shortcut: QuickTerminalShortcut) {
        self.shortcut = shortcut
        guard !isRecording else { return }
        updateTitle()
    }

    @objc private func startRecording() {
        window?.makeFirstResponder(self)
    }

    private func updateTitle() {
        title = shortcut.displayString
    }
}
