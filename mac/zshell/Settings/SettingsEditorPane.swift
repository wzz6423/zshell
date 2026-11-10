//
//  SettingsEditorPane.swift
//  zshell
//

import AppKit

/// File editor behavior and the external app used by file entry points.
final class SettingsEditorPane: SettingsPaneViewController {
    private let wrapLinesSwitch = SettingsSwitch { AppSettings.shared.wrapLines = $0 }
    private let dragImportSwitch = SettingsSwitch { AppSettings.shared.fileTreeDragImport = $0 }

    private let externalEditorPopUp: SettingsPopUpButton<ExternalEditor> = {
        let popup = SettingsPopUpButton<ExternalEditor>(
            items: ExternalEditor.allCases.map { .value($0.title, $0) },
            onChange: { AppSettings.shared.externalEditor = $0 }
        )
        popup.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return popup
    }()

    override func makeGroups() -> [NSView] {
        [
            SettingsGroup(rows: [
                SettingsRow(
                    title: String(localized: "External editor"),
                    control: externalEditorPopUp
                ),
                SettingsRow(
                    title: String(localized: "Wrap lines to editor width"),
                    control: wrapLinesSwitch
                ),
            ]),
            SettingsGroup(header: String(localized: "Files"), rows: [
                SettingsRow(
                    title: String(localized: "Import by dragging into the file tree"),
                    description: String(localized: "Copy Finder files and folders into local projects. File → Import Files… is always available."),
                    control: dragImportSwitch
                ),
            ]),
        ]
    }

    override func syncFromSettings() {
        externalEditorPopUp.select(settings.externalEditor)
        wrapLinesSwitch.isOn = settings.wrapLines
        dragImportSwitch.isOn = settings.fileTreeDragImport
    }
}
