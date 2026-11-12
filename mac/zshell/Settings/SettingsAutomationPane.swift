//
//  SettingsAutomationPane.swift
//  zshell
//

import AppKit

/// Zshell's coordination skill and agent CLI integrations.
final class SettingsAutomationPane: SettingsPaneViewController {
    private let supportView = AgentCLISupportSettingsView(frame: .zero)
    private let resumeConversationsSwitch = SettingsSwitch {
        AppSettings.shared.resumeAgentConversations = $0
    }
    private let notifyAttentionSwitch = SettingsSwitch { AppSettings.shared.notifyOnAgentAttention = $0 }
    private let notifyCompletionSwitch = SettingsSwitch { AppSettings.shared.notifyOnAgentCompletion = $0 }
    private let customRulesSwitch = SettingsSwitch { AppSettings.shared.customAgentRecognitionRules = $0 }
    private let screenInferenceSwitch = SettingsSwitch { AppSettings.shared.agentScreenInference = $0 }
    private lazy var recognitionGroup = SettingsGroup(header: String(localized: "Agent Recognition"), rows: [
        SettingsRow(title: String(localized: "Use custom recognition rules"), control: customRulesSwitch, symbolName: "slider.horizontal.3"),
        SettingsRow(title: String(localized: "Infer agent state from the screen"),
                    description: String(localized: "Uses two live footer samples. Native lifecycle events and program reports take priority."),
                    control: screenInferenceSwitch, symbolName: "text.viewfinder"),
        SettingsButtonRow(title: String(localized: "Manage Agent Rules…")) { AgentRecognitionRulesController.shared.show() },
    ])
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

    override func viewDidLoad() {
        super.viewDidLoad()
        // The row does its own error reporting and reverts the toggle when an
        // install or uninstall throws, so the handler stays a plain rethrow.
        supportView.changeHandler = { try AppSettings.shared.setAIEnabled($0) }
    }

    override func makeGroups() -> [NSView] {
        [integrationGroup, recognitionGroup, notificationGroup]
    }

    override func syncFromSettings() {
        let visibility = SettingsVisibility.current
        supportView.apply(isEnabled: settings.aiEnabled)
        resumeConversationsSwitch.isOn = settings.resumeAgentConversations
        customRulesSwitch.isOn = settings.customAgentRecognitionRules
        screenInferenceSwitch.isOn = settings.agentScreenInference
        integrationGroup.setRowHidden(!visibility.aiEnabled, at: 1)
        notifyAttentionSwitch.isOn = settings.notifyOnAgentAttention
        notifyCompletionSwitch.isOn = settings.notifyOnAgentCompletion
        notificationGroup.isHidden = !visibility.aiEnabled
    }
}
