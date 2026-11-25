import AppKit

@MainActor
final class QuickCommandParameterEditorView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    var onChange: (() -> Void)?
    private let parameterPicker = NSPopUpButton()
    private let nameField = NSTextField()
    private let kindPicker = NSPopUpButton()
    private let defaultField = NSTextField()
    private let choicesView = NSTextView()
    private let choicesScroll = NSScrollView()
    private let choicesLabel = NSTextField(labelWithString: String(localized: "Choices (one per line)"))
    private let removeButton = NSButton()
    private let addButton = NSButton()
    private let details = NSStackView()
    private var draft: [QuickCommandParameter] = []
    private var selectedIndex = -1
    private var isUpdating = false

    var parameters: [QuickCommandParameter] {
        var result = draft
        if result.indices.contains(selectedIndex) { result[selectedIndex] = currentParameter() }
        return result
    }

    init() {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: String(localized: "Parameters"))
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        addButton.title = String(localized: "Add Parameter")
        addButton.target = self
        addButton.action = #selector(addParameter)
        addButton.identifier = NSUserInterfaceItemIdentifier("quick-command-add-parameter")
        addButton.bezelStyle = .rounded
        removeButton.title = String(localized: "Remove Parameter")
        removeButton.identifier = NSUserInterfaceItemIdentifier("quick-command-remove-parameter")
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeParameter)
        parameterPicker.identifier = NSUserInterfaceItemIdentifier("quick-command-parameter-picker")
        parameterPicker.setAccessibilityLabel(String(localized: "Parameters"))
        parameterPicker.target = self
        parameterPicker.action = #selector(selectParameter)
        let header = NSStackView(views: [parameterPicker, addButton, removeButton])
        header.spacing = 8
        parameterPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)

        nameField.identifier = NSUserInterfaceItemIdentifier("quick-command-parameter-name")
        defaultField.identifier = NSUserInterfaceItemIdentifier("quick-command-parameter-default")
        for field in [nameField, defaultField] { field.delegate = self }
        kindPicker.identifier = NSUserInterfaceItemIdentifier("quick-command-parameter-kind")
        kindPicker.addItems(withTitles: [String(localized: "Text"), String(localized: "Dropdown")])
        kindPicker.target = self
        kindPicker.action = #selector(changeKind)
        kindPicker.setAccessibilityLabel(String(localized: "Parameter Type"))

        choicesView.isRichText = false
        choicesView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        choicesView.delegate = self
        choicesView.isVerticallyResizable = true
        choicesView.isHorizontallyResizable = false
        choicesView.textContainer?.widthTracksTextView = true
        choicesView.textContainerInset = NSSize(width: 4, height: 4)
        choicesView.identifier = NSUserInterfaceItemIdentifier("quick-command-parameter-choices")
        choicesView.setAccessibilityLabel(String(localized: "Choices (one per line)"))
        choicesScroll.documentView = choicesView
        choicesScroll.hasVerticalScroller = true
        choicesScroll.borderType = .bezelBorder
        choicesScroll.translatesAutoresizingMaskIntoConstraints = false
        choicesScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let nameAndKind = NSStackView(views: [nameField, kindPicker])
        nameAndKind.spacing = 8
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        details.orientation = .vertical
        details.alignment = .width
        details.spacing = 6
        for view in [
            NSTextField(labelWithString: String(localized: "Parameter Name")), nameAndKind,
            NSTextField(labelWithString: String(localized: "Default Value")), defaultField, choicesLabel, choicesScroll,
        ] { details.addArrangedSubview(view) }
        nameField.setAccessibilityLabel(String(localized: "Parameter Name"))
        defaultField.setAccessibilityLabel(String(localized: "Default Value"))
        let stack = NSStackView(views: [label, header, details])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setParameters([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setParameters(_ parameters: [QuickCommandParameter]) {
        draft = parameters
        selectedIndex = draft.isEmpty ? -1 : 0
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isUpdating else { return }
        commitCurrent()
        if draft.indices.contains(selectedIndex) { parameterPicker.item(at: selectedIndex)?.title = nameField.stringValue }
        onChange?()
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdating else { return }
        commitCurrent()
        onChange?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            window?.selectNextKeyView(control)
            return true
        }
        return false
    }

    private func currentParameter() -> QuickCommandParameter {
        let kind: QuickCommandParameter.Kind = kindPicker.indexOfSelectedItem == 1 ? .dropdown : .text
        var choices = choicesView.string.components(separatedBy: .newlines)
        if choices.last == "" { choices.removeLast() }
        return QuickCommandParameter(
            name: nameField.stringValue, kind: kind, defaultValue: defaultField.stringValue,
            choices: kind == .dropdown ? choices : []
        )
    }

    private func commitCurrent() {
        guard draft.indices.contains(selectedIndex) else { return }
        draft[selectedIndex] = currentParameter()
    }

    private func refresh() {
        isUpdating = true
        defer { isUpdating = false }
        parameterPicker.removeAllItems()
        for parameter in draft { parameterPicker.addItem(withTitle: parameter.name) }
        parameterPicker.isEnabled = !draft.isEmpty
        addButton.isEnabled = draft.count < QuickCommandTemplate.maximumParameters
        removeButton.isEnabled = selectedIndex >= 0
        details.isHidden = selectedIndex < 0
        guard draft.indices.contains(selectedIndex) else { return }
        parameterPicker.selectItem(at: selectedIndex)
        let parameter = draft[selectedIndex]
        nameField.stringValue = parameter.name
        kindPicker.selectItem(at: parameter.kind == .dropdown ? 1 : 0)
        defaultField.stringValue = parameter.defaultValue
        choicesView.string = parameter.choices.joined(separator: "\n")
        choicesLabel.isHidden = parameter.kind == .text
        choicesScroll.isHidden = parameter.kind == .text
    }

    @objc private func selectParameter() {
        commitCurrent()
        selectedIndex = parameterPicker.indexOfSelectedItem
        refresh()
        onChange?()
    }

    @objc private func changeKind() {
        commitCurrent()
        refresh()
        onChange?()
    }

    @objc private func addParameter() {
        guard draft.count < QuickCommandTemplate.maximumParameters else { return }
        commitCurrent()
        var name = "arg"
        var index = 2
        while draft.contains(where: { $0.name == name }) { name = "arg" + String(index); index += 1 }
        draft.append(.init(name: name))
        selectedIndex = draft.count - 1
        refresh()
        window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
        onChange?()
    }

    @objc private func removeParameter() {
        guard draft.indices.contains(selectedIndex) else { return }
        draft.remove(at: selectedIndex)
        selectedIndex = min(selectedIndex, draft.count - 1)
        refresh()
        onChange?()
    }
}
