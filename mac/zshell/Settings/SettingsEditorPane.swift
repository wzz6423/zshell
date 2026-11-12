//
//  SettingsEditorPane.swift
//  zshell
//

import AppKit
import Combine

/// File editor behavior and the external app used by file entry points.
final class SettingsEditorPane: SettingsPaneViewController {
    private let wrapLinesSwitch = SettingsSwitch { AppSettings.shared.wrapLines = $0 }
    private let dragImportSwitch = SettingsSwitch { AppSettings.shared.fileTreeDragImport = $0 }
    private let remoteWriteSwitch = SettingsSwitch { AppSettings.shared.remoteFileWritesEnabled = $0 }
    private let protectSavesSwitch = SettingsSwitch { AppSettings.shared.protectEditorSaves = $0 }
    private let recoverDraftsSwitch = SettingsSwitch { AppSettings.shared.recoverEditorDrafts = $0 }
    private var draftObservation: AnyCancellable?
    private lazy var recoveryRow = SettingsRow(
        title: String(localized: "Back up unsaved drafts"),
        description: "", control: recoverDraftsSwitch
    )
    private lazy var manageDrafts = SettingsButtonRow(title: String(localized: "Recover Drafts…")) {
        guard let manager = TerminalManager.activeWindowManager else { return }
        EditorDraftRecoveryController.shared.show(for: manager)
    }

    private let externalEditorPopUp: SettingsPopUpButton<ExternalEditor> = {
        let popup = SettingsPopUpButton<ExternalEditor>(
            items: ExternalEditor.allCases.map { .value($0.title, $0) },
            onChange: { AppSettings.shared.externalEditor = $0 }
        )
        popup.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return popup
    }()

    override func makeGroups() -> [NSView] {
        draftObservation = EditorDraftStore.shared.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncFromSettings() }
        return [
            SettingsGroup(rows: [
                SettingsRow(
                    title: String(localized: "External editor"),
                    control: externalEditorPopUp
                ),
                SettingsRow(
                    title: String(localized: "Wrap lines to editor width"),
                    control: wrapLinesSwitch
                ),
                SettingsRow(
                    title: String(localized: "Protect against save conflicts"),
                    control: protectSavesSwitch
                ),
            ]),
            SettingsGroup(rows: [recoveryRow, manageDrafts]),
            SettingsGroup(header: String(localized: "Files"), rows: [
                SettingsRow(
                    title: String(localized: "Allow remote file changes"),
                    description: String(localized: "Create, rename, move to remote trash, and save files over SSH. Reading remains available when this is off."),
                    control: remoteWriteSwitch
                ),
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
        remoteWriteSwitch.isOn = settings.remoteFileWritesEnabled
        protectSavesSwitch.isOn = settings.protectEditorSaves
        recoverDraftsSwitch.isOn = settings.recoverEditorDrafts
        let explanation = settings.recoverEditorDrafts
            ? String(localized: "Recover unsaved file and editable diff changes after relaunch. Backups stay on this Mac for up to 30 days. Capacity limits may delete older backups sooner.")
            : String(localized: "New backups and automatic recovery are off. Recover or delete unexpired backups with Recover Drafts…")
        let expiry = String(localized: "Expired backups are deleted while Zshell runs, even with backups off. If Zshell is closed, cleanup runs the next time it opens.")
        recoveryRow.setDescription([explanation, expiry, EditorDraftStore.shared.lastError].compactMap { $0 }.joined(separator: "\n"))
    }
}
