//
//  QuickLaunchEditorController.swift
//  zshell
//

import AppKit

/// A small form window for creating or editing one Quick Launch entry. The
/// type popup switches between the command fields and the SSH fields; saving
/// writes straight into `QuickLaunchStore`, which the launcher panel observes.
@MainActor
final class QuickLaunchEditorController: NSObject, NSWindowDelegate {
    /// Editors keep themselves alive between presentation and close — nothing
    /// else owns one — so they are parked here until the window closes.
    private static var openEditors: [QuickLaunchEditorController] = []

    private enum KindChoice: Int {
        case command
        case ssh
    }

    private let editingEntry: QuickLaunchEntry?
    private let window: NSWindow

    private let nameField = NSTextField()
    private let groupField = NSTextField()
    private let typePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let commandField = NSTextField()
    private let directoryField = NSTextField()
    private let userField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let optionsField = NSTextField()
    private let kindDescription = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private var grid: NSGridView?
    /// The fitting size changes when the type popup switches forms; the panel
    /// remembers the top edge so the window grows downward, like a sheet.
    private var anchoredTop: CGFloat?

    private init(entry: QuickLaunchEntry?) {
        editingEntry = entry
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = entry == nil
            ? String(
                localized: "New Quick Launch Entry",
                comment: "Title of the Quick Launch entry editor for a new entry."
            )
            : String(
                localized: "Edit Quick Launch Entry",
                comment: "Title of the Quick Launch entry editor for an existing entry."
            )
        window.isReleasedWhenClosed = false
        window.delegate = self

        buildForm()
    }

    /// Presents the editor centered over `parent` (the launcher panel when it
    /// is open, else centered on screen).
    static func present(editing entry: QuickLaunchEntry?, relativeTo parent: NSWindow?) {
        let controller = QuickLaunchEditorController(entry: entry)
        openEditors.append(controller)

        if let parent {
            let frame = controller.window.frame
            controller.window.setFrameOrigin(NSPoint(
                x: parent.frame.midX - frame.width / 2,
                y: parent.frame.midY - frame.height / 2
            ))
        } else {
            controller.window.center()
        }
        // The launcher panel floats, so the editor must float above it.
        controller.window.level = .floating
        controller.window.makeKeyAndOrderFront(nil)
        controller.window.makeFirstResponder(controller.nameField)
    }

    // MARK: - Form

    private var selectedKind: KindChoice {
        KindChoice(rawValue: typePopUp.indexOfSelectedItem) ?? .command
    }

    private func buildForm() {
        typePopUp.addItems(withTitles: [
            String(localized: "Command", comment: "Quick Launch entry type: a shell command."),
            String(
                localized: "SSH Connection",
                comment: "Quick Launch entry type: an SSH connection."
            ),
        ])
        typePopUp.controlSize = .small
        typePopUp.target = self
        typePopUp.action = #selector(kindChanged)

        commandField.placeholderString = String(
            localized: "npm run dev",
            comment: "Placeholder of the Quick Launch command field."
        )
        groupField.placeholderString = String(
            localized: "Optional, e.g. Work",
            comment: "Placeholder of the Quick Launch group field."
        )
        userField.placeholderString = String(
            localized: "Optional",
            comment: "Marks a Quick Launch editor field as optional."
        )
        hostField.placeholderString = String(
            localized: "example.com",
            comment: "Placeholder of the Quick Launch SSH host field."
        )
        portField.placeholderString = String(
            localized: "22",
            comment: "Placeholder of the Quick Launch SSH port field."
        )
        optionsField.placeholderString = String(
            localized: "Optional, e.g. -L 8080:localhost:80",
            comment: "Placeholder of the Quick Launch SSH options field."
        )

        let browseButton = NSButton(
            title: String(
                localized: "Browse…",
                comment: "Button opening a directory picker."
            ),
            target: self,
            action: #selector(browseForDirectory)
        )
        browseButton.bezelStyle = .rounded
        browseButton.controlSize = .small
        let directoryRow = NSStackView(views: [directoryField, browseButton])
        directoryRow.orientation = .horizontal
        directoryRow.spacing = 6
        directoryField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        kindDescription.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        kindDescription.textColor = .secondaryLabelColor
        kindDescription.maximumNumberOfLines = 0

        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true

        saveButton.title = String(localized: "Save")
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"

        let cancelButton = NSButton(
            title: String(localized: "Cancel"),
            target: self,
            action: #selector(cancel)
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [errorLabel, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .firstBaseline
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.addRow(with: [
            formLabel(String(
                localized: "Name",
                comment: "Quick Launch editor label for the entry name."
            )),
            nameField,
        ])
        grid.addRow(with: [
            formLabel(String(
                localized: "Group",
                comment: "Quick Launch editor label for the entry's group."
            )),
            groupField,
        ])
        grid.addRow(with: [
            formLabel(String(
                localized: "Type",
                comment: "Quick Launch editor label for the entry type."
            )),
            typePopUp,
        ])
        grid.addRow(with: [
            formLabel(String(
                localized: "Command",
                comment: "Quick Launch editor label for the shell command."
            )),
            commandField,
        ])
        grid.addRow(with: [
            formLabel(String(
                localized: "Working Directory",
                comment: "Quick Launch editor label for the command's starting directory."
            )),
            directoryRow,
        ])
        grid.addRow(with: [
            formLabel(String(
                localized: "User",
                comment: "Quick Launch editor label for the SSH user."
            )),
            userField,
        ])
        grid.addRow(with: [
            formLabel(String(
                localized: "Host",
                comment: "Quick Launch editor label for the SSH host."
            )),
            hostField,
        ])
        grid.addRow(with: [
            formLabel(String(
                localized: "Port",
                comment: "Quick Launch editor label for the SSH port."
            )),
            portField,
        ])
        grid.addRow(with: [
            formLabel(String(
                localized: "Options",
                comment: "Quick Launch editor label for extra SSH arguments."
            )),
            optionsField,
        ])
        // Rows 0-2 are the shared name/group/type rows; 3-4 describe a
        // command, 5-8 an SSH connection. One grid keeps the label column
        // aligned while hiding rows switches between the two forms.
        grid.translatesAutoresizingMaskIntoConstraints = false
        self.grid = grid

        let stack = NSStackView(views: [grid, kindDescription, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(
                equalTo: window.contentView!.topAnchor, constant: 20
            ),
            stack.leadingAnchor.constraint(
                equalTo: window.contentView!.leadingAnchor, constant: 20
            ),
            stack.trailingAnchor.constraint(
                equalTo: window.contentView!.trailingAnchor, constant: -20
            ),
            stack.bottomAnchor.constraint(
                equalTo: window.contentView!.bottomAnchor, constant: -16
            ),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            kindDescription.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            typePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        fillForm()
    }

    private func formLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func fillForm() {
        guard let entry = editingEntry else {
            typePopUp.selectItem(at: KindChoice.command.rawValue)
            kindChanged()
            return
        }
        nameField.stringValue = entry.name
        groupField.stringValue = entry.group ?? ""
        switch entry.kind {
        case .command(let command, let directory):
            commandField.stringValue = command
            directoryField.stringValue = directory ?? ""
            typePopUp.selectItem(at: KindChoice.command.rawValue)
        case .ssh(let user, let host, let port, let extraArguments):
            userField.stringValue = user ?? ""
            hostField.stringValue = host
            portField.stringValue = port.map(String.init) ?? ""
            optionsField.stringValue = extraArguments ?? ""
            typePopUp.selectItem(at: KindChoice.ssh.rawValue)
        }
        kindChanged()
    }

    @objc private func kindChanged() {
        guard let grid else { return }
        let hideCommand = selectedKind != .command
        let hideSSH = selectedKind != .ssh
        for row in 3..<grid.numberOfRows {
            grid.row(at: row).isHidden = row >= 5 ? hideSSH : hideCommand
        }
        kindDescription.stringValue = selectedKind == .command
            ? String(
                localized: "The command runs in a new terminal session using your login shell.",
                comment: "Explains what a Quick Launch command entry does."
            )
            : String(
                localized: "The connection opens with ssh in a new terminal session.",
                comment: "Explains what a Quick Launch SSH entry does."
            )
        sizeToFitWindow()
    }

    private func sizeToFitWindow() {
        guard let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let size = contentView.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let oldTop = anchoredTop ?? window.frame.maxY
        anchoredTop = oldTop
        window.setContentSize(size)
        // setContentSize keeps the bottom-left corner fixed; re-anchor the
        // top edge and re-center horizontally so the form grows downward.
        window.setFrameOrigin(NSPoint(
            x: window.frame.midX - size.width / 2,
            y: oldTop - window.frame.height
        ))
    }

    @objc private func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Button in the directory picker.")
        panel.message = String(
            localized: "Choose the directory the command starts in.",
            comment: "Message in the Quick Launch directory picker."
        )
        if !directoryField.stringValue.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: directoryField.stringValue, isDirectory: true)
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.directoryField.stringValue = url.path
        }
    }

    // MARK: - Save / cancel

    @objc private func save() {
        do {
            let kind = try readKind()
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let group = groupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = name.isEmpty ? Self.defaultName(for: kind) : name
            if let editingEntry {
                QuickLaunchStore.shared.update(
                    QuickLaunchEntry(
                        id: editingEntry.id,
                        name: resolvedName,
                        kind: kind,
                        group: group.isEmpty ? nil : group
                    )
                )
            } else {
                QuickLaunchStore.shared.add(
                    QuickLaunchEntry(
                        name: resolvedName,
                        kind: kind,
                        group: group.isEmpty ? nil : group
                    )
                )
            }
            close()
        } catch let error as ValidationError {
            showError(error.message)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private struct ValidationError: Error {
        let message: String
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        sizeToFitWindow()
    }

    private func readKind() throws -> QuickLaunchEntry.Kind {
        switch selectedKind {
        case .command:
            let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                throw ValidationError(message: String(
                    localized: "A command is required.",
                    comment: "Quick Launch editor validation for an empty command."
                ))
            }
            let directory = directoryField.stringValue.trimmingCharacters(in: .whitespaces)
            if !directory.isEmpty {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: directory,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw ValidationError(message: String(
                        localized: "The working directory must be an existing folder.",
                        comment: "Quick Launch editor validation for a bad directory."
                    ))
                }
                return .command(command: command, directory: directory)
            }
            return .command(command: command, directory: nil)
        case .ssh:
            let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else {
                throw ValidationError(message: String(
                    localized: "A host is required.",
                    comment: "Quick Launch editor validation for an empty SSH host."
                ))
            }
            let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
            let portText = portField.stringValue.trimmingCharacters(in: .whitespaces)
            var port: Int?
            if !portText.isEmpty {
                guard let value = Int(portText), (1...65535).contains(value) else {
                    throw ValidationError(message: String(
                        localized: "The port must be a number between 1 and 65535.",
                        comment: "Quick Launch editor validation for a bad SSH port."
                    ))
                }
                port = value
            }
            let options = optionsField.stringValue.trimmingCharacters(in: .whitespaces)
            return .ssh(
                user: user.isEmpty ? nil : user,
                host: host,
                port: port,
                extraArguments: options.isEmpty ? nil : options
            )
        }
    }

    /// A blank name falls back to what the entry runs, so the list never shows
    /// an unlabeled row.
    private static func defaultName(for kind: QuickLaunchEntry.Kind) -> String {
        switch kind {
        case .command(let command, _):
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        case .ssh(let user, let host, _, _):
            return user.map { "\($0)@\(host)" } ?? host
        }
    }

    @objc private func cancel() {
        close()
    }

    private func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.openEditors.removeAll { $0 === self }
    }
}
