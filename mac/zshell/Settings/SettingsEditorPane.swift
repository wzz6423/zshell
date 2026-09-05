//
//  SettingsEditorPane.swift
//  zshell
//

import AppKit

/// The file editor's text behavior.
final class SettingsEditorPane: SettingsPaneViewController {
    private let wrapLinesSwitch = SettingsSwitch { AppSettings.shared.wrapLines = $0 }

    override func makeGroups() -> [NSView] {
        [
            SettingsGroup(rows: [
                SettingsRow(
                    title: String(localized: "Wrap lines to editor width"),
                    control: wrapLinesSwitch
                ),
            ]),
        ]
    }

    override func syncFromSettings() {
        wrapLinesSwitch.isOn = settings.wrapLines
    }
}
