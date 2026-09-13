//
//  CommandShortcutRecorder.swift
//  zshell
//

import AppKit
import Carbon.HIToolbox

/// Records an in-app command shortcut: click to arm, then press the chord.
/// Unlike the Quick Terminal recorder there is no live hotkey to suspend, but
/// the flow is the same — Escape cancels, an unusable chord beeps and keeps
/// recording, and a chord the settings layer refuses (a conflict) leaves the
/// old binding in place.
final class CommandShortcutRecorder: NSButton {
    /// Called with the recorded chord; return `false` to reject it, which
    /// beeps and keeps the recorder armed.
    var onShortcutChanged: ((CommandShortcut) -> Bool)?

    private var shortcut: CommandShortcut?
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .small
        font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        target = self
        action = #selector(startRecording)
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
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        guard isRecording else { return true }
        isRecording = false
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
        // Building a chord presses the modifiers one key at a time; those
        // bare-modifier events are ignored rather than rejected so the
        // recording continues until a real key arrives.
        guard
            event.charactersIgnoringModifiers != nil,
            !event.charactersIgnoringModifiers!.isEmpty
        else { return }
        guard let shortcut = CommandShortcut(event: event) else {
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

    func setShortcut(_ shortcut: CommandShortcut) {
        self.shortcut = shortcut
        guard !isRecording else { return }
        updateTitle()
    }

    @objc private func startRecording() {
        window?.makeFirstResponder(self)
    }

    private func updateTitle() {
        title = shortcut?.displayString ?? String(localized: "Shortcut")
    }
}
