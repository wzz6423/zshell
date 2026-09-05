//
//  SettingsTerminalPane.swift
//  zshell
//

import AppKit

/// Everything that shapes a terminal pane: which emulator draws it, how the
/// cursor looks, how keys and history behave, and the global quick terminal.
final class SettingsTerminalPane: SettingsPaneViewController {
    private let backendPicker = SettingsBackendPicker { AppSettings.shared.terminalBackend = $0 }

    private let cursorShapeView = TerminalCursorShapeSettingsView(frame: .zero)
    private let cursorBlinkingView = TerminalCursorBlinkingSettingsView(frame: .zero)

    private let optionAsAltSwitch = SettingsSwitch { AppSettings.shared.macosOptionAsAlt = $0 }
    private let restoreHistorySwitch = SettingsSwitch { AppSettings.shared.restoreTerminalHistory = $0 }

    private let shortcutRecorder = QuickTerminalShortcutRecorder(frame: .zero)

    private let quickTerminalSizeRow = SettingsSliderRow(
        title: String(localized: "Size"),
        range: AppSettings.quickTerminalSizeRange,
        format: .percent,
        step: 0.05,
        showsStepper: false,
        accessibilityLabel: String(localized: "Quick Terminal default size"),
        onChange: { AppSettings.shared.quickTerminalSize = $0 }
    )

    private let quickTerminalOpacityRow = SettingsSliderRow(
        title: String(localized: "Opacity"),
        range: AppSettings.quickTerminalOpacityRange,
        format: .percent,
        step: 0.05,
        showsStepper: false,
        accessibilityLabel: String(localized: "Quick Terminal default opacity"),
        onChange: { AppSettings.shared.quickTerminalOpacity = $0 }
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        cursorShapeView.changeHandler = { AppSettings.shared.cursorShape = $0 }
        cursorBlinkingView.changeHandler = { AppSettings.shared.cursorBlinking = $0 }
        // The overlay owns the live hotkey registration and rejects a shortcut
        // it cannot claim, so the recorder keeps the old one on false.
        shortcutRecorder.onShortcutChanged = { GlobalTerminalOverlay.shared.setHotkey($0) }
    }

    override func makeGroups() -> [NSView] {
        var groups: [NSView] = []

        // Only offer this once there is a real choice. `selectable` omits
        // backends this build cannot create, so every card here takes effect
        // instead of silently producing a dead pane.
        if TerminalBackend.selectable.count > 1 {
            groups.append(SettingsGroup(rows: [
                SettingsRow(
                    title: String(localized: "Backend"),
                    description: String(localized: "Changes apply only to new terminals. Open shells keep their current backend."),
                    control: backendPicker
                ),
            ]))
        }

        groups.append(SettingsGroup(header: String(localized: "Cursor"), rows: [
            SettingsCustomRow(cursorShapeView),
            SettingsCustomRow(cursorBlinkingView),
        ]))

        groups.append(SettingsGroup(header: String(localized: "Behavior"), rows: [
            SettingsRow(
                title: String(localized: "Use Option as Alt/Meta"),
                description: String(localized: "Sends Option-key combinations to terminal programs as Meta shortcuts instead of macOS text input"),
                control: optionAsAltSwitch
            ),
            SettingsRow(
                title: String(localized: "Restore session history on relaunch"),
                description: String(localized: "Reopened terminals show their previous scrollback above a fresh shell"),
                control: restoreHistorySwitch
            ),
        ]))

        groups.append(SettingsGroup(header: String(localized: "Quick Terminal"), rows: [
            SettingsRow(title: String(localized: "Shortcut"), control: shortcutRecorder),
            quickTerminalSizeRow,
            quickTerminalOpacityRow,
        ]))

        return groups
    }

    override func syncFromSettings() {
        backendPicker.select(settings.terminalBackend)
        cursorShapeView.apply(shape: settings.cursorShape)
        cursorBlinkingView.apply(isBlinking: settings.cursorBlinking)
        optionAsAltSwitch.isOn = settings.macosOptionAsAlt
        restoreHistorySwitch.isOn = settings.restoreTerminalHistory
        shortcutRecorder.setShortcut(settings.quickTerminalShortcut)
        quickTerminalSizeRow.setValue(settings.quickTerminalSize)
        quickTerminalOpacityRow.setValue(settings.quickTerminalOpacity)
    }
}
