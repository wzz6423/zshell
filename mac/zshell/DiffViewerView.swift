//
//  DiffViewerView.swift
//  zshell
//

import AppKit
import Combine
import Foundation
import PierreDiffsSwift
import SwiftUI
import UniformTypeIdentifiers

/// Mutable pipe storage shared by the two dedicated readers in
/// `DiffTab.runGitData`. Each instance is written by exactly one reader.
private nonisolated final class DiffPipeData: @unchecked Sendable {
    var value = Data()
}

/// Lightweight UI state that should follow Zshell across launches without
/// becoming a user-facing TOML setting.
@MainActor
private final class DiffViewPreferences: ObservableObject {
    static let shared = DiffViewPreferences()

    private static let layoutKey = "diffView.layout"
    private static let modeKey = "diffView.mode"

    @Published var diffStyle: DiffStyle {
        didSet {
            UserDefaults.standard.set(diffStyle.rawValue, forKey: Self.layoutKey)
        }
    }

    @Published var prefersEditing: Bool {
        didSet {
            UserDefaults.standard.set(
                prefersEditing ? "edit" : "review",
                forKey: Self.modeKey
            )
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: Self.layoutKey),
           let style = DiffStyle(rawValue: rawValue) {
            diffStyle = style
        } else {
            diffStyle = .unified
        }
        prefersEditing = defaults.string(forKey: Self.modeKey) == "edit"
    }
}

/// Observable inputs for a diff tab's web view. Owned by `DiffTab` and also
/// retained by the tab's long-lived hosting view. Its edit callbacks capture
/// the owning `DiffTab` weakly so that view retention cannot leak the tab.
@MainActor
final class DiffWebModel: nonisolated ObservableObject {
    @Published var oldContent = ""
    @Published var newContent = ""
    @Published var fileName = ""
    @Published var fileID = ""
    @Published var canEdit = false
    @Published var annotations: [DiffAnnotation] = []
    @Published var oldFileName: String?
    var overflowMode: OverflowMode { AppSettings.shared.diffWrapLines ? .wrap : .scroll }
    var onFileEditChange: ((String, String) -> Void)?
    var onFileEditComplete: ((String, String) -> Void)?
    var onEditorStateChange: ((String, PierreEditorState) -> Void)?
    var restoredEditorState: PierreEditorState?
    var onAnnotationClick: ((String) -> Void)?
    /// The WKWebView renders blank until its JS bundle has drawn the diff;
    /// a skeleton covers it until the bridge reports ready.
    @Published var isReady = false
    /// Explicit appearance follows the retained AppKit host when it is reparented.
    @Published private(set) var usesDarkAppearance = false

    func updateAppearance(_ appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard usesDarkAppearance != isDark else { return }
        usesDarkAppearance = isDark
    }
}

/// A git diff opened as a tab from the git panel. Loads both sides of the
/// change (via `git show` / the worktree) so they survive tab switches;
/// reloads when the view reappears.
@MainActor
final class DiffTab: nonisolated ObservableObject, nonisolated Identifiable {
    static let pullRequestReviewDidChange = Notification.Name("zshell.pullRequestReviewDidChange")
    nonisolated struct TreeComparison: Sendable {
        let before: String
        let after: String
    }
    nonisolated let id = UUID()

    /// Absolute repository root the diff runs in.
    let repoRoot: String
    /// Repo-relative path, as porcelain reports it.
    let path: String
    /// Diffs HEAD → index instead of index → worktree.
    let staged: Bool
    var untracked: Bool
    /// Historical commit shown by this tab. Nil keeps the existing
    /// index/worktree behavior.
    let commitHash: String?
    /// First parent and name-status metadata used to describe a historical
    /// comparison in the tab strip.
    let commitParentHash: String?
    let commitStatus: Character?
    let treeComparison: TreeComparison?
    /// Previous path when the change is a rename/copy; the "before" side
    /// reads from here so renames diff old file → new file like VS Code.
    var origPath: String?

    @Published private(set) var error: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isUnmerged = false
    @Published private(set) var isEditable = false
    @Published private(set) var isDirty = false
    @Published private(set) var reviewSnapshot: DiffReviewSnapshot?
    @Published var saveError: String?
    @Published private(set) var imageComparison: ImageComparison?

    let web = DiffWebModel()
    let pullRequest = ProjectPullRequestModel()
    let pullRequestWeb = DiffWebModel()
    @Published private(set) var showsPullRequestComments = false
    @Published private(set) var pullRequestReviewState: ProjectPullRequestReviewState = .idle
    @Published private(set) var pullRequestWebHostView: NSView?
    private var pullRequestObservation: AnyCancellable?
    private var reviewActionObservation: AnyCancellable?
    private var pullRequestIdentity: ProjectPullRequestReviewIdentity?
    private var pullRequestGeneration: UInt = 0
    private var pullRequestReviewController: ProjectPullRequestReviewController?

    /// Image bytes remain in their original Git representation until AppKit
    /// decodes them on the main actor. Git loading stays detached, while image
    /// decoding gets the same thread-affinity as the preview view.
    nonisolated struct ImageComparison: Equatable, Sendable {
        let beforeData: Data?
        let afterData: Data?
    }

    /// The web view lives on the tab (not in the SwiftUI view) so switching
    /// tabs re-parents the same rendered view instead of booting a fresh
    /// WKWebView — same pattern as `TerminalSession.terminalView`.
    ///
    /// It starts nil so project selection can commit its skeleton before the
    /// selected diff creates WebKit's AppKit hierarchy on the main actor.
    @Published private(set) var webHostView: NSView?

    private nonisolated static let maxBytes = 5 << 20
    private var savedNewContent = ""
    private(set) var saveBaseline: FileSaveSnapshot?
    /// Live text emitted by Pierre's editor. Kept out of `DiffWebModel` while
    /// editing so a keystroke does not rebuild the CodeView item that owns the
    /// editor, selection, and undo stack.
    private var editedNewContent = ""
    var unsavedText: String? { isDirty ? editedNewContent : nil }
    private var reloadGeneration: UInt = 0
    private var isSaving = false
    private(set) var draftID: UUID
    private var editorState: PierreEditorState?
    private var recoveryGeneration: UInt = 0
    private var isRestoringDraft = false
    private var discardedDraftText: String?

    init(
        repoRoot: String,
        path: String,
        staged: Bool,
        untracked: Bool,
        origPath: String?,
        commitHash: String? = nil,
        commitParentHash: String? = nil,
        commitStatus: Character? = nil,
        treeComparison: TreeComparison? = nil,
        draftID: UUID = UUID(),
        recoveringDraft: Bool = false
    ) {
        self.draftID = draftID
        self.repoRoot = repoRoot
        self.path = path
        self.staged = staged
        self.untracked = untracked
        self.origPath = origPath
        self.commitHash = commitHash
        self.commitParentHash = commitParentHash
        self.commitStatus = commitStatus
        self.treeComparison = treeComparison
        web.fileName = name
        web.fileID = path
        web.onFileEditChange = { [weak self] fileID, contents in
            self?.updateEditedContent(fileID: fileID, contents: contents)
        }
        web.onFileEditComplete = { [weak self] fileID, contents in
            self?.completeEditing(fileID: fileID, contents: contents)
        }
        web.onEditorStateChange = { [weak self] fileID, state in
            guard let self, self.web.fileID == fileID else { return }
            self.editorState = state
            if self.isDirty { EditorDraftStore.shared.schedule(self.draftID) }
        }
        pullRequestObservation = pullRequest.$state.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.pullRequestChanged() }
        }
        reviewActionObservation = NotificationCenter.default.publisher(for: Self.pullRequestReviewDidChange)
            .sink { [weak self] notification in
                guard let self, let url = notification.object as? String,
                      self.currentPullRequestIdentity?.url == url else { return }
                self.pullRequestReviewController?.discussionDidChange()
                if self.showsPullRequestComments || self.pullRequestReviewController?.window?.isVisible == true {
                    self.showPullRequestComments(force: true, preserveVisibility: true)
                }
                else {
                    self.pullRequestGeneration &+= 1
                    self.pullRequestReviewState = .idle
                }
            }
        pullRequestWeb.onAnnotationClick = { [weak self] id in
            guard let self, case .ready(let file) = self.pullRequestReviewState,
                  file.identity == self.currentPullRequestIdentity,
                  let thread = file.threads.first(where: { $0.comments.nodes.contains { $0.id == id } }) else { return }
            self.showPullRequestReview(threadID: thread.id)
        }
        self.draftID = EditorDraftStore.shared.register(draftID, owner: id) { [weak self] in self?.draftSnapshot() }
        if recoveringDraft, AppSettings.shared.recoverEditorDrafts, !staged,
           commitHash == nil, treeComparison == nil { recoverDraft(id: draftID) }
        else { reload() }
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    isolated deinit { EditorDraftStore.shared.unregister(draftID, owner: id) }

    var title: String {
        if let commitHash {
            let after = "\(name) (\(commitHash.prefix(7)))"
            guard let commitParentHash else { return after }
            let beforeName = ((origPath ?? path) as NSString).lastPathComponent
            let before = "\(beforeName) (\(commitParentHash.prefix(7)))"
            switch commitStatus {
            case "A": return after
            case "D": return before
            default: return "\(before) ↔ \(after)"
            }
        }
        return staged
            ? String(localized: "\(name) (Staged)", comment: "Tab title for the staged diff of a file.")
            : name
    }

    func reload(force: Bool = false, discarding draft: String? = nil) {
        guard !isRestoringDraft else { return }
        // Keep the editor's document and undo history stable until the user
        // leaves edit mode, and never replace an unsaved buffer from disk.
        guard force || !isEditing, !isDirty || draft == editedNewContent else { return }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        error = nil
        reviewSnapshot = nil
        imageComparison = nil
        let root = repoRoot
        let path = path
        let oldPath = origPath ?? path
        let staged = staged
        let untracked = untracked
        let commitHash = commitHash
        let treeComparison = treeComparison

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                var failureVar: String?
                var baseline: FileSaveSnapshot?
                let unmerged = commitHash == nil && treeComparison == nil && !staged
                    && Self.isUnmerged(path: path, in: root)
                let old: GitContent
                let new: GitContent
                if let treeComparison {
                    old = Self.gitContent("\(treeComparison.before):\(oldPath)", in: root)
                    new = Self.gitContent("\(treeComparison.after):\(path)", in: root)
                } else if let commitHash {
                    old = Self.gitContent("\(commitHash)^:\(oldPath)", in: root)
                    new = Self.gitContent("\(commitHash):\(path)", in: root)
                } else if staged {
                    old = Self.gitContent("HEAD:\(oldPath)", in: root)
                    new = Self.gitContent(":\(path)", in: root)
                } else {
                    if untracked {
                        old = .missing
                    } else {
                        // An unmerged index has no stage-0 `:path`. Prefer our
                        // side, then the merge base, so conflict rows show a
                        // meaningful before-side instead of the whole file as new.
                        old = Self.firstGitContent([
                            ":\(oldPath)", ":2:\(oldPath)", ":1:\(oldPath)", "HEAD:\(oldPath)",
                        ], in: root)
                    }
                    new = Self.readWorktreeContent(root: root, path: path, baseline: &baseline, error: &failureVar)
                }
                let editable = commitHash == nil && treeComparison == nil && !staged
                    && Self.isEditableWorktreeFile(root: root, path: path)
                let reviewKey = DiffReviewKey(
                    repositoryRoot: root,
                    path: path,
                    layer: staged ? .staged : .worktree
                )
                let fingerprint: String?
                if commitHash == nil && treeComparison == nil {
                    let head = GitStatusModel.runGit(
                        ["rev-parse", "--verify", "HEAD"], in: root
                    )
                    fingerprint = DiffReviewFingerprint.load(
                        path: path,
                        originalPath: oldPath,
                        layer: staged ? .staged : .worktree,
                        hasHead: head.status == 0,
                        untracked: untracked,
                        in: root,
                        runGit: { GitCommandRunner.runData($0, in: $1, limit: .max) }
                    )
                } else {
                    fingerprint = nil
                }
                return (
                    old: old,
                    new: new,
                    reviewKey: reviewKey,
                    fingerprint: fingerprint,
                    failure: failureVar,
                    unmerged: unmerged,
                    editable: editable,
                    baseline: baseline
                )
            }.value
            guard let self, self.reloadGeneration == generation else { return }
            let comparison = Self.imageComparison(
                from: result.old,
                beforePath: oldPath,
                and: result.new,
                afterPath: path
            )
            var failure = result.failure
            let old: String
            let new: String
            if comparison == nil {
                old = Self.textContent(from: result.old, error: &failure)
                new = Self.textContent(from: result.new, error: &failure)
            } else {
                old = ""
                new = ""
            }
            if let draft {
                guard self.editedNewContent == draft else {
                    self.isLoading = false
                    return
                }
                guard failure == nil, comparison == nil, result.editable else {
                    self.isLoading = false
                    self.saveError = failure ?? String(localized: "Could not read file")
                    return
                }
                // Old editor completion messages must not re-install the discarded draft.
                self.web.fileID = "\(self.path)#reload-\(generation)"
            }
            let hasChanges = comparison.map { $0.beforeData != $0.afterData } ?? (old != new)
            self.isLoading = false
            self.error = failure
            self.isUnmerged = result.unmerged
            self.imageComparison = failure == nil ? comparison : nil
            self.isEditable = result.editable && failure == nil && comparison == nil
            self.web.canEdit = self.isEditable
            self.web.oldContent = old
            self.web.newContent = new
            self.savedNewContent = new
            self.saveBaseline = result.baseline
            self.editedNewContent = new
            self.isDirty = false
            if draft != nil { self.discardDraftBackup() }
            self.saveError = nil
            if self.commitHash == nil, self.treeComparison == nil, result.failure == nil,
               failure == nil, hasChanges, let fingerprint = result.fingerprint {
                let snapshot = DiffReviewSnapshot(
                    key: result.reviewKey,
                    fingerprint: fingerprint
                )
                if DiffReviewStore.shared.register(snapshot) {
                    self.reviewSnapshot = snapshot
                } else {
                    self.reviewSnapshot = nil
                }
            } else {
                self.reviewSnapshot = nil
                if self.commitHash == nil && self.treeComparison == nil {
                    DiffReviewStore.shared.invalidate(result.reviewKey)
                }
            }
        }
    }

    /// Refreshes a live diff when navigation brings it back on screen.
    /// Historical blobs are immutable and already loaded by `init`; rerunning
    /// four Git processes and republishing both files on every project switch
    /// only makes WebKit render the same diff again. An initial live load also
    /// stays in flight rather than being duplicated by the view's first mount.
    func refreshWhenSelected() {
        if commitHash == nil, treeComparison == nil { pullRequest.sync(directory: repoRoot) }
        guard commitHash == nil, treeComparison == nil, !isLoading else { return }
        reload()
    }

    /// WebKit views are main-actor objects, but their creation does not need to
    /// be part of the project-selection transaction. Yielding lets SwiftUI
    /// display the existing skeleton first and avoids materializing every
    /// hidden diff in a project at once.
    func materializeWebHostView() async {
        guard webHostView == nil else { return }
        await Task.yield()
        guard !Task.isCancelled, webHostView == nil else { return }
        web.updateAppearance(NSApp.effectiveAppearance)
        webHostView = DiffWebHostingView(model: web)
    }

    var canShowPullRequestComments: Bool {
        commitHash == nil && treeComparison == nil && currentPullRequestIdentity != nil
    }

    var currentPullRequestIdentity: ProjectPullRequestReviewIdentity? {
        if case .pullRequest(let pr) = pullRequest.state, let context = pullRequest.context {
            return ProjectPullRequestReviewIdentity(pr, context: context)
        }
        if case .loading = pullRequest.state, let identity = pullRequestIdentity,
           pullRequest.context == identity.context {
            return identity
        }
        return nil
    }

    private func pullRequestChanged() {
        let identity = currentPullRequestIdentity
        guard identity != pullRequestIdentity else { return }
        pullRequestIdentity = identity
        pullRequestGeneration &+= 1
        if showsPullRequestComments { pullRequestReviewState = .failed(.changed) }
    }

    func showPullRequestComments(force: Bool = false, preserveVisibility: Bool = false) {
        pullRequestChanged()
        guard canShowPullRequestComments, let identity = currentPullRequestIdentity else { return }
        if !preserveVisibility { showsPullRequestComments = true }
        pullRequestGeneration &+= 1
        let generation = pullRequestGeneration
        pullRequestReviewState = .loading
        let path = path, root = repoRoot
        Task { [weak self] in
            let result = await ProjectPullRequestReviewCache.shared.value(for: identity, path: path, force: force)
            let verified = await Task.detached(priority: .utility) { GitStatusModel.branchSnapshot(in: root) }.value
            guard let self, self.pullRequestGeneration == generation, self.currentPullRequestIdentity == identity else { return }
            guard case .repository(let snapshot) = verified,
                  case .context(let current) = ProjectPullRequestContext.resolve(snapshot), current == identity.context else {
                self.pullRequestReviewState = .failed(.changed)
                self.pullRequest.refresh()
                return
            }
            self.pullRequestReviewState = result
            if case .ready(let file) = result {
                if self.pullRequestWeb.fileID != file.path || self.pullRequestWeb.oldContent != file.oldContents
                    || self.pullRequestWeb.newContent != file.newContents || self.pullRequestWeb.annotations != file.annotations {
                    self.pullRequestWeb.isReady = false
                }
                self.pullRequestWeb.fileID = file.path
                self.pullRequestWeb.fileName = file.path
                self.pullRequestWeb.oldFileName = file.oldPath == file.path ? nil : file.oldPath
                self.pullRequestWeb.oldContent = file.oldContents
                self.pullRequestWeb.newContent = file.newContents
                self.pullRequestWeb.annotations = file.annotations
                self.pullRequestWeb.updateAppearance(NSApp.effectiveAppearance)
                if self.pullRequestWebHostView == nil {
                    self.pullRequestWebHostView = DiffWebHostingView(model: self.pullRequestWeb)
                }
            }
        }
    }

    func hidePullRequestComments() {
        pullRequestGeneration &+= 1
        showsPullRequestComments = false
    }

    func showPullRequestReview(threadID: String? = nil) {
        guard case .ready(let file) = pullRequestReviewState,
              file.identity == currentPullRequestIdentity else { return }
        if let controller = pullRequestReviewController { controller.select(file: file, threadID: threadID) }
        else { pullRequestReviewController = ProjectPullRequestReviewController(diff: self, file: file, threadID: threadID) }
        pullRequestReviewController?.present(from: pullRequestWebHostView?.window)
    }

    /// Accepts the updated side emitted by Pierre's editor. The web view owns
    /// the live document; this mirrored value drives dirty state and saving.
    func updateEditedContent(fileID: String, contents: String) {
        guard isEditable, fileID == web.fileID else { return }
        let changed = editedNewContent != contents
        editedNewContent = contents
        isDirty = contents != savedNewContent
        if changed, isDirty || isLoading {
            // A reload already in flight must not win after the first edit.
            reloadGeneration &+= 1
            isLoading = false
        }
        if isDirty { EditorDraftStore.shared.schedule(draftID) }
        else { EditorDraftStore.shared.remove(draftID) }
    }

    /// Once Pierre has torn down its editor, publish the final buffer so the
    /// read-only diff renders the text the user just reviewed and edited.
    func completeEditing(fileID: String, contents: String) {
        updateEditedContent(fileID: fileID, contents: contents)
        guard isEditable, fileID == web.fileID else { return }
        web.newContent = contents
    }

    func setDiffStyle(_ style: DiffStyle) {
        DiffViewPreferences.shared.diffStyle = style
        if isDirty { EditorDraftStore.shared.schedule(draftID) }
    }

    var diffStyle: DiffStyle { DiffViewPreferences.shared.diffStyle }

    func setEditing(_ isEditing: Bool) {
        guard isEditable else { return }
        DiffViewPreferences.shared.prefersEditing = isEditing
        if isDirty { EditorDraftStore.shared.schedule(draftID) }
    }

    private var isEditing: Bool {
        isEditable && DiffViewPreferences.shared.prefersEditing
    }

    @discardableResult
    func save(resolveConflict: ((FileSaveCoordinator.Conflict, String) -> FileSaveConflictController.Choice)? = nil) -> Bool {
        guard isEditable, isDirty else { return !isDirty }
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        reloadGeneration &+= 1
        isLoading = false
        let fileURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(path)
        let draft = editedNewContent
        do {
            switch try FileSaveConflictController.save(
                text: draft, path: fileURL.path, baseline: saveBaseline,
                protectionEnabled: AppSettings.shared.protectEditorSaves,
                in: webHostView?.window, resolveConflict: resolveConflict
            ) {
            case .saved(let snapshot):
                saveBaseline = snapshot
                savedNewContent = draft
                isDirty = editedNewContent != draft
                if isDirty { EditorDraftStore.shared.schedule(draftID) }
                else { EditorDraftStore.shared.remove(draftID) }
                saveError = nil
                return !isDirty
            case .reload:
                reload(force: true, discarding: draft)
            case .cancelled:
                saveError = String(localized: "The file changed on disk. Your draft was kept.")
            }
        } catch {
            saveError = error.localizedDescription
        }
        return false
    }

    func restoreDraft(_ draft: String, baseline: FileSaveSnapshot) {
        guard commitHash == nil, treeComparison == nil, !staged, baseline.text != nil else { return }
        recoveryGeneration &+= 1
        isRestoringDraft = false
        discardedDraftText = nil
        reloadGeneration &+= 1
        web.fileID = "\(path)#draft-\(reloadGeneration)"
        saveBaseline = baseline
        savedNewContent = baseline.text ?? ""
        editedNewContent = draft
        isDirty = true
        isEditable = true
        isLoading = false
        error = nil
        saveError = nil
        imageComparison = nil
        web.canEdit = true
        web.newContent = draft
        EditorDraftStore.shared.schedule(draftID)
    }

    func draftSnapshot() -> EditorDraftRecord? {
        guard isEditable, isDirty, editedNewContent != discardedDraftText, let saveBaseline,
              commitHash == nil, treeComparison == nil, !staged else { return nil }
        return EditorDraftRecord(id: draftID,
            source: .diff(repoRoot: repoRoot, path: path, untracked: untracked, originalPath: origPath),
            text: editedNewContent, baseline: saveBaseline,
            diffState: .init(oldText: web.oldContent, style: diffStyle.rawValue,
                             editing: isEditing, editor: editorState))
    }

    func restoreDraft(_ record: EditorDraftRecord) {
        guard record.isValid, case .diff(let root, let path, _, _) = record.source,
              root == repoRoot, path == self.path, let state = record.diffState else { return }
        if let style = DiffStyle(rawValue: state.style) { DiffViewPreferences.shared.diffStyle = style }
        DiffViewPreferences.shared.prefersEditing = state.editing
        web.oldContent = state.oldText
        editorState = state.editor
        web.restoredEditorState = state.editor
        restoreDraft(record.text, baseline: record.baseline)
    }

    func discardDraftBackup() {
        discardedDraftText = editedNewContent
        EditorDraftStore.shared.remove(draftID)
    }

    private func recoverDraft(id: UUID) {
        isRestoringDraft = true
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        Task { [weak self] in
            let record = try? await EditorDraftStore.shared.archive.load(id)
            guard let self, self.recoveryGeneration == generation, !self.isDirty else { return }
            self.isRestoringDraft = false
            guard AppSettings.shared.recoverEditorDrafts else { self.reload(); return }
            if let record, case .diff(let root, let path, _, _) = record.source,
               root == self.repoRoot, path == self.path { self.restoreDraft(record) }
            else { self.reload() }
        }
    }

    private nonisolated enum GitContent {
        case missing
        case content(String)
        case binary(Data)
        case tooLarge
    }

    /// Image decoding belongs on the main actor with the AppKit views that use
    /// it. The detached Git read retains raw bytes only until this decision.
    private static func imageComparison(
        from old: GitContent,
        beforePath: String,
        and new: GitContent,
        afterPath: String
    ) -> ImageComparison? {
        let beforeData: Data?
        switch old {
        case .missing:
            beforeData = nil
        case .binary(let data):
            beforeData = data
        case .content, .tooLarge:
            return nil
        }

        let afterData: Data?
        switch new {
        case .missing:
            afterData = nil
        case .binary(let data):
            afterData = data
        case .content, .tooLarge:
            return nil
        }

        guard beforeData != nil || afterData != nil else { return nil }
        let isKnownImage = Self.isImagePath(beforePath) || Self.isImagePath(afterPath)
        let hasDecodableImage = [beforeData, afterData].contains { data in
            data.flatMap(NSImage.init(data:)) != nil
        }
        guard isKnownImage || hasDecodableImage else { return nil }
        return ImageComparison(beforeData: beforeData, afterData: afterData)
    }

    private nonisolated static func isImagePath(_ path: String) -> Bool {
        let pathExtension = URL(fileURLWithPath: path).pathExtension
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension)
        else { return false }
        return type.conforms(to: .image)
    }

    private static func textContent(from content: GitContent, error: inout String?) -> String {
        switch content {
        case .missing:
            return ""
        case .content(let content):
            return content
        case .binary:
            if error == nil {
                error = String(localized: "Binary file")
            }
            return ""
        case .tooLarge:
            if error == nil {
                error = String(localized: "File is too large to diff")
            }
            return ""
        }
    }

    private nonisolated static func firstGitContent(
        _ specs: [String], in root: String
    ) -> GitContent {
        for spec in specs {
            let content = gitContent(spec, in: root)
            if case .missing = content { continue }
            return content
        }
        return .missing
    }

    private nonisolated static func gitContent(_ spec: String, in root: String) -> GitContent {
        let size = GitStatusModel.runGit(["cat-file", "-s", spec], in: root)
        guard size.status == 0 else { return .missing }
        let byteCount = Int(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard byteCount <= maxBytes else { return .tooLarge }
        let run = runGitData(["cat-file", "blob", spec], in: root)
        guard run.status == 0 else { return .missing }
        guard run.stdout.count <= maxBytes else { return .tooLarge }
        guard !run.stdout.contains(0),
              let content = String(data: run.stdout, encoding: .utf8)
        else {
            return .binary(run.stdout)
        }
        return .content(content)
    }

    /// GitStatusModel's general runner intentionally exposes decoded text.
    /// Diff blobs need their original bytes so invalid UTF-8 and embedded NULs
    /// cannot be mistaken for an empty text file.
    private nonisolated static func runGitData(
        _ args: [String], in root: String
    ) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        process.environment = GitCommandRunner.processEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (-1, Data(), error.localizedDescription)
        }

        let outData = DiffPipeData()
        let errData = DiffPipeData()
        let captureLimit = maxBytes + 1
        let readers = DispatchGroup()
        // Pipe EOF is part of this synchronous Git operation. Matching the
        // caller avoids a user-initiated diff load waiting on utility readers.
        let readerQualityOfService = Thread.current.qualityOfService
        readers.enter()
        let stdoutReader = Thread {
            // Drain the pipe so Git cannot deadlock, but retain at most one
            // byte beyond the limit. The index may change between cat-file's
            // size check and this read while an agent is working.
            while true {
                let chunk: Data
                do {
                    guard let next = try stdout.fileHandleForReading.read(upToCount: 64 * 1024),
                          !next.isEmpty else { break }
                    chunk = next
                } catch {
                    break
                }
                let remaining = captureLimit - outData.value.count
                if remaining > 0 {
                    outData.value.append(chunk.prefix(remaining))
                }
            }
            readers.leave()
        }
        stdoutReader.qualityOfService = readerQualityOfService
        stdoutReader.start()
        readers.enter()
        let stderrReader = Thread {
            errData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        stderrReader.qualityOfService = readerQualityOfService
        stderrReader.start()
        process.waitUntilExit()
        readers.wait()
        return (
            process.terminationStatus,
            outData.value,
            String(data: errData.value, encoding: .utf8) ?? ""
        )
    }

    private nonisolated static func isUnmerged(path: String, in root: String) -> Bool {
        let run = GitStatusModel.runGit(
            ["--literal-pathspecs", "ls-files", "--unmerged", "--", path], in: root
        )
        return run.status == 0 && !run.stdout.isEmpty
    }

    /// Editing is limited to regular worktree files. In particular, writing a
    /// symlink atomically would replace the link itself with a regular file.
    private nonisolated static func isEditableWorktreeFile(root: String, path: String) -> Bool {
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else { return false }
        return true
    }

    private nonisolated static func readWorktreeContent(
        root: String, path: String, baseline: inout FileSaveSnapshot?, error: inout String?
    ) -> GitContent {
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
        let fm = FileManager.default
        if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            guard destination.utf8.count <= maxBytes else {
                return .tooLarge
            }
            return .content(destination)
        }
        do {
            let snapshot = try FileSaveCoordinator.read(path: url.path)
            baseline = snapshot
            if snapshot.isMissing { return .missing }
            guard snapshot.isRegular else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            guard let data = snapshot.data else { return .tooLarge }
            guard !data.contains(0),
                  let text = String(data: data, encoding: .utf8)
            else {
                return .binary(data)
            }
            return .content(text)
        } catch let readError as CocoaError
            where readError.code == .fileNoSuchFile || readError.code == .fileReadNoSuchFile {
            // Deleted from the worktree: an empty "after" side is the diff.
            return .missing
        } catch let fileError {
            error = String(
                localized: "Unable to read file: \(fileError.localizedDescription)",
                comment: "Diff error followed by a system-provided error description."
            )
            return .missing
        }
    }
}

/// Font handling for the diff web view, so a diff reads at the same family and
/// size as the terminal and the editor.
///
/// A family the user picked in Settings is installed system-wide and the web
/// view resolves it by name. zshell's bundled JetBrains Mono is different:
/// `TerminalFont.registerBundledFonts` registers it for this process only, and
/// the diff renders in a separate WebKit content process that cannot see it —
/// so its faces travel to the web view as embedded font data. Reading and
/// encoding them happens once for the whole app.
private enum DiffFont {
    static func renderOptions(family: String, size: Double) -> PierreDiffRenderOptions {
        let usesBundled = family.isEmpty || family == TerminalFont.bundledFamily
        return PierreDiffRenderOptions(
            font: .bundled(
                familyName: usesBundled ? TerminalFont.bundledFamily : family,
                faces: usesBundled ? bundledFaces : [],
                sizePoints: size
            )
        )
    }

    /// All four faces travel, rather than letting the browser synthesize bold
    /// and italic: synthetic faces in a monospace grid do not stay aligned
    /// with the real one.
    private static let bundledFaces: [PierreDiffFontFace] = {
        let variants = [
            ("JetBrainsMono-Regular", "400", "normal"),
            ("JetBrainsMono-Bold", "700", "normal"),
            ("JetBrainsMono-Italic", "400", "italic"),
            ("JetBrainsMono-BoldItalic", "700", "italic"),
        ]
        return variants.compactMap { resource, weight, style in
            PierreDiffFontFace.load(
                family: TerminalFont.bundledFamily,
                resource: resource,
                extension: "ttf",
                weight: weight,
                style: style
            )
        }
    }()
}

/// The tab retains this AppKit host across navigation. Both ordinary changes
/// and PR comments use the worker-backed, virtualized multi-file pipeline.
private final class DiffWebHostingView: NSView {
    private let model: DiffWebModel
    private let renderer = PierreMultiDiffNSView()
    private var observations: [AnyCancellable] = []
    private var updateScheduled = false

    init(model: DiffWebModel) {
        self.model = model
        super.init(frame: .zero)
        renderer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(renderer)
        NSLayoutConstraint.activate([
            renderer.leadingAnchor.constraint(equalTo: leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderer.topAnchor.constraint(equalTo: topAnchor),
            renderer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        renderer.onFileEditChange = { [weak model] in model?.onFileEditChange?($0, $1) }
        renderer.onFileEditComplete = { [weak model] in model?.onFileEditComplete?($0, $1) }
        renderer.onEditorStateChange = { [weak model] in model?.onEditorStateChange?($0, $1) }
        renderer.onAnnotationClick = { [weak model] in model?.onAnnotationClick?($0) }
        renderer.onReady = { [weak model] in model?.isReady = true }
        observations = [
            model.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() },
            AppSettings.shared.$fontFamily.removeDuplicates().sink { [weak self] _ in self?.scheduleUpdate() },
            AppSettings.shared.$fontSize.removeDuplicates().sink { [weak self] _ in self?.scheduleUpdate() },
            AppSettings.shared.$diffWrapLines.removeDuplicates().sink { [weak self] _ in self?.scheduleUpdate() },
            DiffViewPreferences.shared.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() },
        ]
        updateRenderer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        model.updateAppearance(effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        model.updateAppearance(effectiveAppearance)
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.updateRenderer()
        }
    }

    private func updateRenderer() {
        let preferences = DiffViewPreferences.shared, settings = AppSettings.shared
        renderer.update(files: [PierreDiffFile(id: model.fileID, name: model.fileName,
            oldName: model.oldFileName, oldContents: model.oldContent, newContents: model.newContent,
            isEditable: model.canEdit && preferences.prefersEditing, annotations: model.annotations)],
            diffStyle: preferences.diffStyle, overflowMode: model.overflowMode,
            renderOptions: DiffFont.renderOptions(family: settings.fontFamily, size: settings.fontSize),
            usesDarkAppearance: model.usesDarkAppearance)
        if let state = model.restoredEditorState {
            model.restoredEditorState = nil
            renderer.restoreEditorState(state, fileID: model.fileID)
        }
    }
}

/// AppKit owns the binary image comparison so each side gets the same zooming
/// and viewport behavior as Files previews.
private struct DiffImageComparisonHostView: NSViewRepresentable {
    let comparison: DiffTab.ImageComparison

    func makeNSView(context: Context) -> DiffImageComparisonNSView {
        let view = DiffImageComparisonNSView()
        view.update(comparison: comparison)
        return view
    }

    func updateNSView(_ view: DiffImageComparisonNSView, context: Context) {
        view.update(comparison: comparison)
    }
}

@MainActor
final class DiffImageComparisonNSView: NSView {
    private let before = DiffImageComparisonSideView(
        title: String(localized: "Before", comment: "The previous version in an image diff.")
    )
    private let after = DiffImageComparisonSideView(
        title: String(localized: "After", comment: "The new version in an image diff.")
    )
    private let divider = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        for view in [before, divider, after] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        divider.wantsLayer = true

        NSLayoutConstraint.activate([
            before.leadingAnchor.constraint(equalTo: leadingAnchor),
            before.topAnchor.constraint(equalTo: topAnchor),
            before.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: before.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            after.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            after.trailingAnchor.constraint(equalTo: trailingAnchor),
            after.topAnchor.constraint(equalTo: topAnchor),
            after.bottomAnchor.constraint(equalTo: bottomAnchor),
            before.widthAnchor.constraint(equalTo: after.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(comparison: DiffTab.ImageComparison) {
        before.update(imageData: comparison.beforeData)
        after.update(imageData: comparison.afterData)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.background.cgColor
            divider.layer?.backgroundColor = Theme.divider.cgColor
        }
    }
}

@MainActor
private final class DiffImageComparisonSideView: NSView {
    private let titleLabel: NSTextField
    private let divider = NSView()
    private var content: NSView?
    private var imageData: Data?

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        divider.wantsLayer = true
        for view in [titleLabel, divider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(imageData: Data?) {
        guard self.imageData != imageData || content == nil else { return }
        self.imageData = imageData
        content?.removeFromSuperview()

        let replacement: NSView
        if let imageData, let image = NSImage(data: imageData) {
            replacement = ImagePreviewView(image: image, backgroundColor: Theme.background)
            replacement.setAccessibilityLabel(titleLabel.stringValue)
        } else {
            replacement = placeholder(
                text: String(localized: imageData == nil ? "No image" : "Image unavailable")
            )
        }
        replacement.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replacement)
        NSLayoutConstraint.activate([
            replacement.leadingAnchor.constraint(equalTo: leadingAnchor),
            replacement.trailingAnchor.constraint(equalTo: trailingAnchor),
            replacement.topAnchor.constraint(equalTo: divider.bottomAnchor),
            replacement.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        content = replacement
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func placeholder(text: String) -> NSView {
        let container = NSView()
        let icon = NSImageView()
        let label = NSTextField(labelWithString: text)
        icon.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
        ])
        container.setAccessibilityElement(true)
        container.setAccessibilityLabel("\(titleLabel.stringValue): \(text)")
        return container
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.background.cgColor
            divider.layer?.backgroundColor = Theme.divider.cgColor
        }
    }
}

struct DiffViewerView: NSViewRepresentable {
    let diff: DiffTab
    let isSelected: Bool

    init(diff: DiffTab, isSelected: Bool = true) {
        self.diff = diff
        self.isSelected = isSelected
    }

    func makeNSView(context: Context) -> DiffViewerNSView { DiffViewerNSView(diff: diff) }
    func updateNSView(_ view: DiffViewerNSView, context: Context) { view.setSelected(isSelected) }
}

@MainActor
final class DiffViewerNSView: NSView {
    private let diff: DiffTab
    private let controls = DiffControlsNSView()
    private let conflict = NSTextField(labelWithString: "")
    private let saveError = NSTextField(labelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let content = NSView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let skeleton = DiffSkeletonNSView()
    private var imageView: DiffImageComparisonNSView?
    private var shownContent: NSView?
    private var observations: [AnyCancellable] = []
    private var selected = false
    private var scheduled = false
    private var materializing = false

    init(diff: DiffTab) {
        self.diff = diff
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        for view in [controls, conflict, saveError, notice, content] { addSubview(view) }
        conflict.font = .systemFont(ofSize: 11, weight: .medium)
        conflict.textColor = .systemOrange
        saveError.font = .systemFont(ofSize: 11)
        saveError.textColor = .systemOrange
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 11)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        observations = [
            diff.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() },
            diff.web.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() },
            diff.pullRequest.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() },
            diff.pullRequestWeb.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() },
            DiffViewPreferences.shared.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() },
            DiffReviewStore.shared.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() },
            AppSettings.shared.$diffWrapLines.removeDuplicates().sink { [weak self] _ in self?.scheduleUpdate() },
            NotificationCenter.default.publisher(for: AppLocalization.didChange)
                .sink { [weak self] _ in self?.scheduleUpdate() },
            Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                guard let self, self.selected, self.window != nil,
                      self.diff.commitHash == nil, self.diff.treeComparison == nil else { return }
                self.diff.pullRequest.sync(directory: self.diff.repoRoot)
            },
        ]
        updateContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func setSelected(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        if selected { diff.refreshWhenSelected() }
        updateContent()
    }

    override func layout() {
        super.layout()
        var top: CGFloat = 0
        for banner in [conflict, saveError, notice] where !banner.isHidden {
            let height = banner === notice ? max(28, banner.sizeThatFits(NSSize(width: max(0, bounds.width - 20), height: 200)).height + 12) : 28
            banner.frame = NSRect(x: 10, y: top + 6, width: max(0, bounds.width - 20), height: height - 12)
            top += height
        }
        controls.frame = NSRect(x: 0, y: top, width: bounds.width, height: DiffViewerLayout.controlsHeight)
        top += DiffViewerLayout.controlsHeight
        content.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        if shownContent === placeholder {
            let size = placeholder.sizeThatFits(NSSize(width: max(0, content.bounds.width - 48), height: 300))
            placeholder.frame = NSRect(x: 24, y: (content.bounds.height - size.height) / 2,
                width: max(0, content.bounds.width - 48), height: size.height)
        } else { shownContent?.frame = content.bounds }
        skeleton.frame = content.bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func scheduleUpdate() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.updateContent()
        }
    }

    private func updateContent() {
        let prMode = diff.showsPullRequestComments
        let snapshot = prMode ? nil : diff.reviewSnapshot
        controls.update(diffStyle: diff.diffStyle,
            wrapsLines: AppSettings.shared.diffWrapLines,
            isEditing: diff.isEditable && DiffViewPreferences.shared.prefersEditing,
            canEdit: diff.isEditable && !prMode,
            showsLayout: prMode || diff.imageComparison == nil,
            reviewAvailable: snapshot != nil,
            reviewed: snapshot.map(DiffReviewStore.shared.isReviewed) ?? false,
            commentsAvailable: diff.canShowPullRequestComments,
            showsComments: prMode,
            reviewActionsAvailable: prMode && { if case .ready = diff.pullRequestReviewState { true } else { false } }(),
            onDiffStyleChange: { [weak diff] in diff?.setDiffStyle($0) },
            onWrapLinesChange: { AppSettings.shared.diffWrapLines = $0 },
            onEditingChange: { [weak diff] in diff?.setEditing($0) },
            onReviewChange: { reviewed in
                guard let snapshot else { return }
                DiffReviewStore.shared.setReviewed(reviewed, for: snapshot)
            },
            onComments: { [weak diff] in
                guard let diff else { return }
                if diff.showsPullRequestComments { diff.hidePullRequestComments() }
                else { diff.showPullRequestComments() }
            },
            onRefreshComments: { [weak diff] in diff?.showPullRequestComments(force: true) },
            onPullRequestReview: { [weak diff] in diff?.showPullRequestReview() })
        conflict.isHidden = prMode || !diff.isUnmerged
        conflict.stringValue = String(localized: "Unresolved merge conflict")
        saveError.isHidden = diff.saveError == nil
        saveError.stringValue = diff.saveError.map {
            String(localized: "Could not save: \($0)", comment: "Diff save error with system details.")
        } ?? ""
        notice.isHidden = true
        if prMode {
            switch diff.pullRequestReviewState {
            case .idle, .loading:
                showPlaceholder(String(localized: "Loading PR comments…"))
            case .failed(let failure):
                showPlaceholder(failure.message)
            case .ready(let file):
                guard file.identity == diff.currentPullRequestIdentity else {
                    showPlaceholder(ProjectPullRequestReviewState.Failure.changed.message)
                    break
                }
                let annotations = file.annotations
                if diff.pullRequestWeb.annotations != annotations { diff.pullRequestWeb.annotations = annotations }
                var messages = ["#\(file.identity.number)"]
                if file.outdatedThreadCount > 0 { messages.append(String(localized: "Outdated comments are hidden.")) }
                if file.annotations.isEmpty { messages.append(String(localized: "No PR comments for this file")) }
                notice.stringValue = messages.joined(separator: " · ")
                notice.isHidden = false
                if let host = diff.pullRequestWebHostView { show(host, ready: diff.pullRequestWeb.isReady) }
                else { show(skeleton, ready: true) }
            }
        } else if let error = diff.error {
            showPlaceholder(error)
        } else if let comparison = diff.imageComparison {
            if imageView == nil { imageView = DiffImageComparisonNSView() }
            imageView?.update(comparison: comparison)
            show(imageView!, ready: true)
        } else if diff.isLoading && diff.web.oldContent == diff.web.newContent {
            show(skeleton, ready: true)
        } else if diff.web.oldContent == diff.web.newContent {
            showPlaceholder(diff.isUnmerged ? String(localized: "Conflict is still unresolved") : String(localized: "No changes"))
        } else if let host = diff.webHostView {
            show(host, ready: diff.web.isReady)
        } else {
            show(skeleton, ready: true)
            if selected, !materializing {
                materializing = true
                Task { [weak self] in
                    guard let self else { return }
                    await self.diff.materializeWebHostView()
                    self.materializing = false
                    self.updateContent()
                }
            }
        }
        updateColors()
        needsLayout = true
    }

    private func showPlaceholder(_ text: String) {
        placeholder.stringValue = text
        show(placeholder, ready: true)
    }

    private func show(_ view: NSView, ready: Bool) {
        if shownContent !== view {
            shownContent?.removeFromSuperview()
            shownContent = view
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
        }
        if ready || view === skeleton { if view !== skeleton { skeleton.removeFromSuperview() } }
        else { content.addSubview(skeleton) }
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Theme.background.cgColor }
    }
}

private final class DiffSkeletonNSView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.background.setFill()
        dirtyRect.fill()
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        let widths: [CGFloat] = [0.42, 0.62, 0.30, 0.55, 0.38, 0.50, 0.24, 0.16]
        for row in 0..<24 {
            let y = CGFloat(row) * 18 + 16
            NSBezierPath(roundedRect: NSRect(x: row % 8 == 0 ? 16 : 34, y: y,
                width: bounds.width * widths[row % 8] * 0.55, height: 9), xRadius: 3, yRadius: 3).fill()
        }
    }
}

private enum DiffViewerLayout {
    static let controlsHeight: CGFloat = 37
}

private final class DiffControlsNSView: NSView {
    private let reviewButton = DiffReviewButton()
    private let commentsButton = NSButton(title: "", target: nil, action: nil)
    private let refreshButton = WorkspaceChromeButton(symbol: "arrow.clockwise", label: "")
    private let pullRequestReviewButton = WorkspaceChromeButton(symbol: "checkmark.bubble", label: "")
    private let wrapLinesButton = WorkspaceChromeButton(symbol: "arrow.turn.down.left", label: "")
    private let optionsButton = WorkspaceChromeButton(symbol: "ellipsis", label: "")
    private let leadingControls = NSStackView()
    private let trailingControls = NSStackView()
    private let modeControl = NSSegmentedControl(
        labels: [
            String(localized: "Review", comment: "Read-only mode for a diff."),
            String(localized: "Edit", comment: "Editable mode for a diff."),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let layoutControl = NSSegmentedControl(
        labels: [
            String(localized: "Unified", comment: "A single-column diff layout."),
            String(localized: "Split", comment: "A side-by-side diff layout."),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let divider = NSView()
    private var onDiffStyleChange: ((DiffStyle) -> Void)?
    private var onWrapLinesChange: ((Bool) -> Void)?
    private var onEditingChange: ((Bool) -> Void)?
    private var onReviewChange: ((Bool) -> Void)?
    private var onComments: (() -> Void)?
    private var onRefreshComments: (() -> Void)?
    private var onPullRequestReview: (() -> Void)?
    private var reviewTitle = ""
    private var commentsTitle = ""
    private var canEdit = false
    private var showsLayout = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        leadingControls.orientation = .horizontal
        leadingControls.alignment = .centerY
        leadingControls.spacing = 8
        leadingControls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leadingControls)
        for button in [reviewButton, commentsButton, refreshButton, pullRequestReviewButton] { leadingControls.addArrangedSubview(button) }
        reviewButton.onToggle = { [weak self] in self?.onReviewChange?($0) }
        commentsButton.bezelStyle = .accessoryBarAction
        commentsButton.controlSize = .small
        commentsButton.imagePosition = .imageLeading
        commentsButton.target = self
        commentsButton.action = #selector(commentsClicked)
        refreshButton.onAction = { [weak self] in self?.onRefreshComments?() }
        pullRequestReviewButton.onAction = { [weak self] in self?.onPullRequestReview?() }

        trailingControls.orientation = .horizontal
        trailingControls.alignment = .centerY
        trailingControls.spacing = 8
        trailingControls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingControls)
        for control in [modeControl, layoutControl] {
            control.controlSize = .small
            trailingControls.addArrangedSubview(control)
        }
        trailingControls.addArrangedSubview(optionsButton)
        trailingControls.addArrangedSubview(wrapLinesButton)
        optionsButton.isHidden = true
        optionsButton.onAction = { [weak self] in self?.showOptions() }
        wrapLinesButton.setButtonType(.pushOnPushOff)
        wrapLinesButton.onAction = { [weak self] in
            guard let self else { return }
            self.onWrapLinesChange?(self.wrapLinesButton.state == .on)
        }
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel(String(localized: "Diff Mode"))
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)
        layoutControl.setAccessibilityLabel(String(localized: "Diff Layout"))

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            leadingControls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leadingControls.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingControls.trailingAnchor.constraint(lessThanOrEqualTo: trailingControls.leadingAnchor, constant: -8),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),
            refreshButton.heightAnchor.constraint(equalToConstant: 24),
            pullRequestReviewButton.widthAnchor.constraint(equalToConstant: 24),
            pullRequestReviewButton.heightAnchor.constraint(equalToConstant: 24),
            wrapLinesButton.widthAnchor.constraint(equalToConstant: 24),
            wrapLinesButton.heightAnchor.constraint(equalToConstant: 24),
            optionsButton.widthAnchor.constraint(equalToConstant: 24),
            optionsButton.heightAnchor.constraint(equalToConstant: 24),
            trailingControls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailingControls.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        diffStyle: DiffStyle,
        wrapsLines: Bool,
        isEditing: Bool,
        canEdit: Bool,
        showsLayout: Bool,
        reviewAvailable: Bool,
        reviewed: Bool,
        commentsAvailable: Bool,
        showsComments: Bool,
        reviewActionsAvailable: Bool,
        onDiffStyleChange: @escaping (DiffStyle) -> Void,
        onWrapLinesChange: @escaping (Bool) -> Void,
        onEditingChange: @escaping (Bool) -> Void,
        onReviewChange: @escaping (Bool) -> Void,
        onComments: @escaping () -> Void,
        onRefreshComments: @escaping () -> Void,
        onPullRequestReview: @escaping () -> Void
    ) {
        self.canEdit = canEdit
        self.showsLayout = showsLayout
        self.onDiffStyleChange = onDiffStyleChange
        self.onWrapLinesChange = onWrapLinesChange
        self.onEditingChange = onEditingChange
        self.onReviewChange = onReviewChange
        self.onComments = onComments
        self.onRefreshComments = onRefreshComments
        self.onPullRequestReview = onPullRequestReview
        updateAppearanceColors()
        reviewButton.update(reviewed: reviewed, available: reviewAvailable)
        reviewTitle = reviewButton.title
        reviewButton.isHidden = showsComments || !reviewAvailable
        commentsButton.isHidden = !commentsAvailable && !showsComments
        commentsTitle = showsComments ? String(localized: "Back to Changes") : String(localized: "PR Comments")
        commentsButton.title = commentsTitle
        commentsButton.image = NSImage(systemSymbolName: showsComments ? "chevron.left" : "text.bubble", accessibilityDescription: nil)
        commentsButton.setAccessibilityLabel(commentsButton.title)
        commentsButton.toolTip = commentsButton.title
        refreshButton.isHidden = !showsComments || !commentsAvailable
        refreshButton.configure(symbol: "arrow.clockwise", label: String(localized: "Refresh PR Comments"))
        pullRequestReviewButton.isHidden = !showsComments
        pullRequestReviewButton.isEnabled = reviewActionsAvailable
        pullRequestReviewButton.configure(symbol: "checkmark.bubble", label: String(localized: "Review Pull Request…"))

        modeControl.setLabel(String(localized: "Review", comment: "Read-only mode for a diff."), forSegment: 0)
        modeControl.setLabel(String(localized: "Edit", comment: "Editable mode for a diff."), forSegment: 1)
        modeControl.setAccessibilityLabel(String(localized: "Diff Mode"))
        layoutControl.setLabel(String(localized: "Unified", comment: "A single-column diff layout."), forSegment: 0)
        layoutControl.setLabel(String(localized: "Split", comment: "A side-by-side diff layout."), forSegment: 1)
        layoutControl.setAccessibilityLabel(String(localized: "Diff Layout"))
        layoutControl.selectedSegment = diffStyle == .split ? 1 : 0
        modeControl.isHidden = !canEdit
        layoutControl.isHidden = !showsLayout
        wrapLinesButton.isHidden = !showsLayout
        wrapLinesButton.configure(symbol: "arrow.turn.down.left", label: String(localized: "Wrap lines to diff width"))
        wrapLinesButton.state = wrapsLines ? .on : .off
        wrapLinesButton.contentTintColor = wrapsLines ? .controlAccentColor : .secondaryLabelColor
        wrapLinesButton.setAccessibilityValue(wrapsLines ? 1 : 0)
        optionsButton.configure(symbol: "ellipsis", label: String(localized: "Diff Options"))
        modeControl.setEnabled(canEdit, forSegment: 1)
        modeControl.selectedSegment = canEdit && isEditing ? 1 : 0
        needsLayout = true
    }

    override func layout() {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        func width(_ title: String, hidden: Bool) -> CGFloat {
            hidden ? 0 : (title as NSString).size(withAttributes: [.font: font]).width + 32
        }
        let segments: [(NSSegmentedControl, [String], [String])] = [
            (modeControl, [String(localized: "Review"), String(localized: "Edit")], ["eye", "pencil"]),
            (layoutControl, [String(localized: "Unified"), String(localized: "Split")], ["rectangle", "rectangle.split.2x1"]),
        ]
        let trailingWidth = segments.reduce(CGFloat(0)) { total, entry in
            let available = entry.0 === modeControl ? canEdit : showsLayout
            return total + (available ? entry.1.reduce(CGFloat(0)) { $0 + width($1, hidden: false) } + 8 : 0)
        } + (wrapLinesButton.isHidden ? 0 : 32)
        let expandedWidth = width(reviewTitle, hidden: reviewButton.isHidden)
            + width(commentsTitle, hidden: commentsButton.isHidden)
            + (refreshButton.isHidden ? 0 : 32) + (pullRequestReviewButton.isHidden ? 0 : 32)
            + trailingWidth + 36
        let compact = bounds.width < expandedWidth
        let review = compact ? "" : reviewTitle, comments = compact ? "" : commentsTitle
        if reviewButton.title != review { reviewButton.title = review }
        if commentsButton.title != comments { commentsButton.title = comments }
        let compactLeadingWidth: CGFloat = (reviewButton.isHidden ? 0 : 32) + (commentsButton.isHidden ? 0 : 32)
            + (refreshButton.isHidden ? 0 : 32) + (pullRequestReviewButton.isHidden ? 0 : 32)
        let compactSegments = bounds.width < compactLeadingWidth + trailingWidth + 36
        for (control, titles, symbols) in segments {
            for index in titles.indices {
                let title = compactSegments ? "" : titles[index]
                if control.label(forSegment: index) != title { control.setLabel(title, forSegment: index) }
                control.setImage(compactSegments ? NSImage(systemSymbolName: symbols[index], accessibilityDescription: titles[index]) : nil,
                    forSegment: index)
                control.setWidth(compactSegments ? 24 : 0, forSegment: index)
                control.setToolTip(titles[index], forSegment: index)
            }
        }
        let minimumWidth = compactLeadingWidth + (canEdit ? 68 : 0) + (showsLayout ? 68 : 0)
            + (wrapLinesButton.isHidden ? 0 : 32) + 36
        let usesMenu = bounds.width < minimumWidth
        leadingControls.isHidden = usesMenu
        modeControl.isHidden = !canEdit || usesMenu
        layoutControl.isHidden = !showsLayout || usesMenu
        optionsButton.isHidden = !usesMenu
        super.layout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
        modeControl.needsDisplay = true
        layoutControl.needsDisplay = true
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.background.cgColor
            divider.layer?.backgroundColor = Theme.divider.cgColor
        }
    }

    @objc private func modeChanged() {
        onEditingChange?(modeControl.selectedSegment == 1)
    }

    @objc private func layoutChanged() {
        onDiffStyleChange?(layoutControl.selectedSegment == 1 ? .split : .unified)
    }

    @objc private func commentsClicked() { onComments?() }

    private func showOptions() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, tag: Int, checked: Bool = false, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(optionSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = checked ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if !reviewButton.isHidden { item(reviewTitle, tag: 0, checked: reviewButton.accessibilityValue() as? String == String(localized: "Reviewed")) }
        if !commentsButton.isHidden { item(commentsTitle, tag: 1) }
        if !refreshButton.isHidden { item(String(localized: "Refresh PR Comments"), tag: 2) }
        if !pullRequestReviewButton.isHidden { item(String(localized: "Review Pull Request…"), tag: 3, enabled: pullRequestReviewButton.isEnabled) }
        if !menu.items.isEmpty && (canEdit || showsLayout) { menu.addItem(.separator()) }
        if canEdit {
            item(String(localized: "Review"), tag: 4, checked: modeControl.selectedSegment == 0)
            item(String(localized: "Edit"), tag: 5, checked: modeControl.selectedSegment == 1)
        }
        if showsLayout {
            item(String(localized: "Unified"), tag: 6, checked: layoutControl.selectedSegment == 0)
            item(String(localized: "Split"), tag: 7, checked: layoutControl.selectedSegment == 1)
        }
        menu.popUp(positioning: nil, at: .zero, in: optionsButton)
    }

    @objc private func optionSelected(_ item: NSMenuItem) {
        switch item.tag {
        case 0: reviewButton.performClick(nil)
        case 1: onComments?()
        case 2: onRefreshComments?()
        case 3: onPullRequestReview?()
        case 4, 5: onEditingChange?(item.tag == 5)
        case 6, 7: onDiffStyleChange?(item.tag == 7 ? .split : .unified)
        default: break
        }
    }
}
