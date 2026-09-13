//
//  SettingsAutomationPane.swift
//  zshell
//

import AppKit
import Combine

/// Zshell's coordination skill, agent CLI integrations, and local account usage.
final class SettingsAutomationPane: SettingsPaneViewController {
    private let supportView = AgentCLISupportSettingsView(frame: .zero)
    private let usageView = AgentUsageSettingsView(frame: .zero)
    private let usage = AgentUsageModel.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        // The row does its own error reporting and reverts the toggle when an
        // install or uninstall throws, so the handler stays a plain rethrow.
        supportView.changeHandler = { try AppSettings.shared.setAIEnabled($0) }
        observe(
            usage.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    DispatchQueue.main.async { self?.syncUsage() }
                }
        )
        usage.refreshIfNeeded()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        usage.refreshIfNeeded()
    }

    override func makeGroups() -> [NSView] {
        [
            SettingsGroup(rows: [SettingsCustomRow(supportView)]),
            SettingsGroup(
                header: String(localized: "Account Usage"),
                rows: [SettingsCustomRow(usageView)]
            ),
        ]
    }

    override func syncFromSettings() {
        supportView.apply(isEnabled: settings.aiEnabled)
        syncUsage()
    }

    private func syncUsage() {
        usageView.apply(claude: usage.claude, codex: usage.codex)
    }
}
