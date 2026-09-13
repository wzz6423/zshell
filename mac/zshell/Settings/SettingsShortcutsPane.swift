//
//  SettingsShortcutsPane.swift
//  zshell
//

import AppKit

/// Remaps the menu shortcuts of the core commands. Each row records a new
/// chord; conflicts are refused inline with the command that holds the
/// binding, and a button restores every shipped default at once.
final class SettingsShortcutsPane: SettingsPaneViewController {
    private var recorders: [AppCommand: CommandShortcutRecorder] = [:]

    private let conflictLabel = NSTextField(wrappingLabelWithString: "")
    private var conflictRowIndex = 0
    private var shortcutsGroup: SettingsGroup?

    private lazy var resetRow = SettingsButtonRow(
        title: String(localized: "Restore Default Shortcuts")
    ) { [weak self] in
        self?.settings.resetCommandShortcuts()
        self?.conflictLabel.stringValue = ""
    }

    override func makeGroups() -> [NSView] {
        let rows: [NSView] = AppCommand.allCases.map { command in
            let recorder = CommandShortcutRecorder(frame: .zero)
            recorder.setAccessibilityLabel(command.title)
            recorder.onShortcutChanged = { [weak self] shortcut in
                self?.apply(shortcut, to: command) ?? false
            }
            recorders[command] = recorder
            return SettingsRow(title: command.title, control: recorder)
        }

        conflictLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        conflictLabel.textColor = .systemRed
        let conflictRow = SettingsStackRow(views: [conflictLabel])
        conflictRowIndex = rows.count

        let group = SettingsGroup(
            header: String(localized: "Shortcuts"),
            rows: rows + [conflictRow]
        )
        group.setRowHidden(true, at: conflictRowIndex)
        shortcutsGroup = group

        // The reset button stands on its own rather than inside a group: it is
        // an action, not a setting, and hairlines around a lone button read as
        // an empty group.
        return [group, resetRow]
    }

    override func syncFromSettings() {
        for command in AppCommand.allCases {
            recorders[command]?.setShortcut(settings.commandShortcut(for: command))
        }
        resetRow.button.isEnabled = !settings.commandShortcuts.isEmpty
    }

    private func apply(_ shortcut: CommandShortcut, to command: AppCommand) -> Bool {
        guard let conflict = settings.setCommandShortcut(shortcut, for: command) else {
            conflictLabel.stringValue = ""
            shortcutsGroup?.setRowHidden(true, at: conflictRowIndex)
            return true
        }
        conflictLabel.stringValue = Self.conflictDescription(for: conflict)
        shortcutsGroup?.setRowHidden(false, at: conflictRowIndex)
        return false
    }

    private static func conflictDescription(
        for conflict: AppSettings.CommandShortcutConflict
    ) -> String {
        switch conflict {
        case .command(let command):
            String(
                localized: "Already used by “\(command.title)”",
                comment: "A recorded shortcut is taken by another command. The placeholder is that command's name."
            )
        case .quickTerminal:
            String(localized: "Already used by the Quick Terminal")
        }
    }
}
