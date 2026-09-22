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

    private lazy var checkRow = SettingsButtonRow(title: updater.updateActionTitle) {
        Updater.shared.checkForUpdates()
    }

    override func makeGroups() -> [NSView] {
        [
            SettingsGroup(rows: [
                SettingsRow(
                    title: String(localized: "Automatically check for updates"),
                    control: automaticSwitch
                ),
                SettingsRow(
                    title: String(localized: "Automatically download and install updates"),
                    description: String(localized: "Downloads updates in the background and installs them when you quit or restart Zshell."),
                    control: automaticDownloadSwitch
                ),
                checkRow,
            ]),
        ]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        automaticSwitch.setAccessibilityLabel(String(localized: "Automatically check for updates"))
        automaticDownloadSwitch.setAccessibilityLabel(String(localized: "Automatically download and install updates"))
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
        checkRow.button.title = updater.updateActionTitle
        checkRow.button.isEnabled = updater.canCheckForUpdates && !updater.isUpdating
    }
}
