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
                checkRow,
            ]),
        ]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        syncFromUpdater()
        observe(
            updater.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.syncFromUpdater() }
        )
    }

    private func syncFromUpdater() {
        automaticSwitch.isOn = updater.automaticallyChecksForUpdates
        checkRow.button.title = updater.updateActionTitle
        checkRow.button.isEnabled = updater.canCheckForUpdates && !updater.isUpdating
    }
}
