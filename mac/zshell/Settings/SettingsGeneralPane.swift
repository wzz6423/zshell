//
//  SettingsGeneralPane.swift
//  zshell
//

import AppKit

/// App-wide preferences that belong to no single surface: the language Zshell
/// uses, its appearance, whether projects show the toolbar, and the reset escape hatch.
final class SettingsGeneralPane: SettingsPaneViewController {
    private let themePicker = SettingsThemePicker { AppSettings.shared.theme = $0 }

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

    private lazy var toolbarRow = SettingsRow(
        title: String(localized: "Toolbar"),
        description: Self.toolbarDescription(for: settings.toolbarVisibility),
        control: toolbarPopUp,
        symbolName: "macwindow"
    )

    private lazy var languageGroup = SettingsGroup(rows: [
        SettingsRow(title: String(localized: "Language"), control: languagePopUp, symbolName: "globe"),
        toolbarRow,
    ])

    private lazy var appearanceGroup = SettingsGroup(header: String(localized: "Appearance"), rows: [
        SettingsCustomRow(themePicker),
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
        [languageGroup, appearanceGroup, resetRow]
    }

    override func syncFromSettings() {
        languagePopUp.select(settings.language)
        themePicker.select(settings.theme)
        themePicker.refreshPreviews()
        toolbarPopUp.select(settings.toolbarVisibility)
        toolbarRow.setDescription(Self.toolbarDescription(for: settings.toolbarVisibility))
        resetRow.button.isEnabled = !settings.isAtDefaults
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
