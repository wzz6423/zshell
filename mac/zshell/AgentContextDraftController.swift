import AppKit
import Combine

@MainActor
final class AgentContextDraftController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let shared = AgentContextDraftController()
    private(set) var panel: NSPanel?
    let editor = NSTextView()
    private let projectLabel = NSTextField(labelWithString: "")
    private let sourceLabel = NSTextField(wrappingLabelWithString: "")
    private let targetLabel = NSTextField(labelWithString: "")
    private let targetPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private let focusButton = NSButton()
    private let closeButton = NSButton()
    private weak var project: Project?
    private weak var manager: TerminalManager?
    private weak var previousWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    private var targets: [AgentContextDraftTarget] = []
    private var observations: [AnyCancellable] = []
    private var localizationObservation: AnyCancellable?
    private var hostCloseObservation: AnyCancellable?
    private var readOnlyObservation: AnyCancellable?
    private var reloadScheduled = false
    private var restoresFocus = true
    private var error: String?

    override init() {
        super.init()
        localizationObservation = NotificationCenter.default.publisher(for: AppLocalization.didChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.localize() }
        readOnlyObservation = NotificationCenter.default.publisher(for: TerminalReadOnlyController.didChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleReload() }
    }

    func show(for project: Project, manager: TerminalManager, error: String? = nil) {
        guard manager.projects.contains(where: { $0 === project }),
            let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow)
        else { return }
        if panel == nil { configure() }
        guard let panel else { return }
        if self.project !== project || !panel.isVisible {
            if panel.isVisible { close(restoreFocus: false) }
            self.project = project
            self.manager = manager
            previousWindow = host
            previousResponder = host.firstResponder
            observations = [project.objectWillChange, manager.objectWillChange].map { publisher in
                publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleReload() }
            }
            hostCloseObservation = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: host)
                .sink { [weak self] _ in self?.close(restoreFocus: false) }
        }
        self.error = error
        // The shared editor's undo stack cannot carry another project's text
        // into the newly bound draft. Appending also starts a new undo history.
        editor.undoManager?.removeAllActions()
        editor.string = project.agentContextDraft.text
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        localize()
        reload()
        AppWindowPresentation.attach(panel, to: host, placement: .centered)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
    }

    func show(in manager: TerminalManager) {
        if let project = manager.selectedProject { show(for: project, manager: manager) }
    }

    func close(restoreFocus: Bool = true) {
        restoresFocus = restoreFocus
        panel?.close()
        restoresFocus = true
    }

    func windowWillClose(_ notification: Notification) {
        if let panel { AppWindowPresentation.hideChild(panel) }
        if restoresFocus, let window = previousWindow, let responder = previousResponder,
            let view = responder as? NSView, view.window === window, !view.isHiddenOrHasHiddenAncestor
        {
            window.makeFirstResponder(responder)
        }
        observations.removeAll()
        hostCloseObservation = nil
        project = nil
        manager = nil
        previousWindow = nil
        previousResponder = nil
        editor.undoManager?.removeAllActions()
        editor.string = ""
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let text = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
        guard text.utf8.count <= AgentContextDraft.maximumBytes else {
            error = String(localized: "The draft can hold 256 KiB and 64 sources. Remove text before adding more.")
            updateActions()
            return false
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard let project else { return }
        _ = project.agentContextDraft.edit(editor.string)
        error = nil
        updateSources()
        updateActions()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }

    @objc func copyDraft(_ sender: Any?) {
        guard let draft = project?.agentContextDraft else { return }
        error = draft.copy(to: .general) ? nil : String(localized: "The draft could not be copied.")
        updateActions()
    }

    @objc func focusAgent(_ sender: Any?) {
        guard let project, let target = project.agentContextDraft.target,
            let context = target.context(in: project), let session = context.session,
            let window = context.manager.presentationWindow
        else {
            error = String(localized: "The selected agent exited, changed identity, or moved to another project. Choose an active agent.")
            updateActions()
            return
        }
        close(restoreFocus: false)
        context.manager.revealSession(session)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            guard let current = target.context(in: project), current.session === session,
                current.manager.selectedProjectID == project.id,
                current.tab.focusedPaneID == current.pane.id, session.surface.window === window
            else { return }
            window.makeFirstResponder(session.surface)
        }
    }

    @objc private func targetChanged(_ sender: Any?) {
        guard let project else { return }
        project.agentContextDraft.target = targetPicker.selectedItem?.representedObject as? AgentContextDraftTarget
        error = nil
        updateActions()
    }

    @objc private func dismiss(_ sender: Any?) { close() }

    private func scheduleReload() {
        guard panel?.isVisible == true, !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    func reload() {
        guard let project, let manager else { return }
        let candidates = manager.projects.contains(where: { $0 === project })
            ? ZshellAutomationRouter.projectContexts(project, manager: manager).compactMap(AgentContextDraftTarget.init) : []
        if project.agentContextDraft.target == nil { project.agentContextDraft.target = candidates.first }
        let selected = project.agentContextDraft.target
        targets = candidates
        targetPicker.removeAllItems()
        if let selected, !candidates.contains(selected) {
            targetPicker.addItem(withTitle: selected.name)
            targetPicker.lastItem?.representedObject = selected
        }
        for target in candidates {
            targetPicker.addItem(withTitle: target.name)
            targetPicker.lastItem?.representedObject = target
        }
        if targetPicker.numberOfItems == 0 { targetPicker.addItem(withTitle: String(localized: "No active agents in this project")) }
        if let selected, let item = targetPicker.itemArray.first(where: { ($0.representedObject as? AgentContextDraftTarget) == selected }) {
            targetPicker.select(item)
        }
        targetPicker.isEnabled = !candidates.isEmpty
        projectLabel.stringValue = project.name
        updateSources()
        updateActions()
    }

    private func updateSources() {
        guard let draft = project?.agentContextDraft else { return }
        sourceLabel.stringValue = draft.sources.suffix(4).map(\.label).joined(separator: "\n")
        sourceLabel.toolTip = draft.sources.map(\.label).joined(separator: "\n")
        sourceLabel.isHidden = draft.sources.isEmpty
    }

    private func updateActions() {
        guard let project else { return }
        let draft = project.agentContextDraft
        let context = draft.target?.context(in: project)
        copyButton.isEnabled = !draft.text.isEmpty
        focusButton.isEnabled = context != nil
        if let session = context?.session, let status = session.agentStatus {
            let phase = session.isReadOnly ? String(localized: "Read Only") : status.phase.statusDescription
            statusLabel.stringValue = phase + "\n" + String(localized: "Copy the draft, then focus the agent to review its input and paste manually.")
        } else if draft.target != nil {
            statusLabel.stringValue = String(localized: "The selected agent exited, changed identity, or moved to another project. Choose an active agent.")
        } else {
            statusLabel.stringValue = String(localized: "No active agents in this project")
        }
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
    }

    private func localize() {
        panel?.title = String(localized: "Agent Context Draft")
        targetLabel.stringValue = String(localized: "Local Agent")
        copyButton.title = String(localized: "Copy Draft")
        focusButton.title = String(localized: "Focus Agent")
        closeButton.title = String(localized: "Close")
        editor.setAccessibilityLabel(String(localized: "Agent Context Draft"))
        targetPicker.setAccessibilityLabel(String(localized: "Local Agent"))
        reload()
    }

    private func configure() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 510),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 520, height: 360)
        panel.identifier = .init("agent-context-draft")
        panel.delegate = self
        self.panel = panel
        guard let content = panel.contentView else { return }
        projectLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.maximumNumberOfLines = 4
        sourceLabel.lineBreakMode = .byTruncatingTail
        targetPicker.target = self
        targetPicker.action = #selector(targetChanged(_:))
        targetPicker.identifier = .init("draft-agent")
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.identifier = .init("draft-editor")
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        for (button, action, identifier) in [
            (copyButton, #selector(copyDraft(_:)), "draft-copy"),
            (focusButton, #selector(focusAgent(_:)), "draft-focus"),
            (closeButton, #selector(dismiss(_:)), "draft-close"),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.identifier = .init(identifier)
        }
        closeButton.keyEquivalent = "\u{1b}"
        let targetRow = NSStackView(views: [targetLabel, targetPicker])
        targetRow.orientation = .horizontal
        targetRow.spacing = 8
        targetPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [closeButton, NSView(), focusButton, copyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for child in [projectLabel, sourceLabel, targetRow, scroll, statusLabel, errorLabel, buttons] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            projectLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            projectLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            projectLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            sourceLabel.leadingAnchor.constraint(equalTo: projectLabel.leadingAnchor),
            sourceLabel.trailingAnchor.constraint(equalTo: projectLabel.trailingAnchor),
            sourceLabel.topAnchor.constraint(equalTo: projectLabel.bottomAnchor, constant: 6),
            targetRow.leadingAnchor.constraint(equalTo: projectLabel.leadingAnchor),
            targetRow.trailingAnchor.constraint(equalTo: projectLabel.trailingAnchor),
            targetRow.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: projectLabel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: projectLabel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: targetRow.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
            statusLabel.leadingAnchor.constraint(equalTo: projectLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: projectLabel.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -6),
            errorLabel.leadingAnchor.constraint(equalTo: projectLabel.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: projectLabel.trailingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: projectLabel.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: projectLabel.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }
}
