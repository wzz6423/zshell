import AppKit

@MainActor
final class QuickCommandInvocation {
    private weak var session: TerminalSession?
    private weak var originWindow: NSWindow?
    private let surfaceID: ObjectIdentifier
    private let hostManagerID: ObjectIdentifier?
    private let projectID: UUID?
    private let tabID: UUID?
    private let paneID: UUID?
    private let shellIdentity: ZshellAgentProcessIdentity?
    private let inputGeneration: UInt64
    private var consumed = false

    init(session: TerminalSession) {
        self.session = session
        originWindow = session.surface.window
        surfaceID = ObjectIdentifier(session.surface)
        hostManagerID = session.hostManagerID
        let context = ZshellAutomationRouter.context(forSession: session.id)
        projectID = context?.project.id
        tabID = context?.tab.id
        paneID = context?.pane.id
        shellIdentity = session.shellPid.flatMap(ZshellAgentProcessIdentity.init(pid:))
        inputGeneration = session.surface.inputGeneration
    }

    var unavailableReason: String? {
        guard !consumed, let session, !session.isTerminating, !session.hasExited, let shellIdentity, shellIdentity.isAlive,
            session.shellPid == shellIdentity.pid,
            ObjectIdentifier(session.surface) == surfaceID,
            session.hostManagerID == hostManagerID,
            let originWindow, session.surface.window === originWindow
        else { return String(localized: "This terminal changed or closed. Reopen the quick command.") }
        guard !session.isReadOnly, session.surface.inputGeneration == inputGeneration else {
            return String(localized: "This terminal is read only or its lock changed. Reopen the quick command after unlocking.")
        }
        if let projectID {
            guard let context = ZshellAutomationRouter.context(forSession: session.id),
                context.session === session, session.belongs(to: context.manager),
                context.project.id == projectID, context.tab.id == tabID, context.pane.id == paneID,
                context.manager.selectedProjectID == projectID, context.project.selectedTabID == tabID,
                context.tab.focusedPaneID == paneID
            else { return String(localized: "The selected project or pane changed. Reopen the quick command.") }
        } else if session.hostManagerID != nil {
            return String(localized: "This terminal changed or closed. Reopen the quick command.")
        }
        guard session.remoteConnection == nil, session.isShellAvailableForAutomation,
            session.terminalPromptQueueIsReady,
            !TerminalCommandTaskStore.shared.hasActiveTask(terminalID: session.id),
            session.promptQueue.commands.isEmpty
        else {
            return String(localized: "Use an empty prompt in the original zsh terminal with no queued or running task.")
        }
        return nil
    }

    @discardableResult
    func send(_ command: String, run: Bool) -> Bool {
        guard unavailableReason == nil, QuickCommandTemplate.isSingleLine(command), let session else { return false }
        consumed = true
        session.cancelPromptQueueDispatch()
        guard session.sendCommand(command, asPaste: true) else { return false }
        return !run || session.sendEnter()
    }
}

@MainActor
final class QuickCommandInvocationWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let preset: QuickCommandPreset
    private let invocation: QuickCommandInvocation
    private let run: Bool
    private let preview = NSTextView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()
    private var fields: [String: NSControl] = [:]
    private var readinessTimer: Timer?
    private var didSend = false
    private var valueError: String?
    private var parentCloseObserver: NSObjectProtocol?
    private var isDismissed = false

    init(preset: QuickCommandPreset, session: TerminalSession, run: Bool) {
        self.preset = preset
        invocation = QuickCommandInvocation(session: session)
        self.run = run
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = preset.name
        window.identifier = NSUserInterfaceItemIdentifier("quick-command-preview")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 540, height: 360)
        super.init(window: window)
        window.delegate = self
        configureContent()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(relativeTo parent: NSWindow?) {
        // Parameter previews must remain attached to their exact originating
        // terminal window; the generic host fallback could choose another one.
        guard let parent, let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window)
        parentCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: parent, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        readinessTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshReadiness() }
        }
        readinessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        if let first = preset.parameters.first, let field = fields[first.name] {
            window.makeFirstResponder(field)
        }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            window?.selectNextKeyView(control)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        dismiss()
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let parameters = NSStackView()
        parameters.orientation = .vertical
        parameters.alignment = .width
        parameters.spacing = 8
        for parameter in preset.parameters {
            let label = NSTextField(labelWithString: parameter.name)
            let input: NSControl
            if parameter.kind == .dropdown {
                let picker = NSPopUpButton()
                picker.addItems(withTitles: parameter.choices)
                picker.selectItem(at: parameter.choices.firstIndex(of: parameter.defaultValue) ?? -1)
                picker.target = self
                picker.action = #selector(valueChanged)
                input = picker
            } else {
                let field = NSTextField(string: parameter.defaultValue)
                field.delegate = self
                input = field
            }
            input.identifier = NSUserInterfaceItemIdentifier("quick-command-value-" + parameter.name)
            input.setAccessibilityLabel(parameter.name)
            input.setContentHuggingPriority(.defaultLow, for: .horizontal)
            fields[parameter.name] = input
            let row = NSStackView(views: [label, input])
            row.spacing = 12
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            parameters.addArrangedSubview(row)
        }
        let parameterScroll = NSScrollView()
        parameterScroll.hasVerticalScroller = true
        parameterScroll.documentView = parameters
        parameters.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            parameters.leadingAnchor.constraint(equalTo: parameterScroll.contentView.leadingAnchor),
            parameters.topAnchor.constraint(equalTo: parameterScroll.contentView.topAnchor),
            parameters.widthAnchor.constraint(equalTo: parameterScroll.contentView.widthAnchor),
        ])
        parameterScroll.translatesAutoresizingMaskIntoConstraints = false
        parameterScroll.heightAnchor.constraint(equalToConstant: min(CGFloat(preset.parameters.count) * 34, 170)).isActive = true

        let previewLabel = NSTextField(labelWithString: String(localized: "Command Preview"))
        previewLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        preview.identifier = NSUserInterfaceItemIdentifier("quick-command-preview-text")
        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = false
        preview.textContainer?.widthTracksTextView = true
        preview.textContainerInset = NSSize(width: 8, height: 6)
        preview.setAccessibilityLabel(String(localized: "Command Preview"))
        let previewScroll = NSScrollView()
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .bezelBorder
        errorLabel.identifier = NSUserInterfaceItemIdentifier("quick-command-preview-error")
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        actionButton.title = run ? String(localized: "Run Command") : String(localized: "Insert into Terminal")
        actionButton.identifier = NSUserInterfaceItemIdentifier("quick-command-preview-send")
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(submit)
        // Return belongs to parameter editing; execution requires this action.
        actionButton.keyEquivalent = ""
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
        cancel.identifier = NSUserInterfaceItemIdentifier("quick-command-preview-cancel")
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [NSView(), cancel, actionButton])
        footer.spacing = 8
        for view in [parameterScroll, previewLabel, previewScroll, errorLabel, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            parameterScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            parameterScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            parameterScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            previewLabel.leadingAnchor.constraint(equalTo: parameterScroll.leadingAnchor),
            previewLabel.topAnchor.constraint(equalTo: parameterScroll.bottomAnchor, constant: 14),
            previewScroll.leadingAnchor.constraint(equalTo: parameterScroll.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: parameterScroll.trailingAnchor),
            previewScroll.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 6),
            previewScroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -10),
            previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            errorLabel.leadingAnchor.constraint(equalTo: parameterScroll.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: parameterScroll.trailingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: parameterScroll.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: parameterScroll.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func values() -> [String: String] {
        var result: [String: String] = [:]
        for parameter in preset.parameters {
            guard let field = fields[parameter.name] else { continue }
            if let picker = field as? NSPopUpButton {
                let index = picker.indexOfSelectedItem
                result[parameter.name] = parameter.choices.indices.contains(index) ? parameter.choices[index] : ""
            } else {
                result[parameter.name] = field.stringValue
            }
        }
        return result
    }

    private func refresh() {
        do {
            preview.string = try preset.resolvedCommand(values: values())
            valueError = nil
        } catch {
            preview.string = ""
            valueError = error.localizedDescription
        }
        refreshReadiness()
    }

    private func refreshReadiness() {
        guard !didSend else { return }
        errorLabel.stringValue = valueError ?? invocation.unavailableReason ?? ""
        actionButton.isEnabled = errorLabel.stringValue.isEmpty
    }

    @objc private func valueChanged() { refresh() }

    @objc private func submit() {
        guard !didSend else { return }
        do {
            let command = try preset.resolvedCommand(values: values())
            guard command == preview.string else { refresh(); return }
            guard invocation.unavailableReason == nil else { refresh(); return }
            didSend = true
            guard invocation.send(command, run: run) else {
                errorLabel.stringValue = String(localized: "The terminal could not accept this command. Reopen the quick command.")
                actionButton.isEnabled = false
                return
            }
            dismiss()
        } catch {
            refresh()
        }
    }

    @objc private func cancel() { dismiss() }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        readinessTimer?.invalidate()
        readinessTimer = nil
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        parentCloseObserver = nil
        if let window {
            if let parent = window.sheetParent { parent.endSheet(window) } else { close() }
            window.orderOut(nil)
        }
        let completion = onClose
        onClose = nil
        completion?()
    }
}
