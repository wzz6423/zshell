import AppKit

final class TerminalSessionDirectorySettingsView: NSView, NSTextFieldDelegate {
    private let directoryField = NSTextField()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let onChange: (NewSessionDirectoryPolicy, String) -> Void
    private var policy: NewSessionDirectoryPolicy = .current
    private lazy var policyPopup = SettingsPopUpButton<NewSessionDirectoryPolicy>(
        items: NewSessionDirectoryPolicy.allCases.map { .value($0.title, $0) },
        onChange: { [weak self] policy in
            guard let self else { return }
            self.policy = policy
            self.onChange(policy, self.directoryField.stringValue)
            self.updateState()
            if policy == .custom { self.window?.makeFirstResponder(self.directoryField) }
        }
    )
    private lazy var chooseButton = SettingsActionButton(title: String(localized: "Choose…")) { [weak self] in
        self?.chooseDirectory()
    }
    private lazy var directoryRow = NSStackView(views: [directoryField, chooseButton])

    init(onChange: @escaping (NewSessionDirectoryPolicy, String) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        directoryField.controlSize = .small
        directoryField.placeholderString = String(localized: "Absolute path or ~/folder")
        directoryField.delegate = self
        directoryField.setAccessibilityLabel(String(localized: "Custom new session directory"))
        directoryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        directoryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseButton.setAccessibilityLabel(String(localized: "Choose a new session directory"))
        directoryRow.orientation = .horizontal
        directoryRow.alignment = .centerY
        directoryRow.spacing = 8

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let heading = SettingsRow(title: String(localized: "New session directory"), control: policyPopup,
                                  symbolName: "folder.fill", symbolColor: .systemIndigo)
        let stack = NSStackView(views: [heading, directoryRow, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            directoryRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(policy: NewSessionDirectoryPolicy, directory: String) {
        self.policy = policy
        policyPopup.select(policy)
        if directoryField.stringValue != directory { directoryField.stringValue = directory }
        updateState()
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange(policy, directoryField.stringValue)
        updateState()
    }

    private func updateState() {
        directoryRow.isHidden = policy != .custom
        detailLabel.textColor = .secondaryLabelColor
        if policy == .custom {
            let localization = AppLocalization.current
            switch TerminalSessionDirectory.customDirectory(directoryField.stringValue) {
            case .success: break
            case .failure(.invalidPath):
                showError(String(
                    localized: "Enter an absolute path or ~/folder. New sessions use the current directory until this path is valid.",
                    defaultValue: "Enter an absolute path or ~/folder. Explicit, pinned, and group directories still take precedence. Otherwise, new sessions use the current directory if available, or your home directory.",
                    bundle: localization.bundle, locale: localization.locale
                ))
                return
            case .failure(.missingDirectory):
                showError(String(
                    localized: "This directory does not exist. New sessions use the current directory until it is available.",
                    defaultValue: "This directory does not exist. Explicit, pinned, and group directories still take precedence. Otherwise, new sessions use the current directory if available, or your home directory.",
                    bundle: localization.bundle, locale: localization.locale
                ))
                return
            case .failure(.notDirectory):
                showError(String(
                    localized: "This path is a file, not a directory. New sessions use the current directory.",
                    defaultValue: "This path is a file, not a directory. Explicit, pinned, and group directories still take precedence. Otherwise, new sessions use the current directory if available, or your home directory.",
                    bundle: localization.bundle, locale: localization.locale
                ))
                return
            case .failure(.inaccessibleDirectory):
                showError(String(
                    localized: "Zshell cannot access this directory. New sessions use the current directory.",
                    defaultValue: "Zshell cannot access this directory. Explicit, pinned, and group directories still take precedence. Otherwise, new sessions use the current directory if available, or your home directory.",
                    bundle: localization.bundle, locale: localization.locale
                ))
                return
            }
        }
        detailLabel.stringValue = String(localized: "Applies to new local sessions. Explicit, pinned, and group directories take precedence; splits keep their source directory.")
    }

    private func showError(_ message: String) {
        detailLabel.stringValue = message
        detailLabel.textColor = .systemOrange
    }

    private func chooseDirectory() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose the directory for new local sessions.")
        if case .success(let directory) = TerminalSessionDirectory.customDirectory(directoryField.stringValue) {
            panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let directory = panel.url?.path else { return }
            self.apply(policy: .custom, directory: directory)
            self.onChange(.custom, directory)
        }
    }
}
