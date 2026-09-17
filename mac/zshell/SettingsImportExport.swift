//
//  SettingsImportExport.swift
//  zshell
//

import AppKit
import UniformTypeIdentifiers

/// Menu entry points for carrying the settings that live in config.toml
/// between installs. Export writes the same representation `save()` persists;
/// import validates with the app's own strict reader, confirms, and applies
/// through ``AppSettings/applyImported(_:)``.
@MainActor
enum SettingsImportExport {
    /// UniformTypeIdentifiers ships no predefined `toml` type, so derive one
    /// from the extension; matching files by extension is all the panels need.
    private static let tomlType = UTType(filenameExtension: "toml") ?? .data

    static func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [tomlType]
        panel.nameFieldStringValue = "zshell-settings.toml"
        panel.message = String(
            localized: "Choose where to save the exported settings.",
            comment: "Message in the settings export save panel."
        )
        present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try AppSettings.shared.serializedConfig()
                    .write(to: url, atomically: true, encoding: .utf8)
            } catch {
                presentError(
                    String(localized: "Couldn’t Export Settings"),
                    detail: String(
                        localized: "The settings could not be written to “\(url.path)”.",
                        comment: "The placeholder is the chosen export file's path."
                    )
                )
                return
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "Settings Exported")
            alert.informativeText = String(
                localized: "The current settings were written to “\(url.path)”.",
                comment: "The placeholder is the chosen export file's path."
            )
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Reveal in Finder"))
            present(alert) { response in
                guard response == .alertSecondButtonReturn else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    static func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [tomlType]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(
            localized: "Choose a settings file to import.",
            comment: "Message in the settings import open panel."
        )
        panel.prompt = String(
            localized: "Import",
            comment: "Button in the settings import open panel."
        )
        present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            importSettings(from: url)
        }
    }

    private static func importSettings(from url: URL) {
        guard let parsed = TOML.parseStrictly(at: url) else {
            presentError(
                String(localized: "Couldn’t Import Settings"),
                detail: String(
                    localized: "The file “\(url.path)” could not be read.",
                    comment: "The placeholder is the chosen import file's path."
                )
            )
            return
        }
        if let malformed = parsed.malformed {
            presentError(
                String(localized: "Couldn’t Import Settings"),
                detail: String(
                    localized: "Line \(malformed.number) could not be read: \(malformed.text)",
                    comment: """
                        Import error for a malformed line. The first placeholder \
                        is the 1-based line number; the second is the line's \
                        text as written in the file.
                        """
                )
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "Apply the settings in “\(url.path)”?",
            comment: "Confirmation before importing. The placeholder is the chosen file's path."
        )
        alert.informativeText = String(
            localized: "The current settings will be replaced.",
            comment: "Explains what confirming an import does."
        )
        alert.addButton(withTitle: String(localized: "Apply"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            backUpCurrentConfig()
            AppSettings.shared.applyImported(parsed.values)
        }
    }

    /// Copies config.toml to config.toml.bak in the same directory before an
    /// import overwrites it. The backup stays for manual recovery — restoring
    /// it by hand is the escape hatch when an import turns out unwanted.
    private static func backUpCurrentConfig() {
        let backupURL = AppSettings.configURL.deletingLastPathComponent()
            .appendingPathComponent("config.toml.bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: AppSettings.configURL, to: backupURL)
    }

    private static func presentError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        present(alert) { _ in }
    }

    /// Sheets panels and alerts on the active Zshell window. Without an owning
    /// application window there is no stable place for an ordinary popup, so
    /// the request is ignored instead of falling back to a screen-level modal.
    private static func present(
        _ panel: NSSavePanel,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard let window = AppWindowPresentation.hostWindow() else { return }
        panel.beginSheetModal(for: window, completionHandler: completion)
    }

    private static func present(
        _ alert: NSAlert,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard let window = AppWindowPresentation.hostWindow() else { return }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}
