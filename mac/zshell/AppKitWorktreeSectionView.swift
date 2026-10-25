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
    let createWorktree: () -> Void
    let removeWorktree: (GitStatusModel.Worktree) -> Void
    let deleteBranch: (String) -> Void
    var isBusy = false

    func makeNSView(context: Context) -> GitRepositorySectionNSView {
        GitRepositorySectionNSView(frame: .zero)
    }

    func updateNSView(_ view: GitRepositorySectionNSView, context: Context) {
        view.apply(worktrees: worktrees, isCollapsed: isCollapsed, fontScale: fontScale,
                   openWorktree: openWorktree, createWorktree: createWorktree,
                   removeWorktree: removeWorktree, deleteBranch: deleteBranch,
                   toggleCollapsed: { isCollapsed.toggle() }, isBusy: isBusy)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GitRepositorySectionNSView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 240
        return CGSize(width: width,
               height: GitRepositorySectionMetrics(fontScale: fontScale)
                .height(count: worktrees.count, collapsed: isCollapsed))
    }
}

struct GitBranchesSectionView: NSViewRepresentable {
    let branches: [String]
    @Binding var isCollapsed: Bool
    let fontScale: CGFloat
    let repositoryID: String
    let isBusy: Bool
    let switchBranch: (String) -> Void
    let createBranch: (NSWindow?) -> Void
    let createWorktree: (String) -> Void
    let deleteBranch: (String) -> Void

    func makeNSView(context: Context) -> GitRepositorySectionNSView {
        GitRepositorySectionNSView(frame: .zero)
    }

    func updateNSView(_ view: GitRepositorySectionNSView, context: Context) {
        view.apply(branches: branches, isCollapsed: isCollapsed, fontScale: fontScale,
                   repositoryID: repositoryID, isBusy: isBusy, switchBranch: switchBranch,
                   createBranch: { [weak view] in createBranch(view?.window) }, createWorktree: createWorktree,
                   deleteBranch: deleteBranch, toggleCollapsed: { isCollapsed.toggle() })
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GitRepositorySectionNSView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 240
        return CGSize(width: width, height: GitRepositorySectionMetrics(fontScale: fontScale)
            .height(count: branches.count, collapsed: isCollapsed, branchRows: true))
    }
}

struct GitRepositorySectionMetrics {
    let sidebar: SidebarLayoutMetrics
    init(fontScale: CGFloat) { sidebar = SidebarLayoutMetrics(fontScale: fontScale) }
    var headerHeight: CGFloat {
        sidebar.lineHeight(designedFontSize: 9.5, weight: .medium, minimum: 16) + 11
    }
    var rowHeight: CGFloat {
        sidebar.lineHeight(designedFontSize: 11, weight: .medium, minimum: 14)
            + sidebar.lineHeight(designedFontSize: 9.5, minimum: 12) + 7
    }
    var branchRowHeight: CGFloat {
        sidebar.lineHeight(designedFontSize: 11, weight: .medium, minimum: 14) + 10
    }
    func listHeight(count: Int, branchRows: Bool = false) -> CGFloat {
        min(CGFloat(max(0, count)) * (branchRows ? branchRowHeight : rowHeight), 160 * sidebar.growthScale)
    }
    func height(count: Int, collapsed: Bool, branchRows: Bool = false) -> CGFloat {
        count == 0 ? 0 : headerHeight + (collapsed ? 0 : listHeight(count: count, branchRows: branchRows))
    }
}

final class GitRepositorySectionNSView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let header = NSButton(title: String(localized: "WORKTREES"), target: nil, action: nil)
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let scrollView = GitRepositoryScrollView()
    private let tableView = RowButtonTableView()
    private enum Rows: Equatable {
        case worktrees([GitStatusModel.Worktree])
        case branches([String])

        var count: Int {
            switch self {
            case .worktrees(let values): values.count
            case .branches(let values): values.count
            }
        }
        var isBranches: Bool {
            if case .branches = self { return true }
            return false
        }
    }
    private var rows: Rows = .worktrees([])
    private var repositoryID = ""
    private var isBusy = false
    private var metrics = GitRepositorySectionMetrics(fontScale: 1)
    private var isCollapsed = false
    private var openWorktree: ((String) -> Void)?
    private var createItem: (() -> Void)?
    private var removeWorktree: ((GitStatusModel.Worktree) -> Void)?
    private var deleteBranch: ((String) -> Void)?
    private var toggleCollapsed: (() -> Void)?
    private var switchBranch: ((String) -> Void)?
    private var createWorktreeForBranch: ((String) -> Void)?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: metrics.height(count: rows.count, collapsed: isCollapsed, branchRows: rows.isBranches))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.isBordered = false
        header.alignment = .left
        header.imagePosition = .imageLeading
        header.target = self
        header.action = #selector(toggleSection)
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.toolTip = String(localized: "Create Worktree")
        addButton.target = self
        addButton.action = #selector(createItemClicked)
        addButton.setAccessibilityLabel(String(localized: "Create Worktree"))
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
        tableView.action = #selector(activateSelectedRow)
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
        for view in [header, addButton, countLabel, scrollView] { addSubview(view) }
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(
        worktrees: [GitStatusModel.Worktree], isCollapsed: Bool, fontScale: CGFloat,
        openWorktree: @escaping (String) -> Void,
        createWorktree: @escaping () -> Void,
        removeWorktree: @escaping (GitStatusModel.Worktree) -> Void,
        deleteBranch: @escaping (String) -> Void,
        toggleCollapsed: @escaping () -> Void,
        isBusy: Bool = false
    ) {
        self.openWorktree = openWorktree
        self.removeWorktree = removeWorktree
        self.deleteBranch = deleteBranch
        switchBranch = nil
        createWorktreeForBranch = nil
        let previousPaths: Set<String>
        if case .worktrees(let previous) = rows { previousPaths = Set(previous.map(\.path)) }
        else { previousPaths = [] }
        let changedRepository = !previousPaths.isEmpty && previousPaths.isDisjoint(with: worktrees.map(\.path))
        apply(rows: .worktrees(worktrees), isCollapsed: isCollapsed, fontScale: fontScale,
              isBusy: isBusy, title: String(localized: "WORKTREES"),
              createTitle: String(localized: "Create Worktree"), create: createWorktree,
              toggleCollapsed: toggleCollapsed, changedRepository: changedRepository)
    }

    func apply(
        branches: [String], isCollapsed: Bool, fontScale: CGFloat, repositoryID: String,
        isBusy: Bool, switchBranch: @escaping (String) -> Void,
        createBranch: @escaping () -> Void, createWorktree: @escaping (String) -> Void,
        deleteBranch: @escaping (String) -> Void, toggleCollapsed: @escaping () -> Void
    ) {
        openWorktree = nil
        removeWorktree = nil
        self.switchBranch = switchBranch
        createWorktreeForBranch = createWorktree
        self.deleteBranch = deleteBranch
        let changedRepository = self.repositoryID != repositoryID
        self.repositoryID = repositoryID
        apply(rows: .branches(branches), isCollapsed: isCollapsed, fontScale: fontScale,
              isBusy: isBusy, title: String(localized: "Branches"),
              createTitle: String(localized: "Create New Branch…"), create: createBranch,
              toggleCollapsed: toggleCollapsed, changedRepository: changedRepository)
    }

    private func apply(
        rows: Rows, isCollapsed: Bool, fontScale: CGFloat, isBusy: Bool,
        title: String, createTitle: String, create: @escaping () -> Void,
        toggleCollapsed: @escaping () -> Void, changedRepository: Bool
    ) {
        let nextMetrics = GitRepositorySectionMetrics(fontScale: fontScale)
        let changed = self.rows != rows || metrics.sidebar.fontScale != nextMetrics.sidebar.fontScale
        self.rows = rows
        self.isCollapsed = isCollapsed
        self.isBusy = isBusy
        metrics = nextMetrics
        self.createItem = create
        self.toggleCollapsed = toggleCollapsed
        let scale = metrics.sidebar.fontScale
        header.title = title
        tableView.setAccessibilityLabel(title)
        header.font = .systemFont(ofSize: 9.5 * scale, weight: .medium)
        header.contentTintColor = .secondaryLabelColor
        header.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7 * scale, weight: .semibold))
        header.setAccessibilityLabel(title + ", \(rows.count)")
        header.setAccessibilityValue(String(localized: isCollapsed ? "Collapsed" : "Expanded"))
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9 * scale, weight: .medium))
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = createTitle
        addButton.setAccessibilityLabel(createTitle)
        addButton.isEnabled = !isBusy
        countLabel.font = .monospacedDigitSystemFont(ofSize: 9 * scale, weight: .medium)
        countLabel.stringValue = String(rows.count)
        scrollView.isHidden = isCollapsed || rows.count == 0
        tableView.rowHeight = rows.isBranches ? metrics.branchRowHeight : metrics.rowHeight
        if changed { tableView.reloadData() }
        else { updateVisibleRows() }
        if changedRepository { scrollView.contentView.scroll(to: .zero) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let countWidth = ceil(countLabel.fittingSize.width)
        let labelHeight = metrics.headerHeight - 11
        let actionWidth = metrics.sidebar.slotSize(18)
        header.frame = NSRect(x: 8, y: 8, width: max(0, bounds.width - countWidth - actionWidth - 28), height: labelHeight)
        addButton.frame = NSRect(x: max(8, bounds.width - countWidth - actionWidth - 13), y: 6,
                                  width: actionWidth, height: labelHeight + 4)
        countLabel.frame = NSRect(x: max(8, bounds.width - countWidth - 8), y: 8,
                                 width: countWidth, height: labelHeight)
        let listHeight = isCollapsed ? 0 : min(
            metrics.listHeight(count: rows.count, branchRows: rows.isBranches),
            max(0, bounds.height - metrics.headerHeight)
        )
        scrollView.frame = NSRect(x: 0, y: metrics.headerHeight, width: bounds.width, height: listHeight)
        let contentWidth = max(0, scrollView.contentSize.width)
        let contentHeight = max(listHeight, CGFloat(rows.count) * tableView.rowHeight)
        tableView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        tableView.tableColumns.first?.width = contentWidth
        // A shorter refreshed list must not leave an empty viewport at the old offset.
        let maximum = max(0, contentHeight - scrollView.contentSize.height)
        let offset = min(max(0, scrollView.contentView.bounds.minY), maximum)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        GitRepositoryTableRowView(frame: .zero)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("worktreeRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? GitRepositoryRowButton
            ?? GitRepositoryRowButton(frame: .zero)
        cell.identifier = identifier
        configure(cell, row: row)
        return cell
    }

    private func configure(_ cell: GitRepositoryRowButton, row: Int) {
        guard row >= 0, row < rows.count else { return }
        switch rows {
        case .worktrees(let worktrees):
            let worktree = worktrees[row]
            cell.apply(worktree: worktree, metrics: metrics, open: { [weak self] in
                self?.openWorktree?(worktree.path)
            }, remove: { [weak self] in
                self?.removeWorktree?(worktree)
            }, deleteBranch: { [weak self] branch in
                self?.deleteBranch?(branch)
            }, isBusy: isBusy)
        case .branches(let branches):
            let branch = branches[row]
            cell.apply(branch: branch, metrics: metrics, isBusy: isBusy, switchBranch: { [weak self] in
                self?.switchBranch?(branch)
            }, createWorktree: { [weak self] in
                self?.createWorktreeForBranch?(branch)
            }, deleteBranch: { [weak self] branch in
                self?.deleteBranch?(branch)
            })
        }
    }

    private func updateVisibleRows() {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound else { return }
        for index in range.location..<NSMaxRange(range) where index >= 0 && index < rows.count {
            if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? GitRepositoryRowButton {
                configure(cell, row: index)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateVisibleRows()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { activateSelectedRow() }
        else { super.keyDown(with: event) }
    }

    @objc private func toggleSection() { toggleCollapsed?() }

    @objc private func createItemClicked() { if !isBusy { createItem?() } }

    @objc private func activateSelectedRow() {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard index >= 0, index < rows.count else { return }
        switch rows {
        case .worktrees(let worktrees):
            if !worktrees[index].isBare { openWorktree?(worktrees[index].path) }
        case .branches(let branches):
            if !isBusy { switchBranch?(branches[index]) }
        }
    }
}

/// Consume boundary scrolls here rather than handing them to a parent scroll
/// view, including when a refresh leaves too few rows to need scrolling.
private final class GitRepositoryScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let maximum = max(0, (documentView?.bounds.height ?? 0) - contentSize.height)
        let offset = contentView.bounds.minY
        guard maximum > 0,
              !(offset <= 0 && event.scrollingDeltaY > 0),
              !(offset >= maximum && event.scrollingDeltaY < 0) else { return }
        super.scrollWheel(with: event)
    }
}

private final class GitRepositoryTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // A neutral selection keeps the embedded button labels legible in both appearances.
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}

private final class GitRepositoryRowButton: NSButton {
    private let branchLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(labelWithString: String(localized: "Current"))
    private let folderIcon = NSImageView()
    private let openIcon = NSImageView()
    private var metrics = GitRepositorySectionMetrics(fontScale: 1)
    private var activate: (() -> Void)?
    private var removeWorktree: (() -> Void)?
    private var deleteBranch: ((String) -> Void)?
    private var branch: String?
    private var canDeleteBranch = false
    private var createWorktree: (() -> Void)?
    private var isBranchRow = false
    private var isHovered = false
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(activateClicked)
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

    func apply(
        worktree: GitStatusModel.Worktree,
        metrics: GitRepositorySectionMetrics,
        open: @escaping () -> Void,
        remove: @escaping () -> Void,
        deleteBranch: @escaping (String) -> Void,
        isBusy: Bool = false
    ) {
        isBranchRow = false
        pathLabel.isHidden = false
        createWorktree = nil
        self.metrics = metrics
        activate = open
        removeWorktree = remove
        self.deleteBranch = deleteBranch
        branch = worktree.branch
        canDeleteBranch = !isBusy && worktree.isCurrent && worktree.branch != nil
        let scale = metrics.sidebar.fontScale
        currentLabel.stringValue = String(localized: "Current")
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
        setAccessibilityIdentifier("worktreeRow")
        setAccessibilityHelp(worktree.isBare ? String(localized: "Bare repositories cannot be opened in a terminal tab")
            : String(localized: "Opens a new terminal tab in this worktree"))
        let menu = NSMenu()
        menu.autoenablesItems = false
        let removeItem = NSMenuItem(
            title: String(localized: "Remove Worktree"),
            action: #selector(removeWorktreeClicked), keyEquivalent: ""
        )
        removeItem.target = self
        removeItem.isEnabled = !isBusy && !worktree.isCurrent && !worktree.isBare
        menu.addItem(removeItem)
        if worktree.branch != nil {
            let deleteItem = NSMenuItem(
                title: String(localized: "Delete Branch…"),
                action: #selector(deleteBranchClicked), keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.isEnabled = canDeleteBranch
            menu.addItem(deleteItem)
        }
        self.menu = menu
        synchronizeHoverWithMouse()
        needsLayout = true
    }

    func apply(
        branch: String, metrics: GitRepositorySectionMetrics, isBusy: Bool,
        switchBranch: @escaping () -> Void, createWorktree: @escaping () -> Void,
        deleteBranch: @escaping (String) -> Void
    ) {
        self.metrics = metrics
        self.branch = branch
        isBranchRow = true
        activate = switchBranch
        removeWorktree = nil
        self.createWorktree = createWorktree
        self.deleteBranch = deleteBranch
        canDeleteBranch = !isBusy
        let scale = metrics.sidebar.fontScale
        branchLabel.stringValue = branch
        branchLabel.font = .systemFont(ofSize: 11 * scale, weight: .medium)
        branchLabel.textColor = .labelColor
        pathLabel.isHidden = true
        currentLabel.isHidden = true
        folderIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11 * scale, weight: .medium))
        folderIcon.contentTintColor = .secondaryLabelColor
        openIcon.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9 * scale, weight: .medium))
        openIcon.contentTintColor = .tertiaryLabelColor
        isEnabled = !isBusy
        alphaValue = isBusy ? 0.55 : 1
        toolTip = String(localized: "Switch Branch") + "\n" + branch
        setAccessibilityLabel(branch)
        setAccessibilityHelp(String(localized: "Switch Branch"))
        setAccessibilityIdentifier("branchRow")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let createItem = NSMenuItem(title: String(localized: "Create Worktree…"),
                                   action: #selector(createWorktreeClicked), keyEquivalent: "")
        createItem.target = self
        createItem.isEnabled = !isBusy
        menu.addItem(createItem)
        let deleteItem = NSMenuItem(title: String(localized: "Delete Branch…"),
                                   action: #selector(deleteBranchClicked), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.isEnabled = canDeleteBranch
        menu.addItem(deleteItem)
        self.menu = menu
        synchronizeHoverWithMouse()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let iconSize = metrics.sidebar.iconSize(14)
        let leading = 8 + iconSize + 7
        let available = max(0, bounds.width - leading - iconSize - 16)
        let titleHeight = metrics.sidebar.lineHeight(designedFontSize: 11, weight: .medium, minimum: 14)
        let pathHeight = isBranchRow ? 0 : metrics.sidebar.lineHeight(designedFontSize: 9.5, minimum: 12)
        let top = (bounds.height - titleHeight - pathHeight - (isBranchRow ? 0 : 1)) / 2
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
        addTrackingArea(NSTrackingArea(rect: NSIntersectionRect(bounds, visibleRect),
            options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self))
        synchronizeHoverWithMouse()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeHoverWithMouse()
    }

    override func viewDidHide() {
        super.viewDidHide()
        setHovered(false)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        synchronizeHoverWithMouse()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func synchronizeHoverWithMouse() {
        guard let window, !isHiddenOrHasHiddenAncestor else {
            setHovered(false)
            return
        }
        // Scrolling and row reuse can move the row without a mouse exit.
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(NSIntersectionRect(bounds, visibleRect).contains(point))
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (isHovered || isHighlighted) {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.09 : 0.05).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
    @objc private func activateClicked() { if isEnabled { activate?() } }

    @objc private func removeWorktreeClicked() { removeWorktree?() }

    @objc private func createWorktreeClicked() { if isEnabled { createWorktree?() } }

    @objc private func deleteBranchClicked() {
        guard canDeleteBranch, let branch else { return }
        deleteBranch?(branch)
    }
}
