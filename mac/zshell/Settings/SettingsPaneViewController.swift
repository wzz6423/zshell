//
//  SettingsPaneViewController.swift
//  zshell
//

import AppKit
import Combine

/// One category of settings, scrolling inside the detail side of the settings
/// window.
///
/// Subclasses describe themselves as groups of rows in ``makeGroups()`` and
/// refresh their controls in ``syncFromSettings()``; the base class owns the
/// scroller and the `AppSettings` subscription, so every category stays in step
/// with a change made anywhere else — the command palette, a live config
/// reload, or another pane.
class SettingsPaneViewController: NSViewController {
    let settings = AppSettings.shared

    private let groupStack = NSStackView()
    private var observations: Set<AnyCancellable> = []

    override func loadView() {
        let content = SettingsPaneContentView()
        content.translatesAutoresizingMaskIntoConstraints = false

        groupStack.orientation = .vertical
        groupStack.alignment = .leading
        groupStack.spacing = SettingsMetrics.groupSpacing
        groupStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(groupStack)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            groupStack.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: SettingsMetrics.paneInset
            ),
            groupStack.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -SettingsMetrics.paneInset
            ),
            groupStack.topAnchor.constraint(
                equalTo: content.topAnchor,
                constant: SettingsMetrics.paneInset
            ),
            groupStack.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                constant: -SettingsMetrics.paneInset
            ),
        ])

        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for group in makeGroups() {
            groupStack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: groupStack.widthAnchor).isActive = true
        }
        syncFromSettings()
        // `@Published` fires from `willSet`, so the new value is only readable
        // one main-queue hop later.
        AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncFromSettings() }
            .store(in: &observations)
    }

    /// The groups this pane shows, top to bottom. Called once, after the view
    /// loads.
    func makeGroups() -> [NSView] { [] }

    /// Pushes the stored settings into this pane's controls. Programmatic
    /// updates don't fire target/action, so this can't loop back.
    func syncFromSettings() {}

    /// Keeps a subscription alive for the pane's lifetime, for panes that watch
    /// something besides `AppSettings`.
    func observe(_ cancellable: AnyCancellable) {
        cancellable.store(in: &observations)
    }
}

/// The scrolled content. Flipped so the groups stack from the top down.
private final class SettingsPaneContentView: NSView {
    override var isFlipped: Bool { true }
}
