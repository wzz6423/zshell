//
//  SettingsAppearancePane.swift
//  zshell
//

import AppKit
import GhosttyTheme

/// Light/dark appearance, the color theme for each, and the fonts the terminal
/// and sidebars draw with.
final class SettingsAppearancePane: SettingsPaneViewController {
    /// Installed fixed-pitch families (bundled default first).
    private let families = TerminalFont.selectableFamilies()

    private let themePicker = SettingsThemePicker { AppSettings.shared.theme = $0 }

    private let darkThemePopUp = SettingsPopUpButton<String>(
        items: Theme.commonDarkThemes.map { .value($0.name, $0.name) },
        onChange: { AppSettings.shared.themeDark = $0 }
    )

    private let lightThemePopUp = SettingsPopUpButton<String>(
        items: Theme.commonLightThemes.map { .value($0.name, $0.name) },
        onChange: { AppSettings.shared.themeLight = $0 }
    )

    private lazy var familyPopUp = SettingsPopUpButton<String>(
        items: [
            // The empty tag is the bundled family: a config naming no family
            // must keep following the bundled default across app updates.
            .value(String(localized: "\(TerminalFont.bundledFamily) (Bundled)"), ""),
            .separator,
        ] + families.dropFirst().map { .value($0, $0) },
        onChange: { AppSettings.shared.fontFamily = $0 }
    )

    private let fontSizeRow = SettingsSliderRow(
        title: String(localized: "Size"),
        range: AppSettings.fontSizeRange,
        format: .points,
        step: 1,
        showsStepper: true,
        onChange: { AppSettings.shared.fontSize = $0 }
    )

    private let sidebarFontSizeRow = SettingsSliderRow(
        title: String(localized: "Font size"),
        range: AppSettings.sidebarFontSizeRange,
        format: .points,
        step: 1,
        showsStepper: true,
        accessibilityLabel: String(localized: "Sidebar font size"),
        onChange: { AppSettings.shared.sidebarFontSize = $0 }
    )

    private let thickenSwitch = SettingsSwitch { AppSettings.shared.fontThicken = $0 }

    private let preview = FontThickenPreviewView(frame: .zero)

    override func makeGroups() -> [NSView] {
        [
            SettingsGroup(rows: [
                SettingsRow(title: String(localized: "Theme"), control: themePicker),
            ]),
            SettingsGroup(header: String(localized: "Colors"), rows: [
                SettingsRow(title: String(localized: "Dark theme"), control: darkThemePopUp),
                SettingsRow(title: String(localized: "Light theme"), control: lightThemePopUp),
            ]),
            SettingsGroup(header: String(localized: "Font"), rows: [
                SettingsRow(title: String(localized: "Family"), control: familyPopUp),
                fontSizeRow,
                SettingsRow(
                    title: String(localized: "Thicken font strokes"),
                    description: String(localized: "Renders terminal text with slightly heavier strokes, like classic macOS font smoothing"),
                    control: thickenSwitch
                ),
                SettingsCustomRow(preview),
            ]),
            SettingsGroup(header: String(localized: "Sidebar"), rows: [
                sidebarFontSizeRow,
            ]),
        ]
    }

    override func syncFromSettings() {
        themePicker.select(settings.theme)
        // The previews paint the resolved palettes, which follow the theme
        // names rather than the light/dark selection.
        themePicker.refreshPreviews()
        darkThemePopUp.select(settings.themeDark)
        lightThemePopUp.select(settings.themeLight)
        familyPopUp.select(settings.fontFamily)
        fontSizeRow.setValue(settings.fontSize)
        sidebarFontSizeRow.setValue(settings.sidebarFontSize)
        thickenSwitch.isOn = settings.fontThicken
        preview.configure(
            font: TerminalFont.resolve(
                family: settings.fontFamily,
                size: CGFloat(settings.fontSize)
            ),
            thicken: settings.fontThicken
        )
    }
}
