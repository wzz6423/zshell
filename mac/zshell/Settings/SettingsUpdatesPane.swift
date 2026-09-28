//
//  SettingsUpdatesPane.swift
//  zshell
//

import AppKit
import Combine

final class SettingsUpdatesPane: SettingsPaneViewController {
    private let updater = Updater.shared

    private let automaticSwitch = SettingsSwitch {
        Updater.shared.automaticallyChecksForUpdates = $0
    }

    private let automaticDownloadSwitch = SettingsSwitch {
        Updater.shared.automaticallyDownloadsUpdates = $0
    }

    private let automaticInstallSwitch = SettingsSwitch {
        Updater.shared.automaticallyInstallsUpdates = $0
    }

    private lazy var updateGroup = SettingsGroup(rows: [
        SettingsRow(
            title: String(localized: "Automatically check for updates"),
            control: automaticSwitch
        ),
        SettingsRow(
            title: String(localized: "Automatically download updates"),
            description: String(localized: "Downloads updates in the background. If automatic installation is off, updates install when you quit Zshell."),
            control: automaticDownloadSwitch
        ),
        SettingsRow(
            title: String(localized: "Automatically install updates"),
            description: String(localized: "Installs downloaded updates and restarts Zshell automatically. Running terminal processes will stop."),
            control: automaticInstallSwitch
        ),
        checkRow,
    ])

    private lazy var checkRow = SettingsButtonRow(title: updater.updateActionTitle) {
        Updater.shared.checkForUpdates()
    }

    override func makeGroups() -> [NSView] { [updateGroup] }

    override func viewDidLoad() {
        super.viewDidLoad()
        automaticSwitch.setAccessibilityLabel(String(localized: "Automatically check for updates"))
        automaticDownloadSwitch.setAccessibilityLabel(String(localized: "Automatically download updates"))
        automaticInstallSwitch.setAccessibilityLabel(String(localized: "Automatically install updates"))
        syncFromUpdater()
        observe(
            updater.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.syncFromUpdater() }
        )
    }

    private func syncFromUpdater() {
        automaticSwitch.isOn = updater.automaticallyChecksForUpdates
        automaticDownloadSwitch.isOn = updater.automaticallyDownloadsUpdates
        automaticDownloadSwitch.isEnabled = updater.automaticallyChecksForUpdates && updater.allowsAutomaticUpdates
        automaticInstallSwitch.isOn = updater.automaticallyInstallsUpdates
        updateGroup.setRowHidden(!updater.automaticallyDownloadsUpdates, at: 2)
        checkRow.button.title = updater.updateActionTitle
        checkRow.button.isEnabled = updater.canCheckForUpdates && !updater.isUpdating
    }
}
