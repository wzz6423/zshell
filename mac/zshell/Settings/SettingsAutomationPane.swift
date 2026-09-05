//
//  SettingsAutomationPane.swift
//  zshell
//

import AppKit

/// Zshell's coordination skill and the agent CLI integrations it installs.
final class SettingsAutomationPane: SettingsPaneViewController {
    private let supportView = AgentCLISupportSettingsView(frame: .zero)

    override func viewDidLoad() {
        super.viewDidLoad()
        // The row does its own error reporting and reverts the toggle when an
        // install or uninstall throws, so the handler stays a plain rethrow.
        supportView.changeHandler = { try AppSettings.shared.setAIEnabled($0) }
    }

    override func makeGroups() -> [NSView] {
        [SettingsGroup(rows: [SettingsCustomRow(supportView)])]
    }

    override func syncFromSettings() {
        supportView.apply(isEnabled: settings.aiEnabled)
    }
}
