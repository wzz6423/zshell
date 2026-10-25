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

    private let categoryTitle = NSTextField(wrappingLabelWithString: "")
    private let groupStack = NSStackView()
    private var category: SettingsCategory?
    private var observations: Set<AnyCancellable> = []

    override func loadView() {
        let content = SettingsPaneContentView()
        content.translatesAutoresizingMaskIntoConstraints = false

        categoryTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        categoryTitle.maximumNumberOfLines = 0
        categoryTitle.stringValue = category?.title ?? ""
        categoryTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        categoryTitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(categoryTitle)

        groupStack.orientation = .vertical
        groupStack.alignment = .leading
        groupStack.spacing = SettingsMetrics.groupSpacing
        groupStack.detachesHiddenViews = true
        groupStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(groupStack)

        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            categoryTitle.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: SettingsMetrics.paneInset
            ),
            categoryTitle.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -SettingsMetrics.paneInset
            ),
            categoryTitle.topAnchor.constraint(
                equalTo: content.topAnchor,
                constant: SettingsMetrics.paneInset
            ),
            groupStack.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: SettingsMetrics.paneInset
            ),
            groupStack.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -SettingsMetrics.paneInset
            ),
            groupStack.topAnchor.constraint(
                equalTo: categoryTitle.bottomAnchor,
                constant: SettingsMetrics.groupSpacing
            ),
            groupStack.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                constant: -SettingsMetrics.paneInset
            ),
        ])

        view = scroll
    }

    func setCategory(_ category: SettingsCategory) {
        self.category = category
        if isViewLoaded {
            categoryTitle.stringValue = category.title
        }
    }

    @discardableResult
    func revealSearchResult(_ title: String, in section: String? = nil) -> Bool {
        guard let scroll = view as? NSScrollView, let document = scroll.documentView else { return false }
        view.superview?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        let group = section.flatMap { section in
            groupStack.arrangedSubviews.compactMap { $0 as? SettingsGroup }
                .first { $0.headerTitle == section && !$0.isHidden }
        }
        let searchRoot: NSView = group ?? document
        var fallback: NSView?
        func matchingRow(in current: NSView) -> NSView? {
            guard !current.isHidden else { return nil }
            let matchesLabel = (current as? NSTextField).map { !$0.isEditable && $0.stringValue == title } ?? false
            let matchesButton = (current as? NSButton)?.title == title
            if matchesLabel || matchesButton || current.accessibilityLabel() == title {
                var ancestor: NSView? = current
                while let candidate = ancestor, candidate !== document {
                    if candidate is SettingsRow || candidate is SettingsSliderRow
                        || candidate is SettingsCustomRow || candidate is SettingsButtonRow {
                        return candidate
                    }
                    ancestor = candidate.superview
                }
                if fallback == nil { fallback = current }
            }
            for child in current.subviews {
                if let row = matchingRow(in: child) { return row }
            }
            return nil
        }

        guard let target = matchingRow(in: searchRoot) ?? fallback ?? group else { return false }
        let targetRect = target.convert(target.bounds, to: document)
        let clip = scroll.contentView
        // Full-height content scrolls beneath the toolbar; keep the match below it.
        let minY = document.bounds.minY - scroll.contentInsets.top
        let maxY = max(minY, document.bounds.maxY - clip.bounds.height + scroll.contentInsets.bottom)
        let maxX = max(document.bounds.minX, document.bounds.maxX - clip.bounds.width)
        let origin = NSPoint(
            x: min(max(clip.bounds.minX, document.bounds.minX), maxX),
            y: min(max(targetRect.minY - scroll.contentInsets.top - 20, minY), maxY)
        )
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        return true
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
