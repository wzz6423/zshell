//
//  TerminalStartupSettingsView.swift
//  zshell
//

import AppKit

/// AppKit editor for the program and argv used by terminals opened afterwards.
final class TerminalStartupSettingsView: NSView, NSTextFieldDelegate {
    private let modeButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let programField = NSTextField()
    private let argumentsField = NSTextField()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let customFields = NSGridView()
    private let onChange: (String, String) -> Void
    private var isSynchronizing = false

    init(onChange: @escaping (String, String) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)

        modeButton.controlSize = .small
        modeButton.addItem(withTitle: String(localized: "Login shell"))
        modeButton.addItem(withTitle: String(localized: "Custom program"))
        modeButton.target = self
        modeButton.action = #selector(modeChanged)
        modeButton.setAccessibilityLabel(String(localized: "Terminal startup mode"))

        configureField(
            programField,
            placeholder: String(localized: "Full executable path, for example /opt/homebrew/bin/fish"),
            accessibilityLabel: String(localized: "Startup program")
        )
        configureField(
            argumentsField,
            placeholder: String(localized: "Arguments, for example --no-config"),
            accessibilityLabel: String(localized: "Startup arguments")
        )
        programField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        argumentsField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        customFields.addRow(with: [
            formLabel(String(localized: "Program")),
            programField,
        ])
        customFields.addRow(with: [
            formLabel(String(localized: "Arguments")),
            argumentsField,
        ])
        customFields.rowSpacing = 8
        customFields.columnSpacing = 8
        customFields.column(at: 0).xPlacement = .trailing
        customFields.column(at: 0).width = 72
        customFields.column(at: 1).xPlacement = .fill

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isSelectable = false
        detailLabel.maximumNumberOfLines = 0

        let modeSpacer = NSView()
        modeSpacer.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let modeRow = NSStackView(views: [modeSpacer, modeButton])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 8

        let detailSpacer = NSView()
        detailSpacer.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let detailRow = NSStackView(views: [detailSpacer, detailLabel])
        detailRow.orientation = .horizontal
        detailRow.alignment = .top
        detailRow.spacing = 8
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [modeRow, customFields, detailRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            modeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            customFields.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: 170),
        ])
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(program: String, arguments: String) {
        let isEditingCustomProgram = modeButton.indexOfSelectedItem == 1
            && programField.stringValue.isEmpty
            && program.isEmpty
            && window?.firstResponder === programField.currentEditor()
        guard !isEditingCustomProgram else { return }
        guard programField.stringValue != program
                || argumentsField.stringValue != arguments
                || modeButton.indexOfSelectedItem != (program.isEmpty ? 0 : 1)
        else { return }

        isSynchronizing = true
        programField.stringValue = program
        argumentsField.stringValue = arguments
        modeButton.selectItem(at: program.isEmpty ? 0 : 1)
        isSynchronizing = false
        updateState()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isSynchronizing else { return }
        onChange(programField.stringValue, argumentsField.stringValue)
        updateState()
    }

    @objc private func modeChanged() {
        let usesLoginShell = modeButton.indexOfSelectedItem == 0
        if usesLoginShell {
            isSynchronizing = true
            programField.stringValue = ""
            argumentsField.stringValue = ""
            isSynchronizing = false
            onChange("", "")
        }
        updateState()
        if !usesLoginShell {
            window?.makeFirstResponder(programField)
        }
    }

    private func updateState() {
        let isCustom = modeButton.indexOfSelectedItem == 1
        customFields.isHidden = !isCustom
        guard isCustom else {
            detailLabel.stringValue = String(localized: "Uses your account login shell with its login startup files.")
            detailLabel.textColor = .secondaryLabelColor
            return
        }

        switch TerminalStartupCommand.resolve(
            program: programField.stringValue,
            arguments: argumentsField.stringValue
        ) {
        case .success(.some):
            detailLabel.stringValue = String(localized: "Arguments are parsed without a shell. Quotes and backslashes preserve argument boundaries.")
            detailLabel.textColor = .secondaryLabelColor
        case .success(nil), .failure(.programNotExecutable):
            detailLabel.stringValue = String(localized: "Enter the full path to an executable file. New terminals use your login shell until the path is valid.")
            detailLabel.textColor = .systemOrange
        case .failure(.invalidArguments):
            detailLabel.stringValue = String(localized: "Close every quote and do not end arguments with a backslash. New terminals use your login shell until the arguments are valid.")
            detailLabel.textColor = .systemOrange
        }
    }

    private func configureField(
        _ field: NSTextField,
        placeholder: String,
        accessibilityLabel: String
    ) {
        field.controlSize = .small
        field.placeholderString = placeholder
        field.delegate = self
        field.setAccessibilityLabel(accessibilityLabel)
    }

    private func formLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }
}
