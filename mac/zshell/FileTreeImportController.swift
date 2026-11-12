import AppKit
import Combine

@MainActor
final class FileTreeImportController: ObservableObject {
    static let shared = FileTreeImportController()
    @Published private(set) var isImporting = false
    private var operation: FileTreeImportOperation?
    private var task: Task<Void, Never>?
    private weak var manager: TerminalManager?
    private var projectID: UUID?
    private var root = ""
    private var directory = ""
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?
    private var cancelButton: NSButton?
    private weak var confirmationWindow: NSWindow?
    private var observations: [AnyCancellable] = []

    func chooseFiles(manager: TerminalManager, directory: String) {
        guard !isImporting, manager.canImportFiles,
              let window = manager.presentationWindow else { return }
        let root = manager.fileTree.rootPath
        let projectID = manager.selectedProjectID
        let destination: FileTreeImportService.Destination
        do { destination = try FileTreeImportService.destination(root: root, directory: directory) }
        catch { showError(error, in: window); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Copy files and folders into “\(directory)”.")
        panel.beginSheetModal(for: window) { [weak self, weak manager] response in
            guard response == .OK, let manager else { return }
            manager.syncFileTree()
            guard manager.selectedProjectID == projectID, manager.fileTree.rootPath == root else { return }
            do {
                try destination.validate()
                self?.importFiles(panel.urls, manager: manager, directory: directory, destination: destination)
            } catch { self?.showError(error, in: window) }
        }
    }

    func importFiles(_ urls: [URL], manager: TerminalManager, directory: String,
                     destination: FileTreeImportService.Destination? = nil) {
        guard !isImporting, manager.canImportFiles, !urls.isEmpty,
              let window = manager.presentationWindow else { return }
        self.manager = manager
        projectID = manager.selectedProjectID
        root = manager.fileTree.rootPath
        self.directory = directory
        let progressOwner = FileTreeImportProgressOwner(self)
        let operation = FileTreeImportOperation { name in
            Task { @MainActor in
                progressOwner.controller?.progressLabel?.stringValue = String(localized: "Copying “\(name)”…")
            }
        }
        self.operation = operation
        isImporting = true
        observeDestination(manager)
        showProgress(in: window)
        let root = root
        task = Task { [weak self] in
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try FileTreeImportService.prepare(sources: urls, root: root, directory: directory,
                                                      operation: operation, destination: destination)
                }.value
                guard let self else { operation.cancel(); return }
                try self.validateSelection()
                self.hideProgress()
                var decisions: [Int: FileTreeImportService.Decision] = [:]
                for index in plan.conflicts {
                    try operation.checkCancellation()
                    try self.validateSelection()
                    decisions[index] = try await self.confirmReplacement(plan.entries[index].name, in: window)
                }
                try operation.checkCancellation()
                try self.validateSelection()
                self.showProgress(in: window)
                _ = try await Task.detached(priority: .userInitiated) {
                    try FileTreeImportService.perform(plan, decisions: decisions, operation: operation)
                }.value
                self.finish(error: nil)
            } catch {
                self?.finish(error: error)
            }
        }
    }

    func cancel() {
        operation?.cancel()
        if let confirmationWindow { confirmationWindow.sheetParent?.endSheet(confirmationWindow, returnCode: .abort) }
        progressLabel?.stringValue = String(localized: "Cancelling import…")
        cancelButton?.isEnabled = false
    }

    private func observeDestination(_ manager: TerminalManager) {
        observations = [
            manager.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.cancelIfSelectionChanged() }
            },
            manager.fileTree.$rootPath.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.cancelIfSelectionChanged() }
            },
        ]
    }

    private func validateSelection() throws {
        guard let manager, manager.selectedProjectID == projectID,
              manager.selectedProject?.isRemote == false else { throw CancellationError() }
        manager.syncFileTree()
        guard manager.fileTree.rootPath == root else { throw CancellationError() }
    }

    private func cancelIfSelectionChanged() {
        if (try? validateSelection()) == nil { cancel() }
    }

    private func confirmReplacement(_ name: String, in window: NSWindow) async throws -> FileTreeImportService.Decision {
        let alert = NSAlert()
        alert.messageText = String(localized: "Replace “\(name)”?", comment: "The placeholder is an existing file or folder name.")
        alert.informativeText = String(localized: "An item with this name already exists in “\(directory)”. Replace it with the imported copy, skip this item, or cancel the entire import.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Skip"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[2].keyEquivalent = "\u{1b}"
        confirmationWindow = alert.window
        defer { confirmationWindow = nil }
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        switch response {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .skip
        default: throw CancellationError()
        }
    }

    private func showProgress(in window: NSWindow) {
        guard progressWindow == nil else { return }
        let title = NSTextField(labelWithString: String(localized: "Import Files…"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let destination = NSTextField(labelWithString: directory)
        destination.font = .systemFont(ofSize: 11)
        destination.textColor = .secondaryLabelColor
        destination.lineBreakMode = .byTruncatingHead
        destination.maximumNumberOfLines = 1
        destination.toolTip = directory
        let label = NSTextField(labelWithString: String(localized: "Preparing import…"))
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [title, destination, label, indicator, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = String(localized: "Import Files…")
        panel.isReleasedWhenClosed = false
        let content = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            destination.widthAnchor.constraint(equalTo: stack.widthAnchor),
            label.widthAnchor.constraint(equalTo: stack.widthAnchor),
            indicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = content
        progressWindow = panel
        progressLabel = label
        cancelButton = cancel
        window.beginSheet(panel)
    }

    private func hideProgress() {
        if let progressWindow {
            progressWindow.sheetParent?.endSheet(progressWindow)
            progressWindow.orderOut(nil)
        }
        progressWindow = nil
        progressLabel = nil
        cancelButton = nil
    }

    private func finish(error: Error?) {
        hideProgress()
        observations = []
        isImporting = false
        task = nil
        operation = nil
        let manager = manager
        self.manager = nil
        if manager?.selectedProjectID == projectID, manager?.fileTree.rootPath == root {
            manager?.fileTree.didImportFiles(in: directory)
            NotificationCenter.default.post(name: .fileTreeImportDidFinish, object: manager)
        }
        guard let error, !(error is CancellationError), let window = manager?.presentationWindow else { return }
        showError(error, in: window)
    }

    private func showError(_ error: Error, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn’t Import Files")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    @objc private func cancelClicked() { cancel() }
}

extension Notification.Name {
    static let fileTreeImportDidFinish = Notification.Name("zshell.fileTreeImportDidFinish")
}

@MainActor
private final class FileTreeImportProgressOwner {
    weak var controller: FileTreeImportController?
    init(_ controller: FileTreeImportController) { self.controller = controller }
}
