import AppKit
import Darwin
import Foundation
import PierreDiffsSwift
import STTextView
import WebKit
@testable import zshell

@main
struct EditorDraftRecoveryTests {
    @MainActor private static var checks = 0
    @MainActor private static let fileDraft = "Recovered 中文 😀 é\nunsaved file text\n"
    @MainActor private static let diffDraft = "Recovered diff 中文 👩🏽‍💻\nunsaved diff text\n"

    @MainActor static func main() async {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        do {
            let phase = CommandLine.arguments[1]
            let root = try SettingsConfigFile.resolve(URL(fileURLWithPath: CommandLine.arguments[2]))
            switch phase {
            case "write": try await write(root)
            case "normal-write": try await write(root, normalExit: true)
            case "restore": try await restore(root)
            case "boundaries": try await boundaries(root)
            case "quota": try await quota(root)
            case "expiry": try await expiry(root)
            case "workspace": try await workspace(root)
            default: throw failure("Unknown phase")
            }
            print("EDITOR_DRAFT_SUCCESS phase=\(phase) checks=\(checks)")
            exit(0)
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func check(_ passed: Bool, _ label: String) throws {
        checks += 1
        print("\(passed ? "PASS" : "FAIL") \(label)")
        if !passed { throw failure(label) }
    }

    private static func failure(_ label: String) -> NSError {
        NSError(domain: "EditorDraftRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }

    @MainActor private static func wait(_ label: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw failure("Timed out: \(label)")
    }

    @MainActor private static func loaded(_ path: URL) async throws -> FileTab {
        let file = FileTab(path: path.path)
        try await wait("file loads") { if case .text = file.content { return true }; return false }
        return file
    }

    @MainActor private static func loadedDiff(_ root: URL, name: String) async throws -> DiffTab {
        let diff = DiffTab(repoRoot: root.path, path: name, staged: false, untracked: true, origPath: nil)
        try await wait("diff loads") { !diff.isLoading }
        try check(diff.isEditable && diff.saveBaseline != nil, "the production worktree diff loaded its disk baseline")
        return diff
    }

    @MainActor private static func write(_ root: URL, normalExit: Bool = false) async throws {
        SessionStore.save([])
        let settings = AppSettings.shared
        try check(settings.recoverEditorDrafts && settings.protectEditorSaves, "both safety settings are enabled by default")
        let path = root.appendingPathComponent("old-name.txt")
        try "baseline 中文\n".write(to: path, atomically: true, encoding: .utf8)
        let file = try await loaded(path)
        let editor = SourceEditorController(file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            palette: .theme(dark: false), wrapLines: true, isFocused: false, onFocused: {}, onSplit: { _ in })
        let text = editor.scrollView.documentView as! STTextView
        text.textSelection = NSRange(location: 0, length: file.text.utf16.count)
        text.insertText(fileDraft)
        try check(file.text == fileDraft && file.isDirty, "real AppKit editing creates an unsaved file buffer")
        file.editorState = EditorState(selectionLocation: 13, selectionLength: 2, scrollX: 0, scrollY: 36)
        let renamed = root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: path, to: renamed)
        file.updatePath(renamed.path)

        let diffPath = root.appendingPathComponent("diff.txt")
        try "diff baseline\n".write(to: diffPath, atomically: true, encoding: .utf8)
        let diff = try await loadedDiff(root, name: "diff.txt")
        diff.updateEditedContent(fileID: diff.web.fileID, contents: diffDraft)
        diff.setDiffStyle(.split)
        diff.setEditing(true)
        diff.web.onEditorStateChange?(diff.web.fileID, PierreEditorState(selections: [
            .init(start: .init(line: 0, character: 10), end: .init(line: 0, character: 12), direction: 1)
        ], view: .init(scrollLeft: 20), scrollTop: 30))

        let deletedPath = root.appendingPathComponent("deleted.txt")
        try "deleted baseline".write(to: deletedPath, atomically: true, encoding: .utf8)
        let deleted = try await loaded(deletedPath)
        deleted.text = "deleted file draft"
        deleted.refreshDirtyState()
        let originalPath = root.appendingPathComponent("symlink-target.txt")
        try "symlink baseline".write(to: originalPath, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: originalPath.path)
        let linked = try await loaded(link)
        linked.text = "symlink draft"
        linked.refreshDirtyState()

        // Capture the real production layout shape, including a dirty file and diff.
        let layout = SessionSnapshot.ProjectSnapshot.LayoutSnapshot.split(axis: .horizontal, fraction: 0.63,
            first: .pane(.init(content: .file(path: path.path, editorState: file.editorState), weight: 1, draftID: file.draftID)),
            second: .pane(.init(content: .diff(repoRoot: root.path, path: "diff.txt", staged: false, untracked: true, origPath: nil),
                                weight: 1, draftID: diff.draftID)))
        let split = SessionSnapshot.ProjectSnapshot.TabSnapshot(layout: layout, focusedPaneIndex: 1)
        let singleDeleted = SessionSnapshot.ProjectSnapshot.TabSnapshot(layout: .pane(.init(
            content: .file(path: deletedPath.path, editorState: nil), weight: 1, draftID: deleted.draftID)), focusedPaneIndex: 0)
        let singleLinked = SessionSnapshot.ProjectSnapshot.TabSnapshot(layout: .pane(.init(
            content: .file(path: link.path, editorState: nil), weight: 1, draftID: linked.draftID)), focusedPaneIndex: 0)
        let snapshots = [split, singleDeleted, singleLinked]
        try JSONEncoder().encode(snapshots).write(to: root.appendingPathComponent("layout.json"))
        let manager = TerminalManager()
        for project in manager.projects { project.terminateAll() }
        manager.openOrFocusDirectories([root.path])
        let project = manager.selectedProject!
        let filePane = Pane(content: .file(file)), diffPane = Pane(content: .diff(diff))
        project.append(PaneTab(layout: .split(.init(axis: .horizontal, fraction: 0.63,
            first: .pane(filePane), second: .pane(diffPane))), focusedPaneID: diffPane.id))
        project.append(PaneTab(content: .file(deleted)))
        project.append(PaneTab(content: .file(linked)))
        // Exercise the ordinary timer rather than calling the test's write/flush path.
        try await Task.sleep(for: .milliseconds(900))
        let records = try await EditorDraftStore.shared.archive.records()
        try check(records.count == 4 && records.contains { $0.id == file.draftID && $0.path == renamed.path },
                  "automatic backup survives a rename with the same stable draft ID")
        try check(records.contains { $0.id == diff.draftID && $0.text == diffDraft && $0.diffState?.style == "split" },
                  "automatic backup captures dirty editable diff contents and layout")
        try await wait("the automatic session layout snapshot includes every editor") {
            Set(SessionStore.load().flatMap(\.projects).flatMap(\.tabs).flatMap { $0.layout.allDraftIDs })
                .isSuperset(of: [file.draftID, diff.draftID, deleted.draftID, linked.draftID])
        }
        if normalExit {
            TerminalManager.prepareForApplicationQuit(endAll: true)
            try check(SessionStore.load().flatMap(\.projects).flatMap(\.tabs).contains { $0.layout.allDraftIDs.contains(file.draftID) },
                      "the production final quit boundary persists stable editor draft IDs")
            UserDefaults.standard.synchronize()
            return
        }
        UserDefaults.standard.synchronize()
        print("EDITOR_DRAFT_READY_FOR_CRASH")
        // The Python driver sends SIGKILL while the process still owns all buffers.
        while true { try await Task.sleep(for: .milliseconds(50)) }
    }

    @MainActor private static func restore(_ root: URL) async throws {
        let snapshots = try JSONDecoder().decode([SessionSnapshot.ProjectSnapshot.TabSnapshot].self,
                                                 from: Data(contentsOf: root.appendingPathComponent("layout.json")))
        let restoringManager = TerminalManager()
        do {
            try await wait("the session store automatically restores four dirty editors") {
                restoringManager.projects.flatMap(\.tabs).flatMap(\.allContents).filter(\.isDirty).count == 4
            }
        } catch {
            print("SESSION_DIAGNOSTIC stored=\(SessionStore.load().flatMap(\.projects).flatMap(\.tabs).flatMap { $0.layout.allDraftIDs })")
            print("SESSION_DIAGNOSTIC dirty=\(restoringManager.projects.flatMap(\.tabs).flatMap(\.allContents).filter(\.isDirty).count)")
            throw error
        }
        try check(restoringManager.projects.flatMap(\.tabs).flatMap(\.allContents).filter(\.isDirty).count == 4,
                  "the production session store restores editor draft IDs across process exits")
        for project in restoringManager.projects {
            project.tabs.removeAll { $0.allContents.contains(where: \.isDirty) }
        }
        let project = restoringManager.newProject()
        defer { for project in restoringManager.projects { project.terminateAll() } }
        let tabs = snapshots.compactMap { project.restoreTab(from: $0) }
        do {
            try await wait("file and diff drafts restore from the production project path") {
                tabs.flatMap(\.allContents).filter(\.isDirty).count == 4
            }
        } catch {
            let records = try await EditorDraftStore.shared.archive.records()
            print("RECOVERY_DIAGNOSTIC archive=\(records.map { "\($0.id):\($0.path)" })")
            for content in tabs.flatMap(\.allContents) {
                print("RECOVERY_DIAGNOSTIC id=\(String(describing: content.draftID)) dirty=\(content.isDirty) path=\(content.fileIconPath ?? "")")
            }
            throw error
        }
        try check(tabs[0].allPanes.count == 2 && tabs[0].focusedPaneID == tabs[0].allPanes[1].id,
                  "relaunch restores split layout and focused diff pane")
        guard case .split(let split) = tabs[0].layout else { throw failure("split missing") }
        try check(abs(split.fraction - 0.63) < 0.001, "saved split fraction survives recovery")
        guard case .file(let file) = tabs[0].allContents[0], case .diff(let diff) = tabs[0].allContents[1],
              case .file(let deleted) = tabs[1].allContents[0], case .file(let linked) = tabs[2].allContents[0] else {
            throw failure("restored pane types")
        }
        try check(file.text == fileDraft && file.isDirty && file.editorState.selectionLocation == 13,
                  "the UTF-8 draft and UTF-16 selection survive SIGKILL and process restart")
        try check(file.path == root.appendingPathComponent("renamed.txt").path,
                  "a newer draft rename repairs the older layout path using the same stable ID")
        try check(file.saveBaseline?.text == "baseline 中文\n" && diff.saveBaseline?.text == "diff baseline\n",
                  "both recovered buffers retain their original baseline, not the changed disk version")
        try check(diff.unsavedText == diffDraft && diff.diffStyle == .split,
                  "dirty diff and its split style survive process restart")
        try check(diff.draftSnapshot()?.diffState?.editor?.selections?.first?.start.character == 10,
                  "the editable diff restores serialized caret state")
        var stateArrived = false
        let callback = diff.web.onEditorStateChange
        diff.web.onEditorStateChange = { id, state in
            callback?(id, state)
            if state.selections?.first?.start.character == 10 { stateArrived = true }
        }
        await diff.materializeWebHostView()
        func webView(in view: NSView) -> WKWebView? {
            (view as? WKWebView) ?? view.subviews.compactMap { webView(in: $0) }.first
        }
        guard let pierreWeb = diff.webHostView.flatMap({ webView(in: $0) }) else { throw failure("Pierre web view") }
        // WebKit pauses animation frames outside displays. Drive only that
        // scheduling clock; all rendering, editor state and bridge code is production.
        pierreWeb.configuration.userContentController.addUserScript(WKUserScript(source: """
            window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 16);
            window.cancelAnimationFrame = clearTimeout;
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let diffWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        diffWindow.isReleasedWhenClosed = false
        diffWindow.contentView = diff.webHostView
        diffWindow.orderFront(nil)
        defer { diffWindow.close() }
        do { try await wait("Pierre mounts recovered text and its caret") { stateArrived } }
        catch {
            if let web = diff.webHostView.flatMap({ webView(in: $0) }) {
                let value = try? await web.evaluateJavaScript("({ready: typeof window.pierreBridge, size: [innerWidth,innerHeight], hidden: document.hidden, html: document.getElementById('diff-container').outerHTML.slice(0,2500)})")
                print("PIERRE_DIAGNOSTIC ready=\(diff.web.isReady) \(String(describing: value))")
            }
            throw error
        }
        try check(diff.web.isReady && stateArrived && QuickTerminalOffscreen.isSafe(),
                  "the real AppKit Pierre bridge applies the recovered caret in a screen-hidden window")
        let mounted = SourceEditorController(file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            palette: .theme(dark: false), wrapLines: true, isFocused: false, onFocused: {}, onSplit: { _ in })
        let textView = mounted.scrollView.documentView as! STTextView
        try check(textView.text == fileDraft && textView.textSelection == NSRange(location: 13, length: 2),
                  "the production AppKit editor mounts the recovered buffer and selection")
        let fileDisk = try String(contentsOfFile: file.path, encoding: .utf8)
        let diffDisk = try String(contentsOf: root.appendingPathComponent("diff.txt"), encoding: .utf8)
        try check(fileDisk == "external file version" && diffDisk == "external diff version",
                  "restoring does not write either externally modified file")
        var conflicts = 0
        try check(!file.save { _, _ in conflicts += 1; return .keepDraft } && conflicts == 1,
                  "cancelled save after recovery retains the file draft and external version")
        conflicts = 0
        try check(!diff.save { _, _ in conflicts += 1; return .keepDraft } && conflicts == 1 && diff.isDirty,
                  "cancelled diff save after recovery retains its unsaved document")
        conflicts = 0
        try check(!deleted.save { conflict, _ in conflicts += 1; precondition(conflict.current.isMissing); return .keepDraft }
                  && conflicts == 1 && !FileManager.default.fileExists(atPath: deleted.path),
                  "recovery retains a deleted file's draft and asks before recreating it")
        conflicts = 0
        try check(!linked.save { _, _ in conflicts += 1; return .keepDraft } && conflicts == 1,
                  "a retargeted symlink cannot silently receive the recovered edits")

        // Repeated close requests share exact-text discard approvals, but a cancelled
        // outer request must leave every backup until its final commit boundary.
        do {
            let confirmation = UnsavedChangesConfirmation()!
            try check(confirmation.requiresConfirmation(.file(file)), "recovered edits still require close confirmation")
        }
        let recoveryHost = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        recoveryHost.isReleasedWhenClosed = false
        recoveryHost.identifier = NSUserInterfaceItemIdentifier("main-editor-draft-test")
        restoringManager.attach(to: recoveryHost)
        recoveryHost.orderFront(nil)
        defer { recoveryHost.close() }
        EditorDraftRecoveryController.shared.show(for: restoringManager)
        let panel = NSApp.windows.first { $0.identifier?.rawValue == "editor-draft-recovery" }!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let recoveryTable = descendants(panel.contentView!).compactMap { $0 as? NSTableView }.first!
        try await wait("the recovery manager loads backups") { recoveryTable.numberOfRows >= 4 }
        try check(panel.parent === recoveryHost && QuickTerminalOffscreen.isSafe(),
                  "the AppKit recovery manager attaches to the requesting workspace")
        let fileRecord = try await EditorDraftStore.shared.archive.load(file.draftID)!
        tabs[0].isZoomed = true
        try check(restoringManager.restoreEditorDraft(fileRecord) && tabs[0].focusedPaneID == tabs[0].allPanes[0].id && !tabs[0].isZoomed,
                  "recovering another pane leaves the previous zoom and reveals its split context")
        tabs[0].isZoomed = true
        try check(restoringManager.restoreEditorDraft(fileRecord) && tabs[0].isZoomed,
                  "recovering the already focused pane preserves its zoom")
        panel.performClose(nil)
        try check(!panel.isVisible && panel.parent == nil, "closing recovery dismisses its panel without restoring or deleting")
        EditorDraftStore.shared.flush()
        try check(try await EditorDraftStore.shared.archive.load(file.draftID) != nil,
                  "cancelled recovery/close leaves the backup available")
        try check(file.save { _, _ in .overwrite } && !file.isDirty,
                  "explicit overwrite saves the recovered file after comparing the disk version")
        try check(try await EditorDraftStore.shared.archive.load(file.draftID) == nil,
                  "a successful recovered save clears its durable backup")
        deleted.discardDraftBackup()
        EditorDraftStore.shared.flush()
        try check(try await EditorDraftStore.shared.archive.load(deleted.draftID) == nil,
                  "explicit discard stays removed through the quit flush")

        AppSettings.shared.recoverEditorDrafts = false
        diff.updateEditedContent(fileID: diff.web.fileID, contents: "edit while backups are off")
        try await Task.sleep(for: .milliseconds(650))
        let retained = try await EditorDraftStore.shared.archive.load(diff.draftID)
        try check(retained?.text == diffDraft, "disabling drafts stops writing and retains the previous backup")
        let disabled = DiffTab(repoRoot: diff.repoRoot, path: diff.path, staged: false, untracked: true,
                               origPath: nil, draftID: diff.draftID, recoveringDraft: true)
        try await wait("disabled diff loads from disk") { !disabled.isLoading }
        try check(!disabled.isDirty && disabled.web.newContent == "external diff version",
                  "disabled automatic recovery loads disk without deleting retained backups")
        let manager = TerminalManager()
        try check(manager.restoreEditorDraft(retained!) && restoringManager.hasUnsavedChanges,
                  "manual recovery reuses the existing dirty pane in another window while backups are off")
        try check(!manager.projects.flatMap(\.tabs).flatMap(\.allContents).contains { $0.draftID == retained!.id },
                  "cross-window manual recovery does not register a duplicate buffer for the same draft ID")
        var duplicate: DiffTab? = DiffTab(repoRoot: diff.repoRoot, path: diff.path, staged: false, untracked: true,
                                        origPath: nil, draftID: diff.draftID)
        let duplicateID = duplicate!.draftID
        try check(duplicateID != diff.draftID && disabled.draftID != diff.draftID,
                  "duplicate saved identities claim independent backup registrations")
        try await wait("a duplicate loads disk") { duplicate?.isLoading == false }
        duplicate!.updateEditedContent(fileID: duplicate!.web.fileID, contents: "independent duplicate buffer")
        AppSettings.shared.recoverEditorDrafts = true
        EditorDraftStore.shared.flush()
        let duplicateBackup = try await EditorDraftStore.shared.archive.load(duplicateID)
        let originalBackup = try await EditorDraftStore.shared.archive.load(diff.draftID)
        try check(duplicateBackup?.text == "independent duplicate buffer" && originalBackup?.text == "edit while backups are off",
                  "both independently edited buffers keep durable backups")
        duplicate = nil
        diff.updateEditedContent(fileID: diff.web.fileID, contents: "original owner remains active")
        EditorDraftStore.shared.flush()
        try check(try await EditorDraftStore.shared.archive.load(diff.draftID)?.text == "original owner remains active",
                  "unloading a duplicate cannot unregister the original editor")
        for project in manager.projects { project.terminateAll() }
    }

    @MainActor private static func quota(_ root: URL) async throws {
        let path = root.appendingPathComponent("quota-base.txt")
        try "base".write(to: path, atomically: true, encoding: .utf8)
        let baseline = try FileSaveCoordinator.read(path: path.path)
        for action in ["load", "records", "flush", "startup", "disabled-timer"] {
            let directory = root.appendingPathComponent("quota-\(action)")
            let archive = EditorDraftArchive(directory: directory, enabled: true)
            let records = (0..<EditorDraftArchive.maximumEntries).map {
                EditorDraftRecord(id: UUID(), source: .file(path: path.path), text: "draft \($0)", baseline: baseline)
            }
            try archive.flush(records)
            for (index, record) in records.enumerated() {
                let url = directory.appendingPathComponent("\(record.id.uuidString.lowercased()).json")
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(-60 - index))],
                                                       ofItemAtPath: url.path)
            }
            if action == "disabled-timer" {
                archive.setEnabled(false)
                archive.startExpiryCleanup(interval: 0.05)
                try await Task.sleep(for: .milliseconds(100))
            }
            let malformedID = UUID()
            let malformed = directory.appendingPathComponent("\(malformedID.uuidString.lowercased()).json")
            try Data("{broken JSON".utf8).write(to: malformed)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: malformed.path)
            var rejected: [URL] = [malformed]
            for expired in [false, true] {
                let candidate = EditorDraftRecord(id: UUID(), source: .file(path: path.path), text: "invalid draft", baseline: baseline)
                var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as! [String: Any]
                if expired { payload["updatedAt"] = Date().addingTimeInterval(-EditorDraftArchive.retention - 60).timeIntervalSinceReferenceDate }
                else { payload["version"] = 2 }
                let url = directory.appendingPathComponent("\(candidate.id.uuidString.lowercased()).json")
                try JSONSerialization.data(withJSONObject: payload).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                rejected.append(url)
            }
            let ids = Set(records.map(\.id))
            switch action {
            case "load":
                try check(try await archive.load(malformedID) == nil, "a malformed quota candidate cannot be loaded")
            case "records":
                try check(Set(try await archive.records().map(\.id)) == ids,
                          "listing skips newer malformed JSON without losing any of the 32 valid draft IDs")
            case "flush": try archive.flush([records[0]])
            case "startup":
                archive.startExpiryCleanup()
                try await Task.sleep(for: .milliseconds(150))
            default: try await Task.sleep(for: .milliseconds(150))
            }
            let remaining = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
            try check(remaining.isSuperset(of: ids),
                      "\(action) preserves all 32 valid draft IDs when a newer malformed entry is present")
            try check(Set(try await archive.records().map(\.id)) == ids,
                      "\(action) retains every valid draft for later recovery")
            try check(rejected.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                      "\(action) removes malformed, invalid and expired JSON before they can consume the archive quota")
        }
    }

    @MainActor private static func capacity(_ root: URL, baseline: FileSaveSnapshot) async throws {
        let directory = root.appendingPathComponent("capacity-archive")
        let archive = EditorDraftArchive(directory: directory, enabled: true)
        let text = String(repeating: "x", count: (4 << 20) - 1024)
        let records = (0..<EditorDraftArchive.maximumEntries).map { _ in
            EditorDraftRecord(id: UUID(), source: .file(path: baseline.destinationPath), text: text, baseline: baseline)
        }
        try archive.flush(records)
        func bytes() throws -> Int {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                .reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        }
        try check(try bytes() > 127 << 20 && bytes() <= EditorDraftArchive.maximumTotalBytes,
                  "32 valid draft payloads exercise the 128 MiB archive boundary")
        let small = EditorDraftRecord(id: records[0].id, source: records[0].source, text: "new keystroke", baseline: baseline)
        let started = Date()
        let error = await withCheckedContinuation { continuation in
            archive.write([small]) { continuation.resume(returning: $0) }
        }
        if let error { throw error }
        let duration = Date().timeIntervalSince(started)
        print("DRAFT_ARCHIVE_INCREMENTAL_WRITE_SECONDS=\(duration)")
        try check(duration < 0.5, "a healthy near-capacity incremental write finishes within the automatic backup window")
        let corrupt = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        FileManager.default.createFile(atPath: corrupt.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let file = try FileHandle(forWritingTo: corrupt)
        try file.truncate(atOffset: 70 << 20)
        try file.close()
        try archive.flush([small])
        try check(!FileManager.default.fileExists(atPath: corrupt.path) && bytes() <= EditorDraftArchive.maximumTotalBytes,
                  "a large malformed candidate is removed before applying the total-byte quota")
        try check(Set(try await archive.records().map(\.id)) == Set(records.map(\.id)),
                  "a newer malformed file cannot displace valid IDs from a near-capacity archive")
        let oversized = EditorDraftRecord(id: UUID(), source: records[0].source, text: text, baseline: baseline)
        try archive.flush([oversized])
        let bounded = try await archive.records()
        try check(bounded.count <= EditorDraftArchive.maximumEntries && bounded.contains { $0.id == oversized.id }
                  && bytes() <= EditorDraftArchive.maximumTotalBytes,
                  "a new valid draft still enforces both capacity limits")
    }

    @MainActor private static func boundaries(_ root: URL) async throws {
        try await quota(root)
        let path = root.appendingPathComponent("archive-base.txt")
        try "base".write(to: path, atomically: true, encoding: .utf8)
        let baseline = try FileSaveCoordinator.read(path: path.path)
        let directory = root.appendingPathComponent("private-archive")
        let archive = EditorDraftArchive(directory: directory, enabled: true)
        let record = EditorDraftRecord(id: UUID(), source: .file(path: path.path), text: "draft", baseline: baseline)
        try archive.flush([record])
        let actual = directory.appendingPathComponent("\(record.id.uuidString.lowercased()).json")
        let modes = try [directory, actual].map { try FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as! NSNumber }
        try check(modes[0].intValue == 0o700 && modes[1].intValue == 0o600,
                  "drafts are private on disk before any rename publishes them")
        for _ in 0..<40 {
            try archive.flush([EditorDraftRecord(id: UUID(), source: .file(path: path.path), text: "bounded", baseline: baseline)])
        }
        try check(try await archive.records().count <= EditorDraftArchive.maximumEntries,
                  "an archive with many abandoned editors stays bounded")
        let fifoID = UUID()
        let fifo = directory.appendingPathComponent("\(fifoID.uuidString.lowercased()).json")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw failure("mkfifo") }
        try check(try await archive.load(fifoID) == nil, "a draft path replaced with a FIFO cannot block recovery")
        let external = root.appendingPathComponent("external-private.txt")
        try "do not read or write".write(to: external, atomically: true, encoding: .utf8)
        let linkID = UUID()
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("\(linkID.uuidString.lowercased()).json").path,
                                                   withDestinationPath: external.path)
        try check(try await archive.load(linkID) == nil, "a draft symlink is rejected without reading its target")
        do {
            try archive.flush([EditorDraftRecord(id: linkID, source: .file(path: path.path), text: "attack", baseline: baseline)])
            throw failure("symlink write accepted")
        } catch EditorDraftArchive.Failure.unsafeFile { }
        try check(try String(contentsOf: external, encoding: .utf8) == "do not read or write",
                  "a substituted draft symlink cannot overwrite an external file")
        let corruptID = UUID()
        let corrupt = directory.appendingPathComponent("\(corruptID.uuidString.lowercased()).json")
        try Data("{broken JSON".utf8).write(to: corrupt)
        chmod(corrupt.path, 0o600)
        try check(try await archive.load(corruptID) == nil, "malformed JSON does not discard the usable archive")
        let tooLarge = EditorDraftRecord(id: UUID(), source: .file(path: path.path),
                                         text: String(repeating: "x", count: FileSaveCoordinator.maxBytes + 1), baseline: baseline)
        do { try archive.flush([tooLarge]); throw failure("oversized text accepted") }
        catch EditorDraftArchive.Failure.invalidRecord { }
        try check(try await archive.load(tooLarge.id) == nil, "oversized buffers cannot create unbounded backups")
        let oversizedID = UUID()
        let oversized = directory.appendingPathComponent("\(oversizedID.uuidString.lowercased()).json")
        FileManager.default.createFile(atPath: oversized.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(EditorDraftArchive.maximumRecordBytes + 1))
        try handle.close()
        try check(try await archive.load(oversizedID) == nil, "oversized JSON is rejected before allocating its payload")
        let expired = EditorDraftRecord(id: UUID(), source: .file(path: path.path), text: "expired", baseline: baseline)
        let expiredPath = directory.appendingPathComponent("\(expired.id.uuidString.lowercased()).json")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expired)) as! [String: Any]
        let old = Date().addingTimeInterval(-EditorDraftArchive.retention - 60)
        json["updatedAt"] = old.timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: json).write(to: expiredPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: old], ofItemAtPath: expiredPath.path)
        try check(try await archive.load(expired.id) == nil, "drafts older than 30 days cannot be restored")
        try check(!FileManager.default.fileExists(atPath: expiredPath.path), "loading removes an expired backup without a new write")
        let hardID = UUID()
        let hard = directory.appendingPathComponent("\(hardID.uuidString.lowercased()).json")
        chmod(external.path, 0o600)
        guard Darwin.link(external.path, hard.path) == 0 else { throw failure("hardlink") }
        try check(try await archive.load(hardID) == nil, "hardlinked draft files cannot expose another file")
        do {
            try archive.flush([EditorDraftRecord(id: hardID, source: .file(path: path.path), text: "attack", baseline: baseline)])
            throw failure("hardlink write accepted")
        } catch EditorDraftArchive.Failure.unsafeFile { }
        try check(try String(contentsOf: external, encoding: .utf8) == "do not read or write",
                  "hardlinked archive paths cannot overwrite their other link")
        let interrupted = directory.appendingPathComponent(".\(UUID().uuidString.lowercased()).tmp")
        try Data("interrupted".utf8).write(to: interrupted)
        try archive.flush([record])
        try check(!FileManager.default.fileExists(atPath: interrupted.path), "a later write removes interrupted atomic-write files")
        try await capacity(root, baseline: baseline)

        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            archive.write([]) { _ in
                continuation.resume()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        let removalStarted = Date()
        archive.remove(record.id)
        let removalDuration = Date().timeIntervalSince(removalStarted)
        release.signal()
        try check(removalDuration < 0.5, "removing a backup returns while an earlier writer still owns the archive queue")
        try check(try await archive.load(record.id) == nil, "a queued removal completes before a later load")
        archive.write([record]) { _ in }
        archive.remove(record.id)
        try archive.flush()
        try check(!FileManager.default.fileExists(atPath: actual.path), "write, remove, and flush keep their serial order")
        archive.write([record]) { _ in }
        try check(try await archive.load(record.id)?.text == record.text, "new edits can back up again after an ordered removal")

        archive.setEnabled(false)
        archive.remove(record.id)
        try archive.flush([record])
        try check(try await archive.load(record.id) == nil, "disabled writing cannot recreate a deleted backup")
        let symlinkDirectory = root.appendingPathComponent("unsafe-archive")
        try FileManager.default.createSymbolicLink(atPath: symlinkDirectory.path, withDestinationPath: directory.path)
        let unsafe = EditorDraftArchive(directory: symlinkDirectory, enabled: true)
        do { try unsafe.flush([record]); throw failure("symlink directory accepted") }
        catch EditorDraftArchive.Failure.unsafeDirectory { }
        try check(true, "linked archive directories are rejected before writing")
    }

    @MainActor private static func expiry(_ root: URL) async throws {
        SessionStore.save([])
        AppSettings.shared.recoverEditorDrafts = false
        let path = root.appendingPathComponent("expiry-base.txt")
        try "base".write(to: path, atomically: true, encoding: .utf8)
        let baseline = try FileSaveCoordinator.read(path: path.path)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = ((try? SettingsConfigFile.resolve(support)) ?? support).appendingPathComponent("zshell-dev")
        let directory = base.appendingPathComponent("editor-drafts")
        // The driver reuses its disposable home after restore; those valid
        // leftovers must not turn this 32-draft fixture into a real overflow.
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let old = Date().addingTimeInterval(-EditorDraftArchive.retention - 60)
        func backup(expired: Bool, modified: Date = Date()) throws -> URL {
            let record = EditorDraftRecord(id: UUID(), source: .file(path: path.path), text: "private draft", baseline: baseline)
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
            if expired { json["updatedAt"] = old.timeIntervalSinceReferenceDate }
            let url = directory.appendingPathComponent("\(record.id.uuidString.lowercased()).json")
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let overdue = try backup(expired: true, modified: old)
        let refreshed = try backup(expired: true)
        let current = try (0..<EditorDraftArchive.maximumEntries).map { _ in
            try backup(expired: false, modified: Date().addingTimeInterval(-60))
        }
        let malformed = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        try Data("{broken JSON".utf8).write(to: malformed)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: malformed.path)
        let interrupted = directory.appendingPathComponent(".\(UUID().uuidString.lowercased()).tmp")
        try Data("unpublished private text".utf8).write(to: interrupted)
        let delegate = ZshellApplicationDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        NSApp.setActivationPolicy(.prohibited)
        try await wait("launch cleanup runs with backups off and no editor clients") {
            !FileManager.default.fileExists(atPath: overdue.path) && !FileManager.default.fileExists(atPath: refreshed.path)
                && !FileManager.default.fileExists(atPath: malformed.path)
        }
        try check(!AppSettings.shared.recoverEditorDrafts && current.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                  "application startup removes malformed and expired backups but preserves all 32 valid draft IDs with backups off")
        try check(!FileManager.default.fileExists(atPath: interrupted.path),
                  "startup cleanup removes interrupted private temporary files without new backups")

        let periodicDirectory = root.appendingPathComponent("periodic-expiry")
        let seed = EditorDraftArchive(directory: periodicDirectory, enabled: true)
        let record = EditorDraftRecord(id: UUID(), source: .file(path: path.path), text: "periodic draft", baseline: baseline)
        try seed.flush([record])
        let periodicPath = periodicDirectory.appendingPathComponent("\(record.id.uuidString.lowercased()).json")
        let periodic = EditorDraftArchive(directory: periodicDirectory, enabled: false)
        periodic.startExpiryCleanup(interval: 0.05)
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: periodicPath.path)
        try await wait("periodic cleanup runs without writes or listing") { !FileManager.default.fileExists(atPath: periodicPath.path) }
        try check(true, "the independent timer removes newly expired backups while writing remains disabled")
        try check(QuickTerminalOffscreen.isSafe(), "startup expiry cleanup never opens test windows on screen")
        for window in NSApp.windows { window.orderOut(nil) }
    }

    @MainActor private static func workspace(_ root: URL) async throws {
        AppMenuController.shared.install()
        let menu = NSApp.mainMenu!.items.dropFirst().first!.submenu!
        try check(menu.items.contains { $0.title == String(localized: "Recover Drafts…") },
                  "the production File menu includes the recovery action")
        let controller = ZshellWorkspaceWindowController(number: 1)
        let window = controller.window!, manager = controller.manager
        controller.showWindow(nil)
        let project = manager.newProject()
        let path = root.appendingPathComponent("workspace-file.txt")
        try "file baseline".write(to: path, atomically: true, encoding: .utf8)
        let file = try await loaded(path)
        file.text = "independent file pane"; file.refreshDirtyState()
        let diffPath = root.appendingPathComponent("workspace-diff.txt")
        try "before\n".write(to: diffPath, atomically: true, encoding: .utf8)
        let diff = try await loadedDiff(root, name: "workspace-diff.txt")
        let draft = "Recovered workspace diff 中文\n" + String(repeating: "long diff line ", count: 30) + "\n"
        diff.restoreDraft(EditorDraftRecord(id: diff.draftID,
            source: .diff(repoRoot: root.path, path: diff.path, untracked: true, originalPath: nil),
            text: draft, baseline: diff.saveBaseline!,
            diffState: .init(oldText: "before\n", style: "split", editing: true, editor: nil)))
        let filePane = Pane(content: .file(file)), diffPane = Pane(content: .diff(diff))
        let tab = PaneTab(layout: .split(.init(axis: .horizontal, fraction: 0.57,
            first: .pane(filePane), second: .pane(diffPane))), focusedPaneID: diffPane.id)
        project.append(tab)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await wait("workspace creates its actual pane anchors") {
            descendants(window.contentView!).contains { $0 is DiffPaneAnchorNSView }
        }
        let workspace = descendants(window.contentView!).compactMap { $0 as? DiffWorkspaceNSView }.first!
        try await wait("workspace mounts only the selected diff") { diff.webHostView != nil }
        let web = descendants(diff.webHostView!).compactMap { $0 as? WKWebView }.first!
        web.configuration.userContentController.addUserScript(WKUserScript(source: """
            window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 16);
            window.cancelAnimationFrame = clearTimeout;
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        try await wait("the real diff bridge becomes ready") { diff.web.isReady }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
            workspace.layoutSubtreeIfNeeded()
        }
        try await settle()
        let viewer = descendants(workspace).compactMap { $0 as? DiffViewerNSView }.first { $0.isHidden == false }!
        let expected = manager.diffWorkspaceLayout.frame(for: diff.id, in: workspace)!
        try check(viewer.frame.equalTo(expected) && expected.width < workspace.bounds.width * 0.6,
                  "a recovered file-plus-diff workspace places the diff in its actual split rectangle")
        try check(workspace.layer?.masksToBounds == true && viewer.layer?.masksToBounds == true,
                  "diff backgrounds and selection layers are clipped by native pane bounds")
        try check(!viewer.frame.contains(NSPoint(x: expected.minX - 5, y: expected.midY)),
                  "the diff renderer cannot draw or accept hits in the divider gap")
        var rendered = false
        for _ in 0..<100 {
            let renderer = try await web.evaluateJavaScript("window.__INSTANCE?.render(true); window.__INSTANCE?.getEditor('" + diff.web.fileID + "')?.getText()")
            if renderer as? String == draft { rendered = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(rendered, "the complete workspace renders the actual recovered Pierre document")
        for width in [520.0, 940.0] {
            window.setContentSize(NSSize(width: width, height: 640))
            try await settle()
            let expected = manager.diffWorkspaceLayout.frame(for: diff.id, in: workspace)!
            try check(viewer.frame.equalTo(expected) && workspace.bounds.contains(viewer.frame),
                      "native diff bounds follow workspace resize to \(Int(width)) points")
        }
        let original = diff.webHostView
        tab.focusPane(filePane.id); tab.isZoomed = true
        try await settle()
        try check(viewer.isHidden && diff.webHostView === original,
                  "zooming the file hides and retains the neighboring diff renderer")
        tab.focusPane(diffPane.id)
        try await settle()
        try check(!tab.isZoomed && !viewer.isHidden && diff.webHostView === original,
                  "switching the zoomed pane reveals its retained split diff")
        tab.isZoomed = true
        try await settle()
        try check(viewer.frame.width > workspace.bounds.width * 0.9 && diff.webHostView === original,
                  "zooming the diff expands its native frame without rebuilding WebKit")
        tab.isZoomed = false
        diff.setDiffStyle(.unified)
        try await settle()
        try check(diff.webHostView === original && !viewer.isHidden,
                  "unified diff editing keeps the same native pane and document")
        let otherProject = manager.newProject()
        try await settle()
        try check(viewer.isHidden && diff.webHostView === original,
                  "switching projects hides and retains the original native diff")
        manager.selectedProjectID = project.id
        try await settle()
        try check(!viewer.isHidden && diff.webHostView === original && otherProject.id != project.id,
                  "returning to a visited project reuses its same WebKit document")
        let other = PaneTab(content: .file(file)); project.append(other)
        try await settle()
        try check(viewer.isHidden && diff.webHostView === original, "switching tabs hides the diff without unmounting its WebKit tree")
        project.selectedTabID = tab.id
        try await settle()
        try check(!viewer.isHidden && diff.webHostView === original, "returning to a split tab reuses its retained diff renderer")
        let terminal = project.sessions.first!
        project.tabs.removeAll { $0.sessions.contains(where: { $0.id == terminal.id }) }
        let terminalPane = Pane(content: .session(terminal))
        tab.layout = .split(.init(axis: .horizontal, fraction: 0.48,
            first: .pane(terminalPane), second: .pane(diffPane)))
        try await settle()
        try check(viewer.frame.equalTo(manager.diffWorkspaceLayout.frame(for: diff.id, in: workspace)!),
                  "a terminal-plus-diff layout confines the diff to its own pane")

        func hit(at point: NSPoint) -> NSView? {
            let root = window.contentView!.superview!
            return root.hitTest(root.superview?.convert(point, from: nil) ?? point)
        }
        func click(at point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                NSApp.sendEvent(event)
            }
        }
        let diffPoint = viewer.convert(NSPoint(x: viewer.bounds.midX, y: viewer.bounds.midY), to: nil)
        try check(hit(at: diffPoint).map { $0 === viewer || $0.isDescendant(of: viewer) } == true,
                  "a normal window hit test resolves inside the actual diff viewer")
        tab.focusPane(terminalPane.id)
        click(at: diffPoint)
        try check(tab.focusedPaneID == diffPane.id, "a normal diff click focuses its pane through the production event monitor")
        tab.focusPane(terminalPane.id)
        manager.toggleCommandPalette()
        try await settle()
        try check(hit(at: diffPoint).map { $0 !== viewer && !$0.isDescendant(of: viewer) } == true,
                  "the real command palette receives hits over the diff rectangle")
        click(at: diffPoint)
        try check(tab.focusedPaneID == terminalPane.id && manager.canSplit,
                  "clicking the command palette over a diff preserves the terminal command target")
        manager.dismissCommandPalette()
        try await settle()
        let switcher = descendants(window.contentView!).compactMap { $0 as? TabSwitcherMonitorView }.first!.controller!
        let controlTab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        _ = switcher.handle(controlTab, manager: manager)
        try await settle()
        let switcherPoint = stride(from: viewer.bounds.minX + 20, to: viewer.bounds.maxX - 20, by: 20)
            .flatMap { x in stride(from: viewer.bounds.minY + 20, to: viewer.bounds.maxY - 20, by: 20)
                .map { viewer.convert(NSPoint(x: x, y: $0), to: nil) } }
            .first { point in hit(at: point).map { $0 !== viewer && !$0.isDescendant(of: viewer) } == true }
        try check(switcher.isPresented && switcherPoint != nil,
                  "the real tab switcher receives hits over the diff rectangle")
        click(at: switcherPoint!)
        try check(tab.focusedPaneID == terminalPane.id, "clicking a tab switcher card cannot steal pane focus for the covered diff")
        switcher.cancel()
        project.selectedTabID = tab.id
        try await settle()
        let otherPath = root.appendingPathComponent("other-workspace-diff.txt")
        try "before other".write(to: otherPath, atomically: true, encoding: .utf8)
        let second = try await loadedDiff(root, name: otherPath.lastPathComponent)
        second.restoreDraft("second diff draft", baseline: second.saveBaseline!)
        let secondPane = Pane(content: .diff(second))
        tab.layout = .split(.init(axis: .horizontal, fraction: 0.52, first: .pane(diffPane), second: .pane(secondPane)))
        try await settle()
        let visible = descendants(workspace).compactMap { $0 as? DiffViewerNSView }.filter { !$0.isHidden }
        try check(visible.count == 2 && !visible[0].frame.intersects(visible[1].frame),
                  "two editable diff panes have distinct non-overlapping native rectangles")
        try check(diff.webHostView === original && QuickTerminalOffscreen.isSafe(),
                  "workspace changes preserve the original renderer and never capture input on screen")
        for project in manager.projects { project.terminateAll() }
        window.orderOut(nil)
        window.contentView = nil
        manager.windowClosed()
    }
}

private extension SessionSnapshot.ProjectSnapshot.LayoutSnapshot {
    var allDraftIDs: [UUID] {
        switch self {
        case .pane(let pane): return pane.draftID.map { [$0] } ?? []
        case .split(_, _, let first, let second): return first.allDraftIDs + second.allDraftIDs
        }
    }
}
