import AppKit

@MainActor
final class TerminalSharingPreviewController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let shared = TerminalSharingPreviewController()
    private let exporter: TerminalOutputExportController
    private let worker = DispatchQueue(label: "sh.zshell.terminal-sharing", qos: .userInitiated)
    private(set) var panel: NSPanel?
    let editor = NSTextView()
    private let originalSwitch = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()
    private let cancelButton = NSButton()
    private weak var host: NSWindow?
    private weak var previousResponder: NSResponder?
    private var observations: [NSObjectProtocol] = []
    private var job: TerminalOutputExportJob?
    private var generation = 0
    private var original: String?
    private var redacted: String?
    private var matchCount = 0
    private var includesOriginal = false
    private var savesFile = false
    private var exporting = false
    private var restoresFocus = true
    nonisolated private enum Failure: Sendable { case read, tooLarge }

    init(exporter: TerminalOutputExportController = .shared) {
        self.exporter = exporter
        super.init()
    }

    isolated deinit { clear() }

    func canSave() -> Bool {
        exporter.focusedSurface(in: TerminalManager.activeWindowManager).map(canPreview(from:)) ?? false
    }

    func save() {
        if let surface = exporter.focusedSurface(in: TerminalManager.activeWindowManager) { save(from: surface) }
    }

    func canPreview(from surface: any TerminalBackendSurface) -> Bool {
        panel?.isVisible != true && job == nil && !exporting && exporter.canSave(from: surface)
    }

    func save(from surface: any TerminalBackendSurface) {
        guard canPreview(from: surface), let host = surface.window else { return }
        guard let capture = TerminalHistorySerializer.takeLogCapture(from: surface) else { present(.read, on: host); return }
        show(job: TerminalOutputExportJob(capture), on: host, savesFile: true)
    }

    func copy(from surface: any TerminalBackendSurface, location: TerminalCommandOutputLocation? = nil) {
        guard canPreview(from: surface), let host = surface.window else { return }
        let text: String?
        if let location {
            text = surface.commandText(at: location, part: .output, maxBytes: TerminalSecretRedaction.maximumBytes)
        } else {
            text = surface.readSelectedText(maxBytes: TerminalSecretRedaction.maximumBytes)
        }
        guard let text else { present(.read, on: host); return }
        show(job: TerminalOutputExportJob(text: text), on: host, savesFile: false)
    }

    private func show(job: TerminalOutputExportJob, on host: NSWindow, savesFile: Bool) {
        if panel == nil { configure() }
        guard let panel else { if let capture = job.cancel() { worker.async { capture.discard() } }; return }
        generation += 1
        let currentGeneration = generation
        self.job = job
        self.host = host
        previousResponder = host.firstResponder
        self.savesFile = savesFile
        includesOriginal = false
        originalSwitch.state = .off
        errorLabel.stringValue = ""
        observations = [NSWindow.willCloseNotification, NSApplication.willTerminateNotification, AppLocalization.didChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: name == NSWindow.willCloseNotification ? host : nil, queue: .main)
            {
                [weak self] _ in
                assumeMainActor {
                    if name == AppLocalization.didChange { self?.localize() } else { self?.close(restoreFocus: false) }
                }
            }
        }
        localize()
        AppWindowPresentation.attach(panel, to: host, placement: .centered)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(cancelButton)
        worker.async { [weak self] in
            var result: (String, TerminalSecretRedaction.Result)?
            var failure: Failure?
            do {
                if let text = try job.read(maxBytes: TerminalSecretRedaction.maximumBytes), !job.isCancelled() {
                    if let redacted = TerminalSecretRedaction.redact(text), redacted.text.utf8.count <= TerminalSecretRedaction.maximumBytes
                    {
                        result = (text, redacted)
                    } else {
                        failure = .tooLarge
                    }
                } else {
                    failure = .read
                }
            } catch TerminalHistorySerializer.LogCapture.ReadFailure.tooLarge { failure = .tooLarge } catch { failure = .read }
            let capturedResult = result
            let capturedFailure = failure
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration, self.job === job, !job.isCancelled() else { return }
                self.job = nil
                if let (original, redacted) = capturedResult {
                    self.original = original
                    self.redacted = redacted.text
                    self.matchCount = redacted.matchCount
                    self.editor.undoManager?.removeAllActions()
                    self.editor.string = redacted.text
                    self.panel?.makeFirstResponder(self.editor)
                    self.localize()
                } else {
                    self.errorLabel.stringValue = self.message(for: capturedFailure ?? .read)
                    self.localize()
                }
            }
        }
    }

    func close(restoreFocus: Bool = true) {
        restoresFocus = restoreFocus
        panel?.close()
        restoresFocus = true
    }

    func windowWillClose(_ notification: Notification) {
        let previousHost = host
        let responder = previousResponder
        clear()
        if let panel, let sheet = panel.attachedSheet { panel.endSheet(sheet, returnCode: .abort) }
        if let panel { AppWindowPresentation.hideChild(panel) }
        if restoresFocus, let previousHost, let view = responder as? NSView,
            view.window === previousHost, !view.isHiddenOrHasHiddenAncestor
        {
            previousHost.makeFirstResponder(view)
        }
    }

    private func clear() {
        generation += 1
        if let panel { exporter.cancel(on: panel) }
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        if let capture = job?.cancel() { worker.async { capture.discard() } }
        job = nil
        original = nil
        redacted = nil
        host = nil
        previousResponder = nil
        exporting = false
        editor.undoManager?.removeAllActions()
        editor.string = ""
        errorLabel.stringValue = ""
    }

    @objc private func toggleOriginal(_ sender: Any?) {
        guard original != nil, !exporting else { return }
        if includesOriginal { original = editor.string } else { redacted = editor.string }
        includesOriginal = originalSwitch.state == .on
        // Switching modes must not leave the original secrets in Undo when
        // the user returns to a redacted preview.
        editor.undoManager?.removeAllActions()
        editor.string = (includesOriginal ? original : redacted) ?? ""
        errorLabel.stringValue = ""
        localize()
    }

    @objc private func performAction(_ sender: Any?) {
        guard original != nil, !exporting else { return }
        let text = editor.string
        guard text.utf8.count <= TerminalSecretRedaction.maximumBytes else {
            errorLabel.stringValue = message(for: .tooLarge)
            localize()
            return
        }
        if savesFile {
            guard let panel else { return }
            exporting = true
            let currentGeneration = generation
            localize()
            exporter.save(text: text, on: panel) { [weak self] saved in
                guard let self, self.generation == currentGeneration else { return }
                self.exporting = false
                if saved { self.close() } else { self.localize() }
            }
        } else {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(text, forType: .string) {
                close()
            } else {
                errorLabel.stringValue = String(localized: "The preview could not be copied.")
                localize()
            }
        }
    }

    @objc private func dismiss(_ sender: Any?) { close() }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let text = (textView.string as NSString).replacingCharacters(in: range, with: replacementString)
        guard text.utf8.count <= TerminalSecretRedaction.maximumBytes else {
            errorLabel.stringValue = message(for: .tooLarge)
            localize()
            return false
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        errorLabel.stringValue = ""
        localize()
    }

    func textView(_ textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }

    private func message(for failure: Failure) -> String {
        switch failure {
        case .read: String(localized: "The selected terminal text could not be read or exceeds 2 MiB. Try a smaller selection.")
        case .tooLarge: String(localized: "The sharing preview supports up to 2 MiB. Try a smaller selection.")
        }
    }

    private func present(_ failure: Failure, on host: NSWindow) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn’t Preview Terminal Text")
        alert.informativeText = message(for: failure)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: host)
    }

    private func localize() {
        panel?.title = String(localized: "Terminal Sharing Preview")
        originalSwitch.title = String(localized: "Include Original Secrets")
        actionButton.title = savesFile ? String(localized: "Save Preview") : String(localized: "Copy Preview")
        cancelButton.title = String(localized: "Cancel")
        editor.setAccessibilityLabel(String(localized: "Terminal Sharing Preview"))
        if job != nil {
            status.stringValue = String(localized: "Checking terminal text locally")
        } else if original != nil {
            status.stringValue =
                includesOriginal
                ? String(localized: "Original secrets are included. Review and edit this text before sharing.")
                : String(
                    localized: "Suspected secrets replaced: \(matchCount). Detection can miss secrets; review and edit before sharing.")
        } else {
            status.stringValue = ""
        }
        let ready = original != nil && !exporting
        originalSwitch.isEnabled = ready
        editor.isEditable = ready
        actionButton.isEnabled = ready
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
    }

    private func configure() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 540, height: 340)
        panel.identifier = .init("terminal-sharing-preview")
        panel.delegate = self
        self.panel = panel
        guard let content = panel.contentView else { return }
        originalSwitch.setButtonType(.switch)
        originalSwitch.target = self
        originalSwitch.action = #selector(toggleOriginal(_:))
        originalSwitch.identifier = .init("terminal-sharing-original")
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.identifier = .init("terminal-sharing-editor")
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        for (button, selector, identifier) in [
            (actionButton, #selector(performAction(_:)), "terminal-sharing-action"),
            (cancelButton, #selector(dismiss(_:)), "terminal-sharing-cancel"),
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = selector
            button.identifier = .init(identifier)
        }
        actionButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [NSView(), cancelButton, actionButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        for view in [originalSwitch, scroll, status, errorLabel, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            originalSwitch.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            originalSwitch.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            originalSwitch.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: originalSwitch.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            footer.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }
}

@MainActor
final class TerminalSharingMenuTarget: NSObject, NSMenuItemValidation {
    private weak var surface: (any TerminalBackendSurface)?
    private let location: TerminalCommandOutputLocation?
    private let savesFile: Bool

    private init(surface: any TerminalBackendSurface, location: TerminalCommandOutputLocation?, savesFile: Bool) {
        self.surface = surface
        self.location = location
        self.savesFile = savesFile
    }

    static func item(for surface: any TerminalBackendSurface, location: TerminalCommandOutputLocation? = nil, savesFile: Bool = false)
        -> NSMenuItem
    {
        let target = TerminalSharingMenuTarget(surface: surface, location: location, savesFile: savesFile)
        let title =
            savesFile
            ? String(localized: "Save Redacted Output")
            : location == nil ? String(localized: "Copy with Redaction") : String(localized: "Copy Output with Redaction")
        let item = NSMenuItem(title: title, action: #selector(preview(_:)), keyEquivalent: "")
        item.identifier = .init(
            savesFile ? "zshell-save-redacted-output" : location == nil ? "zshell-copy-redacted-selection" : "zshell-copy-redacted-output")
        item.target = target
        item.representedObject = target
        item.isEnabled = target.validateMenuItem(item)
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let surface, TerminalSharingPreviewController.shared.canPreview(from: surface) else { return false }
        if savesFile { return true }
        if let location, let region = surface.commandRegion(at: location) { return region.outputStart < region.outputEnd }
        return location == nil && surface.hasSelection
    }

    @objc private func preview(_ sender: NSMenuItem) {
        guard let surface else { return }
        if savesFile {
            TerminalSharingPreviewController.shared.save(from: surface)
        } else {
            TerminalSharingPreviewController.shared.copy(from: surface, location: location)
        }
    }
}
