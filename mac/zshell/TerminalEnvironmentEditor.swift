//
//  TerminalEnvironmentEditor.swift
//  zshell
//

import AppKit

/// AppKit editor for project launch settings and a tab's overrides.
@MainActor
final class TerminalEnvironmentEditorController: NSWindowController, NSWindowDelegate {
    static let shared = TerminalEnvironmentEditorController()

    private enum Scope {
        case project(Project)
        case tab(Project, PaneTab)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let variableStack = NSStackView()
    private let commandMode = NSPopUpButton()
    private let commandText = NSTextView()
    private let commandScroll = NSScrollView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var variableRows: [EnvironmentVariableRow] = []
    private var scope: Scope?
    private weak var parentWindow: NSWindow?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 570),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "Terminal Environment")
        super.init(window: window)
        window.delegate = self
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func show(project: Project) {
        shared.present(.project(project))
    }

    static func show(project: Project, tab: PaneTab) {
        shared.present(.tab(project, tab))
    }

    private func present(_ scope: Scope) {
        self.scope = scope
        loadValues()
        guard let window else { return }
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        parentWindow = parent
        if let parent, parent !== window {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0

        variableStack.orientation = .vertical
        variableStack.alignment = .leading
        variableStack.spacing = 8

        let addButton = NSButton(
            title: String(localized: "Add Variable"),
            target: self,
            action: #selector(addVariable)
        )
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small

        commandMode.addItems(withTitles: [
            String(localized: "Inherit Project Command"),
            String(localized: "Replace Project Command"),
            String(localized: "Disable Project Command"),
        ])
        commandMode.target = self
        commandMode.action = #selector(commandModeChanged)

        commandText.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        commandText.isRichText = false
        commandText.allowsUndo = true
        commandScroll.documentView = commandText
        commandScroll.hasVerticalScroller = true
        commandScroll.borderType = .bezelBorder

        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true

        let cancel = NSButton(
            title: String(localized: "Cancel"),
            target: self,
            action: #selector(cancelEditing)
        )
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(
            title: String(localized: "Save"),
            target: self,
            action: #selector(saveEditing)
        )
        save.keyEquivalent = "\r"

        let environmentHeader = NSTextField(
            labelWithString: String(localized: "Environment Variables")
        )
        environmentHeader.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let commandHeader = NSTextField(
            labelWithString: String(localized: "Initialization Command")
        )
        commandHeader.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let plaintextWarning = NSTextField(wrappingLabelWithString: String(
            localized: "Values are saved as plain text in the session snapshot. Do not store passwords, tokens, or other secrets here."
        ))
        plaintextWarning.textColor = .secondaryLabelColor
        plaintextWarning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let buttonRow = NSStackView(views: [NSView(), cancel, save])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.views.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            titleLabel, detailLabel, environmentHeader, variableStack,
            addButton, plaintextWarning, commandHeader, commandMode,
            commandScroll, errorLabel, buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: detailLabel)
        stack.setCustomSpacing(18, after: plaintextWarning)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            variableStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandMode.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 105),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func loadValues() {
        variableRows.forEach { $0.removeFromSuperview() }
        variableRows = []
        errorLabel.isHidden = true

        switch scope {
        case .project(let project):
            titleLabel.stringValue = String(localized: "Project Terminal Environment")
            detailLabel.stringValue = String(
                localized: "These settings apply only to terminals created after you save. Existing terminal processes are unchanged."
            )
            commandMode.isHidden = true
            commandText.isEditable = true
            commandText.string = project.launchSettings.initializationCommand ?? ""
            project.launchSettings.environmentVariables.forEach(addVariableRow)
        case .tab(let project, let tab):
            titleLabel.stringValue = String(localized: "Tab Terminal Environment")
            detailLabel.stringValue = String(
                localized: "Tab variables override project variables with the same name. These settings affect only terminals created later in this tab."
            )
            commandMode.isHidden = false
            let settings = tab.launchSettingsOverride
            commandMode.selectItem(at: settings.initializationMode.menuIndex)
            commandText.string = settings.initializationCommand ?? ""
            commandText.isEditable = settings.initializationMode == .replace
            settings.environmentVariables.forEach(addVariableRow)
            _ = project
        case nil:
            break
        }
        if variableRows.isEmpty { addVariableRow(.init(name: "", value: "")) }
    }

    @objc private func addVariable() {
        addVariableRow(.init(name: "", value: ""))
        variableRows.last?.nameField.window?.makeFirstResponder(variableRows.last?.nameField)
    }

    private func addVariableRow(_ variable: TerminalEnvironmentVariable) {
        let row = EnvironmentVariableRow(variable: variable) { [weak self] row in
            self?.removeVariableRow(row)
        }
        variableRows.append(row)
        variableStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: variableStack.widthAnchor).isActive = true
    }

    private func removeVariableRow(_ row: EnvironmentVariableRow) {
        variableRows.removeAll { $0 === row }
        variableStack.removeArrangedSubview(row)
        row.removeFromSuperview()
    }

    @objc private func commandModeChanged() {
        commandText.isEditable = commandMode.indexOfSelectedItem == 1
    }

    @objc private func cancelEditing() {
        closeEditor()
    }

    @objc private func saveEditing() {
        guard let variables = validatedVariables() else { return }
        let command = normalizedCommand(commandText.string)
        switch scope {
        case .project(let project):
            project.launchSettings = TerminalLaunchSettings(
                environmentVariables: variables,
                initializationCommand: command
            )
        case .tab(_, let tab):
            let mode = TerminalLaunchSettingsOverride.InitializationMode(
                menuIndex: commandMode.indexOfSelectedItem
            )
            tab.launchSettingsOverride = TerminalLaunchSettingsOverride(
                environmentVariables: variables,
                initializationMode: mode,
                initializationCommand: mode == .replace ? command : nil
            )
        case nil:
            return
        }
        closeEditor()
    }

    private func validatedVariables() -> [TerminalEnvironmentVariable]? {
        var names = Set<String>()
        var variables: [TerminalEnvironmentVariable] = []
        for row in variableRows {
            let name = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = row.valueField.stringValue
            if name.isEmpty, value.isEmpty { continue }
            guard TerminalLaunchSettings.isValidEnvironmentVariableName(name) else {
                return showError(String(
                    localized: "Variable names must begin with a letter or underscore and contain only letters, numbers, and underscores."
                ))
            }
            guard !TerminalLaunchSettings.isProtectedEnvironmentVariable(name) else {
                return showError(String(
                    localized: "“\(name)” is managed by Zshell and cannot be overridden.",
                    comment: "The placeholder is an environment variable name."
                ))
            }
            guard names.insert(name).inserted else {
                return showError(String(
                    localized: "“\(name)” appears more than once.",
                    comment: "The placeholder is a duplicate environment variable name."
                ))
            }
            variables.append(.init(name: name, value: value))
        }
        errorLabel.isHidden = true
        return variables
    }

    private func showError<T>(_ message: String) -> T? {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        NSSound.beep()
        return nil
    }

    private func normalizedCommand(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func closeEditor() {
        guard let window else { return }
        if let parentWindow, window.sheetParent === parentWindow {
            parentWindow.endSheet(window)
        } else {
            window.orderOut(nil)
        }
        scope = nil
        self.parentWindow = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeEditor()
        return false
    }
}

private extension TerminalLaunchSettingsOverride.InitializationMode {
    var menuIndex: Int {
        switch self {
        case .inherit: 0
        case .replace: 1
        case .disabled: 2
        }
    }

    init(menuIndex: Int) {
        switch menuIndex {
        case 1: self = .replace
        case 2: self = .disabled
        default: self = .inherit
        }
    }
}

private final class EnvironmentVariableRow: NSView {
    let nameField = NSTextField()
    let valueField = NSTextField()
    private let remove: (EnvironmentVariableRow) -> Void

    init(
        variable: TerminalEnvironmentVariable,
        remove: @escaping (EnvironmentVariableRow) -> Void
    ) {
        self.remove = remove
        super.init(frame: .zero)

        nameField.placeholderString = String(localized: "Name")
        nameField.stringValue = variable.name
        nameField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueField.placeholderString = String(localized: "Value")
        valueField.stringValue = variable.value
        valueField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let button = NSButton(
            image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: String(localized: "Remove Variable"))!,
            target: self,
            action: #selector(removeRow)
        )
        button.isBordered = false
        button.toolTip = String(localized: "Remove Variable")

        let stack = NSStackView(views: [nameField, valueField, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            nameField.widthAnchor.constraint(equalTo: valueField.widthAnchor, multiplier: 0.55),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func removeRow() {
        remove(self)
    }
}
