//
//  SettingsTerminalPane.swift
//  zshell
//

import AppKit
import Combine

/// Everything that shapes a terminal pane: which emulator draws it, how the
/// cursor looks, how keys and history behave, and the global quick terminal.
final class SettingsTerminalPane: SettingsPaneViewController {
    private let startupView = TerminalStartupSettingsView { program, arguments in
        AppSettings.shared.terminalStartupProgram = program
        AppSettings.shared.terminalStartupArguments = arguments
    }
    private let backendPicker = SettingsBackendPicker { AppSettings.shared.terminalBackend = $0 }

    private let cursorShapeView = TerminalCursorShapeSettingsView(frame: .zero)
    private let cursorBlinkingView = TerminalCursorBlinkingSettingsView(frame: .zero)

    private let optionAsAltSwitch = SettingsSwitch { AppSettings.shared.macosOptionAsAlt = $0 }
    private let terminalBellSwitch = SettingsSwitch { AppSettings.shared.terminalBell = $0 }
    private let shiftEnterNewlineSwitch = SettingsSwitch { AppSettings.shared.shiftEnterNewline = $0 }
    private let restoreHistorySwitch = SettingsSwitch { AppSettings.shared.restoreTerminalHistory = $0 }
    private let copyOnSelectSwitch = SettingsSwitch { AppSettings.shared.copyOnSelect = $0 }
    private let terminalBackgroundBlurSwitch = SettingsSwitch {
        AppSettings.shared.terminalBackgroundBlur = $0
    }

    private let terminalBackgroundOpacityRow = SettingsSliderRow(
        title: String(localized: "Opacity"),
        range: AppSettings.terminalBackgroundOpacityRange,
        format: .percent,
        step: 0.05,
        showsStepper: false,
        accessibilityLabel: String(localized: "Terminal background opacity"),
        onChange: { AppSettings.shared.terminalBackgroundOpacity = $0 }
    )

    private let notifyOnErrorSwitch = SettingsSwitch { AppSettings.shared.notifyOnError = $0 }
    private let notifyFinishPopup = SettingsPopUpButton<Int>(
        items: SettingsTerminalPane.notifyFinishItems,
        onChange: { AppSettings.shared.notifyFinishSeconds = $0 }
    )

    private let shortcutRecorder = QuickTerminalShortcutRecorder(frame: .zero)

    /// Popup entries for `terminal.notify-finish-seconds`: off, then the
    /// offered minimum runtimes. One interpolated format covers every step,
    /// the way the font-size readout does.
    private static var notifyFinishItems: [SettingsPopUpItem<Int>] {
        AppSettings.notifyFinishSecondChoices.map { seconds in
            .value(
                seconds == 0
                    ? String(localized: "Off")
                    : String(localized: "\(seconds)s", comment: "A runtime threshold, in seconds, for command-finish notifications; the placeholder is that number."),
                seconds
            )
        }
    }

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
        observe(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncFromSettings() }
        )
    }

    override func makeGroups() -> [NSView] {
        var startupRows: [NSView] = [
            SettingsRow(
                title: String(localized: "Startup"),
                description: String(localized: "Changes apply only to new terminals. Open terminals keep their current process."),
                control: startupView
            ),
        ]

        // Only offer this once there is a real choice. `selectable` omits
        // backends this build cannot create, so every card here takes effect
        // instead of silently producing a dead pane.
        if TerminalBackend.selectable.count > 1 {
            startupRows.append(
                SettingsRow(
                    title: String(localized: "Backend"),
                    description: String(localized: "Changes apply only to new terminals. Open shells keep their current backend."),
                    control: backendPicker
                )
            )
        }

        var groups: [NSView] = [SettingsGroup(rows: startupRows)]
        groups.append(SettingsGroup(header: String(localized: "Cursor"), rows: [
            SettingsCustomRow(cursorShapeView),
            SettingsCustomRow(cursorBlinkingView),
        ]))

        groups.append(SettingsGroup(header: String(localized: "Background"), rows: [
            terminalBackgroundOpacityRow,
            SettingsRow(
                title: String(localized: "Blur behind window"),
                description: String(localized: "Adds frosted material behind translucent terminal backgrounds"),
                control: terminalBackgroundBlurSwitch
            ),
        ]))

        groups.append(SettingsGroup(header: String(localized: "Behavior"), rows: [
            SettingsRow(
                title: String(localized: "Use Option as Alt/Meta"),
                description: String(localized: "Sends Option-key combinations to terminal programs as Meta shortcuts instead of macOS text input"),
                control: optionAsAltSwitch
            ),
            SettingsRow(
                title: String(localized: "Terminal bell"),
                description: String(localized: "Plays the alert sound and uses macOS visual alerts when terminal programs ring the bell"),
                control: terminalBellSwitch
            ),
            SettingsRow(
                title: String(localized: "Shift+Enter inserts a newline"),
                description: String(localized: "Lets coding agents insert a new line with Shift+Enter while Enter still submits the prompt"),
                control: shiftEnterNewlineSwitch
            ),
            SettingsRow(
                title: String(localized: "Restore session history on relaunch"),
                description: String(localized: "Reopened terminals show their previous scrollback above a fresh shell"),
                control: restoreHistorySwitch
            ),
            SettingsRow(
                title: String(localized: "Copy on select"),
                description: String(localized: "Copies selected terminal text to the clipboard when you finish dragging"),
                control: copyOnSelectSwitch
            ),
        ]))

        groups.append(SettingsGroup(header: String(localized: "Command Notifications"), rows: [
            SettingsRow(
                title: String(localized: "Long-running commands"),
                description: String(localized: "Notify when a command runs at least this long and then finishes. Changes apply to zsh terminals opened afterwards."),
                control: notifyFinishPopup
            ),
            SettingsRow(
                title: String(localized: "Failed commands"),
                description: String(localized: "Notify when a command exits with a failure, no matter how briefly it ran. Changes apply to zsh terminals opened afterwards."),
                control: notifyOnErrorSwitch
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
        startupView.apply(
            program: settings.terminalStartupProgram,
            arguments: settings.terminalStartupArguments
        )
        backendPicker.select(settings.terminalBackend)
        cursorShapeView.apply(shape: settings.cursorShape)
        cursorBlinkingView.apply(isBlinking: settings.cursorBlinking)
        optionAsAltSwitch.isOn = settings.macosOptionAsAlt
        terminalBellSwitch.isOn = settings.terminalBell
        shiftEnterNewlineSwitch.isOn = settings.shiftEnterNewline
        restoreHistorySwitch.isOn = settings.restoreTerminalHistory
        copyOnSelectSwitch.isOn = settings.copyOnSelect
        terminalBackgroundOpacityRow.setValue(settings.terminalBackgroundOpacity)
        terminalBackgroundBlurSwitch.isOn = settings.terminalBackgroundBlur
        terminalBackgroundBlurSwitch.isEnabled = settings.terminalBackgroundOpacity < 1
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        notifyFinishPopup.select(settings.notifyFinishSeconds)
        notifyOnErrorSwitch.isOn = settings.notifyOnError
        shortcutRecorder.setShortcut(settings.quickTerminalShortcut)
        quickTerminalSizeRow.setValue(settings.quickTerminalSize)
        quickTerminalOpacityRow.setValue(settings.quickTerminalOpacity)
    }
}
