import AppKit
import Combine

@MainActor
final class NewWorktreeSessionController: NSObject, NSComboBoxDelegate {
    private let alert = NSAlert()
    private let branchField = NSComboBox()
    private let basePicker = NSPopUpButton()
    private let directoryField = NSTextField()
    private let chooseButton = NSButton()
    private let branchLabel = NSTextField(labelWithString: "")
    private let baseLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let helpLabel = NSTextField(wrappingLabelWithString: "")
    private let repository: SessionWorktreeService.Repository
    private var usesSuggestedDirectory = true
    private var languageObservation: AnyCancellable?

    private init(repository: SessionWorktreeService.Repository) {
        self.repository = repository
        super.init()
        branchField.addItems(withObjectValues: repository.branches.filter { branch in
            !repository.worktrees.contains(where: { $0.branch == branch })
        })
        branchField.completes = true
        branchField.delegate = self
        branchField.setAccessibilityIdentifier("worktreeSessionBranch")
        basePicker.setAccessibilityIdentifier("worktreeSessionBase")
        directoryField.setAccessibilityIdentifier("worktreeSessionDirectory")
        directoryField.delegate = self
        directoryField.stringValue = SessionWorktreeService.defaultPath(repositoryRoot: repository.root, branch: "")
        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseDirectory)
        let pathRow = NSStackView(views: [directoryField, chooseButton])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8
        directoryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let grid = NSGridView(views: [[branchLabel, branchField], [baseLabel, basePicker], [directoryLabel, pathRow]])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline
        let content = NSStackView(views: [grid, helpLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.frame = NSRect(x: 0, y: 0, width: 510, height: 152)
        grid.translatesAutoresizingMaskIntoConstraints = false
        helpLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.widthAnchor.constraint(equalTo: content.widthAnchor),
            helpLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            branchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        alert.accessoryView = content
        alert.addButton(withTitle: "")
        alert.addButton(withTitle: "")
        refreshLanguage()
        languageObservation = NotificationCenter.default.publisher(for: AppLocalization.didChange)
            .sink { [weak self] _ in self?.refreshLanguage() }
    }

    static func present(manager: TerminalManager, project: Project) async {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow), host.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let source = manager.worktreeSourceDirectory(for: project)
        do {
            let repository = try await SessionWorktreeService().repository(at: source)
            let controller = NewWorktreeSessionController(repository: repository)
            controller.alert.window.initialFirstResponder = controller.branchField
            let response = await controller.alert.beginSheetModal(for: host)
            guard response == .alertFirstButtonReturn else { return }
            let base: SessionWorktreeService.Base = controller.basePicker.indexOfSelectedItem == 1
                ? .currentHead : .repositoryDefault
            _ = try await manager.newWorktreeSession(in: project, branch: controller.branchField.stringValue,
                                                    directory: controller.directoryField.stringValue,
                                                    sourceDirectory: source, base: base, expectedHead: repository.head)
        } catch {
            await manager.showWorktreeError(error, in: host)
        }
    }

    private func refreshLanguage() {
        alert.messageText = String(localized: "New Session in Worktree…")
        alert.informativeText = String(localized: "Create an isolated checkout and open its own terminal session.")
        alert.buttons[0].title = String(localized: "Create Session")
        alert.buttons[1].title = String(localized: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        branchLabel.stringValue = String(localized: "Branch")
        branchField.placeholderString = String(localized: "New or existing local branch")
        branchField.setAccessibilityLabel(branchLabel.stringValue)
        baseLabel.stringValue = String(localized: "Baseline")
        let selected = max(0, basePicker.indexOfSelectedItem)
        basePicker.removeAllItems()
        if let reference = repository.defaultReference {
            basePicker.addItem(withTitle: String(localized: "Default Branch (\(reference.replacingOccurrences(of: "refs/heads/", with: "")))"))
        } else {
            basePicker.addItem(withTitle: String(localized: "Default Branch Unavailable"))
            basePicker.item(at: 0)?.isEnabled = false
        }
        basePicker.addItem(withTitle: String(localized: "Current HEAD"))
        basePicker.selectItem(at: repository.defaultReference == nil ? 1 : selected)
        basePicker.setAccessibilityLabel(baseLabel.stringValue)
        directoryLabel.stringValue = String(localized: "Worktree Directory")
        directoryField.setAccessibilityLabel(directoryLabel.stringValue)
        chooseButton.title = String(localized: "Choose…")
        chooseButton.setAccessibilityLabel(String(localized: "Choose Worktree Directory"))
        updateBranchState()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSControl === directoryField { usesSuggestedDirectory = false }
        updateBranchState()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) { updateBranchState() }

    private func updateBranchState() {
        let branch = branchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesSuggestedDirectory {
            directoryField.stringValue = SessionWorktreeService.defaultPath(repositoryRoot: repository.root, branch: branch)
        }
        basePicker.isEnabled = !repository.branches.contains(branch)
        helpLabel.stringValue = basePicker.isEnabled
            ? String(localized: "New branches start from the selected baseline. Choose a directory that does not exist yet.")
            : String(localized: "Existing branches keep their current commit. Choose a directory that does not exist yet.")
        alert.buttons[0].isEnabled = !branch.isEmpty
    }

    @objc private func chooseDirectory() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Choose Worktree Directory")
        panel.prompt = String(localized: "Choose")
        panel.canCreateDirectories = true
        let current = URL(fileURLWithPath: directoryField.stringValue, isDirectory: true)
        panel.directoryURL = FileManager.default.fileExists(atPath: current.deletingLastPathComponent().path)
            ? current.deletingLastPathComponent() : URL(fileURLWithPath: repository.root).deletingLastPathComponent()
        panel.nameFieldStringValue = current.lastPathComponent
        panel.beginSheetModal(for: alert.window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.usesSuggestedDirectory = false
            self?.directoryField.stringValue = url.path
        }
    }
}
