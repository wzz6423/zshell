//
//  AppKitWorktreeSectionView.swift
//  zshell
//

import AppKit
import SwiftUI

/// Only the mounting boundary is SwiftUI; AppKit owns the header, rows, and
/// bounded scroll viewport, independently of the Git change list below it.
struct GitWorktreeSectionView: NSViewRepresentable {
    let worktrees: [GitStatusModel.Worktree]
    @Binding var isCollapsed: Bool
    let fontScale: CGFloat
    let openWorktree: (String) -> Void

    func makeNSView(context: Context) -> GitWorktreeSectionNSView {
        GitWorktreeSectionNSView(frame: .zero)
    }

    func updateNSView(_ view: GitWorktreeSectionNSView, context: Context) {
        view.apply(worktrees: worktrees, isCollapsed: isCollapsed, fontScale: fontScale,
                   openWorktree: openWorktree, toggleCollapsed: { isCollapsed.toggle() })
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GitWorktreeSectionNSView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 240
        return CGSize(width: width,
               height: GitWorktreeSectionMetrics(fontScale: fontScale)
                .height(count: worktrees.count, collapsed: isCollapsed))
    }
}

struct GitWorktreeSectionMetrics {
    let sidebar: SidebarLayoutMetrics
    init(fontScale: CGFloat) { sidebar = SidebarLayoutMetrics(fontScale: fontScale) }
    var headerHeight: CGFloat {
        sidebar.lineHeight(designedFontSize: 9.5, weight: .medium, minimum: 16) + 11
    }
    var rowHeight: CGFloat {
        sidebar.lineHeight(designedFontSize: 11, weight: .medium, minimum: 14)
            + sidebar.lineHeight(designedFontSize: 9.5, minimum: 12) + 7
    }
    func listHeight(count: Int) -> CGFloat {
        min(CGFloat(max(0, count)) * rowHeight, 160 * sidebar.growthScale)
    }
    func height(count: Int, collapsed: Bool) -> CGFloat {
        count == 0 ? 0 : headerHeight + (collapsed ? 0 : listHeight(count: count))
    }
}

final class GitWorktreeSectionNSView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let header = NSButton(title: String(localized: "WORKTREES"), target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let scrollView = GitWorktreeScrollView()
    private let tableView = RowButtonTableView()
    private var worktrees: [GitStatusModel.Worktree] = []
    private var metrics = GitWorktreeSectionMetrics(fontScale: 1)
    private var isCollapsed = false
    private var openWorktree: ((String) -> Void)?
    private var toggleCollapsed: (() -> Void)?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: metrics.height(count: worktrees.count, collapsed: isCollapsed))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.isBordered = false
        header.alignment = .left
        header.imagePosition = .imageLeading
        header.target = self
        header.action = #selector(toggleSection)
        countLabel.alignment = .right
        countLabel.textColor = .tertiaryLabelColor
        countLabel.setAccessibilityElement(false)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.style = .fullWidth
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(openSelectedWorktree)
        tableView.setAccessibilityLabel(String(localized: "WORKTREES"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("worktree"))
        column.minWidth = 0
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        for view in [header, countLabel, scrollView] { addSubview(view) }
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(
        worktrees: [GitStatusModel.Worktree], isCollapsed: Bool, fontScale: CGFloat,
        openWorktree: @escaping (String) -> Void, toggleCollapsed: @escaping () -> Void
    ) {
        let nextMetrics = GitWorktreeSectionMetrics(fontScale: fontScale)
        let changed = self.worktrees != worktrees || metrics.sidebar.fontScale != nextMetrics.sidebar.fontScale
        let differentRepository = !self.worktrees.isEmpty
            && !worktrees.contains { next in self.worktrees.contains { $0.path == next.path } }
        self.worktrees = worktrees
        self.isCollapsed = isCollapsed
        self.metrics = nextMetrics
        self.openWorktree = openWorktree
        self.toggleCollapsed = toggleCollapsed
        let scale = metrics.sidebar.fontScale
        header.font = .systemFont(ofSize: 9.5 * scale, weight: .medium)
        header.contentTintColor = .secondaryLabelColor
        header.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7 * scale, weight: .semibold))
        header.setAccessibilityLabel(String(localized: "WORKTREES") + ", \(worktrees.count)")
        header.setAccessibilityValue(String(localized: isCollapsed ? "Collapsed" : "Expanded"))
        countLabel.font = .monospacedDigitSystemFont(ofSize: 9 * scale, weight: .medium)
        countLabel.stringValue = String(worktrees.count)
        scrollView.isHidden = isCollapsed || worktrees.isEmpty
        tableView.rowHeight = metrics.rowHeight
        if changed { tableView.reloadData() }
        else { updateVisibleRows() }
        if differentRepository { scrollView.contentView.scroll(to: .zero) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let countWidth = ceil(countLabel.intrinsicContentSize.width)
        let labelHeight = metrics.headerHeight - 11
        header.frame = NSRect(x: 8, y: 8, width: max(0, bounds.width - countWidth - 24), height: labelHeight)
        countLabel.frame = NSRect(x: max(8, bounds.width - countWidth - 8), y: 8,
                                 width: countWidth, height: labelHeight)
        let listHeight = isCollapsed ? 0 : min(
            metrics.listHeight(count: worktrees.count),
            max(0, bounds.height - metrics.headerHeight)
        )
        scrollView.frame = NSRect(x: 0, y: metrics.headerHeight, width: bounds.width, height: listHeight)
        let contentWidth = max(0, scrollView.contentSize.width)
        let contentHeight = max(listHeight, CGFloat(worktrees.count) * metrics.rowHeight)
        tableView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        tableView.tableColumns.first?.width = contentWidth
        // A shorter refreshed list must not leave an empty viewport at the old offset.
        let maximum = max(0, contentHeight - scrollView.contentSize.height)
        let offset = min(max(0, scrollView.contentView.bounds.minY), maximum)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { worktrees.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        GitWorktreeTableRowView(frame: .zero)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("worktreeRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? GitWorktreeRowButton
            ?? GitWorktreeRowButton(frame: .zero)
        cell.identifier = identifier
        configure(cell, row: row)
        return cell
    }

    private func configure(_ cell: GitWorktreeRowButton, row: Int) {
        guard worktrees.indices.contains(row) else { return }
        let worktree = worktrees[row]
        cell.apply(worktree: worktree, metrics: metrics) { [weak self] in
            self?.openWorktree?(worktree.path)
        }
    }

    private func updateVisibleRows() {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound else { return }
        for index in range.location..<NSMaxRange(range) where worktrees.indices.contains(index) {
            if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? GitWorktreeRowButton {
                configure(cell, row: index)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateVisibleRows()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { openSelectedWorktree() }
        else { super.keyDown(with: event) }
    }

    @objc private func toggleSection() { toggleCollapsed?() }

    @objc private func openSelectedWorktree() {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard worktrees.indices.contains(index), !worktrees[index].isBare else { return }
        openWorktree?(worktrees[index].path)
    }
}

/// Consume boundary scrolls here rather than handing them to a parent scroll
/// view, including when a refresh leaves too few rows to need scrolling.
private final class GitWorktreeScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let maximum = max(0, (documentView?.bounds.height ?? 0) - contentSize.height)
        let offset = contentView.bounds.minY
        guard maximum > 0,
              !(offset <= 0 && event.scrollingDeltaY > 0),
              !(offset >= maximum && event.scrollingDeltaY < 0) else { return }
        super.scrollWheel(with: event)
    }
}

private final class GitWorktreeTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // A neutral selection keeps the embedded button labels legible in both appearances.
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}

private final class GitWorktreeRowButton: NSButton {
    private let branchLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(labelWithString: String(localized: "Current"))
    private let folderIcon = NSImageView()
    private let openIcon = NSImageView()
    private var metrics = GitWorktreeSectionMetrics(fontScale: 1)
    private var openWorktree: (() -> Void)?
    private var isHovered = false
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(openClicked)
        for label in [branchLabel, pathLabel, currentLabel] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
        }
        pathLabel.lineBreakMode = .byTruncatingHead
        for view in [branchLabel, pathLabel, currentLabel, folderIcon, openIcon] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(worktree: GitStatusModel.Worktree, metrics: GitWorktreeSectionMetrics, open: @escaping () -> Void) {
        self.metrics = metrics
        openWorktree = open
        let scale = metrics.sidebar.fontScale
        branchLabel.stringValue = worktree.branch ?? String(localized: "Detached HEAD")
        branchLabel.font = .systemFont(ofSize: 11 * scale, weight: .medium)
        branchLabel.textColor = .labelColor
        pathLabel.stringValue = worktree.path
        pathLabel.font = .systemFont(ofSize: 9.5 * scale)
        pathLabel.textColor = .secondaryLabelColor
        currentLabel.font = .systemFont(ofSize: 8.5 * scale, weight: .medium)
        currentLabel.textColor = Theme.accent
        currentLabel.isHidden = !worktree.isCurrent
        folderIcon.image = NSImage(systemSymbolName: worktree.isBare ? "archivebox" : "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11 * scale, weight: .medium))
        folderIcon.contentTintColor = worktree.isCurrent ? Theme.accent : .secondaryLabelColor
        openIcon.image = NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9 * scale, weight: .medium))
        openIcon.contentTintColor = .tertiaryLabelColor
        isEnabled = !worktree.isBare
        alphaValue = worktree.isBare ? 0.55 : 1
        toolTip = worktree.isBare ? String(localized: "Bare repositories do not have a working directory")
            : String(localized: "Open Worktree in New Tab") + "\n" + worktree.path
        setAccessibilityLabel(branchLabel.stringValue + ", " + worktree.path
            + (worktree.isCurrent ? ", " + String(localized: "Current") : ""))
        setAccessibilityHelp(worktree.isBare ? String(localized: "Bare repositories cannot be opened in a terminal tab")
            : String(localized: "Opens a new terminal tab in this worktree"))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let iconSize = metrics.sidebar.iconSize(14)
        let leading = 8 + iconSize + 7
        let available = max(0, bounds.width - leading - iconSize - 16)
        let titleHeight = metrics.sidebar.lineHeight(designedFontSize: 11, weight: .medium, minimum: 14)
        let pathHeight = metrics.sidebar.lineHeight(designedFontSize: 9.5, minimum: 12)
        let top = (bounds.height - titleHeight - pathHeight - 1) / 2
        let currentWidth = currentLabel.isHidden ? 0 : min(available, ceil(currentLabel.intrinsicContentSize.width))
        let branchWidth = max(0, available - currentWidth - (currentWidth > 0 ? 5 : 0))
        folderIcon.frame = NSRect(x: 8, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        branchLabel.frame = NSRect(x: leading, y: top, width: branchWidth, height: titleHeight)
        currentLabel.frame = NSRect(x: leading + available - currentWidth, y: top, width: currentWidth, height: titleHeight)
        pathLabel.frame = NSRect(x: leading, y: top + titleHeight + 1, width: available, height: pathHeight)
        openIcon.frame = NSRect(x: bounds.width - iconSize - 8, y: (bounds.height - iconSize) / 2,
                               width: iconSize, height: iconSize)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (isHovered || isHighlighted) {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.09 : 0.05).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
    @objc private func openClicked() { if isEnabled { openWorktree?() } }
}
