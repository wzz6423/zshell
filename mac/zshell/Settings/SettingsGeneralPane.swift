//
//  SettingsGeneralPane.swift
//  zshell
//

import AppKit

/// App-wide preferences that belong to no single surface: the language Zshell
/// launches in, whether projects show the toolbar, and the reset escape hatch.
final class SettingsGeneralPane: SettingsPaneViewController {
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
        control: toolbarPopUp
    )

    private lazy var languageGroup = SettingsGroup(rows: [
        SettingsRow(title: String(localized: "Language"), control: languagePopUp),
        toolbarRow,
        relaunchRow,
    ])

    private lazy var relaunchRow: NSView = {
        let notice = NSTextField(wrappingLabelWithString: String(
            localized: "Relaunch Zshell to apply the language change.",
            comment: "Explains that the language change is pending."
        ))
        notice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notice.textColor = .secondaryLabelColor
        notice.maximumNumberOfLines = 0
        return SettingsStackRow(
            views: [
                notice,
                SettingsActionButton(title: String(localized: "Relaunch Zshell")) { [weak self] in
                    self?.relaunch()
                },
            ],
            alignment: .firstBaseline
        )
    }()

    private lazy var resetRow = SettingsButtonRow(
        title: String(localized: "Reset to Defaults")
    ) { [weak self] in
        self?.settings.resetToDefaults()
    }

    override func makeGroups() -> [NSView] {
        // The reset button stands on its own rather than inside a group: it is
        // an action, not a setting, and hairlines around a lone button read as
        // an empty group.
        [languageGroup, resetRow]
    }

    override func syncFromSettings() {
        languagePopUp.select(settings.language)
        toolbarPopUp.select(settings.toolbarVisibility)
        toolbarRow.setDescription(Self.toolbarDescription(for: settings.toolbarVisibility))
        languageGroup.setRowHidden(!settings.languageRequiresRelaunch, at: 2)
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

    /// Reopens Zshell as a second instance and quits this one, so the new
    /// process picks up the per-app `AppleLanguages` value.
    private func relaunch() {
        TerminalManager.saveForRelaunch()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let error else {
                    NSApp.terminate(nil)
                    return
                }
                self?.presentRelaunchFailure(error)
            }
        }
    }

    private func presentRelaunchFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn’t Relaunch Zshell")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
