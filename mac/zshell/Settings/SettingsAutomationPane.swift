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
    private let resumeConversationsSwitch = SettingsSwitch {
        AppSettings.shared.resumeAgentConversations = $0
    }
    private let notifyAttentionSwitch = SettingsSwitch { AppSettings.shared.notifyOnAgentAttention = $0 }
    private let notifyCompletionSwitch = SettingsSwitch { AppSettings.shared.notifyOnAgentCompletion = $0 }
    private lazy var integrationGroup = SettingsGroup(rows: [
        SettingsCustomRow(supportView),
        SettingsRow(title: String(localized: "Resume agent conversations"), control: resumeConversationsSwitch),
        SettingsButtonRow(title: String(localized: "Agent Conversation History")) {
            guard let manager = TerminalManager.activeWindowManager else { return }
            AgentConversationHistoryController.shared.show(for: manager, filter: .all)
        },
    ])
    private lazy var notificationGroup = SettingsGroup(header: String(localized: "Notifications"), rows: [
        SettingsRow(title: String(localized: "Notify when agents need attention"), control: notifyAttentionSwitch),
        SettingsRow(title: String(localized: "Notify when agents finish"), control: notifyCompletionSwitch),
    ])
    private lazy var usageGroup = SettingsGroup(
        header: String(localized: "Account Usage"),
        rows: [SettingsCustomRow(usageView)]
    )

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
        [integrationGroup, notificationGroup, usageGroup]
    }

    override func syncFromSettings() {
        let visibility = SettingsVisibility.current
        supportView.apply(isEnabled: settings.aiEnabled)
        resumeConversationsSwitch.isOn = settings.resumeAgentConversations
        integrationGroup.setRowHidden(!visibility.aiEnabled, at: 1)
        notifyAttentionSwitch.isOn = settings.notifyOnAgentAttention
        notifyCompletionSwitch.isOn = settings.notifyOnAgentCompletion
        notificationGroup.isHidden = !visibility.aiEnabled
        syncUsage()
    }

    private func syncUsage() {
        usageView.apply(claude: usage.claude, codex: usage.codex)
        usageGroup.isHidden = !usageView.hasVisibleUsage
    }
}
