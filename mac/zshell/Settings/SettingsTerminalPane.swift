//
//  SettingsTerminalPane.swift
//  zshell
//

import AppKit

/// Startup, input, history, notifications, and the global quick terminal.
final class SettingsTerminalPane: SettingsPaneViewController {
    private let startupView = TerminalStartupSettingsView { program, arguments in
        AppSettings.shared.terminalStartupProgram = program
        AppSettings.shared.terminalStartupArguments = arguments
    }
    private let backendPicker = SettingsBackendPicker { AppSettings.shared.terminalBackend = $0 }

    private let automaticProfilesSwitch = SettingsSwitch { AppSettings.shared.automaticallyApplyTerminalProfiles = $0 }
    private let commandHistorySwitch = SettingsSwitch { AppSettings.shared.commandHistoryEnabled = $0 }
    private let textHintsSwitch = SettingsSwitch { AppSettings.shared.terminalTextHints = $0 }
    private let quickTerminalSwitch = SettingsSwitch { AppSettings.shared.quickTerminalEnabled = $0 }
    private let optionAsAltSwitch = SettingsSwitch { AppSettings.shared.macosOptionAsAlt = $0 }
    private let vimCommandHintsSwitch = SettingsSwitch { AppSettings.shared.vimCommandHints = $0 }
    private let shellCompletionsSwitch = SettingsSwitch { AppSettings.shared.shellCompletions = $0 }
    private let terminalBellSwitch = SettingsSwitch { AppSettings.shared.terminalBell = $0 }
    private let shiftEnterNewlineSwitch = SettingsSwitch { AppSettings.shared.shiftEnterNewline = $0 }
    private let restoreHistorySwitch = SettingsSwitch { AppSettings.shared.restoreTerminalHistory = $0 }
    private let preserveSessionsSwitch = SettingsSwitch { AppSettings.shared.preserveTerminalSessions = $0 }
    private let copyOnSelectSwitch = SettingsSwitch { AppSettings.shared.copyOnSelect = $0 }
    private let focusFollowsMouseSwitch = SettingsSwitch { AppSettings.shared.focusFollowsMouse = $0 }
    private let notifyOnErrorSwitch = SettingsSwitch { AppSettings.shared.notifyOnError = $0 }
    private let notifyFinishPopup = SettingsPopUpButton<Int>(
        items: SettingsTerminalPane.notifyFinishItems,
        onChange: { AppSettings.shared.notifyFinishSeconds = $0 }
    )

    private let shortcutRecorder = QuickTerminalShortcutRecorder(frame: .zero)
    private let quickTerminalModePopup = SettingsPopUpButton<QuickTerminalMode>(
        items: QuickTerminalMode.allCases.map { .value($0.title, $0) },
        onChange: { AppSettings.shared.quickTerminalMode = $0 }
    )

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

    private lazy var quickTerminalGroup = SettingsGroup(header: String(localized: "Quick Terminal"), rows: [
        SettingsRow(title: String(localized: "Enable Quick Terminal"), control: quickTerminalSwitch),
        SettingsRow(title: String(localized: "Session behavior"), description: QuickTerminalMode.explanation,
                    control: quickTerminalModePopup),
        SettingsRow(title: String(localized: "Shortcut"), control: shortcutRecorder),
        quickTerminalSizeRow,
        quickTerminalOpacityRow,
    ])

    override func viewDidLoad() {
        super.viewDidLoad()
        // The overlay owns the live hotkey registration and rejects a shortcut
        // it cannot claim, so the recorder keeps the old one on false.
        shortcutRecorder.onShortcutChanged = { GlobalTerminalOverlay.shared.setHotkey($0) }
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

        startupRows.append(SettingsRow(
            title: String(localized: "Keep sessions running after quitting"),
            description: String(localized: "New terminals keep shells, agents, and servers running when Zshell quits. Closing a pane ends its tasks. Turn this off before quitting to end all sessions."),
            control: preserveSessionsSwitch
        ))
        startupRows.append(SettingsButtonRow(title: String(localized: "Workspace Templates…")) {
            guard let manager = TerminalManager.activeWindowManager else { return }
            WorkspaceTemplateController.shared.show(for: manager)
        })

        var groups: [NSView] = [SettingsGroup(rows: startupRows)]
        groups.append(SettingsGroup(header: String(localized: "Terminal Profiles"), rows: [
            SettingsRow(title: String(localized: "Apply terminal profiles automatically"), control: automaticProfilesSwitch),
            SettingsButtonRow(title: String(localized: "Manage Terminal Profiles…")) { [weak self] in
                TerminalProfileEditor.show(relativeTo: self?.view.window)
            },
        ]))
        groups.append(SettingsGroup(header: String(localized: "Input"), rows: [
            SettingsRow(
                title: String(localized: "Shell completions"),
                control: shellCompletionsSwitch
            ),
            SettingsRow(title: String(localized: "Show terminal text hints"), control: textHintsSwitch),
            SettingsRow(
                title: String(localized: "Vim command hints"),
                control: vimCommandHintsSwitch
            ),
            SettingsRow(
                title: String(localized: "Use Option as Alt/Meta"),
                control: optionAsAltSwitch
            ),
            SettingsRow(
                title: String(localized: "Shift+Enter inserts a newline"),
                control: shiftEnterNewlineSwitch
            ),
            SettingsRow(
                title: String(localized: "Copy on select"),
                control: copyOnSelectSwitch
            ),
            SettingsRow(
                title: String(localized: "Focus follows mouse"),
                control: focusFollowsMouseSwitch
            ),
        ]))

        groups.append(SettingsGroup(header: String(localized: "History"), rows: [
            SettingsRow(title: String(localized: "Record command history"), control: commandHistorySwitch),
            SettingsRow(
                title: String(localized: "Restore session history on relaunch"),
                description: String(localized: "Reopened terminals show their previous scrollback above a fresh shell"),
                control: restoreHistorySwitch
            ),
            SettingsButtonRow(title: String(localized: "Command History…")) {
                guard let manager = TerminalManager.activeWindowManager else { return }
                TerminalCommandHistoryController.shared.show(for: manager)
            },
        ]))

        let notificationScope = NSTextField(wrappingLabelWithString: String(localized: "Changes apply to new zsh terminals."))
        notificationScope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notificationScope.textColor = .secondaryLabelColor
        notificationScope.maximumNumberOfLines = 0
        groups.append(SettingsGroup(header: String(localized: "Notifications"), rows: [
            SettingsRow(
                title: String(localized: "Long-running commands"),
                control: notifyFinishPopup
            ),
            SettingsRow(
                title: String(localized: "Failed commands"),
                control: notifyOnErrorSwitch
            ),
            SettingsCustomRow(notificationScope),
            SettingsRow(title: String(localized: "Terminal bell"), control: terminalBellSwitch),
            SettingsButtonRow(title: String(localized: "Notification History…")) {
                TerminalNotificationCenterController.shared.show()
            },
        ]))
        groups.append(quickTerminalGroup)

        return groups
    }

    override func syncFromSettings() {
        let visibility = SettingsVisibility.current
        startupView.apply(
            program: settings.terminalStartupProgram,
            arguments: settings.terminalStartupArguments
        )
        backendPicker.select(settings.terminalBackend)
        automaticProfilesSwitch.isOn = settings.automaticallyApplyTerminalProfiles
        commandHistorySwitch.isOn = settings.commandHistoryEnabled
        textHintsSwitch.isOn = settings.terminalTextHints
        quickTerminalSwitch.isOn = settings.quickTerminalEnabled
        for index in 1...4 { quickTerminalGroup.setRowHidden(!visibility.quickTerminalEnabled, at: index) }
        optionAsAltSwitch.isOn = settings.macosOptionAsAlt
        vimCommandHintsSwitch.isOn = settings.vimCommandHints
        shellCompletionsSwitch.isOn = settings.shellCompletions
        terminalBellSwitch.isOn = settings.terminalBell
        shiftEnterNewlineSwitch.isOn = settings.shiftEnterNewline
        restoreHistorySwitch.isOn = settings.restoreTerminalHistory
        preserveSessionsSwitch.isOn = settings.preserveTerminalSessions
        copyOnSelectSwitch.isOn = settings.copyOnSelect
        focusFollowsMouseSwitch.isOn = settings.focusFollowsMouse
        notifyFinishPopup.select(settings.notifyFinishSeconds)
        notifyOnErrorSwitch.isOn = settings.notifyOnError
        shortcutRecorder.setShortcut(settings.quickTerminalShortcut)
        quickTerminalModePopup.select(settings.quickTerminalMode)
        quickTerminalSizeRow.setValue(settings.quickTerminalSize)
        quickTerminalOpacityRow.setValue(settings.quickTerminalOpacity)
    }
}
