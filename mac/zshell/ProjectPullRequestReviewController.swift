import AppKit
import Combine

@MainActor
final class ProjectPullRequestReviewController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private weak var diff: DiffTab?
    private var target: ProjectPullRequestReviewTarget
    private var threadID: String?
    private var access: ProjectPullRequestReviewAccess?
    private var loading = false
    private var writing = false
    private var uncertain = false
    private var generation: UInt = 0
    private var feedback = Feedback.none
    private var observations: [AnyCancellable] = []
    private let heading = NSTextField(labelWithString: "")
    private let discussion = NSTextView()
    private let discussionScroll = NSScrollView()
    private let editor = NSTextView()
    private let editorScroll = NSScrollView()
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let reviewPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let githubButton = NSButton(title: "", target: nil, action: nil)
    private let resolveButton = NSButton(title: "", target: nil, action: nil)
    private let submitButton = NSButton(title: "", target: nil, action: nil)
    private let reviewEvents: [ProjectPullRequestReviewAction.Review] = [.comment, .approve, .requestChanges]
    private var selectedReview: ProjectPullRequestReviewAction.Review { reviewEvents[max(0, reviewPicker.indexOfSelectedItem)] }
    private var isCurrent: Bool {
        diff?.currentPullRequestIdentity == target.identity
            && (diff?.pullRequestReviewState.readyFile.map(ProjectPullRequestReviewTarget.init)) == target
    }

    private enum Feedback {
        case none, loading, submitting, submitted, failure(ProjectPullRequestReviewActionError)

        var message: String {
            switch self {
            case .none: ""
            case .loading: String(localized: "Loading PR comments…")
            case .submitting: String(localized: "Submitting…")
            case .submitted: String(localized: "Review action submitted.")
            case .failure(let error): error.message
            }
        }
    }

    init(diff: DiffTab, file: ProjectPullRequestReviewFile, threadID: String?) {
        self.diff = diff
        target = ProjectPullRequestReviewTarget(file)
        self.threadID = threadID
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.minSize = NSSize(width: 430, height: 330)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        makeContent()
        observations = [
            diff.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshControls() } },
            diff.pullRequest.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshControls() } },
            NotificationCenter.default.publisher(for: AppLocalization.didChange).sink { [weak self] _ in self?.localize() },
        ]
        localize()
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(from source: NSWindow?) {
        guard let window else { return }
        if let source { window.setFrameOrigin(NSPoint(x: source.frame.midX - window.frame.width / 2, y: source.frame.midY - window.frame.height / 2)) }
        else { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
    }

    func select(file: ProjectPullRequestReviewFile, threadID: String?) {
        guard !writing else { window?.makeKeyAndOrderFront(nil); return }
        if self.threadID == threadID, target == ProjectPullRequestReviewTarget(file), window?.isVisible == true { return }
        if !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (self.threadID != threadID || target != ProjectPullRequestReviewTarget(file)) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Discard this unsent comment?")
            alert.addButton(withTitle: String(localized: "Keep Editing"))
            alert.addButton(withTitle: String(localized: "Discard"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        target = ProjectPullRequestReviewTarget(file)
        self.threadID = threadID
        generation &+= 1
        access = nil
        editor.string = ""
        uncertain = false
        reviewPicker.selectItem(at: 0)
        localize()
        load()
    }

    private func makeContent() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.maximumNumberOfLines = 0
        stateLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        discussion.isEditable = false
        discussion.isSelectable = true
        discussion.isRichText = false
        discussion.font = .systemFont(ofSize: 12)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 12)
        editor.delegate = self
        for (scroll, text) in [(discussionScroll, discussion), (editorScroll, editor)] {
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.documentView = text
            text.isHorizontallyResizable = false
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        let spacer = NSView()
        let header = NSStackView(views: [heading, spacer, refreshButton, githubButton])
        let footer = NSStackView(views: [resolveButton, NSView(), reviewPicker, submitButton])
        for row in [header, footer] { row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY }
        for button in [refreshButton, githubButton, resolveButton, submitButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        refreshButton.action = #selector(refreshClicked)
        githubButton.action = #selector(openGitHub)
        resolveButton.action = #selector(resolveClicked)
        submitButton.action = #selector(submitClicked)
        reviewPicker.target = self
        reviewPicker.action = #selector(reviewChanged)
        reviewPicker.controlSize = .small
        reviewPicker.menu?.autoenablesItems = false
        for view in [header, discussionScroll, editorScroll, stateLabel, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16).isActive = true
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16).isActive = true
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            discussionScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            discussionScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            editorScroll.topAnchor.constraint(equalTo: discussionScroll.bottomAnchor, constant: 12),
            editorScroll.heightAnchor.constraint(equalToConstant: 110),
            stateLabel.topAnchor.constraint(equalTo: editorScroll.bottomAnchor, constant: 8),
            footer.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func localize() {
        window?.title = String(localized: "Pull Request Review")
        heading.stringValue = "#\(target.identity.number) · \(target.path)"
        refreshButton.title = String(localized: "Refresh")
        githubButton.title = String(localized: "Open on GitHub")
        discussion.setAccessibilityLabel(String(localized: "Review discussion"))
        editor.setAccessibilityLabel(threadID == nil ? String(localized: "Review comment") : String(localized: "Reply"))
        let selected = reviewPicker.indexOfSelectedItem
        reviewPicker.removeAllItems()
        reviewPicker.addItems(withTitles: reviewEvents.map(\.title))
        reviewPicker.selectItem(at: max(0, selected))
        reviewPicker.setAccessibilityLabel(String(localized: "Review decision"))
        renderDiscussion()
        refreshControls()
    }

    private func renderDiscussion() {
        if let thread = access?.thread {
            let title = thread.isResolved ? String(localized: "Resolved") : String(localized: "Unresolved")
            discussion.string = ([title] + thread.comments.nodes.map {
                "\($0.author?.login ?? String(localized: "Deleted user"))\n\($0.body)"
            }).joined(separator: "\n\n")
        } else if threadID == nil {
            discussion.string = String(localized: "Submit your review of this pull request. The review is attached to the displayed commit.")
        } else { discussion.string = "" }
    }

    private func refreshControls() {
        let active = isCurrent && !loading && !writing && !uncertain
        editor.isEditable = !writing
        reviewPicker.isHidden = threadID != nil
        reviewPicker.isEnabled = active && access?.canReview == true
        for (index, event) in reviewEvents.enumerated() where index < reviewPicker.numberOfItems {
            reviewPicker.item(at: index)?.isEnabled = event == .comment ? access?.canReview == true : access?.canApprove == true
        }
        submitButton.title = writing ? String(localized: "Submitting…")
            : threadID == nil ? String(localized: "Submit Review") : String(localized: "Reply")
        submitButton.isEnabled = active && (threadID == nil
            ? (selectedReview == .comment ? access?.canReview == true : access?.canApprove == true)
                && GitHubPullRequestReviewActions.validBody(editor.string, required: selectedReview != .approve)
            : access?.canReply == true && GitHubPullRequestReviewActions.validBody(editor.string, required: true))
        resolveButton.isHidden = threadID == nil
        let resolved = access?.thread?.isResolved == true
        resolveButton.title = resolved ? String(localized: "Reopen Discussion") : String(localized: "Resolve Discussion")
        resolveButton.isEnabled = active && (resolved ? access?.canUnresolve == true : access?.canResolve == true)
        refreshButton.isEnabled = !writing && !loading && isCurrent
        githubButton.isEnabled = !writing
        stateLabel.stringValue = isCurrent ? feedback.message : ProjectPullRequestReviewActionError.changed.message
    }

    private func load() {
        guard isCurrent, !writing else { refreshControls(); return }
        generation &+= 1
        let current = generation, target = target, threadID = threadID
        loading = true
        access = nil
        renderDiscussion()
        feedback = .loading
        refreshControls()
        Task { [weak self] in
            let uncertain = await ProjectPullRequestReviewActionCoordinator.shared.hasUncertainOutcome(target.identity)
            let result = await GitHubPullRequestReviewActions.load(target, threadID: threadID)
            guard let self, self.generation == current else { return }
            self.loading = false
            guard self.isCurrent else { self.refreshControls(); return }
            self.uncertain = uncertain
            switch result {
            case .success(let access):
                self.access = access
                self.feedback = uncertain ? .failure(.outcomeUnknown) : .none
            case .failure(let error): self.feedback = .failure(error)
            }
            self.renderDiscussion()
            self.refreshControls()
        }
    }

    private func perform(_ action: ProjectPullRequestReviewAction) {
        guard isCurrent, !loading, !writing, !uncertain else { return }
        writing = true
        feedback = .submitting
        refreshControls()
        let target = target
        Task { [weak self] in
            let result = await ProjectPullRequestReviewActionCoordinator.shared.perform(target, action: action)
            guard let self else { return }
            self.writing = false
            switch result {
            case .success:
                if case .reply = action { self.editor.string = "" }
                if case .review = action { self.editor.string = "" }
                self.feedback = .submitted
                if case .review = action { self.window?.close() }
                else { self.load() }
                self.diff?.showPullRequestComments(force: true)
            case .failure(let error):
                self.uncertain = error == .outcomeUnknown
                self.feedback = .failure(error)
                self.refreshControls()
            }
        }
    }

    @objc private func refreshClicked() {
        let identity = target.identity
        Task { [weak self] in
            let unknown = await ProjectPullRequestReviewActionCoordinator.shared.hasUncertainOutcome(identity)
            guard let self else { return }
            if unknown {
                let alert = NSAlert()
                alert.messageText = ProjectPullRequestReviewActionError.outcomeUnknown.message
                alert.addButton(withTitle: String(localized: "Cancel"))
                alert.addButton(withTitle: String(localized: "I Checked GitHub"))
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                await ProjectPullRequestReviewActionCoordinator.shared.acknowledgeCheckedOutcome(identity)
                self.uncertain = false
            }
            self.load()
        }
    }

    @objc private func openGitHub() {
        guard let url = URL(string: target.identity.url) else { return }
        let threadURL = (access?.thread?.comments.nodes.first?.url)
            .flatMap { ProjectPullRequestReviewFile.commentURL($0, identity: target.identity) }
        NSWorkspace.shared.open(threadURL ?? url)
    }

    @objc private func submitClicked() {
        guard submitButton.isEnabled else { return }
        if let threadID { perform(.reply(threadID: threadID, body: editor.string)) }
        else { perform(.review(selectedReview, body: editor.string)) }
    }

    @objc private func resolveClicked() {
        guard resolveButton.isEnabled, let threadID else { return }
        perform(.resolve(threadID: threadID, resolved: access?.thread?.isResolved != true))
    }

    @objc private func reviewChanged() { refreshControls() }
    func textDidChange(_ notification: Notification) { refreshControls() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !writing else { return false }
        guard !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard this unsent comment?")
        alert.addButton(withTitle: String(localized: "Keep Editing"))
        alert.addButton(withTitle: String(localized: "Discard"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}

private extension ProjectPullRequestReviewState {
    var readyFile: ProjectPullRequestReviewFile? { if case .ready(let file) = self { file } else { nil } }
}
