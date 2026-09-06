//
//  SettingsUpdatesPane.swift
//  zshell
//

import AppKit
import Combine

/// How Zshell updates itself. A Homebrew installation is managed by Homebrew,
/// so this pane reports that instead of offering Sparkle's schedule.
final class SettingsUpdatesPane: SettingsPaneViewController {
    private let updater = Updater.shared

    private let automaticSwitch = SettingsSwitch {
        Updater.shared.automaticallyChecksForUpdates = $0
    }

    private lazy var checkRow = SettingsButtonRow(title: updater.updateActionTitle) {
        Updater.shared.checkForUpdates()
    }

    /// Homebrew owns the update schedule, so the row states the channel rather
    /// than offering a toggle that could not take effect.
    private lazy var homebrewNoticeRow: NSView = {
        let icon = NSImageView(
            image: NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
                ?? NSImage()
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: String(localized: "Installed with Homebrew"))
        title.font = .systemFont(ofSize: NSFont.systemFontSize)

        let badge = NSStackView(views: [icon, title])
        badge.orientation = .horizontal
        badge.alignment = .centerY
        badge.spacing = 6

        let description = NSTextField(wrappingLabelWithString: String(
            localized: "Homebrew manages updates for this installation."
        ))
        description.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 0

        let column = NSStackView(views: [badge, description])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return SettingsCustomRow(column)
    }()

    override func makeGroups() -> [NSView] {
        [
            SettingsGroup(rows: [
                updater.isHomebrewInstallation
                    ? homebrewNoticeRow
                    : SettingsRow(
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
