//
//  SettingsAppearancePane.swift
//  zshell
//

import AppKit
import Combine
import GhosttyTheme

/// Light/dark appearance, the color theme for each, and the fonts the terminal
/// and sidebars draw with.
final class SettingsAppearancePane: SettingsPaneViewController {
    /// Installed fixed-pitch families (bundled default first).
    private let families = TerminalFont.selectableFamilies()
    private let fallbackFamilies = TerminalFont.selectableCJKFallbackFamilies()

    private let themePicker = SettingsThemePicker { AppSettings.shared.theme = $0 }

    private let iconPicker = SettingsApplicationIconPicker {
        AppSettings.shared.applicationIcon = $0
    }

    private let darkThemePopUp = SettingsPopUpButton<String>(
        items: Theme.commonDarkThemes.map { .value($0.name, $0.name) },
        onChange: { AppSettings.shared.themeDark = $0 }
    )

    private let lightThemePopUp = SettingsPopUpButton<String>(
        items: Theme.commonLightThemes.map { .value($0.name, $0.name) },
        onChange: { AppSettings.shared.themeLight = $0 }
    )

    private let terminalThemeOnlySwitch = SettingsSwitch {
        AppSettings.shared.terminalThemeOnly = $0
    }

    private lazy var familyPopUp = SettingsPopUpButton<String>(
        items: [
            // The empty tag is the bundled family: a config naming no family
            // must keep following the bundled default across app updates.
            .value(String(localized: "\(TerminalFont.bundledFamily) (Bundled)"), ""),
            .separator,
        ] + families.dropFirst().map { .value($0, $0) },
        onChange: { AppSettings.shared.fontFamily = $0 }
    )

    private lazy var fallbackFamilyPopUp = SettingsPopUpButton<String>(
        items: [
            .value(String(localized: "System Default"), ""),
            .separator,
        ] + fallbackFamilies.map { .value($0, $0) },
        onChange: { AppSettings.shared.fontFallbackFamily = $0 }
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

    private let interfaceScaleRow = SettingsSliderRow(
        title: String(localized: "Interface size"),
        range: AppSettings.interfaceScaleRange,
        format: .percent,
        step: 0.05,
        showsStepper: true,
        accessibilityLabel: String(localized: "Interface size"),
        onChange: { AppSettings.shared.interfaceScale = $0 }
    )

    private let thickenSwitch = SettingsSwitch { AppSettings.shared.fontThicken = $0 }

    private let thickenStrengthRow = SettingsSliderRow(
        title: String(localized: "Stroke strength"),
        range: AppSettings.fontThickenStrengthRange,
        format: .integer,
        step: 1,
        showsStepper: false,
        onChange: { AppSettings.shared.fontThickenStrength = Int($0) }
    )

    private let lineHeightRow = SettingsSliderRow(
        title: String(localized: "Line height"),
        range: AppSettings.terminalLineHeightRange,
        format: .percent,
        step: 0.05,
        showsStepper: true,
        onChange: { AppSettings.shared.terminalLineHeight = $0 }
    )

    private let paneFocusRingSwitch = SettingsSwitch {
        AppSettings.shared.showPaneFocusRing = $0
    }

    private let paneFocusRingOpacityRow = SettingsSliderRow(
        title: String(localized: "Opacity"),
        range: AppSettings.paneFocusRingOpacityRange,
        format: .percent,
        step: 0.05,
        showsStepper: false,
        accessibilityLabel: String(localized: "Pane focus ring opacity"),
        onChange: { AppSettings.shared.paneFocusRingOpacity = $0 }
    )

    private let preview = FontThickenPreviewView(frame: .zero)
    private let cursorShapeView = TerminalCursorShapeSettingsView(frame: .zero)
    private let cursorBlinkingView = TerminalCursorBlinkingSettingsView(frame: .zero)
    private let terminalBackgroundBlurSwitch = SettingsSwitch { AppSettings.shared.terminalBackgroundBlur = $0 }
    private let terminalBackgroundOpacityRow = SettingsSliderRow(
        title: String(localized: "Opacity"),
        range: AppSettings.terminalBackgroundOpacityRange,
        format: .percent,
        step: 0.05,
        showsStepper: false,
        accessibilityLabel: String(localized: "Terminal background opacity"),
        onChange: { AppSettings.shared.terminalBackgroundOpacity = $0 }
    )
    private lazy var backgroundGroup = SettingsGroup(header: String(localized: "Background"), rows: [
        terminalBackgroundOpacityRow,
        SettingsRow(title: String(localized: "Blur behind window"), control: terminalBackgroundBlurSwitch),
    ])
    private lazy var fontGroup = SettingsGroup(header: String(localized: "Font"), rows: [
        SettingsRow(title: String(localized: "Latin family"), control: familyPopUp),
        SettingsRow(title: String(localized: "CJK fallback"), control: fallbackFamilyPopUp),
        fontSizeRow,
        lineHeightRow,
        SettingsRow(title: String(localized: "Thicken font strokes"), control: thickenSwitch),
        thickenStrengthRow,
        SettingsCustomRow(preview),
    ])
    private lazy var panesGroup = SettingsGroup(header: String(localized: "Panes"), rows: [
        SettingsRow(title: String(localized: "Show focus ring on active pane"), control: paneFocusRingSwitch),
        paneFocusRingOpacityRow,
    ])

    override func viewDidLoad() {
        super.viewDidLoad()
        cursorShapeView.changeHandler = { AppSettings.shared.cursorShape = $0 }
        cursorBlinkingView.changeHandler = { AppSettings.shared.cursorBlinking = $0 }
        observe(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.syncFromSettings() }
        )
    }

    override func makeGroups() -> [NSView] {
        [
            SettingsGroup(header: String(localized: "Theme"), rows: [
                SettingsCustomRow(themePicker),
            ]),
            SettingsGroup(header: String(localized: "App Icon"), rows: [
                SettingsRow(title: String(localized: "Dock icon"), control: iconPicker, symbolName: "app"),
            ]),
            SettingsGroup(header: String(localized: "Colors"), rows: [
                SettingsRow(title: String(localized: "Dark theme"), control: darkThemePopUp),
                SettingsRow(title: String(localized: "Light theme"), control: lightThemePopUp),
                SettingsRow(
                    title: String(localized: "Terminal theme only"),
                    description: String(localized: "Keep the window, sidebars, and editor on Zshell’s default colors"),
                    control: terminalThemeOnlySwitch,
                    symbolName: "terminal"
                ),
            ]),
            fontGroup,
            SettingsGroup(header: String(localized: "Cursor"), rows: [
                SettingsCustomRow(cursorShapeView),
                SettingsCustomRow(cursorBlinkingView),
            ]),
            backgroundGroup,
            SettingsGroup(header: String(localized: "Interface"), rows: [
                interfaceScaleRow,
                sidebarFontSizeRow,
            ]),
            panesGroup,
        ]
    }

    override func syncFromSettings() {
        let visibility = SettingsVisibility.current
        themePicker.select(settings.theme)
        // The previews paint the resolved palettes, which follow the theme
        // names rather than the light/dark selection.
        themePicker.refreshPreviews()
        iconPicker.select(settings.applicationIcon)
        darkThemePopUp.select(settings.themeDark)
        lightThemePopUp.select(settings.themeLight)
        terminalThemeOnlySwitch.isOn = settings.terminalThemeOnly
        familyPopUp.select(settings.fontFamily)
        fallbackFamilyPopUp.select(settings.fontFallbackFamily)
        fontSizeRow.setValue(settings.fontSize)
        sidebarFontSizeRow.setValue(settings.sidebarFontSize)
        interfaceScaleRow.setValue(settings.interfaceScale)
        thickenSwitch.isOn = settings.fontThicken
        thickenStrengthRow.setValue(Double(settings.fontThickenStrength))
        fontGroup.setRowHidden(!visibility.fontThicken, at: 5)
        lineHeightRow.setValue(settings.terminalLineHeight)
        cursorShapeView.apply(shape: settings.cursorShape)
        cursorBlinkingView.apply(isBlinking: settings.cursorBlinking)
        terminalBackgroundOpacityRow.setValue(settings.terminalBackgroundOpacity)
        terminalBackgroundBlurSwitch.isOn = settings.terminalBackgroundBlur
        backgroundGroup.setRowHidden(!visibility.terminalBackgroundBlur, at: 1)
        paneFocusRingSwitch.isOn = settings.showPaneFocusRing
        paneFocusRingOpacityRow.setValue(settings.paneFocusRingOpacity)
        panesGroup.setRowHidden(!visibility.showPaneFocusRing, at: 1)
        preview.configure(
            font: TerminalFont.resolve(
                family: settings.fontFamily,
                fallbackFamily: settings.fontFallbackFamily,
                size: CGFloat(settings.fontSize)
            ),
            thicken: settings.fontThicken,
            thickenStrength: settings.fontThickenStrength,
            lineHeight: CGFloat(settings.terminalLineHeight)
        )
    }
}
