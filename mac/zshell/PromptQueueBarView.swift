//
//  PromptQueueBarView.swift
//  zshell
//

import AppKit
import Combine

/// Pane-bottom bar for one session's prompt queue (⌘⇧M). Pure AppKit: it
/// composes and drains text destined for the terminal's next prompt, so it
/// owns its input handling directly rather than through a SwiftUI layer.
///
/// The bar docks instead of floating — the terminal grid gives up the bar's
/// height rather than the bar covering the prompt area. The terminal's bottom
/// edge is pinned to this bar's top edge by `TerminalHostView`, and the bar
/// drives its own height constraint between 0 (closed) and the fitted height.
/// Height changes are applied without animation: the surface reflows its grid
/// on every step, and the find bar sets the precedent of appearing plainly.
final class PromptQueueBarView: NSView {
    private enum Metrics {
        static let padding: CGFloat = 8
        static let horizontalPadding: CGFloat = 10
        static let inputRowHeight: CGFloat = 25
        static let sectionSpacing: CGFloat = 6
        static let countLabelHeight: CGFloat = 14
        static let itemRowHeight: CGFloat = 22
        static let itemSpacing: CGFloat = 2
        static let maxListHeight: CGFloat = 118
        static let fieldMinWidth: CGFloat = 120
    }

    private var queue: TerminalPromptQueue?
    private weak var session: TerminalSession?

    /// 0 while the bar is closed, the fitted height while open. Owned by the
    /// bar so presentation survives the pane being parked and remounted.
    private lazy var heightConstraint =
        heightAnchor.constraint(equalToConstant: 0)
    private lazy var listHeightConstraint =
        listScroll.heightAnchor.constraint(equalToConstant: 0)

    /// Wired by TerminalHostView so a height change re-lays-out the pane in
    /// the same frame. Cleared again when the host is dismantled.
    var onLayoutChange: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    /// Guards the deferred field focus so it is dropped when the bar closes
    /// before the tick runs.
    private var focusFieldOnNextTick = false

    private let inputField = NSTextField(string: "")
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let listScroll = NSScrollView()
    private let listStack = NSStackView()
    private let inputRow = NSStackView(views: [])
    private let contentStack = NSStackView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Wires the bar to its model. Called once from the owning session's
    /// init, after the bar's view tree exists.
    func attach(queue: TerminalPromptQueue, session: TerminalSession) {
        self.queue = queue
        self.session = session
        queue.$isPresented
            .removeDuplicates()
            .sink { [weak self] presented in
                // A genuine open/close transition; a remounting pane must not
                // yank keyboard focus into the bar.
                self?.applyPresentation(presented, focusFieldOnOpen: true)
            }
            .store(in: &cancellables)
        queue.$commands
            .sink { [weak self] commands in self?.rebuildItems(commands) }
            .store(in: &cancellables)
        applyPresentation(queue.isPresented, focusFieldOnOpen: false)
        rebuildItems(queue.commands)
    }

    // MARK: - View construction

    private func buildView() {
        wantsLayer = true
        // The bar clips its own content while collapsing; it is view-sized
        // and never live-resized the way a masked Metal surface would be.
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityLabel(
            String(localized: "Prompt Queue", comment: "Accessibility label for the prompt queue bar.")
        )
        heightConstraint.isActive = true
        listHeightConstraint.isActive = true

        inputField.placeholderString = String(
            localized: "Add a prompt to run later…",
            comment: "Placeholder of the prompt queue's input field."
        )
        inputField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        inputField.delegate = self
        inputField.target = self
        inputField.action = #selector(addToQueue)
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inputField.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal
        )
        inputField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Metrics.fieldMinWidth
        ).isActive = true

        addButton.title = String(
            localized: "Add to Queue",
            comment: "Prompt queue: queue the typed prompt."
        )
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        addButton.target = self
        addButton.action = #selector(addToQueue)

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: nil
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        // Icon-only control, so it carries its own name (and tooltip).
        closeButton.setAccessibilityLabel(String(
            localized: "Close Prompt Queue",
            comment: "Accessibility label for the prompt queue bar's close button."
        ))
        closeButton.toolTip = closeButton.accessibilityLabel()
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.distribution = .fill
        inputRow.spacing = 6
        inputRow.addArrangedSubview(inputField)
        inputRow.addArrangedSubview(addButton)
        inputRow.addArrangedSubview(closeButton)
        inputRow.heightAnchor.constraint(
            equalToConstant: Metrics.inputRowHeight
        ).isActive = true

        countLabel.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .medium
        )
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal
        )
        // Yielding to the intrinsic height keeps a font-metric surprise from
        // ever breaking a required constraint; the computed bar height
        // absorbs the difference.
        let countHeight = countLabel.heightAnchor.constraint(
            equalToConstant: Metrics.countLabelHeight
        )
        countHeight.priority = .defaultHigh
        countHeight.isActive = true

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = Metrics.itemSpacing
        listStack.translatesAutoresizingMaskIntoConstraints = false

        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listScroll.documentView = listStack
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(
                equalTo: listScroll.contentView.leadingAnchor
            ),
            listStack.trailingAnchor.constraint(
                equalTo: listScroll.contentView.trailingAnchor
            ),
            listStack.topAnchor.constraint(
                equalTo: listScroll.contentView.topAnchor
            ),
            listStack.bottomAnchor.constraint(
                greaterThanOrEqualTo: listScroll.contentView.bottomAnchor
            ),
        ])

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Metrics.sectionSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(inputRow)
        contentStack.addArrangedSubview(countLabel)
        contentStack.addArrangedSubview(listScroll)

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Metrics.horizontalPadding
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Metrics.horizontalPadding
            ),
            contentStack.topAnchor.constraint(
                equalTo: topAnchor, constant: Metrics.padding
            ),
        ])
        // The bar's height is computed from the same metrics; the stack
        // only has to fit inside it, so the bottom edge stays an
        // inequality and a rounding mismatch can never fight a required
        // constraint.
        let contentFits = contentStack.bottomAnchor.constraint(
            lessThanOrEqualTo: bottomAnchor, constant: -Metrics.padding
        )
        contentFits.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentFits,
            inputRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            listScroll.widthAnchor.constraint(
                equalTo: contentStack.widthAnchor
            ),
        ])
    }

    // MARK: - State

    private func applyPresentation(
        _ presented: Bool, focusFieldOnOpen: Bool
    ) {
        heightConstraint.constant = fittedHeight(
            presented: presented, count: queue?.commands.count ?? 0
        )
        isHidden = !presented
        onLayoutChange?()
        if presented, focusFieldOnOpen {
            focusFieldOnNextTick = true
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if presented {
                guard focusFieldOnOpen, self.focusFieldOnNextTick else { return }
                self.focusFieldOnNextTick = false
                self.window?.makeFirstResponder(self.inputField)
            } else {
                // Hand typing back to the terminal on the next tick, once the
                // bar has collapsed — the same sequencing the find bar's
                // restore needs so AppKit cannot resign the field editor
                // afterwards and leave the window without a first responder.
                guard let session = self.session,
                      NSApp.isActive,
                      let window = session.surface.window,
                      window.isKeyWindow,
                      window.firstResponder !== session.surface
                else { return }
                window.makeFirstResponder(session.surface)
            }
        }
    }

    private func rebuildItems(_ commands: [String]) {
        for view in listStack.arrangedSubviews {
            view.removeFromSuperview()
        }
        for (index, command) in commands.enumerated() {
            let row = itemRow(command: command, index: index)
            listStack.addArrangedSubview(row)
            // Activated here rather than in itemRow: the row only gains a
            // common ancestor with the list stack once it is arranged, and
            // activating before that raises.
            // Every row fills the list width, so the two buttons line up in
            // one column across rows of differing text lengths.
            row.widthAnchor.constraint(
                equalTo: listStack.widthAnchor
            ).isActive = true
        }
        countLabel.stringValue = commands.isEmpty
            ? ""
            : String(
                localized: "Queued: \(commands.count)",
                comment: "Prompt queue header. The placeholder is the number of queued prompts."
            )
        countLabel.isHidden = commands.isEmpty
        listScroll.isHidden = commands.isEmpty
        listHeightConstraint.constant = listHeight(for: commands.count)
        heightConstraint.constant = fittedHeight(
            presented: queue?.isPresented == true, count: commands.count
        )
        onLayoutChange?()
    }

    private func listHeight(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return min(
            CGFloat(count) * Metrics.itemRowHeight
                + CGFloat(count - 1) * Metrics.itemSpacing,
            Metrics.maxListHeight
        )
    }

    private func fittedHeight(presented: Bool, count: Int) -> CGFloat {
        guard presented else { return 0 }
        if count == 0 {
            return Metrics.padding * 2 + Metrics.inputRowHeight
        }
        return Metrics.padding * 2 + Metrics.inputRowHeight
            + Metrics.sectionSpacing + Metrics.countLabelHeight
            + Metrics.sectionSpacing + listHeight(for: count)
    }

    /// One queued prompt: the user's own text as a read-only preview, plus
    /// the two actions v1 offers.
    private func itemRow(command: String, index: Int) -> NSView {
        // The preview is the user's own prompt text — content, never a
        // localization lookup key.
        let preview = NSTextField(labelWithString: command)
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.lineBreakMode = .byTruncatingTail
        preview.cell?.truncatesLastVisibleLine = true
        preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal
        )

        let send = NSButton(
            title: String(
                localized: "Send Now",
                comment: "Prompt queue: run a queued prompt immediately."
            ),
            target: self,
            action: #selector(sendNow(_:))
        )
        send.bezelStyle = .rounded
        send.controlSize = .small
        send.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        send.tag = index
        send.setContentCompressionResistancePriority(.required, for: .horizontal)

        let remove = NSButton(
            title: String(
                localized: "Remove",
                comment: "Prompt queue: delete a queued prompt."
            ),
            target: self,
            action: #selector(removePrompt(_:))
        )
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        remove.tag = index
        remove.setContentCompressionResistancePriority(
            .required, for: .horizontal
        )

        let row = NSStackView(views: [preview, send, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.heightAnchor.constraint(
            equalToConstant: Metrics.itemRowHeight
        ).isActive = true
        return row
    }

    // MARK: - Actions

    @objc private func addToQueue() {
        guard let queue else { return }
        let text = inputField.stringValue
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        queue.enqueue(text)
        inputField.stringValue = ""
        // The field keeps focus: queueing is a typing flow, and the next
        // instruction is usually one entry away.
    }

    @objc private func sendNow(_ sender: NSButton) {
        guard let queue, queue.commands.indices.contains(sender.tag) else {
            return
        }
        let command = queue.commands[sender.tag]
        session?.cancelPromptQueueDispatch()
        queue.remove(at: sender.tag)
        session?.sendQueuedPrompt(command)
    }

    @objc private func removePrompt(_ sender: NSButton) {
        queue?.remove(at: sender.tag)
    }

    @objc private func closeClicked() {
        queue?.dismiss()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dynamic theme colors resolve per draw, so a theme switch repaints
        // on the next display cycle without extra bookkeeping.
        Theme.background.setFill()
        dirtyRect.fill()
        // Hairline against the terminal above, the same divider the sidebars
        // draw. Flipped, so the pane's top edge is y = 0.
        Theme.divider.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension PromptQueueBarView: NSTextFieldDelegate {
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        // Esc closes the bar and keeps the queue — the find bar's contract.
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        queue?.dismiss()
        return true
    }
}
