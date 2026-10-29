import AppKit

@MainActor
final class WorkspaceTemplateEditorController: NSObject {
    private let entry: WorkspaceTemplateStore.Entry
    private let store: WorkspaceTemplateStore
    private let panel: NSPanel
    private let textView = NSTextView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    private let cancelButton = NSButton()
    private var localizationObservation: NSObjectProtocol?

    init(entry: WorkspaceTemplateStore.Entry, store: WorkspaceTemplateStore) {
        self.entry = entry
        self.store = store
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 540, height: 400)
        panel.identifier = NSUserInterfaceItemIdentifier("workspace-template-editor")
        guard let content = panel.contentView else { return }
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.string = (try? entry.template.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        for (button, action) in [(saveButton, #selector(save(_:))), (cancelButton, #selector(cancel(_:)))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        cancelButton.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [NSView(), cancelButton, saveButton])
        actions.spacing = 8
        for view in [noticeLabel, scroll, errorLabel, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16).isActive = true
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16).isActive = true
        }
        NSLayoutConstraint.activate([
            noticeLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: noticeLabel.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -8),
            errorLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            errorLabel.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        localizationObservation = NotificationCenter.default.addObserver(forName: AppLocalization.didChange, object: nil, queue: .main) {
            [weak self] _ in assumeMainActor { self?.localize() }
        }
        localize()
    }

    deinit {
        if let localizationObservation { NotificationCenter.default.removeObserver(localizationObservation) }
    }

    func show(on host: NSWindow) {
        AppWindowPresentation.presentSheet(panel, on: host)
        panel.makeFirstResponder(textView)
    }

    func close() {
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
    }

    private func localize() {
        panel.title = String(localized: "Edit Workspace Template")
        noticeLabel.stringValue = String(localized: "Edit directories, startup commands, browser URLs and split fractions in JSON. Saving validates the template and does not run commands.")
        textView.setAccessibilityLabel(String(localized: "Workspace Template JSON"))
        saveButton.title = String(localized: "Save")
        cancelButton.title = String(localized: "Cancel")
    }

    @objc private func save(_ sender: Any?) {
        do {
            let template = try WorkspaceTemplate.decode(Data(textView.string.utf8))
            try store.update(entry.id, template: template)
            cancel(sender)
        } catch { errorLabel.stringValue = error.localizedDescription }
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }
}
