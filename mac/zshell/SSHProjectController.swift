//
//  SSHProjectController.swift
//  zshell
//

import AppKit

@MainActor
final class SSHProjectController {
    static let shared = SSHProjectController()

    private init() {}

    func present(for manager: TerminalManager) {
        let alert = NSAlert()
        alert.messageText = String(localized: "New SSH Project")
        alert.informativeText = String(
            localized: "Connect with the system OpenSSH client. Password prompts are disabled."
        )
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let fields = SSHProjectFieldsView()
        alert.accessoryView = fields
        alert.window.initialFirstResponder = fields.hostField

        let completion: (NSApplication.ModalResponse) -> Void = { [weak manager] response in
            guard response == .alertFirstButtonReturn, let manager else { return }
            do {
                let endpoint = try SSHEndpoint(
                    host: fields.hostField.stringValue,
                    user: fields.userField.stringValue,
                    port: fields.portField.stringValue.isEmpty
                        ? nil : fields.portField.integerValue
                )
                let directory = fields.directoryField.stringValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                manager.newSSHProject(
                    endpoint: endpoint,
                    remoteDirectory: directory.isEmpty ? nil : directory
                )
            } catch {
                self.presentValidationError(error, for: manager)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func presentValidationError(_ error: Error, for manager: TerminalManager) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t create the SSH project.")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { [weak manager] _ in
                guard let manager else { return }
                self.present(for: manager)
            }
        } else {
            alert.runModal()
        }
    }
}

private final class SSHProjectFieldsView: NSView {
    let hostField = NSTextField()
    let userField = NSTextField()
    let portField = NSTextField()
    let directoryField = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        hostField.placeholderString = String(localized: "example.com")
        userField.placeholderString = NSUserName()
        portField.placeholderString = "22"
        directoryField.placeholderString = "~/project"

        let grid = NSGridView(views: [
            row(String(localized: "Host"), hostField),
            row(String(localized: "User"), userField),
            row(String(localized: "Port"), portField),
            row(String(localized: "Remote Directory"), directoryField),
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 260
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func row(_ title: String, _ field: NSTextField) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return [label, field]
    }
}
