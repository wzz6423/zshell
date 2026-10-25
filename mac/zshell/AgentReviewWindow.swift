//
//  AgentReviewWindow.swift
//  zshell
//

import AppKit
import Combine
import PierreDiffsSwift

@MainActor
final class AgentReviewWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [String: AgentReviewWindowController] = [:]
    private let repositoryRoot: String

    static func show(repositoryRoot: String) {
        guard !repositoryRoot.isEmpty else { return }
        let root = URL(fileURLWithPath: repositoryRoot).resolvingSymlinksInPath().path
        let controller = windows[root] ?? AgentReviewWindowController(repositoryRoot: root)
        windows[root] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(repositoryRoot: String) {
        self.repositoryRoot = repositoryRoot
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.contentViewController = AgentReviewViewController(repositoryRoot: repositoryRoot)
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        Self.windows.removeValue(forKey: repositoryRoot)
    }
}

@MainActor
private final class AgentReviewViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private nonisolated enum Scope: Int, Sendable {
        case latestTurn
        case uncommitted
        case entireBranch
    }

    private let repositoryRoot: String
    private let store = AgentTurnReviewStore.shared
    private let scopePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let agentPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let basePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)!, target: nil, action: nil)
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let fileTable = NSTableView()
    private let detail = NSView()
    private let hunkPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keepButton = NSButton(title: "", target: nil, action: nil)
    private let revertButton = NSButton(title: "", target: nil, action: nil)
    private let decisionLabel = NSTextField(labelWithString: "")
    private let preview = NSView()
    private let layoutPicker = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)

    private var scope: Scope { Scope(rawValue: scopePicker.indexOfSelectedItem) ?? .latestTurn }
    private var files: [AgentReviewFile] = []
    private var before: AgentWorkspaceSnapshot?
    private var after: AgentWorkspaceSnapshot?
    private var selectedTurn: AgentReviewTurn?
    private var contents: AgentReviewFileContents?
    private var diff: DiffTab?
    private var generation = UUID()
    private var fileGeneration = UUID()
    private var loading = false
    private var reverting = false
    private var loadTask: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var diffSubscription: AnyCancellable?
    private var webReadySubscription: AnyCancellable?
    private var loadingOverlay: NSView?

    init(repositoryRoot: String) {
        self.repositoryRoot = repositoryRoot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        let header = NSStackView(views: [scopePicker, agentPicker, basePicker, NSView(), refreshButton])
        header.orientation = .horizontal
        header.spacing = 8
        for picker in [scopePicker, agentPicker, basePicker] {
            picker.controlSize = .small
            picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            picker.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
        }
        scopePicker.target = self; scopePicker.action = #selector(scopeChanged)
        agentPicker.target = self; agentPicker.action = #selector(scopeChanged)
        basePicker.target = self; basePicker.action = #selector(scopeChanged)
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.target = self; refreshButton.action = #selector(refresh)
        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 3
        descriptionLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.resizingMask = .autoresizingMask
        fileTable.addTableColumn(column)
        fileTable.headerView = nil
        fileTable.rowHeight = 28
        fileTable.style = .sourceList
        fileTable.delegate = self; fileTable.dataSource = self
        let fileScroll = NSScrollView()
        fileScroll.hasVerticalScroller = true
        fileScroll.autohidesScrollers = true
        fileScroll.documentView = fileTable
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(fileScroll)
        split.addArrangedSubview(detail)
        fileScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        fileScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        let sidebarWidth = fileScroll.widthAnchor.constraint(equalToConstant: 230)
        sidebarWidth.priority = .defaultLow
        sidebarWidth.isActive = true

        let actions = NSStackView(views: [hunkPicker, layoutPicker, NSView(), decisionLabel, keepButton, revertButton])
        actions.spacing = 8
        hunkPicker.controlSize = .small
        hunkPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hunkPicker.target = self; hunkPicker.action = #selector(hunkChanged)
        layoutPicker.controlSize = .small
        layoutPicker.target = self; layoutPicker.action = #selector(layoutChanged)
        keepButton.controlSize = .small; keepButton.bezelStyle = .accessoryBarAction
        keepButton.target = self; keepButton.action = #selector(keepHunk)
        revertButton.controlSize = .small; revertButton.bezelStyle = .accessoryBarAction
        revertButton.target = self; revertButton.action = #selector(revertHunk)
        decisionLabel.font = .systemFont(ofSize: 11)
        decisionLabel.textColor = .secondaryLabelColor

        for item in [header, descriptionLabel, split] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        for item in [actions, preview] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: 26),
            descriptionLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            descriptionLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            descriptionLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            split.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            actions.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 10),
            actions.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -10),
            actions.topAnchor.constraint(equalTo: detail.topAnchor, constant: 6),
            actions.heightAnchor.constraint(equalToConstant: 30),
            preview.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            preview.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 6),
            preview.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])
        localize()
        updateAgents()
        store.$revision.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.updateAgents()
            let current = self.currentTurn()
            if self.scope == .latestTurn,
               current?.id != self.selectedTurn?.id || current?.isActive != self.selectedTurn?.isActive {
                self.loadScope()
            } else {
                self.selectedTurn = self.scope == .latestTurn ? current : nil
                self.updateActions()
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AppLocalization.didChange).sink { [weak self] _ in
            self?.localize()
            self?.updateAgents()
            self?.loadScope()
        }.store(in: &subscriptions)
        loadScope()
        Task { [weak self] in await self?.loadBaseReferences() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.title = String(localized: "Review Changes…")
    }

    private func localize() {
        let selectedScope = scopePicker.indexOfSelectedItem
        scopePicker.removeAllItems()
        scopePicker.addItems(withTitles: [
            String(localized: "Latest Turn"), String(localized: "Uncommitted"), String(localized: "Entire Branch"),
        ])
        scopePicker.selectItem(at: max(0, selectedScope))
        scopePicker.setAccessibilityLabel(String(localized: "Review scope"))
        agentPicker.setAccessibilityLabel(String(localized: "Agent"))
        basePicker.setAccessibilityLabel(String(localized: "Base branch"))
        refreshButton.toolTip = String(localized: "Refresh")
        refreshButton.setAccessibilityLabel(String(localized: "Refresh"))
        keepButton.title = String(localized: "Keep Hunk")
        revertButton.title = String(localized: "Revert Hunk")
        hunkPicker.setAccessibilityLabel(String(localized: "Change hunk"))
        fileTable.setAccessibilityLabel(String(localized: "Changed files"))
        layoutPicker.segmentCount = 2
        layoutPicker.setLabel(String(localized: "Unified"), forSegment: 0)
        layoutPicker.setLabel(String(localized: "Split"), forSegment: 1)
        layoutPicker.selectedSegment = 0
        layoutPicker.setAccessibilityLabel(String(localized: "Diff layout"))
        view.window?.title = String(localized: "Review Changes…")
    }

    private func updateAgents() {
        let selected = agentPicker.selectedItem?.representedObject as? String
        agentPicker.removeAllItems()
        for turn in store.records(in: repositoryRoot) {
            let timestamp = turn.startedAt.formatted(date: .omitted, time: .shortened)
            let item = NSMenuItem(title: "\(turn.alias) · \(timestamp)", action: nil, keyEquivalent: "")
            item.representedObject = turn.sessionID.uuidString
            agentPicker.menu?.addItem(item)
        }
        if let selected, let item = agentPicker.itemArray.first(where: { $0.representedObject as? String == selected }) {
            agentPicker.select(item)
        }
        if agentPicker.numberOfItems == 0 { agentPicker.addItem(withTitle: String(localized: "No agent turns")) }
    }

    private func currentTurn() -> AgentReviewTurn? {
        guard let id = agentPicker.selectedItem?.representedObject as? String else { return nil }
        return store.records(in: repositoryRoot).first { $0.sessionID.uuidString == id }
    }

    private func loadBaseReferences() async {
        let root = repositoryRoot
        guard let values = try? await Task.detached(priority: .userInitiated, operation: {
            try AgentReviewGit.string(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"], in: root)
        }).value else { return }
        let refs = values.split(separator: "\n").map(String.init)
        basePicker.removeAllItems()
        for reference in refs {
            let label = reference.replacingOccurrences(of: "refs/heads/", with: "")
                .replacingOccurrences(of: "refs/remotes/", with: "")
            basePicker.addItem(withTitle: label)
            basePicker.lastItem?.representedObject = reference
        }
        let preferred = ["refs/remotes/origin/HEAD", "refs/heads/main", "refs/heads/master"]
        if let index = preferred.compactMap({ refs.firstIndex(of: $0) }).first {
            basePicker.selectItem(at: index)
        }
        if scope == .entireBranch { loadScope() }
    }

    @objc private func scopeChanged() { loadScope() }
    @objc private func refresh() { loadScope() }

    private func loadScope() {
        generation = UUID()
        let request = generation
        loadTask?.cancel()
        fileTask?.cancel()
        selectedTurn = scope == .latestTurn ? currentTurn() : nil
        agentPicker.isHidden = scope != .latestTurn
        basePicker.isHidden = scope != .entireBranch
        files = []; before = nil; after = nil
        fileTable.reloadData()
        clearDetail()
        descriptionLabel.stringValue = String(localized: "Loading review…")
        loading = true
        updateActions()
        let selectedScope = scope
        let turn = selectedTurn
        let root = repositoryRoot
        let reference = basePicker.selectedItem?.representedObject as? String
        loadTask = Task { [weak self] in
            do {
                let comparison = try await Task.detached(priority: .userInitiated) {
                    let before: AgentWorkspaceSnapshot
                    let after: AgentWorkspaceSnapshot
                    if selectedScope == .latestTurn {
                        guard let turn else { throw AgentReviewError.unavailable }
                        if turn.isActive { throw AgentReviewError.git(String(localized: "Agent working")) }
                        if let failure = turn.failure { throw AgentReviewError.git(failure) }
                        guard let start = turn.before, let end = turn.after else { throw AgentReviewError.unavailable }
                        before = start; after = end
                    } else {
                        after = try AgentReviewGit.capture(in: root)
                        before = try AgentReviewGit.comparisonBase(
                            in: root, branch: selectedScope == .entireBranch, reference: reference
                        )
                        guard before.head == after.head else { throw AgentReviewError.stale }
                    }
                    return (before, after, try AgentReviewGit.files(from: before, to: after))
                }.value
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.before = comparison.0; self.after = comparison.1; self.files = comparison.2
                self.loading = false
                self.descriptionLabel.stringValue = selectedScope == .latestTurn
                    ? String(localized: "This turn includes all workspace edits between its start and finish, regardless of author. Keep only records a review; Revert changes the working tree.")
                    : (selectedScope == .entireBranch
                        ? String(localized: "The entire branch compares its merge base with the selected branch to the current working tree, including uncommitted files.")
                        : String(localized: "Uncommitted compares HEAD with the current working tree, including staged and untracked files."))
                self.fileTable.reloadData()
                if !self.files.isEmpty {
                    self.fileTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                } else {
                    self.showMessage(String(localized: "No changes"))
                }
                self.updateActions()
            } catch {
                guard let self, self.generation == request else { return }
                self.loading = false
                self.descriptionLabel.stringValue = error.localizedDescription
                self.showMessage(error.localizedDescription)
                self.updateActions()
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("file")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingMiddle
        field.stringValue = "\(files[row].status)  \(files[row].path)"
        field.toolTip = files[row].path
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { loadFile() }

    private var selectedFile: AgentReviewFile? {
        files.indices.contains(fileTable.selectedRow) ? files[fileTable.selectedRow] : nil
    }

    private var selectedHunk: AgentReviewHunk? {
        guard let contents, contents.hunks.indices.contains(hunkPicker.indexOfSelectedItem - 1) else { return nil }
        return contents.hunks[hunkPicker.indexOfSelectedItem - 1]
    }

    private func clearDetail() {
        fileGeneration = UUID()
        contents = nil; diff = nil; diffSubscription = nil; webReadySubscription = nil
        loadingOverlay = nil
        hunkPicker.removeAllItems()
        for subview in preview.subviews { subview.removeFromSuperview() }
        updateActions()
    }

    private func loadFile() {
        clearDetail()
        guard let file = selectedFile, let before, let after else { return }
        let request = fileGeneration
        showMessage(String(localized: "Loading review…"))
        fileTask?.cancel()
        fileTask = Task { [weak self] in
            do {
                let content = try await Task.detached(priority: .userInitiated) {
                    try AgentReviewGit.contents(for: file, before: before, after: after)
                }.value
                guard let self, self.fileGeneration == request, !Task.isCancelled else { return }
                self.contents = content
                self.hunkPicker.addItem(withTitle: String(localized: "Entire file"))
                for (index, hunk) in content.hunks.enumerated() {
                    self.hunkPicker.addItem(withTitle: "\(index + 1)  \(hunk.header)")
                }
                self.hunkPicker.selectItem(at: content.hunks.isEmpty ? 0 : 1)
                let diff = DiffTab(
                    repoRoot: after.root, path: file.path, staged: false, untracked: false, origPath: nil,
                    treeComparison: .init(before: before.tree, after: after.tree)
                )
                self.diff = diff
                self.webReadySubscription = diff.web.$isReady.receive(on: RunLoop.main).sink { [weak self] _ in
                    guard let self, self.fileGeneration == request else { return }
                    self.updatePreviewLoading()
                }
                self.diffSubscription = diff.$isLoading.filter { !$0 }.receive(on: RunLoop.main).sink { [weak self] _ in
                    guard let self, self.fileGeneration == request else { return }
                    self.renderDiff()
                }
                self.updateActions()
            } catch {
                guard let self, self.fileGeneration == request else { return }
                self.showMessage(error.localizedDescription)
                self.updateActions()
            }
        }
    }

    @objc private func hunkChanged() { renderDiff() }

    @objc private func layoutChanged() {
        diff?.setDiffStyle(layoutPicker.selectedSegment == 1 ? .split : .unified)
    }

    private func renderDiff() {
        guard let diff, !diff.isLoading else { return }
        layoutPicker.selectedSegment = diff.diffStyle == .split ? 1 : 0
        updateActions()
        if let error = diff.error { showMessage(error); return }
        if let comparison = diff.imageComparison {
            let imageView = DiffImageComparisonNSView()
            imageView.update(comparison: comparison)
            installPreview(imageView)
            return
        }
        guard let contents else { return }
        if let hunk = selectedHunk {
            diff.web.oldContent = hunk.before.joined()
            diff.web.newContent = hunk.after.joined()
        } else {
            diff.web.oldContent = String(data: contents.before ?? Data(), encoding: .utf8) ?? ""
            diff.web.newContent = String(data: contents.after ?? Data(), encoding: .utf8) ?? ""
        }
        if diff.web.oldContent == diff.web.newContent {
            showMessage(String(localized: "No text hunks. Binary and mode-only changes are read-only."))
            return
        }
        let request = fileGeneration
        Task { [weak self] in
            await diff.materializeWebHostView()
            guard let self, self.fileGeneration == request, let host = diff.webHostView else { return }
            self.installPreview(host)
        }
    }

    private func updateActions() {
        refreshButton.isEnabled = !loading && !reverting
        scopePicker.isEnabled = !reverting
        agentPicker.isEnabled = !reverting
        basePicker.isEnabled = !reverting
        layoutPicker.isHidden = diff?.imageComparison != nil
        keepButton.isHidden = scope != .latestTurn
        revertButton.isHidden = scope != .latestTurn
        let available = !loading && !reverting && selectedFile != nil && selectedHunk != nil
            && selectedTurn?.isActive == false && selectedTurn?.failure == nil
        var reverted = false
        decisionLabel.stringValue = ""
        if let turn = selectedTurn, let file = selectedFile, let hunk = selectedHunk {
            let key = AgentTurnReviewStore.decisionKey(file: file, hunk: hunk)
            reverted = turn.reverted.contains(key)
            decisionLabel.stringValue = reverted ? String(localized: "Reverted")
                : (turn.kept.contains(key) ? String(localized: "Kept") : String(localized: "Unreviewed"))
        }
        keepButton.isEnabled = available && !reverted
        revertButton.isEnabled = available && !reverted && !store.hasActiveTurn(in: repositoryRoot)
            && selectedTurn?.overlapped == false
        revertButton.toolTip = selectedTurn?.overlapped == true ? AgentReviewError.overlapping.localizedDescription
            : (store.hasActiveTurn(in: repositoryRoot) ? AgentReviewError.active.localizedDescription : nil)
        hunkPicker.isEnabled = !reverting && !(contents?.hunks.isEmpty ?? true)
    }

    @objc private func keepHunk() {
        guard let turn = selectedTurn, let file = selectedFile, let hunk = selectedHunk else { return }
        do { try store.keep(turn: turn, file: file, hunk: hunk) }
        catch { descriptionLabel.stringValue = error.localizedDescription }
    }

    @objc private func revertHunk() {
        guard !reverting, let turn = selectedTurn, let file = selectedFile,
              let contents, let hunk = selectedHunk else { return }
        reverting = true
        updateActions()
        Task { [weak self] in
            do { try await self?.store.revert(turn: turn, file: file, contents: contents, hunk: hunk) }
            catch { self?.descriptionLabel.stringValue = error.localizedDescription }
            self?.reverting = false
            self?.updateActions()
        }
    }

    private func showMessage(_ message: String) {
        installPreview(messageView(message))
    }

    private func messageView(_ message: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -48),
        ])
        return container
    }

    private func updatePreviewLoading() {
        guard let diff, diff.webHostView?.superview === preview else { return }
        if diff.web.isReady {
            loadingOverlay?.removeFromSuperview()
            loadingOverlay = nil
        } else if loadingOverlay == nil {
            // Keep WebKit visible underneath the cover so its first render
            // does not get throttled as an offscreen document.
            let overlay = messageView(String(localized: "Loading review…"))
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = Theme.background.cgColor
            overlay.frame = preview.bounds
            overlay.autoresizingMask = [.width, .height]
            preview.addSubview(overlay)
            loadingOverlay = overlay
        }
    }

    private func installPreview(_ content: NSView) {
        guard content.superview !== preview else { return }
        for subview in preview.subviews { subview.removeFromSuperview() }
        loadingOverlay = nil
        content.frame = preview.bounds
        content.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            content.topAnchor.constraint(equalTo: preview.topAnchor),
            content.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
        ])
        updatePreviewLoading()
    }
}
