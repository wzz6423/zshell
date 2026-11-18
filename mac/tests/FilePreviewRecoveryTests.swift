import AppKit
import Combine
import Darwin
import Foundation
import ObjectiveC.runtime
import STTextView
import UniformTypeIdentifiers
@testable import zshell

@main
@MainActor
struct FilePreviewRecoveryTests {
    private static var checks = 0
    private nonisolated static let markdown = "# 真实 Markdown 😀\n\nA **bold** paragraph with 中文.\n"

    static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        #if !FILE_PREVIEW_SOURCE_MODEL && !FILE_PREVIEW_BASELINE
        FilePreviewPickerSelection.install()
        #endif
        Task { @MainActor in await run() }
        NSApplication.shared.run()
    }

    private static func run() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
            try check(AppSettings.shared.terminalBackend.rawValue == CommandLine.arguments[3],
                      "the fixture loads its requested terminal backend setting")
            #if FILE_PREVIEW_BASELINE
            try await baseline(root, requireMissingAction: CommandLine.arguments[1] == "missing-action")
            #else
            try await recovery(root)
            #if !FILE_PREVIEW_SOURCE_MODEL
            try await restoredWorkspace(root)
            #endif
            #endif
            try check(QuickTerminalOffscreen.isSafe(), "fixture never becomes visible or active")
            print("FILE_PREVIEW_SUCCESS case=\(CommandLine.arguments[1]) backend=\(CommandLine.arguments[3]) checks=\(checks)")
            exit(0)
        } catch {
            fputs("FILE_PREVIEW_FAILURE \(error)\n", stderr)
            exit(1)
        }
    }

    private static func check(_ condition: Bool, _ label: String) throws {
        checks += 1
        guard condition else {
            throw NSError(domain: "FilePreviewRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
        }
        print("PASS \(label)")
    }

    private static func wait(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "FilePreviewRecovery", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out: " + label])
    }

    private static func loaded(_ url: URL, recoveringDraft: Bool = false) async throws -> FileTab {
        let file = FileTab(path: url.path, recoveringDraft: recoveringDraft)
        try await wait("file read settles") {
            if case .unavailable(let message) = file.content { return !message.isEmpty }
            return true
        }
        return file
    }

    private static func write(_ url: URL, text: String = markdown) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    #if !FILE_PREVIEW_SOURCE_MODEL
    private static func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        [root as? T].compactMap { $0 } + root.subviews.flatMap { descendants($0, type) }
    }

    private static func update(_ view: FileViewerContainerView, source: Bool) {
        view.update(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    palette: .theme(dark: false), wrapLines: true, isFocused: false,
                    showsSource: source, onFocused: {}, onSplit: { _ in })
        view.layoutSubtreeIfNeeded()
    }

    private static func mounted(_ file: FileTab) -> (FileViewerContainerView, NSWindow) {
        let view = FileViewerContainerView(file: file)
        let window = NSWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 680, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        update(view, source: false)
        return (view, window)
    }

    #if !FILE_PREVIEW_BASELINE
    private static func choose(in window: NSWindow, using button: NSButton, url: URL) async throws {
        button.performClick(nil)
        try await wait("native picker opens") { window.attachedSheet is NSOpenPanel }
        let panel = window.attachedSheet as! NSOpenPanel
        // Only the OS file selection is supplied by the fixture. The actual
        // sheet completion, asynchronous FileTab read and alert are production.
        FilePreviewPickerSelection.panel = panel
        FilePreviewPickerSelection.url = url
        window.endSheet(panel, returnCode: .OK)
        try await wait("native picker completes") { !(window.attachedSheet is NSOpenPanel) }
    }
    #endif

    private static func markdownViews(_ file: FileTab) async throws {
        let original = file.text
        let (view, window) = mounted(file)
        defer { window.contentView = nil; window.close() }
        try await wait("Markdown render") {
            (file.editorView as? MarkdownPreviewView)?.findTarget.string.contains("真实 Markdown") == true
        }
        let preview = file.editorView as! MarkdownPreviewView
        try check(!preview.findTarget.string.contains("**bold**"), "Markdown renders formatting in its AppKit preview")
        update(view, source: true)
        let editor = (file.editorView as? NSScrollView)?.documentView as? STTextView
        try check(editor != nil && file.text == original, "source view opens with the complete original UTF-8 text")
        let edited = original + "\nunsaved **preview round trip** 中文\n"
        editor!.insertText(edited, replacementRange: NSRange(location: 0, length: original.utf16.count))
        try check(file.isDirty && file.text == edited, "real source editor writes its draft back to the tab")
        update(view, source: false)
        try await wait("edited Markdown render") {
            (file.editorView as? MarkdownPreviewView)?.findTarget.string.contains("unsaved preview round trip") == true
        }
        update(view, source: true)
        try check(((file.editorView as? NSScrollView)?.documentView as? STTextView) === editor,
                  "preview/source switching reuses the source editor and its undo history")
        try check(file.text == edited && file.isDirty, "preview/source switching retains unsaved Unicode content")
        file.reloadFromDiskIfClean()
        try await Task.sleep(for: .milliseconds(30))
        try check(file.text == edited && file.isDirty, "a clean reload request cannot replace the editor draft")
        try check(!window.isVisible, "Markdown and source views use a hidden native window")
    }
    #endif

    #if FILE_PREVIEW_BASELINE
    private static func baseline(_ root: URL, requireMissingAction: Bool) async throws {
        let path = root.appendingPathComponent("中文 directory/README.zh-CN.md")
        try write(path)
        let file = try await loaded(path)
        defer { file.close() }
        try check(file.text == markdown, "normal readable Markdown bytes load")
        try await markdownViews(file)
        let missing = try await loaded(root.appendingPathComponent("removed-worktree/README.zh-CN.md"))
        defer { missing.close() }
        let (view, window) = mounted(missing)
        defer { window.contentView = nil; window.close() }
        let actions = descendants(view, NSButton.self).filter { $0.accessibilityIdentifier() == "file-preview.locate" }
        if requireMissingAction {
            try check(actions.count == 1, "missing restored files expose a native locate action")
        } else {
            try check(actions.isEmpty, "baseline reproduces the unrecoverable missing-file placeholder")
        }
    }
    #else
    private static func isMissing(_ file: FileTab) -> Bool { if case .missing = file.content { return true }; return false }

    private static func recovery(_ root: URL) async throws {
        let path = root.appendingPathComponent("中文 directory/README.zh-CN.md")
        try write(path)
        let stale = root.appendingPathComponent("removed-worktree/zshell/promo/README.zh-CN.md")
        let file = try await loaded(stale, recoveringDraft: true)
        defer { file.close() }
        let identity = file.id, draftID = file.draftID
        let state = EditorState(selectionLocation: 5, selectionLength: 2, scrollX: 0, scrollY: 15)
        file.editorState = state
        try check(isMissing(file) && !file.isDirty, "restoring a removed worktree yields a distinct missing state")
        #if !FILE_PREVIEW_SOURCE_MODEL
        let (view, window) = mounted(file)
        defer { window.contentView = nil; window.close() }
        let buttons = descendants(view, NSButton.self).filter { $0.accessibilityIdentifier() == "file-preview.locate" }
        try check(buttons.count == 1 && buttons[0].isEnabled, "missing restored files expose an enabled native locate action")
        try check(descendants(view, NSTextField.self).contains { $0.stringValue == stale.path && $0.isSelectable },
                  "the missing placeholder displays its selectable original path")
        buttons[0].performClick(nil)
        try await wait("native file picker") { window.attachedSheet != nil }
        guard let chooser = window.attachedSheet as? NSOpenPanel else {
            throw NSError(domain: "FilePreviewRecovery", code: 3)
        }
        try check(chooser.canChooseFiles && !chooser.canChooseDirectories && !chooser.allowsMultipleSelection,
                  "Locate File opens the single-file native picker")
        window.endSheet(chooser, returnCode: .cancel)
        try await wait("file picker cancels") { window.attachedSheet == nil }
        try check(file.path == stale.path && isMissing(file), "cancelling the native picker keeps the original missing tab")
        let selectedURL = root.appendingPathComponent("picker-selected.md")
        try write(selectedURL)
        try await choose(in: window, using: buttons[0], url: selectedURL)
        try await wait("native picker success callback") { file.path == selectedURL.path && !isMissing(file) }
        try check(file.path == selectedURL.path && file.id == identity && file.text == markdown,
                  "the native picker OK callback opens the selected real file in the same tab")
        try FileManager.default.removeItem(at: selectedURL)
        file.reloadFromDiskIfClean()
        try await wait("picker target becomes missing") { isMissing(file) }
        file.updatePath(stale.path)
        update(view, source: false)
        try check(descendants(view, NSTextField.self).contains { $0.stringValue == stale.path },
                  "a missing-to-missing path change updates the displayed recovery path")
        let locate = descendants(view, NSButton.self).first { $0.accessibilityIdentifier() == "file-preview.locate" }!
        let invalid = root.appendingPathComponent("picker-denied.md")
        try write(invalid)
        chmod(invalid.path, 0)
        try await choose(in: window, using: locate, url: invalid)
        try await wait("native picker read-error callback") { window.attachedSheet != nil && !(window.attachedSheet is NSOpenPanel) }
        chmod(invalid.path, 0o600)
        try check(file.path == stale.path && isMissing(file), "the picker read-error callback preserves the original missing path")
        window.endSheet(window.attachedSheet!, returnCode: .alertFirstButtonReturn)
        try await wait("read-error alert closes") { window.attachedSheet == nil }
        #endif
        let missingTarget = root.appendingPathComponent("also-missing.md")
        try check(await file.reopen(at: missingTarget) == false, "a missing target cannot replace the original path")
        let directory = root.appendingPathComponent("中文 directory")
        try check(await file.reopen(at: directory) == false, "a directory cannot replace the original path")
        let binary = root.appendingPathComponent("binary.md")
        try Data([0, 1, 2]).write(to: binary)
        try check(await file.reopen(at: binary) == false, "binary Markdown cannot replace the original path")
        let denied = root.appendingPathComponent("denied.md")
        try write(denied)
        try check(chmod(denied.path, 0) == 0 && geteuid() != 0, "unreadable target fixture denies reads")
        let deniedResult = await file.reopen(at: denied)
        chmod(denied.path, 0o600)
        try check(!deniedResult && file.path == stale.path && file.editorState == state,
                  "failed reads keep the original path and stored editor position")
        let deniedPDF = root.appendingPathComponent("denied.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: deniedPDF)
        chmod(deniedPDF.path, 0)
        let deniedPDFResult = await file.reopen(at: deniedPDF)
        chmod(deniedPDF.path, 0o600)
        try check(!deniedPDFResult && file.path == stale.path,
                  "an unreadable Quick Look target cannot replace the missing path")
        try check(await file.reopen(at: URL(string: "https://fixture.invalid/file.md")!) == false,
                  "a remote URL cannot become a local replacement")
        let cancelled = Task { @MainActor in await file.reopen(at: path) }
        cancelled.cancel()
        try check(await cancelled.value == false && file.path == stale.path, "cancelled reads cannot re-point the missing tab")
        let reopened = await file.reopen(at: path)
        try check(reopened && file.path == path.path && file.id == identity && file.draftID == draftID,
                  "a readable selection reopens the same tab and draft identity")
        try check(file.text == markdown && !file.isDirty && file.editorState == state,
                  "selected Markdown loads all bytes and preserves stored editor state")
        try check(file.saveBaseline?.matches(try FileSaveCoordinator.read(path: path.path)) == true,
                  "reopened content and save baseline describe the same selected file")
        try check(!FileManager.default.fileExists(atPath: stale.path), "locating a file never recreates the deleted path")
        #if !FILE_PREVIEW_SOURCE_MODEL
        try await markdownViews(file)
        #else
        file.text += "unsaved 中文\n"; file.refreshDirtyState()
        #endif
        let draft = file.text
        try check(await file.reopen(at: path) == false && file.text == draft && file.isDirty,
                  "locate refuses a readable or dirty tab without losing its draft")
        var conflicts = 0
        let saved = file.save { _, _ in conflicts += 1; return .keepDraft }
        try check(saved && conflicts == 0 && !file.isDirty, "saving a reopened draft uses the selected file's baseline")
        try check(try String(contentsOf: path, encoding: .utf8) == draft, "save writes only the explicitly selected path")
        try await boundaries(root, target: path)
    }

    private static func boundaries(_ root: URL, target: URL) async throws {
        let normal = root.appendingPathComponent("normal.md")
        try write(normal)
        let file = try await loaded(normal)
        defer { file.close() }
        let moved = root.appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: normal, to: moved)
        let revision = file.reloadRevision
        file.updatePath(moved.path)
        try check(file.text == markdown && file.reloadRevision == revision,
                  "a loaded file rename retains its content without re-reading")
        try check(file.saveBaseline?.destinationPath == moved.path, "rename re-points the existing save baseline")
        try FileManager.default.removeItem(at: moved)
        file.reloadFromDiskIfClean()
        try await wait("deleted clean file") { isMissing(file) }
        try write(moved)
        file.reloadFromDiskIfClean()
        try await wait("restored original path") { file.text == markdown }
        try check(!isMissing(file) && file.path == moved.path, "reappearing files resume normal reads at the original path")
        let alias = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let linked = try await loaded(root.appendingPathComponent("missing-link-tab.md"))
        defer { linked.close() }
        try check(await linked.reopen(at: alias), "a readable symbolic link can be explicitly selected")
        try check(linked.path == alias.path && linked.saveBaseline?.destinationPath == target.path,
                  "symlink display path and resolved save target keep their existing semantics")
        let package = root.appendingPathComponent("document.rtfd")
        let attributed = NSAttributedString(string: "Native Quick Look package 中文")
        let wrapper = try attributed.fileWrapper(from: NSRange(location: 0, length: attributed.length),
                                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        try wrapper.write(to: package, options: .atomic, originalContentsURL: nil)
        let packageFile = try await loaded(package)
        defer { packageFile.close() }
        let type = UTType(filenameExtension: "rtfd")
        let quickLookEligible = type?.conforms(to: .text) == false && type?.conforms(to: .compositeContent) == true
        try check({
            if case .quickLook = packageFile.content { return quickLookEligible }
            if case .unavailable = packageFile.content { return !quickLookEligible }
            return false
        }(), "RTFD packages preserve the registered content type's existing preview route")
        let compositeDirectory = root.appendingPathComponent("document.pages")
        try FileManager.default.createDirectory(at: compositeDirectory, withIntermediateDirectories: false)
        let composite = try await loaded(compositeDirectory)
        defer { composite.close() }
        try check({ if case .quickLook = composite.content { return true }; return false }(),
                  "existing composite-content directories still open through Quick Look")
        let imageURL = root.appendingPathComponent("image.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        let image = try await loaded(imageURL)
        defer { image.close() }
        try check({ if case .image = image.content { return true }; return false }(),
                  "existing PNG files keep their native image preview")
        let fifo = root.appendingPathComponent("queue.md")
        try check(mkfifo(fifo.path, 0o600) == 0, "nonblocking read fixture creates a FIFO")
        let unavailable = try await loaded(fifo)
        defer { unavailable.close() }
        try check({ if case .unavailable = unavailable.content { return true }; return false }(),
                  "special files keep the existing unreadable-file state without blocking")
        let closed = try await loaded(root.appendingPathComponent("closed.md"))
        closed.close()
        try check(await closed.reopen(at: target) == false, "closing a missing tab prevents a late replacement read")
        let remote = FileTab(path: target.path, source: .unavailableRemote)
        defer { remote.close() }
        try check(await remote.reopen(at: target) == false && remote.text.isEmpty,
                  "a remote tab cannot reopen a coincidentally matching local file")
        let renamed = try await loaded(root.appendingPathComponent("during-rename.md"))
        defer { renamed.close() }
        var changed = false
        let observation = renamed.$isReopening.dropFirst().sink { reopening in
            if reopening && !changed { changed = true; renamed.updatePath(root.appendingPathComponent("new-missing.md").path) }
        }
        try check(await renamed.reopen(at: target) == false && renamed.path.hasSuffix("/new-missing.md"),
                  "a path change during replacement invalidates the older result")
        withExtendedLifetime(observation) {}
        for ext in ["png", "pdf", "svg"] {
            let media = try await loaded(root.appendingPathComponent("absent." + ext))
            try check(isMissing(media), "missing \(ext) previews preserve the missing-file state")
            media.close()
        }
    }

    #if !FILE_PREVIEW_SOURCE_MODEL
    private static func restoredWorkspace(_ root: URL) async throws {
        typealias Snapshot = SessionSnapshot.ProjectSnapshot
        let path = root.appendingPathComponent("workspace/README.zh-CN.md")
        try write(path)
        let stale = root.appendingPathComponent("removed-workspace/README.zh-CN.md")
        let saved = Snapshot.TabSnapshot(layout: .pane(.init(content: .file(path: stale.path, editorState: .init(selectionLocation: 4)),
                                                               weight: 1)), focusedPaneIndex: 0)
        SessionStore.save([SessionSnapshot(projects: [Snapshot(customName: "File fixture", customDirectory: root.path,
                                                               tabs: [saved], selectedTabIndex: 0)], selectedProjectIndex: 0)])
        let manager = TerminalManager()
        defer { for project in manager.projects { project.terminateAll() } }
        guard let project = manager.selectedProject, let tab = project.selectedTab,
              case .file(let file)? = project.focusedContent else {
            throw NSError(domain: "FilePreviewRecovery", code: 4)
        }
        try await wait("session restore missing file") { isMissing(file) }
        try check(project.sessions.isEmpty && file.path == stale.path && file.editorState.selectionLocation == 4,
                  "production session restore preserves the missing path and file-only layout")
        let tabID = tab.id, paneID = file.id
        try check(await file.reopen(at: path), "the production restored tab accepts an explicit readable replacement")
        try check(project.selectedTab?.id == tabID && project.focusedContent?.id == paneID,
                  "replacement keeps the restored tab, pane and selection")
        try await Task.sleep(for: .milliseconds(650))
        let snapshots = SessionStore.load()
        guard case .pane(let pane)? = snapshots.first?.projects.first?.tabs.first?.layout,
              case .file(let storedPath, _ ) = pane.content else {
            throw NSError(domain: "FilePreviewRecovery", code: 5)
        }
        try check(storedPath == path.path, "ordinary workspace autosave remembers the explicitly located path")
        var tabUpdates = 0
        let observation = tab.objectWillChange.sink { _ in tabUpdates += 1 }
        let replacement = try await loaded(root.appendingPathComponent("replacement-missing.md"))
        defer { replacement.close() }
        let replacementPane = Pane(content: .file(replacement))
        tab.layout = .pane(replacementPane)
        tab.focusedPaneID = replacementPane.id
        let afterLayout = tabUpdates
        file.updatePath(root.appendingPathComponent("old-file-renamed.md").path)
        try check(tabUpdates == afterLayout, "replacing the layout releases the old file path observation")
        replacement.updatePath(root.appendingPathComponent("replacement-renamed.md").path)
        try check(tabUpdates > afterLayout, "the replacement layout observes its current file path")
        let fresh = PaneTab(content: .file(replacement))
        var freshUpdates = 0
        let freshObservation = fresh.objectWillChange.sink { _ in freshUpdates += 1 }
        replacement.updatePath(root.appendingPathComponent("replacement-current.md").path)
        try check(freshUpdates == 1, "fresh single-file tabs propagate path changes without focus changes")
        withExtendedLifetime([observation, freshObservation]) {}
    }
    #endif
    #endif
}

#if !FILE_PREVIEW_SOURCE_MODEL && !FILE_PREVIEW_BASELINE
@MainActor
private enum FilePreviewPickerSelection {
    static weak var panel: NSOpenPanel?
    static var url: URL?

    static func install() {
        let original = class_getInstanceMethod(NSOpenPanel.self, NSSelectorFromString("URL"))!
        let selected = class_getInstanceMethod(NSOpenPanel.self, #selector(NSOpenPanel.filePreview_selectedURL))!
        method_exchangeImplementations(original, selected)
    }
}

extension NSOpenPanel {
    @objc fileprivate func filePreview_selectedURL() -> NSURL? {
        if self === FilePreviewPickerSelection.panel { return FilePreviewPickerSelection.url as NSURL? }
        return filePreview_selectedURL()
    }
}
#endif
