//
//  SettingsGeneralPane.swift
//  zshell
//

import AppKit

/// App-wide preferences that belong to no single surface: the language Zshell
/// uses, whether projects show the toolbar, the Git proxy, and the reset escape hatch.
final class SettingsGeneralPane: SettingsPaneViewController, NSTextFieldDelegate {
    private let languagePopUp = SettingsPopUpButton<AppLanguage>(
        items: AppLanguage.allCases.map { .value($0.title, $0) },
        onChange: { AppSettings.shared.language = $0 }
    )

    private let toolbarPopUp = SettingsPopUpButton<ToolbarVisibility>(
        items: [
            .value(String(localized: "Auto", comment: "Toolbar visibility that follows the project."), .auto),
            .value(String(localized: "Always Show", comment: "Toolbar visibility."), .always),
            .value(String(localized: "Hide", comment: "Toolbar visibility."), .hide),
        ],
        onChange: { AppSettings.shared.toolbarVisibility = $0 }
    )

    private let presencePopUp = SettingsPopUpButton<ApplicationPresence>(
        items: ApplicationPresence.allCases.map { .value($0.title, $0) },
        onChange: { AppSettings.shared.applicationPresence = $0 }
    )

    private lazy var toolbarRow = SettingsRow(
        title: String(localized: "Toolbar"),
        description: Self.toolbarDescription(for: settings.toolbarVisibility),
        control: toolbarPopUp,
        symbolName: "macwindow"
    )

    private lazy var languageGroup = SettingsGroup(rows: [
        SettingsRow(title: String(localized: "Language"), control: languagePopUp, symbolName: "globe"),
        SettingsRow(
            title: String(localized: "Show Zshell in"),
            description: String(localized: "With a menu bar icon, closing the last workspace window keeps its terminals running."),
            control: presencePopUp,
            symbolName: "menubar.rectangle"
        ),
        toolbarRow,
    ])

    private let gitProxySwitch = SettingsSwitch { AppSettings.shared.gitProxyEnabled = $0 }
    private let gitProxyField = NSTextField()

    private lazy var gitProxyAddressRow = SettingsRow(
        title: String(localized: "Proxy address"),
        description: Self.gitProxyAddressDescription(isValid: true),
        control: gitProxyField,
        symbolName: "link"
    )

    private lazy var gitGroup = SettingsGroup(header: String(localized: "Git"), rows: [
        SettingsRow(
            title: String(localized: "Use proxy for Git"),
            description: String(localized: "Applies to Git panel actions, pull request status, and Git in terminals opened afterwards."),
            control: gitProxySwitch,
            symbolName: "network"
        ),
        gitProxyAddressRow,
    ])

    private lazy var resetRow = SettingsButtonRow(
        title: String(localized: "Reset to Defaults")
    ) { [weak self] in
        self?.settings.resetToDefaults()
    }

    override func makeGroups() -> [NSView] {
        // The reset button stands on its own rather than inside a group: it is
        // an action, not a setting, and hairlines around a lone button read as
        // an empty group.
        gitProxyField.controlSize = .small
        gitProxyField.placeholderString = GitProxy.defaultAddress
        gitProxyField.delegate = self
        gitProxyField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return [languageGroup, gitGroup, resetRow]
    }

    override func syncFromSettings() {
        languagePopUp.select(settings.language)
        presencePopUp.select(settings.applicationPresence)
        toolbarPopUp.select(settings.toolbarVisibility)
        toolbarRow.setDescription(Self.toolbarDescription(for: settings.toolbarVisibility))
        gitProxySwitch.isOn = settings.gitProxyEnabled
        if !isEditing(gitProxyField) {
            gitProxyField.stringValue = settings.gitProxyAddress
            gitProxyAddressRow.setDescription(Self.gitProxyAddressDescription(
                isValid: GitProxy.normalized(settings.gitProxyAddress) != nil))
        }
        resetRow.button.isEnabled = !settings.isAtDefaults
    }

    func controlTextDidChange(_ notification: Notification) {
        // Keep the last valid address in effect while the user is mid-edit.
        let isValid = GitProxy.normalized(gitProxyField.stringValue) != nil
        gitProxyAddressRow.setDescription(Self.gitProxyAddressDescription(isValid: isValid))
        if isValid { settings.gitProxyAddress = gitProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func isEditing(_ field: NSTextField) -> Bool {
        field.currentEditor() != nil && view.window?.firstResponder === field.currentEditor()
    }

    private static func gitProxyAddressDescription(isValid: Bool) -> String {
        isValid
            ? String(localized: "HTTP, HTTPS, or SOCKS proxy URL. Changes apply to terminals opened afterwards.")
            : String(localized: "Enter a proxy URL such as http://127.0.0.1:7897.")
    }

    private static func toolbarDescription(for visibility: ToolbarVisibility) -> String {
        switch visibility {
        case .auto:
            String(localized: "Shows the toolbar only in Git repositories")
        case .always:
            String(localized: "Shows the toolbar in every project")
        case .hide:
            String(localized: "Keeps the toolbar hidden")
        }
    }

}
