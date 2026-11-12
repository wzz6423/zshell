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
    private let usageSwitch = SettingsSwitch { AppSettings.shared.agentUsageEnabled = $0 }
    private let claudeUsageSwitch = SettingsSwitch { AppSettings.shared.claudeUsageEnabled = $0 }
    private let codexUsageSwitch = SettingsSwitch { AppSettings.shared.codexUsageEnabled = $0 }
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
    private lazy var usageGroup = SettingsGroup(
        header: String(localized: "Account Usage"),
        rows: [
            SettingsRow(
                title: String(localized: "Read account usage"),
                description: String(localized: "Read account limits from local CLI integrations without collecting sign-in credentials."),
                control: usageSwitch
            ),
            SettingsRow(title: String(localized: "Read Claude Code usage"), control: claudeUsageSwitch),
            SettingsRow(title: String(localized: "Read Codex usage"), control: codexUsageSwitch),
            SettingsCustomRow(usageView),
        ]
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
        [integrationGroup, recognitionGroup, notificationGroup, usageGroup]
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
        usageSwitch.isOn = settings.agentUsageEnabled
        claudeUsageSwitch.isOn = settings.claudeUsageEnabled
        codexUsageSwitch.isOn = settings.codexUsageEnabled
        claudeUsageSwitch.isEnabled = settings.agentUsageEnabled
        codexUsageSwitch.isEnabled = settings.agentUsageEnabled
        syncUsage()
    }

    private func syncUsage() {
        usageView.apply(claude: usage.claude, codex: usage.codex)
        usageGroup.setRowHidden(!usageView.hasVisibleUsage, at: 3)
    }
}
