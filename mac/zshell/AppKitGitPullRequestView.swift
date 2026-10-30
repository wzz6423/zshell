//
//  AppKitGitPullRequestView.swift
//  zshell
//

import AppKit
import Combine
import SwiftUI

/// The current branch's pull request in the local Git panel. Clicking opens
/// it; a failed or empty lookup retries instead.
final class GitPullRequestBarView: NSView {
    var onHeightChanged: (() -> Void)?
    let button = WorkspaceChromeButton(symbol: "arrow.triangle.pull", label: "")
    private let model = ProjectPullRequestModel()
    private var observations: [AnyCancellable] = []
    private var fontScale: CGFloat = 1
    private var directory: String?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        addSubview(button)
        let refresh = NSMenuItem(title: String(localized: "Refresh Pull Request Status"),
                                 action: #selector(refreshStatus), keyEquivalent: "")
        refresh.target = self
        menu = NSMenu()
        menu?.addItem(refresh)
        button.menu = menu
        observations = [
            model.$state.removeDuplicates().sink { [weak self] _ in
                // `@Published` fires before the stored value changes.
                DispatchQueue.main.async { self?.apply() }
            },
            NotificationCenter.default.publisher(for: AppLocalization.didChange)
                .sink { [weak self] _ in self?.apply() },
            // An idle Git panel does not poll, so a PR merged or closed
            // remotely would otherwise keep its old status; the model only
            // queries GitHub again once its last lookup is a minute old.
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in
                    guard let self, self.window != nil, self.directory != nil else { return }
                    self.model.sync(directory: self.directory)
                },
        ]
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(directory: String?, fontScale: CGFloat) {
        if self.fontScale != fontScale {
            self.fontScale = fontScale
            apply()
        }
        self.directory = directory
        model.sync(directory: directory)
    }

    func detach() {
        directory = nil
        model.detach()
    }

    @objc func refreshStatus() { model.refresh() }

    private func apply() {
        let state = model.state
        button.configure(symbol: "arrow.triangle.pull", label: state.help, pointSize: 9.5 * fontScale)
        button.font = .systemFont(ofSize: 9.5 * fontScale)
        button.title = state.label
        switch state {
        case .pullRequest:
            button.onAction = { [weak model] in model?.open { NSWorkspace.shared.open($0) } }
        case .failed, .none:
            button.onAction = { [weak model] in model?.refresh() }
        case .hidden, .loading:
            button.onAction = nil
        }
        button.isEnabled = button.onAction != nil
        isHidden = state == .hidden
        invalidateIntrinsicContentSize()
        needsLayout = true
        onHeightChanged?()
    }

    override var intrinsicContentSize: NSSize {
        // Includes the gap the tracking strip above leaves before the next section.
        NSSize(width: NSView.noIntrinsicMetric, height: model.state == .hidden ? 0 : ceil(17 * max(1, fontScale)) + 6)
    }

    override func layout() {
        super.layout()
        let width = min(bounds.width - 24, ceil(button.intrinsicContentSize.width))
        button.frame = NSRect(x: 12, y: 0, width: max(0, width), height: max(0, bounds.height - 6))
    }
}

struct GitPullRequestBar: NSViewRepresentable {
    let directory: String
    let fontScale: CGFloat

    func makeNSView(context: Context) -> GitPullRequestBarView { GitPullRequestBarView() }

    func updateNSView(_ view: GitPullRequestBarView, context: Context) {
        view.update(directory: directory.isEmpty ? nil : directory, fontScale: fontScale)
    }

    static func dismantleNSView(_ view: GitPullRequestBarView, coordinator: ()) { view.detach() }
}
